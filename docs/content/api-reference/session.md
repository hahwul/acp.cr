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
  mcp_servers : Array(ACP::Protocol::McpServerConfig)? = nil
) : ACP::Session
```

Creates a new session and returns a `Session` instance.

### `.load`

```crystal
ACP::Session.load(
  client : ACP::Client,
  session_id : String,
  cwd : String,
  mcp_servers : Array(ACP::Protocol::McpServerConfig)? = nil
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

### `#mode=`

```crystal
session.mode = (mode_id : String)
```

Switches the session mode.

### `#available_mode_ids`

```crystal
session.available_mode_ids : Array(String)
```

Returns the list of available mode IDs for the session.

### `#set_config_option`

```crystal
session.set_config_option(
  config_id : String,
  value : JSON::Any::Type
) : ACP::Protocol::SessionSetConfigOptionResult
```

Changes a configuration option.

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
| `modes` | `SessionModeState?` | Available modes |
| `config_options` | `Array(ConfigOption)?` | Configuration options |
