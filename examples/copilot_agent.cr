# Copilot ACP Agent Example
#
# This example demonstrates using the GitHub Copilot CLI as an ACP agent.
# It uses the `copilot --acp --stdio` command to start the agent.
#
# Prerequisites:
#   - GitHub Copilot CLI installed (https://docs.github.com/en/copilot/managing-copilot/configure-personal-settings/installing-the-github-copilot-extension-for-your-cli)
#   - Authenticated via `gh auth login` with Copilot access
#
# Usage:
#   crystal run examples/copilot_agent.cr

require "../src/acp"
require "colorize"

# 1. Prepare the agent command.
# We use 'copilot --acp --stdio' to start Copilot CLI in ACP stdio mode.
agent_command = "copilot"
agent_args = ["--acp", "--stdio"]

puts "--- Copilot ACP Agent Example ---"

# Check if copilot is installed
unless Process.find_executable(agent_command)
  STDERR.puts "Error: 'copilot' command not found. Please install the GitHub Copilot CLI extension."
  STDERR.puts "See: https://docs.github.com/en/copilot/managing-copilot/configure-personal-settings/installing-the-github-copilot-extension-for-your-cli"
  exit 1
end

# 2. Spawn the process transport.
# We'll forward the agent's stderr to our stderr so we can see its logs.
transport = ACP::ProcessTransport.new(agent_command, args: agent_args)
client = ACP::Client.new(transport, client_name: "copilot-acp-example")

# 3. Set up update handler to show the streaming response.
client.on_update = ->(update : ACP::Protocol::SessionUpdateParams) {
  case u = update.update
  when ACP::Protocol::AgentMessageChunkUpdate
    print u.text
    STDOUT.flush
  when ACP::Protocol::ThoughtUpdate
    puts <<-MSG

      [Thinking: #{u.title}]
      MSG
      .colorize(:magenta)
    puts u.text.colorize(:dark_gray)
  when ACP::Protocol::StatusUpdate
    puts <<-MSG

      [Status: #{u.status}] #{u.message}
      MSG
      .colorize(:yellow)
  end
  nil
}

begin
  # 4. Initialize connection.
  puts "Connecting to Copilot ACP Agent..."
  client.initialize_connection

  if ai = client.agent_info
    puts "Connected to: #{ai.name} v#{ai.version}"
  end

  # 5. Create a session.
  session = ACP::Session.create(client, cwd: Dir.current)
  puts "Session #{session.id} active."

  # 6. Send a prompt.
  puts <<-MSG

    Prompt: 'Tell me a very short joke about Crystal programming language.'
    MSG
  print "Copilot: "
  STDOUT.flush

  result = session.prompt("Tell me a very short joke about Crystal programming language.")

  puts <<-MSG


    (Finished with reason: #{result.stop_reason})
    MSG
rescue ex : Exception
  STDERR.puts "An error occurred: #{ex.message}"
  if rpc_ex = ex.as?(ACP::JsonRpcError)
    STDERR.puts "RPC Error Data: #{rpc_ex.data}"
  end
ensure
  # 7. Close client (this will also terminate the copilot process).
  client.close
  puts "Disconnected."
end
