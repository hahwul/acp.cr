# Gemini ACP Agent Example
#
# This example demonstrates using the Gemini CLI as an ACP agent.
# It uses the `gemini --acp` command to start the agent.
#
# Prerequisites:
#   - Gemini CLI installed (`npm install -g @google/gemini-cli`)
#   - Authenticated via `gemini login` or `GEMINI_API_KEY` environment variable
#
# Usage:
#   crystal run examples/gemini_agent.cr

require "./terminal_display"
require "colorize"

# 1. Prepare the agent command.
# We use 'gemini --acp' to start Gemini in ACP mode.
# (Older Gemini CLI versions used '--experimental-acp', now deprecated.)
agent_command = "gemini"
agent_args = ["--acp"]

ExampleTerminal.puts STDOUT, "--- Gemini ACP Agent Example ---"

# Check if gemini is installed
unless Process.find_executable(agent_command)
  ExampleTerminal.puts STDERR, "Error: 'gemini' command not found. Please install it with: npm install -g @google/gemini-cli"
  exit 1
end

# 2. Spawn the process transport.
# Display the agent's diagnostics as terminal-safe text.
::Log.setup(backend: ExampleTerminal.log_backend)
agent = ExampleTerminal::Agent.new(agent_command, agent_args)
transport = agent.transport
client = ACP::Client.new(transport, client_name: "gemini-acp-example")

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
  ExampleTerminal.puts STDOUT, "Connecting to Gemini ACP Agent..."
  client.initialize_connection

  if ai = client.agent_info
    ExampleTerminal.puts STDOUT, "Connected to: #{ExampleTerminal.text(ai.name)} v#{ExampleTerminal.text(ai.version)}"
  end

  # 5. Create a session.
  session = ACP::Session.create(client, cwd: Dir.current)
  ExampleTerminal.puts STDOUT, "Session #{ExampleTerminal.text(session.id)} active."

  # 6. Send a prompt.
  ExampleTerminal.puts STDOUT, <<-MSG

    Prompt: 'Tell me a very short joke about Crystal programming language.'
    MSG
  ExampleTerminal.print STDOUT, "Gemini: "

  result = session.prompt("Tell me a very short joke about Crystal programming language.")

  ExampleTerminal.puts STDOUT, <<-MSG


    (Finished with reason: #{ExampleTerminal.text(result.stop_reason)})
    MSG
rescue ex : Exception
  ExampleTerminal.puts STDERR, "An error occurred: #{ExampleTerminal.text(ex.message)}"
  if rpc_ex = ex.as?(ACP::JsonRpcError)
    ExampleTerminal.puts STDERR, "RPC Error Data: #{ExampleTerminal.text(rpc_ex.data.to_s)}"
  end
ensure
  # 7. Close client (this will also terminate the gemini process).
  client.close
  ExampleTerminal.puts STDOUT, "Disconnected."
end
