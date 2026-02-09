# Simple ACP Client Example
#
# A minimal example demonstrating how to:
#   1. Spawn an agent process
#   2. Initialize the connection
#   3. Create a session
#   4. Send a single text prompt and get the result
#
# Usage:
#   crystal run examples/simple_client.cr -- <agent-command> [args...]

require "../src/acp"

if ARGV.empty?
  STDERR.puts "Usage: crystal run examples/simple_client.cr -- <agent-command> [args...]"
  exit(1)
end

agent_command = ARGV[0]
agent_args = ARGV.size > 1 ? ARGV[1..] : [] of String

# 1. Create a transport by spawning the agent process.
transport = ACP::ProcessTransport.new(agent_command, args: agent_args)

# 2. Create the client.
client = ACP::Client.new(transport)

begin
  # 3. Initialize the connection.
  # This performs the handshake and negotiates protocol versions.
  client.initialize_connection
  puts "Connected to agent: #{client.agent_info.try(&.name)}"

  # 4. Create a session.
  # Most interactions happen within the context of a session.
  session = ACP::Session.create(client, cwd: Dir.current)
  puts "Session created: #{session.id}"

  # 5. Send a prompt.
  # In this simple example, we'll just print updates as they come.
  client.on_update = ->(update : ACP::Protocol::SessionUpdateParams) {
    if chunk = update.update.as?(ACP::Protocol::AgentMessageChunkUpdate)
      print chunk.text
    end
    nil
  }

  puts <<-MSG

    Sending prompt: 'Hello, who are you?'
    MSG
  print "Agent response: "
  STDOUT.flush

  result = session.prompt("Hello, who are you?")
  puts <<-MSG


    Prompt finished with reason: #{result.stop_reason}
    MSG
ensure
  # 6. Cleanup.
  # Closing the client also closes the transport and terminates the agent process.
  client.close
end
