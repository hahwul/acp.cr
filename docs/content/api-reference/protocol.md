+++
title = "Protocol Types"
description = "ACP protocol type definitions and enumerations"
weight = 4
+++

## Overview

The `ACP::Protocol` module contains all JSON-RPC 2.0 and ACP schema types. All types use `JSON::Serializable` and many use discriminated unions for polymorphic deserialization.

## Enumerations

### StopReason

```crystal
enum ACP::Protocol::StopReason
  EndTurn
  MaxTokens
  MaxTurnRequests
  Refusal
  Cancelled
end
```

### ToolKind

```crystal
enum ACP::Protocol::ToolKind
  Read
  Edit
  Delete
  Move
  Search
  Execute
  Think
  Fetch
  SwitchMode
  Other
end
```

### ToolCallStatus

```crystal
enum ACP::Protocol::ToolCallStatus
  Pending
  InProgress
  Completed
  Failed
end
```

### PermissionOptionKind

```crystal
enum ACP::Protocol::PermissionOptionKind
  AllowOnce
  AllowAlways
  RejectOnce
  RejectAlways
end
```

### PlanEntryPriority

```crystal
enum ACP::Protocol::PlanEntryPriority
  High
  Medium
  Low
end
```

### PlanEntryStatus

```crystal
enum ACP::Protocol::PlanEntryStatus
  Pending
  InProgress
  Completed
end
```

### SessionConfigOptionCategory

```crystal
enum ACP::Protocol::SessionConfigOptionCategory
  Mode
  Model
  ThoughtLevel
  Other
end
```

### Role

```crystal
enum ACP::Protocol::Role
  Assistant
  User
end
```

## Content Blocks

Content blocks are used to construct prompts. They form a discriminated union (`ContentBlock`):

| Type | Description |
|------|-------------|
| `TextContentBlock` | Plain text with optional annotations |
| `ImageContentBlock` | Base64 image with MIME type |
| `AudioContentBlock` | Base64 audio with MIME type |
| `ResourceContentBlock` | Embedded resource (URI + content) |
| `ResourceLinkContentBlock` | Resource link with metadata |
| `FileContentBlock` | Backward-compatible alias for `ResourceLinkContentBlock` |

## Tool Call Content

Types for tool call content within updates:

| Type | Description |
|------|-------------|
| `ToolCallContentBlock` | Wraps a standard content block |
| `ToolCallDiff` | File modification diff (path, oldText, newText) |
| `ToolCallTerminal` | Embedded terminal reference by ID |
| `ToolCallLocation` | File location tracking (path, line) |

## Session Update Types

Session updates are received via the `on_update` callback. They form a discriminated union (`SessionUpdate`):

| Type | Key Fields |
|------|------------|
| `AgentMessageChunkUpdate` | `delta : String` |
| `AgentThoughtChunkUpdate` | `delta : String` |
| `ToolCallUpdate` | `tool_name : String`, `tool_call_id : String` |
| `ToolCallStatusUpdate` | `status : ToolCallStatus`, `tool_call_id : String` |
| `PlanUpdate` | `entries : Array(PlanEntry)` |
| `UserMessageChunkUpdate` | `delta : String` |
| `AvailableCommandsUpdate` | `commands : Array(Command)` |
| `CurrentModeUpdate` | `mode_id : String` |
| `ConfigOptionUpdate` | `config_id : String`, `value : JSON::Any` |

## Capabilities

### ClientCapabilities

```crystal
ACP::Protocol::ClientCapabilities.new(
  fs : FsCapabilities? = nil,
  terminal : Bool? = nil
)
```

| Field | Type | Description |
|-------|------|-------------|
| `fs` | `FsCapabilities?` | File system capabilities |
| `terminal` | `Bool?` | Terminal support |

### FsCapabilities

```crystal
ACP::Protocol::FsCapabilities.new(
  read_text_file : Bool? = nil,
  write_text_file : Bool? = nil
)
```

### AgentCapabilities

| Field | Type | Description |
|-------|------|-------------|
| `load_session` | `Bool?` | Session loading support |
| `prompt_capabilities` | `PromptCapabilities?` | Prompt format support |
| `mcp_capabilities` | `McpCapabilities?` | MCP support |
| `session_capabilities` | `SessionCapabilities?` | Session features |

### PromptCapabilities

| Field | Type | Description |
|-------|------|-------------|
| `image` | `Bool?` | Image content support |
| `audio` | `Bool?` | Audio content support |
| `embedded_context` | `Bool?` | Embedded context support |

## Client Methods

Types for agent-initiated requests:

### File System

| Method | Params | Result |
|--------|--------|--------|
| `fs/read_text_file` | `ReadTextFileParams` | `ReadTextFileResult` |
| `fs/write_text_file` | `WriteTextFileParams` | `WriteTextFileResult` |

### Terminal

| Method | Params | Result |
|--------|--------|--------|
| `terminal/create` | `CreateTerminalParams` | `CreateTerminalResult` |
| `terminal/output` | `TerminalOutputParams` | `TerminalOutputResult` |
| `terminal/release` | `ReleaseTerminalParams` | `ReleaseTerminalResult` |
| `terminal/wait_for_exit` | `WaitForTerminalExitParams` | `WaitForTerminalExitResult` |
| `terminal/kill` | `KillTerminalParams` | `KillTerminalResult` |

## Error Codes

```crystal
module ACP::Protocol::ErrorCode
  PARSE_ERROR       = -32700
  INVALID_REQUEST   = -32600
  METHOD_NOT_FOUND  = -32601
  INVALID_PARAMS    = -32602
  INTERNAL_ERROR    = -32603
  AUTH_REQUIRED     = -32000
  RESOURCE_NOT_FOUND = -32002
end
```
