require "path"
require "./initialization"
require "./configuration"

module ACP
  module Protocol
    module V2
      # Parameters of the draft session/set_title request.
      alias SetSessionTitleParams = Protocol::SetSessionTitleParams

      # The title the Agent stored after setting a session title.
      alias SetSessionTitleResult = Protocol::SetSessionTitleResult

      # Checks absolute paths in the Agent's POSIX or Windows filesystem syntax.
      def self.absolute_path?(value : String) : Bool
        Path.posix(value).absolute? || Path.windows(value).absolute?
      end

      # An inclusive cursor for replaying session history.
      struct ReplayFrom
        include JSON::Serializable
        include JSON::Serializable::Unmapped

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
      end

      # A v2 MCP server with an explicit transport discriminator. Future
      # transport settings are preserved in `json_unmapped`.
      struct McpServer
        include JSON::Serializable
        include JSON::Serializable::Unmapped

        # MCP transport type such as `stdio` or `http`.
        @[JSON::Field(key: "type")]
        getter transport_type : String

        # Creates a transport definition with variant-specific fields.
        def initialize(@transport_type : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
        end

        # Encodes a standard stdio server with its required v2 discriminator.
        def self.stdio(server : Protocol::McpServerStdio) : McpServer
          new("stdio", JSON.parse(server.to_json).as_h)
        end

        # Encodes a standard HTTP server.
        def self.http(server : Protocol::McpServerHttp) : McpServer
          fields = JSON.parse(server.to_json).as_h
          fields.delete("type")
          new("http", fields)
        end

        # Typed stdio configuration when the transport is stdio.
        def stdio_config : Protocol::McpServerStdio?
          Protocol::McpServerStdio.from_json(to_json) if @transport_type == "stdio"
        rescue JSON::ParseException
          nil
        end

        # Typed HTTP configuration when the transport is HTTP.
        def http_config : Protocol::McpServerHttp?
          Protocol::McpServerHttp.from_json(to_json) if @transport_type == "http"
        rescue JSON::ParseException
          nil
        end
      end

      # Parameters for creating a v2 session.
      struct SessionNewParams
        include JSON::Serializable

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

        # Extension metadata.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates new session parameters.
        def initialize(
          @cwd : String,
          *,
          @additional_directories : Array(String)? = nil,
          @mcp_servers : Array(McpServer)? = nil,
          @system_prompt : Protocol::SystemPrompt? = nil,
          @meta : Hash(String, JSON::Any)? = nil,
        )
        end
      end

      # Parameters for attaching to an existing v2 session.
      struct SessionResumeParams
        include JSON::Serializable

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

        # Extension metadata.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates session resume parameters.
        def initialize(
          @session_id : String,
          @cwd : String,
          *,
          @replay_from : ReplayFrom? = nil,
          @additional_directories : Array(String)? = nil,
          @mcp_servers : Array(McpServer)? = nil,
          @system_prompt : Protocol::SystemPrompt? = nil,
          @meta : Hash(String, JSON::Any)? = nil,
        )
        end
      end

      # Optional configuration and slash commands returned during session setup.
      abstract struct SessionSetupResult
        include JSON::Serializable
        include ConfigOptionList
        include AvailableCommandList

        # Agent configuration, including open option variants.
        @[JSON::Field(key: "configOptions")]
        property config_options : Array(JSON::Any) = [] of JSON::Any

        # Available slash commands, including open command variants.
        @[JSON::Field(key: "availableCommands")]
        property available_commands : Array(JSON::Any) = [] of JSON::Any

        # Extension metadata.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?
      end

      # A newly created v2 session and its initial configuration.
      struct SessionNewResult < SessionSetupResult
        # Unique ID assigned by the Agent.
        @[JSON::Field(key: "sessionId")]
        property session_id : String

        # Creates a new-session result.
        def initialize(
          @session_id : String,
          @config_options : Array(JSON::Any) = [] of JSON::Any,
          @available_commands : Array(JSON::Any) = [] of JSON::Any,
          @meta : Hash(String, JSON::Any)? = nil,
        )
        end
      end

      # Configuration returned when resuming a v2 session.
      struct SessionResumeResult < SessionSetupResult
        # Creates a resume result.
        def initialize(
          @config_options : Array(JSON::Any) = [] of JSON::Any,
          @available_commands : Array(JSON::Any) = [] of JSON::Any,
          @meta : Hash(String, JSON::Any)? = nil,
        )
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
        include JSON::Serializable::Unmapped

        # Target session ID.
        @[JSON::Field(key: "sessionId")]
        property session_id : String

        # ID of the configuration option.
        @[JSON::Field(key: "configId")]
        property config_id : String

        # Value discriminator, typically `id` or `boolean`.
        @[JSON::Field(key: "type")]
        property value_type : String

        # Value, including extension variants.
        property value : JSON::Any

        # Extension metadata.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Builds a request with an explicit value type.
        def initialize(
          @session_id : String,
          @config_id : String,
          @value_type : String,
          @value : JSON::Any,
          @meta : Hash(String, JSON::Any)? = nil,
        )
        end

        # Builds a request for a select ID or boolean.
        def self.new(session_id : String, config_id : String, value : String | Bool, meta : Hash(String, JSON::Any)? = nil)
          new(session_id, config_id, value.is_a?(Bool) ? "boolean" : "id", JSON::Any.new(value), meta)
        end
      end

      # The complete configuration after a successful option change.
      struct SessionSetConfigOptionResult
        include JSON::Serializable
        include ConfigOptionList

        # All current configuration options, including extension variants.
        @[JSON::Field(key: "configOptions")]
        property config_options : Array(JSON::Any)

        # Extension metadata.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates a result containing all current configuration options.
        def initialize(@config_options : Array(JSON::Any), @meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # Parameters for inserting a user prompt into a v2 session.
      struct SessionPromptParams
        include JSON::Serializable

        # Target session ID.
        @[JSON::Field(key: "sessionId")]
        property session_id : String

        # Content blocks, preserving any custom block variants.
        property prompt : Array(JSON::Any)

        # Optional key for retrying this prompt without inserting it twice.
        @[JSON::Field(key: "idempotencyKey")]
        property idempotency_key : String?

        # Extension metadata.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Builds a prompt with raw or extension content blocks.
        def initialize(
          @session_id : String,
          @prompt : Array(JSON::Any),
          @idempotency_key : String? = nil,
          @meta : Hash(String, JSON::Any)? = nil,
        )
        end

        # Builds a prompt from standard ACP content blocks.
        def self.new(session_id : String, prompt : Array(Protocol::ContentBlock),
                     idempotency_key : String? = nil, meta : Hash(String, JSON::Any)? = nil)
          new(session_id, prompt.map { |content| JSON.parse(content.to_json) }, idempotency_key, meta)
        end
      end

      # Acknowledges insertion into the transcript. Foreground state and stop
      # reason are delivered by subsequent session updates.
      struct SessionPromptResult
        include JSON::Serializable

        # ID of the inserted user message.
        @[JSON::Field(key: "messageId")]
        property message_id : String

        # Extension metadata.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates an acknowledgement for an inserted prompt.
        def initialize(@message_id : String, @meta : Hash(String, JSON::Any)? = nil)
        end
      end
    end
  end
end
