# ACP — Agent Client Protocol for Crystal

An unofficial Crystal implementation of the [Agent Client Protocol (ACP)](https://agentclientprotocol.com), which defines a JSON-RPC 2.0 based communication standard between code editors (clients) and AI coding agents.

📖 **Full documentation is available at [acp.cr.hahwul.com](https://acp.cr.hahwul.com/)**

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  acp:
    github: hahwul/acp.cr
```

Then run:

```sh
shards install
```

## Quick Start

The snippet collects ACP updates for an application. Use the
[simple client example](examples/simple_client.cr) to display updates and agent
diagnostics in a terminal.

```crystal
require "acp"

Log.setup(:none)

begin
  File.open(File::NULL, "w") do |diagnostics|
    transport = ACP::ProcessTransport.new("my-agent", ["--stdio"], stderr: diagnostics)
    client = ACP::Client.new(transport, client_name: "my-editor")

    begin
      client.initialize_connection
      session = ACP::Session.create(client, cwd: Dir.current)

      updates = [] of ACP::Protocol::SessionUpdateParams
      client.on_update = ->(update : ACP::Protocol::SessionUpdateParams) do
        updates << update
        nil
      end

      result = session.prompt("Explain this codebase in one paragraph.")
      # Use updates and result.stop_reason in your application.
    ensure
      client.close
    end
  end
rescue ACP::Error
  STDERR.puts "ACP request failed."
  exit(1)
end
```

To select ACP v1 or v2 Preview automatically, use `ACP.connect_negotiated`.
It returns an initialized `ACP::Client` or `ACP::V2::Client` according to the
Agent's selection. [Client API](https://acp.cr.hahwul.com/api-reference/client/#automatic-version-negotiation)

To build a draft ACP proxy chain, compose `ACP::Proxy` and `ACP::Conductor`
over stdio. [Proxy Chains guide](https://acp.cr.hahwul.com/user-guide/proxy-chains/)

## Examples

Several examples are provided in the `examples/` directory:

- `simple_client.cr` — Basic connection and prompting
- `content_blocks.cr` — Rich prompts with multiple content types
- `claude_code_agent.cr` — Claude Code as an ACP agent
- `gemini_agent.cr` — Gemini CLI as an ACP agent
- `codex_agent.cr` — Codex via ACP adapter
- `copilot_agent.cr` — GitHub Copilot CLI via ACP
- `interactive_client.cr` — Full-featured interactive CLI client

```sh
crystal run examples/claude_code_agent.cr
crystal run examples/gemini_agent.cr
crystal run examples/interactive_client.cr -- my-agent --stdio
```

The examples display terminal control characters from agent messages,
diagnostics, and permission labels as visible escapes.

## Development

```sh
crystal spec
crystal tool format
```

## Contributing

1. Fork it (<https://github.com/hahwul/acp.cr/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [hahwul](https://github.com/hahwul) - creator and maintainer

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
