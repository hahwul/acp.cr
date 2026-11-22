# ACP Content Blocks & Tool Handling Example
#
# This example demonstrates:
#   1. Using the PromptBuilder to send mixed content (text and files)
#   2. Handling tool call updates and other session notifications
#   3. Using the automated session/prompt flow
#
# Usage:
#   crystal run examples/content_blocks.cr -- <agent-command> [args...]

require "./terminal_display"
require "colorize"

if ARGV.empty?
  ExampleTerminal.puts STDERR, "Usage: crystal run examples/content_blocks.cr -- <agent-command> [args...]"
  exit(1)
end

agent_command = ARGV[0]
agent_args = ARGV.size > 1 ? ARGV[1..] : [] of String

::Log.setup(backend: ExampleTerminal.log_backend)
agent = ExampleTerminal::Agent.new(agent_command, agent_args)
transport = agent.transport
client = ACP::Client.new(transport)

# Set up handlers before initializing
client.on_update = ->(update : ACP::Protocol::SessionUpdateParams) {
  case u = update.update
  when ACP::Protocol::AgentMessageChunkUpdate
    ExampleTerminal.print STDOUT, ExampleTerminal.text(u.text, multiline: true)
  when ACP::Protocol::AgentThoughtChunkUpdate
    ExampleTerminal.puts STDOUT, <<-MSG

      [Thought]
      MSG
      .colorize(:magenta)
    ExampleTerminal.puts STDOUT, ExampleTerminal.text(u.text, multiline: true).colorize(:dark_gray)
  when ACP::Protocol::ToolCallUpdate
    ExampleTerminal.puts STDOUT, <<-MSG

      [Tool Call: #{ExampleTerminal.text(u.title)}] Status: #{ExampleTerminal.text(u.status)}
      MSG
      .colorize(:cyan)
  when ACP::Protocol::ToolCallStatusUpdate
    ExampleTerminal.puts STDOUT, <<-MSG

      [Tool Update: #{ExampleTerminal.text(u.tool_call_id)}] Status: #{ExampleTerminal.text(u.status)}
      MSG
      .colorize(:green)
  when ACP::Protocol::StatusUpdate
    ExampleTerminal.puts STDOUT, <<-MSG

      [Status: #{ExampleTerminal.text(u.status)}] #{ExampleTerminal.text(u.message)}
      MSG
      .colorize(:yellow)
  end
  nil
}

failed = false
begin
  client.initialize_connection
  session = ACP::Session.create(client, cwd: Dir.current)

  ExampleTerminal.puts STDOUT, "Session #{ExampleTerminal.text(session.id)} started."

  # Use PromptBuilder to create a rich prompt
  prompt = ACP::PromptBuilder.new
    .text("I am sending you this source file for analysis.")
    .resource_link("src/acp.cr")
    .text("Can you summarize what the main module does?")
    .build

  ExampleTerminal.puts STDOUT, "Sending rich prompt with file attachment..."
  result = session.prompt(prompt)

  ExampleTerminal.puts STDOUT, <<-MSG

    Final Stop Reason: #{ExampleTerminal.text(result.stop_reason)}
    MSG
rescue ex : ACP::Error
  ExampleTerminal.puts STDERR, "ACP error: #{ExampleTerminal.text(ex.message)}"
  failed = true
ensure
  client.close
end
exit(1) if failed
