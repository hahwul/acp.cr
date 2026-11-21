require "base64"
require "./initialization"
require "./metadata_patch"
require "../content_block"
require "../tool_call_content"
require "../raw_json"
require "../session_options"

module ACP
  module Protocol
    module V2
      # Optional actions allowed for a tool call or an Agent-owned terminal.
      struct EntityCapabilities
        include JSON::Serializable
        include LosslessMetadata

        # A current marker authorizing a cancel request.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::V2::Capability))]
        property cancel : Capability?

        # Creates entity capabilities.
        def initialize(@cancel : Capability? = nil, meta : Hash(String, JSON::Any)? = nil)
          self.meta = meta
        end
      end

      # One file operation in a structured diff.
      struct DiffChange
        include JSON::Serializable
        include LosslessOpenObject

        # Open operation discriminator, such as modify, move, or copy.
        getter operation : String

        # Creates a file change with its operation-specific fields.
        def initialize(@operation : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
        end

        # Reads one operation with its required absolute paths.
        def self.new(pull : JSON::PullParser) : self
          location = pull.location
          wire = WireFrame.read_raw(pull)
          unless WireFrame.unique_members?(wire, recursive: false)
            raise JSON::ParseException.new("Ambiguous ACP diff change fields", *location)
          end

          change = previous_def(JSON::PullParser.new(wire))
          unless change.valid_paths?
            raise JSON::ParseException.new("ACP diff change requires absolute paths for #{change.operation}", *location)
          end
          change
        end

        # Absolute destination path or the affected path.
        def path : String?
          absolute_path_field("path")
        end

        # Absolute source path for a move or copy.
        def old_path : String?
          absolute_path_field("oldPath")
        end

        # Open file type qualifier.
        def file_type : String?
          @json_unmapped["fileType"]?.try(&.as_s?)
        end

        # Optional media type of the file contents.
        def mime_type : String?
          @json_unmapped["mimeType"]?.try(&.as_s?)
        end

        protected def valid_paths? : Bool
          case @operation
          when "add", "delete", "modify"
            !path.nil?
          when "move", "copy"
            !path.nil? && !old_path.nil?
          else
            true
          end
        end

        private def absolute_path_field(key : String) : String?
          if value = @json_unmapped[key]?.try(&.as_s?)
            value if Protocol.absolute_path?(value)
          end
        end
      end

      # Optional patch text associated with a structured diff.
      struct DiffPatch
        include JSON::Serializable
        include LosslessMetadata

        # Optional extension formats are retained as strings.
        property format : String

        # Patch text.
        property text : String

        # Creates a patch in the supplied format.
        def initialize(@format : String, @text : String, meta : Hash(String, JSON::Any)? = nil)
          self.meta = meta
        end

        # Reads patch fields with an unambiguous format and text.
        def self.new(pull : JSON::PullParser) : self
          location = pull.location
          wire = WireFrame.read_raw(pull)
          unless WireFrame.unique_members?(wire, recursive: false)
            raise JSON::ParseException.new("Ambiguous ACP diff patch fields", *location)
          end
          previous_def(JSON::PullParser.new(wire))
        end
      end

      # Structured file changes and their optional textual patch.
      struct DiffContent
        include JSON::Serializable
        include LosslessMetadata

        # Usable changes in wire order. Conflicting destination paths are omitted.
        @[JSON::Field(converter: ::ACP::Protocol::V2::DiffContent::Changes)]
        property changes : Array(DiffChange)

        # Optional patch, including custom and future formats.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalContentValue(::ACP::Protocol::V2::DiffPatch))]
        property patch : DiffPatch?

        # Creates the structured diff.
        def initialize(@changes : Array(DiffChange), @patch : DiffPatch? = nil, meta : Hash(String, JSON::Any)? = nil)
          self.meta = meta
        end

        # Reads the change list, treating an ambiguous optional patch as absent.
        def self.new(pull : JSON::PullParser) : self
          location = pull.location
          wire = RawJson.new(pull)
          repeated = repeated_fields(wire)
          if repeated.includes?("changes")
            raise JSON::ParseException.new("Ambiguous ACP diff changes", *location)
          end
          wire = wire.without_field("patch") if repeated.includes?("patch")
          previous_def(JSON::PullParser.new(wire.json))
        end

        # :nodoc:
        def self.repeated_fields(wire : RawJson) : Set(String)
          seen = Set(String).new
          repeated = Set(String).new
          if wire.object?
            pull = JSON::PullParser.new(wire.json)
            pull.read_object do |key|
              repeated.add(key) if key.in?("type", "changes", "patch") && !seen.add?(key)
              pull.skip
            end
          end
          repeated
        end

        # Returns the patch in ACP's standard git_patch format, when supplied.
        # Use changes as the authoritative list of affected files.
        def git_patch : DiffPatch?
          patch = @patch
          patch if patch && patch.format == "git_patch"
        end

        # :nodoc:
        module Changes
          def self.from_json(pull : JSON::PullParser) : Array(DiffChange)
            location = pull.location
            changes = [] of DiffChange
            paths = Set(String).new
            conflicts = Set(String).new
            pull.read_array do
              if change = decode_change(pull)
                if (path = change.path) && !paths.add?(path)
                  conflicts.add(path)
                end
                changes << change
              end
            end

            changes.reject! { |change| (path = change.path) && conflicts.includes?(path) } unless conflicts.empty?
            if changes.empty?
              raise JSON::ParseException.new("ACP diff requires a usable file change", *location)
            end
            changes
          end

          private def self.decode_change(pull : JSON::PullParser) : DiffChange?
            return DiffChange.new(pull) if pull.kind.begin_object?

            WireFrame.read_raw(pull)
            nil
          rescue JSON::ParseException
            nil
          end

          def self.to_json(value : Array(DiffChange), json : JSON::Builder) : Nil
            value.to_json(json)
          end
        end
      end

      # Open content item belonging to a tool call.
      struct ToolCallContent
        include JSON::Serializable
        include LosslessOpenObject

        # Content type such as content, diff, terminal, or session.
        @[JSON::Field(key: "type")]
        getter content_type : String

        # Creates content with the fields of its variant.
        def initialize(@content_type : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
        end

        # Reads open content, clearing ambiguous fields in a structured diff.
        def self.new(pull : JSON::PullParser) : self
          wire = RawJson.new(pull)
          content = previous_def(JSON::PullParser.new(wire.json))
          return content unless content.content_type == "diff"

          repeated = DiffContent.repeated_fields(wire)
          return content if repeated.empty?

          wire = wire.without_field("changes") if repeated.includes?("type") || repeated.includes?("changes")
          wire = wire.without_field("patch") if repeated.includes?("patch")
          previous_def(JSON::PullParser.new(wire.json))
        end

        # Typed diff for a recognized structured diff item.
        def diff : DiffContent?
          DiffContent.from_json(WireFrame.encode(self)) if @content_type == "diff"
        rescue JSON::ParseException
          nil
        end

        # Open ACP v2 display block for a content item.
        def content_block : Protocol::ContentBlock?
          return unless @content_type == "content" && (content = exact_unmapped_json("content"))

          Protocol::ContentBlock.from_v2_json(content)
        rescue JSON::Error
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
      end

      # :nodoc:
      module ToolPatchContentList
        def self.from_json(pull : JSON::PullParser) : Array(ToolCallContent)?
          OptionalContentList(ToolCallContent).from_json(pull) do |item|
            decode(RawJson.new(item))
          end
        end

        private def self.decode(wire : RawJson) : ToolCallContent?
          return unless wire.object?

          unless WireFrame.unique_members?(wire.json, recursive: false)
            # A diff can still render its changes when its optional patch is ambiguous.
            return unless WireFrame.field(wire.json, "type", unique: true) == %("diff") &&
                          WireFrame.unique_members?(wire.without_field("patch").json, recursive: false)
          end

          content = ToolCallContent.from_json(wire.json)
          case content.content_type
          when "content"  then content if content.content_block
          when "diff"     then content if content.diff
          when "terminal" then content if content.terminal_id
          when "session"  then content if content.session_id
          else                 content
          end
        rescue JSON::ParseException
          nil
        end
      end

      # :nodoc:
      module ToolPatchLocationList
        def self.from_json(pull : JSON::PullParser) : Array(Protocol::ToolCallLocation)?
          OptionalContentList(Protocol::ToolCallLocation).from_json(pull) do |item|
            decode(RawJson.new(item))
          end
        end

        private def self.decode(wire : RawJson) : Protocol::ToolCallLocation?
          return unless wire.object?
          path = WireFrame.field(wire.json, "path", unique: true)
          return unless path && path.starts_with?('"') && Protocol.absolute_path?(String.from_json(path))

          wire = wire.without_field("line") unless valid_line?(wire)
          Protocol::ToolCallLocation.from_json(wire.json)
        rescue JSON::ParseException
          nil
        end

        private def self.valid_line?(wire : RawJson) : Bool
          line = WireFrame.field(wire.json, "line", unique: true)
          return true if line.nil? || line == "null"

          number = line.to_u32?
          !!number && !number.zero?
        rescue JSON::ParseException
          false
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
        PatchFields.tolerant({
          name:         {String, "name", OptionalCapabilityString},
          title:        {String, "title", OptionalCapabilityString},
          kind:         {String, "kind", OptionalCapabilityString},
          status:       {String, "status", OptionalCapabilityString},
          content:      {Array(ToolCallContent), "content", ToolPatchContentList},
          locations:    {Array(Protocol::ToolCallLocation), "locations", ToolPatchLocationList},
          capabilities: {EntityCapabilities, "capabilities", OptionalCapabilityObject(EntityCapabilities)},
        })
        include LosslessMetadataPatch

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
        include LosslessMetadata

        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "tool_call_content_chunk"

        # Tool call receiving the chunk.
        @[JSON::Field(key: "toolCallId")]
        property tool_call_id : String

        # Content item to append.
        property content : ToolCallContent

        # Creates a tool-call content chunk.
        def initialize(@tool_call_id : String, @content : ToolCallContent, meta : Hash(String, JSON::Any)? = nil)
          self.meta = meta
        end
      end

      # Base64 terminal output snapshot.
      struct TerminalOutput
        include JSON::Serializable
        include LosslessMetadata

        # Base64-encoded terminal bytes.
        property data : String

        # Creates an output snapshot from base64 text.
        def initialize(@data : String, meta : Hash(String, JSON::Any)? = nil)
          self.meta = meta
        end

        # Decodes the terminal output bytes.
        def bytes : Bytes
          Base64.decode(@data)
        end
      end

      # Process exit status for an Agent-owned terminal.
      struct TerminalExitStatus
        include JSON::Serializable
        include LosslessMetadata

        # Signed exit code, including platform-specific values.
        @[JSON::Field(key: "exitCode")]
        property exit_code : Int64?

        # Signal name when the process was terminated by a signal.
        property signal : String?

        # Creates an exit status snapshot.
        def initialize(@exit_code : Int64? = nil, @signal : String? = nil, meta : Hash(String, JSON::Any)? = nil)
          self.meta = meta
        end
      end

      # Reported dimensions of the Agent-owned terminal.
      struct TerminalSize
        include JSON::Serializable
        include LosslessMetadata

        # Terminal columns.
        property cols : UInt16

        # Terminal rows.
        property rows : UInt16

        # Creates terminal dimensions.
        def initialize(@cols : UInt16, @rows : UInt16, meta : Hash(String, JSON::Any)? = nil)
          self.meta = meta
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
        })
        include LosslessMetadataPatch

        # Creates a terminal patch. Set a field to nil to explicitly clear it.
        def initialize(@terminal_id : String)
        end
      end

      # Appends bytes to an Agent-owned display terminal.
      struct TerminalOutputChunk
        include JSON::Serializable
        include LosslessMetadata

        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "terminal_output_chunk"

        # Terminal receiving these output bytes.
        @[JSON::Field(key: "terminalId")]
        property terminal_id : String

        # Base64-encoded output bytes.
        property data : String

        # Creates a terminal output chunk from base64 text.
        def initialize(@terminal_id : String, @data : String, meta : Hash(String, JSON::Any)? = nil)
          self.meta = meta
        end

        # Decodes the newly appended output bytes.
        def bytes : Bytes
          Base64.decode(@data)
        end
      end
    end
  end
end
