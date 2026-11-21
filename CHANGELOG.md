# Changelog

## Unreleased

### Breaking Changes
- Typed session mode and configuration setters validate IDs and values against the session's current advertisements. Initialize with `session.configOptions.boolean` to set v1 boolean options.
- ACP v1 client helpers now reject unadvertised session operations, optional prompt and setup features, and invalid workspace paths before sending requests. Use absolute Agent-side paths and check the negotiated capabilities.
- `StdioTransport#incoming` now carries `Transport::IncomingFrame?`. Use `receive` for `JSON::Any?` or `receive_frame` to retain input beyond the range of `JSON::Any`.
- Schema `uint32`/`uint64` fields are now unsigned: `ReadTextFileParams#line`/`#limit` and `ToolCallLocation#line` are `UInt32?`, `CreateTerminalParams#output_byte_limit` is `UInt64?`, and `UsageUpdate#used`/`#size` are `UInt64`. Valid values above the signed maximum now decode, and negative values are rejected (an `fs/read_text_file` / `terminal/create` request carrying one is answered with `-32602 Invalid params`)
- An agent request for an unknown `_`-prefixed extension method with no `on_agent_request` handler is answered with `-32601 Method not found` (method name in `data`) instead of a `null` result, per extensibility#custom-requests and matching the Rust SDK
- `WaitForTerminalExitResult#exit_code` and `TerminalExitStatus#exit_code` are `UInt32?` (schema `uint32`). Convert a `Process::Status` with `status.exit_code?.try(&.to_u32!)`. That is nil for a signal, and `to_u32!` keeps a Windows NTSTATUS such as `0xC0000005` instead of raising
- `SessionSetConfigOptionParams#value` is `String | Bool`, and `ConfigOption`'s constructor takes `current_value : String | Bool | Nil`. `type: "boolean"` config options are now parsed instead of skipped, so they show up in `config_options` (they have a nil `current_value`; read `boolean_value`). Agents only send them to clients that advertise `session.configOptions.boolean`
- A request that times out now also sends `$/cancel_request` for its ID
- A request still waiting when the connection drops (agent exit, EOF, `Client#close`) raises `ConnectionClosedError` ("Connection lost" / "Client closed" in the message), as `send_request` documents, instead of a locally made-up `JsonRpcError` -32603 that reported `received?` as if the agent had sent it
- `ProcessTransport.new` (and so `ACP.connect`) raises `TransportError`, with the original error as `cause`, when the agent can't be started (missing command, bad `chdir`), instead of `File::NotFoundError`

### Bug Fixes
- Recheck cancellation grants at the transport writer. Keep historical tool, terminal, and child grants inactive during replay, and preserve current root grants when resuming without replay.
- Treat ACP v2 close and delete responses for missing sessions as successful. Apply runtime cleanup even when response metadata contains wide numbers.
- Track ACP v1 and v2 session choices per session. Setup, configuration replies, and Agent updates replace the cached lists in receive order. V2 exposes the exact JSON for extension options.
- Preserve native MCP-over-ACP declarations in the typed `SessionNewParams` constructor.
- Preserve full `UInt64` values when stdio dispatches typed ACP usage updates, terminal requests, and elicitation forms.
- Redact MCP server credentials from outgoing request logs.
- Validate ACP v2 prompts, idempotency keys, MCP server settings, workspace paths, system prompts, and configuration value types before sending requests.
- Preserve message IDs when converting streaming updates to typed `ContentChunk` values. Preserve extension metadata on client and agent implementation info and typed MCP server, environment, and header values.
- Answer both requests when the agent reuses the ID of a request still in flight and the newer one finishes first; the older one was taken for cancelled and never answered
- Deliver each response to its request once: a response repeated three times in one burst blocked the dispatcher fiber forever, so no later response or notification arrived
- Run agent-to-client request handlers (`on_agent_request`, `on_read_text_file`, ...) in their own fiber, so a blocking handler no longer stalls the dispatcher — e.g. the `cancelled` prompt response sent after `session/cancel` was not read until a still-open permission prompt returned. Notifications stay on the dispatcher, in order; request handlers may now run concurrently with each other and with notification callbacks
- Serialize outgoing transport writes — concurrent senders could interleave bytes within a JSON-RPC frame and hand the agent an unparseable line
- Deliver `session/update` to `on_notification` when no `on_update` handler is registered, instead of dropping every session update
- Reject JSON-RPC ids that cannot be represented exactly in `Protocol.extract_id` — a fractional id was truncated onto an unrelated pending request, and an out-of-range numeric id raised `OverflowError` inside the dispatcher
- Accept omitted collection fields when parsing agent messages (`agentCapabilities`, `sessions`, `configOptions`, `availableModes`, `entries`, `availableCommands`, `truncated`, `PlanEntry` priority/status), matching the defaults their constructors already used
- Add the missing `session/resume` and `session/close` constants to `Protocol::AgentMethod`, and derive `known?`/`session_method?` from a single list
- Make `ExtensionMethod.add_prefix` idempotent so echoing an agent's extension method name no longer puts `__method` on the wire
- Forward `max_line_bytes` from `ProcessTransport` to the underlying `StdioTransport`
- Make `ProcessTransport#wait` safe to call repeatedly and after `close`, instead of racing the internal reaper fiber and raising `Channel::ClosedError`
- Clear the client's cached active session on every `Session#close` path, so an id-less `session_prompt` raises `NoActiveSessionError` rather than targeting a closed session
- Percent-encode and decode `file://` URIs in `ResourceLinkContentBlock`, fixing paths containing spaces, `#`, `?`, or `%`
- Fix cancellation fiber leak, authentication parsing crash, and the `ACP_LOG_LEVEL` default mismatch in the `interactive_client` example

