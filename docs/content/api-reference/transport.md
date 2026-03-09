+++
title = "Transport"
description = "Transport layer for ACP communication"
weight = 3
+++

## Overview

The transport layer handles the low-level communication between the client and the agent process. All transports implement the abstract `ACP::Transport` base class using newline-delimited JSON over stdio.

## ACP::Transport (Abstract Base)

### `#send`

```crystal
transport.send(message : Hash) : Nil
```

Sends a JSON-RPC message to the agent.

### `#receive`

```crystal
transport.receive : JSON::Any?
```

Receives the next message from the agent. Blocks until a message is available. Returns `nil` if the transport is closed.

### `#close`

```crystal
transport.close : Nil
```

Closes the transport.

### `#closed?`

```crystal
transport.closed? : Bool
```

Returns whether the transport is closed.

## ACP::StdioTransport

Communicates over existing IO pairs using newline-delimited JSON.

### Constructor

```crystal
ACP::StdioTransport.new(
  reader : IO,
  writer : IO,
  buffer_size : Int32 = 256
)
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `reader` | `IO` | -- | IO to read agent messages from |
| `writer` | `IO` | -- | IO to write client messages to |
| `buffer_size` | `Int32` | `256` | Internal channel buffer size |

### `#receive(timeout)`

```crystal
transport.receive(timeout : Time::Span) : JSON::Any?
```

Receives a message with a timeout. Returns `nil` if no message arrives within the specified duration.

> The `StdioTransport` spawns a background reader fiber that continuously reads from the IO and pushes parsed JSON messages to a buffered channel.

## ACP::ProcessTransport

Spawns a child process and communicates over its stdin/stdout.

### Constructor

```crystal
ACP::ProcessTransport.new(
  command : String,
  args : Array(String) = [] of String,
  env : Hash(String, String)? = nil,
  chdir : String? = nil,
  stderr : IO? = nil,
  buffer_size : Int32 = 256
)
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `command` | `String` | -- | Command to spawn |
| `args` | `Array(String)` | `[]` | Command arguments |
| `env` | `Hash(String, String)?` | `nil` | Environment variables |
| `chdir` | `String?` | `nil` | Working directory for the process |
| `stderr` | `IO?` | `nil` | IO for stderr output (e.g., `STDERR`) |
| `buffer_size` | `Int32` | `256` | Internal channel buffer size |

### Process Management

```crystal
transport.process        # => Process (the spawned process)
transport.terminated?    # => Bool (has the process exited?)
transport.wait           # => Process::Status (blocks until process exits)
```

## ACP.connect

Convenience function that creates a `ProcessTransport`, wraps it in a `Client`, and calls `initialize_connection`:

```crystal
client = ACP.connect(
  command : String,
  args : Array(String) = [] of String,
  client_name : String = "acp-crystal",
  client_version : String = ACP::VERSION,
  capabilities : ACP::Protocol::ClientCapabilities = ACP::Protocol::ClientCapabilities.new,
  env : Hash(String, String)? = nil,
  chdir : String? = nil
) : ACP::Client
```

Example:

```crystal
client = ACP.connect(
  "npx",
  args: ["-y", "@anthropic-ai/claude-code", "--agent"],
  client_name: "my-editor",
  client_version: "1.0"
)
```
