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
#   ACP_LOG_LEVEL  — set to "debug", "info", "warn", or "error" (default: "warn")
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

require "./terminal_display"
require "colorize"

# ─── Configuration ──────────────────────────────────────────────────

LOG_LEVEL   = ENV.fetch("ACP_LOG_LEVEL", "warn")
SESSION_CWD = ENV.fetch("ACP_CWD", Dir.current)
TIMEOUT_RAW = ENV.fetch("ACP_TIMEOUT", "30")
TIMEOUT     = TIMEOUT_RAW.to_f64?.try { |timeout_val| timeout_val > 0 ? timeout_val : nil }

# Configure logging based on the environment variable.
log_severity = case LOG_LEVEL.downcase
               when "debug" then ::Log::Severity::Debug
               when "info"  then ::Log::Severity::Info
               when "warn"  then ::Log::Severity::Warn
               when "error" then ::Log::Severity::Error
               else              ::Log::Severity::Warn
               end

::Log.setup(log_severity, ExampleTerminal.log_backend(STDERR))

# ─── Terminal Helpers ───────────────────────────────────────────────

module Term
  # Prints a styled header line.
  def self.header(text : String)
    ExampleTerminal.puts STDERR, ""
    heading = ExampleTerminal.text(text)
    ExampleTerminal.puts STDERR, heading.colorize(:cyan).bold
    ExampleTerminal.puts STDERR, ("─" * [heading.size, 60].min).colorize(:dark_gray)
  end

  # Prints an info message to stderr (not stdout, which is for the agent).
  def self.info(text : String)
    ExampleTerminal.puts STDERR, "  #{ExampleTerminal.text(text)}".colorize(:blue)
  end

  # Prints a success message.
  def self.success(text : String)
    ExampleTerminal.puts STDERR, "  ✓ #{ExampleTerminal.text(text)}".colorize(:green)
  end

  # Prints a warning.
  def self.warn(text : String)
    ExampleTerminal.puts STDERR, "  ⚠ #{ExampleTerminal.text(text)}".colorize(:yellow)
  end

  # Prints an error.
  def self.error(text : String)
    ExampleTerminal.puts STDERR, "  ✗ #{ExampleTerminal.text(text)}".colorize(:red)
  end

  # Prints agent output (to stderr so it doesn't mix with protocol on stdout).
  def self.agent(text : String)
    ExampleTerminal.print STDERR, ExampleTerminal.text(text, multiline: true)
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
    ExampleTerminal.puts STDERR, "  🔧 [#{ExampleTerminal.text(label)}] #{ExampleTerminal.text(status)}".colorize(color)
  end

  # Prints a thought/reasoning block.
  def self.thought(text : String)
    ExampleTerminal.puts STDERR, "  💭 #{ExampleTerminal.text(text, multiline: true)}".colorize(:magenta)
  end

  # Prints the end-of-message marker with optional stop reason.
  def self.message_end(stop_reason : String?)
    if reason = stop_reason
      unless reason == "end_turn"
        ExampleTerminal.puts STDERR, ""
        info("[Stop: #{reason}]")
      end
    end
    ExampleTerminal.puts STDERR, "" # Newline after message
  end

  # Prints a tool call chunk line.
  def self.tool_chunk(tool_call_id : String, content : String?, kind : String?, active_tools : Hash(String, String))
    if text = content
      kind_label = kind ? " [#{kind}]" : ""
      title = active_tools[tool_call_id]? || tool_call_id
      label = ExampleTerminal.text("#{title}#{kind_label}")
      ExampleTerminal.puts STDERR, "  🔧 #{label}: #{ExampleTerminal.text(text, multiline: true)}".colorize(:dark_gray)
    end
  end

  # Registers a tool call start and prints its status line.
  def self.tool_start(update : ACP::Protocol::ToolCallStartUpdate, active_tools : Hash(String, String))
    active_tools[update.tool_call_id] = update.title || update.tool_name || update.tool_call_id
    tool(update.tool_call_id, update.title || update.tool_name, update.status || "pending")
  end

  # Prints the tool call end status and any error.
  def self.tool_end(tool_call_id : String, tool_status : String, tool_error : String?, active_tools : Hash(String, String))
    title = active_tools.delete(tool_call_id) || tool_call_id
    tool(tool_call_id, title, tool_status)
    if err = tool_error
      error("  Tool error: #{err}")
    end
  end

  # Prints a plan with entries.
  def self.plan(entries : Array(ACP::Protocol::PlanEntry))
    ExampleTerminal.puts STDERR, "  📋 Plan:".colorize(:cyan)
    entries.each_with_index do |entry, idx|
      status_icon = case entry.status
                    when "completed"   then "✓"
                    when "in_progress" then "▶"
                    when "failed"      then "✗"
                    else                    "○"
                    end
      ExampleTerminal.puts STDERR, "     #{status_icon} #{idx + 1}. #{ExampleTerminal.text(entry.content)}".colorize(:white)
    end
  end

  # Prints a status update line.
  def self.status(update_status : String, message : String?)
    text = "#{update_status}#{message ? ": #{message}" : ""}"
    ExampleTerminal.puts STDERR, "  ⏳ #{ExampleTerminal.text(text)}".colorize(:dark_gray)
  end

  # Prints an agent error with optional detail.
  def self.agent_error(message : String, detail : String?)
    error("Agent error: #{message}")
    if detail_text = detail
      ExampleTerminal.puts STDERR, "    #{ExampleTerminal.text(detail_text, multiline: true)}".colorize(:dark_gray)
    end
  end

  # Prints the prompt indicator and reads a line from the TTY.
  def self.prompt : String?
    ExampleTerminal.print STDERR, "\n> ".colorize(:green).bold

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
    ExampleTerminal.print STDERR, "  #{ExampleTerminal.text(question)} [y/N] ".colorize(:yellow)

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
    ExampleTerminal.puts STDERR, "  #{ExampleTerminal.text(question)}".colorize(:yellow)
    options.each_with_index do |opt, i|
      ExampleTerminal.puts STDERR, "    #{i + 1}) #{ExampleTerminal.text(opt[:label], escape_backslashes: true)} (#{ExampleTerminal.text(opt[:id], escape_backslashes: true)})".colorize(:white)
    end
    ExampleTerminal.puts STDERR, "    0) Cancel".colorize(:dark_gray)
    ExampleTerminal.print STDERR, "  Choice: ".colorize(:yellow)

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
    end
  end
