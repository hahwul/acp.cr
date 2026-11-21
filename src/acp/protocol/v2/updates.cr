require "./initialization"
require "../raw_json"
require "../usage"
require "../cursor_update"
require "./configuration"
require "./session_updates"
require "./tool_updates"

module ACP
  module Protocol
    module V2
      # Draft token usage for the foreground work that just completed.
      alias Usage = Protocol::Usage

      # Announces or patches a position in a session's transcript.
      alias CursorUpdate = Protocol::CursorUpdate

      # A position relative to a transcript entity.
      alias CursorAnchor = Protocol::CursorAnchor

      # The methods currently available at a transcript position.
      alias CursorCapabilities = Protocol::CursorCapabilities

      # Marker for forking at a transcript position.
      alias CursorForkCapabilities = Protocol::CursorForkCapabilities

      # Identifies work that can continue independently of the foreground.
      struct BackgroundWork
        include JSON::Serializable
        include LosslessUnmapped

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
      abstract struct SessionState
        include JSON::Serializable
        include LosslessUnmapped

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

        # Token usage on an idle snapshot, when reported. A repeated or replayed
        # snapshot may carry the same usage.
        def usage : Usage?
          return unless idle?

          json = field_json("usage")
          Usage::Optional.from_json(json) if json
        end

        # JSON-RPC error details for a failed foreground operation.
        def error : Protocol::JsonRpcErrorObject?
          return unless stop_reason == "error" && (json = field_json("error"))

          Protocol::JsonRpcErrorObject.from_json(json)
        rescue JSON::Error
          # A valid error can carry data that is too wide for the typed view.
          return unless json

          object = RawJson.new(JSON::PullParser.new(json))
          code = object.field("code").try(&.as_i64?)
          message = object.field("message").try(&.as_s?)
          if code && message && (Int32::MIN..Int32::MAX).includes?(code)
            Protocol::JsonRpcErrorObject.new(code.to_i32, message)
          end
        end

        # Complete reported background list, or nil when unreported.
        def background : Array(BackgroundWork)?
          return unless (json = field_json("background")) && (entries = RawJson.new(JSON::PullParser.new(json)).elements?)

          entries.map do |raw|
            item = BackgroundWork.from_json(raw.json)
            return if item.entity_type.in?("terminal", "tool_call", "subagent") && item.entity_id.nil?

            item
          end
        rescue JSON::Error
          nil
        end

        # Extension metadata for this snapshot.
        def meta : Hash(String, JSON::Any)?
          @json_unmapped["_meta"]?.try(&.as_h?)
        end

        private def field_json(name : String) : String?
          raw_field(name) || @json_unmapped[name]?.try { |value| WireFrame.encode(value) }
        end
      end

      # A state snapshot embedded in a session announcement or response.
      struct StateSnapshot < SessionState
      end

      # Standalone notification carrying a foreground and background snapshot.
      struct StateUpdate < SessionState
        # Discriminator for this session update.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "state_update"
      end

      # Announces or patches a child session on its parent session's timeline.
      struct SubagentUpdate
        include JSON::Serializable

        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "subagent_update"

        # ID of the child. The enclosing update identifies its parent.
        @[JSON::Field(key: "sessionId")]
        getter session_id : String

        # A cleared state removes the report. Cleared directories inherit the parent's values.
        PatchFields.define({
          title:                  {String, "title"},
          description:            {String, "description"},
          capabilities:           {EntityCapabilities, "capabilities"},
          state:                  {StateSnapshot, "state"},
          cwd:                    {String, "cwd"},
          additional_directories: {Array(String), "additionalDirectories"},
        })
        include LosslessMetadataPatch

        # Creates an update for the specified child. Set only the patched fields.
        def initialize(@session_id : String)
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

        include MessageContentPatch
        include LosslessMetadataPatch

        # Creates a message upsert. Assign nil explicitly to clear a field.
        def initialize(@session_update : String, @message_id : String)
        end

        # Returns well-formed skill references in a user message in content order.
        def skill_references : Array(SkillReference)
          return [] of SkillReference unless @session_update == "user_message"

          content_raw.try(&.elements?).try(&.compact_map { |block| SkillReference.from_content_block(block) }) || [] of SkillReference
        end
      end

      # Appends a content block to a transcript message.
      struct MessageChunkUpdate
        include JSON::Serializable
        include LosslessMetadata
        include LosslessContentField

        # Discriminator for this message's role.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String

        # ID of the message in this transcript.
        @[JSON::Field(key: "messageId")]
        getter message_id : String

        # Creates a message chunk.
        def initialize(@session_update : String, @message_id : String, content : JSON::Any, meta : Hash(String, JSON::Any)? = nil)
          @content_wire = PreservedJson.new(content)
          self.meta = meta
        end

        # Converts display content to a typed chunk with its message ID.
        def to_content_chunk : Protocol::ContentChunk?
          block = Protocol::ContentBlock.from_v2_json(content_raw)
          Protocol::ContentChunk.new(block, meta_raw: meta_raw, message_id: @message_id)
        rescue JSON::Error
          nil
        end

        # Returns the skill reference in a user message chunk, if present.
        def skill_reference : SkillReference?
          SkillReference.from_content_block(content_raw) if @session_update == "user_message_chunk"
        end
      end

      # Agent notification marking the end of a requested history replay.
      struct ReplayCompleteUpdate
        include JSON::Serializable
        include LosslessMetadata

        # Discriminator for this session update.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "replay_complete"

        # Creates a replay completion update.
        def initialize(meta : Hash(String, JSON::Any)? = nil)
          self.meta = meta
        end
      end

      # A v2 candidate with the original prompt blocks, including extra fields.
      alias PromptSuggestion = Protocol::PromptSuggestionOf(JSON::Any)

      # Replaces the suggestions for the next user prompt.
      struct PromptSuggestionsUpdate
        include JSON::Serializable

        # Discriminator for this session update.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "prompt_suggestions_update"

        # Suggestions in Agent priority order. An empty list withdraws them.
        @[JSON::Field(converter: ::ACP::Protocol::PromptSuggestionList(::ACP::Protocol::V2::PromptSuggestion))]
        getter suggestions : Array(PromptSuggestion)

        # Extension metadata scoped to the replacement.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        getter meta : Hash(String, JSON::Any)?

        # Creates a replacement list for a v2 session.
        def initialize(@suggestions : Array(PromptSuggestion), @meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # An open v2 session update. The raw payload remains available for
      # unknown variants and for fields beyond the typed projection.
      struct SessionUpdate
        include JSON::Serializable
        include LosslessUnmapped

        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String

        # Creates an update with its variant payload.
        def initialize(@session_update : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
        end

        protected def keep_exact_unmapped?(_key : String) : Bool
          true
        end

        # Filters prompt suggestions while keeping the original JSON of the usable entries.
        # :nodoc:
        def filter_prompt_suggestions(types : Set(String)) : JSON::Any?
          return unless raw = exact_unmapped_json("suggestions")
          pull = JSON::PullParser.new(raw)
          return unless pull.kind.begin_array?

          suggestions = [] of PromptSuggestion
          filtered = JSON.build do |builder|
            builder.array do
              pull.read_array do
                candidate = WireFrame.read_raw(pull)
                # Duplicate members can change the meaning for a downstream parser.
                suggestion = Protocol::PromptSuggestionList(PromptSuggestion).decode_usable(candidate, unique_members: true)
                if suggestion && suggestion.allowed?(types)
                  suggestions << suggestion
                  builder.raw(candidate)
                end
              end
            end
          end
          projection = JSON.parse(WireFrame.encode(suggestions))
          retain_unmapped_json("suggestions", filtered, projection: projection)
          projection
        end

        # Returns the typed form of a recognized session update.
        def typed
          case @session_update
          when "state_update"
            StateUpdate.from_json(WireFrame.encode(self))
          when "user_message", "agent_message", "agent_thought"
            MessageUpdate.from_json(WireFrame.encode(self))
          when "user_message_chunk", "agent_message_chunk", "agent_thought_chunk", "session_message_chunk"
            MessageChunkUpdate.from_json(WireFrame.encode(self))
          when "replay_complete"
            ReplayCompleteUpdate.from_json(WireFrame.encode(self))
          when "cursor_update"
            CursorUpdate.from_json(WireFrame.encode(self))
          when "tool_call_update"
            ToolCallUpdate.from_json(WireFrame.encode(self))
          when "tool_call_content_chunk"
            ToolCallContentChunk.from_json(WireFrame.encode(self))
          when "terminal_update"
            TerminalUpdate.from_json(WireFrame.encode(self))
          when "terminal_output_chunk"
            TerminalOutputChunk.from_json(WireFrame.encode(self))
          when "subagent_update"
            SubagentUpdate.from_json(WireFrame.encode(self))
          when "session_message"
            SessionMessageUpdate.from_json(WireFrame.encode(self))
          when "session_info_update"
            SessionInfoUpdate.from_json(WireFrame.encode(self))
          when "usage_update"
            UsageUpdate.from_json(WireFrame.encode(self))
          when "compaction_update"
            CompactionUpdate.from_json(WireFrame.encode(self))
          when "compaction_summary_chunk"
            Protocol::CompactionSummaryChunkUpdate.from_v2_json(WireFrame.encode(self))
          when "plan_update"
            PlanUpdate.from_json(WireFrame.encode(self))
          when "plan_removed"
            Protocol::PlanRemovedUpdate.from_json(WireFrame.encode(self))
          when "notice"
            Protocol::NoticeUpdate.from_json(WireFrame.encode(self))
          when "available_commands_update"
            AvailableCommandsUpdate.from_json(WireFrame.encode(self))
          when "config_option_update"
            ConfigOptionUpdate.from_json(to_json)
          when "prompt_suggestions_update"
            PromptSuggestionsUpdate.from_json(WireFrame.encode(self))
          end
        rescue JSON::ParseException
          nil
        end
      end

      # Parameters of a v2 session/update notification.
      struct SessionUpdateParams
        include JSON::Serializable
        include LosslessUnmapped
        include LosslessMetadata

        # Session whose state or transcript changed.
        @[JSON::Field(key: "sessionId")]
        property session_id : String

        # Open update payload.
        property update : SessionUpdate

        # Creates a notification payload.
        def initialize(@session_id : String, @update : SessionUpdate, meta : Hash(String, JSON::Any)? = nil)
          self.meta = meta
        end

        # The delivered notification params, including extension fields and exact JSON numbers.
        def raw : RawJson
          RawJson.new(JSON::PullParser.new(WireFrame.encode(self)))
        end

        protected def keep_exact_unmapped?(_key : String) : Bool
          true
        end
      end
    end
  end
end
