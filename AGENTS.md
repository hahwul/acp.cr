# AGENTS.md — Guide for AI Agents Working on acp.cr

## Project Overview

**acp.cr** is an unofficial Crystal implementation of the [Agent Client Protocol (ACP)](https://agentclientprotocol.com). It provides a JSON-RPC 2.0 based client library for communicating with AI coding agents over stdio transport.

- **Language**: Crystal (>= 1.19.1)
- **License**: MIT
- **Author**: hahwul
- **No external dependencies** — uses only the Crystal standard library.

## Repository Structure

```
src/
├── acp.cr                          # Main entry point, ACP.connect convenience method
└── acp/
    ├── version.cr                  # VERSION and PROTOCOL_VERSION constants
    ├── errors.cr                   # Custom error hierarchy (Transport, Protocol, JSON-RPC, Session, Auth)
    ├── transport.cr                # Abstract Transport, StdioTransport, ProcessTransport
    ├── client.cr                   # Core ACP::Client with JSON-RPC dispatch, typed handlers
    ├── session.cr                  # High-level ACP::Session wrapper + PromptBuilder DSL
    └── protocol/
        ├── capabilities.cr         # ClientCapabilities, AgentCapabilities, MCP server types
        ├── client_methods.cr       # fs/*, terminal/* types + AgentMethod/ClientMethod/ExtensionMethod constants
        ├── content_block.cr        # ContentBlock discriminated union (text, image, audio, resource, resource_link)
        ├── enums.cr                # StopReason, ToolKind, ToolCallStatus, Role, etc.
        ├── tool_call_content.cr    # ToolCallContent, ToolCallDiff, ToolCallTerminal, ToolCallLocation
        ├── types.cr                # All JSON-RPC method params/results, ExtRequest/ExtResponse/ExtNotification, message builders
        └── updates.cr              # SessionUpdate discriminated union (20+ update types), ContentChunk
examples/
├── simple_client.cr                # Minimal usage example
├── content_blocks.cr               # Rich prompts with multiple content types
├── gemini_agent.cr                 # Using Gemini CLI as an ACP agent
└── interactive_client.cr           # Full interactive CLI client (build target)
spec/
├── spec_helper.cr
└── acp_spec.cr                     # Comprehensive test suite with TestTransport mock
```

## Build and Test Commands

```sh
# Install dependencies
shards install

# Run all tests
crystal spec

# Run tests with verbose output
crystal spec --verbose

# Format code
crystal tool format

# Build the interactive example (defined as a target in shard.yml)
shards build

# Or build directly
crystal build examples/interactive_client.cr -o bin/acp-client

# Run the interactive client
bin/acp-client <agent-command> [args...]
# Example: bin/acp-client claude-code --stdio
```

## Architecture & Key Design Decisions

### Layered Architecture

1. **Transport Layer** (`transport.cr`) — Abstract `Transport` base with `StdioTransport` (IO pairs) and `ProcessTransport` (spawns child process). Messages are newline-delimited JSON. A background fiber reads incoming messages into a `Channel`.

2. **Client Layer** (`client.cr`) — `ACP::Client` manages the JSON-RPC 2.0 protocol: request/response correlation via integer IDs, notification dispatch, and typed handler callbacks. Uses a dispatcher fiber that routes messages from the transport channel.

3. **Session Layer** (`session.cr`) — `ACP::Session` is a convenience wrapper scoping operations to a single session ID. Includes `PromptBuilder` DSL for ergonomic content block construction.

4. **Protocol Types** (`protocol/`) — All types use `JSON::Serializable`. The `SessionUpdate` struct uses a discriminated union pattern with a `session_update` string field to determine the concrete type.

### JSON-RPC 2.0 Pattern

- Outgoing requests get monotonically increasing integer IDs.
- Response correlation uses `Hash(Int64, Channel)` keyed by request ID.
- Agent-initiated requests (e.g., `session/request_permission`) are handled via the `on_agent_request` callback.
- Notifications (no `id` field) are routed to `on_notification` or `on_update` handlers.
- Extension methods (prefixed with `_` on the wire) are supported via `ext_method` / `ext_notification` on both `Client` and `Session`.

### Typed Handler System

The client supports strongly-typed handlers for agent-to-client method calls:
- `on_read_text_file` / `on_write_text_file` — filesystem operations
- `on_create_terminal` / `on_terminal_output` / `on_release_terminal` / `on_wait_for_terminal_exit` / `on_kill_terminal` — terminal operations

These handlers automatically deserialize JSON params into typed structs.

### Error Hierarchy

```
ACP::Error
├── TransportError
│   ├── ConnectionClosedError
│   └── TransportTimeoutError
├── ProtocolError
│   ├── VersionMismatchError
│   └── InvalidStateError
├── JsonRpcError (with standard + ACP-specific error codes)
├── SessionNotFoundError
├── NoActiveSessionError
├── AuthenticationError
├── RequestTimeoutError
└── RequestCancelledError
```

### ContentChunk

The `Protocol::ContentChunk` struct wraps a typed `ContentBlock` for message chunk session updates. This matches the Rust SDK's `ContentChunk` type. The chunk update types (`AgentMessageChunkUpdate`, `UserMessageChunkUpdate`, `AgentThoughtChunkUpdate`) keep `content` as `JSON::Any` for backward compatibility but provide:
- `content_block` — attempts to parse the content as a typed `ContentBlock`.
- `to_content_chunk` — returns a `ContentChunk` wrapping the parsed content block.

### Session Config Options (Grouped)

`ConfigOption` supports both flat and grouped option values, matching the Rust SDK's `SessionConfigSelect` / `SessionConfigSelectGroup`:
- `options : Array(ConfigOptionValue)?` — flat list of values (`SessionConfigSelectOptions::Flat`).
- `groups : Array(ConfigOptionGroup)?` — grouped values (`SessionConfigSelectOptions::Grouped`).
- `grouped?` — returns true if the option uses groups.
- `all_values` — returns all values flattened across groups or flat options.
- Type aliases: `SessionConfigSelectOption`, `SessionConfigSelectGroup`, `SessionConfigOption` for Rust SDK naming parity.

### Client State Machine

`ClientState` enum: `Created → Initialized → SessionActive → Closed`

Methods enforce valid state transitions via `ensure_state`.

## Coding Conventions

- **Crystal style**: Use `crystal tool format` before committing.
- **Documentation**: All public methods and types have doc comments (`#` comments above the definition).
- **Properties**: Use `property` for mutable fields, `getter` for read-only. Use `@[JSON::Field(ignore: true)]` for fields that should not appear in JSON serialization (e.g., `ExtRequest.method`).
- **JSON mapping**: Use `JSON::Serializable` with `@[JSON::Field(key: "camelCase")]` annotations where the protocol uses camelCase.
- **Nil safety**: Crystal's strict nil checking is enforced. Use `String?` for optional protocol fields. When passing nullable values to methods expecting non-nil, provide sensible defaults (e.g., `u.status || "pending"`).
- **Aliases**: Backward-compatible aliases (e.g., `ToolCallStartUpdate = ToolCallUpdate`, `ThoughtUpdate = AgentThoughtChunkUpdate`, `SessionConfigOption = ConfigOption`) preserve API compatibility and provide naming parity with the Rust SDK.
- **Logging**: Use `ACP::Log` (scoped to `"acp.transport"`) for transport-level diagnostics. Examples use `STDERR` for UI output.
- **Fiber safety**: Crystal fibers are cooperatively scheduled on a single thread — use `Channel` for inter-fiber communication, no mutexes needed.

## Testing

Tests use Crystal's built-in `spec` framework. The test suite in `spec/acp_spec.cr` uses a `TestTransport` mock that:
- Records all sent messages in `sent_messages`
- Allows injecting responses via `inject_message` and `inject_raw`
- Simulates the full JSON-RPC request/response cycle

When adding new features:
1. Add protocol types to the appropriate file in `src/acp/protocol/`.
2. Add method name constants to `AgentMethod` or `ClientMethod` modules in `client_methods.cr`.
3. Add client methods to `src/acp/client.cr` (including `send_request_raw`/`send_notification_raw` variants for raw JSON params).
4. Add convenience wrappers to `src/acp/session.cr` if appropriate.
5. Add tests to `spec/acp_spec.cr` using `TestTransport`.
6. Run `crystal tool format` before committing.

## Environment Variables (Interactive Client)

- `ACP_LOG_LEVEL` — `debug`, `info`, `warn`, or `error` (default: `warn`)
- `ACP_CWD` — Working directory for the session (default: current directory)
- `ACP_TIMEOUT` — Request timeout in seconds (default: `30`, `0` = no timeout)

## Common Pitfalls

- **Nullable protocol fields**: Many ACP protocol fields are optional (`String?`, `Array?`). Always handle nil when passing these to methods with non-nil parameters.
- **Extension method prefix**: Extension methods use `_` prefix on the wire. Use `Protocol::ExtensionMethod.add_prefix` / `strip_prefix` rather than manual string manipulation. The `ext_method` / `ext_notification` APIs handle prefixing automatically.
- **SessionUpdate dispatch**: The `SessionUpdate` struct uses `session_update` as a discriminator. When adding new update types, register them in the `from_json_object_key` mapping in `updates.cr`.
- **Channel lifecycle**: Always handle `Channel::ClosedError` when sending/receiving on channels, as transports may close at any time.
- **Process cleanup**: `ProcessTransport#close` sends a graceful termination signal and waits 2 seconds before force-killing. Ensure `client.close` is called in all exit paths.