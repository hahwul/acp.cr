# ACP Interactive Client Example
#
# A fully-featured interactive CLI client that demonstrates the ACP
# Crystal library. This example:
#
#   1. Spawns an agent process (or connects via raw stdio)
#   2. Performs the `initialize` handshake
#   3. Optionally authenticates
#   4. Creates a new session with the current working directory
#   5. Enters an interactive loop: reads user input, sends prompts,
#      displays streamed agent responses, handles permission requests
#   6. Handles CTRL+C gracefully by sending `session/cancel`
#
# Usage:
#   crystal run examples/interactive_client.cr -- <agent-command> [args...]
#
# Examples:
#   crystal run examples/interactive_client.cr -- claude-code --stdio
#   crystal run examples/interactive_client.cr -- my-agent --mode stdio
#
# Environment variables:
#   ACP_LOG_LEVEL  — set to "debug", "info", "warn", or "error" (default: "info")
#   ACP_CWD        — override the working directory for the session (default: Dir.current)
#   ACP_TIMEOUT    — request timeout in seconds (default: 30, 0 = no timeout)
#
# Special commands in the interactive loop:
#   /quit, /exit    — exit the client
#   /cancel         — cancel the current operation
#   /mode <id>      — switch to a different mode
#   /modes          — list available modes
#   /session        — show current session info
#   /help           — show available commands

require "../src/acp"
require "log"
require "colorize"

# ─── Configuration ──────────────────────────────────────────────────

LOG_LEVEL   = ENV.fetch("ACP_LOG_LEVEL", "warn")
SESSION_CWD = ENV.fetch("ACP_CWD", Dir.current)
TIMEOUT_RAW = ENV.fetch("ACP_TIMEOUT", "30")
TIMEOUT     = TIMEOUT_RAW.to_f64?.try { |t| t > 0 ? t : nil }

# Configure logging based on the environment variable.
log_severity = case LOG_LEVEL.downcase
               when "debug" then ::Log::Severity::Debug
               when "info"  then ::Log::Severity::Info
               when "warn"  then ::Log::Severity::Warn
               when "error" then ::Log::Severity::Error
               else              ::Log::Severity::Info
               end

::Log.setup(log_severity, ::Log::IOBackend.new(io: STDERR, formatter: ::Log::ShortFormat))

# ─── Terminal Helpers ───────────────────────────────────────────────

