require "./types"

module ACP
  module Protocol
    # :nodoc:
    struct ForkParams(Mcp, Option)
      include JSON::Serializable
      include LosslessMetadata

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

      @[JSON::Field(key: "mcpServers")]
      @mcp_servers_wire : McpServerList(Mcp)?

      # System-level instructions for the fork.
      @[JSON::Field(key: "systemPrompt")]
      getter system_prompt : SystemPrompt?

      # Ordered initial configuration choices for the fork.
      @[JSON::Field(key: "configOptions")]
      getter config_options : Array(Option)?

      # Builds a request for the whole session or an announced cursor.
      def initialize(
        @session_id : String,
        @cwd : String,
        *,
        @cursor_id : String? = nil,
        @additional_directories : Array(String)? = nil,
        mcp_servers : Array(Mcp)? = nil,
        @system_prompt : SystemPrompt? = nil,
        @config_options : Array(Option)? = nil,
        meta : Hash(String, JSON::Any)? = nil,
      )
        @mcp_servers_wire = mcp_servers.try { |servers| McpServerList(Mcp).new(servers) }
        self.meta = meta
      end

      # MCP servers to connect to for the fork.
      def mcp_servers : Array(Mcp)?
        @mcp_servers_wire.try(&.servers)
      end

      # MCP server declarations including exact extension values.
      def mcp_servers_raw : RawJson?
        @mcp_servers_wire.try(&.raw)
      end

      # Replaces the MCP server list with exact declarations.
      def mcp_servers_raw=(servers : RawJson?) : RawJson?
        @mcp_servers_wire = servers.try { |wire| McpServerList(Mcp).new(JSON::PullParser.new(wire.json)) }
        servers
      end

      def_equals_and_hash @session_id, @cwd, @cursor_id, @additional_directories, @mcp_servers_wire, @system_prompt, @config_options, metadata_comparison
    end

    # Parameters for creating a v1 session from an existing session.
    alias SessionForkParams = ForkParams(JSON::Any, InitialSessionConfigOption)

    # A newly created v1 fork and its initial configuration.
    alias SessionForkResult = SessionNewResult
  end
end
