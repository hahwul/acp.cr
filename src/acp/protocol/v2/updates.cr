require "./initialization"

module ACP
  module Protocol
    module V2
      # Identifies work that can continue independently of the foreground.
      struct BackgroundWork
        include JSON::Serializable
        include JSON::Serializable::Unmapped

        # Entity discriminator, e.g. terminal, tool_call, or subagent.
        @[JSON::Field(key: "type")]
        getter entity_type : String

        # Creates a background item with its variant-specific fields.
        def initialize(@entity_type : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
        end

        # ID of the reported entity for a recognized kind of background work.
        def entity_id : String?
          key = case @entity_type
                when "terminal"  then "terminalId"
                when "tool_call" then "toolCallId"
                when "subagent"  then "sessionId"
                else                  return
                end
          @json_unmapped[key]?.try(&.as_s?)
        end
      end

      # Foreground and background state snapshot for a session. Variant fields
      # are retained for forward compatibility.
      struct StateUpdate
        include JSON::Serializable
        include JSON::Serializable::Unmapped

        # Discriminator for this session update.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "state_update"

        # Foreground state, e.g. running, requires_action, idle, or unknown.
        getter state : String

        # Creates a snapshot with fields specific to its state.
        def initialize(@state : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
        end

        # Whether the Agent reports an idle foreground state.
        def idle? : Bool
          @state == "idle"
        end

        # Agent-provided explanation for an idle snapshot, including future reasons.
        def stop_reason : String?
          @json_unmapped["stopReason"]?.try(&.as_s?) if idle?
        end

        # JSON-RPC error details for a failed foreground operation.
        def error : Protocol::JsonRpcErrorObject?
          return unless stop_reason == "error" && (raw = @json_unmapped["error"]?)

          Protocol::JsonRpcErrorObject.from_json(raw.to_json)
        rescue JSON::ParseException
          nil
        end

        # Complete reported background list, or nil when unreported.
        def background : Array(BackgroundWork)?
          @json_unmapped["background"]?.try(&.as_a?).try &.map { |item| BackgroundWork.from_json(item.to_json) }
        rescue JSON::ParseException
          nil
        end

        # Extension metadata for this snapshot.
        def meta : Hash(String, JSON::Any)?
          @json_unmapped["_meta"]?.try(&.as_h?)
        end
      end

      # Upserts a complete user message, Agent message, or Agent thought.
      struct MessageUpdate
        include JSON::Serializable

        # Discriminator for this message's role.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String

        # ID of the message in this transcript.
        @[JSON::Field(key: "messageId")]
        getter message_id : String

        # Replacement content blocks when present.
        @[JSON::Field(presence: true)]
        getter content : Array(JSON::Any)?

        # Whether this update includes replacement content or a clear.
        @[JSON::Field(ignore: true)]
        getter? content_present : Bool = false

        # Top-level metadata patch.
        @[JSON::Field(key: "_meta", presence: true)]
        getter meta : Hash(String, JSON::Any)?

        # Whether this update includes a metadata patch or a clear.
        @[JSON::Field(ignore: true)]
        getter? meta_present : Bool = false

        # Creates a message upsert. Assign nil explicitly to clear a field.
        def initialize(@session_update : String, @message_id : String)
        end

        # Sets replacement content, with nil clearing the message.
        def content=(@content : Array(JSON::Any)?) : Array(JSON::Any)?
          @content_present = true
          @content
        end

        # Sets the metadata patch, with nil clearing all metadata.
        def meta=(@meta : Hash(String, JSON::Any)?) : Hash(String, JSON::Any)?
          @meta_present = true
          @meta
        end

        # Applies this update's top-level metadata patch to a previous snapshot.
        def apply_metadata(previous : Hash(String, JSON::Any)?) : Hash(String, JSON::Any)?
          return previous.try(&.dup) unless @meta_present
          return unless patch = @meta

          result = previous.try(&.dup) || {} of String => JSON::Any
          patch.each do |key, value|
            if value.raw.nil?
              result.delete(key)
            else
              result[key] = value
            end
          end
          result
        end

        protected def on_to_json(json : ::JSON::Builder)
          json.field("content", nil) if @content_present && @content.nil?
          json.field("_meta", nil) if @meta_present && @meta.nil?
        end
      end

      # Appends a content block to a transcript message.
      struct MessageChunkUpdate
        include JSON::Serializable

        # Discriminator for this message's role.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String

        # ID of the message in this transcript.
        @[JSON::Field(key: "messageId")]
        getter message_id : String

        # One content block, including future variants.
        property content : JSON::Any

        # Extension metadata scoped to the chunk.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates a message chunk.
        def initialize(@session_update : String, @message_id : String, @content : JSON::Any, @meta : Hash(String, JSON::Any)? = nil)
        end

        # Converts a known content block to a typed chunk with its message ID.
        def to_content_chunk : Protocol::ContentChunk?
          block = Protocol::ContentBlock.from_json(@content.to_json)
          Protocol::ContentChunk.new(block, @meta, @message_id)
        rescue JSON::ParseException
          nil
        end
      end

      # Agent notification marking the end of a requested history replay.
      struct ReplayCompleteUpdate
        include JSON::Serializable

        # Discriminator for this session update.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "replay_complete"

        # Extension metadata.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates a replay completion update.
        def initialize(@meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # An open v2 session update. The raw payload remains available for
      # unknown variants and for fields beyond the typed projection.
      struct SessionUpdate
        include JSON::Serializable
        include JSON::Serializable::Unmapped

        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String

        # Creates an update with its variant payload.
        def initialize(@session_update : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
        end

        # Returns the typed form of a recognized lifecycle update.
        def typed : StateUpdate | MessageUpdate | MessageChunkUpdate | ReplayCompleteUpdate | Nil
          case @session_update
          when "state_update"
            StateUpdate.from_json(to_json)
          when "user_message", "agent_message", "agent_thought"
            MessageUpdate.from_json(to_json)
          when "user_message_chunk", "agent_message_chunk", "agent_thought_chunk"
            MessageChunkUpdate.from_json(to_json)
          when "replay_complete"
            ReplayCompleteUpdate.from_json(to_json)
          end
        rescue JSON::ParseException
          nil
        end
      end

      # Parameters of a v2 session/update notification.
      struct SessionUpdateParams
        include JSON::Serializable

        # Session whose state or transcript changed.
        @[JSON::Field(key: "sessionId")]
        property session_id : String

        # Open update payload.
        property update : SessionUpdate

        # Extension metadata scoped to the notification.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates a notification payload.
        def initialize(@session_id : String, @update : SessionUpdate, @meta : Hash(String, JSON::Any)? = nil)
        end
      end
    end
  end
end