end

# ─── Validate Arguments ────────────────────────────────────────────

if ARGV.empty?
  ExampleTerminal.puts STDERR, "Usage: crystal run examples/interactive_client.cr -- <agent-command> [args...]"
  ExampleTerminal.puts STDERR, ""
  ExampleTerminal.puts STDERR, "Examples:"
  ExampleTerminal.puts STDERR, "  crystal run examples/interactive_client.cr -- claude-code --stdio"
  ExampleTerminal.puts STDERR, "  crystal run examples/interactive_client.cr -- my-agent --mode stdio"
  ExampleTerminal.puts STDERR, ""
  ExampleTerminal.puts STDERR, "Environment variables:"
  ExampleTerminal.puts STDERR, "  ACP_LOG_LEVEL  debug|info|warn|error (default: warn)"
  ExampleTerminal.puts STDERR, "  ACP_CWD        working directory (default: current)"
  ExampleTerminal.puts STDERR, "  ACP_TIMEOUT    request timeout in seconds (default: 30)"
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

Process.on_terminate do
  if prompting && client_ref
    # Send cancel signal to the main loop.
    begin
      cancel_channel.send(nil)
    rescue Channel::ClosedError
    end
  else
    ExampleTerminal.puts STDERR, "\nExiting...".colorize(:yellow)
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
  agent = ExampleTerminal::Agent.new(agent_command, agent_args, chdir: SESSION_CWD)
  transport = agent.transport
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
    ExampleTerminal.puts STDERR, "" # Blank line before agent response
  when ACP::Protocol::AgentMessageChunkUpdate
    Term.agent(u.text)
    current_message.print(u.text)
  when ACP::Protocol::AgentMessageEndUpdate
    in_message = false
    Term.message_end(u.stop_reason)
  when ACP::Protocol::ThoughtUpdate
    Term.thought(u.text)
  when ACP::Protocol::ToolCallStartUpdate
    Term.tool_start(u, active_tools)
  when ACP::Protocol::ToolCallChunkUpdate
    Term.tool_chunk(u.tool_call_id, u.content, u.kind, active_tools)
  when ACP::Protocol::ToolCallEndUpdate
    Term.tool_end(u.tool_call_id, u.status, u.error, active_tools)
  when ACP::Protocol::PlanUpdate
    Term.plan(u.entries)
  when ACP::Protocol::StatusUpdate
    Term.status(u.status, u.message)
  when ACP::Protocol::ErrorUpdate
    Term.agent_error(u.message, u.detail)
  end

  nil
end

