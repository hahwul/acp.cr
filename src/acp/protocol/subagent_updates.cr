require "json"
require "./capabilities"
require "./content_block"
require "./metadata_patch"
require "./patch_fields"
require "./raw_json"

module ACP
  module Protocol
    # :nodoc:
    module StateFields
      MEMBERS = {"state", "background", "stopReason", "usage", "error", "_meta"}

      def self.reported_state?(wire : RawJson) : Bool
        wire.object? && WireFrame.repeated_members(wire.json, "state").empty? && !!wire.field("state").try(&.as_s?)
      end

      def self.normalize_patch(wire : RawJson) : RawJson
        return wire unless state = wire.field("state")

        if WireFrame.repeated_members(wire.json, "state").empty? && (state.null? || reported_state?(state))
          wire
        else
          wire.without_field("state")
        end
      end

      def self.parser(pull : JSON::PullParser) : JSON::PullParser
        location = pull.location
        wire = RawJson.new(pull)
        repeated = WireFrame.repeated_members(wire.json, *MEMBERS)
        if repeated.includes?("state")
          raise JSON::ParseException.new("Ambiguous ACP foreground state", *location)
        end
        repeated.each { |field| wire = wire.without_field(field) }
        JSON::PullParser.new(wire.json)
      end
    end

    # A foreground state snapshot reported by the agent for a child session.
    # The state and stop reason are open strings. Extra fields are preserved
    # in `json_unmapped` so applications can display future state variants.
    struct SubagentState
      include JSON::Serializable
      include LosslessOpenObject

      # Current foreground state, e.g. running, requires_action, idle or unknown.
      getter state : String

      # Builds a foreground state snapshot with optional extra wire fields.
      def initialize(@state : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
      end

      # Reads unambiguous foreground state.
      def self.new(pull : JSON::PullParser) : self
        previous_def(StateFields.parser(pull))
      end

      # Copies the representable attributes while preserving exact wire fields.
      def dup : SubagentState
        copy = self
        copy.json_unmapped = @json_unmapped.dup
        copy
      end

      # Reported reason why foreground work stopped.
      def stop_reason : String?
        @json_unmapped["stopReason"]?.try(&.as_s?)
      end

      # Reported JSON-RPC error payload for the error stop reason.
      def error : JSON::Any?
        @json_unmapped["error"]?.try { |value| value unless value.raw.nil? }
      end
    end

    # Announces or patches a child session of the enclosing session.
    # See: https://agentclientprotocol.com/protocol/v1/subagents
    struct SubagentUpdate < SessionUpdate
      # ID of the child. The enclosing update's session ID identifies its parent.
      @[JSON::Field(key: "sessionId")]
      getter session_id : String

      # Optional fields are patches. A cleared directory inherits its parent's
      # value. An empty additional directory list replaces the parent's list.
      PatchFields.define({
        title:                  {String, "title"},
        description:            {String, "description"},
        capabilities:           {SubagentSessionCapabilities, "capabilities"},
        state:                  {SubagentState, "state"},
        cwd:                    {String, "cwd"},
        additional_directories: {Array(String), "additionalDirectories"},
      })
      include LosslessMetadataPatch

      # Builds an announcement. Assign only the fields this update should patch.
      def initialize(@session_id : String)
        @session_update = "subagent_update"
      end
    end

    # :nodoc:
    module OptionalSessionMessageContent
      def self.from_json(pull : JSON::PullParser) : Array(ContentBlock)?
        had_items = false
        blocks = OptionalContentList(ContentBlock).from_json(pull) do |item|
          had_items = true
          OptionalContentValue(ContentBlock).from_json(item)
        end
        # Only an explicitly empty list should clear the stored content.
        blocks unless had_items && blocks.try(&.empty?)
      end
    end

    # Creates or patches a view of an inter-session message in a transcript.
    # See: https://agentclientprotocol.com/protocol/v1/prompt-turn#session-directed-messages
    struct SessionMessageUpdate < SessionUpdate
      # ID of the message in the enclosing session's transcript.
      @[JSON::Field(key: "messageId")]
      getter message_id : String

      # Only present fields replace stored values. A null or empty content
      # list clears the message. Linked IDs refer to views in other transcripts.
      PatchFields.tolerant({
        sender_session_id:    {String, "senderSessionId", OptionalCapabilityString},
        recipient_session_id: {String, "recipientSessionId", OptionalCapabilityString},
        sender_message_id:    {String, "senderMessageId", OptionalCapabilityString},
        recipient_message_id: {String, "recipientMessageId", OptionalCapabilityString},
        content:              {Array(ContentBlock), "content", OptionalSessionMessageContent},
      })
      include LosslessMetadataField

      # Builds a message update. Assign only the fields it should patch.
      def initialize(@message_id : String)
        @session_update = "session_message"
      end

      # Reads an unambiguous message ID and omits conflicting optional updates.
      def self.new(pull : JSON::PullParser) : self
        previous_def(RawJson.patch_parser(pull, required: {"sessionUpdate", "messageId"},
          optional: {"senderSessionId", "recipientSessionId", "senderMessageId", "recipientMessageId", "content", "_meta"}))
      end

      def_equals_and_hash @session_update, @message_id, sender_session_id, sender_session_id_present?,
        recipient_session_id, recipient_session_id_present?, sender_message_id, sender_message_id_present?,
        recipient_message_id, recipient_message_id_present?, content, content_present?, metadata_comparison, meta_present?
    end

    # Appends a content block to an inter-session message in a transcript.
    struct SessionMessageChunkUpdate < SessionUpdate
      include LosslessMetadata

      # ID of the message in the enclosing session's transcript.
      @[JSON::Field(key: "messageId")]
      getter message_id : String

      # A single content block to append.
      property content : ContentBlock

      # Builds a content chunk for the message.
      def initialize(@message_id : String, @content : ContentBlock, meta : Hash(String, JSON::Any)? = nil)
        @session_update = "session_message_chunk"
        self.meta = meta
      end

      # Reads one unambiguous content block and its optional metadata.
      def self.new(pull : JSON::PullParser) : self
        previous_def(RawJson.patch_parser(pull, required: {"sessionUpdate", "messageId", "content"}, optional: {"_meta"}))
      end

      def_equals_and_hash @session_update, @message_id, @content, metadata_comparison
    end
  end
end
