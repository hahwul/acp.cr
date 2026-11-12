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

### `#logout`

```crystal
client.logout : ACP::Protocol::LogoutResult
```

Ends the authenticated state (`logout`). Only call it when `agent_capabilities.try(&.auth).try(&.logout?)` is true. Active sessions may start failing with auth errors afterwards.

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
  mcp_servers : Array(JSON::Any) = [] of JSON::Any,
  *,
  additional_directories : Array(String)? = nil,
  system_prompt : ACP::Protocol::SystemPrompt? = nil
) : ACP::Protocol::SessionNewResult
```

Creates a new session. Transitions state to `SessionActive`.

`additional_directories` (extra absolute workspace roots) and `system_prompt` (e.g. `ACP::Protocol::SystemPrompt.append("...")`) are omitted from the request when nil. Only pass them when the agent advertises `sessionCapabilities.additionalDirectories?` / `sessionCapabilities.system_prompt?`, and only use an `override` prompt when `system_prompt.override?` is true. `session_load` and `session_resume` take the same two keyword arguments; send the full root list and the original prompt again, since neither is restored implicitly.

### `#session_load`

```crystal
client.session_load(
  session_id : String,
  cwd : String,
  mcp_servers : Array(JSON::Any) = [] of JSON::Any,
  *,
  additional_directories : Array(String)? = nil,
  system_prompt : ACP::Protocol::SystemPrompt? = nil
) : ACP::Protocol::SessionLoadResult
```

Resumes a previous session by ID.

### `#session_delete`

```crystal
client.session_delete(session_id : String) : ACP::Protocol::SessionDeleteResult
```

Removes a session from the agent's `session/list` results. Only call it when `sessionCapabilities.delete?` is true. A `-32002` answer counts as success. The client's cached active session is left alone; call `forget_session` if you deleted it.

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
  value : String | Bool,
  session_id : String? = nil
) : ACP::Protocol::SessionSetConfigOptionResult
```

Changes a configuration option in the active session. Pass a value ID for a `select` option and a `Bool` for a `boolean` option (sent with `type: "boolean"`). Agents only send boolean options to clients that advertise `session.configOptions.boolean`; read them with `ConfigOption#boolean?` and `#boolean_value`.

### `#cancel_request`

```crystal
client.cancel_request(request_id : ACP::Protocol::RequestId) : Nil
```

Sends `$/cancel_request` for one of the client's outstanding requests. The agent still answers it, usually with a `-32800` error (`JsonRpcError#request_cancelled?`). A request that hits its timeout is cancelled this way automatically. Use `session_cancel` to cancel a prompt turn.

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
| `on_create_elicitation` | `CreateElicitationParams` | `CreateElicitationResult` | Handle `elicitation/create` |
| `on_elicitation_complete` | `CompleteElicitationParams` | `Nil` | Handle the `elicitation/complete` notification (else `on_notification`) |

Set `client_capabilities.elicitation` to the modes `on_create_elicitation` handles. A request for a mode that isn't advertised there is answered with `-32602` and never reaches the handler.

Each agent request runs its handler in its own fiber, so a handler may block (e.g. waiting on the user) without holding up responses or notifications, but request handlers may run concurrently with each other and with notification callbacks. `on_update` / `on_notification` still run in arrival order on the dispatcher fiber, so they must not wait on a request of their own (for example `session_set_mode`): its response can't be read until the callback returns, and the call times out. Make such calls from another fiber (`spawn`). A request with no matching handler, including an unknown `_`-prefixed extension method, is answered with `-32601 Method not found`. A handler that raises `ACP::JsonRpcError` is answered with that error's code, message and data (for example `-32002` for a missing file or unknown terminal); any other exception becomes `-32603`.

When the agent sends `$/cancel_request` for one of its requests, a request that only reads or waits (`session/request_permission`, `elicitation/create`, `fs/read_text_file`, `terminal/output`, `terminal/wait_for_exit`) is answered at once, with the `cancelled` outcome for a permission request and `-32800` for the others. Whatever its handler returns later is dropped. Requests with side effects, such as writes, terminal creation and extension methods, are left to their handler, which still has to answer. In every case the notification is also passed to `on_notification`, so the application can stop the work.
