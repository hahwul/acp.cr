# Changelog

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
