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

The prompt response acknowledges insertion and carries the inserted user
message's ID. Foreground completion arrives in an idle `state_update`.
Keep `on_update` callbacks short because they run on the dispatcher fiber.
[ACP v2 prompt acceptance](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle#2-prompt-accepted)

Session creation and fork responses in both versions, and v2 prompt
acknowledgements, expose exact extension metadata via `meta_raw`. An
ambiguous returned ID or repeated JSON-RPC `result` raises `ProtocolError`.
New sessions must also have IDs distinct from existing sessions.
[ACP v1 session setup](https://agentclientprotocol.com/protocol/v1/session-setup#creating-a-session)
[ACP v2 session setup](https://agentclientprotocol.com/protocol/v2/session-setup#creating-a-session)

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

Return `RequestPermissionResult.selected(option_id)` for an option from the
request or `RequestPermissionResult.cancelled` when no option was chosen.
An invalid result or selection returns JSON-RPC `-32603` to the Agent.
Over stdio, repeated permission option fields return `-32602` before the
callback runs. Custom and future ACP v2 outcome objects pass through unchanged.
[ACP v2 Permissions](https://agentclientprotocol.com/protocol/v2/tool-calls#requesting-permission)

`on_elicitation_complete` fires once for each accepted URL elicitation on the
connection. A completion that arrives before the `accept` reply is sent
is held until the reply is written successfully. Completion callbacks run
on the dispatcher. If no typed handler is set, matching notifications that
fit in `JSON::Any` go to `on_notification`. The typed completion exposes
exact metadata through `meta_raw`.
[ACP v2 URL Completion](https://agentclientprotocol.com/protocol/v2/elicitation#url-completion)

Both protocol versions require an elicitation scope and a message. URL
mode also requires an absolute URL and an opaque `elicitationId`. The
client returns JSON-RPC `-32602` for invalid requests before calling the
handler. ACP v1 accepts an explicit `null` request ID for request scope.
[ACP v1 Elicitation Scope](https://agentclientprotocol.com/protocol/v1/elicitation#creating-an-elicitation)

Typed form and URL requests expose exact extension metadata through
`meta_raw`. Use `CreateElicitationResult#meta_raw=` to return exact metadata
or copy it from a request. The `meta` accessor provides editable JSON
object fields. Edits to objects and arrays preserve untouched wire values,
including nested entries moved within an array. Scalar matches prefer their
original positions. Use `meta_raw=` to distinguish numbers that project to
the same value or to replace an array that contains unrepresentable scalars.
Stdio supports exact replies. A custom transport that cannot preserve an
exact reply returns JSON-RPC `-32603` to the Agent.
[ACP Extension Metadata](https://agentclientprotocol.com/protocol/v2/extensibility)

An ACP v2 elicitation with `request_id` belongs to an outstanding Client request
on the same connection. The client rejects a request-scoped elicitation
with `toolCallId`. The callback's local `cancellation` channel closes when
the elicitation is cancelled, its originating request ends before an input
reply is sent, or the connection closes. Use the channel to dismiss a form
or URL consent prompt that is still open.
[ACP v2 Elicitation](https://agentclientprotocol.com/protocol/v2/elicitation#creating-an-elicitation)

For v2 form elicitations, `requested_schema` contains the supported
controls. An optional control of an unsupported type is omitted.
A form with a missing or unsupported required control, or a malformed
standard control, returns JSON-RPC `-32602` before the callback runs.
Use `requested_schema_raw` for the original schema with exact values.
Render text fields with unrecognized `format` values as plain text.
[ACP v2 Form Mode](https://agentclientprotocol.com/protocol/v2/elicitation#form-mode)

For accepted forms, the client checks submitted field names, required
fields, types, choices, bounds, and the `email`, `uri`, `date`, and
`date-time` string formats against the original schema. Format checks
are local syntax checks. Leap seconds are checked for possible placement at
the end of a UTC month. A callback that supplies invalid form content
causes a JSON-RPC `-32603` reply to the Agent.
For a declared custom field, use `CreateElicitationResult.accept_raw`
with a `Protocol::RawJson` content object. Stdio sends those values with
their exact JSON numbers. Custom transports can override `send_wire`
to support exact frames.
[ACP v2 Elicitation Responses](https://agentclientprotocol.com/protocol/v2/elicitation#responses)

ACP v1 form callbacks also validate submissions against the original schema.
The schema type and property map retain their v1 defaults. V1 `date-time`
uses ISO 8601. V1 `pattern` translates common ECMAScript character classes and
Unicode escapes and uses Crystal's regex engine with bounded matching.
A v1 client using its generic Agent request callback can
return the same form replies as a typed handler. Invalid submissions return
`-32603` to the Agent.
[ACP v1 Elicitation](https://agentclientprotocol.com/protocol/v1/elicitation)

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

### Session info and usage

Use a `SessionDetailsStore` per connection to retain the session info and
context-window usage reported through `on_update`.

```crystal
details = ACP::V2::SessionDetailsStore.new
client.on_update = ->(update : ACP::Protocol::V2::SessionUpdateParams) do
  details.observe(update)
  nil
end

info = details.session_info(session_id)
usage = details.session_usage(session_id)
```

Both lookups return `nil` until their first usable update. Session info
patches the title, RFC 3339 activity time, and metadata. Usage updates
replace the token counts and patch the cumulative cost and usage metadata.
`cost_raw` preserves the Agent's exact JSON amount. `cost` provides a
`Float64` projection. A parent's reported cost already includes its
descendants' cost.

The store defaults to 128 sessions and 64 KiB of retained detail data per
session. Adjust `session_limit:` and `session_byte_limit:`, or pass `nil`
to remove a limit. The store keeps the latest token counts and applies
cost and usage metadata that fit. It preserves explicit clears when a
different usage field exceeds the budget.

When the Agent sends current details on resume, it sends them after any
requested replay. Use `forget_session` when you stop retaining details
for a session. [ACP v2 session info](https://agentclientprotocol.com/protocol/v2/session-list#updating-session-metadata) · [ACP v2 usage](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle#session-usage-updates) · [Current-state synchronization](https://agentclientprotocol.com/protocol/v2/session-setup#current-state-synchronization)

### Session compaction

Feed each connection's v2 session updates to a `CompactionStore` in
receive order. Compaction updates are available without a v2 capability.

```crystal
compactions = ACP::V2::CompactionStore.new
client.on_update = ->(update : ACP::Protocol::V2::SessionUpdateParams) do
  compactions.observe(update)
  nil
end

snapshot = compactions.compaction(session_id, compaction_id)
```

`compactions(session_id)` lists retained entries in first-seen order. The
snapshot has the current status, error, and exact `meta_raw`. Read
`summary_raw` for exact blocks or `summary_blocks` for usable display
blocks. A summary replacement clears or replaces the accumulated blocks.
Chunk metadata stays on the incoming `CompactionSummaryChunkUpdate`.

The store defaults to 128 compactions across sessions and 256 KiB per entry.
Adjust `compaction_limit:` and `compaction_byte_limit:`, or pass `nil` to
remove a limit. `summary_incomplete?` flags a gap caused by the byte limit.
An accepted summary replacement clears the gap and resumes appending chunks.
When a replacement summary exceeds the budget, the store can still retain
the status, error, and metadata that fit. An update can also retain a new
status and summary with earlier details if the new error or metadata
would exceed the budget.

Use `forget_session` to discard one session's compactions. To reconstruct a
view from full replay, collect its updates in a fresh store and use each
session's own `replay_complete` to track delivery. The configured limits
apply to replayed updates. [ACP v2 session compaction](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle#session-compaction) · [Replay completion](https://agentclientprotocol.com/protocol/v2/session-setup#replay-complete)

### Transcript messages

Feed each connection's v2 session updates to a `MessageStore` in receive
order. User, Agent, thought, and session-directed messages have independent
ID scopes within each session.

```crystal
transcript = ACP::V2::MessageStore.new
client.on_update = ->(update : ACP::Protocol::V2::SessionUpdateParams) do
  transcript.observe(update)
  nil
end

message = transcript.message(session_id, ACP::V2::MessageKind::Agent, message_id)
```

`messages(session_id)` lists retained messages in first-seen order. Use
`content_raw` for exact blocks, `content_blocks` to decode usable display
blocks, and `skill_references` for draft skill references in user messages.
Message updates patch `meta_raw` by key. Chunk metadata remains available
on the incoming `MessageChunkUpdate`. Session-directed messages expose the
reported sender and recipient session and message IDs.

The store defaults to 512 messages across sessions and 256 KiB per message
for IDs, links, metadata, content, and streamed block storage. Adjust
`message_limit:` and `message_byte_limit:`, or pass `nil` to remove a limit.
At the message count limit, `observe` returns `false` for a new message ID.
`observe` returns `true` when an update applies or records a content gap.
Use `content_incomplete?` to show that content exceeded the byte limit.
An oversized replacement clears earlier content, and an oversized chunk
leaves the retained prefix. A full content replacement clears the gap
and resumes appending chunks. A replacement can fit while new links or
metadata exceed the remaining budget. In that case the new content is
retained with the previous links and metadata.

For a full replay, use `forget_session` on the affected sessions or collect
replay into a fresh store. Each session's `replay_complete` marks the end of
the Agent's replay delivery. The store's configured limits still apply
to those updates. [ACP v2 message updates](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle#message-ids) · [Replay completion](https://agentclientprotocol.com/protocol/v2/session-setup#replay-complete)

### Plan state

Feed each connection's v2 session updates to a `PlanStore` in receive order.
A `plan_update` replaces the complete plan with that ID in its session.

```crystal
plans = ACP::V2::PlanStore.new
client.on_update = ->(update : ACP::Protocol::V2::SessionUpdateParams) do
  plans.observe(update)
  nil
end

snapshot = plans.plan(session_id, plan_id)
current = snapshot.try(&.plan.typed)
```

`plans(session_id)` lists retained snapshots. `plan_raw` keeps exact JSON
for checklist, Markdown, and extension plans. `meta_raw` holds metadata
from the update envelope. A removal deletes the corresponding snapshot.

The store defaults to 128 plans across sessions and 256 KiB of serialized
state per plan. Set `plan_limit:` or `plan_byte_limit:` to change a limit,
or pass `nil` to remove it. `observe` returns `true` when an update stores
or discards a snapshot. An oversized replacement discards any previous
snapshot with that ID so the display can clear outdated content.

Use `forget_session` to discard one session's plan state. To rebuild from
full replay while keeping the current view available, feed the replay into
a fresh store and switch each session's view after its own `replay_complete`.
[ACP v2 plan updates](https://agentclientprotocol.com/protocol/v2/agent-plan#updating-plans) · [Replay completion](https://agentclientprotocol.com/protocol/v2/session-setup#replay-complete)

### Tool-call state

Create a `ToolCallStore` per connection and feed it v2 session updates in
receive order. The client sends permission tool-call patches through the
same `on_update` callback before it calls `on_request_permission`.

```crystal
tool_calls = ACP::V2::ToolCallStore.new
client.on_update = ->(update : ACP::Protocol::V2::SessionUpdateParams) do
  tool_calls.observe(update)
  nil
end

call = tool_calls.tool_call(session_id, tool_call_id)
```

Snapshots contain the current fields, exact JSON for raw input and output,
and detached content in receive order. A content patch replaces the list.
Chunks append to it. Content-item metadata stays on the item. Read
chunk-scoped metadata from `ToolCallContentChunk#meta_raw` in the callback.
Use the snapshot for display and `client.tool_call_cancel` for live
cancellation checks. When presenting a permission prompt, use the
`RequestPermissionParams` delivered to that permission callback.

By default, the store retains up to 128 calls across sessions and up to
1 MiB of serialized state per call. Set `call_limit:` or `call_byte_limit:`
to change the corresponding limit, or pass `nil` to remove it. `observe`
returns `false` when an update would exceed either limit or a tool-call patch
repeats a recognized field. The stored state remains intact in either case.

Use `forget_session` to discard one session's tool-call history. For full
replay of a session tree, clear all affected sessions first or use a fresh
store. [ACP v2 tool-call updates](https://agentclientprotocol.com/protocol/v2/tool-calls#streaming-content)

### Display-only terminal state

Create a `TerminalStore` per connection and feed it v2 session updates in
receive order. Look up terminals by the reporting session and terminal IDs.

```crystal
terminals = ACP::V2::TerminalStore.new
client.on_update = ->(update : ACP::Protocol::V2::SessionUpdateParams) do
  terminals.observe(update)
  nil
end

# Read this after the terminal has sent an update.
snapshot = terminals.terminal(session_id, terminal_id)
output = snapshot.try(&.output)
```

The store keeps the newest 1 MiB of output per terminal by default. Set
`output_byte_limit:` to choose a different byte budget, or zero to keep
terminal state without output bytes. `output` is a detached byte slice when
output is available. It can begin in the middle of a UTF-8 character or
terminal sequence when the limit discards earlier bytes. Apply your display
policy before rendering it. `output_meta_raw` describes the latest replacement
snapshot. Chunk metadata is available on each `TerminalOutputChunk` update.

The default `terminal_limit:` is 128 across all sessions. At capacity,
`observe` returns `false` for new terminal IDs. The default
`terminal_metadata_byte_limit:` is 64 KiB per terminal. A top-level `_meta`
patch that would exceed this limit leaves the stored metadata unchanged.

Use `forget_session` to discard one session's display history. For full
replay of a session tree, clear the parent and each affected child first,
or rebuild the display state in a fresh store. Stored capabilities reflect
the reported display state. Use `client.terminal_cancel` for current
cancellation checks. [ACP v2 display-only terminals](https://agentclientprotocol.com/protocol/v2/tool-calls#display-only-terminals)

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

### `#session_list`

Both protocol versions return usable sessions in the Agent's order, even when
some entries are malformed. V2 entries use absolute workspace roots and RFC
3339 timestamps. The page and each entry expose exact extension metadata via
`meta_raw`.

Use `has_more?` to check for another page. An empty cursor is valid. Pass
`next_cursor` and the original filters in the next request.
[ACP v1 session list](https://agentclientprotocol.com/protocol/v1/session-list)
[ACP v2 session list](https://agentclientprotocol.com/protocol/v2/session-list)

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

For `session/request_permission`, return the JSON form of
`Protocol::RequestPermissionResult.selected(option_id)` or
`Protocol::RequestPermissionResult.cancelled`. Select an ID from the Agent's
original options. Invalid results or selections return JSON-RPC `-32603`.
Over stdio, repeated permission option fields return `-32602` before the
callback runs.
[ACP v1 Permissions](https://agentclientprotocol.com/protocol/v1/tool-calls#requesting-permission)

For an accepted URL elicitation, `on_elicitation_complete` receives the
matching completion once. If no typed handler is set, the matching
notification goes to `on_notification`.
[ACP v1 URL Completion](https://agentclientprotocol.com/protocol/v1/elicitation#url-completion)

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

For ACP v1, advertise file reads, file writes, and terminal support before
initialization. The client handles `fs/read_text_file` and
`fs/write_text_file` according to their separate capability flags.
`clientCapabilities.terminal` enables the terminal methods as a group.
Requests outside the advertisement return `-32601` before reaching either
the typed handler or `on_agent_request`.

File paths and any supplied terminal working directory must be absolute
in POSIX or Windows syntax.
File reads use one-based line numbers. Terminal environment entries
require string `name` and `value` fields.
Malformed parameters return `-32602` before either callback. Typed request
parameters provide exact extension metadata through `meta_raw`, and
`CreateTerminalParams#env_raw` retains the complete environment array.
[ACP v1 File System](https://agentclientprotocol.com/protocol/v1/file-system#checking-support)
[ACP v1 Terminals](https://agentclientprotocol.com/protocol/v1/terminals#checking-support)

Call `client.session_workspace(params.session_id)` to look up the Agent-side
`cwd` and `additional_directories` in either callback. ACP v1 records the roots from
successful new, load, resume, and fork replies, including raw requests and
sessions without subagents. A successful reattachment replaces the root set.
A reattachment timeout clears the lookup until a setup succeeds. A confirmed
close or archive, local `forget_session`, and disconnection also clear it.
The lookup returns `nil` when the workspace is unknown. Announced subagents can
inherit roots from their parent.

Apply your application's access policy using these roots. The ACP file system
spec recommends checking resolved paths at the time of use and comparing
them by path component.
[ACP v1 Workspace Root Security](https://agentclientprotocol.com/protocol/v1/session-setup#workspace-root-security)

Use `meta_raw=` to attach exact JSON metadata to typed file and terminal
results, including `TerminalExitStatus`. Stdio preserves the original
number tokens. Custom transports that cannot preserve an exact reply
return `-32603` to the Agent.
[ACP v1 Extension Metadata](https://agentclientprotocol.com/protocol/v1/extensibility#the-_meta-field)

For ACP v1 file and terminal methods, `on_agent_request` must return a
result object with the method's required fields. Return `{}` for an
empty successful acknowledgement. Malformed results return `-32603`.
Additional result fields and explicit `ACP::JsonRpcError` replies pass
through.

Return a fresh `terminalId` for every successful `terminal/create` on the
connection. Subsequent terminal requests must use that ID with its creating
session. With a handler registered, unknown, retired, and other-session IDs
return `-32002` before dispatch. A duplicate creation ID returns `-32603` and
invalidates that ID for the connection.
`terminal/kill` keeps the terminal available for output and exit status.
Your release callback must stop the command if it is still running and free
its resources. Successful release invalidates the ID. A confirmed session
close or archive, or a local `forget_session`, also clears the retired
attachment's terminal bindings. The application owns terminal processes and
their cleanup, including cleanup when a creation reply cannot be delivered.
[ACP v1 Terminals](https://agentclientprotocol.com/protocol/v1/terminals#releasing-terminals)

The client applies the original `terminal/create` output byte limit to typed
and generic `terminal/output` replies. It replaces invalid UTF-8 bytes with
replacement characters, then keeps the newest complete characters that fit.
When the client records truncation from a validated output snapshot, later
snapshots of that terminal keep `truncated` set to true.
The application controls its terminal capture buffer and can enforce the same
limit while collecting output.
[ACP v1 Terminal Output Limit](https://agentclientprotocol.com/protocol/v1/terminals#executing-commands)

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

When the Agent cancels a permission request, the Client answers with the
`cancelled` outcome. A cancelled v2 elicitation gets the `cancel` action.
Other requests that only read or wait, such as `fs/read_text_file`,
`terminal/output`, and `terminal/wait_for_exit`, are answered with `-32800`.
Those handlers' late answers are dropped. Handlers for writes, terminal
creation, and extension requests still answer the original request.

Valid cancellations are also passed to `on_notification` so the application
can stop the work. ACP v2 delivers this callback for outstanding requests
from the Agent. Cancellation IDs retain their number or string type, and
ambiguous IDs are ignored. Use `CancelRequestParams#meta_raw` when decoding
the notification JSON directly.
[ACP v2 request cancellation](https://agentclientprotocol.com/protocol/v2/cancellation)
