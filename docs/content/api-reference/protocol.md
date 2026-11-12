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
| `AgentMessageChunkUpdate` | `content : JSON::Any`, `text : String`, `message_id : String?` |
| `AgentThoughtChunkUpdate` | `content : JSON::Any`, `text : String`, `message_id : String?` |
| `ToolCallUpdate` | `tool_call_id : String`, `title : String`, `kind : String?`, `status : String?` |
| `ToolCallStatusUpdate` | `tool_call_id : String`, `status : String?`, `title : String?` |
| `PlanUpdate` | `entries : Array(PlanEntry)` |
| `UserMessageChunkUpdate` | `content : JSON::Any`, `text : String`, `message_id : String?` |
| `AvailableCommandsUpdate` | `available_commands : Array(AvailableCommand)` |
| `CurrentModeUpdate` | `current_mode_id : String` |
| `ConfigOptionUpdate` | `config_options : Array(JSON::Any)`, `typed_config_options : Array(ConfigOption)` |
| `NoticeUpdate` | `severity : String`, `title : String`, `description : String?` (needs `session.notices`) |
| `CompactionUpdate` | `compaction_id : String`, `status : String`, `summary : Array(JSON::Any)?`, `error : String?`, `summary_present?`, `error_present?`, `typed_summary` (needs `session.compaction`) |
| `CompactionSummaryChunkUpdate` | `compaction_id : String`, `content : JSON::Any`, `text : String` (needs `session.compaction`) |

`CompactionUpdate`'s `summary`, `error` and `_meta` are patches. If a field is omitted, the stored value stays as it is. If it is `null`, the value is cleared. Both cases read as nil, so use `summary_present?` / `error_present?` / `meta_present?` to tell them apart.

## Capabilities

### ClientCapabilities

```crystal
ACP::Protocol::ClientCapabilities.new(
  fs : FsCapabilities? = nil,
  terminal : Bool = false,
  session : ClientSessionCapabilities? = nil,
  elicitation : ElicitationCapabilities? = nil
)
```

| Field | Type | Description |
|-------|------|-------------|
| `fs` | `FsCapabilities?` | File system capabilities |
| `terminal?` | `Bool` | Terminal support |
| `session` | `ClientSessionCapabilities?` | `compaction`, `notices` and `config_options.boolean`; each one is opt-in |
| `elicitation` | `ElicitationCapabilities?` | Supported `elicitation/create` modes (`form`, `url`) |

Nothing is advertised by default. Only set a capability once the client handles it.

### FsCapabilities

```crystal
ACP::Protocol::FsCapabilities.new(
  read_text_file : Bool = false,
  write_text_file : Bool = false
)
```

### AgentCapabilities

| Field | Type | Description |
|-------|------|-------------|
| `load_session` | `Bool?` | Session loading support |
| `prompt_capabilities` | `PromptCapabilities?` | Prompt format support |
| `mcp_capabilities` | `McpCapabilities?` | MCP support |
| `session_capabilities` | `SessionCapabilities?` | Session features: `list?`, `resume?`, `close?`, `delete?`, `additional_directories?`, `system_prompt?` (and `system_prompt.override?`) |
| `auth` | `AgentAuthCapabilities?` | `logout?` |

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

`WaitForTerminalExitResult#exit_code` and `TerminalExitStatus#exit_code` are `UInt32?` (schema `uint32`).

### Elicitation

| Method | Params | Result |
|--------|--------|--------|
| `elicitation/create` | `CreateElicitationParams` | `CreateElicitationResult` (`.accept(content)`, `.decline`, `.cancel`) |
| `elicitation/complete` (notification) | `CompleteElicitationParams` | -- |

`CreateElicitationParams` flattens the schema's mode and scope variants. A form request has `requested_schema : ElicitationSchema`, and a URL request has `elicitation_id` and `url`. A session-scoped request has `session_id` and may have `tool_call_id`; a request-scoped one has `request_id`. Each `ElicitationSchema` property is an `ElicitationPropertySchema` whose `property_type` is `string`, `number`, `integer`, `boolean` or `array`.

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
