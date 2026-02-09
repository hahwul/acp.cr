# Gemini ACP Agent Example
#
# This example demonstrates using the Gemini CLI as an ACP agent.
# It uses the `gemini --experimental-acp` command to start the agent.
#
# Prerequisites:
#   - Gemini CLI installed (`npm install -g @google/gemini-cli`)
#   - Authenticated via `gemini login` or `GEMINI_API_KEY` environment variable
#
# Usage:
#   crystal run examples/gemini_agent.cr

require "../src/acp"
require "colorize"

# 1. Prepare the agent command.
# We use 'gemini --experimental-acp' to start Gemini in ACP mode.
agent_command = "gemini"
agent_args = ["--experimental-acp"]

puts "--- Gemini ACP Agent Example ---"

# Check if gemini is installed
unless Process.find_executable(agent_command)
  STDERR.puts "Error: 'gemini' command not found. Please install it with: npm install -g @google/gemini-cli"
  exit 1
end

# 2. Spawn the process transport.
# We'll forward the agent's stderr to our stderr so we can see its logs.
transport = ACP::ProcessTransport.new(agent_command, args: agent_args)
client = ACP::Client.new(transport, client_name: "gemini-acp-example")

# 3. Set up update handler to show the streaming response.
client.on_update = ->(update : ACP::Protocol::SessionUpdateParams) {
  case u = update.update
  when ACP::Protocol::AgentMessageChunkUpdate
    print u.text
    STDOUT.flush
  when ACP::Protocol::ThoughtUpdate
    puts "
[Thinking: #{u.title}]".colorize(:magenta)
    puts u.text.colorize(:dark_gray)
  when ACP::Protocol::StatusUpdate
    puts "
[Status: #{u.status}] #{u.message}".colorize(:yellow)
  end
  nil
}

begin
  # 4. Initialize connection.
  puts "Connecting to Gemini ACP Agent..."
  client.initialize_connection

  if ai = client.agent_info
    puts "Connected to: #{ai.name} v#{ai.version}"
  end

  # 5. Create a session.
  session = ACP::Session.create(client, cwd: Dir.current)
  puts "Session #{session.id} active."

  # 6. Send a prompt.
  puts "
Prompt: 'Tell me a very short joke about Crystal programming language.'"
  print "Gemini: "
  STDOUT.flush

  result = session.prompt("Tell me a very short joke about Crystal programming language.")

  puts "

(Finished with reason: #{result.stop_reason})"
rescue ex : Exception
  STDERR.puts "An error occurred: #{ex.message}"
  if rpc_ex = ex.as?(ACP::JsonRpcError)
    STDERR.puts "RPC Error Data: #{rpc_ex.data}"
  end
ensure
  # 7. Close client (this will also terminate the gemini process).
  client.close
  puts "Disconnected."
end
