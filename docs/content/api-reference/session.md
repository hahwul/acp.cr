+++
title = "Session"
description = "High-level session wrapper for ACP operations"
weight = 2
+++

## Overview

`ACP::Session` is a convenience wrapper around `ACP::Client` that provides session-scoped operations. It manages the session ID and delegates to the underlying client.

## Factory Methods

### `.create`

```crystal
ACP::Session.create(
  client : ACP::Client,
  cwd : String,
  mcp_servers : Array(JSON::Any)? = nil,
  *,
  additional_directories : Array(String)? = nil,
  system_prompt : ACP::Protocol::SystemPrompt? = nil
) : ACP::Session
```

Creates a new session and returns a `Session` instance. See `Client#session_new` for `additional_directories` and `system_prompt`.

### `.load`

```crystal
ACP::Session.load(
  client : ACP::Client,
  session_id : String,
  cwd : String,
  mcp_servers : Array(JSON::Any)? = nil,
  *,
  additional_directories : Array(String)? = nil,
  system_prompt : ACP::Protocol::SystemPrompt? = nil
) : ACP::Session
```

Loads an existing session by ID and returns a `Session` instance.

## Prompt Methods

### `#prompt(text)`

```crystal
session.prompt(text : String) : ACP::Protocol::SessionPromptResult
```

Sends a single text prompt.

### `#prompt(*texts)`

```crystal
session.prompt(*texts : String) : ACP::Protocol::SessionPromptResult
```

Sends multiple text blocks as a single prompt.

### `#prompt(blocks)`

```crystal
session.prompt(
  blocks : Array(ACP::Protocol::ContentBlock)
) : ACP::Protocol::SessionPromptResult
```

Sends pre-built content blocks.

### `#prompt(&block)`

```crystal
session.prompt(
  &block : ACP::PromptBuilder ->
) : ACP::Protocol::SessionPromptResult
```

Sends a prompt built using the PromptBuilder DSL.

```crystal
result = session.prompt do |b|
  b.text("Review this code")
  b.resource_link("/path/to/file.cr", "text/x-crystal")
end
```

## Session Control

### `#cancel`

```crystal
session.cancel : Nil
```

Cancels an in-progress generation.

`session.subagents` returns the immediate children announced for that session
when the client advertises subagent support. Use the client's
`session_cancel(child.session_id)` when `child.cancel?` is true.

### `#mode=`

```crystal
session.mode = (mode_id : String)
```

Switches to one of the IDs in `available_mode_ids`.

### `#available_mode_ids`

```crystal
session.available_mode_ids : Array(String)
```

Returns the list of available mode IDs for the session.

### `#set_config_option`

```crystal
session.set_config_option(
  config_id : String,
  value : String | Bool
) : ACP::Protocol::SessionSetConfigOptionResult
```

Changes an option from the session's current `config_options`. Pass an
advertised value ID for a `select` option or a `Bool` for a negotiated
`boolean` option.

### `#close`

```crystal
session.close : Nil
```

Marks the session as closed.

### `#closed?`

```crystal
session.closed? : Bool
```

Returns whether the session is closed.

## Extension Methods

### `#ext_method`

```crystal
session.ext_method(
  method : String,
  params : Hash(String, JSON::Any::Type)? = nil
) : JSON::Any
```

Sends a custom extension request.

### `#ext_notification`

```crystal
session.ext_notification(
  method : String,
  params : Hash(String, JSON::Any::Type)? = nil
) : Nil
```

Sends a custom extension notification.

## Properties

| Property | Type | Description |
|----------|------|-------------|
| `id` | `String` | Session ID |
| `client` | `Client` | Underlying client |
| `modes` | `SessionModeState?` | Current mode and available modes |
| `config_options` | `Array(ConfigOption)?` | Latest configuration options advertised for this session |
