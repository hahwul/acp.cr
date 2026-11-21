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

### `#send_checked`

Runs a check before sending a message with a cursor. Custom transports that
queue writes can override this method to call the supplied block just before
writing the frame. If the block raises, leave the frame unsent. The default
implementation calls the block before delegating to `send`.

### `#receive`

```crystal
transport.receive : JSON::Any?
```

Receives the next message from the agent. Blocks until a message is available. Returns `nil` if the transport is closed.

### `#receive_frame`

```crystal
transport.receive_frame : ACP::Transport::IncomingFrame?
```

Returns a `JSON::Any` or a `Protocol::WireFrame` with exact JSON in
`#json`. Even in ordinary mode, stdio retains exact session updates,
some typed requests and responses, and frames outside the numeric range of
`JSON::Any`. Use `receive` for the projected `JSON::Any` view. Custom transports
can implement `receive_frame` to provide exact frames. The default
implementation calls `receive`.
Subclasses of `StdioTransport` or `ProcessTransport` that customize how the
client reads frames should override `receive_frame`.

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
  buffer_size : Int32? = nil,
  max_line_bytes : Int32 = 16 * 1024 * 1024,
  *,
  exact_frames : Bool = false
)
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `reader` | `IO` | -- | IO to read agent messages from |
| `writer` | `IO` | -- | IO to write client messages to |
| `buffer_size` | `Int32?` | `nil` | Internal channel capacity. Defaults to 256 in ordinary mode and 4 in exact mode |
| `max_line_bytes` | `Int32` | 16 MiB | Maximum JSON frame size in bytes |
| `exact_frames` | `Bool` | `false` | Preserve exact JSON on every frame for a proxy or conductor |

With `exact_frames: true`, use `receive_frame` and `send_wire` to preserve
numeric values and explicit nulls. Oversized input ends the connection, and
oversized exact output raises `TransportError`. In ordinary mode, the reader
drops oversized lines and resumes at the next line.

### `#receive(timeout)`

```crystal
transport.receive(timeout : Time::Span) : JSON::Any?
```

Receives a message with a timeout. Returns `nil` if no message arrives within the specified duration.

The stdio `receive` methods skip frames outside the range of `JSON::Any`.
`receive_frame(timeout)` also accepts a timeout. The `incoming` channel carries
both `JSON::Any` and `Protocol::WireFrame` values plus the `nil` EOF sentinel.

Client request methods returning `JSON::Any` raise `ProtocolError` when a
response payload exceeds that type's numeric range.

## ACP::ProcessTransport

Spawns a child process and communicates over its stdin/stdout.

### Constructor

```crystal
ACP::ProcessTransport.new(
  command : String,
  args : Array(String) = [] of String,
  env : Hash(String, String)? = nil,
  chdir : String? = nil,
  stderr : IO = STDERR,
  buffer_size : Int32? = nil,
  max_line_bytes : Int32 = 16 * 1024 * 1024,
  *,
  exact_frames : Bool = false
)
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `command` | `String` | -- | Command to spawn |
| `args` | `Array(String)` | `[]` | Command arguments |
| `env` | `Hash(String, String)?` | `nil` | Environment variables |
| `chdir` | `String?` | `nil` | Working directory for the process |
| `stderr` | `IO` | `STDERR` | Where the agent's stderr goes |
| `buffer_size` | `Int32?` | `nil` | Internal channel capacity. Defaults to 256 in ordinary mode and 4 in exact mode |
| `max_line_bytes` | `Int32` | 16 MiB | Maximum JSON frame size in bytes |
| `exact_frames` | `Bool` | `false` | Preserve exact JSON on every frame for a proxy or conductor |

Raises `ACP::TransportError` if the agent can't be started (missing command, bad `chdir`).

### Process Management

```crystal
transport.process        # => Process (the spawned process)
transport.terminated?    # => Bool (has the process exited?)
transport.wait           # => Process::Status (blocks until process exits)
```

Closing the transport closes the Agent's stdin and starts draining its remaining
stdout. The Agent gets one second to exit on its own, then two seconds after
SIGTERM before SIGKILL. The transport stops delivering messages immediately,
and the call waits through the grace periods when escalation is needed. Call `transport.wait` to wait for shutdown and read the exit status.

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
