# ACP — Agent Client Protocol for Crystal
#
# A Crystal implementation of the Agent Client Protocol (ACP), which
# defines a JSON-RPC 2.0 based communication standard between code
# editors (clients) and AI coding agents.
#
# ## Quick Start
#
#   ```
# require "acp"
#
# # Spawn an agent process and connect via stdio
# transport = ACP::ProcessTransport.new("my-agent", ["--stdio"])
# client = ACP::Client.new(transport, client_name: "my-editor")
#
# # Initialize the connection
# init_result = client.initialize_connection
#
# # Create a new session
# session = ACP::Session.create(client, cwd: Dir.current)
#
# # Set up an update handler for streaming responses
# client.on_update = ->(update : ACP::Protocol::SessionUpdateParams) do
#   case u = update.update
#   when ACP::Protocol::AgentMessageChunkUpdate
#     print u.content
#   end
#   nil
# end
#
# # Send a prompt
# result = session.prompt("Hello, agent!")
# puts "\n[Stop reason: #{result.stop_reason}]"
#
# # Clean up
# client.close
#   ```
#
# ## Architecture
#
# - `ACP::Protocol` — All JSON-RPC 2.0 and ACP schema types
#   - `Protocol::ContentBlock` — Prompt content (text, image, audio, file)
#   - `Protocol::SessionUpdate` — Streamed update types from the agent
#   - `Protocol::*Params / *Result` — Method parameter and result types
# - `ACP::Transport` — Abstract transport layer
#   - `ACP::StdioTransport` — Newline-delimited JSON over IO pairs
#   - `ACP::ProcessTransport` — Spawns a child process with stdio pipes
# - `ACP::Client` — Main client class with full protocol support
# - `ACP::Session` — Higher-level session-scoped convenience wrapper
# - `ACP::PromptBuilder` — DSL for constructing prompt content blocks

require "./acp/version"
require "./acp/errors"
require "./acp/protocol/enums"
require "./acp/protocol/capabilities"
require "./acp/protocol/content_block"
require "./acp/protocol/tool_call_content"
require "./acp/protocol/updates"
require "./acp/protocol/types"
require "./acp/protocol/client_methods"
require "./acp/transport"
require "./acp/client"
require "./acp/session"

module ACP
  # The default protocol version this library implements.
  # Re-exported here for convenience; canonical definition is in version.cr.

  # Shortcut to create a client connected to a local agent process via stdio.
  #
  # - `command` — the agent executable path or name.
  # - `args` — command-line arguments for the agent.
  # - `client_name` — name to identify this client during initialization.
  # - `client_version` — version string for the client.
  # - `capabilities` — client capabilities to advertise.
  # - `env` — optional environment variables for the agent process.
  # - `chdir` — optional working directory for the agent process.
  #
  # Returns an initialized `ACP::Client` connected to the spawned agent.
  # The caller is responsible for calling `client.close` when done.
  def self.connect(
    command : String,
    args : Array(String) = [] of String,
    client_name : String = "acp-crystal",
    client_version : String = VERSION,
    capabilities : Protocol::ClientCapabilities = Protocol::ClientCapabilities.new,
    env : Process::Env = nil,
    chdir : String? = nil,
  ) : Client
    transport = ProcessTransport.new(
      command,
      args: args,
      env: env,
      chdir: chdir
    )

    Client.new(
      transport,
      client_name: client_name,
      client_version: client_version,
      client_capabilities: capabilities
    )
  end
end
