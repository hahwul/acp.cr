+++
title = "Basic Usage"
description = "Client lifecycle, transport, sessions, and prompting"
weight = 2
+++

## Client Lifecycle

The `ACP::Client` follows a state machine pattern:

```
Created → Initialized → SessionActive → Closed
```

Each state transition happens through specific method calls:

```crystal
client = ACP::Client.new(transport, client_name: "app", client_version: "1.0")
# State: Created

result = client.initialize_connection
# State: Initialized

session_result = client.session_new(Dir.current)
# State: SessionActive

client.close
# State: Closed
```

## Transport Options

### ProcessTransport

Spawns an agent process and communicates over stdio:

```crystal
transport = ACP::ProcessTransport.new(
  "npx",
  args: ["-y", "@anthropic-ai/claude-code", "--agent"],
  env: {"ANTHROPIC_API_KEY" => "sk-..."},
  chdir: Dir.current,
  stderr: STDERR
)
```

You can check the process status:

```crystal
transport.terminated?  # => false
transport.wait         # blocks until process exits
```

### StdioTransport

For working with existing IO pairs (e.g., pre-spawned processes):

```crystal
transport = ACP::StdioTransport.new(
  reader: io_read,
  writer: io_write,
  buffer_size: 256
)
```

## Sessions

### Creating a New Session

```crystal
session = ACP::Session.create(client, Dir.current)
```

### Loading an Existing Session

```crystal
session = ACP::Session.load(client, "session-id-123", Dir.current)
```

### Sending Prompts

Simple text prompt:

```crystal
result = session.prompt("Explain this code")
```

Multiple text blocks:

```crystal
result = session.prompt("First context", "Now do this")
```

Using the PromptBuilder DSL:

```crystal
result = session.prompt do |b|
  b.text("Review this file")
  b.resource_link("/path/to/file.cr", "text/x-crystal")
end
```

### Session Modes

Switch between available agent modes:

```crystal
# List available modes
session.available_mode_ids  # => ["code", "plan", "architect"]

# Switch mode
session.mode = "plan"
```

### Configuration Options

```crystal
session.set_config_option("model", "claude-sonnet")
```

## Handling Callbacks

Set up handlers on the client to process streaming updates and agent requests:

```crystal
client.on_update = ->(update : ACP::Protocol::SessionUpdate) {
  case update
  when ACP::Protocol::AgentMessageChunkUpdate
    print update.delta
  when ACP::Protocol::ToolCallUpdate
    puts "Tool: #{update.tool_name}"
  end
}

client.on_agent_request = ->(method : String, params : JSON::Any?) {
  # Handle permission requests, fs operations, etc.
  nil
}
```

### Typed Client Method Handlers

For specific agent-initiated requests, use typed handlers:

```crystal
client.on_read_text_file = ->(params : ACP::Protocol::ReadTextFileParams) {
  content = File.read(params.path)
  ACP::Protocol::ReadTextFileResult.new(content: content)
}

client.on_write_text_file = ->(params : ACP::Protocol::WriteTextFileParams) {
  File.write(params.path, params.content)
  ACP::Protocol::WriteTextFileResult.new(success: true)
}
```

## Error Handling

All errors inherit from `ACP::Error`. Wrap operations in begin/rescue:

```crystal
begin
  result = session.prompt("Do something")
rescue ex : ACP::RequestTimeoutError
  puts "Timed out: #{ex.message}"
rescue ex : ACP::ConnectionClosedError
  puts "Connection lost"
rescue ex : ACP::Error
  puts "ACP error: #{ex.message}"
end
```

See the [Error Handling guide](/user-guide/error-handling/) for detailed patterns.
