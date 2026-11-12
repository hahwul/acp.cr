+++
title = "Errors"
description = "Error types and error codes"
weight = 6
+++

## Overview

All acp.cr errors inherit from `ACP::Error`, which itself inherits from Crystal's `Exception`. Errors are organized by category: transport, protocol, state, and request-level.

## Error Hierarchy

### ACP::Error

Base class for all acp.cr errors.

```crystal
begin
  # any ACP operation
rescue ex : ACP::Error
  puts ex.message
end
```

### ACP::TransportError

Transport-level failure (e.g., broken pipe, IO error).

```crystal
rescue ex : ACP::TransportError
  puts "Transport failed: #{ex.message}"
```

### ACP::ConnectionClosedError

The connection is closed: raised by a call made after it closed, and by a request still waiting when the agent exits or `close` runs.

```crystal
rescue ex : ACP::ConnectionClosedError
  puts "Connection lost"
```

### ACP::TransportTimeoutError

A transport-level operation timed out. The built-in transports never raise it; a request that times out raises `RequestTimeoutError`.

```crystal
rescue ex : ACP::TransportTimeoutError
  puts "Transport timeout"
```

### ACP::ProtocolError

A protocol-level issue occurred (e.g., malformed message).

```crystal
rescue ex : ACP::ProtocolError
  puts "Protocol error: #{ex.message}"
```

### ACP::VersionMismatchError

The agent's protocol version is incompatible.

```crystal
rescue ex : ACP::VersionMismatchError
  puts "Version mismatch: #{ex.message}"
```

### ACP::InvalidStateError

An operation was attempted in the wrong client state.

```crystal
rescue ex : ACP::InvalidStateError
  puts "Invalid state: #{ex.message}"
```

### ACP::JsonRpcError

A JSON-RPC 2.0 error was returned by the agent.

```crystal
rescue ex : ACP::JsonRpcError
  puts "Error code: #{ex.code}"
  puts "Error message: #{ex.message}"
```

### ACP::SessionNotFoundError

The referenced session does not exist. The client never raises it itself: an agent reports an unknown session as a `JsonRpcError` with code `-32002` (`resource_not_found?`).

```crystal
rescue ex : ACP::SessionNotFoundError
  puts "Session not found"
```

### ACP::NoActiveSessionError

An operation requiring an active session was attempted without one.

```crystal
rescue ex : ACP::NoActiveSessionError
  puts "No active session"
```

### ACP::AuthenticationError

Authentication with the agent failed. The client never raises it itself: `authenticate` raises the agent's `JsonRpcError`, and a request that needs authentication fails with `-32000` (`auth_required?`).

```crystal
rescue ex : ACP::AuthenticationError
  puts "Auth failed: #{ex.message}"
```

### ACP::RequestTimeoutError

A request exceeded its timeout duration.

```crystal
rescue ex : ACP::RequestTimeoutError
  puts "Request timed out"
```

### ACP::RequestCancelledError

A request was cancelled before completion. The client never raises it itself: an agent answers a cancelled request with a `JsonRpcError` with code `-32800` (`request_cancelled?`).

```crystal
rescue ex : ACP::RequestCancelledError
  puts "Request cancelled"
```

## Error Codes

Standard JSON-RPC 2.0 error codes and ACP-specific codes:

| Constant | Value | Description |
|----------|-------|-------------|
| `PARSE_ERROR` | `-32700` | Invalid JSON received |
| `INVALID_REQUEST` | `-32600` | Invalid JSON-RPC request |
| `METHOD_NOT_FOUND` | `-32601` | Method does not exist |
| `INVALID_PARAMS` | `-32602` | Invalid method parameters |
| `INTERNAL_ERROR` | `-32603` | Internal error |
| `AUTH_REQUIRED` | `-32000` | Authentication required |
| `RESOURCE_NOT_FOUND` | `-32002` | Requested resource not found |
