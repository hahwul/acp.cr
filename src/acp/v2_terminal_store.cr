require "./protocol/v2/updates"

module ACP
  module V2
    # A detached snapshot of the Agent-owned terminal reported by a session.
    # Nil output means the Agent has not supplied output or has cleared it.
    # Capabilities reflect the reported state, including during replay.
    record TerminalSnapshot,
      session_id : String,
      terminal_id : String,
      command : String?,
      cwd : String?,
      size : Protocol::V2::TerminalSize?,
      output : Bytes?,
      output_meta_raw : Protocol::RawJson?,
      exit_status : Protocol::V2::TerminalExitStatus?,
      capabilities : Protocol::V2::EntityCapabilities?,
      meta_raw : Protocol::RawJson?

    # Retains display state from ACP v2 terminal updates in receive order.
    class TerminalStore
      private alias Wire = Protocol::V2

      # Default number of output bytes retained per terminal.
      DEFAULT_OUTPUT_BYTE_LIMIT = 1024 * 1024

      # Default number of terminals retained across sessions in a store.
      DEFAULT_TERMINAL_LIMIT = 128

      # Default byte limit for the accumulated top-level metadata on a terminal.
      DEFAULT_TERMINAL_METADATA_BYTE_LIMIT = 64 * 1024

      private class Output
        @buffer = Bytes.empty
        @start = 0
        @size = 0

        def initialize(@limit : Int32)
        end

        def append(output : Wire::TerminalOutput | Wire::TerminalOutputChunk) : Nil
          return if @limit.zero? || output.data.empty?

          bytes = output.bytes
          bytes = bytes[bytes.size - @limit, @limit] if bytes.size > @limit
          size = Math.min(@size.to_i64 + bytes.size, @limit).to_i
          grow(size) if size > @buffer.size

          previous_size = size - bytes.size
          @start = position(@start, @size - previous_size)
          offset = position(@start, previous_size)
          first = Math.min(bytes.size, @buffer.size - offset)
          bytes[0, first].copy_to(@buffer + offset)
          bytes[first, bytes.size - first].copy_to(@buffer)
          @size = size
        end

        def snapshot : Bytes
          result = Bytes.new(@size)
          copy_to(result)
          result
        end

        private def copy_to(dest : Bytes) : Nil
          return if @size.zero?

          first = Math.min(@size, @buffer.size - @start)
          @buffer[@start, first].copy_to(dest)
          @buffer[0, @size - first].copy_to(dest + first)
        end

        private def grow(size : Int32) : Nil
          capacity = Math.min(Math.max(size, @buffer.size.to_i64 * 2), @limit).to_i
          replacement = Bytes.new(capacity)
          copy_to(replacement)
          @buffer = replacement
          @start = 0
        end

        private def position(start : Int32, distance : Int32) : Int32
          ((start.to_i64 + distance) % @buffer.size).to_i
        end
      end

      private class Entry
        @fields : Wire::TerminalUpdate
        @output : Output?
        @output_meta_raw : Protocol::RawJson?
        @meta_raw : Protocol::RawJson?

        def initialize(terminal_id : String, @output_byte_limit : Int32, @terminal_metadata_byte_limit : Int32)
          @fields = Wire::TerminalUpdate.new(terminal_id)
        end

        def apply(patch : Wire::TerminalUpdate) : Nil
          if patch.meta_present?
            metadata = patch.apply_metadata_raw(@meta_raw)
            @meta_raw = metadata if !metadata || metadata.json.bytesize <= @terminal_metadata_byte_limit
          end
          @fields.command = patch.command if patch.command_present?
          @fields.cwd = patch.cwd if patch.cwd_present?
          @fields.size = patch.size if patch.size_present?
          @fields.exit_status = patch.exit_status if patch.exit_status_present?
          @fields.capabilities = patch.capabilities if patch.capabilities_present?
          if patch.output_present?
            @output = nil
            @output_meta_raw = nil
            if replacement = patch.output
              (@output = Output.new(@output_byte_limit)).append(replacement)
              @output_meta_raw = replacement.meta_raw
            end
          end
        end

        def apply(chunk : Wire::TerminalOutputChunk) : Nil
          (@output ||= Output.new(@output_byte_limit)).append(chunk)
        end

        def snapshot(session_id : String) : TerminalSnapshot
          # Detach the typed fields, including their editable metadata views.
          current = Wire::TerminalUpdate.from_json(Protocol::WireFrame.encode(@fields))
          TerminalSnapshot.new(session_id, current.terminal_id, current.command, current.cwd,
            current.size, @output.try(&.snapshot), @output_meta_raw, current.exit_status,
            current.capabilities, @meta_raw)
        end
      end

      @terminals = {} of {String, String} => Entry
      @mutex = Mutex.new

      # Creates a store with limits for terminal count and each terminal's output and top-level metadata.
      # Zero output bytes retains terminal state and empty output.
      def initialize(@output_byte_limit : Int32 = DEFAULT_OUTPUT_BYTE_LIMIT, *,
                     @terminal_limit : Int32 = DEFAULT_TERMINAL_LIMIT,
                     @terminal_metadata_byte_limit : Int32 = DEFAULT_TERMINAL_METADATA_BYTE_LIMIT)
        raise ArgumentError.new("Terminal output byte limit must be non-negative") if @output_byte_limit < 0
        raise ArgumentError.new("Terminal limit must be positive") if @terminal_limit <= 0
        raise ArgumentError.new("Terminal metadata byte limit must be non-negative") if @terminal_metadata_byte_limit < 0
      end

      # Applies a terminal patch or chunk. Returns false for other updates, malformed updates,
      # or a new terminal above the terminal limit. Over-budget terminal metadata is left unchanged.
      # Call this with each session update in receive order.
      def observe(params : Wire::SessionUpdateParams) : Bool
        return false unless params.update.session_update.in?("terminal_update", "terminal_output_chunk")

        case update = params.update.typed
        when Wire::TerminalUpdate, Wire::TerminalOutputChunk
          @mutex.synchronize do
            key = {params.session_id, update.terminal_id}
            unless entry = @terminals[key]?
              return false if @terminals.size >= @terminal_limit

              entry = @terminals[key] = Entry.new(update.terminal_id, @output_byte_limit, @terminal_metadata_byte_limit)
            end
            entry.apply(update)
          end
          true
        else
          false
        end
      end

      # Returns the current display state for this session and terminal, if seen.
      def terminal(session_id : String, terminal_id : String) : TerminalSnapshot?
        @mutex.synchronize do
          @terminals[{session_id, terminal_id}]?.try(&.snapshot(session_id))
        end
      end

      # Drops the display history for a session, for example before replaying it from the start.
      def forget_session(session_id : String) : Bool
        @mutex.synchronize do
          before = @terminals.size
          @terminals.reject! { |key, _| key[0] == session_id }
          @terminals.size < before
        end
      end
    end
  end
end
