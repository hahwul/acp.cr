require "./initialization"
require "./configuration"
require "../session_fork"

module ACP
  module Protocol
    module V2
      # Parameters of the draft session/set_title request.
      alias SetSessionTitleParams = Protocol::SetSessionTitleParams

      # The title the Agent stored after setting a session title.
      alias SetSessionTitleResult = Protocol::SetSessionTitleResult

      # Checks absolute paths in the Agent's POSIX or Windows filesystem syntax.
      def self.absolute_path?(value : String) : Bool
        Protocol.absolute_path?(value)
      end

      # An inclusive cursor for replaying session history.
      struct ReplayFrom
        include JSON::Serializable
        include LosslessOpenObject

        @[JSON::Field(ignore: true)]
        @metadata_wire : PreservedJson?

        # Cursor discriminator. `start` replays from the earliest retained entry.
        @[JSON::Field(key: "type")]
        getter cursor_type : String

        # Creates a cursor and retains variant-specific fields.
        def initialize(@cursor_type : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
        end

        # Replays the entire retained session history.
        def self.start(meta : Hash(String, JSON::Any)? = nil) : ReplayFrom
          fields = {} of String => JSON::Any
          fields["_meta"] = JSON::Any.new(meta) if meta
          new("start", fields)
        end

        protected def on_unknown_json_attribute(pull, key, key_location)
          return super unless key == "_meta"

          wire = RawJson.new(pull)
          metadata = PreservedMetadata.wrap(wire) if wire.object?
          @metadata_wire = metadata.try(&.partial?) ? nil : metadata
          retain_unmapped_json(key, wire.json, projection: @metadata_wire.try(&.value))
        end

        protected def retained_unmapped_json(key : String, value : JSON::Any) : String?
          if key == "_meta" && (metadata = @metadata_wire) && (view = metadata.value.try(&.as_h?)) && value.as_h?.try(&.same?(view))
            return metadata.raw.json
          end

          super
        end

        def_equals_and_hash @cursor_type, @json_unmapped, @raw_fields
      end

      # A v2 MCP server with an explicit transport discriminator. Future
      # transport settings are preserved in `json_unmapped`.
      struct McpServer
        include JSON::Serializable
        include LosslessOpenObject
        include EditableLosslessUnmapped

        # MCP transport type such as `stdio` or `http`.
        @[JSON::Field(key: "type")]
        getter transport_type : String

        # Creates a transport definition with variant-specific fields.
        def initialize(@transport_type : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
        end

        # Encodes a standard stdio server with its required v2 discriminator.
        def self.stdio(server : Protocol::McpServerStdio) : McpServer
          from_declaration(server, "stdio")
        end

        # Encodes a standard HTTP server.
        def self.http(server : Protocol::McpServerHttp) : McpServer
          from_declaration(server, "http")
        end

        # Encodes a server registered on the current ACP connection.
        def self.acp(server : Protocol::McpServerAcp) : McpServer
          from_declaration(server, "acp")
        end

        private def self.from_declaration(server : Protocol::McpServer, transport_type : String) : McpServer
          wire = RawJson.new(JSON::PullParser.new(WireFrame.encode(server)))
          type = RawJson.new(JSON::Any.new(transport_type))
          from_json(wire.with_field("type", type).json)
        end

        protected def project_unmapped_field(key : String, wire : RawJson) : PreservedJson
          preserved = super
          # A wide number in header or env metadata must not hide the
          # editable list. In particular, deleting it must remove it on wire.
          if !preserved.value && key.in?("headers", "env") && wire.elements?.try(&.all?(&.object?))
            return PreservedJson.new(wire, project_array_objects: true, project_nested_objects: true)
          end
          preserved
        end

        # Typed stdio configuration when the transport is stdio.
        def stdio_config : Protocol::McpServerStdio?
          Protocol::McpServerStdio.from_json(WireFrame.encode(self)) if @transport_type == "stdio"
        rescue JSON::ParseException
          nil
        end

        # Typed HTTP configuration when the transport is HTTP.
        def http_config : Protocol::McpServerHttp?
          Protocol::McpServerHttp.from_json(WireFrame.encode(self)) if @transport_type == "http"
        rescue JSON::ParseException
          nil
        end

        def_equals_and_hash @transport_type, @json_unmapped, @raw_fields
      end

      # Parameters for creating a v2 session.
      struct SessionNewParams
        include JSON::Serializable
        include LosslessMetadata

        # Absolute working directory for the session.
        property cwd : String

        # Additional absolute workspace roots.
        @[JSON::Field(key: "additionalDirectories")]
        property additional_directories : Array(String)?

        # MCP transport definitions. v2 stdio entries use `"type":"stdio"`.
        @[JSON::Field(key: "mcpServers")]
        property mcp_servers : Array(McpServer)?

        # Client-supplied system prompt.
        @[JSON::Field(key: "systemPrompt")]
        property system_prompt : Protocol::SystemPrompt?

        # Initial configuration choices, in application order.
        @[JSON::Field(key: "configOptions")]
        property config_options : Array(InitialSessionConfigOption)?

        # Creates new session parameters.
        def initialize(
          @cwd : String,
          *,
          @additional_directories : Array(String)? = nil,
          @mcp_servers : Array(McpServer)? = nil,
          @system_prompt : Protocol::SystemPrompt? = nil,
          meta : Hash(String, JSON::Any)? = nil,
          @config_options : Array(InitialSessionConfigOption)? = nil,
        )
          self.meta = meta
        end

        def_equals_and_hash @cwd, @additional_directories, @mcp_servers, @system_prompt, @config_options, metadata_comparison
      end

      # Parameters for attaching to an existing v2 session.
      struct SessionResumeParams
        include JSON::Serializable
        include LosslessMetadata

        # Existing session ID.
        @[JSON::Field(key: "sessionId")]
        property session_id : String

        # Absolute working directory for the session.
        property cwd : String

        # Additional absolute workspace roots.
        @[JSON::Field(key: "additionalDirectories")]
        property additional_directories : Array(String)?

        # MCP transport definitions.
        @[JSON::Field(key: "mcpServers")]
        property mcp_servers : Array(McpServer)?

        # Beginning of optional inclusive history replay.
        @[JSON::Field(key: "replayFrom")]
        property replay_from : ReplayFrom?

        # Client-supplied system prompt.
        @[JSON::Field(key: "systemPrompt")]
        property system_prompt : Protocol::SystemPrompt?

        # Initial configuration choices, in application order.
        @[JSON::Field(key: "configOptions")]
        property config_options : Array(InitialSessionConfigOption)?

        # Creates session resume parameters.
        def initialize(
          @session_id : String,
          @cwd : String,
          *,
          @replay_from : ReplayFrom? = nil,
          @additional_directories : Array(String)? = nil,
          @mcp_servers : Array(McpServer)? = nil,
          @system_prompt : Protocol::SystemPrompt? = nil,
          meta : Hash(String, JSON::Any)? = nil,
          @config_options : Array(InitialSessionConfigOption)? = nil,
        )
          self.meta = meta
        end

        def_equals_and_hash @session_id, @cwd, @additional_directories, @mcp_servers, @replay_from, @system_prompt, @config_options, metadata_comparison
      end

      # Optional configuration and slash commands returned during session setup.
      abstract struct SessionSetupResult
        include JSON::Serializable
        include LosslessConfigOptionList
        include LosslessAvailableCommandList
        include LosslessMetadata

        @[JSON::Field(key: "configOptions", converter: ::ACP::Protocol::V2::AdvertisementArray)]
        @config_options_wire : PreservedJson = PreservedJson.new(JSON::Any.new([] of JSON::Any))

        @[JSON::Field(key: "availableCommands", converter: ::ACP::Protocol::V2::AvailableCommandsJson)]
        @available_commands_wire : PreservedJson = PreservedJson.new(JSON::Any.new([] of JSON::Any))
      end

      # A newly created v2 session and its initial configuration.
      struct SessionNewResult < SessionSetupResult
        # Unique ID assigned by the Agent.
        @[JSON::Field(key: "sessionId")]
        property session_id : String

        # Creates a new-session result.
        def initialize(
          @session_id : String,
          config_options : Array(JSON::Any) = [] of JSON::Any,
          available_commands : Array(JSON::Any) = [] of JSON::Any,
          meta : Hash(String, JSON::Any)? = nil,
        )
          self.config_options = config_options
          self.available_commands = available_commands
          self.meta = meta
        end

        # Decodes a setup response with an unambiguous session ID and advertisements.
        def self.new(pull : JSON::PullParser) : self
          previous_def(RawJson.patch_parser(pull, required: {"sessionId", "configOptions", "availableCommands"}, optional: {"_meta"}))
        end
      end

      # Configuration returned when resuming a v2 session.
      struct SessionResumeResult < SessionSetupResult
        AdvertisementArray.guard_envelope "configOptions", "availableCommands"

        # Creates a resume result.
        def initialize(
          config_options : Array(JSON::Any) = [] of JSON::Any,
          available_commands : Array(JSON::Any) = [] of JSON::Any,
          meta : Hash(String, JSON::Any)? = nil,
        )
          self.config_options = config_options
          self.available_commands = available_commands
          self.meta = meta
        end
      end

      # Parameters for creating a v2 session from an existing session.
      alias SessionForkParams = Protocol::ForkParams(McpServer, InitialSessionConfigOption)

      # The newly created v2 fork, configuration, and commands.
      alias SessionForkResult = SessionNewResult

      # Workspace or saved session whose options the Agent should preview.
      alias SessionOptionsParams = Protocol::SessionOptionsParams

      # Advisory options and commands for a proposed v2 session.
      struct SessionOptionsResult < SessionSetupResult
        AdvertisementArray.guard_envelope "configOptions", "availableCommands"

        # Creates an options and commands preview.
        def initialize(
          config_options : Array(JSON::Any) = [] of JSON::Any,
          available_commands : Array(JSON::Any) = [] of JSON::Any,
          meta : Hash(String, JSON::Any)? = nil,
        )
          self.config_options = config_options
          self.available_commands = available_commands
          self.meta = meta
        end
      end

      # :nodoc:
      module LosslessConfigValue
        @[JSON::Field(key: "value", converter: ::ACP::Protocol::PreservedMetadata)]
        @value_wire : PreservedJson

        # The choice's JSON::Any view, or JSON null if no view is available.
        def value : JSON::Any
          @value_wire.value || JSON::Any.new(nil)
        end

        # The exact choice, including opaque extension payloads.
        def value_raw : RawJson
          @value_wire.raw
        end

        protected def value_comparison
          if @value_wire.partial?
            value_raw
          else
            @value_wire.value || value_raw
          end
        end
      end

      # A configuration choice to apply when setting up a v2 session.
      struct InitialSessionConfigOption
        include JSON::Serializable
        include LosslessUnmapped
        include LosslessMetadata
        include LosslessConfigValue

        # ID of the configuration option to set.
        @[JSON::Field(key: "configId")]
        getter config_id : String

        # Value discriminator. V2 requires it, including for IDs and booleans.
        @[JSON::Field(key: "type")]
        getter value_type : String

        # Creates an initial option with a built-in or extension value type.
        def initialize(@config_id : String, @value_type : String, value : JSON::Any | RawJson, meta : Hash(String, JSON::Any)? = nil)
          @value_wire = value.is_a?(RawJson) ? PreservedMetadata.wrap(value) : PreservedJson.new(value)
          self.meta = meta
          raise ArgumentError.new("Initial v2 config value does not match its type") unless valid_value?
        end

        # Creates an ID or boolean value.
        def self.new(config_id : String, value : String | Bool, meta : Hash(String, JSON::Any)? = nil)
          new(config_id, value.is_a?(Bool) ? "boolean" : "id", JSON::Any.new(value), meta)
        end

        protected def keep_exact_unmapped?(_key : String) : Bool
          true
        end

        def_equals_and_hash @config_id, @value_type, value_comparison, @json_unmapped, @raw_fields, metadata_comparison

        private def valid_value? : Bool
          case @value_type
          when "id"      then !value.as_s?.nil?
          when "boolean" then !value.as_bool?.nil?
          else                true
          end
        end

        private def after_initialize : Nil
          unless valid_value?
            raise JSON::ParseException.new("Initial v2 config value does not match its type", 0, 0)
          end
        end
      end

      # Filters and pagination for the agent's session list.
      alias SessionListParams = Protocol::SessionListParams

      # Session metadata returned from v2 session/list.
      alias SessionInfo = Protocol::SessionInfo

      # A page of the agent's session list.
      alias SessionListResult = Protocol::SessionListResult

      # Closes an active session and releases its resources.
      alias SessionCloseParams = Protocol::SessionCloseParams

      # Successful session/close response with optional metadata.
      alias SessionCloseResult = Protocol::SessionCloseResult

      # Deletes an existing session.
      alias SessionDeleteParams = Protocol::SessionDeleteParams

      # Successful session/delete response with optional metadata.
      alias SessionDeleteResult = Protocol::SessionDeleteResult

      # Archives a session and closes its runtime.
      alias SessionArchiveParams = Protocol::SessionArchiveParams

      # Successful session/archive response with optional metadata.
      alias SessionArchiveResult = Protocol::SessionArchiveResult

      # Restores a session to the default list without attaching to it.
      alias SessionUnarchiveParams = Protocol::SessionUnarchiveParams

      # Successful session/unarchive response with optional metadata.
      alias SessionUnarchiveResult = Protocol::SessionUnarchiveResult

      # Cancels ongoing work in one session.
      alias SessionCancelParams = Protocol::SessionCancelParams

      # Changes a configuration option in a v2 session.
      struct SessionSetConfigOptionParams
        include JSON::Serializable
        include LosslessUnmapped
        include EditableLosslessUnmapped
        include LosslessMetadata
        include LosslessConfigValue

        # Target session ID.
        @[JSON::Field(key: "sessionId")]
        property session_id : String

        # ID of the configuration option.
        @[JSON::Field(key: "configId")]
        property config_id : String

        # Value discriminator, typically `id` or `boolean`.
        @[JSON::Field(key: "type")]
        property value_type : String

        # Builds a request with an explicit value type.
        def initialize(
          @session_id : String,
          @config_id : String,
          @value_type : String,
          value : JSON::Any | RawJson,
          meta : Hash(String, JSON::Any)? = nil,
        )
          @value_wire = value.is_a?(RawJson) ? PreservedMetadata.wrap(value) : PreservedJson.new(value)
          self.meta = meta
        end

        # Builds a request for a select ID or boolean.
        def self.new(session_id : String, config_id : String, value : String | Bool, meta : Hash(String, JSON::Any)? = nil)
          new(session_id, config_id, value.is_a?(Bool) ? "boolean" : "id", JSON::Any.new(value), meta)
        end

        # Replaces the choice with a JSON::Any value.
        def value=(value : JSON::Any) : JSON::Any
          @value_wire = PreservedJson.new(value)
          value
        end

        # Replaces the choice with an exact JSON value.
        def value_raw=(value : RawJson) : RawJson
          @value_wire = PreservedMetadata.wrap(value)
          value
        end

        protected def keep_exact_unmapped?(_key : String) : Bool
          true
        end

        def_equals_and_hash @session_id, @config_id, @value_type, value_comparison, @json_unmapped, @raw_fields, metadata_comparison
      end

      # The complete configuration after a successful option change.
      struct SessionSetConfigOptionResult
        include JSON::Serializable
        include LosslessConfigOptionList
        include LosslessMetadata

        AdvertisementArray.guard_envelope "configOptions"

        @[JSON::Field(key: "configOptions", converter: ::ACP::Protocol::V2::RequiredConfigOptionArray)]
        @config_options_wire : PreservedJson

        # Creates a result containing all current configuration options.
        def initialize(config_options : Array(JSON::Any), meta : Hash(String, JSON::Any)? = nil)
          @config_options_wire = PreservedJson.new(JSON::Any.new(config_options))
          self.meta = meta
        end
      end

      # Parameters for inserting a user prompt into a v2 session.
      struct SessionPromptParams
        include JSON::Serializable
        include LosslessMetadata

        # Target session ID.
        @[JSON::Field(key: "sessionId")]
        property session_id : String

        @[JSON::Field(key: "prompt", converter: ::ACP::Protocol::ContentBlockArray)]
        @prompt_wire : PreservedJson

        # Optional key for retrying this prompt without inserting it twice.
        @[JSON::Field(key: "idempotencyKey")]
        property idempotency_key : String?

        # Builds a prompt with raw or extension content blocks.
        def initialize(
          @session_id : String,
          prompt : Array(JSON::Any),
          @idempotency_key : String? = nil,
          meta : Hash(String, JSON::Any)? = nil,
        )
          @prompt_wire = PreservedJson.new(JSON::Any.new(prompt))
          self.meta = meta
        end

        private def initialize(@session_id : String, @prompt_wire : PreservedJson, @idempotency_key : String?, meta : Hash(String, JSON::Any)?)
          self.meta = meta
        end

        # Builds a prompt from typed v2 content and skill references.
        def self.new(session_id : String, prompt : Array(Protocol::ContentBlock) | Array(PromptContentBlock),
                     idempotency_key : String? = nil, meta : Hash(String, JSON::Any)? = nil)
          blocks = ContentBlockArray.from_json(JSON::PullParser.new(WireFrame.encode(prompt)))
          new(session_id, blocks, idempotency_key, meta)
        end

        # Prompt blocks with their representable JSON::Any fields.
        def prompt : Array(JSON::Any)
          @prompt_wire.value.not_nil!.as_a
        end

        # Replaces the prompt blocks.
        def prompt=(value : Array(JSON::Any)) : Array(JSON::Any)
          @prompt_wire = PreservedJson.new(JSON::Any.new(value))
          value
        end

        # Exact JSON for the prompt blocks.
        def prompt_raw : RawJson
          @prompt_wire.raw
        end

        def_equals_and_hash @session_id, @prompt_wire, @idempotency_key, metadata_comparison
      end

      # Acknowledges insertion into the transcript. Foreground state and stop
      # reason are delivered by subsequent session updates.
      struct SessionPromptResult
        include JSON::Serializable
        include LosslessMetadata

        # ID of the inserted user message.
        @[JSON::Field(key: "messageId")]
        property message_id : String

        # Creates an acknowledgement for an inserted prompt.
        def initialize(@message_id : String, meta : Hash(String, JSON::Any)? = nil)
          self.meta = meta
        end

        # Decodes an acknowledgement with an unambiguous user message ID.
        def self.new(pull : JSON::PullParser) : self
          previous_def(RawJson.patch_parser(pull, required: {"messageId"}, optional: {"_meta"}))
        end
      end
    end
  end
end
