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

ACP v2 prompts accept baseline text and resource links. Images, audio,
embedded resources, and skill references require their respective grants.
For custom content, set `client.on_prompt_content_type` to check the
Agent’s advertised `capabilities` against the extension’s documented rules.
The callback receives the custom type and the Agent’s capability object.
Stdio preserves the exact JSON values in the advertisement.

```crystal
client.on_prompt_content_type = ->(type : String, agent : ACP::Protocol::RawJson) do
  meta = agent.field("session").try(&.field("prompt")).try(&.field("_meta"))
  type == "_example.test/diagram" && meta.try(&.field("example.test/diagrams")).try(&.json) == "true"
end
```

This example uses an extension that advertises a boolean under prompt
capability metadata. The extension defines its own key, location, and
value. Return `true` only when the Agent advertises support for that type.
[ACP v2 Prompt Content](https://agentclientprotocol.com/protocol/v2/content#content-types)

Use `note.raw` from the v2 update callback to store or forward notification
parameters. It preserves unknown fields and exact JSON numbers over stdio,
including in updates whose `typed` accessor returns `nil`. The notification's
`meta` exposes fields representable as `JSON::Any`. Use `meta_raw` for the
whole metadata object. Custom transports can supply `Protocol::WireFrame`
from `receive_frame` to retain exact values.
[ACP v2 Session Updates](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle#session-updates)

Use `session_state(session_id)` to read the latest foreground and background
snapshot for an attached root session. A new session starts at `idle` until
the Agent reports activity. A resume uses the Agent's current snapshot.
A newly attached session with no usable resume snapshot reports `unknown`.
`background` is `nil` when unreported and empty when the Agent reports no
background work. Check `idle?` before interpreting a stop reason. Use
`subagent(session_id)` for a child session's state.

The snapshot is available from `on_update` once its session is attached.
`session_state_raw(session_id)` preserves extension fields and exact JSON
numbers over stdio. Closing or deleting the session clears the snapshot.
[ACP v2 Session States](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle#session-states)

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

Read the latest configuration with `session_config_options(session_id)`.
It returns an empty list when an attached session offers no options, and
`nil` when the client has no snapshot for that session. Use
`session_config_options_raw(session_id)` for the exact option list, including
extension fields and precise numbers. `session_set_config_option` checks the
Agent's current option IDs and advertised select values before sending.
[ACP v2 Session Config Options](https://agentclientprotocol.com/protocol/v2/session-config-options)

Read the current command list with `session_available_commands(session_id)`.
Filter by `slash_command?` to build slash command completion. The list is
empty when the session has no commands and `nil` when the client has no
snapshot for the session. Ambiguous command names are omitted from the
typed list. Setup responses and `available_commands_update`
notifications replace the list. Read it inside `on_update` to see the
latest live replacement. With the stdio transport,
`session_available_commands_raw(session_id)` retains extension variants and
exact numeric values. After a close, archive, or delete timeout, the list
is unavailable until the Agent confirms the request failed or a successful
resume supplies a new list.
[ACP v2 Slash Commands](https://agentclientprotocol.com/protocol/v2/slash-commands)

In a permission callback, `typed_subject` exposes the optional tool-call
patch or command details. Use `subject_raw` for exact JSON, including future
subjects and values outside `JSON::Any`. Tool-call patches also expose
`raw_input_raw`, `raw_output_raw`, and `meta_raw`. Changes to a `JSON::Any`
array are serialized from that view at its numeric precision. A tool-call
patch from a permission request reaches `on_update` in receive order before
the permission handler runs. Use the callback's `request_id` to match
`$/cancel_request` notifications delivered through `on_notification`.
[ACP v2 Permission Requests](https://agentclientprotocol.com/protocol/v2/tool-calls#requesting-permission)

### Repeat initialization

On a v2 connection, call `initialize_connection` again before your first
other request. Wait for each initialization to return before calling it
again. Use the optional `info`, `capabilities`, and `meta` arguments to
update what you advertise. Omitted arguments reuse the last successful
offer. Pass `meta: nil` to clear the initialization metadata.

The latest successful handshake takes effect on the connection. A JSON-RPC
error from the Agent leaves the previous successful handshake active. A
timeout or malformed response closes the connection because the Agent may
have already applied the new handshake.
[ACP v2 Repeating Initialization](https://agentclientprotocol.com/protocol/v2/initialization#repeating-initialization)

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

Use the `Transport` interface to instrument or substitute the wire connection.
Typed client methods can handle responses directly in the dispatcher.

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

### `#auth_status` (draft)

On v1 and v2, `client.auth_status` reads the Agent's authentication state
when the `auth.status` capability is advertised. Register
`on_auth_status_update` to receive changes from the Agent. `state` maps
future values to `unknown`, and `raw_state` preserves the wire value.
`accounts` describes the accounts for display.
[ACP Authentication State Proposal](https://github.com/agentclientprotocol/agent-client-protocol/blob/aa2aa6c77b80fd37ff81205ad2cfef60ef83ef1a/docs/rfds/get-auth-state.mdx)

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

### ACP v1 request validation

The client checks the Agent's advertised capabilities before calling
`session/load`, `session/resume`, `session/list`, `session/close`, or
`session/delete`. Images, audio, and embedded resources in prompts also require
the matching capability. Text and resource links are available by default.

Use absolute paths in the Agent's filesystem for session directories and MCP
stdio executables. Additional roots, system prompts, and HTTP or SSE MCP
servers require the Agent to advertise support. A system prompt accepts
non-empty text content and uses `append` or a mode advertised by the Agent.
For extensions that advertise custom modes through metadata, set
`client.on_system_prompt_mode` to interpret the extension's declaration.
The resolver receives the mode name and the Agent's system-prompt capability.

The client raises `InvalidStateError` for missing capabilities and
`ArgumentError` for invalid paths or content.
[ACP v1 Session Setup](https://agentclientprotocol.com/protocol/v1/session-setup)
[ACP v1 Prompt Turn](https://agentclientprotocol.com/protocol/v1/prompt-turn)

### `#session_status` (draft)

Call `client.session_status(session_id)` to query a session without attaching
to it. The Agent advertises support through `sessionCapabilities.status` in v1
or `session.status` in v2. `Session#status` queries the wrapped v1 session ID.
Pass `meta:` to include extension metadata in the request.

`status` returns `open` for a session in memory and `saved` for a persisted
session or a future status. `raw_status` preserves the Agent's value. In v2,
`state` can also carry a foreground snapshot. A missing snapshot leaves the
foreground state unknown. An unknown session ID raises an `ACP::JsonRpcError`
with code `-32002`.
[ACP Session Status Proposal](https://github.com/agentclientprotocol/agent-client-protocol/blob/aa2aa6c77b80fd37ff81205ad2cfef60ef83ef1a/docs/rfds/session-status.mdx)

### `#session_options` (draft)

Call `client.session_options(cwd)` to preview configuration for a new session.
For a saved session, use `SessionOptionsParams.new(cwd, session_id: id)`.
The Agent advertises this feature through `sessionCapabilities.options` in v1
or `session.options` in v2. V1 previews include modes when available. V2
previews can also include advisory slash commands.

Pass chosen values as an ordered `config_options:` array of
`InitialSessionConfigOption` values on `session/new`, v1 `session/load`,
or `session/resume`. Use the protocol version's namespace. In v1, boolean choices require
the Client's `session.configOptions.boolean` capability. Read the resulting
configuration and, in v2, the available commands from the setup response.
[ACP Session Options Proposal](https://github.com/agentclientprotocol/agent-client-protocol/blob/94824f11ec78f7a6699323a9342e47fa5edf2530/docs/rfds/session-options.mdx)

### `#session_fork` (draft)

Call `client.session_fork(source_id, cwd)` when the Agent advertises
`sessionCapabilities.fork` in v1 or `session.fork` in v2. The returned
`session_id` identifies the new active session. V1 also exposes
`Session#fork(cwd)`, which returns a wrapper for the fork.

Use `SessionForkParams` in the protocol version's namespace to supply extra
workspace roots, MCP servers, a system prompt, or ordered initial settings.
For a custom system prompt mode, check the Agent's extension advertisement
before supplying the mode.
Pass `cursor_id:` to fork at a cursor reported as forkable on the source
session on this connection. A `-32602` reply retires the fork grant used by
that request. A later announcement can grant fork access again.
The source session keeps its history and its other cursors.
[ACP Session Fork Proposal](https://github.com/agentclientprotocol/agent-client-protocol/blob/94824f11ec78f7a6699323a9342e47fa5edf2530/docs/rfds/session-fork.mdx)

### `#session_set_title` (draft)

Call `client.session_set_title(session_id, title)` on v1 or v2 when the Agent
advertises `sessionCapabilities.title` or `session.title`, respectively.
The session can be inactive on the connection. Use `result.title` for display
because the Agent can normalize the title before storing it.
`Session#set_title` uses the wrapped v1 session ID.
[ACP Session Title Proposal](https://github.com/agentclientprotocol/agent-client-protocol/blob/aa2aa6c77b80fd37ff81205ad2cfef60ef83ef1a/docs/rfds/session-set-title.mdx)

### `#session_archive` and `#session_unarchive` (draft)

Call `client.session_archive(session_id)` to close a session and hide it from
the default list while retaining its ID and saved conversation. Call
`client.session_unarchive(session_id)` to restore it to the default list. Load
or resume it separately before prompting. Both operations require the Agent's
`sessionCapabilities.archive` capability in v1 or `session.archive` in v2.
A missing session produces JSON-RPC error `-32002`. The v1 `Session` wrapper
also exposes `archive` and `unarchive`.

If a request times out, the Agent may still commit the change. Check the
session's archive state in a later list response.

Use `client.session_list(archived: "only")` in v1 or pass
`ACP::Protocol::V2::SessionListParams.new(archived: "only")` in v2 to list
archived sessions. Use `"include"` to list both archived and unarchived
sessions. Preserve the filter when following `next_cursor`. The Agent reports
the archive state as `SessionInfo#archived`.
[ACP Session Archive Proposal](https://github.com/agentclientprotocol/agent-client-protocol/blob/94824f11ec78f7a6699323a9342e47fa5edf2530/docs/rfds/session-archive.mdx)

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

Switches the session to an advertised mode. Read the available modes and
the current selection with `client.session_modes(session_id)`. Omit the
session ID to read or change the active session.
[ACP v1 Session Modes](https://agentclientprotocol.com/protocol/v1/session-modes)

### `#session_set_config_option`

```crystal
client.session_set_config_option(
  config_id : String,
  value : String | Bool,
  session_id : String? = nil
) : ACP::Protocol::SessionSetConfigOptionResult
```

Changes an option in the given or active session. Read the latest list with
`client.session_config_options(session_id)`. Pass an advertised value ID for
a `select` option. To pass a `Bool` for a `boolean` option, advertise
`session.configOptions.boolean` when initializing the client.

Setup responses and configuration updates replace the session's option list
as the client receives them. A successful configuration change also returns
a complete list. Choice state is available until the session closes or the
client forgets it. After a timed-out load, wait for the Agent's response or
reconnect before requesting another load of the same session.
[ACP v1 Session Config Options](https://agentclientprotocol.com/protocol/v1/session-config-options)

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

## MCP-over-ACP (draft)

Register an MCP handler on an initialized ACP client and include its
declaration in session setup. The Agent must advertise `mcpCapabilities.acp`
in v1 or `session.mcp.acp` in v2. A registration can be declared in multiple
sessions on the same connection.

```crystal
server = client.register_mcp_server("workspace-tools") do |context|
  handle_workspace_mcp_request(context)
end

# With ACP::V2::Client
wire_server = ACP::Protocol::V2::McpServer.acp(server)
session = client.session_new(ACP::Protocol::V2::SessionNewParams.new(
  Dir.current, mcp_servers: [wire_server]))
```

With `ACP::Client` v1, pass `[server.to_json_any]` as the `mcp_servers` list.
The Agent can call a registered handler before the session setup response
arrives. The handler receives `ACP::McpRequestContext` and returns a
`MessageMcpResponse.success(result)` or `.failure(mcp_error)`. Use
`McpJson.from_json` to pass exact JSON for arguments, results, or opaque
multi-round-trip state.

Handlers implement the MCP methods they expose and apply authorization and
subscription filters. The binding validates the MCP 2026-07-28 request
metadata, routes `context.notify` to the active operation, and preserves
inner MCP errors separately from ACP binding failures. Use
`context.cancellation` or `context.cancelled?` to stop work and finish cleanup
before returning. Unregistering a server or closing its connection signals
cancellation to the affected handlers.

Set `mcp_request_limit:` on either client to change the default of 32 active
operations. The binding limits individual frames to 16 MiB, outer ACP IDs
to 1 KiB, and retained input and queued output to 32 MiB each. A handler may
have one notification waiting to write at a time. The connection closes
if its bounded rejection queue fills. Stdio preserves exact JSON frames.
Custom transports can return `WireFrame` with `exact_params: true` and
override `send_wire` to preserve exact JSON in both directions.
[MCP-over-ACP Proposal](https://github.com/agentclientprotocol/agent-client-protocol/blob/94824f11ec78f7a6699323a9342e47fa5edf2530/docs/rfds/mcp-over-acp.mdx)

## Model providers (draft)

After initialization, call `providers_list` if the Agent advertises
`agentCapabilities.providers` in v1 or `capabilities.providers` in v2.
Each entry reports the provider ID, its supported API protocols, whether
the Agent requires it, and its current routing. A missing `current` value
indicates a disabled provider. The routing summary carries the protocol
and base URL.

Call `providers_set(SetProviderParams.new(provider_id, api_type, base_url,
headers: headers))` to replace a provider's full configuration. Use the
wire types in the protocol version's namespace. Supply the full intended
header map with each replacement. The Agent owns routing and decides when
changes apply to existing sessions.

`providers_disable(provider_id)` queries the Agent's current provider list
and rejects the operation if that provider is required. These methods apply
to the Agent process. Built-in stdio frame logs redact provider parameters and
their replies, including late or repeated replies. Once the log keeps track
of more than 256 provider request IDs, it redacts all response payloads for
that connection.
Applications receive the Agent's JSON-RPC errors, including any data the
Agent returns.
[ACP v1 draft schema](https://github.com/agentclientprotocol/agent-client-protocol/blob/94824f11ec78f7a6699323a9342e47fa5edf2530/schema/v1/schema.unstable.json) · [ACP v2 draft schema](https://github.com/agentclientprotocol/agent-client-protocol/blob/94824f11ec78f7a6699323a9342e47fa5edf2530/schema/v2/schema.unstable.json)

## Agent Skills (v2 draft)

Advertise `commands: CommandsCapabilities.new(skill: CommandsSkillCapabilities.new)`
on `Protocol::V2::ClientSessionCapabilities` and pass it as `session:` on
the v2 client capabilities. Read negotiated skills with
`session_available_commands(session_id).try(&.compact_map(&.skill))`. Setup
responses, command updates, and `session_options` previews also expose
`typed_available_skills`. Each skill has a name, description, and optional
path on the Agent's filesystem.

When the user selects a skill, put its name in
`Protocol::V2::SkillReference.new(name)` and send it through
`SessionPromptParams.new`. Use `Array(Protocol::V2::PromptContentBlock)` to
mix references with other typed content. An Agent that advertises
`session.prompt.skill` accepts one reference as the first block. With
`session.prompt.skill.inline`, references can appear anywhere.

The client checks the session's current list before sending a new skill
reference. To retry a keyed submission, call
`session_prompt(original_params, retry_submission: true)` with the same
prompt and `idempotency_key`. The Agent can then acknowledge an earlier
submission after the command list has changed.
In user-message updates, `skill_references` and `skill_reference` expose
references in full messages and chunks, including during replay.
[ACP Agent Skills Proposal](https://github.com/agentclientprotocol/agent-client-protocol/blob/94824f11ec78f7a6699323a9342e47fa5edf2530/docs/rfds/agent-skills.mdx)

## Prompt suggestions (draft)

Opt in by setting `prompt_suggestions: PromptSuggestionsCapabilities.new`
on the `ClientSessionCapabilities` for your protocol version. Pass that group
as `session:` on `ClientCapabilities`. An empty prompt suggestion capability
supports text and resource links. Add the `image:`, `audio:`, or
`embedded_context:` markers to offer those content types when the Agent also
supports them.

In v1, read `Protocol::PromptSuggestionsUpdate` from `on_update`. In v2, read
`Protocol::V2::PromptSuggestionsUpdate` from `note.update.typed`. Treat the
list as a replacement for that session's current suggestions. An empty
list withdraws the previous suggestions. Typed updates keep compatible
candidates in the Agent's order and skip entire unusable candidates. Start
with an empty list when you open or restore a session.

After the user accepts a suggestion, pass its `prompt` to `session_prompt`
in v1 or to `Protocol::V2::SessionPromptParams.new` in v2. Call the request
outside the dispatcher callback. [ACP Prompt Suggestions Proposal](https://github.com/agentclientprotocol/agent-client-protocol/blob/94824f11ec78f7a6699323a9342e47fa5edf2530/docs/rfds/prompt-suggestions.mdx)

## Session cursors (draft)

On v1, opt in with
`ClientSessionCapabilities.new(cursors: SessionCursorsCapabilities.new)`
in the client's session capabilities. On v2, cursor updates are available
automatically. They arrive through `on_update` as `Protocol::CursorUpdate`
in v1 and through `update.typed` in v2.

Use `client.session_cursor(session_id, cursor_id)` or
`client.session_cursors(session_id)` to read the current snapshots.
Their IDs are opaque and session-scoped. Each snapshot keeps the first
reported anchor and the latest capabilities. Use `anchor.known_position?`
and the transcript's entity IDs to decide where to display a cursor.

Full replays rebuild the stored cursors, including announced child sessions.
In v1, new snapshots become available when `session/load` succeeds. In v2,
each session's `replay_complete` publishes its snapshots and starts applying
live cursor updates. Until those boundaries, lookups return the previous
snapshots. Use `raw_meta_field` for exact metadata values outside the range
of `JSON::Any`.
Full replays can supply updated entity IDs for existing cursor anchors.
Closing a session or resuming without replay preserves its cursors.
[ACP Session Cursors Proposal](https://github.com/agentclientprotocol/agent-client-protocol/blob/94824f11ec78f7a6699323a9342e47fa5edf2530/docs/rfds/session-cursors.mdx)

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
