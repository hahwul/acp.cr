+++
title = "Client"
description = "Core ACP client for protocol communication"
weight = 1
+++

## Overview

`ACP::Client` manages the ACP v1 lifecycle. It handles request correlation and dispatches incoming messages via a background fiber.

## ACP v2 Preview

Use `ACP::V2::Client` with an existing transport, or `ACP::V2.connect` to start
and initialize an Agent subprocess. Use `ACP::Client` or `ACP.connect` for
v1 Agents. A v2 connection raises `VersionMismatchError` when the Agent
selects a different version.

```crystal
client = ACP::V2::Client.new(ACP::ProcessTransport.new("my-agent"))
client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
  if chunk = note.update.typed.as?(ACP::Protocol::V2::MessageChunkUpdate)
    print chunk.to_content_chunk.try(&.text)
  end
  nil
end

begin
  client.initialize_connection
  session = client.session_new(Dir.current)
  inserted = client.session_prompt_text(session.session_id, "Summarize this project")
  puts "Inserted message #{inserted.message_id}"
  # Continue reading session updates until your application is done.
ensure
  client.close
end
```

The prompt response acknowledges insertion. Foreground completion arrives
in an idle `state_update`. Keep `on_update` callbacks short because they run
on the dispatcher fiber.

The v2 client supports session creation, listing, resume and replay, prompts,
configuration changes, close and delete. Register `on_request_permission`
and `on_create_elicitation` to handle Agent requests. Authentication is
available through `auth_login`, `auth_logout`, and `authenticate_terminal`.
Use `tool_call_cancel` and `terminal_cancel` when the entity announces a
current cancel capability. [ACP v2 Prompt Lifecycle](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle)

For `session_prompt`, supply at least one content block. An optional
`idempotency_key` must contain 1 to 255 characters. Session setup requires
absolute Agent paths, unique MCP server names, and an absolute executable
path for each stdio server. Invalid arguments raise `ArgumentError` before
the client sends the request.
[ACP v2 Session Setup](https://agentclientprotocol.com/protocol/v2/session-setup)

In a permission callback, `typed_subject` exposes the optional tool-call patch
or command details. Future subjects retain their raw fields. A tool-call
patch from a permission request reaches `on_update` in receive order before
the permission handler runs. Use the callback's `request_id` to match
`$/cancel_request` notifications delivered through `on_notification`.
[ACP v2 Permission Requests](https://agentclientprotocol.com/protocol/v2/tool-calls#requesting-permission)

## Automatic version negotiation

Use `ACP.connect_negotiated` to try ACP v2 Preview first. If the Agent
selects v1, the connector closes the first connection and starts a fresh
one with the v1 handshake. An initialization error or unknown version
is returned to the caller.

```crystal
client = ACP.connect_negotiated("my-agent", ["--stdio"])
begin
  case client
  when ACP::V2::Client
    puts client.initialization_result.not_nil!.info.name
  when ACP::Client
    puts client.agent_info.try(&.name) || "ACP v1 Agent"
  end
ensure
  client.close
end
```

The optional `info` applies to both handshakes. Advertise capabilities
through `v1_capabilities` and `v2_capabilities`. To negotiate over a custom
transport, pass a block to `ACP.connect_negotiated` that opens a fresh
transport each time it is called.
[ACP Initialization](https://agentclientprotocol.com/protocol/v2/initialization#protocol-version)

## Constructor

### `.new`

```crystal
ACP::Client.new(
  transport : ACP::Transport,
  client_name : String = "acp-crystal",
  client_version : String = ACP::VERSION,
  client_capabilities : ACP::Protocol::ClientCapabilities = ACP::Protocol::ClientCapabilities.new,
  client_info : ACP::Protocol::ClientInfo? = nil
)
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `transport` | `Transport` | -- | The transport layer to use |
| `client_name` | `String` | `"acp-crystal"` | Client application name |
| `client_version` | `String` | `ACP::VERSION` | Client version string |
| `client_capabilities` | `ClientCapabilities` | `ClientCapabilities.new` | Advertised client capabilities |
| `client_info` | `ClientInfo?` | `nil` | Optional full implementation info, including display title and `_meta` |

When supplied, `client_info` supplies the name and version sent in the
handshake. The same keyword is available on `ACP.connect`.

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

Authenticates with the agent using an advertised Agent-managed method. Call
after `initialize_connection` if authentication is required. Use
`client.typed_auth_methods` to inspect the available flows.

### `#authenticate_terminal`

`client.authenticate_terminal(method_id) { |method| ... }` runs an advertised
terminal login before session setup. Set
`auth: ACP::Protocol::ClientAuthCapabilities.new(terminal: true)` in the
client capabilities when your `ProcessTransport` can run the configured
agent directly in an interactive terminal. The block receives
`TerminalAuthMethod#args` and `#env`. Present them to the user and return true
to approve the invocation.

Use the returned `Client` for subsequent calls. It connects with the original
process configuration, initializes, and carries over the previous callbacks
and timeouts. A declined or unsuccessful login raises
`ACP::AuthenticationError` and leaves the original connection available.
See [ACP Terminal Authentication](https://agentclientprotocol.com/protocol/v1/authentication#terminal-authentication).

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
| `typed_auth_methods` | `Array(AuthenticationMethod)` | Supported protocol and terminal descriptors |
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

## Subagent Sessions

Set `subagents: ACP::Protocol::SubagentCapabilities.new` in the client
capabilities before initialization to receive child session announcements and
session-directed messages. Use the outer `params.session_id` for updates and
request attribution, and `SubagentUpdate#session_id` for the announced child.

| Method | Result |
|--------|--------|
| `subagent(session_id)` | Current child state and permissions, or `nil` |
| `subagents(parent_id)` | Immediate children announced under that parent |
| `session_workspace(session_id)` | Effective working directory and additional directories, or `nil` |

`SubagentSession#cancel?` indicates when `session_cancel(child_id)` is
available. Other requests for the child raise `ACP::InvalidStateError`.
Agent requests still reach their existing handlers with their original
session IDs. Apply your workspace and permission policy to those requests.

Use `subagent(id)` for confirmed state. During `session/load`, typed callbacks
have `before_load_response?` set for the parent and its descendants. Treat
child state, capabilities, and configuration in those updates as history.
During `session/resume`, updates may arrive before the response. The client
publishes effective state and cancellation permission when the resume succeeds.

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

Each agent request runs its handler in its own fiber, so a handler may block (e.g. waiting on the user) without holding up responses or notifications, but request handlers may run concurrently with each other and with notification callbacks. `on_update` / `on_notification` still run in arrival order on the dispatcher fiber, so they must not wait on a request of their own (for example `session_set_mode`): its response can't be read until the callback returns, so the call times out (or, with a nil timeout, hangs for good). Make such calls from another fiber (`spawn`). A request with no matching handler, including an unknown `_`-prefixed extension method, is answered with `-32601 Method not found`. A handler that raises `ACP::JsonRpcError` is answered with that error's code, message and data (for example `-32002` for a missing file or unknown terminal); any other exception becomes `-32603`.

When the agent sends `$/cancel_request` for one of its requests, a request that only reads or waits (`session/request_permission`, `elicitation/create`, `fs/read_text_file`, `terminal/output`, `terminal/wait_for_exit`) is answered at once, with the `cancelled` outcome for a permission request and `-32800` for the others. Whatever its handler returns later is dropped. Requests with side effects, such as writes, terminal creation and extension methods, are left to their handler, which still has to answer. In every case the notification is also passed to `on_notification`, so the application can stop the work.