### Features
- Track ACP v2 foreground and background snapshots for attached sessions. Preserve state across prompt acknowledgements, replay, and session resume.
- Read the latest ACP v2 command advertisements per session, with exact JSON for extension commands and one shared list for skill validation.
- Allow ACP v2 clients to repeat initialization before their first other request and update advertised capabilities on success.
- Expose draft ACP token usage from v1 prompt results and v2 idle state snapshots, with full unsigned 64-bit counters.
- Add draft ACP Proxy Chains for v1 and v2 Preview. `ACP::Conductor` routes terminal and nested chains, and `ACP::Proxy` can forward or handle messages in either direction.
- Host native MCP servers on ACP v1 and v2 connections with request-scoped notifications, cancellation, and exact JSON.
- Configure draft ACP v1 and v2 model providers with typed discovery, replacement, and disable requests.
- Advertise and invoke draft ACP v2 Agent Skills with typed command entries and prompt references.
- Create draft ACP v1 and v2 session forks, including forks at an announced cursor and initial configuration choices.
- Opt in to draft prompt suggestions in ACP v1 and v2 and receive ordered, typed replacement lists.
- Preview draft ACP v1 and v2 session options and provide initial configuration during session setup.
- Decode draft ACP v1 and v2 session cursors and track their anchors and capabilities across full replays.
- Add draft ACP v1 and v2 session archiving, restoration, and archive filters on `session/list`.
- Add draft ACP v1 and v2 session title changes and return the title stored by the Agent.
- Add draft ACP v1 and v2 session status queries, with optional foreground state in v2.
- Add draft ACP v1 and v2 authentication status queries and updates, with account details redacted from transport logs.
- Decode ACP v2 permission subjects, apply their tool-call patches in receive order, and expose the request ID to permission callbacks.
- Add `ACP.connect_negotiated` for automatic ACP v2 Preview selection and v1 fallback.
- Decode ACP v2 configuration options and advertised commands in session updates and responses.
- Decode ACP v2 subagents, inter-session messages, execution plans, session info, usage, notices, and compaction updates.
- Decode ACP v2 tool-call and display terminal updates, structured diffs, and streamed terminal bytes.
- Add an opt-in ACP v2 client for initialization, authentication, session and prompt operations, permission and elicitation callbacks, and capability-gated cancellation.
- Decode ACP v2 Preview foreground state, message upserts and chunks, and replay completion while preserving open session update payloads.
- Add ACP v2 Preview session setup, resume and replay, and prompt acknowledgement wire types.
- Add namespaced ACP v2 Preview wire types for initialization, authentication, capabilities, and unsupported-version errors.
- Add typed ACP v1 authentication methods, opt-in terminal login with a user-approved invocation, and reconnection with the original process configuration.
- Validate advertised authentication method IDs and logout support before sending authentication requests.
- Support opted-in ACP v1 subagent sessions with nested associations, inherited workspace roots, current state, and capability-gated cancellation. Replay and failed attachment keep historical child state separate from active permissions.
- Add ACP v1 wire types for subagent announcements, session-directed messages and chunks, and session references in tool calls.
- Support opt-in ACP v1 plan operations via `PlanCapabilities`, `IdentifiedPlanUpdate`, and `PlanRemovedUpdate`. Plans can carry a complete checklist or a Markdown document and use IDs scoped to their session.
- Support the stable ACP v1 features of schema 1.31. Each new client capability is opt-in and off by default:
  - `session/delete`: `Client#session_delete` (treats `-32002` as success), `SessionDeleteParams`/`SessionDeleteResult`, and `SessionCapabilities#delete?`
  - `logout`: `Client#logout`, `LogoutParams`/`LogoutResult`, and `AgentCapabilities#auth` with `AgentAuthCapabilities#logout?`
  - Elicitation: the `Client#on_create_elicitation` and `#on_elicitation_complete` handlers, `ClientCapabilities#elicitation` (`form` / `url`), `CreateElicitationParams`, `CreateElicitationResult` (`.accept` / `.decline` / `.cancel`), `CompleteElicitationParams` and `ElicitationSchema`/`ElicitationPropertySchema`. A request for a mode the client did not advertise is answered with `-32602`
  - `systemPrompt` and `additionalDirectories` on `session/new`, `session/load` and `session/resume` (keyword arguments on the `Client` and `Session` methods), `Protocol::SystemPrompt`, `SessionInfo#additional_directories`, and `SessionCapabilities#system_prompt?` / `#additional_directories?`
  - Session notices and compaction: `ClientCapabilities#session` (`ClientSessionCapabilities` with `notices`, `compaction`, `config_options.boolean`), plus the `NoticeUpdate`, `CompactionUpdate` (patch fields keep "omitted" apart from "cleared") and `CompactionSummaryChunkUpdate` session updates
  - Boolean config options: `ConfigOption#boolean?` / `#boolean_value`, and `session_set_config_option(id, true)`
  - `$/cancel_request`: `Client#cancel_request` and `Protocol::CancelRequestParams`. When the agent cancels a pending request that only reads or waits (permission, elicitation, `fs/read_text_file`, `terminal/output`, `terminal/wait_for_exit`), the client answers it at once and drops the handler's late answer. The notification is also passed to `on_notification`
