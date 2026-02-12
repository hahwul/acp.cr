# ACP — Agent Client Protocol for Crystal

An unofficial Crystal implementation of the [Agent Client Protocol (ACP)](https://agentclientprotocol.com), which defines a JSON-RPC 2.0 based communication standard between code editors (clients) and AI coding agents.

## Features

- **Full ACP Protocol Support** — Initialize, authenticate, create sessions, send prompts, handle streaming updates, and manage permissions.
- **JSON-RPC 2.0 Compliant** — Proper request/response correlation, notification handling, and error codes (including ACP-specific codes like `AUTH_REQUIRED` and `RESOURCE_NOT_FOUND`).
- **Stdio Transport** — Newline-delimited JSON over stdin/stdout pipes to a spawned agent process.
- **Async Architecture** — Background dispatcher fiber routes incoming messages via Crystal channels.
- **Streaming Updates** — Real-time handling of agent message chunks, tool calls, thoughts, plans, slash commands, mode changes, and config option updates.
- **Permission Handling** — Built-in support for `session/request_permission` agent-initiated requests.
- **Typed Client Method Handlers** — Register strongly-typed handlers for `fs/read_text_file`, `fs/write_text_file`, and all `terminal/*` methods with automatic JSON deserialization.
- **Protocol Enums** — Strongly-typed enums for `StopReason`, `ToolKind`, `ToolCallStatus`, `PermissionOptionKind`, `PlanEntryPriority`, `PlanEntryStatus`, `SessionConfigOptionCategory`, and `Role`.
- **Tool Call Content Types** — Typed structs for tool call content variants: standard content blocks, file diffs (`ToolCallDiff`), and embedded terminals (`ToolCallTerminal`), plus `ToolCallLocation` for file tracking.
- **Type-Safe** — All protocol types use `JSON::Serializable` with discriminated unions for polymorphic content.
- **Zero External Dependencies** — Uses only the Crystal standard library.
- **Ergonomic API** — High-level `Session` wrapper and `PromptBuilder` DSL on top of the low-level `Client`.

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  acp:
    github: hahwul/acp
```

Then run:

```sh
shards install
```

## Quick Start

```crystal
require "acp"

# 1. Connect to an agent process via stdio
transport = ACP::ProcessTransport.new("my-agent", ["--stdio"])
client = ACP::Client.new(transport, client_name: "my-editor")

# 2. Initialize the connection (handshake)
init_result = client.initialize_connection

# 3. Create a new session
session = ACP::Session.create(client, cwd: Dir.current)

# 4. Handle streaming updates
client.on_update = ->(update : ACP::Protocol::SessionUpdateParams) do
  case u = update.update
  when ACP::Protocol::AgentMessageChunkUpdate
    print u.text  # Stream agent text to the terminal
  when ACP::Protocol::ToolCallUpdate
    puts "\n🔧 #{u.title} [#{u.status}]"
  when ACP::Protocol::AgentThoughtChunkUpdate
    puts "💭 #{u.text}"
  end
  nil
end

# 5. Send a prompt and wait for the result
result = session.prompt("Explain this codebase in one paragraph.")
puts "\n[Done — stop reason: #{result.stop_reason}]"

# 6. Clean up
client.close
```

## Examples

Several examples are provided in the `examples/` directory to help you get started:

- `simple_client.cr` — A minimal example showing basic connection and prompting.
- `content_blocks.cr` — Demonstrates rich prompts with multiple content types (text, resource links) and tool handling.
- `claude_code_agent.cr` — Demonstrates how to use **Claude Code** as an ACP agent (via `npx`).
- `gemini_agent.cr` — Demonstrates how to use the **Gemini CLI** as an ACP agent.
- `codex_agent.cr` — Demonstrates how to use **Codex** via ACP adapter.
- `interactive_client.cr` — A full-featured interactive CLI client with streaming, tool calls, and permission handling.

### Running Examples

```sh
# Basic usage
crystal run examples/simple_client.cr -- <agent-command>

# Using Gemini CLI as an agent
# Requires: gemini CLI installed and GEMINI_API_KEY environment variable
crystal run examples/gemini_agent.cr

# Using Codex as an agent
# Requires: npm installed
crystal run examples/codex_agent.cr

# Using Claude Code as an agent
# Requires: Node.js and npm installed
crystal run examples/claude_code_agent.cr

# Rich prompt example
crystal run examples/content_blocks.cr -- my-agent --stdio
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      Your Application                   │
│                                                         │
│  ┌───────────┐   ┌─────────────┐   ┌────────────────┐   │
│  │  Session  │──▶│   Client    │──▶│   Transport    │───┼──▶ Agent Process
│  │  (high)   │   │  (core)     │   │  (stdio/pipe)  │   │     (stdin/stdout)
│  └───────────┘   └─────────────┘   └────────────────┘   │
│       │               │                    │            │
│       ▼               ▼                    ▼            │
│  PromptBuilder   Dispatcher Fiber    Reader Fiber       │
│                  (routes msgs)       (parses JSON)      │
└─────────────────────────────────────────────────────────┘
```

### Module Overview

| Module | Description |
|--------|-------------|
| `ACP::Protocol` | All JSON-RPC 2.0 and ACP schema types (params, results, content blocks, updates) |
| `ACP::Protocol::StopReason` | Enum for prompt turn stop reasons (`EndTurn`, `MaxTokens`, `Cancelled`, etc.) |
| `ACP::Protocol::ToolKind` | Enum for tool call categories (`Read`, `Edit`, `Execute`, `SwitchMode`, etc.) |
| `ACP::Protocol::ToolCallStatus` | Enum for tool call lifecycle (`Pending`, `InProgress`, `Completed`, `Failed`) |
| `ACP::Protocol::ToolCallContent` | Typed content variants for tool calls (content blocks, diffs, terminals) |
| `ACP::Protocol::ToolCallLocation` | File location tracking for tool call "follow-along" features |
| `ACP::Protocol::ClientMethod` | Constants and helpers for client-side method names (`fs/*`, `terminal/*`) |
| `ACP::Protocol::ErrorCode` | All standard JSON-RPC and ACP-specific error code constants |
| `ACP::Transport` | Abstract transport base class |
| `ACP::StdioTransport` | Newline-delimited JSON over any `IO` pair |
| `ACP::ProcessTransport` | Spawns a child process and wraps its stdin/stdout as a `StdioTransport` |
| `ACP::Client` | Core client: manages transport, request correlation, callbacks, and all ACP methods |
| `ACP::Session` | High-level session-scoped wrapper around `Client` |
| `ACP::PromptBuilder` | DSL for building arrays of content blocks ergonomically |

## API Reference

### `ACP::Client`

The main class for communicating with an ACP agent.

#### Constructor

```crystal
client = ACP::Client.new(
  transport,                          # ACP::Transport instance
  client_name: "my-app",             # Sent during initialize
  client_version: "1.0.0",           # Sent during initialize
  client_capabilities: ACP::Protocol::ClientCapabilities.new(
    fs: ACP::Protocol::FsCapabilities.new(
      read_text_file: true,
      write_text_file: true,
    ),
    terminal: false
  )
)
```

#### Lifecycle Methods

```crystal
# Perform the ACP handshake. Must be called first.
init_result = client.initialize_connection
# => ACP::Protocol::InitializeResult

# Authenticate (if agent requires it).
client.authenticate("oauth")

# Create a new session.
result = client.session_new("/path/to/project")
# => ACP::Protocol::SessionNewResult

# Load a previous session (if agent supports loadSession capability).
result = client.session_load("session-id-from-before", "/path/to/project")
# => ACP::Protocol::SessionLoadResult

# Send a text prompt.
result = client.session_prompt_text("Hello, agent!")
# => ACP::Protocol::SessionPromptResult

# Send a prompt with content blocks.
blocks = [ACP::Protocol::TextContentBlock.new("Explain this:").as(ACP::Protocol::ContentBlock)]
result = client.session_prompt(blocks)

# Cancel the current operation.
client.session_cancel

# Change session mode.
client.session_set_mode("code")

# Change a session config option.
result = client.session_set_config_option("mode", "code")
# => ACP::Protocol::SessionSetConfigOptionResult

# Close the client and transport.
client.close
```

#### Callbacks

```crystal
# Handle streaming updates from the agent.
client.on_update = ->(update : ACP::Protocol::SessionUpdateParams) do
  case u = update.update
  # ── ACP Standard Update Types ──
  when ACP::Protocol::UserMessageChunkUpdate
    print u.text  # During session/load replay
  when ACP::Protocol::AgentMessageChunkUpdate
    print u.text
  when ACP::Protocol::AgentThoughtChunkUpdate
    puts "💭 #{u.text}"
  when ACP::Protocol::ToolCallUpdate
    puts "🔧 #{u.title} [#{u.status}]"
  when ACP::Protocol::ToolCallStatusUpdate
    puts "🔧 #{u.tool_call_id} → #{u.status}"
  when ACP::Protocol::PlanUpdate
    u.entries.each { |e| puts "  #{e.status}: #{e.content}" }
  when ACP::Protocol::AvailableCommandsUpdate
    u.available_commands.each { |c| puts "  /#{c.name} — #{c.description}" }
  when ACP::Protocol::CurrentModeUpdate
    puts "Mode changed to: #{u.current_mode_id}"
  when ACP::Protocol::ConfigOptionUpdate
    puts "Config options updated"
  # ── Non-Standard Types (backward compat) ──
  when ACP::Protocol::AgentMessageStartUpdate
    # Agent message starting (non-standard)
  when ACP::Protocol::AgentMessageEndUpdate
    puts "" # Message complete (non-standard)
  when ACP::Protocol::StatusUpdate
    puts "⏳ #{u.status}: #{u.message}"
  when ACP::Protocol::ErrorUpdate
    STDERR.puts "❌ #{u.message}"
  end
  nil
end

# ── Typed Client Method Handlers (fs/*, terminal/*) ──
# Register these when advertising the corresponding capabilities.

# Handle fs/read_text_file requests from the agent.
client.on_read_text_file = ->(params : ACP::Protocol::ReadTextFileParams) do
  content = File.read(params.path)
  ACP::Protocol::ReadTextFileResult.new(content: content)
end

# Handle fs/write_text_file requests from the agent.
client.on_write_text_file = ->(params : ACP::Protocol::WriteTextFileParams) do
  File.write(params.path, params.content)
  ACP::Protocol::WriteTextFileResult.new
end

# Handle terminal/create requests from the agent.
client.on_create_terminal = ->(params : ACP::Protocol::CreateTerminalParams) do
  # ... spawn process, track terminal ...
  ACP::Protocol::CreateTerminalResult.new(terminal_id: "term_001")
end

# Other terminal handlers: on_terminal_output, on_release_terminal,
# on_wait_for_terminal_exit, on_kill_terminal

# Handle agent-initiated requests (e.g., permission prompts).
# This is the generic fallback for methods without typed handlers.
client.on_agent_request = ->(method : String, params : JSON::Any) do
  if method == "session/request_permission"
    # Return the user's choice using the ACP-spec outcome format
    JSON.parse(%({"outcome": {"outcome": "selected", "optionId": "allow-once"}}))
  else
    JSON.parse(%({}))
  end
end

# Handle non-update notifications.
client.on_notification = ->(method : String, params : JSON::Any?) do
  puts "Notification: #{method}"
  nil
end

# Handle disconnect.
client.on_disconnect = -> do
  puts "Connection lost!"
  nil
end
```

#### State Inspection

```crystal
client.state                        # => ACP::ClientState (Created, Initialized, SessionActive, Closed)
client.closed?                      # => Bool
client.session_active?              # => Bool
client.session_id                   # => String?
client.agent_capabilities           # => ACP::Protocol::AgentCapabilities?
client.agent_info                   # => ACP::Protocol::AgentInfo?
client.auth_methods                 # => Array(JSON::Any)?
client.negotiated_protocol_version  # => UInt16?
```

### `ACP::Session`

A higher-level wrapper that binds a `Client` to a specific session ID.

```crystal
# Create via factory methods
session = ACP::Session.create(client, cwd: "/my/project")
session = ACP::Session.load(client, "previous-session-id", cwd: "/my/project")

# Send prompts — no need to pass session_id
result = session.prompt("What does this function do?")

# Send multi-block prompts
result = session.prompt([
  ACP::Protocol::TextContentBlock.new("Explain this file:"),
  ACP::Protocol::ResourceLinkContentBlock.from_path("/path/to/file.cr"),
].map(&.as(ACP::Protocol::ContentBlock)))

# Use the PromptBuilder DSL
result = session.prompt do |b|
  b.text("Explain this code:")
  b.resource_link("/path/to/relevant_code.cr")
  b.resource("file:///path/to/file.py", "def hello(): pass", "text/x-python")
end

# Cancel, change mode, change config, inspect
session.cancel
session.mode = "chat"
session.set_config_option("model", "model-2")
session.id                    # => "session-uuid"
session.available_mode_ids    # => ["code", "chat"]
session.closed?               # => false
session.close                 # Mark closed (client-side only)
```

### `ACP::PromptBuilder`

Ergonomic DSL for constructing content block arrays.

```crystal
builder = ACP::PromptBuilder.new
builder
  .text("Look at this code and image:")
  .resource_link("/src/main.cr")                          # Creates a resource_link from path
  .image("base64_encoded_data", "image/png")               # Base64 image data
  .audio("base64_encoded_audio", "audio/wav")              # Base64 audio data
  .resource("file:///path/to/file.py", "code", "text/x-python")  # Embedded resource
  .resource_link("file:///doc.pdf", "doc.pdf", "application/pdf") # Resource link

blocks = builder.build  # => Array(ACP::Protocol::ContentBlock)
```

### Content Block Types

These follow the [ACP Content specification](https://agentclientprotocol.com/protocol/content), which uses the same `ContentBlock` structure as MCP.

| Type | Class | Key Fields |
|------|-------|------------|
| `"text"` | `TextContentBlock` | `text : String` |
| `"image"` | `ImageContentBlock` | `data : String`, `mime_type : String`, `uri : String?` |
| `"audio"` | `AudioContentBlock` | `data : String`, `mime_type : String` |
| `"resource"` | `ResourceContentBlock` | `resource : JSON::Any` (embedded resource with `uri`, `text`/`blob`, `mimeType`) |
| `"resource_link"` | `ResourceLinkContentBlock` | `uri : String`, `name : String`, `mime_type : String?`, `title : String?`, `description : String?`, `size : Int64?` |

All content blocks inherit from `ACP::Protocol::ContentBlock` and are deserialized automatically via the `"type"` discriminator. `FileContentBlock` is a backward-compatible alias for `ResourceLinkContentBlock`.

### Tool Call Content Types

Tool calls can produce three types of content, defined as typed structs inheriting from `ACP::Protocol::ToolCallContent`:

| Type | Class | Key Fields |
|------|-------|------------|
| `"content"` | `ToolCallContentBlock` | `content : ContentBlock` — Standard content block wrapper |
| `"diff"` | `ToolCallDiff` | `path : String`, `old_text : String?`, `new_text : String` — File modification diff |
| `"terminal"` | `ToolCallTerminal` | `terminal_id : String` — Embedded live terminal output |

Additionally, `ToolCallLocation` tracks file locations with `path : String` and `line : Int32?` for "follow-along" features.

### Protocol Enums

Strongly-typed enums for protocol constants (all serialize to/from their wire-format strings):

| Enum | Values | Description |
|------|--------|-------------|
| `StopReason` | `EndTurn`, `MaxTokens`, `MaxTurnRequests`, `Refusal`, `Cancelled` | Why a prompt turn stopped |
| `ToolKind` | `Read`, `Edit`, `Delete`, `Move`, `Search`, `Execute`, `Think`, `Fetch`, `SwitchMode`, `Other` | Tool call categories |
| `ToolCallStatus` | `Pending`, `InProgress`, `Completed`, `Failed` | Tool call lifecycle |
| `PermissionOptionKind` | `AllowOnce`, `AllowAlways`, `RejectOnce`, `RejectAlways` | Permission option types |
| `PlanEntryPriority` | `High`, `Medium`, `Low` | Plan entry importance |
| `PlanEntryStatus` | `Pending`, `InProgress`, `Completed` | Plan entry lifecycle |
| `SessionConfigOptionCategory` | `Mode`, `Model`, `ThoughtLevel`, `Other` | Config option categories |
| `Role` | `Assistant`, `User` | Conversation roles |

```crystal
# Parse from wire string
reason = ACP::Protocol::StopReason.parse("end_turn")  # => StopReason::EndTurn
reason = ACP::Protocol::StopReason.parse?("unknown")   # => nil

# Use in comparisons
if reason == ACP::Protocol::StopReason::Cancelled
  puts "Turn was cancelled"
end

# JSON round-trip
json = ACP::Protocol::ToolKind::Execute.to_json  # => "\"execute\""
ACP::Protocol::ToolKind.from_json(json)           # => ToolKind::Execute
```

### Session Update Types

These are the `session/update` notification types sent from the agent via the `sessionUpdate` discriminator.

**ACP Standard Types:**

| Type | Class | Description |
|------|-------|-------------|
| `"user_message_chunk"` | `UserMessageChunkUpdate` | User message chunk (during session/load replay) |
| `"agent_message_chunk"` | `AgentMessageChunkUpdate` | Streamed text chunk from agent |
| `"agent_thought_chunk"` | `AgentThoughtChunkUpdate` | Agent chain-of-thought / reasoning |
| `"tool_call"` | `ToolCallUpdate` | Tool invocation initiated |
| `"tool_call_update"` | `ToolCallStatusUpdate` | Tool invocation status/result update |
| `"plan"` | `PlanUpdate` | Agent execution plan with entries |
| `"available_commands_update"` | `AvailableCommandsUpdate` | Available slash commands changed |
| `"current_mode_update"` | `CurrentModeUpdate` | Session mode changed |
| `"config_option_update"` | `ConfigOptionUpdate` | Session config options updated |

**Non-Standard Types (backward compatibility):**

| Type | Class | Description |
|------|-------|-------------|
| `"agent_message_start"` | `AgentMessageStartUpdate` | Beginning of agent message |
| `"agent_message_end"` | `AgentMessageEndUpdate` | End of agent message |
| `"thought"` | `AgentThoughtChunkUpdate` | Alias for `agent_thought_chunk` |
| `"tool_call_start"` | `ToolCallUpdate` | Alias for `tool_call` |
| `"tool_call_chunk"` | `ToolCallChunkUpdate` | Streamed tool call I/O |
| `"tool_call_end"` | `ToolCallEndUpdate` | Tool invocation completed |
| `"status"` | `StatusUpdate` | Agent status change |
| `"error"` | `ErrorUpdate` | Non-fatal error report |

### Transport Options

#### `ACP::StdioTransport`

Low-level transport over any `IO` pair:

```crystal
transport = ACP::StdioTransport.new(
  reader: io_to_read_from,   # Agent's stdout
  writer: io_to_write_to,    # Agent's stdin
  buffer_size: 256            # Channel buffer (default: 256)
)
```

#### `ACP::ProcessTransport`

Spawns a child process and wires up stdio:

```crystal
transport = ACP::ProcessTransport.new(
  "claude-code",
  args: ["--stdio"],
  env: {"API_KEY" => "..."},
  chdir: "/my/project",
  stderr: STDERR,              # Where to send agent's stderr
  buffer_size: 256
)

# Additional methods:
transport.process       # => Process
transport.terminated?   # => Bool
transport.wait          # => Process::Status
```

#### `ACP.connect` (Convenience)

```crystal
client = ACP.connect(
  "my-agent",
  args: ["--stdio"],
  client_name: "my-editor",
  client_version: "1.0",
  capabilities: ACP::Protocol::ClientCapabilities.new,
  env: nil,
  chdir: nil
)
```

### Error Types

| Error | Description |
|-------|-------------|
| `ACP::Error` | Base error class |
| `ACP::TransportError` | Transport-level failure |
| `ACP::ConnectionClosedError` | Connection closed unexpectedly |
| `ACP::TransportTimeoutError` | Transport operation timed out |
| `ACP::ProtocolError` | Protocol-level issue |
| `ACP::VersionMismatchError` | Incompatible protocol versions |
| `ACP::InvalidStateError` | Wrong client state for operation |
| `ACP::JsonRpcError` | JSON-RPC 2.0 error from agent (includes `auth_required?` and `resource_not_found?` helpers) |
| `ACP::SessionNotFoundError` | Referenced session doesn't exist |
| `ACP::NoActiveSessionError` | No session established yet |
| `ACP::AuthenticationError` | Authentication failed |
| `ACP::RequestTimeoutError` | Request timed out |
| `ACP::RequestCancelledError` | Request was cancelled |

**Error Code Constants** (`ACP::Protocol::ErrorCode`):

| Constant | Code | Description |
|----------|------|-------------|
| `PARSE_ERROR` | -32700 | Invalid JSON received |
| `INVALID_REQUEST` | -32600 | Not a valid request object |
| `METHOD_NOT_FOUND` | -32601 | Method does not exist |
| `INVALID_PARAMS` | -32602 | Invalid method parameters |
| `INTERNAL_ERROR` | -32603 | Internal JSON-RPC error |
| `AUTH_REQUIRED` | -32000 | Authentication required (ACP-specific) |
| `RESOURCE_NOT_FOUND` | -32002 | Resource not found (ACP-specific) |

## Interactive Client Example

An interactive CLI client is included in `examples/interactive_client.cr`:

```sh
# Build and run
crystal run examples/interactive_client.cr -- my-agent --stdio

# With environment variables
ACP_LOG_LEVEL=debug ACP_CWD=/my/project ACP_TIMEOUT=60 \
  crystal run examples/interactive_client.cr -- my-agent --stdio
```

### Interactive Commands

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/quit`, `/exit` | Exit the client |
| `/cancel` | Cancel current operation |
| `/mode <id>` | Switch agent mode |
| `/modes` | List available modes |
| `/session` | Show session info |
| `CTRL+C` | Cancel current prompt or exit |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ACP_LOG_LEVEL` | `info` | Log level: `debug`, `info`, `warn`, `error` |
| `ACP_CWD` | Current directory | Working directory for the session |
| `ACP_TIMEOUT` | `30` | Request timeout in seconds (0 = no timeout) |

## Protocol Flow

```
Client                              Agent
  │                                    │
  │──── initialize ───────────────────▶│
  │◀─── initialize result ────────────│
  │                                    │
  │──── authenticate (optional) ──────▶│
  │◀─── authenticate result ──────────│
  │                                    │
  │──── session/new ──────────────────▶│
  │◀─── session/new result ───────────│
  │                                    │
  │──── session/prompt ───────────────▶│
  │                                    │
  │◀─── session/update (chunk) ───────│  ┐
  │◀─── session/update (chunk) ───────│  │ Streaming
  │◀─── session/update (tool_call) ───│  │ updates
  │                                    │  │
  │◀─── session/request_permission ───│  │ Agent asks
  │──── permission response ──────────▶│  │ for permission
  │                                    │  │
  │◀─── session/update (tool_update) ─│  │
  │◀─── session/update (chunk) ───────│  ┘
  │◀─── session/prompt result ────────│
  │                                    │
  │──── session/set_mode ─────────────▶│  (optional)
  │◀─── session/set_mode result ──────│
  │                                    │
  │──── session/set_config_option ────▶│  (optional)
  │◀─── session/set_config_option res ─│
  │                                    │
  │──── session/cancel ───────────────▶│  (notification, no response)
  │                                    │
```

## ACP Spec Compliance

This library implements the [Agent Client Protocol v1](https://agentclientprotocol.com) as a **client-side** library. Below is a summary of what is supported:

### Agent Methods (Client → Agent)

| Method | Status | Notes |
|--------|--------|-------|
| `initialize` | ✅ | Full protocol version negotiation and capability exchange |
| `authenticate` | ✅ | Supports credential-based authentication |
| `session/new` | ✅ | With MCP server configs (stdio, http, sse) |
| `session/load` | ✅ | With conversation replay via session/update |
| `session/prompt` | ✅ | All baseline content types supported |
| `session/cancel` | ✅ | Fire-and-forget notification |
| `session/set_mode` | ✅ | Switch between agent operating modes |
| `session/set_config_option` | ✅ | Change session configuration options |

### Client Methods (Agent → Client)

| Method | Status | Notes |
|--------|--------|-------|
| `session/request_permission` | ✅ | With auto-cancel fallback when no handler set |
| `fs/read_text_file` | ✅ | Typed handler via `on_read_text_file`, or generic `on_agent_request` fallback |
| `fs/write_text_file` | ✅ | Typed handler via `on_write_text_file`, or generic `on_agent_request` fallback |
| `terminal/create` | ✅ | Typed handler via `on_create_terminal`, or generic `on_agent_request` fallback |
| `terminal/output` | ✅ | Typed handler via `on_terminal_output`, or generic `on_agent_request` fallback |
| `terminal/release` | ✅ | Typed handler via `on_release_terminal`, or generic `on_agent_request` fallback |
| `terminal/wait_for_exit` | ✅ | Typed handler via `on_wait_for_terminal_exit`, or generic `on_agent_request` fallback |
| `terminal/kill` | ✅ | Typed handler via `on_kill_terminal`, or generic `on_agent_request` fallback |

### Session Update Notifications

| Update Type | Status |
|-------------|--------|
| `user_message_chunk` | ✅ |
| `agent_message_chunk` | ✅ |
| `agent_thought_chunk` | ✅ |
| `tool_call` | ✅ |
| `tool_call_update` | ✅ |
| `plan` | ✅ |
| `available_commands_update` | ✅ |
| `current_mode_update` | ✅ |
| `config_option_update` | ✅ |
| `config_options_update` | ✅ | Alias for `config_option_update` (spec doc variant) |

### Protocol Types

| Category | Status | Notes |
|----------|--------|-------|
| Content Blocks | ✅ | `text`, `image`, `audio`, `resource`, `resource_link` |
| Tool Call Content | ✅ | `ToolCallContentBlock`, `ToolCallDiff`, `ToolCallTerminal` |
| Tool Call Location | ✅ | `ToolCallLocation` with path and line |
| Terminal Exit Status | ✅ | `TerminalExitStatus` with exit code and signal |
| Protocol Enums | ✅ | `StopReason`, `ToolKind`, `ToolCallStatus`, `PermissionOptionKind`, `PlanEntryPriority`, `PlanEntryStatus`, `SessionConfigOptionCategory`, `Role` |
| Error Codes | ✅ | Standard JSON-RPC + ACP-specific (`AUTH_REQUIRED`, `RESOURCE_NOT_FOUND`) |
| MCP Server Config | ✅ | Stdio, HTTP, SSE transports |
| Capabilities | ✅ | Client and Agent capabilities with all spec fields |

## Development

```sh
# Run specs
crystal spec

# Run specs with verbose output
crystal spec --verbose

# Format code
crystal tool format

# Build the interactive example
crystal build examples/interactive_client.cr -o bin/acp-client
```

## Project Structure

```
src/acp/
├── acp.cr                       # Main entry point and ACP.connect convenience
├── client.cr                    # Core client with typed handler dispatch
├── errors.cr                    # Error types with ACP-specific codes
├── session.cr                   # High-level session wrapper and PromptBuilder
├── transport.cr                 # Stdio/Process transports
├── version.cr                   # Version constants
└── protocol/
    ├── capabilities.cr          # Client/Agent capabilities, MCP server configs
    ├── client_methods.cr        # fs/*, terminal/* request/response types
    ├── content_block.cr         # ContentBlock discriminated union
    ├── enums.cr                 # StopReason, ToolKind, ToolCallStatus, etc.
    ├── tool_call_content.cr     # ToolCallContent, Diff, Terminal, Location
    ├── types.cr                 # All method params/results, JSON-RPC builders
    └── updates.cr               # SessionUpdate discriminated union
```


```
src/
├── acp.cr                          # Main entry point
└── acp/
    ├── version.cr                  # Version and protocol version constants
    ├── errors.cr                   # Custom error types
    ├── transport.cr                # Transport layer (Stdio, Process)
    ├── client.cr                   # Core ACP client
    ├── session.cr                  # High-level session wrapper + PromptBuilder
    └── protocol/
        ├── types.cr                # JSON-RPC messages, method params/results
        ├── capabilities.cr         # Client/Agent capability types, MCP server types
        ├── content_block.cr        # Content block types (text, image, audio, resource, resource_link)
        └── updates.cr              # Session update types (standard + backward-compat)
examples/
├── simple_client.cr                # Minimal example
├── content_blocks.cr               # Rich prompts with multiple content types
├── gemini_agent.cr                 # Gemini CLI as ACP agent
├── codex_agent.cr                  # Codex ACP agent example
└── interactive_client.cr           # Interactive CLI client
spec/
├── spec_helper.cr
└── acp_spec.cr                     # Comprehensive test suite
```

## Contributing

1. Fork it (<https://github.com/hahwul/acp/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [hahwul](https://github.com/hahwul) - creator and maintainer

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.