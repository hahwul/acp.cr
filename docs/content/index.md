+++
title = "acp.cr"
description = "Crystal implementation of the Agent Client Protocol"
+++

Crystal implementation of the Agent Client Protocol (ACP). Communicate with AI coding agents over stdio transport using JSON-RPC 2.0 directly from Crystal.

> **Zero dependencies** -- uses only the Crystal standard library.

## Overview

acp.cr provides a type-safe Crystal client for the Agent Client Protocol, a JSON-RPC 2.0 based communication standard that enables code editors and tools to communicate with AI coding agents. It supports initialization, authentication, session management, streaming updates, tool calls, and agent-initiated requests -- all over stdio transport.

## Quick Links

- **[Getting Started](/user-guide/getting-started/)** -- Installation, prerequisites, and your first program
- **[Basic Usage](/user-guide/basic-usage/)** -- Client, transport, and session management
- **[API Reference](/api-reference/client/)** -- Complete API documentation

## Features

- **Full ACP Protocol** -- Initialize, authenticate, create/load sessions, send prompts, handle streaming
- **Transport Abstraction** -- `StdioTransport` for IO pairs, `ProcessTransport` for spawning agents
- **Async Architecture** -- Background dispatcher fiber with Crystal channels for real-time streaming
- **Type-Safe API** -- All protocol types use `JSON::Serializable` with discriminated unions
- **Session Wrapper** -- High-level `Session` class for session-scoped operations
- **PromptBuilder DSL** -- Ergonomic content block construction with text, image, audio, and resource support

## Installation

Add acp.cr to your `shard.yml`:

```yaml
dependencies:
  acp:
    github: hahwul/acp.cr
```

Then run:

```bash
shards install
```
