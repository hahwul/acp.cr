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

ACP v2 resource links expose `icons` as `Array(Protocol::Icon)?`. Each
icon carries `src`, optional MIME type and sizes, and an open `theme`
string. Use `meta_raw` for exact extension metadata. When displaying icons,
apply the ACP icon-fetching rules to the supplied source URI.
[ACP v2 resource links](https://agentclientprotocol.com/protocol/v2/content#resource-link) ·
[ACP URI guidance](https://agentclientprotocol.com/protocol/v2/security#uris-and-remote-resources)

Use `size_bytes` for non-negative sizes through `UInt64::MAX`. The
existing `size` accessor retains the signed view used by ACP v1. Pass
`icons:` to a typed link or either `PromptBuilder#resource_link` overload.
The v2 client sends exact prompt content with `StdioTransport`. Custom
transports can override `send_wire` to support exact prompt frames.

Use `ContentBlock.from_v2_json` to decode ACP v2 display content directly.
Custom and future types yield an `UnknownContentBlock`. Its `type`,
`custom?`, and `raw` accessors expose the discriminator, the extension
namespace check, and the complete JSON payload. Standard types use their
typed decoders. User-message skill references use the dedicated
`skill_reference` and `skill_references` methods.
[ACP v2 content types](https://agentclientprotocol.com/protocol/v2/content#content-types)

V2 full messages and session-directed messages expose `content_blocks`
for display blocks and `content_raw` for the complete replacement. Ambiguous
optional fields are treated as omitted. An explicit `null` clears the
corresponding value.

Message and compaction summary chunks provide `to_content_chunk` with
exact `meta_raw`. Read a serialized v2 wrapper with
`ContentChunk.from_v2_json`. Message chunks also expose `content_raw`.
A message with an ambiguous ID or a chunk with unusable content has
no typed update. The data remains available in `SessionUpdateParams#raw`.
[ACP v2 message IDs](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle#message-ids)

Tool results and summary chunks provide `content_block`. Compaction
updates expose `typed_summary` and `summary_raw`. List helpers skip
malformed blocks and keep the usable blocks in wire order.

The mutable `JSON::Any` views expose representable fields. Updating or
reordering existing blocks preserves their other exact fields. A replacement
block uses the supplied `JSON::Any` value.

## Tool Call Content

Types for tool call content within updates:

| Type | Description |
|------|-------------|
| `ToolCallContentBlock` | Wraps a standard content block |
| `ToolCallDiff` | File modification diff (path, oldText, newText) |
| `ToolCallTerminal` | Embedded terminal reference by ID |
| `ToolCallSessionReference` | Display reference to a session by ID |
| `ToolCallLocation` | File location tracking (path, line) |

## Session Update Types

Session updates are received via the `on_update` callback. They form a discriminated union (`SessionUpdate`):

| Type | Key Fields |
|------|------------|
| `AgentMessageChunkUpdate` | `content : JSON::Any`, `text : String`, `message_id : String?` |
| `AgentThoughtChunkUpdate` | `content : JSON::Any`, `text : String`, `message_id : String?` |
| `ToolCallUpdate` | `tool_call_id : String`, `title : String`, `kind : String?`, `status : String?` |
| `ToolCallStatusUpdate` | `tool_call_id : String`, `status : String?`, `title : String?` |
| `PlanUpdate` | `entries : Array(PlanEntry)` for the session's baseline checklist |
| `IdentifiedPlanUpdate` | `plan : PlanUpdateContent` (needs `plan`) |
| `PlanRemovedUpdate` | `plan_id : String` (needs `plan`) |
| `SubagentUpdate` | Child `session_id` with optional capability, state, and workspace patches |
| `SessionMessageUpdate` | `message_id` with participant, linked transcript ID, and content patches |
| `SessionMessageChunkUpdate` | `message_id` and a single typed `content` block to append |
| `UserMessageChunkUpdate` | `content : JSON::Any`, `text : String`, `message_id : String?` |
| `AvailableCommandsUpdate` | `available_commands : Array(AvailableCommand)` |
| `CurrentModeUpdate` | `current_mode_id : String` |
| `ConfigOptionUpdate` | `config_options : Array(JSON::Any)`, `typed_config_options : Array(ConfigOption)` |
| `NoticeUpdate` | `severity : String`, `title : String`, `description : String?` (needs `session.notices`) |
| `CompactionUpdate` | `compaction_id : String`, `status : String`, `summary : Array(JSON::Any)?`, `error : String?`, `summary_present?`, `error_present?`, `typed_summary` (needs `session.compaction`) |
| `CompactionSummaryChunkUpdate` | `compaction_id : String`, `content : JSON::Any`, `text : String` (needs `session.compaction`) |

Use `to_content_chunk` on agent message, user message, and thought updates
to convert their payload to a typed `ContentChunk` with the same
`message_id` and extension metadata.

`CompactionUpdate`'s `summary`, `error` and `_meta` are patches. If a field is omitted, the stored value stays as it is. If it is `null`, the value is cleared. Both cases read as nil, so use `summary_present?` / `error_present?` / `meta_present?` to tell them apart.

Set `plan: ACP::Protocol::PlanCapabilities.new` in the client capabilities to
receive identified plans. In your callback, replace the entire plan for
`{params.session_id, update.plan.plan_id}` on each `IdentifiedPlanUpdate`.
`PlanItems` contains `entries`. `PlanMarkdown` contains the complete
`content` and an optional absolute `path`. On `PlanRemovedUpdate`, drop
the matching plan for that session. The client ignores removals of IDs it has
not received. See [ACP Agent Plan](https://agentclientprotocol.com/protocol/v1/agent-plan).

The `SubagentUpdate` and `SessionMessageUpdate` types expose `*_present?`
methods for patch fields. An omitted field retains its previous value and an
explicit `null` clears it. A `SubagentState` retains extension fields in
`json_unmapped`, including any payload for a future state or stop reason.
See [ACP Subagents](https://agentclientprotocol.com/protocol/v1/subagents).

## Token Usage

`SessionPromptResult#usage` exposes the optional draft v1 token report.
The Agent sends its accumulated counts with the completed prompt result.
`Usage` provides `total_tokens`, `input_tokens`, and `output_tokens` as
`UInt64`, plus optional reasoning and cache counts.

In v2, use `StateUpdate#usage` or `StateSnapshot#usage` for the token counts
the Agent reported for completed foreground work. A repeated or replayed
snapshot may carry the same usage and must not be counted again.

## ACP v2 Preview Wire Types

`ACP::Protocol::V2` contains preview wire types for initialization,
capabilities, authentication, session setup, configuration changes, and
prompt acknowledgements. It includes method names and structured
unsupported-version error data. Unknown authentication variants preserve
their payload for inspection or forwarding. `ACP::V2::Client` uses these
types for v2 connections. [Client API](/api-reference/client/#acp-v2-preview)
See [ACP v2 Initialization](https://agentclientprotocol.com/protocol/v2/initialization).

Use `ReplayFrom.start` in v2 `SessionResumeParams` to request replay from the
start of retained history. The v2 `SessionPromptParams` accepts an optional
`idempotency_key`, and its response carries the inserted `message_id`. The
Agent reports completion through a later session update.
See [ACP v2 Prompt Lifecycle](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle).

`V2::SessionUpdateParams` retains the original update fields. Its
`update.typed` accessor decodes foreground state, message upserts and chunks,
and replay completion. Use `StateUpdate#idle?` and `#stop_reason` to inspect
foreground completion. An absent or invalid background list represents
unreported work, and an empty list reports that no work is running. Unknown
background kinds still count as work. States and background entries expose
their exact fields through `raw` and `meta_raw`. State snapshots also expose
`background_raw`, `usage_raw`, and `error_raw` for their reported payloads.
[ACP v2 background work](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle#background-work)

For v2 upserts, `meta_present?` distinguishes a supplied patch from
omission, and `meta_raw` exposes the exact metadata object. Use
`apply_metadata_raw(previous)` to apply the patch to an existing
`RawJson?` snapshot. Null clears the snapshot or removes an individual
key, and other values replace their key whole. Use `apply_metadata` for a
`Hash(String, JSON::Any)` view.
[ACP v2 metadata patches](https://agentclientprotocol.com/protocol/v2/extensibility#metadata-patches)

`update.typed` also decodes tool-call and Agent-owned terminal updates and
chunks. Terminal snapshots and chunks expose decoded bytes through `bytes`.
The `*_present?` methods on upserts identify fields the update supplies,
including explicit clears.

Typed v2 display content validates Base64 media and absolute resource URIs.
An invalid optional image URI leaves the image data available. Embedded text
remains available when a sibling blob is invalid. Resource links omit invalid
sizes and icon entries. Display icons use credential-free HTTPS URLs or
Base64 image data URIs. Raw accessors retain the original values for inspection.
[ACP v2 content](https://agentclientprotocol.com/protocol/v2/content)

Terminal updates treat malformed optional fields as omitted. A concrete
`exit_status` still marks an exit when its code and signal are unknown.
Output snapshots and chunks validate standard Base64 on receipt. Decode each
chunk independently with `bytes` and append the decoded bytes in receive
order. A snapshot replaces the accumulated output. Repeated capability
fields clear the cancel grant for the addressed terminal.
[ACP v2 display-only terminals](https://agentclientprotocol.com/protocol/v2/tool-calls#display-only-terminals)

Tool-call updates and permission tool-call subjects treat malformed optional
fields as omitted. Content and locations arrays replace the previous list
with their usable entries in wire order. Explicit `null` and empty arrays
clear the list. Tool-call locations require absolute Agent-side paths.
An invalid optional line leaves just the path, and `meta_raw` exposes the
location's exact extension metadata.
[ACP v2 Tool Calls](https://agentclientprotocol.com/protocol/v2/tool-calls#following-the-agent)

Process `ToolCallContentChunk` in receive order with `ToolCallUpdate`.
Append each chunk's item to the content for its tool call. A later update's
present `content` field replaces or clears that list. Chunk metadata is scoped
to the chunk. Streamed and replacement content use the same item validation
and preserve custom and future payloads. An unusable chunk remains available
in the raw notification. `ToolCallStore` applies both variants to track the
current state. [Tool-call state](../client/#tool-call-state) · [ACP v2 streamed tool content](https://agentclientprotocol.com/protocol/v2/tool-calls#streaming-content)

`ToolCallContent#diff` exposes usable file changes in wire order and omits
entries with conflicting destination paths. It returns `nil` when no usable
changes remain. A malformed optional patch object leaves the structured
changes available. Use `changes` for affected paths, `git_patch` to select
patches labeled with ACP's standard format, and `patch` to inspect other
formats. Tool content and individual file changes expose open fields through
`raw`. Diffs, patches, file changes, tool content, and content chunks expose
exact metadata through `meta_raw`.
[ACP v2 Tool Calls](https://agentclientprotocol.com/protocol/v2/tool-calls#diffs)

Typed child-session announcements and the child cache use the same patch
rules. Malformed optional title, description, capability, or state values
are treated as omitted. A repeated capability field clears the cancel grant.
Child workspace values use absolute Agent-side paths.
An explicit `null` restores inheritance for that workspace field, and an
empty additional-directory list overrides inheritance. The cached
`SubagentSession#meta_raw` exposes the exact association metadata after
applying key-level patches.
[ACP v2 Subagents](https://agentclientprotocol.com/protocol/v2/subagents)

Session-directed messages keep independent local IDs in each session.
`sender_session_id`, `recipient_session_id`, `sender_message_id`, and
`recipient_message_id` patch independently. A malformed or ambiguous optional
field leaves the previous value in place. Chunk content appends in receive
order, and a present `content` patch replaces or clears the accumulated list.
Chunk metadata stays scoped to the chunk. Raw notifications retain the
received content and its exact values.
[ACP v2 session-directed messages](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle#session-directed-messages)

`SessionInfoUpdate`, `UsageUpdate`, and `CompactionUpdate` distinguish omitted
fields from clears and apply metadata patches by key. Invalid optional fields
leave the previous value in place. `updated_at` preserves the reported RFC 3339
string. A compaction summary patch replaces or clears accumulated content, and
usable summary chunks append in receive order. Raw notifications retain the
original values.
[ACP v2 compaction and usage](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle#session-compaction)

V2 notices use `NoticeUpdate` and expose the original severity, the
required title, and optional description. They are live events with no
capability requirement. Both notices and `ReplayCompleteUpdate` expose
exact event metadata through `meta_raw`. Each replay marker applies to
its own session, including during child-session replay.
[ACP v2 session notices](https://agentclientprotocol.com/protocol/v2/prompt-lifecycle#session-notices)
[ACP v2 replay completion](https://agentclientprotocol.com/protocol/v2/session-setup#replay-complete)

`V2::PlanUpdate#plan` exposes the plan ID and the full representation as
`raw`. Its `typed` accessor returns a checklist or a Markdown plan, and
checklists keep valid entries in order. Replace the whole plan for the
given session and plan ID, including when the representation is unknown.
`PlanRemovedUpdate` removes a known plan. The v2 client ignores removals
for plan IDs it has not received in that session. Register your callback
before creating or resuming the session. The client bounds the provisional
IDs it tracks before creation completes. Use `on_update` to receive
plans containing exact values outside `JSON::Any`.
[ACP v2 Agent Plan](https://agentclientprotocol.com/protocol/v2/agent-plan)

Session setup, option previews, option changes, and configuration updates
expose `typed_config_options` and `config_options_raw`. The typed view
keeps valid options in Agent order, including unrecognized option types.
The raw array retains the received values until the projected list is edited.
`ConfigOption#raw` preserves the option's extension fields. Select options
expose flat or grouped choices through `select_options`.
[ACP v2 configuration options](https://agentclientprotocol.com/protocol/v2/session-config-options)

Configuration lists, groups, and individual values retain exact JSON
metadata. Use `ConfigOptionGroup#options_raw` or `meta_raw` to read values
outside `JSON::Any`.

Session setup, option previews, and command updates expose
`available_commands_raw` and `typed_available_commands`. The raw list
preserves the received entries and reflects edits to the projected list.
Replacing an input object also replaces its previous extension data.
The typed list skips duplicate names and retains unrecognized command
types for inspection. Use `slash_command?`
to identify slash commands and `input` for their input specification.
Command inputs and typed skills expose exact metadata through `meta_raw`.
[ACP v2 slash commands](https://agentclientprotocol.com/protocol/v2/slash-commands)

## Capabilities

### ClientCapabilities

```crystal
ACP::Protocol::ClientCapabilities.new(
  fs : FsCapabilities? = nil,
  terminal : Bool = false,
  session : ClientSessionCapabilities? = nil,
  elicitation : ElicitationCapabilities? = nil,
  plan : PlanCapabilities? = nil,
  subagents : SubagentCapabilities? = nil,
  auth : ClientAuthCapabilities? = nil
)
```

| Field | Type | Description |
|-------|------|-------------|
| `fs` | `FsCapabilities?` | File system capabilities |
| `terminal?` | `Bool` | Terminal support |
| `session` | `ClientSessionCapabilities?` | `compaction`, `notices` and `config_options.boolean`; each one is opt-in |
| `elicitation` | `ElicitationCapabilities?` | Supported `elicitation/create` modes (`form`, `url`) |
| `plan` | `PlanCapabilities?` | Support for identified plan updates and removals |
| `subagents` | `SubagentCapabilities?` | Support for child sessions and session-directed messages |
| `auth` | `ClientAuthCapabilities?` | Opt-in terminal authentication |

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
