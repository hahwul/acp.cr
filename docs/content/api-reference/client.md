+++
title = "Client"
description = "Core ACP client for protocol communication"
weight = 1
+++

## Overview

`ACP::Client` is the core class that manages the ACP protocol lifecycle. It handles request correlation, dispatches incoming messages via a background fiber, and provides methods for all ACP protocol operations.

## Constructor

### `.new`

```crystal
ACP::Client.new(
  transport : ACP::Transport,
  client_name : String = "acp-crystal",
  client_version : String = ACP::VERSION,
  client_capabilities : ACP::Protocol::ClientCapabilities = ACP::Protocol::ClientCapabilities.new
)
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `transport` | `Transport` | -- | The transport layer to use |
| `client_name` | `String` | `"acp-crystal"` | Client application name |
| `client_version` | `String` | `ACP::VERSION` | Client version string |
| `client_capabilities` | `ClientCapabilities` | `ClientCapabilities.new` | Advertised client capabilities |

## Lifecycle Methods

### `#initialize_connection`

```crystal
client.initialize_connection : ACP::Protocol::InitializeResult
```

Performs the ACP handshake with the agent. Transitions state from `Created` to `Initialized`. Returns agent info and capabilities.

### `#authenticate`

```crystal
client.authenticate(method_id : String) : Nil
```

Authenticates with the agent using the specified method. Call after `initialize_connection` if authentication is required.

### `#close`

```crystal
client.close : Nil
```

Closes the connection, stops the dispatcher fiber, and cleans up resources. Transitions state to `Closed`.

## Session Methods

### `#session_new`

```crystal
client.session_new(
  cwd : String,
  mcp_servers : Array(ACP::Protocol::McpServerConfig)? = nil
) : ACP::Protocol::SessionNewResult
```

Creates a new session. Transitions state to `SessionActive`.

### `#session_load`

```crystal
client.session_load(
  session_id : String,
  cwd : String,
  mcp_servers : Array(ACP::Protocol::McpServerConfig)? = nil
) : ACP::Protocol::SessionLoadResult
```

Resumes a previous session by ID.

### `#session_prompt`

```crystal
client.session_prompt(
  blocks : Array(ACP::Protocol::ContentBlock),
  session_id : String? = nil
) : ACP::Protocol::SessionPromptResult
```

Sends content blocks as a prompt to the active session.

### `#session_prompt_text`

```crystal
client.session_prompt_text(
  text : String,
  session_id : String? = nil
) : ACP::Protocol::SessionPromptResult
```

Convenience method to send a single text prompt.

### `#session_cancel`

```crystal
client.session_cancel(session_id : String? = nil) : Nil
```

Cancels an in-progress generation.

### `#session_set_mode`

```crystal
client.session_set_mode(
  mode_id : String,
  session_id : String? = nil
) : Nil
```

Switches the session to a different mode.

### `#session_set_config_option`

```crystal
client.session_set_config_option(
  config_id : String,
  value : JSON::Any::Type,
  session_id : String? = nil
) : ACP::Protocol::SessionSetConfigOptionResult
```

Changes a configuration option in the active session.

## Extension Methods

### `#ext_method`

```crystal
client.ext_method(
  method : String,
  params : Hash(String, JSON::Any::Type)? = nil,
  timeout : Float64? = nil
) : JSON::Any
```

Sends a custom extension request to the agent.

### `#ext_notification`

```crystal
client.ext_notification(
  method : String,
  params : Hash(String, JSON::Any::Type)? = nil
) : Nil
```

Sends a custom extension notification (no response expected).

## State & Inspection

| Property | Type | Description |
|----------|------|-------------|
| `state` | `ClientState` | Current state (`Created`, `Initialized`, `SessionActive`, `Closed`) |
| `closed?` | `Bool` | Whether the client is closed |
| `session_active?` | `Bool` | Whether a session is active |
| `session_id` | `String?` | Current session ID |
| `agent_capabilities` | `AgentCapabilities?` | Negotiated agent capabilities |
| `agent_info` | `AgentInfo?` | Agent metadata |
| `auth_methods` | `Array(JSON::Any)?` | Available authentication methods |
| `negotiated_protocol_version` | `UInt16?` | Negotiated protocol version |

## Configuration

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `request_timeout` | `Float64?` | `30.0` | Default request timeout in seconds |
| `prompt_timeout` | `Float64?` | `300.0` | Prompt-specific timeout (5 minutes) |

## Callbacks

| Callback | Type | Description |
|----------|------|-------------|
| `on_update` | `UpdateHandler?` | Handle streaming session updates |
| `on_agent_request` | `AgentRequestHandler?` | Handle agent-initiated requests |
| `on_notification` | `NotificationHandler?` | Handle non-update notifications |
| `on_disconnect` | `(-> Nil)?` | Called on connection loss |

## Typed Client Method Handlers

| Handler | Params Type | Result Type | Description |
|---------|-------------|-------------|-------------|
| `on_read_text_file` | `ReadTextFileParams` | `ReadTextFileResult` | Handle `fs/read_text_file` |
| `on_write_text_file` | `WriteTextFileParams` | `WriteTextFileResult` | Handle `fs/write_text_file` |
| `on_create_terminal` | `CreateTerminalParams` | `CreateTerminalResult` | Handle `terminal/create` |
| `on_terminal_output` | `TerminalOutputParams` | `TerminalOutputResult` | Handle `terminal/output` |
| `on_release_terminal` | `ReleaseTerminalParams` | `ReleaseTerminalResult` | Handle `terminal/release` |
| `on_wait_for_terminal_exit` | `WaitForTerminalExitParams` | `WaitForTerminalExitResult` | Handle `terminal/wait_for_exit` |
| `on_kill_terminal` | `KillTerminalParams` | `KillTerminalResult` | Handle `terminal/kill` |
