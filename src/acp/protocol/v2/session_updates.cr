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

        # :nodoc:
        WIRE_FIELDS = {"sessionUpdate", "messageId", "senderSessionId", "recipientSessionId", "senderMessageId", "recipientMessageId", "content", "_meta"}

        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "session_message"

        # Message ID in the enclosing session's transcript.
        @[JSON::Field(key: "messageId")]
        getter message_id : String

        # Links refer to the sender's and recipient's views of the same message.
        PatchFields.tolerant({
          sender_session_id:    {String, "senderSessionId", OptionalCapabilityString},
          recipient_session_id: {String, "recipientSessionId", OptionalCapabilityString},
          sender_message_id:    {String, "senderMessageId", OptionalCapabilityString},
          recipient_message_id: {String, "recipientMessageId", OptionalCapabilityString},
        })
        include MessageContentPatch
        include LosslessMetadataPatch

        # Creates an update for the specified transcript message.
        def initialize(@message_id : String)
        end

        # Reads a patch for an unambiguous local message and omits conflicting optional fields.
        def self.new(pull : JSON::PullParser) : self
          location = pull.location
          wire = RawJson.new(pull)
          repeated = WireFrame.repeated_members(wire.json, *WIRE_FIELDS)
          if repeated.includes?("sessionUpdate") || repeated.includes?("messageId")
            raise JSON::ParseException.new("Ambiguous ACP session message ID or type", *location)
          end
          repeated.each { |field| wire = wire.without_field(field) }
          previous_def(JSON::PullParser.new(wire.json))
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
        })
        include LosslessMetadataPatch

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
        })
        include LosslessMetadataPatch

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
        include LosslessUnmapped

        # Representation discriminator, such as items or markdown.
        @[JSON::Field(key: "type")]
        getter type : String

        # Plan ID that this content replaces in the enclosing session.
        @[JSON::Field(key: "planId")]
        getter plan_id : String

        # Creates a plan with its representation-specific fields.
        def initialize(@type : String, @plan_id : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
        end

        # Reads the envelope before decoding entries independently.
        def self.new(pull : JSON::PullParser) : self
          location = pull.location
          wire = WireFrame.read_raw(pull)
          unless WireFrame.unique_members?(wire, recursive: false)
            raise JSON::ParseException.new("Ambiguous ACP plan fields", *location)
          end
          previous_def(JSON::PullParser.new(wire))
        end

        protected def keep_exact_unmapped?(_key : String) : Bool
          true
        end

        # The complete plan representation, including unrecognized fields.
        def raw : RawJson
          RawJson.new(JSON::PullParser.new(WireFrame.encode(self)))
        end

        # Exact extension metadata scoped to this plan.
        def meta_raw : RawJson?
          if json = exact_unmapped_json("_meta")
            RawJson.new(JSON::PullParser.new(json)) if json.starts_with?('{')
          end
        end

        # Returns the structured form of a known checklist or Markdown plan.
        def typed : Protocol::PlanUpdateContent?
          case @type
          when "items"
            if entries = exact_unmapped_json("entries")
              parsed = Protocol::PlanEntries.read(JSON::PullParser.new(entries), require_fields: true)
              Protocol::PlanItems.new(@plan_id, parsed, meta_raw: meta_raw)
            end
          when "markdown"
            Protocol::PlanMarkdown.from_json(WireFrame.encode(self))
          end
        rescue JSON::ParseException
          nil
        end

        private def after_initialize : Nil
          valid = case @type
                  when "items"    then exact_unmapped_json("entries").try(&.starts_with?('['))
                  when "markdown" then @json_unmapped["content"]?.try(&.as_s?)
                  else                 true
                  end
          unless valid
            raise JSON::ParseException.new("Missing or invalid content for ACP plan type #{@type.inspect}", 0, 0)
          end
        end
      end

      # Replaces an identified plan with a complete new representation.
      struct PlanUpdate
        include JSON::Serializable
        include LosslessMetadata

        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "plan_update"

        # Complete replacement for this plan.
        property plan : PlanContent

        # Creates an update with a complete plan.
        def initialize(@plan : PlanContent, meta : Hash(String, JSON::Any)? = nil)
          self.meta = meta
        end
      end
    end
  end
end