module Term
  # Prints a styled header line.
  def self.header(text : String)
    STDERR.puts ""
    STDERR.puts text.colorize(:cyan).bold
    STDERR.puts ("─" * [text.size, 60].min).colorize(:dark_gray)
  end

  # Prints an info message to stderr (not stdout, which is for the agent).
  def self.info(text : String)
    STDERR.puts "  #{text}".colorize(:blue)
  end

  # Prints a success message.
  def self.success(text : String)
    STDERR.puts "  ✓ #{text}".colorize(:green)
  end

  # Prints a warning.
  def self.warn(text : String)
    STDERR.puts "  ⚠ #{text}".colorize(:yellow)
  end

  # Prints an error.
  def self.error(text : String)
    STDERR.puts "  ✗ #{text}".colorize(:red)
  end

  # Prints agent output (to stderr so it doesn't mix with protocol on stdout).
  def self.agent(text : String)
    STDERR.print text
  end

  # Prints a tool call status line.
  def self.tool(tool_id : String, title : String?, status : String)
    label = title || tool_id
    color = case status
            when "completed" then :green
            when "failed"    then :red
            when "pending"   then :yellow
            else                  :white
            end
    STDERR.puts "  🔧 [#{label}] #{status}".colorize(color)
  end

  # Prints a thought/reasoning block.
  def self.thought(text : String)
    STDERR.puts "  💭 #{text}".colorize(:magenta)
  end

  # Prints the prompt indicator and reads a line from the TTY.
  def self.prompt : String?
    STDERR.print "\n> ".colorize(:green).bold
    STDERR.flush

    # Read from the real terminal, not stdin (which may be piped).
    # Try /dev/tty first (works on macOS/Linux), fall back to STDIN.
    tty = begin
      File.open("/dev/tty", "r")
    rescue
      STDIN
    end

    line = tty.gets
    tty.close if tty != STDIN
    line
  end

  # Asks a yes/no question.
  def self.confirm(question : String) : Bool
    STDERR.print "  #{question} [y/N] ".colorize(:yellow)
    STDERR.flush

    tty = begin
      File.open("/dev/tty", "r")
    rescue
      STDIN
    end

    answer = tty.gets.try(&.strip.downcase) || "n"
    tty.close if tty != STDIN
    answer == "y" || answer == "yes"
  end

  # Asks the user to pick from a list of options. Returns the selected ID.
  def self.pick(question : String, options : Array({id: String, label: String})) : String?
    STDERR.puts "  #{question}".colorize(:yellow)
    options.each_with_index do |opt, i|
      STDERR.puts "    #{i + 1}) #{opt[:label]} (#{opt[:id]})".colorize(:white)
    end
    STDERR.puts "    0) Cancel".colorize(:dark_gray)
    STDERR.print "  Choice: ".colorize(:yellow)
    STDERR.flush

    tty = begin
      File.open("/dev/tty", "r")
    rescue
      STDIN
    end

    input = tty.gets.try(&.strip) || "0"
    tty.close if tty != STDIN

    idx = input.to_i? || 0
    if idx >= 1 && idx <= options.size
      options[idx - 1][:id]
    else
      nil
    end
  end
end

# ─── Validate Arguments ────────────────────────────────────────────

if ARGV.empty?
  STDERR.puts "Usage: crystal run examples/interactive_client.cr -- <agent-command> [args...]"
  STDERR.puts ""
  STDERR.puts "Examples:"
  STDERR.puts "  crystal run examples/interactive_client.cr -- claude-code --stdio"
  STDERR.puts "  crystal run examples/interactive_client.cr -- my-agent --mode stdio"
  STDERR.puts ""
  STDERR.puts "Environment variables:"
  STDERR.puts "  ACP_LOG_LEVEL  debug|info|warn|error (default: info)"
  STDERR.puts "  ACP_CWD        working directory (default: current)"
  STDERR.puts "  ACP_TIMEOUT    request timeout in seconds (default: 30)"
  exit(1)
end

agent_command = ARGV[0]
agent_args = ARGV.size > 1 ? ARGV[1..] : [] of String

# ─── Signal Handling ────────────────────────────────────────────────

# We use a channel to communicate cancel signals from the signal handler
# to the main loop. This avoids re-entrant issues with the client.
cancel_channel = Channel(Nil).new(1)
client_ref : ACP::Client? = nil
prompting = false

Signal::INT.trap do
  if prompting && (c = client_ref)
    # Send cancel signal to the main loop.
    begin
      cancel_channel.send(nil)
    rescue Channel::ClosedError
    end
  else
    STDERR.puts "\nExiting...".colorize(:yellow)
    if c = client_ref
      c.close rescue nil
    end
    exit(0)
  end
end

# ─── Main ───────────────────────────────────────────────────────────

