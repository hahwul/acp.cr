require "./types"

module ACP
  module Protocol
    # :nodoc:
    struct ForkParams(Mcp, Option)
      include JSON::Serializable

      # Source session whose history should be copied.
      @[JSON::Field(key: "sessionId")]
      getter session_id : String

      # Absolute working directory for the fork.
      getter cwd : String

      # Optional cursor at which to fork the source transcript.
      @[JSON::Field(key: "cursorId")]
      getter cursor_id : String?

      # Full list of additional workspace roots for the fork.
      @[JSON::Field(key: "additionalDirectories")]
      getter additional_directories : Array(String)?

      # MCP servers to connect to for the fork.
      @[JSON::Field(key: "mcpServers")]
      getter mcp_servers : Array(Mcp)?

      # System-level instructions for the fork.
      @[JSON::Field(key: "systemPrompt")]
      getter system_prompt : SystemPrompt?

      # Ordered initial configuration choices for the fork.
      @[JSON::Field(key: "configOptions")]
      getter config_options : Array(Option)?

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      getter meta : Hash(String, JSON::Any)?

      # Builds a request for the whole session or an announced cursor.
      def initialize(
        @session_id : String,
        @cwd : String,
        *,
        @cursor_id : String? = nil,
        @additional_directories : Array(String)? = nil,
        @mcp_servers : Array(Mcp)? = nil,
        @system_prompt : SystemPrompt? = nil,
        @config_options : Array(Option)? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Parameters for creating a v1 session from an existing session.
    alias SessionForkParams = ForkParams(JSON::Any, InitialSessionConfigOption)

    # A newly created v1 fork and its initial configuration.
    alias SessionForkResult = SessionNewResult
  end
end
