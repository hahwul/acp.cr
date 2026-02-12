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

      def initialize(
        @read_text_file : Bool = false,
        @write_text_file : Bool = false,
      )
      end
    end

    # The full set of capabilities the client advertises to the agent
    # during the `initialize` handshake.
    # See: https://agentclientprotocol.com/protocol/initialization#client-capabilities
    struct ClientCapabilities
      include JSON::Serializable

      # File-system access capabilities. Nil means no FS support.
      property fs : FsCapabilities?

      # Whether the client supports all `terminal/*` methods.
      # Serialized as a plain bool in the protocol.
      @[JSON::Field(key: "terminal")]
      property? terminal : Bool = false

      # Extension metadata for custom capabilities.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @fs : FsCapabilities? = nil,
        @terminal : Bool = false,
        @meta : Hash(String, JSON::Any)? = nil,
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

    # Session capabilities supported by the agent.
    # As a baseline, all Agents MUST support session/new, session/prompt,
    # session/cancel, and session/update.
    # See: https://agentclientprotocol.com/protocol/initialization#session-capabilities
    struct SessionCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @meta : Hash(String, JSON::Any)? = nil,
      )
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

      # Extension metadata for custom capabilities.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @load_session : Bool = false,
        @prompt_capabilities : PromptCapabilities? = nil,
        @mcp_capabilities : McpCapabilities? = nil,
        @session_capabilities : SessionCapabilities? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
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
        obj = value.as_h
        transport_type = obj["type"]?.try(&.as_s?)

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
        value.as_a.map { |item| from_json_any(item) }
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
