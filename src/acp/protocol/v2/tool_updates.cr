require "base64"
require "./initialization"
require "./metadata_patch"
require "../tool_call_content"

module ACP
  module Protocol
    module V2
      # Optional actions allowed for a tool call or an Agent-owned terminal.
      struct EntityCapabilities
        include JSON::Serializable

        # A current marker authorizing a cancel request.
        property cancel : Capability?

        # Extension metadata scoped to these capabilities.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates entity capabilities.
        def initialize(@cancel : Capability? = nil, @meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # One file operation in a structured diff.
      struct DiffChange
        include JSON::Serializable
        include JSON::Serializable::Unmapped

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
        @[JSON::Field(key: "_meta")]
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
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates the structured diff.
        def initialize(@changes : Array(DiffChange), @patch : DiffPatch? = nil, @meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # Open content item belonging to a tool call.
      struct ToolCallContent
        include JSON::Serializable
        include JSON::Serializable::Unmapped

        # Content type such as content, diff, terminal, or session.
        @[JSON::Field(key: "type")]
        getter content_type : String

        # Creates content with the fields of its variant.
        def initialize(@content_type : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
        end

        # Typed diff for a recognized structured diff item.
        def diff : DiffContent?
          DiffContent.from_json(@json_unmapped.to_json) if @content_type == "diff"
        rescue JSON::ParseException
          nil
        end

        # Standard content block for a recognized content item.
        def content_block : Protocol::ContentBlock?
          return unless @content_type == "content" && (content = @json_unmapped["content"]?)

          Protocol::ContentBlock.from_json(content.to_json)
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
          raw_input:    {JSON::Any, "rawInput"},
          raw_output:   {JSON::Any, "rawOutput"},
          capabilities: {EntityCapabilities, "capabilities"},
          meta:         {Hash(String, JSON::Any), "_meta"},
        })
        include MetadataPatch

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
        @[JSON::Field(key: "_meta")]
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
