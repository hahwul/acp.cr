# ACP Transport Layer
#
# Provides the abstraction for sending and receiving JSON-RPC 2.0
# messages over different transport mechanisms. The primary transport
# is newline-delimited JSON over stdio (stdin/stdout of a child process).
#
# Architecture:
#   - `Transport` is the abstract base that defines the interface.
#   - `StdioTransport` implements communication over IO pairs (typically
#     the stdin/stdout of a spawned agent process).
#   - Messages are read/written as single-line JSON terminated by '\n'.
#   - A dedicated reader fiber pushes incoming messages into a Channel,
#     decoupling the read loop from message processing.

require "json"
require "./protocol/wire_frame"
require "log"
require "path"
require "./errors"
require "./protocol/types"
require "./protocol/client_methods"

module ACP
  # Logger for transport-level diagnostics.
  Log = ::Log.for("acp.transport")

  # ─── Abstract Transport ───────────────────────────────────────────

  # Abstract base class for all ACP transports. Subclasses must implement
  # the raw read/write operations; the base class provides the JSON
  # parsing/serialization layer on top.
  abstract class Transport
    # A frame already decoded as JSON::Any or preserved as exact wire JSON.
    alias IncomingFrame = JSON::Any | Protocol::WireFrame

    # Sends a JSON-RPC message (Hash serialized to JSON + newline).
    abstract def send(message : Hash(String, JSON::Any)) : Nil

    # Runs a preflight before sending. Transports with a write queue can
    # override this method to run it under the write lock immediately before IO.
    # A preflight that raises leaves the message unsent.
    def send_checked(message : Hash(String, JSON::Any), &preflight : -> Nil) : Nil
      preflight.call
      send(message)
    end

    # Sends exact serialized JSON. Custom transports can override this to
    # support values outside the range of JSON::Any.
    def send_wire(frame : Protocol::WireFrame, &preflight : -> Nil) : Nil
      message = JSON.parse(frame.json).as_h
      send_checked(message, &preflight)
    rescue JSON::Error
      raise ProtocolError.new("This transport cannot send an exact JSON frame")
    end

    # Receives the next incoming JSON message, blocking until one arrives.
    # Returns nil if the transport is closed.
    abstract def receive : JSON::Any?

    # Receives a frame for typed dispatch. Existing transports can continue
    # implementing receive alone.
    def receive_frame : IncomingFrame?
      receive
    end

    # Closes the transport, releasing any underlying resources.
    abstract def close : Nil

    # Returns true if the transport is open and operational.
    abstract def closed? : Bool
  end

  # ─── Stdio Transport ─────────────────────────────────────────────

  # Implements the ACP transport over a pair of IO objects. In the
  # typical case these are the stdin (for writing) and stdout (for
  # reading) of a spawned agent child process.
  #
  # Incoming messages are read in a background fiber and placed into
  # a buffered channel so that `#receive` never blocks the writer.
  #
  # Thread safety: Crystal fibers are cooperatively scheduled on a
  # single thread, so we don't need mutexes — just channels.
  class StdioTransport < Transport
    # Hard cap on the size of a single incoming JSON-RPC line. ACP messages
    # are typically a few KiB; 16 MiB is generous enough for an unusually
    # large ContentBlock (e.g. embedded image data) while preventing a
    # runaway / malicious agent from OOM-ing the client by streaming an
    # unbounded line.
    DEFAULT_MAX_LINE_BYTES = 16 * 1024 * 1024

    private DEFAULT_BUFFER_SIZE = 256
    private EXACT_BUFFER_SIZE   =   4

    # JSON-RPC method names whose `params` are treated as sensitive. The
    # transport redacts these from DEBUG-level frame logs so a session
    # with debug logging enabled does not write credentials/tokens to log
    # files. Add to this set if new methods carry secrets.
    SENSITIVE_METHODS = Set{"authenticate", "auth/status_update", Protocol::AgentMethod::MCP_MESSAGE, Protocol::ProxyMethod::SUCCESSOR}

    # The channel that the reader fiber pushes parsed messages into.
    # A nil value signals that the reader has stopped (EOF or error).
    getter incoming : Channel(IncomingFrame?)

    # Whether the transport has been closed.
    @closed : Bool = false

    # Mutex-like flag to prevent double-close.
    @close_sent : Bool = false

    # Set once `close` has run. Distinct from `@closed`, which also flips when
    # the stream ends on its own (EOF, write failure) — `close` must still
    # release the IOs in that case.
    @close_called : Bool = false

    # The IO we write outgoing messages to (agent's stdin).
    @writer : IO

    # The IO we read incoming messages from (agent's stdout).
    @reader : IO

    # The background reader fiber.
    @reader_fiber : Fiber? = nil

    # Set while a -32700 answer is being written; see `send_parse_error`.
    @parse_error_pending : Atomic(Bool) = Atomic(Bool).new(false)

    # Serializes outgoing writes. A write to a pipe can block (and therefore
    # yield to another fiber) part-way through a frame; without this lock a
    # second fiber's `send` would splice its bytes into the middle of the
    # first frame and hand the agent unparseable JSON.
    @write_mutex : Mutex = Mutex.new

    # Keep late and repeated replies protected. Once the bounded history is
    # full, nil means every response payload is redacted on this transport.
    private MAX_PROVIDER_LOG_IDS = 256
    @provider_request_id_hashes : Set(UInt64)? = Set(UInt64).new
    @provider_log_mutex : Mutex = Mutex.new

    # Maximum size of a single incoming JSON-RPC line, in bytes. Clamped at
    # construction so the read loop's `@max_line_bytes + 1` cannot overflow.
    @max_line_bytes : Int32

    # Whether every input frame is retained for lossless forwarding.
    getter? exact_frames : Bool

    # Creates a new stdio transport.
    #
    # - `reader` — the IO to read incoming JSON-RPC messages from
    #   (typically the agent process's stdout).
    # - `writer` — the IO to write outgoing JSON-RPC messages to
    #   (typically the agent process's stdin).
    # - `buffer_size` — how many messages to buffer in the channel
    #   before back-pressuring the reader fiber. Defaults to 256 in ordinary
    #   mode and 4 in exact mode.
    # - `max_line_bytes` — abort and log a warning if a single incoming
    #   line exceeds this many bytes. Default 16 MiB.
    # - `exact_frames` — retain every frame as exact JSON and apply the line
    #   limit in both directions for a relay.
    def initialize(
      @reader : IO,
      @writer : IO,
      buffer_size : Int32? = nil,
      max_line_bytes : Int32 = DEFAULT_MAX_LINE_BYTES,
      *,
      @exact_frames : Bool = false,
    )
      # Clamp so the read loop's `@max_line_bytes + 1` can never overflow Int32
      # (and a pathological non-positive value can't disable line reads).
      @max_line_bytes = max_line_bytes.clamp(1, Int32::MAX - 1)
      @incoming = Channel(IncomingFrame?).new(buffer_size || (@exact_frames ? EXACT_BUFFER_SIZE : DEFAULT_BUFFER_SIZE))
      start_reader
    end

    # Sends a JSON-RPC message over the transport. The message is
    # serialized as a single line of JSON followed by a newline.
    #
    # The frame is assembled in memory and written under `@write_mutex` so
    # that concurrent senders (e.g. a caller issuing a request while the
    # dispatcher fiber replies to an agent-initiated request) can never
    # interleave their bytes within a line.
    def send(message : Hash(String, JSON::Any)) : Nil
      write_message(message)
    end

    # Runs a preflight immediately before writing a complete frame.
    def send_checked(message : Hash(String, JSON::Any), &preflight : -> Nil) : Nil
      write_message(message, preflight)
    end

    # Writes exact JSON using the same write lock as ordinary messages.
    def send_wire(frame : Protocol::WireFrame, &preflight : -> Nil) : Nil
      pull = JSON::PullParser.new(frame.json)
      raise ProtocolError.new("ACP frames must be JSON objects") unless pull.kind.begin_object?

      wire = frame.json.includes?('\n') ? Protocol::WireFrame.read_raw(pull) : frame.json
      if @exact_frames && wire.bytesize > @max_line_bytes
        raise TransportError.new("Outgoing ACP frame exceeds the relay line limit")
      end
      Log.debug { ">>> [REDACTED exact frame]" }
      write_line(wire + '\n', &preflight)
    end

    private def write_message(message : Hash(String, JSON::Any), preflight : (-> Nil)? = nil) : Nil
      raise ConnectionClosedError.new if @closed

      # Build the complete frame — payload *and* delimiter — before touching
      # the IO, so a single write carries a whole line.
      frame = String.build do |io|
        message.to_json(io)
        io << '\n'
      end
      Log.debug { ">>> #{redact_frame(message)}" }

      write_line(frame) do
        preflight.try(&.call)
        track_provider_request(message)
      end
    end

    private def write_line(frame : String, &preflight : -> Nil) : Nil
      @write_mutex.synchronize do
        # Re-check under the lock: the transport may have been closed while
        # we were queued behind another sender.
        raise ConnectionClosedError.new if @closed
        preflight.call

        begin
          @writer.print(frame)
          @writer.flush
        rescue ex : IO::Error
          Log.error { "Write failed: #{ex.message}" }
          @closed = true
          raise ConnectionClosedError.new("Failed to write: #{ex.message}")
        end
      end
    end

    # Receives the next incoming JSON-RPC message. Blocks until a
    # message is available. Returns nil if the transport is closed
    # or the reader encountered EOF.
    def receive : JSON::Any?
      loop do
        case msg = receive_frame
        when JSON::Any then return msg
        when Protocol::WireFrame
          if view = msg.representable
            return view
          end
        when Nil then return nil
        end
      end
    end

    # Receives JSON::Any or an exact frame for values outside its range.
    def receive_frame : IncomingFrame?
      return if @closed

      begin
        msg = @incoming.receive
        if msg.nil?
          # nil sentinel means the reader stopped.
          @closed = true
        end
        msg
      rescue Channel::ClosedError
        @closed = true
        nil
      end
    end

    # Receives with a timeout. Returns nil if no message arrives
    # within the given duration.
    def receive(timeout : Time::Span) : JSON::Any?
      deadline = Time.instant + timeout
      loop do
        remaining = deadline - Time.instant
        case msg = receive_frame(Math.max(remaining, Time::Span.zero))
        when JSON::Any then return msg
        when Nil       then return nil
        when Protocol::WireFrame
          if view = msg.representable
            return view
          end
          return nil if Time.instant >= deadline
        end
      end
    end

    # Receives an exact frame with a deadline.
    def receive_frame(timeout : Time::Span) : IncomingFrame?
      return if @closed

      select
      when msg = @incoming.receive
        if msg.nil?
          @closed = true
        end
        msg
      when timeout(timeout)
        nil
      end
    rescue Channel::ClosedError
      # The channel was closed (transport shutting down) while we were blocked
      # in the select; treat it the same as a nil sentinel.
      @closed = true
      nil
    end

    # Closes the transport, signaling the reader to stop and
    # closing the underlying IO objects.
    def close : Nil
      return if @close_called
      @close_called = true
      @closed = true

      # Mark the EOF sentinel as handled so the reader fiber won't try to push
      # a nil into a channel we're about to close, then close the channel.
      #
      # We deliberately do NOT perform a blocking `@incoming.send(nil)` here:
      # if the buffer is full and no fiber is currently receiving (e.g. the
      # dispatcher already stopped), that send would block forever and hang
      # close(). Closing the channel alone is sufficient to unblock any pending
      # `receive` — both `receive` variants treat `Channel::ClosedError` (and a
      # nil sentinel) as "transport closed -> nil".
      @close_sent = true
      @incoming.close

      # Close the underlying IOs if they support it.
      @writer.close rescue nil
      @reader.close rescue nil
    end

    # Returns true if the transport has been closed.
    def closed? : Bool
      @closed
    end

    # ─── Private ────────────────────────────────────────────────────

    # Redacts sensitive request parameters and MCP configurations from logs.
    private def redact_frame(message : Hash(String, JSON::Any)) : String
      method = message["method"]?.try(&.as_s?)
      return message.to_json unless params = message["params"]?

      redacted = JSON::Any.new("[REDACTED]")
      if method && (SENSITIVE_METHODS.includes?(method) || Protocol::AgentMethod::PROVIDER_METHODS.includes?(method))
        message.merge({"params" => redacted}).to_json
      elsif (fields = params.as_h?) && fields.has_key?("mcpServers")
        message.merge({"params" => JSON::Any.new(fields.merge({"mcpServers" => redacted}))}).to_json
      else
        message.to_json
      end
    rescue
      "[REDACTED frame]"
    end

    private def track_provider_request(message : Hash(String, JSON::Any)) : Nil
      return unless (method = message["method"]?.try(&.as_s?)) &&
                    (Protocol::AgentMethod::PROVIDER_METHODS.includes?(method) || method == Protocol::ProxyMethod::SUCCESSOR)
      return unless id = Protocol.extract_id(JSON::Any.new(message))

      @provider_log_mutex.synchronize do
        if ids = @provider_request_id_hashes
          ids.add(id.to_s.hash)
          @provider_request_id_hashes = nil if ids.size > MAX_PROVIDER_LOG_IDS
        end
      end
    end

    # Match the client's ID normalization. Hash collisions only redact extra logs.
    private def redact_response?(frame : JSON::Any, fields : Hash(String, JSON::Any)) : Bool
      return false unless fields.has_key?("result") || fields.has_key?("error")

      @provider_log_mutex.synchronize do
        if ids = @provider_request_id_hashes
          if id = Protocol.extract_id(frame)
            ids.includes?(id.to_s.hash)
          else
            !ids.empty?
          end
        else
          true
        end
      end
    end

    # Redacts incoming authentication payloads and launch descriptors.
    private def redact_raw_frame(line : String, frame : IncomingFrame) : String
      return "[REDACTED frame]" if frame.is_a?(Protocol::WireFrame)
      return "[REDACTED frame]" unless fields = frame.as_h?
      return "[REDACTED response]" if redact_response?(frame, fields)

      parsed = fields.dup
      method = parsed["method"]?.try(&.as_s?)
      if method && SENSITIVE_METHODS.includes?(method)
        parsed["params"] = JSON::Any.new("[REDACTED]") if parsed.has_key?("params")
        parsed["result"] = JSON::Any.new("[REDACTED]") if parsed.has_key?("result")
        return parsed.to_json
      end

      if result = parsed["result"]?.try(&.as_h?).try(&.dup)
        has_methods = result.has_key?("authMethods")
        has_accounts = result.has_key?("accounts")
        result["authMethods"] = JSON::Any.new("[REDACTED]") if has_methods
        result["accounts"] = JSON::Any.new("[REDACTED]") if has_accounts
        if has_methods || has_accounts
          parsed["result"] = JSON::Any.new(result)
          return parsed.to_json
        end
      end

      line
    rescue
      "[REDACTED frame]"
    end

    # Read bytes up to (and including) the next '\n' from `@reader` to
    # re-sync after an oversized line. Returns the number of bytes
    # discarded. A nil return from `gets` (EOF) ends the drain.
    private def drain_oversize_line : Int64
      drained = 0_i64
      while chunk = @reader.gets(@max_line_bytes, chomp: false)
        drained += chunk.bytesize
        break if chunk.ends_with?('\n')
      end
      drained
    end

    # Answers an unparseable line with JSON-RPC -32700 and `"id": null`
    # (JSON-RPC 2.0 §5: the id MUST be null when a parse error kept it from
    # being detected), so a peer whose request was garbled gets an answer
    # instead of waiting forever. The raw line is not echoed back.
    #
    # Written from its own fiber so a peer that isn't draining its stdin can
    # never stall the reader; while one answer is still being written,
    # further unparseable lines are not answered.
    private def send_parse_error : Nil
      return unless @parse_error_pending.compare_and_set(false, true)[1]

      spawn(name: "acp-transport-parse-error") do
        send(Protocol.build_error_response(nil, JsonRpcError::PARSE_ERROR, "Parse error"))
      rescue ex : TransportError
        Log.debug { "Could not send parse error: #{ex.message}" }
      ensure
        @parse_error_pending.set(false)
      end
    end

    private def start_reader
      @reader_fiber = spawn(name: "acp-transport-reader") do
        read_loop
      end
    end

    # The main read loop running in a background fiber. Reads lines
    # from the reader IO, parses them as JSON, and pushes them into
    # the incoming channel. Sends a nil sentinel on EOF or error.
    private def read_loop
      loop do
        break if @closed

        begin
          # Read up to ONE byte past the limit, without chomping, so we can
          # distinguish a complete line from a truncated (oversize) one. A
          # complete line ends with '\n' (or is a final, unterminated line that
          # fit within the limit); an oversize line fills `@max_line_bytes + 1`
          # bytes with no terminating newline.
          raw = @reader.gets(@max_line_bytes + 1, chomp: false)
        rescue ex : IO::Error
          # A read error during/after an intentional close is expected — the
          # reader IO was closed underneath us — so don't surface it as an
          # error on a clean shutdown.
          Log.error { "Read error: #{ex.message}" } unless @closed
          break
        end

        # nil from gets means EOF — the agent process closed its stdout.
        if raw.nil?
          Log.debug { "Reader reached EOF" }
          break
        end

        # We read past the limit and still found no newline: this is an
        # oversize line. Drain the rest of the offending logical line and skip
        # it so we re-sync at the next message boundary.
        #
        # A line whose content is exactly `@max_line_bytes` long is
        # `@max_line_bytes + 1` bytes INCLUDING its trailing '\n', so it ends
        # with '\n' here and is correctly treated as a valid, complete line
        # rather than being misclassified as oversize and dropped.
        if raw.bytesize > @max_line_bytes && !raw.ends_with?('\n')
          if @exact_frames
            Log.warn { "Closing relay after oversized incoming ACP frame" }
            break
          end
          drained = drain_oversize_line
          Log.warn { "Dropped oversized incoming line (> #{@max_line_bytes} bytes; drained #{drained} more bytes to re-sync)" }
          next
        end

        line = raw.chomp.strip
        next if line.empty?

        begin
          parsed = @exact_frames ? Protocol::WireFrame.new(line, exact_params: true) : decode_frame(line)
          Log.debug { "<<< #{redact_raw_frame(line, parsed)}" }
          @incoming.send(parsed)
        rescue JSON::Error
          Log.warn { "Failed to parse incoming JSON" }
          # Don't log the raw line at any level — it may be a partially
          # received frame that contains sensitive data.
          send_parse_error
          next
        rescue Channel::ClosedError
          # Channel was closed (transport shutting down).
          break
        end
      end
    ensure
      @provider_log_mutex.synchronize { @provider_request_id_hashes.try(&.clear) }
      # Signal that the reader has stopped, even after a decoding error.
      unless @close_sent
        @close_sent = true
        begin
          @incoming.send(nil)
        rescue Channel::ClosedError
          # Already closed, fine.
        end
      end
    end

    private def decode_frame(line : String) : IncomingFrame
      value = JSON.parse(line)
      envelope = value.as_h?
      method = envelope.try(&.["method"]?).try(&.as_s?)
      update = envelope.try(&.["params"]?).try(&.as_h?).try(&.["update"]?).try(&.as_h?) if method == Protocol::AgentMethod::SESSION_UPDATE
      exact_params = method == Protocol::ClientMethod::MCP_MESSAGE ||
                     (update.try(&.["sessionUpdate"]?) || update.try(&.["type"]?)).try(&.as_s?).in?("config_option_update", "config_options_update")
      config_result = envelope.try(&.["result"]?).try(&.as_h?).try(&.has_key?("configOptions"))
      if exact_params || config_result
        Protocol::WireFrame.new(line, exact_params: true)
      else
        value
      end
    rescue JSON::ParseException
      Protocol::WireFrame.new(line)
    end
  end

  # ─── Process Transport ──────────────────────────────────────────

  # A convenience wrapper that spawns an agent process and creates
  # a `StdioTransport` connected to its stdin/stdout. The agent's
  # stderr is forwarded to a configurable IO (default: STDERR).
  class ProcessTransport < StdioTransport
    # The underlying child process.
    getter process : Process

    # Flag to prevent duplicate close/terminate sequences.
    @process_closing : Bool = false

    # Memoized exit status, so the process is reaped exactly once no matter
    # how many callers (or the internal reaper fiber) ask for it.
    @exit_status : Process::Status? = nil

    # Guards the single reap of the child process.
    @wait_mutex : Mutex = Mutex.new

    @agent_command : String
    @agent_args : Array(String)
    @agent_env : Process::Env
    @agent_directory : String
    @agent_stderr : IO
    @agent_buffer_size : Int32?

    # Spawns an agent process with the given command and arguments,
    # and sets up the stdio transport.
    #
    # - `command` — the agent executable (e.g., "claude-agent").
    # - `args` — command-line arguments for the agent.
    # - `env` — optional environment variables.
    # - `chdir` — optional working directory for the process.
    # - `stderr` — where to send the agent's stderr (default: STDERR).
    # - `buffer_size` — channel buffer size. Defaults to 256 in ordinary
    #   mode and 4 in exact mode.
    # - `max_line_bytes` — abort and log a warning if a single incoming
    #   line exceeds this many bytes. Default 16 MiB.
    # - `exact_frames` — retain every frame as exact JSON and apply the line
    #   limit in both directions for a relay.
    #
    # Raises `TransportError` if the process cannot be started.
    def initialize(
      command : String,
      args : Array(String) = [] of String,
      env : Process::Env = nil,
      chdir : String? = nil,
      stderr : IO = STDERR,
      buffer_size : Int32? = nil,
      max_line_bytes : Int32 = DEFAULT_MAX_LINE_BYTES,
      *,
      exact_frames : Bool = false,
    )
      @agent_command = command
      @agent_args = args.dup
      @agent_env = env.try(&.dup)
      @agent_directory = if chdir
                           Path[chdir].absolute? ? chdir : File.join(Dir.current, chdir)
                         else
                           Dir.current
                         end
      @agent_stderr = stderr
      @agent_buffer_size = buffer_size
      @process = begin
        Process.new(
          command,
          args: args,
          env: env,
          chdir: chdir,
          input: Process::Redirect::Pipe,
          output: Process::Redirect::Pipe,
          error: stderr
        )
      rescue ex
        # A missing or non-executable command or a bad `chdir` raises
        # `File::Error`, a NUL byte in an argument `ArgumentError`; keep the
        # library's contract of raising `ACP::Error`.
        raise TransportError.new("Failed to start agent: #{ex.message}", ex)
      end

      super(@process.output, @process.input, buffer_size, max_line_bytes, exact_frames: exact_frames)
    end

    # Runs the configured Agent in a terminal with the approved login additions.
    # Use when the configured invocation accepts arguments directly.
    def run_terminal_authentication(method : Protocol::TerminalAuthMethod) : Process::Status
      env = {} of String => String?
      @agent_env.try &.each { |key, value| env[key] = value }
      method.env.each { |key, value| env[key] = value }

      Process.run(
        @agent_command,
        @agent_args + method.args,
        env: env,
        chdir: @agent_directory,
        input: Process::Redirect::Inherit,
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit,
      )
    rescue ex : File::Error | IO::Error | ArgumentError
      raise TransportError.new("Failed to start terminal authentication: #{ex.message}", ex)
    end

    # Starts another ACP connection using the original process configuration.
    def reconnect : ProcessTransport
      ProcessTransport.new(@agent_command, @agent_args, @agent_env, @agent_directory,
        @agent_stderr, @agent_buffer_size, @max_line_bytes, exact_frames: @exact_frames)
    end

    # Closes the transport and terminates the agent process if it's
    # still running.
    def close : Nil
      return if @process_closing
      @process_closing = true
      super

      if @process.terminated?
        # Reap the already-terminated process to avoid zombies.
        wait rescue nil
      else
        # Give the process a moment to exit gracefully, then signal it.
        @process.terminate(graceful: true)

        # Wait briefly for graceful shutdown, then force-kill if needed.
        spawn do
          sleep 2.seconds
          begin
            unless @process.terminated?
              @process.terminate(graceful: false)
            end
          rescue
            # Process may have already exited.
          end
          # Reap the process to avoid zombies.
          wait rescue nil
        end
      end
    end

    # Waits for the agent process to exit and returns its status.
    #
    # Safe to call any number of times, from any fiber, and after `close`:
    # the child is reaped exactly once and every caller gets the same status.
    # `Process#wait` itself is single-shot — a second call raises
    # `Channel::ClosedError` — and `close` spawns a reaper fiber that also
    # waits, so calling this without the memo would raise or not depending on
    # which fiber won the race.
    def wait : Process::Status
      @wait_mutex.synchronize do
        if status = @exit_status
          return status
        end

        status = begin
          @process.wait
        rescue ex : Channel::ClosedError
          # Something outside this class already reaped the process; we have
          # no status to report.
          raise TransportError.new("Agent process was already reaped: #{ex.message}")
        end

        @exit_status = status
        status
      end
    end

    # Returns the agent process's exit status if it has already been reaped,
    # or nil if it is still running (or has not been waited on yet). Never
    # blocks — use `wait` when you want to block until the process exits.
    def exit_status : Process::Status?
      @exit_status
    end

    # Returns true if the agent process has terminated.
    def terminated? : Bool
      @process.terminated?
    end
  end
end
