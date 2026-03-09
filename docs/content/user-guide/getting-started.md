+++
title = "Getting Started"
description = "Installation, prerequisites, and your first acp.cr program"
weight = 1
+++

## Prerequisites

Before using acp.cr, ensure your environment meets these requirements:

| Requirement | Version |
|-------------|---------|
| Crystal | >= 1.19.1 |
| An ACP-compatible agent | e.g., Claude Code, Gemini CLI, Codex |

> acp.cr has zero external dependencies -- it uses only the Crystal standard library.

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  acp:
    github: hahwul/acp.cr
```

Then install:

```bash
shards install
```

## Your First Program

Create a file called `hello.cr`:

```crystal
require "acp"

# Connect to an ACP agent via process transport
client = ACP.connect(
  "npx",
  args: ["-y", "@anthropic-ai/claude-code", "--agent"],
  client_name: "my-app",
  client_version: "1.0.0"
)

# Create a new session
session = ACP::Session.create(client, Dir.current)

# Send a prompt and get the result
result = session.prompt("What is the capital of France?")
puts result.stop_reason

# Clean up
session.close
client.close
```

Run it:

```bash
crystal run hello.cr
```

## Using the Convenience Connect

`ACP.connect` is a shorthand that creates a `ProcessTransport`, wraps it in a `Client`, and calls `initialize_connection`:

```crystal
client = ACP.connect(
  "agent-command",
  args: ["--stdio"],
  client_name: "my-editor",
  client_version: "1.0",
  capabilities: ACP::Protocol::ClientCapabilities.new,
  env: {"KEY" => "value"},
  chdir: "/working/dir"
)
```

For more control, you can create the transport and client manually:

```crystal
transport = ACP::ProcessTransport.new(
  "agent-command",
  args: ["--stdio"]
)

client = ACP::Client.new(
  transport,
  client_name: "my-editor",
  client_version: "1.0"
)

result = client.initialize_connection
puts result.agent_info
```

## Supported Agents

acp.cr works with any ACP-compatible agent. Examples included in the project:

- **Claude Code** -- `npx -y @anthropic-ai/claude-code --agent`
- **Gemini CLI** -- `npx -y @anthropic-ai/claude-code --agent` (via adapter)
- **Codex** -- Via ACP adapter
- **GitHub Copilot** -- Via ACP integration
