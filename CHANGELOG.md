# Changelog

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
