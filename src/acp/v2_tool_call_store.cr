require "./protocol/v2/updates"

module ACP
  module V2
    # A detached view of the reported ACP v2 tool call, including during replay.
    record ToolCallSnapshot,
      session_id : String,
      tool_call_id : String,
      name : String?,
      title : String?,
      kind : String,
      status : String,
      content : Array(Protocol::V2::ToolCallContent),
      locations : Array(Protocol::ToolCallLocation),
      raw_input : Protocol::RawJson?,
      raw_output : Protocol::RawJson?,
      capabilities : Protocol::V2::EntityCapabilities?,
      meta_raw : Protocol::RawJson?

    # Retains ACP v2 tool-call state from session updates in receive order.
    class ToolCallStore
      private alias Wire = Protocol::V2

      # Default number of calls retained across sessions in a store.
      DEFAULT_CALL_LIMIT = 128

      # Default serialized byte budget for a retained call.
      DEFAULT_CALL_BYTE_LIMIT = 1024 * 1024

      private class Entry
        @fields : Wire::ToolCallUpdate
        @content = [] of Protocol::RawJson
        @content_bytes = 0_i64
        @field_bytes : Int64
        @raw_input : Protocol::RawJson?
        @raw_output : Protocol::RawJson?
        @meta_raw : Protocol::RawJson?

        def initialize(@session_id : String, @tool_call_id : String, @byte_limit : Int32?)
          @fields = Wire::ToolCallUpdate.new(@tool_call_id)
          @field_bytes = @session_id.bytesize.to_i64 + Protocol::WireFrame.encode(@fields).bytesize
        end

        def apply(patch : Wire::ToolCallUpdate) : Bool
          fields = @fields
          fields.name = patch.name if patch.name_present?
          fields.title = patch.title if patch.title_present?
          fields.kind = patch.kind if patch.kind_present?
          fields.status = patch.status if patch.status_present?
          fields.locations = patch.locations if patch.locations_present?
          fields.capabilities = patch.capabilities if patch.capabilities_present?
          raw_input = patch.raw_input_present? ? patch.raw_input_raw : @raw_input
          raw_output = patch.raw_output_present? ? patch.raw_output_raw : @raw_output
          metadata = patch.apply_metadata_raw(@meta_raw)

          content = @content
          content_bytes = @content_bytes
          if patch.content_present?
            content = patch.content.try(&.map { |item| encode_content(item) }) || [] of Protocol::RawJson
            content_bytes = content.sum(0_i64) { |item| item.json.bytesize.to_i64 + 1 }
          end

          field_bytes = @session_id.bytesize.to_i64 + Protocol::WireFrame.encode(fields).bytesize +
                        payload_bytes(raw_input) + payload_bytes(raw_output) + payload_bytes(metadata)
          return false if (limit = @byte_limit) && field_bytes + content_bytes > limit

          @fields = fields
          @field_bytes = field_bytes
          @content = content
          @content_bytes = content_bytes
          @raw_input = raw_input
          @raw_output = raw_output
          @meta_raw = metadata
          true
        end

        def apply(chunk : Wire::ToolCallContentChunk) : Bool
          item = encode_content(chunk.content)
          content_bytes = @content_bytes + item.json.bytesize.to_i64 + 1
          return false if (limit = @byte_limit) && @field_bytes + content_bytes > limit

          @content << item
          @content_bytes = content_bytes
          true
        end

        def snapshot : ToolCallSnapshot
          # Detach the typed fields and each content item's editable metadata views.
          fields = Wire::ToolCallUpdate.from_json(Protocol::WireFrame.encode(@fields))
          content = @content.map { |item| Wire::ToolCallContent.from_json(item.json) }
          ToolCallSnapshot.new(@session_id, @tool_call_id, fields.name, fields.title,
            fields.kind || "other", fields.status || "pending", content,
            fields.locations || [] of Protocol::ToolCallLocation, @raw_input, @raw_output,
            fields.capabilities, @meta_raw)
        end

        private def encode_content(item : Wire::ToolCallContent) : Protocol::RawJson
          Protocol::RawJson.from_json(Protocol::WireFrame.encode(item))
        end

        private def payload_bytes(payload : Protocol::RawJson?) : Int64
          payload.try(&.json.bytesize.to_i64) || 0_i64
        end
      end

      @calls = {} of {String, String} => Entry
      @mutex = Mutex.new

      # Creates a store with configurable count and byte limits. Nil removes that limit.
      def initialize(*, @call_limit : Int32? = DEFAULT_CALL_LIMIT, @call_byte_limit : Int32? = DEFAULT_CALL_BYTE_LIMIT)
        if (limit = @call_limit) && limit <= 0
          raise ArgumentError.new("Tool-call limit must be positive")
        end
        if (limit = @call_byte_limit) && limit <= 0
          raise ArgumentError.new("Tool-call byte limit must be positive")
        end
      end

      # Applies a tool-call patch or content chunk, including tool-call patches from permission requests.
      # Returns false for unrelated, unusable, or over-limit updates.
      def observe(params : Wire::SessionUpdateParams) : Bool
        payload = params.update
        return false unless payload.session_update.in?("tool_call_update", "tool_call_content_chunk")
        if payload.session_update == "tool_call_update" && Wire::ToolCallUpdate::WIRE_FIELDS.any? { |key| payload.repeated_field?(key) }
          return false
        end

        case update = payload.typed
        when Wire::ToolCallUpdate, Wire::ToolCallContentChunk
          @mutex.synchronize do
            key = {params.session_id, update.tool_call_id}
            if entry = @calls[key]?
              entry.apply(update)
            elsif (limit = @call_limit) && @calls.size >= limit
              false
            else
              entry = Entry.new(params.session_id, update.tool_call_id, @call_byte_limit)
              return false unless entry.apply(update)

              @calls[key] = entry
              true
            end
          end
        else
          false
        end
      end

      # Returns the current tool-call state for this session and ID, if seen.
      def tool_call(session_id : String, tool_call_id : String) : ToolCallSnapshot?
        @mutex.synchronize do
          @calls[{session_id, tool_call_id}]?.try(&.snapshot)
        end
      end

      # Drops the tool-call history for one session.
      def forget_session(session_id : String) : Bool
        @mutex.synchronize do
          before = @calls.size
          @calls.reject! { |key, _| key[0] == session_id }
          @calls.size < before
        end
      end
    end
  end
end
