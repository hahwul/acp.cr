require "../updates"
require "../raw_json"
require "./metadata_patch"

module ACP
  module Protocol
    module V2
      # :nodoc:
      module OptionalContentArray
        def self.from_json(pull : JSON::PullParser) : PreservedJson
          PreservedJson.new(pull, project_array_objects: true)
        end

        def self.to_json(content : PreservedJson, builder : JSON::Builder) : Nil
          content.to_json(builder)
        end
      end

      # :nodoc:
      module ContentArrayPatch
        macro define(name)
          @[JSON::Field(key: {{name.id.stringify}}, presence: true, emit_null: true, ignore_serialize: !{{name.id}}_present?, converter: ::ACP::Protocol::V2::OptionalContentArray)]
          @{{name.id}}_wire : PreservedJson?

          @[JSON::Field(ignore: true)]
          @{{name.id}}_wire_present : Bool = false

          # Replacement content with representable fields in each block.
          def {{name.id}} : Array(JSON::Any)?
            @{{name.id}}_wire.try(&.value).try(&.as_a?)
          end

          # Replaces content. Assign nil to clear it explicitly.
          def {{name.id}}=(value : Array(JSON::Any)?) : Array(JSON::Any)?
            @{{name.id}}_wire_present = true
            @{{name.id}}_wire = value.try { |blocks| PreservedJson.new(JSON::Any.new(blocks)) }
            value
          end

          # Whether the patch supplies an array or explicitly clears it.
          def {{name.id}}_present? : Bool
            @{{name.id}}_wire_present && (!@{{name.id}}_wire || !{{name.id}}.nil?)
          end

          # Exact replacement content with the original numeric values.
          def {{name.id}}_raw : RawJson?
            @{{name.id}}_wire.try(&.raw) if {{name.id}}_present?
          end
        end
      end

      # :nodoc:
      module MessageContentPatch
        ContentArrayPatch.define(content)

        # Usable standard and unrecognized v2 display blocks in wire order.
        def content_blocks : Array(Protocol::ContentBlock)?
          content_raw.try { |raw| Protocol::ContentBlock.decode_v2_array(raw) }
        end
      end

      # Patches a transcript's view of a message between sessions.
      struct SessionMessageUpdate
        include JSON::Serializable

        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "session_message"

        # Message ID in the enclosing session's transcript.
        @[JSON::Field(key: "messageId")]
        getter message_id : String

        # Links refer to the sender's and recipient's views of the same message.
        PatchFields.define({
          sender_session_id:    {String, "senderSessionId"},
          recipient_session_id: {String, "recipientSessionId"},
          sender_message_id:    {String, "senderMessageId"},
          recipient_message_id: {String, "recipientMessageId"},
        })
        include MessageContentPatch
        include LosslessMetadataPatch

        # Creates an update for the specified transcript message.
        def initialize(@message_id : String)
        end
      end

      # Patches the enclosing session's title, last activity, or metadata.
      struct SessionInfoUpdate
        include JSON::Serializable

        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "session_info_update"

        # Title and RFC 3339 timestamp, with a key-level metadata patch.
        PatchFields.define({
          title:      {String, "title"},
          updated_at: {String, "updatedAt"},
          meta:       {Hash(String, JSON::Any), "_meta"},
        })
        include MetadataPatch

        # Creates a session info update. Assign fields to patch them.
        def initialize
        end
      end

      # Reports context-window usage and optionally updates cumulative cost.
      struct UsageUpdate
        include JSON::Serializable

        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "usage_update"

        # Tokens currently in use.
        property used : UInt64

        # Total context capacity in tokens.
        property size : UInt64

        # Cumulative cost and key-level metadata patches.
        PatchFields.define({
          cost: {Protocol::Cost, "cost"},
          meta: {Hash(String, JSON::Any), "_meta"},
        })
        include MetadataPatch

        # Creates a usage update for the reported token counts.
        def initialize(@used : UInt64, @size : UInt64)
        end
      end

      # Creates or patches a context compaction entry on the session timeline.
      struct CompactionUpdate
        include JSON::Serializable

        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "compaction_update"

        # Compaction ID scoped to this session.
        @[JSON::Field(key: "compactionId")]
        getter compaction_id : String

        # Clearing status resets it to in_progress. The summary is open content.
        PatchFields.define({
          status: {String, "status"},
          error:  {String, "error"},
        })
        ContentArrayPatch.define(summary)
        include LosslessMetadataPatch

        # Usable display blocks from the replacement compaction summary.
        def typed_summary : Array(Protocol::ContentBlock)?
          summary_raw.try { |raw| Protocol::ContentBlock.decode_v2_array(raw) }
        end

        # Creates an update for the specified compaction entry.
        def initialize(@compaction_id : String)
        end
      end

      # An identified execution plan, including custom and future representations.
      struct PlanContent
        include JSON::Serializable
        include JSON::Serializable::Unmapped

        # Representation discriminator, such as items or markdown.
        @[JSON::Field(key: "type")]
        getter type : String

        # Plan ID that this content replaces in the enclosing session.
        @[JSON::Field(key: "planId")]
        getter plan_id : String

        # Creates a plan with its representation-specific fields.
        def initialize(@type : String, @plan_id : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
        end

        # Returns the structured form of a known checklist or Markdown plan.
        def typed : Protocol::PlanUpdateContent?
          Protocol::PlanUpdateContent.from_json(to_json) if @type.in?("items", "markdown")
        rescue JSON::ParseException
          nil
        end
      end

      # Replaces an identified plan with a complete new representation.
      struct PlanUpdate
        include JSON::Serializable

        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "plan_update"

        # Complete replacement for this plan.
        property plan : PlanContent

        # Extension metadata scoped to the update.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates an update with a complete plan.
        def initialize(@plan : PlanContent, @meta : Hash(String, JSON::Any)? = nil)
        end
      end
    end
  end
end