- Add `FsCapabilities#meta`

### Improvements
- Add `Client#forget_session` for releasing cached session state locally
- Add `ProcessTransport#exit_status` for a non-blocking exit status check

## v0.3.0

### Features
- Add `session/close` and `session/resume` support — `Client#session_close`, `Client#session_resume`, related params/result types, and `SessionCloseCapabilities`/`SessionResumeCapabilities`
- Add protocol version negotiation — `MIN_PROTOCOL_VERSION` constant and `ACP.supports_protocol_version?` helper, so the client accepts any agent-returned version within the supported range
- Add Crystal 1.20 support

### Bug Fixes
- Fix ACP spec-conformance and robustness bugs surfaced by live Gemini agent testing (transport framing, client request handling, and protocol type edge cases)
- Fix `interactive_client` example capability check
- Fix dispatch-error handling for malformed protocol frames

### Security
- Bound incoming line size to prevent unbounded memory growth from malicious or malformed frames
- Redact sensitive fields in frame logs

### Documentation
- Simplify README and fix the dependency URL

### CI
- Standardize CI workflow and align matrix
- Extend ameba config and clear remaining lint findings

## v0.2.0

### Features
- Add `session/list` support — `SessionInfo`, `SessionListParams`, `SessionListResult` types, `SessionListCapabilities`, `Client#session_list`, and `Session.list` class method
- Add `SessionInfoUpdate` for session metadata change notifications (title, updatedAt)
- Add configurable `Client#prompt_timeout` property (default 5 minutes) for `session/prompt` requests

### Bug Fixes
- Fix race condition in `Client#send_request` — ID generation and pending channel registration are now atomic
- Fix permission handler error response — now returns a proper JSON-RPC error instead of a fake cancellation result
- Fix null safety in `Client#handle_session_update` — added nil checks for malformed params

### Improvements
- Extract duplicated `typed_content`/`typed_locations` methods into `ToolCallContentHelper` mixin
- Improve `ProcessTransport#close` — added duplicate-close guard, zombie process prevention, and graceful shutdown error handling
- Add consecutive dispatch error tracking to detect protocol corruption
- Fix `ConfigOption#grouped?` to use safer nil-aware check

### Removals
- Remove unused `Transport#send_json` convenience method

### Documentation
- Add full documentation site under `docs/`

### CI
- Add hwaro deploy workflow

## v0.1.0

- Initial release
