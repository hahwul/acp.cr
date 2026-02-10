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

require "../src/acp"
require "colorize"

# 1. Prepare the agent command.
# We use 'npx @zed-industries/claude-code-acp' to start Claude Code in ACP mode.
agent_command = "npx"
agent_args = ["@zed-industries/claude-code-acp"]

puts "--- Claude Code ACP Agent Example ---"

# Check if npx is installed
unless Process.find_executable(agent_command)
  STDERR.puts "Error: 'npx' command not found. Please install Node.js and npm."
  exit 1
end

# 2. Spawn the process transport.
# We'll forward the agent's stderr to our stderr so we can see its logs.
transport = ACP::ProcessTransport.new(agent_command, args: agent_args)
client = ACP::Client.new(transport, client_name: "claude-code-acp-example")

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
  puts "Connecting to Claude Code ACP Agent..."
  client.initialize_connection

  if ai = client.agent_info
    puts "Connected to: #{ai.name} v#{ai.version}"
  end

  # 5. Create a session.
  session = ACP::Session.create(client, cwd: Dir.current)
  puts "Session #{session.id} active."

  # 6. Send a prompt.
  prompt_text = "Tell me a very short joke about Crystal programming language."
  puts <<-MSG

    Prompt: '#{prompt_text}'
    MSG
  print "Claude: "
  STDOUT.flush

  result = session.prompt(prompt_text)

  puts <<-MSG


    (Finished with reason: #{result.stop_reason})
    MSG
rescue ex : Exception
  STDERR.puts "An error occurred: #{ex.message}"
  if rpc_ex = ex.as?(ACP::JsonRpcError)
    STDERR.puts "RPC Error Data: #{rpc_ex.data}"
  end
ensure
  # 7. Close client (this will also terminate the process).
  client.close
  puts "Disconnected."
end
