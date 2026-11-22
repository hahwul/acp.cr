# Claude Code ACP Agent Example
#
# This example demonstrates using Claude Code as an ACP agent.
# Claude Code does not natively support ACP, but it can be run in ACP mode using `npx @zed-industries/claude-code-acp`.
#
# Prerequisites:
#   - Node.js and npm/npx installed
#   - Authenticated via `claude login` or have necessary API keys if required by Claude Code
#
# Usage:
#   crystal run examples/claude_code_agent.cr

require "./terminal_display"
require "colorize"

# 1. Prepare the agent command.
# We use 'npx @zed-industries/claude-code-acp' to start Claude Code in ACP mode.
agent_command = "npx"
agent_args = ["@zed-industries/claude-code-acp"]

ExampleTerminal.puts STDOUT, "--- Claude Code ACP Agent Example ---"

# Check if npx is installed
unless Process.find_executable(agent_command)
  ExampleTerminal.puts STDERR, "Error: 'npx' command not found. Please install Node.js and npm."
  exit 1
end

# 2. Spawn the process transport.
# Display the agent's diagnostics as terminal-safe text.
::Log.setup(backend: ExampleTerminal.log_backend)
agent = ExampleTerminal::Agent.new(agent_command, agent_args)
transport = agent.transport
client = ACP::Client.new(transport, client_name: "claude-code-acp-example")

# 3. Set up update handler to show the streaming response.
client.on_update = ->(update : ACP::Protocol::SessionUpdateParams) {
  case u = update.update
  when ACP::Protocol::AgentMessageChunkUpdate
    ExampleTerminal.print STDOUT, ExampleTerminal.text(u.text, multiline: true)
  when ACP::Protocol::ThoughtUpdate
    ExampleTerminal.puts STDOUT, <<-MSG

      [Thinking: #{ExampleTerminal.text(u.title)}]
      MSG
      .colorize(:magenta)
    ExampleTerminal.puts STDOUT, ExampleTerminal.text(u.text, multiline: true).colorize(:dark_gray)
  when ACP::Protocol::StatusUpdate
    ExampleTerminal.puts STDOUT, <<-MSG

      [Status: #{ExampleTerminal.text(u.status)}] #{ExampleTerminal.text(u.message)}
      MSG
      .colorize(:yellow)
  end
  nil
}

begin
  # 4. Initialize connection.
  ExampleTerminal.puts STDOUT, "Connecting to Claude Code ACP Agent..."
  client.initialize_connection

  if ai = client.agent_info
    ExampleTerminal.puts STDOUT, "Connected to: #{ExampleTerminal.text(ai.name)} v#{ExampleTerminal.text(ai.version)}"
  end

  # 5. Create a session.
  session = ACP::Session.create(client, cwd: Dir.current)
  ExampleTerminal.puts STDOUT, "Session #{ExampleTerminal.text(session.id)} active."

  # 6. Send a prompt.
  prompt_text = "Tell me a very short joke about Crystal programming language."
  ExampleTerminal.puts STDOUT, <<-MSG

    Prompt: '#{prompt_text}'
    MSG
  ExampleTerminal.print STDOUT, "Claude: "

  result = session.prompt(prompt_text)

  ExampleTerminal.puts STDOUT, <<-MSG


    (Finished with reason: #{ExampleTerminal.text(result.stop_reason)})
    MSG
rescue ex : Exception
  ExampleTerminal.puts STDERR, "An error occurred: #{ExampleTerminal.text(ex.message)}"
  if rpc_ex = ex.as?(ACP::JsonRpcError)
    ExampleTerminal.puts STDERR, "RPC Error Data: #{ExampleTerminal.text(rpc_ex.data.to_s)}"
  end
ensure
  # 7. Close client (this will also terminate the process).
  client.close
  ExampleTerminal.puts STDOUT, "Disconnected."
end
