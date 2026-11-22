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

require "./terminal_display"

if ARGV.empty?
  ExampleTerminal.puts STDERR, "Usage: crystal run examples/simple_client.cr -- <agent-command> [args...]"
  exit(1)
end

agent_command = ARGV[0]
agent_args = ARGV.size > 1 ? ARGV[1..] : [] of String

# 1. Create a transport by spawning the agent process.
::Log.setup(backend: ExampleTerminal.log_backend)
agent = ExampleTerminal::Agent.new(agent_command, agent_args)
transport = agent.transport

# 2. Create the client.
client = ACP::Client.new(transport)

failed = false
begin
  # 3. Initialize the connection.
  # This performs the handshake and negotiates protocol versions.
  client.initialize_connection
  ExampleTerminal.puts STDOUT, "Connected to agent: #{ExampleTerminal.text(client.agent_info.try(&.name))}"

  # 4. Create a session.
  # Most interactions happen within the context of a session.
  session = ACP::Session.create(client, cwd: Dir.current)
  ExampleTerminal.puts STDOUT, "Session created: #{ExampleTerminal.text(session.id)}"

  # 5. Send a prompt.
  # In this simple example, we'll just print updates as they come.
  client.on_update = ->(update : ACP::Protocol::SessionUpdateParams) {
    if chunk = update.update.as?(ACP::Protocol::AgentMessageChunkUpdate)
      ExampleTerminal.print STDOUT, ExampleTerminal.text(chunk.text, multiline: true)
    end
    nil
  }

  ExampleTerminal.puts STDOUT, <<-MSG

    Sending prompt: 'Hello, who are you?'
    MSG
  ExampleTerminal.print STDOUT, "Agent response: "

  result = session.prompt("Hello, who are you?")
  ExampleTerminal.puts STDOUT, <<-MSG


    Prompt finished with reason: #{ExampleTerminal.text(result.stop_reason)}
    MSG
rescue ex : ACP::Error
  ExampleTerminal.puts STDERR, "ACP error: #{ExampleTerminal.text(ex.message)}"
  failed = true
ensure
  # 6. Cleanup.
  # Closing the client also closes the transport and terminates the agent process.
  client.close
end
exit(1) if failed
