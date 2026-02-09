# ACP Content Blocks & Tool Handling Example
#
# This example demonstrates:
#   1. Using the PromptBuilder to send mixed content (text and files)
#   2. Handling tool call updates and other session notifications
#   3. Using the automated session/prompt flow
#
# Usage:
#   crystal run examples/content_blocks.cr -- <agent-command> [args...]

require "../src/acp"
require "colorize"

if ARGV.empty?
  STDERR.puts "Usage: crystal run examples/content_blocks.cr -- <agent-command> [args...]"
  exit(1)
end

agent_command = ARGV[0]
agent_args = ARGV.size > 1 ? ARGV[1..] : [] of String

transport = ACP::ProcessTransport.new(agent_command, args: agent_args)
client = ACP::Client.new(transport)

# Set up handlers before initializing
client.on_update = ->(update : ACP::Protocol::SessionUpdateParams) {
  case u = update.update
  when ACP::Protocol::AgentMessageChunkUpdate
    print u.text
  when ACP::Protocol::ThoughtUpdate
    puts "
[Thought: #{u.title || "Reasoning"}]".colorize(:magenta)
    puts u.text.colorize(:dark_gray)
  when ACP::Protocol::ToolCallStartUpdate
    puts "
[Tool Call: #{u.title || u.tool_name}] Status: #{u.status}".colorize(:cyan)
  when ACP::Protocol::ToolCallEndUpdate
    puts "
[Tool Done] Status: #{u.status}".colorize(:green)
  when ACP::Protocol::StatusUpdate
    puts "
[Status: #{u.status}] #{u.message}".colorize(:yellow)
  end
  nil
}

begin
  client.initialize_connection
  session = ACP::Session.create(client, cwd: Dir.current)

  puts "Session #{session.id} started."

  # Use PromptBuilder to create a rich prompt
  prompt = ACP::PromptBuilder.new
    .text("I am sending you this source file for analysis.")
    .file("src/acp.cr")
    .text("Can you summarize what the main module does?")
    .build

  puts "Sending rich prompt with file attachment..."
  result = session.prompt(prompt)

  puts "
Final Stop Reason: #{result.stop_reason}"
ensure
  client.close
end