# Step 4: Handle permission requests one at a time on stdin.
permission_prompt = Mutex.new
client.on_request_permission = ->(request : ACP::Protocol::RequestPermissionParams) do
  permission_prompt.synchronize do
    ExampleTerminal.puts STDERR, ""
    Term.header("Permission Request")

    tool = request.tool_call
    if name = tool.name || tool.tool_name
      Term.info("Tool: #{name}")
    end
    if title = tool.title
      Term.info("Action: #{title}")
    end
    if input = tool.raw_input_raw || tool.input_raw
      Term.info("Input: #{input.json}")
    end

    options = request.options.map { |option| {id: option.option_id, label: option.name} }
    if selected = Term.pick("Choose an action:", options)
      ACP::Protocol::RequestPermissionResult.selected(selected)
    else
      ACP::Protocol::RequestPermissionResult.cancelled
    end
  rescue ex
    Term.error("Error handling permission request: #{ex.message}")
    ACP::Protocol::RequestPermissionResult.cancelled
  end
end

client.on_agent_request = ->(method : String, params : JSON::Any) do
  Term.warn("Agent called unknown method: #{method}")
  Term.info("Params: #{params.to_json}")
  raise "Client does not handle method: #{method}"
end

# Step 5: Initialize the connection.
Term.info("Initializing connection...")

begin
  init_result = client.initialize_connection
  Term.success("Connected to agent")

  if ai = init_result.agent_info
    Term.info("Agent: #{ai.name} v#{ai.version}")
  end
  Term.info("Protocol version: #{init_result.protocol_version}")

  if caps = init_result.agent_capabilities
    features = [] of String
    features << "load_session" if caps.load_session?
    if pc = caps.prompt_capabilities
      features << "image" if pc.image?
      features << "audio" if pc.audio?
      features << "embedded_context" if pc.embedded_context?
    end
    Term.info("Agent capabilities: #{features.empty? ? "basic" : features.join(", ")}")
  end
rescue ex : Exception
  msg = if vm_ex = ex.as?(ACP::VersionMismatchError)
          vm_ex.message || "Version mismatch"
        elsif rpc_ex = ex.as?(ACP::JsonRpcError)
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
if (ir = init_result) && (raw_methods = ir.auth_methods) && !raw_methods.empty?
  # Parse leniently: reaching into the raw JSON (`entry.as_h["id"].as_s`)
  # raises on any agent whose authMethods entry isn't shaped exactly as
  # expected, killing the client right after a successful handshake.
  auth_methods = raw_methods.compact_map do |entry|
    ACP::Protocol::AuthMethod.from_json(entry.to_json) rescue nil
  end

  if auth_methods.empty?
    Term.warn("Agent advertised #{raw_methods.size} authentication method(s) in an unrecognized format; skipping")
  else
    if auth_methods.size < raw_methods.size
      Term.warn("Skipped #{raw_methods.size - auth_methods.size} unrecognized authentication method(s)")
    end

    Term.header("Authentication Required")
    Term.info("Available methods: #{auth_methods.map(&.name).join(", ")}")

    method_id = if auth_methods.size == 1
                  auth_methods[0].id
                else
                  options = auth_methods.map { |m| {id: m.id, label: m.name} }
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
  if s = session
    Term.success("Session created: #{s.id}")

    if modes = s.modes
      if modes.available_modes.size > 0
        Term.info("Available modes: #{modes.available_modes.map(&.id).join(", ")}")
      end
    end
  end
rescue ex : Exception
  msg = if rpc_ex = ex.as?(ACP::JsonRpcError)
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
ExampleTerminal.puts STDERR, ""

# A single long-lived listener translates CTRL+C into `session/cancel`.
#
# Spawning one of these per prompt instead would leak a fiber per turn, and
# — worse — leave several fibers competing for the one signal. Whichever
# stale fiber won owned a different `cancel_sent` flag, so the turn the user
# actually cancelled never learned about it and reported a bogus stop reason.
cancel_requested = false
current_session : ACP::Session? = nil

spawn do
  loop do
    begin
      cancel_channel.receive
    rescue Channel::ClosedError
      break
    end

    next unless prompting
    next if cancel_requested

    if active = current_session
      cancel_requested = true
      ExampleTerminal.puts STDERR, ""
      Term.warn("Cancelling...")
      active.cancel rescue nil
    end
  end
end

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
    if s && (modes = s.modes) && modes.available_modes.size > 0
      Term.info("Available modes:")
      modes.available_modes.each do |mode|
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
        Term.info("Modes: #{modes.available_modes.map(&.id).join(", ")}")
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
        s.mode = mode_id
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

  current_session = s
  cancel_requested = false
  prompting = true

  begin
    result = s.prompt(input)

    unless cancel_requested
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
    elsif rpc_ex = ex.as?(ACP::JsonRpcError)
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

if status = agent.wait
  Term.info("Agent process exited with status: #{status.exit_code}")
end

cancel_channel.close rescue nil

Term.success("Goodbye!")
