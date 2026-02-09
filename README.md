# ACP — Agent Client Protocol for Crystal

[![Crystal](https://img.shields.io/badge/Crystal-%3E%3D1.19.1-blue.svg)](https://crystal-lang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

An unofficial Crystal implementation of the [Agent Client Protocol (ACP)](https://github.com/anthropics/acp), which defines a JSON-RPC 2.0 based communication standard between code editors (clients) and AI coding agents.

## Features

- **Full ACP Protocol Support** — Initialize, authenticate, create sessions, send prompts, handle streaming updates, and manage permissions.
- **JSON-RPC 2.0 Compliant** — Proper request/response correlation, notification handling, and error codes.
- **Stdio Transport** — Newline-delimited JSON over stdin/stdout pipes to a spawned agent process.
- **Async Architecture** — Background dispatcher fiber routes incoming messages via Crystal channels.
- **Streaming Updates** — Real-time handling of agent message chunks, tool calls, thoughts, plans, and status changes.
- **Permission Handling** — Built-in support for `session/request_permission` agent-initiated requests.
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
    print u.content  # Stream agent text to the terminal
  when ACP::Protocol::ToolCallStartUpdate
    puts "\n🔧 #{u.title || u.tool_name} [#{u.status}]"
  when ACP::Protocol::ThoughtUpdate
    puts "💭 #{u.content}"
  end
  nil
end

# 5. Send a prompt and wait for the result
result = session.prompt("Explain this codebase in one paragraph.")
puts "\n[Done — stop reason: #{result.stop_reason}]"

# 6. Clean up
client.close
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

# Load a previous session (if agent supports it).
result = client.session_load("session-id-from-before")
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

# Close the client and transport.
client.close
```

#### Callbacks

```crystal
# Handle streaming updates from the agent.
client.on_update = ->(update : ACP::Protocol::SessionUpdateParams) do
  case u = update.update
  when ACP::Protocol::AgentMessageStartUpdate
    # New message starting
  when ACP::Protocol::AgentMessageChunkUpdate
    print u.content
  when ACP::Protocol::AgentMessageEndUpdate
    puts "" # Message complete
  when ACP::Protocol::ThoughtUpdate
    puts "💭 #{u.content}"
  when ACP::Protocol::ToolCallStartUpdate
    puts "🔧 #{u.title} [#{u.status}]"
  when ACP::Protocol::ToolCallEndUpdate
    puts "🔧 #{u.tool_call_id} → #{u.status}"
  when ACP::Protocol::PlanUpdate
    u.steps.try &.each { |s| puts "  #{s.status}: #{s.title}" }
  when ACP::Protocol::StatusUpdate
    puts "⏳ #{u.status}: #{u.message}"
  when ACP::Protocol::ErrorUpdate
    STDERR.puts "❌ #{u.message}"
  end
  nil
end

# Handle agent-initiated requests (e.g., permission prompts).
client.on_agent_request = ->(method : String, params : JSON::Any) do
  if method == "session/request_permission"
    # Return the user's choice as JSON::Any
    JSON.parse(%({"outcome": {"selected": "allow_once"}}))
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
client.auth_methods                 # => Array(String)?
client.negotiated_protocol_version  # => UInt16?
```

### `ACP::Session`

A higher-level wrapper that binds a `Client` to a specific session ID.

```crystal
# Create via factory methods
session = ACP::Session.create(client, cwd: "/my/project")
session = ACP::Session.load(client, "previous-session-id")

# Send prompts — no need to pass session_id
result = session.prompt("What does this function do?")

# Send multi-block prompts
result = session.prompt([
  ACP::Protocol::TextContentBlock.new("Explain this file:"),
  ACP::Protocol::FileContentBlock.new("/path/to/file.cr"),
].map(&.as(ACP::Protocol::ContentBlock)))

# Use the PromptBuilder DSL
result = session.prompt do |b|
  b.text("Explain this image:")
  b.image("https://example.com/screenshot.png")
  b.file("/path/to/relevant_code.cr")
end

# Cancel, change mode, inspect
session.cancel
session.set_mode("chat")
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
  .file("/src/main.cr")
  .image("https://example.com/diagram.png", "image/png")
  .image_data(base64_string, "image/jpeg")
  .audio("https://example.com/voice.mp3")
  .audio_data(base64_audio, "audio/wav")

blocks = builder.build  # => Array(ACP::Protocol::ContentBlock)
```

### Content Block Types

| Type | Class | Key Fields |
|------|-------|------------|
| `"text"` | `TextContentBlock` | `content : String` |
| `"image"` | `ImageContentBlock` | `url : String?`, `data : String?`, `mime_type : String?` |
| `"audio"` | `AudioContentBlock` | `url : String?`, `data : String?`, `mime_type : String?` |
| `"file"` | `FileContentBlock` | `path : String`, `mime_type : String?` |

All content blocks inherit from `ACP::Protocol::ContentBlock` and are deserialized automatically via the `"type"` discriminator.

### Session Update Types

| Type | Class | Description |
|------|-------|-------------|
| `"agent_message_start"` | `AgentMessageStartUpdate` | Beginning of a new agent message |
| `"agent_message_chunk"` | `AgentMessageChunkUpdate` | Streamed text chunk (append to buffer) |
| `"agent_message_end"` | `AgentMessageEndUpdate` | End of agent message |
| `"thought"` | `ThoughtUpdate` | Agent chain-of-thought / reasoning |
| `"tool_call_start"` | `ToolCallStartUpdate` | Tool invocation begun |
| `"tool_call_chunk"` | `ToolCallChunkUpdate` | Streamed tool call I/O |
| `"tool_call_end"` | `ToolCallEndUpdate` | Tool invocation completed |
| `"plan"` | `PlanUpdate` | Agent's high-level plan with steps |
| `"status"` | `StatusUpdate` | Agent status change (thinking, working, etc.) |
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
| `ACP::JsonRpcError` | JSON-RPC 2.0 error from agent |
| `ACP::SessionNotFoundError` | Referenced session doesn't exist |
| `ACP::NoActiveSessionError` | No session established yet |
| `ACP::AuthenticationError` | Authentication failed |
| `ACP::RequestTimeoutError` | Request timed out |
| `ACP::RequestCancelledError` | Request was cancelled |

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
  │◀─── session/update (start) ───────│  ┐
  │◀─── session/update (chunk) ───────│  │ Streaming
  │◀─── session/update (chunk) ───────│  │ updates
  │◀─── session/update (tool_call) ───│  │
  │                                    │  │
  │◀─── session/request_permission ───│  │ Agent asks
  │──── permission response ──────────▶│  │ for permission
  │                                    │  │
  │◀─── session/update (end) ─────────│  ┘
  │◀─── session/prompt result ────────│
  │                                    │
  │──── session/cancel ───────────────▶│  (notification, no response)
  │                                    │
```

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
        ├── capabilities.cr         # Client/Agent capability types
        ├── content_block.cr        # Content block types (text, image, audio, file)
        └── updates.cr              # Session update types
examples/
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
