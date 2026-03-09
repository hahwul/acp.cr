+++
title = "Error Handling"
description = "Handling errors and edge cases in acp.cr"
weight = 5
+++

## Error Hierarchy

All acp.cr errors inherit from `ACP::Error`:

```
ACP::Error
├── ACP::TransportError
│   ├── ACP::ConnectionClosedError
│   └── ACP::TransportTimeoutError
├── ACP::ProtocolError
│   └── ACP::VersionMismatchError
├── ACP::InvalidStateError
├── ACP::JsonRpcError
├── ACP::SessionNotFoundError
├── ACP::NoActiveSessionError
├── ACP::AuthenticationError
├── ACP::RequestTimeoutError
└── ACP::RequestCancelledError
```

## Common Patterns

### Connection Errors

```crystal
begin
  client = ACP.connect("agent-command", args: ["--stdio"],
    client_name: "app", client_version: "1.0")
rescue ex : ACP::TransportError
  puts "Failed to connect: #{ex.message}"
rescue ex : ACP::VersionMismatchError
  puts "Protocol version mismatch: #{ex.message}"
end
```

### Timeout Handling

The client has configurable timeouts:

```crystal
client.request_timeout = 30.0   # Default: 30 seconds
client.prompt_timeout = 300.0   # Default: 5 minutes
```

Handle timeout errors:

```crystal
begin
  result = session.prompt("Long running task")
rescue ex : ACP::RequestTimeoutError
  puts "Request timed out after #{client.prompt_timeout}s"
  session.cancel
end
```

### Session Errors

```crystal
begin
  session = ACP::Session.load(client, "invalid-id", Dir.current)
rescue ex : ACP::SessionNotFoundError
  puts "Session not found, creating new one"
  session = ACP::Session.create(client, Dir.current)
end
```

### State Validation

The client validates state transitions automatically:

```crystal
begin
  # This will fail if no session is active
  client.session_prompt_text("Hello")
rescue ex : ACP::NoActiveSessionError
  puts "No active session"
rescue ex : ACP::InvalidStateError
  puts "Client is in wrong state: #{ex.message}"
end
```

### JSON-RPC Errors

Errors returned by the agent in JSON-RPC format:

```crystal
begin
  result = session.prompt("Do something")
rescue ex : ACP::JsonRpcError
  puts "Agent error code: #{ex.code}"
  puts "Agent error message: #{ex.message}"
end
```

## Disconnect Recovery

```crystal
client.on_disconnect = -> {
  puts "Lost connection, attempting to reconnect..."
  # Your reconnection logic here
}
```

## Best Practices

- Always wrap `connect` and `prompt` calls in error handling
- Set appropriate timeouts for your use case
- Use `session.cancel` to clean up after timeouts
- Check `client.closed?` and `client.session_active?` before operations
- Handle `ConnectionClosedError` for graceful shutdown
