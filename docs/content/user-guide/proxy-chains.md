+++
title = "Proxy Chains"
description = "Connect ACP clients and agents through one or more draft proxy components"
weight = 12
+++

`ACP::Conductor` and `ACP::Proxy` implement the draft
[Proxy Chains RFD](https://agentclientprotocol.com/rfds/proxy-chains) for ACP v1
and v2 Preview. A terminal conductor accepts `initialize`, sends
`proxy/initialize` to each proxy, and sends `initialize` to the final agent.
The chain negotiates one protocol version.

## Run a proxy component

Compile this program and pass its executable to a conductor. The default proxy
forwards ordinary requests and notifications in both directions, including
extension methods.

```crystal
require "acp"

ACP::Proxy.new(STDIN, STDOUT).run
```

Set `on_message` before `run` to forward a modified
`Protocol::ProxySuccessorMessage`, return a local `Protocol::ProxyReply`, or
return `nil` to drop a notification or answer a request with method not found.
The handler receives the direction and a boolean indicating whether the message
is a request. It runs on the routing fiber, so keep it short. Use
`on_initialize_result` to transform the successor's advertised fields while
keeping its `protocolVersion`.

## Run a conductor

```crystal
require "acp"

client = ACP::StdioTransport.new(STDIN, STDOUT, exact_frames: true)
proxy = ACP::ProcessTransport.new("./my-proxy", exact_frames: true)
agent = ACP::ProcessTransport.new("my-agent", ["--stdio"], exact_frames: true)

ACP::Conductor.new(client, agent, proxies: [proxy]).run
```

List proxies in order from the client to the agent. Pass `nil` for the agent
to run a nested conductor that receives `proxy/initialize` and connects to its
successor through its parent conductor. Use `versions: [1_u16]` or
`versions: [2_u16]` to restrict local protocol negotiation.

A conductor owns its transports and closes the chain when a component
disconnects. For stdio and process transports, use `exact_frames: true`. A
custom transport can preserve exact payloads by implementing
`Transport#receive_frame` and `Transport#send_wire`.

The relay assigns request IDs independently at each hop and translates
`$/cancel_request` to the next hop's ID. It retains exact JSON in parameters,
results, and errors, including unknown fields, explicit nulls, and large
numbers. `_meta` on a `proxy/successor` wrapper applies to that hop.
