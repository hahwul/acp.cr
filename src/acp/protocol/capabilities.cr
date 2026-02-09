# ACP Protocol — Capability Types
#
# Defines the capability structures exchanged during the `initialize`
# handshake. The client advertises what it supports (file system access,
# terminal, etc.) and the agent advertises what it can do (load sessions,
# accept images/audio in prompts, etc.).

require "json"

module ACP
  module Protocol
    # ─── Client Capabilities ──────────────────────────────────────────

    # File-system capabilities the client can provide to the agent.
    struct FsCapabilities
      include JSON::Serializable

      # Whether the client can read text files on behalf of the agent.
      @[JSON::Field(key: "readTextFile")]
      property read_text_file : Bool = false

      # Whether the client can write text files on behalf of the agent.
      @[JSON::Field(key: "writeTextFile")]
      property write_text_file : Bool = false

      # Whether the client can list directory contents.
      @[JSON::Field(key: "listDirectory")]
      property list_directory : Bool = false

      def initialize(
        @read_text_file : Bool = false,
        @write_text_file : Bool = false,
        @list_directory : Bool = false,
      )
      end
    end

    # Terminal capabilities the client can provide.
    # When represented as a simple bool in the protocol, we wrap it here
    # so that future extensions (e.g., shell type, size) are easy to add.
    struct TerminalCapabilities
      include JSON::Serializable

      # Whether the client supports creating and managing terminal sessions.
      property enabled : Bool = false

      def initialize(@enabled : Bool = false)
      end
    end

    # The full set of capabilities the client advertises to the agent
    # during the `initialize` handshake.
    struct ClientCapabilities
      include JSON::Serializable

      # File-system access capabilities. Nil means no FS support.
      property fs : FsCapabilities?

      # Terminal support. Serialized as a plain bool in the protocol.
      # We use a custom converter so the wire format stays `"terminal": true/false`.
      @[JSON::Field(key: "terminal")]
      property terminal : Bool = false

      def initialize(
        @fs : FsCapabilities? = nil,
        @terminal : Bool = false,
      )
      end
    end

    # ─── Agent Capabilities ───────────────────────────────────────────

    # Describes which prompt content types the agent can accept.
    struct PromptCapabilities
      include JSON::Serializable

      # Whether the agent accepts image content blocks.
      property image : Bool = false

      # Whether the agent accepts audio content blocks.
      property audio : Bool = false

      # Whether the agent accepts file-reference content blocks.
      property file : Bool = false

      def initialize(
        @image : Bool = false,
        @audio : Bool = false,
        @file : Bool = false,
      )
      end
    end

    # The full set of capabilities the agent advertises to the client
    # in its `initialize` response.
    struct AgentCapabilities
      include JSON::Serializable

      # Whether the agent supports loading previous sessions.
      @[JSON::Field(key: "loadSession")]
      property load_session : Bool = false

      # Describes which prompt content types the agent can accept.
      @[JSON::Field(key: "promptCapabilities")]
      property prompt_capabilities : PromptCapabilities?

      def initialize(
        @load_session : Bool = false,
        @prompt_capabilities : PromptCapabilities? = nil,
      )
      end
    end

    # ─── Info Structs ─────────────────────────────────────────────────

    # Metadata about the client, sent during `initialize`.
    struct ClientInfo
      include JSON::Serializable

      # Human-readable name of the client application.
      property name : String

      # Semantic version string of the client.
      property version : String

      def initialize(@name : String, @version : String)
      end
    end

    # Metadata about the agent, returned in the `initialize` response.
    struct AgentInfo
      include JSON::Serializable

      # Human-readable name of the agent.
      property name : String

      # Semantic version string of the agent.
      property version : String

      def initialize(@name : String, @version : String)
      end
    end

    # ─── MCP Server Reference ────────────────────────────────────────

    # Reference to an MCP (Model Context Protocol) server that the agent
    # should connect to for additional tool/context capabilities.
    struct McpServer
      include JSON::Serializable

      # The URL of the MCP server.
      property url : String

      # Optional authentication token or method for the MCP server.
      property auth : String?

      def initialize(@url : String, @auth : String? = nil)
      end
    end
  end
end
