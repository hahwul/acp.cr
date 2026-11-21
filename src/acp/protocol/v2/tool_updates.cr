require "base64"
require "./initialization"
require "./metadata_patch"
require "../tool_call_content"
require "../raw_json"

module ACP
  module Protocol
    module V2
      # Optional actions allowed for a tool call or an Agent-owned terminal.
      struct EntityCapabilities
        include JSON::Serializable

        # A current marker authorizing a cancel request.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::V2::Capability))]
        property cancel : Capability?

        # Extension metadata scoped to these capabilities.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        property meta : Hash(String, JSON::Any)?

        # Creates entity capabilities.
        def initialize(@cancel : Capability? = nil, @meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # One file operation in a structured diff.
      struct DiffChange
        include JSON::Serializable
        include LosslessUnmapped

        protected def keep_exact_unmapped?(_key : String) : Bool
          true
        end

        # Open operation discriminator, such as modify, move, or copy.
        getter operation : String

        # Creates a file change with its operation-specific fields.
        def initialize(@operation : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
        end

        # Absolute destination path or the affected path.
        def path : String?
          @json_unmapped["path"]?.try(&.as_s?)
        end

        # Absolute source path for a move or copy.
        def old_path : String?
          @json_unmapped["oldPath"]?.try(&.as_s?)
        end

        # Open file type qualifier.
        def file_type : String?
          @json_unmapped["fileType"]?.try(&.as_s?)
        end

        # Optional media type of the file contents.
        def mime_type : String?
          @json_unmapped["mimeType"]?.try(&.as_s?)
        end
      end

      # Renderable patch text associated with a structured diff.
      struct DiffPatch
        include JSON::Serializable

        # Optional extension formats are retained as strings.
        property format : String

        # Patch text.
        property text : String

        # Extension metadata scoped to the patch.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        property meta : Hash(String, JSON::Any)?

        # Creates a renderable patch.
        def initialize(@format : String, @text : String, @meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # Structured file changes and their optional textual patch.
      struct DiffContent
        include JSON::Serializable

        # New, changed, or removed paths reported by the tool.
        property changes : Array(DiffChange)

        # Optional renderable patch.
        property patch : DiffPatch?

        # Extension metadata scoped to the diff.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        property meta : Hash(String, JSON::Any)?

        # Creates the structured diff.
        def initialize(@changes : Array(DiffChange), @patch : DiffPatch? = nil, @meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # Open content item belonging to a tool call.
      struct ToolCallContent
        include JSON::Serializable
        include LosslessUnmapped

        protected def keep_exact_unmapped?(_key : String) : Bool
          true
        end

        # Content type such as content, diff, terminal, or session.
        @[JSON::Field(key: "type")]
        getter content_type : String

        # Creates content with the fields of its variant.
        def initialize(@content_type : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
        end

        # Typed diff for a recognized structured diff item.
        def diff : DiffContent?
          DiffContent.from_json(WireFrame.encode(self)) if @content_type == "diff"
        rescue JSON::ParseException
          nil
        end

        # Standard content block for a recognized content item.
        def content_block : Protocol::ContentBlock?
          return unless @content_type == "content" && (content = exact_unmapped_json("content"))

          Protocol::ContentBlock.from_json(content)
        rescue JSON::ParseException
          nil
        end

        # ID of the referenced Agent-owned terminal.
        def terminal_id : String?
          @json_unmapped["terminalId"]?.try(&.as_s?) if @content_type == "terminal"
        end

        # ID of the referenced child session.
        def session_id : String?
          @json_unmapped["sessionId"]?.try(&.as_s?) if @content_type == "session"
        end

        # Extension metadata scoped to the content item.
        def meta : Hash(String, JSON::Any)?
          @json_unmapped["_meta"]?.try(&.as_h?)
        end
      end

      # Fields shared by tool-call updates and permission subjects.
      abstract struct ToolCallPatch
        include JSON::Serializable
        include LosslessUnmapped

        protected def keep_exact_unmapped?(_key : String) : Bool
          true
        end

        # Tool call updated by this patch.
        @[JSON::Field(key: "toolCallId")]
        getter tool_call_id : String

        # Fields are replaced when present. Top-level metadata patches by key.
        PatchFields.define({
          name:         {String, "name"},
          title:        {String, "title"},
          kind:         {String, "kind"},
          status:       {String, "status"},
          content:      {Array(ToolCallContent), "content"},
          locations:    {Array(Protocol::ToolCallLocation), "locations"},
          capabilities: {EntityCapabilities, "capabilities"},
        })
        include MetadataPatch

        macro raw_payload_field(name, wire_name)
          @[JSON::Field(key: {{wire_name}}, presence: true, emit_null: true, ignore_serialize: !@{{name.id}}_wire_present)]
          @{{name.id}}_wire : PreservedJson?

          @[JSON::Field(ignore: true)]
          @{{name.id}}_wire_present : Bool = false

          # JSON::Any projection when the reported value is representable.
          def {{name.id}} : JSON::Any?
            @{{name.id}}_wire.try(&.value)
          end

          # Replaces the reported value. Assign nil to clear it explicitly.
          def {{name.id}}=(value : JSON::Any?) : JSON::Any?
            @{{name.id}}_wire_present = true
            @{{name.id}}_wire = value.try { |supplied| PreservedJson.new(supplied) }
            value
          end

          # Whether the patch supplies the field, including explicit null.
          def {{name.id}}_present? : Bool
            @{{name.id}}_wire_present
          end

          # Exact JSON for the supplied value when non-null.
          def {{name.id}}_raw : RawJson?
            @{{name.id}}_wire.try(&.raw)
          end
        end

        raw_payload_field raw_input, "rawInput"
        raw_payload_field raw_output, "rawOutput"

        @[JSON::Field(key: "_meta", presence: true, emit_null: true, ignore_serialize: !meta_present?, converter: ::ACP::Protocol::PreservedMetadata)]
        @metadata_wire : PreservedJson?

        @[JSON::Field(ignore: true)]
        @metadata_wire_present = false

        # Extension metadata that can be represented as JSON::Any.
        def meta : Hash(String, JSON::Any)?
          @metadata_wire.try(&.value).try(&.as_h?)
        end

        # Replaces metadata. Assign nil to explicitly clear it.
        def meta=(value : Hash(String, JSON::Any)?) : Hash(String, JSON::Any)?
          @metadata_wire_present = true
          @metadata_wire = value.try { |fields| PreservedJson.new(JSON::Any.new(fields)) }
          value
        end

        # Whether this patch supplies metadata or explicitly clears it.
        def meta_present? : Bool
          @metadata_wire_present && (!@metadata_wire || !!meta_raw)
        end

        # Exact metadata object when the patch supplies one.
        def meta_raw : RawJson?
          if raw = @metadata_wire.try(&.raw)
            raw if raw.object?
          end
        end

        # Applies this patch to a metadata map representable as JSON::Any.
        def apply_metadata(previous : Hash(String, JSON::Any)?) : Hash(String, JSON::Any)?
          return super unless @metadata_wire.try(&.partial?) && (raw = meta_raw)

          result = previous.try(&.dup) || {} of String => JSON::Any
          raw.members?.not_nil!.each do |key, member|
            if !member.null? && (value = member.to_json_any?)
              result[key] = value
            else
              result.delete(key)
            end
          end
          result
        end

        # Creates a tool-call patch. Set a field to nil to explicitly clear it.
        def initialize(@tool_call_id : String)
        end
      end

      # Creates or patches one tool call in the session timeline.
      struct ToolCallUpdate < ToolCallPatch
        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "tool_call_update"
      end

      # Appends one content item to a tool call.
      struct ToolCallContentChunk
        include JSON::Serializable

        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "tool_call_content_chunk"

        # Tool call receiving the chunk.
        @[JSON::Field(key: "toolCallId")]
        property tool_call_id : String

        # Content item to append.
        property content : ToolCallContent

        # Extension metadata scoped to this chunk.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        property meta : Hash(String, JSON::Any)?

        # Creates a tool-call content chunk.
        def initialize(@tool_call_id : String, @content : ToolCallContent, @meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # Base64 terminal output snapshot.
      struct TerminalOutput
        include JSON::Serializable

        # Base64-encoded terminal bytes.
        property data : String

        # Extension metadata scoped to the output snapshot.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates an output snapshot from base64 text.
        def initialize(@data : String, @meta : Hash(String, JSON::Any)? = nil)
        end

        # Decodes the terminal output bytes.
        def bytes : Bytes
          Base64.decode(@data)
        end
      end

      # Process exit status for an Agent-owned terminal.
      struct TerminalExitStatus
        include JSON::Serializable

        # Signed exit code, including platform-specific values.
        @[JSON::Field(key: "exitCode")]
        property exit_code : Int64?

        # Signal name when the process was terminated by a signal.
        property signal : String?

        # Extension metadata scoped to the exit status.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates an exit status snapshot.
        def initialize(@exit_code : Int64? = nil, @signal : String? = nil, @meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # Reported dimensions of the Agent-owned terminal.
      struct TerminalSize
        include JSON::Serializable

        # Terminal columns.
        property cols : UInt16

        # Terminal rows.
        property rows : UInt16

        # Extension metadata scoped to the dimensions.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates terminal dimensions.
        def initialize(@cols : UInt16, @rows : UInt16, @meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # Creates or patches an Agent-owned display terminal.
      struct TerminalUpdate
        include JSON::Serializable

        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "terminal_update"

        # Terminal updated by this patch.
        @[JSON::Field(key: "terminalId")]
        getter terminal_id : String

        # Optional fields distinguish omission from an explicit clear.
        PatchFields.define({
          command:      {String, "command"},
          cwd:          {String, "cwd"},
          output:       {TerminalOutput, "output"},
          exit_status:  {TerminalExitStatus, "exitStatus"},
          size:         {TerminalSize, "size"},
          capabilities: {EntityCapabilities, "capabilities"},
          meta:         {Hash(String, JSON::Any), "_meta"},
        })
        include MetadataPatch

        # Creates a terminal patch. Set a field to nil to explicitly clear it.
        def initialize(@terminal_id : String)
        end
      end

      # Appends bytes to an Agent-owned display terminal.
      struct TerminalOutputChunk
        include JSON::Serializable

        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "terminal_output_chunk"

        # Terminal receiving these output bytes.
        @[JSON::Field(key: "terminalId")]
        property terminal_id : String

        # Base64-encoded output bytes.
        property data : String

        # Extension metadata scoped to this chunk.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates a terminal output chunk from base64 text.
        def initialize(@terminal_id : String, @data : String, @meta : Hash(String, JSON::Any)? = nil)
        end

        # Decodes the newly appended output bytes.
        def bytes : Bytes
          Base64.decode(@data)
        end
      end
    end
  end
end
