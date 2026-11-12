# ACP Protocol — Capability Types
#
# Defines the capability structures exchanged during the `initialize`
# handshake. The client advertises what it supports (file system access,
# terminal, etc.) and the agent advertises what it can do (load sessions,
# accept images/audio in prompts, MCP transports, etc.).
#
# Reference: https://agentclientprotocol.com/protocol/initialization

require "json"

module ACP
  module Protocol
    # ─── Client Capabilities ──────────────────────────────────────────

    # File-system capabilities the client can provide to the agent.
    # See: https://agentclientprotocol.com/protocol/file-system
    struct FsCapabilities
      include JSON::Serializable

      # Whether the client can read text files on behalf of the agent.
      # Enables the `fs/read_text_file` method.
      @[JSON::Field(key: "readTextFile")]
      property? read_text_file : Bool = false

      # Whether the client can write text files on behalf of the agent.
      # Enables the `fs/write_text_file` method.
      @[JSON::Field(key: "writeTextFile")]
      property? write_text_file : Bool = false

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @read_text_file : Bool = false,
        @write_text_file : Bool = false,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Presence (`{}`) advertises that the client handles `compaction_update`
    # and `compaction_summary_chunk` session updates (`CompactionUpdate`,
    # `CompactionSummaryChunkUpdate`).
    # See: https://agentclientprotocol.com/protocol/v1/prompt-turn#session-compaction
    struct CompactionCapabilities
      include JSON::Serializable

      def initialize
      end
    end

    # Presence (`{}`) advertises that the client handles `notice` session
    # updates (`NoticeUpdate`).
    # See: https://agentclientprotocol.com/protocol/v1/prompt-turn#session-notices
    struct NoticeCapabilities
      include JSON::Serializable

      def initialize
      end
    end

    # Presence (`{}`) advertises that the client understands `type: "boolean"`
    # config options.
    # See: https://agentclientprotocol.com/protocol/v1/session-config-options#boolean-config-options
    struct BooleanConfigOptionCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Config option types the client supports beyond the baseline `select`.
    struct SessionConfigOptionsCapabilities
      include JSON::Serializable

      # When present, the agent may send `type: "boolean"` config options.
      property boolean : BooleanConfigOptionCapabilities?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @boolean : BooleanConfigOptionCapabilities? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Session-related client capabilities (`clientCapabilities.session`).
    # Each field is opt-in: omitted or null means unsupported, and the agent
    # MUST NOT send the corresponding updates or option types.
    struct ClientSessionCapabilities
      include JSON::Serializable

      # Context compaction updates.
      property compaction : CompactionCapabilities?

      # Config option types beyond `select`.
      @[JSON::Field(key: "configOptions")]
      property config_options : SessionConfigOptionsCapabilities?

      # Live user-facing notices.
      property notices : NoticeCapabilities?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @compaction : CompactionCapabilities? = nil,
        @config_options : SessionConfigOptionsCapabilities? = nil,
        @notices : NoticeCapabilities? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Presence (`{}`) of `form` / `url` in `ElicitationCapabilities`
    # advertises that elicitation mode.
    struct ElicitationModeCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Schema names for the two mode capability objects.
    alias ElicitationFormCapabilities = ElicitationModeCapabilities
    alias ElicitationUrlCapabilities = ElicitationModeCapabilities

    # The `elicitation/create` modes the client supports. Unlike MCP, an
    # empty object advertises no mode: each mode must be present and non-null.
    # See: https://agentclientprotocol.com/protocol/v1/elicitation#checking-support
    struct ElicitationCapabilities
      include JSON::Serializable

      # Form mode support.
      property form : ElicitationFormCapabilities?

      # URL mode support.
      property url : ElicitationUrlCapabilities?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @form : ElicitationFormCapabilities? = nil,
        @url : ElicitationUrlCapabilities? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end

      # Returns true if the given `mode` ("form" or "url") is advertised.
      def supports?(mode : String?) : Bool
        case mode
        when "form" then !@form.nil?
        when "url"  then !@url.nil?
        else             false
        end
      end
    end

    # The full set of capabilities the client advertises to the agent
    # during the `initialize` handshake.
    #
    # Everything defaults to unsupported. Only advertise a capability once
    # the client actually handles it, e.g. set `elicitation` together with
    # `Client#on_create_elicitation`.
    # See: https://agentclientprotocol.com/protocol/initialization#client-capabilities
    struct ClientCapabilities
      include JSON::Serializable

      # File-system access capabilities. Nil means no FS support.
      property fs : FsCapabilities?

      # Whether the client supports all `terminal/*` methods.
      # Serialized as a plain bool in the protocol.
      @[JSON::Field(key: "terminal")]
      property? terminal : Bool = false

      # Session-related capabilities (compaction, notices, boolean config
      # options). Nil means none.
      property session : ClientSessionCapabilities?

      # Supported `elicitation/create` modes. Nil means elicitation is
      # unsupported.
      property elicitation : ElicitationCapabilities?

      # Extension metadata for custom capabilities.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @fs : FsCapabilities? = nil,
        @terminal : Bool = false,
        @meta : Hash(String, JSON::Any)? = nil,
        @session : ClientSessionCapabilities? = nil,
        @elicitation : ElicitationCapabilities? = nil,
      )
      end
    end

    # ─── Agent Capabilities ───────────────────────────────────────────

    # Describes which prompt content types the agent can accept.
    # As a baseline, all Agents MUST support ContentBlock::Text and
    # ContentBlock::ResourceLink in session/prompt requests.
    # See: https://agentclientprotocol.com/protocol/initialization#prompt-capabilities
    struct PromptCapabilities
      include JSON::Serializable

      # Whether the agent accepts image content blocks.
      property? image : Bool = false

      # Whether the agent accepts audio content blocks.
      property? audio : Bool = false

      # Whether the agent accepts embedded resource content blocks
      # (ContentBlock::Resource) in session/prompt requests.
      @[JSON::Field(key: "embeddedContext")]
      property? embedded_context : Bool = false

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @image : Bool = false,
        @audio : Bool = false,
        @embedded_context : Bool = false,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # MCP transport capabilities supported by the agent.
    # See: https://agentclientprotocol.com/protocol/session-setup#checking-transport-support
    struct McpCapabilities
      include JSON::Serializable

      # Whether the agent supports connecting to MCP servers over HTTP.
      property? http : Bool = false

      # Whether the agent supports connecting to MCP servers over SSE.
      # Note: SSE transport has been deprecated by the MCP spec.
      property? sse : Bool = false

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @http : Bool = false,
        @sse : Bool = false,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Capabilities for the session/list method.
    # Presence of this object (even empty) indicates the agent supports
    # listing sessions via `session/list`.
    # See: https://agentclientprotocol.com/protocol/session-setup#listing-sessions
    struct SessionListCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Capabilities for the session/resume method.
    # Presence of this object (even empty) indicates the agent supports
    # reconnecting to an existing session via `session/resume` without
    # replaying conversation history.
    # See: https://agentclientprotocol.com/protocol/session-setup#resuming-sessions
    struct SessionResumeCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Capabilities for the session/close method.
    # Presence of this object (even empty) indicates the agent supports
    # cancelling ongoing work and freeing resources for a session via
    # `session/close`.
    # See: https://agentclientprotocol.com/protocol/session-setup#closing-active-sessions
    struct SessionCloseCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Capabilities for the session/delete method.
    # Presence of this object (even empty) indicates the agent supports
    # removing sessions from `session/list` via `session/delete`.
    # See: https://agentclientprotocol.com/protocol/v1/session-delete
    struct SessionDeleteCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Presence of this object (even empty) indicates the agent accepts
    # `additionalDirectories` on `session/new`, `session/load` and
    # `session/resume`.
    # See: https://agentclientprotocol.com/protocol/v1/session-setup#additional-workspace-roots
    struct SessionAdditionalDirectoriesCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Presence advertises the `override` system prompt mode.
    struct SessionSystemPromptOverrideCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # System prompt modes the agent supports beyond the baseline `append`.
    struct SessionSystemPromptModeCapabilities
      include JSON::Serializable

      # When present, the agent accepts `mode: "override"`.
      property override : SessionSystemPromptOverrideCapabilities?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @override : SessionSystemPromptOverrideCapabilities? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Presence of this object (even empty) indicates the agent accepts a
    # `systemPrompt` (mode `append`) on `session/new`, `session/load` and
    # `session/resume`.
    # See: https://agentclientprotocol.com/protocol/v1/session-setup#system-prompt
    struct SessionSystemPromptCapabilities
      include JSON::Serializable

      # Additional modes the agent supports.
      property mode : SessionSystemPromptModeCapabilities?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @mode : SessionSystemPromptModeCapabilities? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end

      # Returns true if the agent accepts `mode: "override"`.
      def override? : Bool
        !@mode.try(&.override).nil?
      end
    end

    # Session capabilities supported by the agent.
    # As a baseline, all Agents MUST support session/new, session/prompt,
    # session/cancel, and session/update.
    # See: https://agentclientprotocol.com/protocol/initialization#session-capabilities
    struct SessionCapabilities
      include JSON::Serializable

      # When present (non-null), indicates the agent supports `session/list`.
      # The value is a `SessionListCapabilities` object.
      property list : SessionListCapabilities?

      # When present (non-null), indicates the agent supports `session/resume`.
      property resume : SessionResumeCapabilities?

      # When present (non-null), indicates the agent supports `session/close`.
      property close : SessionCloseCapabilities?

      # When present (non-null), indicates the agent supports `session/delete`.
      property delete : SessionDeleteCapabilities?

      # When present (non-null), the agent accepts `additionalDirectories`.
      @[JSON::Field(key: "additionalDirectories")]
      property additional_directories : SessionAdditionalDirectoriesCapabilities?

      # When present (non-null), the agent accepts a `systemPrompt`.
      @[JSON::Field(key: "systemPrompt")]
      property system_prompt : SessionSystemPromptCapabilities?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @list : SessionListCapabilities? = nil,
        @resume : SessionResumeCapabilities? = nil,
        @close : SessionCloseCapabilities? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
        @delete : SessionDeleteCapabilities? = nil,
        @additional_directories : SessionAdditionalDirectoriesCapabilities? = nil,
        @system_prompt : SessionSystemPromptCapabilities? = nil,
      )
      end

      # Returns true if the agent supports deleting sessions.
      def delete? : Bool
        !@delete.nil?
      end

      # Returns true if the agent accepts `additionalDirectories`.
      def additional_directories? : Bool
        !@additional_directories.nil?
      end

      # Returns true if the agent accepts a `systemPrompt`.
      def system_prompt? : Bool
        !@system_prompt.nil?
      end

      # Returns true if the agent supports session listing.
      def list? : Bool
        !@list.nil?
      end

      # Returns true if the agent supports resuming sessions.
      def resume? : Bool
        !@resume.nil?
      end

      # Returns true if the agent supports closing sessions.
      def close? : Bool
        !@close.nil?
      end
    end

    # Presence of this object (even empty) indicates the agent supports
    # the `logout` method.
    # See: https://agentclientprotocol.com/protocol/v1/authentication#logging-out
    struct LogoutCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Authentication-related agent capabilities (`agentCapabilities.auth`).
    struct AgentAuthCapabilities
      include JSON::Serializable

      # When present (non-null), the agent supports `logout`.
      property logout : LogoutCapabilities?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @logout : LogoutCapabilities? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end

      # Returns true if the agent supports `logout`.
      def logout? : Bool
        !@logout.nil?
      end
    end

    # The full set of capabilities the agent advertises to the client
    # in its `initialize` response.
    # See: https://agentclientprotocol.com/protocol/initialization#agent-capabilities
    struct AgentCapabilities
      include JSON::Serializable

      # Whether the agent supports loading previous sessions via `session/load`.
      @[JSON::Field(key: "loadSession")]
      property? load_session : Bool = false

      # Describes which prompt content types the agent can accept.
      @[JSON::Field(key: "promptCapabilities")]
      property prompt_capabilities : PromptCapabilities?

      # MCP transport capabilities.
      @[JSON::Field(key: "mcpCapabilities")]
      property mcp_capabilities : McpCapabilities?

      # Session capabilities beyond the baseline.
      @[JSON::Field(key: "sessionCapabilities")]
      property session_capabilities : SessionCapabilities?

      # Authentication capabilities (e.g. `logout`).
      property auth : AgentAuthCapabilities?

      # Extension metadata for custom capabilities.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @load_session : Bool = false,
        @prompt_capabilities : PromptCapabilities? = nil,
        @mcp_capabilities : McpCapabilities? = nil,
        @session_capabilities : SessionCapabilities? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
        @auth : AgentAuthCapabilities? = nil,
      )
      end
    end

    # ─── Info Structs ─────────────────────────────────────────────────

    # Metadata about the client, sent during `initialize`.
    # See: https://agentclientprotocol.com/protocol/initialization#implementation-information
    struct ClientInfo
      include JSON::Serializable

      # Intended for programmatic or logical use, but can be used as a
      # display name fallback if title isn't present.
      property name : String

      # Intended for UI and end-user contexts — optimized to be human-readable.
      # If not provided, the name should be used for display.
      property title : String?

      # Version of the implementation.
      property version : String

      def initialize(@name : String, @version : String, @title : String? = nil)
      end
    end

    # Metadata about the agent, returned in the `initialize` response.
    # See: https://agentclientprotocol.com/protocol/initialization#implementation-information
    struct AgentInfo
      include JSON::Serializable

      # Intended for programmatic or logical use, but can be used as a
      # display name fallback if title isn't present.
      property name : String

      # Intended for UI and end-user contexts — optimized to be human-readable.
      # If not provided, the name should be used for display.
      property title : String?

      # Version of the implementation.
      property version : String

      def initialize(@name : String, @version : String, @title : String? = nil)
      end

      # Returns the display-friendly name (title if available, otherwise name).
      def display_name : String
        @title || @name
      end
    end

    # ─── MCP Server References ───────────────────────────────────────

    # Environment variable to set when launching an MCP server.
    struct EnvVariable
      include JSON::Serializable

      # The name of the environment variable.
      property name : String

      # The value of the environment variable.
      property value : String

      def initialize(@name : String, @value : String)
      end
    end

    # HTTP header to set when making requests to an MCP server.
    struct HttpHeader
      include JSON::Serializable

      # The name of the HTTP header.
      property name : String

      # The value to set for the HTTP header.
      property value : String

      def initialize(@name : String, @value : String)
      end
    end

    # Configuration for connecting to an MCP server via stdio transport.
    # All Agents MUST support this transport.
    # See: https://agentclientprotocol.com/protocol/session-setup#stdio-transport
    struct McpServerStdio
      include JSON::Serializable

      # Human-readable name identifying this MCP server.
      property name : String

      # Path to the MCP server executable.
      property command : String

      # Command-line arguments to pass to the MCP server.
      property args : Array(String) = [] of String

      # Environment variables to set when launching the MCP server.
      property env : Array(EnvVariable) = [] of EnvVariable

      def initialize(
        @name : String,
        @command : String,
        @args : Array(String) = [] of String,
        @env : Array(EnvVariable) = [] of EnvVariable,
      )
      end
    end

    # Configuration for connecting to an MCP server via HTTP transport.
    # Only available when Agent capabilities indicate mcpCapabilities.http is true.
    # See: https://agentclientprotocol.com/protocol/session-setup#http-transport
    struct McpServerHttp
      include JSON::Serializable

      # Must be "http".
      @[JSON::Field(key: "type")]
      property transport_type : String = "http"

      # Human-readable name identifying this MCP server.
      property name : String

      # URL to the MCP server.
      property url : String

      # HTTP headers to set when making requests to the MCP server.
      property headers : Array(HttpHeader) = [] of HttpHeader

      def initialize(
        @name : String,
        @url : String,
        @headers : Array(HttpHeader) = [] of HttpHeader,
      )
        @transport_type = "http"
      end
    end

    # Configuration for connecting to an MCP server via SSE transport.
    # Only available when Agent capabilities indicate mcpCapabilities.sse is true.
    # Note: SSE transport has been deprecated by the MCP spec.
    # See: https://agentclientprotocol.com/protocol/session-setup#sse-transport
    struct McpServerSse
      include JSON::Serializable

      # Must be "sse".
      @[JSON::Field(key: "type")]
      property transport_type : String = "sse"

      # Human-readable name identifying this MCP server.
      property name : String

      # URL of the SSE endpoint.
      property url : String

      # HTTP headers to set when establishing the SSE connection.
      property headers : Array(HttpHeader) = [] of HttpHeader

      def initialize(
        @name : String,
        @url : String,
        @headers : Array(HttpHeader) = [] of HttpHeader,
      )
        @transport_type = "sse"
      end
    end

    # Union type representing all MCP server transport configurations.
    # Uses the "type" discriminator to determine transport kind; stdio
    # servers omit the type field (they are the default).
    #
    # For JSON deserialization, use `McpServer.from_json` which handles
    # the discriminator logic. For simplicity in Crystal, the type is
    # kept as a tagged union.
    #
    # See: https://agentclientprotocol.com/protocol/session-setup#transport-types
    alias McpServer = McpServerStdio | McpServerHttp | McpServerSse

    # Helper module for MCP server JSON parsing.
    module McpServerParser
      # Parses a JSON::Any value into the appropriate McpServer subtype.
      def self.from_json_any(value : JSON::Any) : McpServer
        transport_type = value.as_h?.try(&.["type"]?).try(&.as_s?)

        case transport_type
        when "http"
          McpServerHttp.from_json(value.to_json)
        when "sse"
          McpServerSse.from_json(value.to_json)
        else
          # Default: stdio transport (no "type" field)
          McpServerStdio.from_json(value.to_json)
        end
      end

      # Parses a JSON array of MCP servers.
      def self.array_from_json(value : JSON::Any) : Array(McpServer)
        (value.as_a? || [] of JSON::Any).map { |item| from_json_any(item) }
      end
    end

    # ─── Auth Method ──────────────────────────────────────────────────

    # Describes an available authentication method.
    # See: https://agentclientprotocol.com/protocol/initialization
    struct AuthMethod
      include JSON::Serializable

      # Unique identifier for this authentication method.
      property id : String

      # Human-readable name of the authentication method.
      property name : String

      # Optional description providing more details.
      property description : String?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @id : String,
        @name : String,
        @description : String? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end
  end
end
