+++
title = "Streaming"
description = "Real-time streaming of agent responses and updates"
weight = 3
+++

## Overview

acp.cr provides real-time streaming of agent responses through the `on_update` callback. The background dispatcher fiber routes all incoming session updates to your handler as they arrive.

## Setting Up Streaming

Register an update handler before sending prompts:

```crystal
client.on_update = ->(update : ACP::Protocol::SessionUpdate) {
  case update
  when ACP::Protocol::AgentMessageChunkUpdate
    print update.delta
  when ACP::Protocol::AgentThoughtChunkUpdate
    puts "[Thought] #{update.delta}"
  when ACP::Protocol::ToolCallUpdate
    puts "\n=> Tool: #{update.tool_name}"
  when ACP::Protocol::ToolCallStatusUpdate
    puts "   Status: #{update.status}"
  when ACP::Protocol::PlanUpdate
    update.entries.each do |entry|
      puts "  [#{entry.status}] #{entry.title}"
    end
  end
}

result = session.prompt("Refactor this function")
puts "\nDone: #{result.stop_reason}"
```

## Update Types

### Standard Updates

| Type | Description |
|------|-------------|
| `AgentMessageChunkUpdate` | Streamed text chunk from the agent |
| `AgentThoughtChunkUpdate` | Agent reasoning/chain-of-thought |
| `ToolCallUpdate` | Tool invocation initiated |
| `ToolCallStatusUpdate` | Tool status or result update |
| `PlanUpdate` | Execution plan with entries |
| `UserMessageChunkUpdate` | User message chunk (during replay) |
| `AvailableCommandsUpdate` | Slash commands changed |
| `CurrentModeUpdate` | Session mode changed |
| `ConfigOptionUpdate` | Configuration updated |

### Backward-Compatible Updates

These non-standard types are supported for backward compatibility with older agents:

| Type | Description |
|------|-------------|
| `AgentMessageStartUpdate` | Agent message generation started |
| `AgentMessageEndUpdate` | Agent message generation ended |
| `ToolCallChunkUpdate` | Tool call content chunk |
| `ToolCallEndUpdate` | Tool call completed |
| `StatusUpdate` | General status update |
| `ErrorUpdate` | Error notification |

## Cancellation

Cancel an in-progress generation:

```crystal
# From the session
session.cancel

# Or directly from the client
client.session_cancel
```

## Disconnect Handling

Register a disconnect handler to respond to connection loss:

```crystal
client.on_disconnect = -> {
  puts "Connection to agent lost"
  # Attempt reconnection or cleanup
}
```

## Notification Handling

Handle non-update notifications from the agent:

```crystal
client.on_notification = ->(method : String, params : JSON::Any?) {
  puts "Notification: #{method}"
}
```
