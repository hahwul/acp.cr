# Changelog

## Unreleased

### Bug Fixes
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