Term.header("ACP Interactive Client v#{ACP::VERSION}")
Term.info("Agent: #{agent_command} #{agent_args.join(" ")}")
Term.info("CWD:   #{SESSION_CWD}")
Term.info("Timeout: #{TIMEOUT ? "#{TIMEOUT}s" : "none"}")

# Step 1: Spawn the agent process and create the transport.
Term.info("Spawning agent process...")

begin
  transport = ACP::ProcessTransport.new(
    agent_command,
    args: agent_args,
    chdir: SESSION_CWD
  )
rescue ex
  Term.error("Failed to spawn agent: #{ex.message}")
  exit(1)
end

# Step 2: Create the client.
client = ACP::Client.new(
  transport,
  client_name: "acp-crystal-interactive",
  client_version: ACP::VERSION,
  client_capabilities: ACP::Protocol::ClientCapabilities.new(
    fs: ACP::Protocol::FsCapabilities.new(
      read_text_file: false,
      write_text_file: false,
      list_directory: false
    ),
    terminal: false
  )
)
client.request_timeout = TIMEOUT
client_ref = client

# Set up the disconnect handler.
client.on_disconnect = -> do
  Term.warn("Connection to agent lost")
  nil
end

# Step 3: Set up the session update handler.
# This displays streamed content from the agent in real time.
current_message = IO::Memory.new
in_message = false
active_tools = Hash(String, String).new # tool_call_id => title

client.on_update = ->(update : ACP::Protocol::SessionUpdateParams) do
  case u = update.update
  when ACP::Protocol::AgentMessageStartUpdate
    in_message = true
    current_message.clear
    STDERR.puts "" # Blank line before agent response

  when ACP::Protocol::AgentMessageChunkUpdate
    Term.agent(u.content)
    current_message.print(u.content)
  when ACP::Protocol::AgentMessageEndUpdate
    in_message = false
    if reason = u.stop_reason
      unless reason == "end_turn"
        STDERR.puts ""
        Term.info("[Stop: #{reason}]")
      end
    end
    STDERR.puts "" # Newline after message

  when ACP::Protocol::ThoughtUpdate
    Term.thought(u.content)
  when ACP::Protocol::ToolCallStartUpdate
    active_tools[u.tool_call_id] = u.title || u.tool_name || u.tool_call_id
    Term.tool(u.tool_call_id, u.title || u.tool_name, u.status)
  when ACP::Protocol::ToolCallChunkUpdate
    if content = u.content
      kind_label = u.kind ? " [#{u.kind}]" : ""
      title = active_tools[u.tool_call_id]? || u.tool_call_id
      STDERR.puts "  🔧 #{title}#{kind_label}: #{content}".colorize(:dark_gray)
    end
  when ACP::Protocol::ToolCallEndUpdate
    title = active_tools.delete(u.tool_call_id) || u.tool_call_id
    Term.tool(u.tool_call_id, title, u.status)
    if err = u.error
      Term.error("  Tool error: #{err}")
    end
  when ACP::Protocol::PlanUpdate
    if title = u.title
      STDERR.puts "  📋 Plan: #{title}".colorize(:cyan)
    end
    if steps = u.steps
      steps.each_with_index do |step, i|
        status_icon = case step.status
                      when "completed"   then "✓"
                      when "in_progress" then "▶"
                      when "failed"      then "✗"
                      else                    "○"
                      end
        STDERR.puts "     #{status_icon} #{i + 1}. #{step.title}".colorize(:white)
      end
    end
    if content = u.content
      STDERR.puts "  📋 #{content}".colorize(:cyan)
    end
  when ACP::Protocol::StatusUpdate
    STDERR.puts "  ⏳ #{u.status}#{u.message ? ": #{u.message}" : ""}".colorize(:dark_gray)
  when ACP::Protocol::ErrorUpdate
    Term.error("Agent error: #{u.message}")
    if detail = u.detail
      STDERR.puts "    #{detail}".colorize(:dark_gray)
    end
  end

  nil
end

# Step 4: Set up the agent request handler (for permission requests, etc.).
client.on_agent_request = ->(method : String, params : JSON::Any) do
  case method
  when "session/request_permission"
    # Parse the permission request.
    begin
      perm_params = ACP::Protocol::RequestPermissionParams.from_json(params.to_json)

      STDERR.puts ""
      Term.header("Permission Request")

      # Show tool call info.
      tc = perm_params.tool_call
      if name = tc.tool_name
        Term.info("Tool: #{name}")
      end
      if title = tc.title
        Term.info("Action: #{title}")
      end
      if input = tc.input
        Term.info("Input: #{input.to_json}")
      end

      # Build options list for the picker.
      options = perm_params.options.map do |opt|
        {id: opt.id, label: opt.label}
      end

      selected = Term.pick("Choose an action:", options)

      if selected
        result_hash = {"outcome" => {"selected" => selected}}
        JSON.parse(result_hash.to_json)
      else
        JSON.parse(%({"outcome": "cancelled"}))
      end
    rescue ex
      Term.error("Error parsing permission request: #{ex.message}")
      JSON.parse(%({"outcome": "cancelled"}))
    end
  else
    Term.warn("Agent called unknown method: #{method}")
    Term.info("Params: #{params.to_json}")
    JSON.parse(%({"error": "Method not supported"}))
  end
end

# Step 5: Initialize the connection.
Term.info("Initializing connection...")

init_result : ACP::Protocol::InitializeResult? = nil

begin
  init_result = client.initialize_connection
  Term.success("Connected to agent")

  if ai = init_result.agent_info
    Term.info("Agent: #{ai.name} v#{ai.version}")
  end
  Term.info("Protocol version: #{init_result.protocol_version}")

  if caps = init_result.agent_capabilities
    features = [] of String
    features << "load_session" if caps.load_session
    if pc = caps.prompt_capabilities
      features << "image" if pc.image
      features << "audio" if pc.audio
      features << "file" if pc.file
    end
    Term.info("Agent capabilities: #{features.empty? ? "basic" : features.join(", ")}")
  end
rescue ex : Exception
  msg = if (vm_ex = ex.as?(ACP::VersionMismatchError))
          vm_ex.message || "Version mismatch"
        elsif (rpc_ex = ex.as?(ACP::JsonRpcError))
          "Initialize failed: [#{rpc_ex.code}] #{rpc_ex.message}"
        else
          "Initialize failed: #{ex.message}"
        end
  Term.error(msg)
  begin
    client.close
  rescue
  end
  exit(1)
end

# Step 6: Handle authentication if required.
if (ir = init_result) && (methods = ir.auth_methods)
  if methods.size > 0
    Term.header("Authentication Required")
    Term.info("Available methods: #{methods.join(", ")}")

    method_id = if methods.size == 1
                  methods[0]
                else
                  options = methods.map { |m| {id: m, label: m} }
                  Term.pick("Select authentication method:", options)
                end

    if method_id
      begin
        client.authenticate(method_id)
        Term.success("Authenticated with: #{method_id}")
      rescue ex : Exception
        Term.error("Authentication failed: #{ex.message}")
        begin
          client.close
        rescue
        end
        exit(1)
      end
    else
      Term.warn("Authentication skipped (cancelled)")
    end
  end
end

# Step 7: Create a new session.
Term.info("Creating session...")

session : ACP::Session? = nil

begin
  session = ACP::Session.create(client, cwd: SESSION_CWD)
  Term.success("Session created: #{session.not_nil!.id}")

  if modes = session.not_nil!.modes
    if modes.size > 0
      Term.info("Available modes: #{modes.map(&.id).join(", ")}")
    end
  end
rescue ex : Exception
  msg = if (rpc_ex = ex.as?(ACP::JsonRpcError))
          "Failed to create session: [#{rpc_ex.code}] #{rpc_ex.message}"
        else
          "Failed to create session: #{ex.message}"
        end
  Term.error(msg)
  begin
    client.close
  rescue
  end
  exit(1)
end

# Step 8: Interactive prompt loop.
Term.header("Interactive Session")
Term.info("Type your prompts below. Special commands:")
Term.info("  /help    — show commands")
Term.info("  /cancel  — cancel current operation")
Term.info("  /quit    — exit")
Term.info("  CTRL+C   — cancel current prompt or exit")
STDERR.puts ""

loop do
  input = Term.prompt
  break if input.nil? # EOF

  input = input.strip
  next if input.empty?

  # Handle special commands.
  case input
  when "/quit", "/exit", "/q"
    break
  when "/help", "/h"
    Term.info("Available commands:")
    Term.info("  /quit, /exit, /q  — exit the client")
    Term.info("  /cancel, /c       — cancel the current operation")
    Term.info("  /mode <id>        — switch to a different mode")
    Term.info("  /modes            — list available modes")
    Term.info("  /session, /s      — show session info")
    Term.info("  /help, /h         — show this help")
    Term.info("  Anything else     — send as a text prompt")
    next
  when "/cancel", "/c"
    s = session
    if s
      s.cancel
      Term.info("Cancel sent")
    else
      Term.warn("No active session")
    end
    next
  when "/modes"
    s = session
    if s && (modes = s.modes) && modes.size > 0
      Term.info("Available modes:")
      modes.each do |mode|
        desc = mode.description ? " — #{mode.description}" : ""
        Term.info("  #{mode.id}: #{mode.label}#{desc}")
      end
    else
      Term.info("No modes available")
    end
    next
  when "/session", "/s"
    s = session
    if s
      Term.info("Session ID: #{s.id}")
      Term.info("Client state: #{client.state}")
      if modes = s.modes
        Term.info("Modes: #{modes.map(&.id).join(", ")}")
      end
    else
      Term.warn("No active session")
    end
    next
  when .starts_with?("/mode ")
    mode_id = input.sub("/mode ", "").strip
    s = session
    if s && !mode_id.empty?
      begin
        s.set_mode(mode_id)
        Term.success("Mode set to: #{mode_id}")
      rescue ex
        Term.error("Failed to set mode: #{ex.message}")
      end
    else
      Term.warn("Usage: /mode <mode-id>")
    end
    next
  end

  # Regular text prompt — send to the agent.
  s = session
  unless s
    Term.error("No active session")
    next
  end

  prompting = true

  # Spawn a fiber to listen for cancel signals during the prompt.
  cancel_sent = false
  cancel_fiber = spawn do
    loop do
      begin
        cancel_channel.receive
        unless cancel_sent
          cancel_sent = true
          STDERR.puts ""
          Term.warn("Cancelling...")
          s.cancel rescue nil
        end
      rescue Channel::ClosedError
        break
      end
    end
  end

  begin
    result = s.prompt(input)

    unless cancel_sent
      # The update handler already printed the response content.
      # Just show the stop reason if it's interesting.
      case result.stop_reason
      when "end_turn"
        # Normal completion — no extra message needed.
      when "cancelled"
        Term.info("[Cancelled]")
      when "max_tokens"
        Term.warn("[Reached maximum token limit]")
      when "refusal"
        Term.warn("[Agent refused to respond]")
      else
        Term.info("[Stop reason: #{result.stop_reason}]")
      end
    end
  rescue ex : Exception
    if ex.is_a?(ACP::ConnectionClosedError)
      Term.error("Connection lost: #{ex.message}")
      break
    elsif ex.is_a?(ACP::RequestCancelledError)
      Term.info("[Request cancelled]")
    elsif ex.is_a?(ACP::RequestTimeoutError)
      Term.warn("[Request timed out]")
    elsif (rpc_ex = ex.as?(ACP::JsonRpcError))
      Term.error("Agent error [#{rpc_ex.code}]: #{rpc_ex.message}")
    else
      Term.error("Error: #{ex.message}")
    end
  end

  prompting = false
end

# ─── Cleanup ────────────────────────────────────────────────────────

Term.info("Shutting down...")
session.try(&.close)
client.close rescue nil

# Wait for the agent process to exit if using a process transport.
if transport.is_a?(ACP::ProcessTransport)
  begin
    status = transport.wait
    Term.info("Agent process exited with status: #{status.exit_code}")
  rescue
    # Process already terminated.
  end
end

cancel_channel.close rescue nil

Term.success("Goodbye!")
