# ACP — Agent Client Protocol for Crystal

An unofficial Crystal implementation of the [Agent Client Protocol (ACP)](https://agentclientprotocol.com), which defines a JSON-RPC 2.0 based communication standard between code editors (clients) and AI coding agents.

📖 **Full documentation is available at [acp.cr.hahwul.com](https://acp.cr.hahwul.com/)**

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  acp:
    github: hahwul/acp
```

Then run:

```sh
shards install
```

## Quick Start

```crystal
require "acp"

# 1. Connect to an agent process via stdio
transport = ACP::ProcessTransport.new("my-agent", ["--stdio"])
client = ACP::Client.new(transport, client_name: "my-editor")

# 2. Initialize the connection (handshake)
init_result = client.initialize_connection

# 3. Create a new session
session = ACP::Session.create(client, cwd: Dir.current)

# 4. Handle streaming updates
client.on_update = ->(update : ACP::Protocol::SessionUpdateParams) do
  case u = update.update
  when ACP::Protocol::AgentMessageChunkUpdate
    print u.text  # Stream agent text to the terminal
  when ACP::Protocol::ToolCallUpdate
    puts "\n🔧 #{u.title} [#{u.status}]"
  when ACP::Protocol::AgentThoughtChunkUpdate
    puts "💭 #{u.text}"
  end
  nil
end

# 5. Send a prompt and wait for the result
result = session.prompt("Explain this codebase in one paragraph.")
puts "\n[Done — stop reason: #{result.stop_reason}]"

# 6. Clean up
client.close
```

## Examples

Several examples are provided in the `examples/` directory:

- `simple_client.cr` — Basic connection and prompting
- `content_blocks.cr` — Rich prompts with multiple content types
- `claude_code_agent.cr` — Claude Code as an ACP agent
- `gemini_agent.cr` — Gemini CLI as an ACP agent
- `codex_agent.cr` — Codex via ACP adapter
- `interactive_client.cr` — Full-featured interactive CLI client

```sh
crystal run examples/claude_code_agent.cr
crystal run examples/gemini_agent.cr
crystal run examples/interactive_client.cr -- my-agent --stdio
```

## Development

```sh
crystal spec
crystal tool format
```

## Contributing

1. Fork it (<https://github.com/hahwul/acp/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [hahwul](https://github.com/hahwul) - creator and maintainer

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
