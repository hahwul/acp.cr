require "./spec_helper"

# ─── Helper: In-Memory Transport ──────────────────────────────────────
#
# A test transport that uses IO::Memory pairs so we can simulate
# agent communication without spawning a real process.

class TestTransport < ACP::Transport
  getter writer_to_agent : IO::Memory
  getter reader_from_agent : IO::Memory
  getter incoming : Channel(JSON::Any?)
  getter? closed : Bool = false

  # Messages the "agent" has received (written by the client).
  getter sent_messages : Array(JSON::Any) = [] of JSON::Any

  # Queue of messages to deliver to the client (simulating agent responses).
  @response_queue : Array(JSON::Any) = [] of JSON::Any

  def initialize
    @writer_to_agent = IO::Memory.new
    @reader_from_agent = IO::Memory.new
    @incoming = Channel(JSON::Any?).new(64)
  end

  def send(message : Hash(String, JSON::Any)) : Nil
    raise ACP::ConnectionClosedError.new if @closed
    @sent_messages << JSON.parse(message.to_json)
  end

  def receive : JSON::Any?
    return if @closed
    begin
      @incoming.receive
    rescue Channel::ClosedError
      nil
    end
  end

  def close : Nil
    return if @closed
    @closed = true
    @incoming.close
  end

  # ─── Test helpers ───────────────────────────────────────────────────

  # Simulate the agent sending a message to the client.
  def inject_message(msg : JSON::Any?) : Nil
    @incoming.send(msg)
  end

  # Simulate the agent sending a raw JSON string.
  def inject_raw(json_str : String) : Nil
    inject_message(JSON.parse(json_str))
  end

  # Returns the last message sent by the client to the agent.
  def last_sent : JSON::Any?
    @sent_messages.last?
  end

  # Clears all recorded sent messages.
  def clear_sent : Nil
    @sent_messages.clear
  end
end

# Helper to build a standard initialize response for tests.
def build_init_response(id : Int64, protocol_version : UInt16 = 1_u16) : String
  <<-JSON
    {
      "jsonrpc": "2.0",
      "id": #{id},
      "result": {
        "protocolVersion": #{protocol_version},
        "agentCapabilities": {
          "loadSession": true,
          "promptCapabilities": {
            "image": true,
            "audio": false,
            "embeddedContext": true
          },
          "mcpCapabilities": {
            "http": false,
            "sse": false
          }
        },
        "authMethods": [],
        "agentInfo": {
          "name": "test-agent",
          "version": "1.0.0"
        }
      }
    }
    JSON
end

def build_session_new_response(id : Int64, session_id : String = "sess-001") : String
  <<-JSON
    {
      "jsonrpc": "2.0",
      "id": #{id},
      "result": {
        "sessionId": "#{session_id}",
        "modes": {
          "currentModeId": "code",
          "availableModes": [
            {"id": "code", "name": "Code Mode", "description": "Write code"},
            {"id": "chat", "name": "Chat Mode", "description": "Just chat"}
          ]
        },
        "configOptions": []
      }
    }
    JSON
end

def build_prompt_response(id : Int64, stop_reason : String = "end_turn") : String
  <<-JSON
    {
      "jsonrpc": "2.0",
      "id": #{id},
      "result": {
        "stopReason": "#{stop_reason}"
      }
    }
    JSON
end

def build_error_response(id : Int64, code : Int32 = -32600, message : String = "Invalid Request") : String
  <<-JSON
    {
      "jsonrpc": "2.0",
      "id": #{id},
      "error": {
        "code": #{code},
        "message": "#{message}"
      }
    }
    JSON
end

# ═══════════════════════════════════════════════════════════════════════
# Protocol Type Specs
# ═══════════════════════════════════════════════════════════════════════

describe ACP::Protocol do
  # ─── Capabilities ───────────────────────────────────────────────────

  describe ACP::Protocol::FsCapabilities do
    it "serializes with correct JSON keys" do
      fs = ACP::Protocol::FsCapabilities.new(
        read_text_file: true,
        write_text_file: false,
      )
      json = JSON.parse(fs.to_json)
      json["readTextFile"].as_bool.should be_true
      json["writeTextFile"].as_bool.should be_false
    end

    it "deserializes from JSON" do
      json_str = %({"readTextFile": true, "writeTextFile": true})
      fs = ACP::Protocol::FsCapabilities.from_json(json_str)
      fs.read_text_file?.should be_true
      fs.write_text_file?.should be_true
    end

    it "defaults all capabilities to false" do
      fs = ACP::Protocol::FsCapabilities.new
      fs.read_text_file?.should be_false
      fs.write_text_file?.should be_false
    end
  end

  describe ACP::Protocol::ClientCapabilities do
    it "serializes with fs and terminal" do
      caps = ACP::Protocol::ClientCapabilities.new(
        fs: ACP::Protocol::FsCapabilities.new(read_text_file: true),
        terminal: true
      )
      json = JSON.parse(caps.to_json)
      json["terminal"].as_bool.should be_true
      json["fs"]["readTextFile"].as_bool.should be_true
    end

    it "serializes with nil fs" do
      caps = ACP::Protocol::ClientCapabilities.new(terminal: false)
      json = JSON.parse(caps.to_json)
      json["terminal"].as_bool.should be_false
      json["fs"]?.try(&.raw).should be_nil
    end
  end

  describe ACP::Protocol::AgentCapabilities do
    it "deserializes from JSON" do
      json_str = %({"loadSession": true, "promptCapabilities": {"image": true, "audio": false, "embeddedContext": true}})
      caps = ACP::Protocol::AgentCapabilities.from_json(json_str)
      caps.load_session?.should be_true
      caps.prompt_capabilities.should_not be_nil
      pc = caps.prompt_capabilities.as(ACP::Protocol::PromptCapabilities)
      pc.image?.should be_true
      pc.audio?.should be_false
      pc.embedded_context?.should be_true
    end

    it "deserializes with mcpCapabilities" do
      json_str = %({"loadSession": false, "mcpCapabilities": {"http": true, "sse": false}})
      caps = ACP::Protocol::AgentCapabilities.from_json(json_str)
      caps.mcp_capabilities.should_not be_nil
      mc = caps.mcp_capabilities.as(ACP::Protocol::McpCapabilities)
      mc.http?.should be_true
      mc.sse?.should be_false
    end

    it "defaults to no capabilities" do
      caps = ACP::Protocol::AgentCapabilities.new
      caps.load_session?.should be_false
      caps.prompt_capabilities.should be_nil
      caps.mcp_capabilities.should be_nil
    end
  end

  describe ACP::Protocol::PromptCapabilities do
    it "round-trips through JSON" do
      original = ACP::Protocol::PromptCapabilities.new(image: true, audio: true, embedded_context: false)
      json_str = original.to_json
      restored = ACP::Protocol::PromptCapabilities.from_json(json_str)
      restored.image?.should be_true
      restored.audio?.should be_true
      restored.embedded_context?.should be_false
    end
  end

  describe ACP::Protocol::ClientInfo do
    it "serializes name and version" do
      info = ACP::Protocol::ClientInfo.new("my-editor", "2.1.0")
      json = JSON.parse(info.to_json)
      json["name"].as_s.should eq("my-editor")
      json["version"].as_s.should eq("2.1.0")
    end

    it "serializes with title" do
      info = ACP::Protocol::ClientInfo.new("my-editor", "2.1.0", title: "My Editor")
      json = JSON.parse(info.to_json)
      json["title"].as_s.should eq("My Editor")
    end
  end

  describe ACP::Protocol::AgentInfo do
    it "deserializes from JSON" do
      info = ACP::Protocol::AgentInfo.from_json(%({"name": "cool-agent", "version": "3.0"}))
      info.name.should eq("cool-agent")
      info.version.should eq("3.0")
    end

    it "deserializes with title" do
      info = ACP::Protocol::AgentInfo.from_json(%({"name": "cool-agent", "version": "3.0", "title": "Cool Agent"}))
      info.title.should eq("Cool Agent")
      info.display_name.should eq("Cool Agent")
    end

    it "falls back to name for display_name" do
      info = ACP::Protocol::AgentInfo.from_json(%({"name": "cool-agent", "version": "3.0"}))
      info.display_name.should eq("cool-agent")
    end
  end

  describe ACP::Protocol::McpServerStdio do
    it "serializes stdio transport" do
      server = ACP::Protocol::McpServerStdio.new(
        name: "filesystem",
        command: "/path/to/mcp-server",
        args: ["--stdio"],
        env: [ACP::Protocol::EnvVariable.new("API_KEY", "secret123")]
      )
      json = JSON.parse(server.to_json)
      json["name"].as_s.should eq("filesystem")
      json["command"].as_s.should eq("/path/to/mcp-server")
      json["args"].as_a.size.should eq(1)
      json["env"][0]["name"].as_s.should eq("API_KEY")
    end
  end

  describe ACP::Protocol::McpServerHttp do
    it "serializes http transport" do
      server = ACP::Protocol::McpServerHttp.new(
        name: "api-server",
        url: "https://api.example.com/mcp",
        headers: [ACP::Protocol::HttpHeader.new("Authorization", "Bearer token123")]
      )
      json = JSON.parse(server.to_json)
      json["type"].as_s.should eq("http")
      json["name"].as_s.should eq("api-server")
      json["url"].as_s.should eq("https://api.example.com/mcp")
      json["headers"][0]["name"].as_s.should eq("Authorization")
    end
  end

  # ─── Content Blocks ─────────────────────────────────────────────────

  describe ACP::Protocol::TextContentBlock do
    it "serializes with type discriminator" do
      block = ACP::Protocol::TextContentBlock.new("Hello, world!")
      json = JSON.parse(block.to_json)
      json["type"].as_s.should eq("text")
      json["text"].as_s.should eq("Hello, world!")
    end

    it "deserializes via ContentBlock discriminator" do
      json_str = %({"type": "text", "text": "Test content"})
      block = ACP::Protocol::ContentBlock.from_json(json_str)
      block.should be_a(ACP::Protocol::TextContentBlock)
      block.as(ACP::Protocol::TextContentBlock).content.should eq("Test content")
    end

    it "provides backward-compatible content alias" do
      block = ACP::Protocol::TextContentBlock.new("hello")
      block.content.should eq("hello")
      block.text.should eq("hello")
    end
  end

  describe ACP::Protocol::ImageContentBlock do
    it "serializes with data and mimeType" do
      block = ACP::Protocol::ImageContentBlock.new(data: "base64data==", mime_type: "image/png")
      json = JSON.parse(block.to_json)
      json["type"].as_s.should eq("image")
      json["data"].as_s.should eq("base64data==")
      json["mimeType"].as_s.should eq("image/png")
    end

    it "serializes with optional uri" do
      block = ACP::Protocol::ImageContentBlock.new(data: "base64data==", mime_type: "image/png", uri: "file:///tmp/img.png")
      json = JSON.parse(block.to_json)
      json["uri"].as_s.should eq("file:///tmp/img.png")
    end

    it "deserializes via ContentBlock discriminator" do
      json_str = %({"type": "image", "data": "base64data==", "mimeType": "image/png"})
      block = ACP::Protocol::ContentBlock.from_json(json_str)
      block.should be_a(ACP::Protocol::ImageContentBlock)
      block.as(ACP::Protocol::ImageContentBlock).data.should eq("base64data==")
    end
  end

  describe ACP::Protocol::AudioContentBlock do
    it "serializes with data and mimeType" do
      block = ACP::Protocol::AudioContentBlock.new(data: "base64data==", mime_type: "audio/wav")
      json = JSON.parse(block.to_json)
      json["type"].as_s.should eq("audio")
      json["data"].as_s.should eq("base64data==")
      json["mimeType"].as_s.should eq("audio/wav")
    end

    it "deserializes via ContentBlock discriminator" do
      json_str = %({"type": "audio", "data": "base64audio==", "mimeType": "audio/mp3"})
      block = ACP::Protocol::ContentBlock.from_json(json_str)
      block.should be_a(ACP::Protocol::AudioContentBlock)
    end
  end

  describe ACP::Protocol::ResourceContentBlock do
    it "creates with text resource" do
      block = ACP::Protocol::ResourceContentBlock.text(
        uri: "file:///home/user/code.cr",
        text: "puts :hello",
        mime_type: "text/x-crystal"
      )
      json = JSON.parse(block.to_json)
      json["type"].as_s.should eq("resource")
      json["resource"]["uri"].as_s.should eq("file:///home/user/code.cr")
      json["resource"]["text"].as_s.should eq("puts :hello")
      json["resource"]["mimeType"].as_s.should eq("text/x-crystal")
    end

    it "deserializes via ContentBlock discriminator" do
      json_str = %({"type": "resource", "resource": {"uri": "file:///tmp/test.txt", "text": "content"}})
      block = ACP::Protocol::ContentBlock.from_json(json_str)
      block.should be_a(ACP::Protocol::ResourceContentBlock)
      block.as(ACP::Protocol::ResourceContentBlock).uri.should eq("file:///tmp/test.txt")
      block.as(ACP::Protocol::ResourceContentBlock).text.should eq("content")
    end
  end

  describe ACP::Protocol::ResourceLinkContentBlock do
    it "serializes with required fields" do
      block = ACP::Protocol::ResourceLinkContentBlock.new(
        uri: "file:///home/user/doc.pdf",
        name: "doc.pdf",
        mime_type: "application/pdf",
        size: 1024_i64
      )
      json = JSON.parse(block.to_json)
      json["type"].as_s.should eq("resource_link")
      json["uri"].as_s.should eq("file:///home/user/doc.pdf")
      json["name"].as_s.should eq("doc.pdf")
      json["mimeType"].as_s.should eq("application/pdf")
      json["size"].as_i64.should eq(1024)
    end

    it "deserializes via ContentBlock discriminator" do
      json_str = %({"type": "resource_link", "uri": "file:///tmp/test.txt", "name": "test.txt"})
      block = ACP::Protocol::ContentBlock.from_json(json_str)
      block.should be_a(ACP::Protocol::ResourceLinkContentBlock)
    end

    it "creates from file path" do
      block = ACP::Protocol::ResourceLinkContentBlock.from_path("/path/to/file.txt")
      block.uri.should eq("file:///path/to/file.txt")
      block.name.should eq("file.txt")
      block.path.should eq("/path/to/file.txt")
    end
  end

  describe ACP::Protocol::ContentBlocks do
    it "creates text blocks" do
      block = ACP::Protocol::ContentBlocks.text("hello")
      block.should be_a(ACP::Protocol::TextContentBlock)
      block.content.should eq("hello")
    end

    it "creates image blocks" do
      block = ACP::Protocol::ContentBlocks.image("base64data==", "image/png")
      block.should be_a(ACP::Protocol::ImageContentBlock)
      block.data.should eq("base64data==")
      block.mime_type.should eq("image/png")
    end

    it "creates resource link blocks from file path" do
      block = ACP::Protocol::ResourceLinkContentBlock.from_path("/path/to/file.txt")
      block.should be_a(ACP::Protocol::ResourceLinkContentBlock)
      block.path.should eq("/path/to/file.txt")
    end

    it "creates resource link blocks" do
      block = ACP::Protocol::ContentBlocks.resource_link("file:///tmp/f.txt", "f.txt")
      block.should be_a(ACP::Protocol::ResourceLinkContentBlock)
      block.uri.should eq("file:///tmp/f.txt")
      block.name.should eq("f.txt")
    end
  end

  # ─── Session Update Types ──────────────────────────────────────────

  describe ACP::Protocol::SessionUpdate do
    # ── ACP Spec Standard Types (using "sessionUpdate" discriminator) ──

    it "deserializes agent_message_chunk" do
      json_str = %({"sessionUpdate": "agent_message_chunk", "content": "Hello from agent"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::AgentMessageChunkUpdate)
      update.as(ACP::Protocol::AgentMessageChunkUpdate).text.should eq("Hello from agent")
    end

    it "deserializes agent_thought_chunk" do
      json_str = %({"sessionUpdate": "agent_thought_chunk", "content": "Let me think..."})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::AgentThoughtChunkUpdate)
      u = update.as(ACP::Protocol::AgentThoughtChunkUpdate)
      u.text.should eq("Let me think...")
    end

    it "deserializes tool_call" do
      json_str = %({"sessionUpdate": "tool_call", "toolCallId": "tc-1", "title": "Read file", "toolName": "fs.read", "status": "pending"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::ToolCallUpdate)
      u = update.as(ACP::Protocol::ToolCallUpdate)
      u.tool_call_id.should eq("tc-1")
      u.title.should eq("Read file")
      u.tool_name.should eq("fs.read")
      u.status.should eq("pending")
    end

    it "deserializes tool_call_update" do
      json_str = %({"sessionUpdate": "tool_call_update", "toolCallId": "tc-1", "status": "in_progress"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::ToolCallStatusUpdate)
      u = update.as(ACP::Protocol::ToolCallStatusUpdate)
      u.tool_call_id.should eq("tc-1")
      u.status.should eq("in_progress")
    end

    it "deserializes plan with entries" do
      json_str = %({"sessionUpdate": "plan", "entries": [{"content": "Step 1", "priority": "high", "status": "completed"}, {"content": "Step 2", "priority": "medium", "status": "pending"}]})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::PlanUpdate)
      u = update.as(ACP::Protocol::PlanUpdate)
      entries = u.entries
      entries.size.should eq(2)
      entries[0].content.should eq("Step 1")
      entries[0].priority.should eq("high")
      entries[0].status.should eq("completed")
      entries[1].content.should eq("Step 2")
      entries[1].status.should eq("pending")
    end

    it "deserializes available_commands_update" do
      json_str = %({"sessionUpdate": "available_commands_update", "availableCommands": [{"name": "web", "description": "Search the web"}]})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::AvailableCommandsUpdate)
      u = update.as(ACP::Protocol::AvailableCommandsUpdate)
      u.available_commands.size.should eq(1)
      u.available_commands[0].name.should eq("web")
    end

    it "deserializes current_mode_update" do
      json_str = %({"sessionUpdate": "current_mode_update", "currentModeId": "code"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::CurrentModeUpdate)
      u = update.as(ACP::Protocol::CurrentModeUpdate)
      u.current_mode_id.should eq("code")
      u.mode_id.should eq("code")
    end

    it "deserializes config_option_update" do
      json_str = %({"sessionUpdate": "config_option_update", "configOptions": [{"id": "mode", "name": "Mode", "type": "select", "currentValue": "code"}]})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::ConfigOptionUpdate)
    end

    it "deserializes user_message_chunk" do
      json_str = %({"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "hello"}})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::UserMessageChunkUpdate)
      u = update.as(ACP::Protocol::UserMessageChunkUpdate)
      u.text.should eq("hello")
    end

    # ── Non-Standard / Backward Compatibility Types ──

    it "deserializes agent_message_start (non-standard)" do
      json_str = %({"sessionUpdate": "agent_message_start", "messageId": "msg-1", "role": "assistant"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::AgentMessageStartUpdate)
      u = update.as(ACP::Protocol::AgentMessageStartUpdate)
      u.message_id.should eq("msg-1")
      u.role.should eq("assistant")
    end

    it "deserializes agent_message_end (non-standard)" do
      json_str = %({"sessionUpdate": "agent_message_end", "stopReason": "end_turn"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::AgentMessageEndUpdate)
      update.as(ACP::Protocol::AgentMessageEndUpdate).stop_reason.should eq("end_turn")
    end

    it "deserializes thought as alias for agent_thought_chunk" do
      json_str = %({"sessionUpdate": "thought", "content": "Let me think..."})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::AgentThoughtChunkUpdate)
    end

    it "deserializes tool_call_start as alias for tool_call" do
      json_str = %({"sessionUpdate": "tool_call_start", "toolCallId": "tc-1", "title": "Read file", "status": "pending"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::ToolCallUpdate)
    end

    it "deserializes tool_call_chunk (non-standard)" do
      json_str = %({"sessionUpdate": "tool_call_chunk", "toolCallId": "tc-1", "content": "file data", "kind": "output"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::ToolCallChunkUpdate)
      u = update.as(ACP::Protocol::ToolCallChunkUpdate)
      u.tool_call_id.should eq("tc-1")
      u.content.should eq("file data")
      u.kind.should eq("output")
    end

    it "deserializes tool_call_end (non-standard)" do
      json_str = %({"sessionUpdate": "tool_call_end", "toolCallId": "tc-1", "status": "completed", "result": "done"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::ToolCallEndUpdate)
      u = update.as(ACP::Protocol::ToolCallEndUpdate)
      u.tool_call_id.should eq("tc-1")
      u.status.should eq("completed")
      u.result.should eq("done")
    end

    it "deserializes status (non-standard)" do
      json_str = %({"sessionUpdate": "status", "status": "thinking", "message": "Processing your request"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::StatusUpdate)
      u = update.as(ACP::Protocol::StatusUpdate)
      u.status.should eq("thinking")
      u.message.should eq("Processing your request")
    end

    it "deserializes error (non-standard)" do
      json_str = %({"sessionUpdate": "error", "message": "Something went wrong", "code": -1, "detail": "stack trace here"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::ErrorUpdate)
      u = update.as(ACP::Protocol::ErrorUpdate)
      u.message.should eq("Something went wrong")
      u.code.should eq(-1)
      u.detail.should eq("stack trace here")
    end

    # ── Serialization ──

    it "serializes with sessionUpdate discriminator field" do
      update = ACP::Protocol::AgentMessageChunkUpdate.new(content: JSON::Any.new("test"))
      json = JSON.parse(update.to_json)
      json["sessionUpdate"].as_s.should eq("agent_message_chunk")
      json.as_h.has_key?("type").should be_false
    end

    it "exposes backward-compatible .type accessor" do
      json_str = %({"sessionUpdate": "agent_message_chunk", "content": "Hello"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.type.should eq("agent_message_chunk")
    end
  end

  describe ACP::Protocol::SessionUpdateParams do
    it "deserializes full update notification params with sessionUpdate discriminator" do
      json_str = %({"sessionId": "sess-001", "update": {"sessionUpdate": "agent_message_chunk", "content": "Hi"}})
      params = ACP::Protocol::SessionUpdateParams.from_json(json_str)
      params.session_id.should eq("sess-001")
      params.update.should be_a(ACP::Protocol::AgentMessageChunkUpdate)
    end
  end

  # ─── Method Params & Results ────────────────────────────────────────

  describe ACP::Protocol::InitializeParams do
    it "serializes with correct JSON keys" do
      params = ACP::Protocol::InitializeParams.new(
        protocol_version: 1_u16,
        client_capabilities: ACP::Protocol::ClientCapabilities.new(terminal: true),
        client_info: ACP::Protocol::ClientInfo.new("test", "0.1")
      )
      json = JSON.parse(params.to_json)
      json["protocolVersion"].as_i.should eq(1)
      json["clientCapabilities"]["terminal"].as_bool.should be_true
      json["clientInfo"]["name"].as_s.should eq("test")
      json["clientInfo"]["version"].as_s.should eq("0.1")
    end
  end

  describe ACP::Protocol::InitializeResult do
    it "deserializes from JSON" do
      json_str = <<-JSON
        {
          "protocolVersion": 1,
          "agentCapabilities": {"loadSession": true, "promptCapabilities": {"image": true, "audio": false, "embeddedContext": false}},
          "authMethods": [{"id": "oauth"}],
          "agentInfo": {"name": "agent", "version": "1.0"}
        }
        JSON
      result = ACP::Protocol::InitializeResult.from_json(json_str)
      result.protocol_version.should eq(1)
      result.agent_capabilities.load_session?.should be_true
      result.agent_capabilities.prompt_capabilities.as(ACP::Protocol::PromptCapabilities).image?.should be_true
      result.auth_methods.as(Array(JSON::Any))[0]["id"].as_s.should eq("oauth")
      result.agent_info.as(ACP::Protocol::AgentInfo).name.should eq("agent")
    end

    it "deserializes with empty auth methods" do
      json_str = %({"protocolVersion": 1, "agentCapabilities": {}})
      result = ACP::Protocol::InitializeResult.from_json(json_str)
      result.auth_methods.should be_nil
      result.agent_info.should be_nil
    end
  end

  describe ACP::Protocol::AuthenticateParams do
    it "serializes method ID" do
      params = ACP::Protocol::AuthenticateParams.new("oauth")
      json = JSON.parse(params.to_json)
      json["methodId"].as_s.should eq("oauth")
    end
  end

  describe ACP::Protocol::SessionNewParams do
    it "serializes cwd and mcpServers" do
      server = ACP::Protocol::McpServerStdio.new(
        name: "filesystem",
        command: "/path/to/mcp",
        args: ["--stdio"]
      )
      servers = [server.as(ACP::Protocol::McpServer)]
      params = ACP::Protocol::SessionNewParams.new("/home/user/project", servers)
      json = JSON.parse(params.to_json)
      json["cwd"].as_s.should eq("/home/user/project")
      json["mcpServers"].as_a.size.should eq(1)
      json["mcpServers"][0]["name"].as_s.should eq("filesystem")
    end

    it "serializes without mcpServers" do
      params = ACP::Protocol::SessionNewParams.new("/tmp")
      json = JSON.parse(params.to_json)
      json["cwd"].as_s.should eq("/tmp")
      json["mcpServers"].as_a.should be_empty
    end
  end

  describe ACP::Protocol::SessionNewResult do
    it "deserializes session ID with modes" do
      json_str = <<-JSON
        {
          "sessionId": "sess-123",
          "modes": {
            "currentModeId": "code",
            "availableModes": [{"id": "code", "name": "Code"}]
          },
          "configOptions": [{"id": "model", "name": "Model", "configType": "select", "currentValue": "gpt4"}]
        }
        JSON
      result = ACP::Protocol::SessionNewResult.from_json(json_str)
      result.session_id.should eq("sess-123")
      modes = result.modes.as(ACP::Protocol::SessionModeState)
      modes.available_modes.size.should eq(1)
      modes.available_modes[0].id.should eq("code")
      modes.current_mode_id.should eq("code")
      result.config_options.as(Array(ACP::Protocol::ConfigOption)).size.should eq(1)
    end

    it "deserializes minimal response" do
      json_str = %({"sessionId": "sess-minimal"})
      result = ACP::Protocol::SessionNewResult.from_json(json_str)
      result.session_id.should eq("sess-minimal")
      result.modes.should be_nil
      result.config_options.should be_nil
    end
  end

  describe ACP::Protocol::SessionLoadParams do
    it "serializes with session ID, cwd, and mcpServers" do
      params = ACP::Protocol::SessionLoadParams.new("sess-123", "/tmp")
      json = JSON.parse(params.to_json)
      json["sessionId"].as_s.should eq("sess-123")
      json["cwd"].as_s.should eq("/tmp")
      json["mcpServers"].as_a.should be_empty
    end
  end

  describe ACP::Protocol::SessionPromptParams do
    it "serializes session ID and prompt blocks" do
      blocks = [ACP::Protocol::TextContentBlock.new("hello").as(ACP::Protocol::ContentBlock)]
      params = ACP::Protocol::SessionPromptParams.new("sess-001", blocks)
      json = JSON.parse(params.to_json)
      json["sessionId"].as_s.should eq("sess-001")
      json["prompt"].as_a.size.should eq(1)
      json["prompt"][0]["type"].as_s.should eq("text")
      json["prompt"][0]["text"].as_s.should eq("hello")
    end
  end

  describe ACP::Protocol::SessionPromptResult do
    it "deserializes stop reason" do
      result = ACP::Protocol::SessionPromptResult.from_json(%({"stopReason": "end_turn"}))
      result.stop_reason.should eq("end_turn")
    end

    it "handles various stop reasons" do
      %w[end_turn max_tokens refusal cancelled].each do |reason|
        result = ACP::Protocol::SessionPromptResult.from_json(%({"stopReason": "#{reason}"}))
        result.stop_reason.should eq(reason)
      end
    end
  end

  describe ACP::Protocol::SessionCancelParams do
    it "serializes session ID" do
      params = ACP::Protocol::SessionCancelParams.new("sess-001")
      json = JSON.parse(params.to_json)
      json["sessionId"].as_s.should eq("sess-001")
    end
  end

  describe ACP::Protocol::SessionSetModeParams do
    it "serializes session ID and mode ID" do
      params = ACP::Protocol::SessionSetModeParams.new("sess-001", "code")
      json = JSON.parse(params.to_json)
      json["sessionId"].as_s.should eq("sess-001")
      json["modeId"].as_s.should eq("code")
    end
  end

  describe ACP::Protocol::SessionSetModeResult do
    it "deserializes from empty JSON" do
      result = ACP::Protocol::SessionSetModeResult.from_json("{}")
      result.should be_a(ACP::Protocol::SessionSetModeResult)
    end
  end

  describe ACP::Protocol::AuthenticateResult do
    it "deserializes from empty JSON" do
      result = ACP::Protocol::AuthenticateResult.from_json("{}")
      result.should be_a(ACP::Protocol::AuthenticateResult)
    end
  end

  describe ACP::Protocol::ConfigOption do
    it "round-trips through JSON" do
      opt = ACP::Protocol::ConfigOption.new(
        id: "theme",
        name: "Theme",
        config_type: "select",
        current_value: "dark",
        options: [
          ACP::Protocol::ConfigOptionValue.new("light", "Light"),
          ACP::Protocol::ConfigOptionValue.new("dark", "Dark"),
        ],
        description: "UI Theme",
        category: "mode"
      )
      json_str = opt.to_json
      restored = ACP::Protocol::ConfigOption.from_json(json_str)
      restored.id.should eq("theme")
      restored.name.should eq("Theme")
      restored.label.should eq("Theme")
      restored.config_type.should eq("select")
      restored.current_value.should eq("dark")
      restored.value.should eq("dark")
      restored.options.as(Array(ACP::Protocol::ConfigOptionValue)).size.should eq(2)
      restored.description.should eq("UI Theme")
      restored.category.should eq("mode")
    end
  end

  describe ACP::Protocol::RequestPermissionParams do
    it "deserializes permission request" do
      json_str = <<-JSON
        {
        "sessionId": "sess-001",
        "toolCall": {
          "toolCallId": "tc-1",
          "title": "Write to file",
          "toolName": "fs.write",
          "input": {"path": "/tmp/file.txt", "content": "data"}
        },
        "options": [
          {"optionId": "allow_once", "name": "Allow Once", "kind": "allow_once"},
          {"optionId": "allow_always", "name": "Allow Always", "kind": "allow_always"},
          {"optionId": "deny", "name": "Deny", "kind": "reject_once"}
        ]
        }
        JSON
      params = ACP::Protocol::RequestPermissionParams.from_json(json_str)
      params.session_id.should eq("sess-001")
      params.tool_call.tool_call_id.should eq("tc-1")
      params.tool_call.tool_name.should eq("fs.write")
      params.options.size.should eq(3)
      params.options[0].option_id.should eq("allow_once")
      params.options[0].id.should eq("allow_once")
      params.options[0].kind.should eq("allow_once")
      params.options[1].label.should eq("Allow Always")
    end
  end

  describe ACP::Protocol::RequestPermissionResult do
    it "creates selected outcome" do
      result = ACP::Protocol::RequestPermissionResult.selected("allow_once")
      result.cancelled?.should be_false
      result.selected_option_id.should eq("allow_once")
    end

    it "creates cancelled outcome" do
      result = ACP::Protocol::RequestPermissionResult.cancelled
      result.cancelled?.should be_true
      result.selected_option_id.should be_nil
    end
  end

  describe ACP::Protocol::SessionMode do
    it "round-trips through JSON" do
      mode = ACP::Protocol::SessionMode.new("code", "Code Mode", "Write and edit code")
      json_str = mode.to_json
      restored = ACP::Protocol::SessionMode.from_json(json_str)
      restored.id.should eq("code")
      restored.name.should eq("Code Mode")
      restored.label.should eq("Code Mode")
      restored.description.should eq("Write and edit code")
    end
  end

  describe ACP::Protocol::SessionModeState do
    it "round-trips through JSON" do
      state = ACP::Protocol::SessionModeState.new(
        current_mode_id: "code",
        available_modes: [
          ACP::Protocol::SessionMode.new("code", "Code"),
          ACP::Protocol::SessionMode.new("chat", "Chat"),
        ]
      )
      json_str = state.to_json
      restored = ACP::Protocol::SessionModeState.from_json(json_str)
      restored.current_mode_id.should eq("code")
      restored.available_modes.size.should eq(2)
    end
  end

  describe ACP::Protocol::PlanEntry do
    it "round-trips through JSON" do
      entry = ACP::Protocol::PlanEntry.new("Implement feature", priority: "high", status: "in_progress")
      json_str = entry.to_json
      restored = ACP::Protocol::PlanEntry.from_json(json_str)
      restored.content.should eq("Implement feature")
      restored.priority.should eq("high")
      restored.status.should eq("in_progress")
    end

    it "defaults status to pending" do
      entry = ACP::Protocol::PlanEntry.new("Some step")
      entry.status.should eq("pending")
      entry.priority.should eq("medium")
    end
  end

  describe ACP::Protocol::SessionSetConfigOptionParams do
    it "serializes correctly" do
      params = ACP::Protocol::SessionSetConfigOptionParams.new("sess-001", "mode", "code")
      json = JSON.parse(params.to_json)
      json["sessionId"].as_s.should eq("sess-001")
      json["configId"].as_s.should eq("mode")
      json["value"].as_s.should eq("code")
    end
  end

  # ─── Message Classification ─────────────────────────────────────────

  describe ".classify_message" do
    it "classifies a response (id + result)" do
      msg = JSON.parse(%({"jsonrpc": "2.0", "id": 1, "result": {}}))
      ACP::Protocol.classify_message(msg).should eq(ACP::Protocol::MessageKind::Response)
    end

    it "classifies an error response (id + error)" do
      msg = JSON.parse(%({"jsonrpc": "2.0", "id": 1, "error": {"code": -1, "message": "fail"}}))
      ACP::Protocol.classify_message(msg).should eq(ACP::Protocol::MessageKind::Response)
    end

    it "classifies an agent request (id + method)" do
      msg = JSON.parse(%({"jsonrpc": "2.0", "id": "req-1", "method": "session/request_permission", "params": {}}))
      ACP::Protocol.classify_message(msg).should eq(ACP::Protocol::MessageKind::Request)
    end

    it "classifies a notification (method, no id)" do
      msg = JSON.parse(%({"jsonrpc": "2.0", "method": "session/update", "params": {}}))
      ACP::Protocol.classify_message(msg).should eq(ACP::Protocol::MessageKind::Notification)
    end
  end

  describe ".extract_id" do
    it "extracts integer ID" do
      msg = JSON.parse(%({"id": 42}))
      ACP::Protocol.extract_id(msg).should eq(42_i64)
    end

    it "extracts string ID" do
      msg = JSON.parse(%({"id": "req-abc"}))
      ACP::Protocol.extract_id(msg).should eq("req-abc")
    end

    it "returns nil when no ID" do
      msg = JSON.parse(%({"method": "test"}))
      ACP::Protocol.extract_id(msg).should be_nil
    end
  end

  # ─── Message Builders ──────────────────────────────────────────────

  describe ".build_request" do
    it "builds a valid JSON-RPC request with integer ID" do
      params = ACP::Protocol::SessionCancelParams.new("sess-001")
      msg = ACP::Protocol.build_request(1_i64, "session/cancel", params)
      msg["jsonrpc"].should eq(JSON::Any.new("2.0"))
      msg["id"].should eq(JSON::Any.new(1_i64))
      msg["method"].should eq(JSON::Any.new("session/cancel"))
      msg["params"].should_not be_nil
    end

    it "builds a valid JSON-RPC request with string ID" do
      params = ACP::Protocol::SessionCancelParams.new("sess-001")
      msg = ACP::Protocol.build_request("req-1", "session/cancel", params)
      msg["id"].should eq(JSON::Any.new("req-1"))
    end
  end

  describe ".build_notification" do
    it "builds a notification without ID" do
      params = ACP::Protocol::SessionCancelParams.new("sess-001")
      msg = ACP::Protocol.build_notification("session/cancel", params)
      msg["jsonrpc"].should eq(JSON::Any.new("2.0"))
      msg["method"].should eq(JSON::Any.new("session/cancel"))
      msg.has_key?("id").should be_false
    end
  end

  describe ".build_response_raw" do
    it "builds a success response" do
      result = JSON.parse(%({"stopReason": "end_turn"}))
      msg = ACP::Protocol.build_response_raw(1_i64, result)
      msg["jsonrpc"].should eq(JSON::Any.new("2.0"))
      msg["id"].should eq(JSON::Any.new(1_i64))
      msg["result"].should eq(result)
    end
  end

  describe ".build_error_response" do
    it "builds an error response" do
      msg = ACP::Protocol.build_error_response(1_i64, -32600, "Invalid Request")
      msg["jsonrpc"].should eq(JSON::Any.new("2.0"))
      msg["id"].should eq(JSON::Any.new(1_i64))
      error = msg["error"]
      error["code"].as_i.should eq(-32600)
      error["message"].as_s.should eq("Invalid Request")
    end

    it "includes optional data" do
      data = JSON.parse(%({"detail": "missing field"}))
      msg = ACP::Protocol.build_error_response(2_i64, -32602, "Invalid params", data)
      msg["error"]["data"]["detail"].as_s.should eq("missing field")
    end
  end
end

# ═══════════════════════════════════════════════════════════════════════
# Error Type Specs
# ═══════════════════════════════════════════════════════════════════════

describe ACP::Error do
  it "is the base error class" do
    error = ACP::Error.new("test error")
    error.message.should eq("test error")
  end
end

describe ACP::ConnectionClosedError do
  it "has a default message" do
    error = ACP::ConnectionClosedError.new
    error.message.should eq("Connection closed")
  end
end

describe ACP::VersionMismatchError do
  it "includes version info in message" do
    error = ACP::VersionMismatchError.new(1_u16, 2_u16)
    error.client_version.should eq(1_u16)
    error.agent_version.should eq(2_u16)
    error.message.as(String).should contain("1")
    error.message.as(String).should contain("2")
  end

  it "handles nil agent version" do
    error = ACP::VersionMismatchError.new(1_u16)
    error.agent_version.should be_nil
    error.message.as(String).should contain("unknown")
  end
end

describe ACP::InvalidStateError do
  it "has a default message" do
    error = ACP::InvalidStateError.new
    error.message.as(String).should contain("Invalid client state")
  end
end

describe ACP::JsonRpcError do
  it "stores code, message, and data" do
    data = JSON.parse(%({"info": "details"}))
    error = ACP::JsonRpcError.new(-32600, "Invalid Request", data)
    error.code.should eq(-32600)
    error.message.should eq("Invalid Request")
    error.data.should_not be_nil
  end

  it "identifies standard error types" do
    ACP::JsonRpcError.new(-32700, "Parse error").parse_error?.should be_true
    ACP::JsonRpcError.new(-32600, "Invalid Request").invalid_request?.should be_true
    ACP::JsonRpcError.new(-32601, "Method not found").method_not_found?.should be_true
    ACP::JsonRpcError.new(-32602, "Invalid params").invalid_params?.should be_true
    ACP::JsonRpcError.new(-32603, "Internal error").internal_error?.should be_true
  end

  it "identifies server errors" do
    ACP::JsonRpcError.new(-32000, "Server error").server_error?.should be_true
    ACP::JsonRpcError.new(-32050, "Server error").server_error?.should be_true
    ACP::JsonRpcError.new(-32099, "Server error").server_error?.should be_true
    ACP::JsonRpcError.new(-32100, "Not server error").server_error?.should be_false
    ACP::JsonRpcError.new(-31999, "Not server error").server_error?.should be_false
  end

  it "creates from JSON::Any" do
    obj = JSON.parse(%({"code": -32601, "message": "Method not found", "data": {"method": "foo"}}))
    error = ACP::JsonRpcError.from_json_any(obj)
    error.code.should eq(-32601)
    error.message.should eq("Method not found")
    error.data.as(JSON::Any)["method"].as_s.should eq("foo")
  end

  it "handles malformed JSON::Any gracefully" do
    obj = JSON.parse(%({}))
    error = ACP::JsonRpcError.from_json_any(obj)
    error.code.should eq(ACP::JsonRpcError::INTERNAL_ERROR)
    error.message.should eq("Unknown error")
  end

  it "formats to string" do
    error = ACP::JsonRpcError.new(-32600, "Invalid Request")
    str = String.build { |io| error.to_s(io) }
    str.should contain("JsonRpcError(-32600)")
    str.should contain("Invalid Request")
  end
end

describe ACP::SessionNotFoundError do
  it "includes session ID" do
    error = ACP::SessionNotFoundError.new("sess-123")
    error.session_id.should eq("sess-123")
    error.message.as(String).should contain("sess-123")
  end
end

describe ACP::NoActiveSessionError do
  it "has a default message" do
    error = ACP::NoActiveSessionError.new
    error.message.as(String).should contain("No active session")
  end
end

describe ACP::RequestTimeoutError do
  it "includes request ID and timeout" do
    error = ACP::RequestTimeoutError.new(42_i64, 30.0)
    error.request_id.should eq(42_i64)
    error.message.as(String).should contain("42")
    error.message.as(String).should contain("30.0")
  end
end

describe ACP::RequestCancelledError do
  it "includes request ID" do
    error = ACP::RequestCancelledError.new(7_i64)
    error.request_id.should eq(7_i64)
    error.message.as(String).should contain("7")
  end
end

# ═══════════════════════════════════════════════════════════════════════
# Transport Specs
# ═══════════════════════════════════════════════════════════════════════

describe ACP::StdioTransport do
  it "sends JSON messages as newline-delimited lines" do
    reader_io = IO::Memory.new
    writer_io = IO::Memory.new

    transport = ACP::StdioTransport.new(reader_io, writer_io)

    msg = Hash(String, JSON::Any).new
    msg["jsonrpc"] = JSON::Any.new("2.0")
    msg["method"] = JSON::Any.new("test")
    transport.send(msg)

    output = writer_io.to_s
    output.should contain("\"jsonrpc\":\"2.0\"")
    output.should end_with("\n")

    transport.close
  end

  it "reports closed state" do
    reader_io = IO::Memory.new
    writer_io = IO::Memory.new
    transport = ACP::StdioTransport.new(reader_io, writer_io)
    transport.closed?.should be_false
    transport.close
    transport.closed?.should be_true
  end

  it "raises ConnectionClosedError when sending after close" do
    reader_io = IO::Memory.new
    writer_io = IO::Memory.new
    transport = ACP::StdioTransport.new(reader_io, writer_io)
    transport.close

    msg = Hash(String, JSON::Any).new
    msg["test"] = JSON::Any.new("value")

    expect_raises(ACP::ConnectionClosedError) do
      transport.send(msg)
    end
  end

  it "reads newline-delimited JSON messages from reader" do
    # Create a pipe so the reader fiber can read from it
    reader_r, reader_w = IO.pipe
    writer_io = IO::Memory.new

    transport = ACP::StdioTransport.new(reader_r, writer_io)

    # Write a JSON message to the reader end
    reader_w.puts %({"jsonrpc": "2.0", "method": "test", "params": {}})
    reader_w.flush

    # Receive should return the parsed message
    msg = transport.receive
    msg.should_not be_nil
    msg.as(JSON::Any)["method"].as_s.should eq("test")

    reader_w.close
    transport.close
  end

  it "returns nil when receive times out" do
    reader_r, reader_w = IO.pipe
    writer_io = IO::Memory.new

    transport = ACP::StdioTransport.new(reader_r, writer_io)

    # Don't write anything to reader_w

    # Should return nil after timeout
    msg = transport.receive(10.milliseconds)
    msg.should be_nil

    reader_w.close
    transport.close
  end

  it "receives message within timeout" do
    reader_r, reader_w = IO.pipe
    writer_io = IO::Memory.new

    transport = ACP::StdioTransport.new(reader_r, writer_io)

    spawn do
      sleep 5.milliseconds
      reader_w.puts %({"jsonrpc": "2.0", "method": "test"})
      reader_w.flush
    end

    msg = transport.receive(50.milliseconds)
    msg.should_not be_nil
    msg.as(JSON::Any)["method"].as_s.should eq("test")

    reader_w.close
    transport.close
  end

  it "returns nil if message arrives after timeout" do
    reader_r, reader_w = IO.pipe
    writer_io = IO::Memory.new

    transport = ACP::StdioTransport.new(reader_r, writer_io)

    spawn do
      sleep 50.milliseconds
      reader_w.puts %({"jsonrpc": "2.0", "method": "late"})
      reader_w.flush
    end

    # Timeout is 10ms, message comes at 50ms
    msg = transport.receive(10.milliseconds)
    msg.should be_nil

    # Clean up - make sure we can still read it later if we wait
    msg_late = transport.receive
    msg_late.should_not be_nil

    reader_w.close
    transport.close
  end

  it "returns nil on EOF" do
    reader_r, reader_w = IO.pipe
    writer_io = IO::Memory.new

    transport = ACP::StdioTransport.new(reader_r, writer_io)

    # Close the writer to signal EOF
    reader_w.close

    msg = transport.receive
    # After EOF, receive returns nil
    msg.should be_nil
    transport.close
  end

  it "skips malformed JSON lines without crashing" do
    reader_r, reader_w = IO.pipe
    writer_io = IO::Memory.new

    transport = ACP::StdioTransport.new(reader_r, writer_io)

    # Send a malformed line followed by a valid one
    reader_w.puts "this is not json"
    reader_w.puts %({"jsonrpc": "2.0", "method": "valid"})
    reader_w.flush

    # The transport should skip the bad line and deliver the valid one
    msg = transport.receive
    msg.should_not be_nil
    msg.as(JSON::Any)["method"].as_s.should eq("valid")

    reader_w.close
    transport.close
  end

  it "handles multiple messages in sequence" do
    reader_r, reader_w = IO.pipe
    writer_io = IO::Memory.new

    transport = ACP::StdioTransport.new(reader_r, writer_io)

    reader_w.puts %({"id": 1})
    reader_w.puts %({"id": 2})
    reader_w.puts %({"id": 3})
    reader_w.flush

    msg1 = transport.receive
    msg2 = transport.receive
    msg3 = transport.receive

    msg1.as(JSON::Any)["id"].as_i.should eq(1)
    msg2.as(JSON::Any)["id"].as_i.should eq(2)
    msg3.as(JSON::Any)["id"].as_i.should eq(3)

    reader_w.close
    transport.close
  end
end

describe TestTransport do
  it "records sent messages" do
    t = TestTransport.new
    msg = Hash(String, JSON::Any).new
    msg["test"] = JSON::Any.new("hello")
    t.send(msg)
    t.sent_messages.size.should eq(1)
    t.last_sent.as(JSON::Any)["test"].as_s.should eq("hello")
  end

  it "delivers injected messages" do
    t = TestTransport.new
    t.inject_raw(%({"method": "test"}))
    msg = t.receive
    msg.should_not be_nil
    msg.as(JSON::Any)["method"].as_s.should eq("test")
    t.close
  end

  it "raises on send after close" do
    t = TestTransport.new
    t.close
    msg = Hash(String, JSON::Any).new
    expect_raises(ACP::ConnectionClosedError) do
      t.send(msg)
    end
  end
end

# ═══════════════════════════════════════════════════════════════════════
# Client Specs
# ═══════════════════════════════════════════════════════════════════════

describe ACP::Client do
  describe "#initialize" do
    it "starts in Created state" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)
      client.state.should eq(ACP::ClientState::Created)
      client.closed?.should be_false
      transport.close
    end

    it "uses default client info" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)
      client.client_info.name.should eq("acp-crystal")
      client.client_info.version.should eq(ACP::VERSION)
      transport.close
    end

    it "accepts custom client info" do
      transport = TestTransport.new
      client = ACP::Client.new(transport, client_name: "my-editor", client_version: "5.0")
      client.client_info.name.should eq("my-editor")
      client.client_info.version.should eq("5.0")
      transport.close
    end
  end

  describe "#initialize_connection" do
    it "sends initialize request and processes response" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      # Simulate the agent responding in a fiber
      spawn do
        sleep 10.milliseconds
        # The client will have sent a request; respond to it
        if msg = transport.last_sent
          id = msg["id"].as_i64
          transport.inject_raw(build_init_response(id))
        end
      end

      result = client.initialize_connection
      result.protocol_version.should eq(1_u16)
      result.agent_info.as(ACP::Protocol::AgentInfo).name.should eq("test-agent")
      result.agent_capabilities.load_session?.should be_true

      client.state.should eq(ACP::ClientState::Initialized)
      client.agent_capabilities.as(ACP::Protocol::AgentCapabilities).load_session?.should be_true
      client.agent_info.as(ACP::Protocol::AgentInfo).name.should eq("test-agent")
      client.negotiated_protocol_version.should eq(1_u16)

      transport.close
    end

    it "raises InvalidStateError if already initialized" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          id = msg["id"].as_i64
          transport.inject_raw(build_init_response(id))
        end
      end

      client.initialize_connection

      expect_raises(ACP::InvalidStateError) do
        client.initialize_connection
      end

      transport.close
    end

    it "sends correct initialize params" do
      transport = TestTransport.new
      caps = ACP::Protocol::ClientCapabilities.new(
        fs: ACP::Protocol::FsCapabilities.new(read_text_file: true),
        terminal: true
      )
      client = ACP::Client.new(transport, client_name: "test-editor", client_version: "1.0", client_capabilities: caps)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          id = msg["id"].as_i64
          transport.inject_raw(build_init_response(id))
        end
      end

      client.initialize_connection

      sent = transport.sent_messages.first
      sent["method"].as_s.should eq("initialize")
      params = sent["params"]
      params["protocolVersion"].as_i.should eq(1)
      params["clientInfo"]["name"].as_s.should eq("test-editor")
      params["clientCapabilities"]["terminal"].as_bool.should be_true
      params["clientCapabilities"]["fs"]["readTextFile"].as_bool.should be_true

      transport.close
    end

    it "raises VersionMismatchError on incompatible protocol version" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          id = msg["id"].as_i64
          transport.inject_raw(build_init_response(id, protocol_version: 99_u16))
        end
      end

      expect_raises(ACP::VersionMismatchError) do
        client.initialize_connection
      end

      transport.close
    end

    it "raises JsonRpcError when agent returns an error" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          id = msg["id"].as_i64
          transport.inject_raw(build_error_response(id, -32603, "Agent init failed"))
        end
      end

      expect_raises(ACP::JsonRpcError) do
        client.initialize_connection
      end

      transport.close
    end
  end

  describe "#session_new" do
    it "creates a session after initialization" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      # Initialize first
      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          id = msg["id"].as_i64
          transport.inject_raw(build_init_response(id))
        end
      end
      client.initialize_connection

      # Then create session
      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        id = sent["id"].as_i64
        transport.inject_raw(build_session_new_response(id, "sess-test-001"))
      end

      result = client.session_new("/tmp/project")
      result.session_id.should eq("sess-test-001")
      result.modes.as(ACP::Protocol::SessionModeState).available_modes.size.should eq(2)

      client.state.should eq(ACP::ClientState::SessionActive)
      client.session_id.should eq("sess-test-001")
      client.session_active?.should be_true

      transport.close
    end

    it "sends correct params" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64))
        end
      end
      client.initialize_connection

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64))
      end

      server = ACP::Protocol::McpServerStdio.new(name: "test", command: "/bin/test")
      servers = [JSON.parse(server.to_json)]
      client.session_new("/my/project", servers)

      # Find the session/new request
      session_req = transport.sent_messages.find { |msg| msg["method"]?.try(&.as_s?) == "session/new" }
      session_req.should_not be_nil
      params = session_req.as(JSON::Any)["params"]
      params["cwd"].as_s.should eq("/my/project")
      json_servers = params["mcpServers"].as_a
      json_servers.size.should eq(1)

      transport.close
    end

    it "raises InvalidStateError if not initialized" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      expect_raises(ACP::InvalidStateError) do
        client.session_new("/tmp")
      end

      transport.close
    end

    it "loads a session after initialization" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64))
        end
      end
      client.initialize_connection

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(<<-JSON
          {
          "jsonrpc": "2.0",
          "id": #{sent["id"].as_i64},
          "result": {
            "modes": {
              "currentModeId": "code",
              "availableModes": [
                {"id": "code", "name": "Code Mode"}
              ]
            }
          }
          }
          JSON
        )
      end

      _result = client.session_load("sess-loaded", "/tmp")
      client.session_id.should eq("sess-loaded")
      client.state.should eq(ACP::ClientState::SessionActive)

      transport.close
    end
  end

  describe "#session_set_mode" do
    it "sends session/set_mode request" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64))
        end
      end
      client.initialize_connection

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64))
      end
      client.session_new("/tmp")

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(<<-JSON
          {
          "jsonrpc": "2.0",
          "id": #{sent["id"].as_i64},
          "result": {}
          }
          JSON
        )
      end

      client.session_set_mode("chat")

      sent = transport.sent_messages.last
      sent["method"].as_s.should eq("session/set_mode")
      sent["params"]["modeId"].as_s.should eq("chat")

      transport.close
    end
  end

  describe "#session_prompt_text" do
    it "sends text prompt and returns result" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      # Initialize
      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64))
        end
      end
      client.initialize_connection

      # Create session
      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64))
      end
      client.session_new("/tmp")

      # Send prompt
      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_prompt_response(sent["id"].as_i64, "end_turn"))
      end

      result = client.session_prompt_text("Hello!")
      result.stop_reason.should eq("end_turn")

      # Verify the prompt message structure
      prompt_req = transport.sent_messages.find { |msg| msg["method"]?.try(&.as_s?) == "session/prompt" }
      prompt_req.should_not be_nil
      params = prompt_req.as(JSON::Any)["params"]
      params["sessionId"].as_s.should_not be_empty
      params["prompt"].as_a.size.should eq(1)
      params["prompt"][0]["type"].as_s.should eq("text")
      params["prompt"][0]["text"].as_s.should eq("Hello!")

      transport.close
    end

    it "raises NoActiveSessionError without a session" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64))
        end
      end
      client.initialize_connection

      expect_raises(ACP::NoActiveSessionError) do
        client.session_prompt_text("Hello")
      end

      transport.close
    end
  end

  describe "#session_cancel" do
    it "sends a cancel notification" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      # Initialize and create session
      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64))
        end
      end
      client.initialize_connection

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64, "sess-cancel-test"))
      end
      client.session_new("/tmp")

      transport.clear_sent
      client.session_cancel

      # Verify the cancel notification
      cancel_msg = transport.last_sent
      cancel_msg.should_not be_nil
      cancel = cancel_msg.as(JSON::Any)
      cancel["method"].as_s.should eq("session/cancel")
      cancel.as_h.has_key?("id").should be_false
      cancel["params"]["sessionId"].as_s.should eq("sess-cancel-test")

      transport.close
    end

    it "raises NoActiveSessionError without a session" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64))
        end
      end
      client.initialize_connection

      expect_raises(ACP::NoActiveSessionError) do
        client.session_cancel
      end

      transport.close
    end
  end

  describe "#close" do
    it "transitions to Closed state" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)
      client.close
      client.closed?.should be_true
      client.state.should eq(ACP::ClientState::Closed)
    end

    it "is idempotent" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)
      client.close
      client.close # Should not raise
      client.closed?.should be_true
    end

    it "closes the transport" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)
      client.close
      transport.closed?.should be_true
    end
  end

  describe "notification handling" do
    it "dispatches session/update notifications to on_update" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      received_updates = [] of ACP::Protocol::SessionUpdateParams
      client.on_update = ->(update : ACP::Protocol::SessionUpdateParams) do
        received_updates << update
        nil
      end

      # Initialize
      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64))
        end
      end
      client.initialize_connection

      # Inject a session/update notification
      transport.inject_raw(<<-JSON
        {
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {
          "sessionId": "sess-001",
          "update": {
            "sessionUpdate": "agent_message_chunk",
            "content": "Hello from agent"
          }
        }
        }
        JSON
      )

      # Give the dispatcher time to process
      sleep 50.milliseconds

      received_updates.size.should eq(1)
      received_updates[0].session_id.should eq("sess-001")
      update = received_updates[0].update
      update.should be_a(ACP::Protocol::AgentMessageChunkUpdate)
      update.as(ACP::Protocol::AgentMessageChunkUpdate).content.should eq("Hello from agent")

      transport.close
    end

    it "dispatches generic notifications to on_notification" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      received_notifications = [] of {String, JSON::Any?}
      client.on_notification = ->(method : String, params : JSON::Any?) do
        received_notifications << {method, params}
        nil
      end

      # Inject a custom notification
      transport.inject_raw(<<-JSON
        {
        "jsonrpc": "2.0",
        "method": "_custom/event",
        "params": {"data": "test"}
        }
        JSON
      )

      sleep 50.milliseconds

      received_notifications.size.should eq(1)
      received_notifications[0][0].should eq("_custom/event")
      received_notifications[0][1].as(JSON::Any)["data"].as_s.should eq("test")

      transport.close
    end
  end

  describe "agent request handling" do
    it "handles session/request_permission via on_agent_request" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      client.on_agent_request = ->(method : String, _params : JSON::Any) do
        if method == "session/request_permission"
          JSON.parse(%({"outcome": {"selected": "allow_once"}}))
        else
          JSON.parse(%({"error": "unknown method"}))
        end
      end

      # Inject a permission request from the agent
      transport.inject_raw(<<-JSON
        {
        "jsonrpc": "2.0",
        "id": "perm-1",
        "method": "session/request_permission",
        "params": {
          "sessionId": "sess-perm-1",
          "toolCall": {"toolCallId": "tc-1", "title": "Test"},
          "options": [{"optionId": "allow_once", "name": "Allow Once", "kind": "allow_once"}]
        }
        }
        JSON
      )

      sleep 50.milliseconds

      # Check that the client sent a response
      response = transport.sent_messages.find { |msg| msg["id"]?.try(&.as_s?) == "perm-1" }
      response.should_not be_nil
      response.as(JSON::Any)["result"]["outcome"]["selected"].as_s.should eq("allow_once")

      transport.close
    end

    it "auto-cancels permission requests when no handler is set" do
      transport = TestTransport.new
      _client = ACP::Client.new(transport)

      # No on_agent_request handler set

      transport.inject_raw(<<-JSON
        {
        "jsonrpc": "2.0",
        "id": "perm-2",
        "method": "session/request_permission",
        "params": {
          "sessionId": "sess-perm-2",
          "toolCall": {"toolCallId": "tc-2", "title": "Auto-cancel"},
          "options": [{"optionId": "allow_once", "name": "Allow", "kind": "allow_once"}]
        }
        }
        JSON
      )

      sleep 50.milliseconds

      response = transport.sent_messages.find { |msg| msg["id"]?.try(&.as_s?) == "perm-2" }
      response.should_not be_nil
      response.as(JSON::Any)["result"]["outcome"].as_s.should eq("cancelled")

      transport.close
    end

    it "responds with cancellation when handler raises error" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      client.on_agent_request = ->(_method : String, _params : JSON::Any) {
        raise "Permission check failed"
      }

      transport.inject_raw(<<-JSON
        {
        "jsonrpc": "2.0",
        "id": "perm-error",
        "method": "session/request_permission",
        "params": {
          "sessionId": "sess-perm-error",
          "toolCall": {"toolCallId": "tc-error", "title": "Error Test"},
          "options": [{"optionId": "allow_once", "name": "Allow", "kind": "allow_once"}]
        }
        }
        JSON
      )

      sleep 50.milliseconds

      response = transport.sent_messages.find { |msg| msg["id"]?.try(&.as_s?) == "perm-error" }
      response.should_not be_nil
      response.as(JSON::Any)["result"]["outcome"].as_s.should eq("cancelled")

      transport.close
    end

    it "returns method-not-found for unknown agent methods without handler" do
      transport = TestTransport.new
      _client = ACP::Client.new(transport)

      transport.inject_raw(<<-JSON
        {
        "jsonrpc": "2.0",
        "id": "unk-1",
        "method": "unknown/method",
        "params": {}
        }
        JSON
      )

      sleep 50.milliseconds

      response = transport.sent_messages.find { |msg| msg["id"]?.try(&.as_s?) == "unk-1" }
      response.should_not be_nil
      response.as(JSON::Any)["error"]["code"].as_i.should eq(-32601)

      transport.close
    end
  end

  describe "disconnect handling" do
    it "calls on_disconnect when transport closes" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      disconnected = false
      client.on_disconnect = -> do
        disconnected = true
        nil
      end

      # Inject nil to signal EOF, which will trigger the disconnect callback
      transport.inject_message(nil)

      sleep 50.milliseconds

      disconnected.should be_true

      transport.close
    end
  end

  describe "#send_request timeout" do
    it "raises RequestTimeoutError when no response arrives" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)
      client.request_timeout = 0.05 # 50ms timeout for fast test

      params = ACP::Protocol::SessionCancelParams.new("sess-001")

      expect_raises(ACP::RequestTimeoutError) do
        client.send_request("some/method", params, timeout: 0.05)
      end

      transport.close
    end
  end

  describe "#send_request on closed client" do
    it "raises ConnectionClosedError" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)
      client.close

      params = ACP::Protocol::SessionCancelParams.new("sess-001")

      expect_raises(ACP::ConnectionClosedError) do
        client.send_request("test", params)
      end
    end
  end
end

# ═══════════════════════════════════════════════════════════════════════
# Session Specs
# ═══════════════════════════════════════════════════════════════════════

# Helper to create a fully initialized client with a session
def setup_client_with_session
  transport = TestTransport.new
  client = ACP::Client.new(transport)

  # Initialize
  spawn do
    sleep 10.milliseconds
    if msg = transport.last_sent
      transport.inject_raw(build_init_response(msg["id"].as_i64))
    end
  end
  client.initialize_connection

  {transport, client}
end

describe ACP::Session do
  describe ".create" do
    it "creates a new session through the client" do
      transport, client = setup_client_with_session

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64, "sess-via-create"))
      end

      session = ACP::Session.create(client, cwd: "/my/project")
      session.id.should eq("sess-via-create")
      session.closed?.should be_false
      session.modes.as(ACP::Protocol::SessionModeState).available_modes.size.should eq(2)

      transport.close
    end

    it "passes mcp_servers to client.session_new" do
      transport, client = setup_client_with_session

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64, "sess-mcp-test"))
      end

      server = ACP::Protocol::McpServerStdio.new(name: "test-mcp", command: "/bin/mcp")
      servers = [JSON.parse(server.to_json)]

      session = ACP::Session.create(client, cwd: "/my/project", mcp_servers: servers)
      session.id.should eq("sess-mcp-test")

      session_req = transport.sent_messages.find { |msg| msg["method"]?.try(&.as_s?) == "session/new" }
      session_req.should_not be_nil
      params = session_req.as(JSON::Any)["params"]

      json_servers = params["mcpServers"].as_a
      json_servers.size.should eq(1)
      json_servers[0]["name"].as_s.should eq("test-mcp")

      transport.close
    end
  end

  describe ".load" do
    it "loads an existing session" do
      transport, client = setup_client_with_session

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(<<-JSON
          {
          "jsonrpc": "2.0",
          "id": #{sent["id"].as_i64},
          "result": {}
          }
          JSON
        )
      end

      session = ACP::Session.load(client, session_id: "sess-existing", cwd: "/tmp")
      session.id.should eq("sess-existing")
      session.closed?.should be_false

      transport.close
    end
  end

  describe "#prompt(text)" do
    it "sends a text prompt and returns result" do
      transport, client = setup_client_with_session

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64, "sess-prompt"))
      end

      session = ACP::Session.create(client, cwd: "/tmp")

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_prompt_response(sent["id"].as_i64))
      end

      result = session.prompt("What is Crystal?")
      result.stop_reason.should eq("end_turn")

      transport.close
    end

    it "raises error when session is closed" do
      transport, client = setup_client_with_session

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64))
      end

      session = ACP::Session.create(client, cwd: "/tmp")
      session.close

      expect_raises(ACP::InvalidStateError) do
        session.prompt("test")
      end

      transport.close
    end
  end

  describe "#cancel" do
    it "sends a cancel notification" do
      transport, client = setup_client_with_session

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64, "sess-cancel"))
      end

      session = ACP::Session.create(client, cwd: "/tmp")
      transport.clear_sent

      session.cancel

      cancel_msg = transport.last_sent
      cancel_msg.should_not be_nil
      cancel = cancel_msg.as(JSON::Any)
      cancel["method"].as_s.should eq("session/cancel")
      cancel["params"]["sessionId"].as_s.should eq("sess-cancel")

      transport.close
    end

    it "is a no-op when session is closed" do
      transport, client = setup_client_with_session

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64))
      end

      session = ACP::Session.create(client, cwd: "/tmp")
      session.close
      transport.clear_sent

      session.cancel # Should not raise or send anything

      transport.sent_messages.size.should eq(0)
      transport.close
    end
  end

  describe "#close" do
    it "marks the session as closed" do
      transport, client = setup_client_with_session

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64))
      end

      session = ACP::Session.create(client, cwd: "/tmp")
      session.closed?.should be_false
      session.close
      session.closed?.should be_true

      transport.close
    end
  end

  describe "#available_mode_ids" do
    it "returns mode IDs when modes exist" do
      transport, client = setup_client_with_session

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64))
      end

      session = ACP::Session.create(client, cwd: "/tmp")
      session.available_mode_ids.should eq(["code", "chat"])

      transport.close
    end

    it "returns empty array when no modes" do
      transport, client = setup_client_with_session

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(<<-JSON
          {
          "jsonrpc": "2.0",
          "id": #{sent["id"].as_i64},
          "result": {"sessionId": "sess-no-modes"}
          }
          JSON
        )
      end

      session = ACP::Session.create(client, cwd: "/tmp")
      session.available_mode_ids.should eq([] of String)

      transport.close
    end
  end

  describe "#to_s" do
    it "includes session ID" do
      transport, client = setup_client_with_session

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64, "sess-tostr"))
      end

      session = ACP::Session.create(client, cwd: "/tmp")
      str = session.to_s
      str.should contain("sess-tostr")
      str.should contain("ACP::Session")

      transport.close
    end

    it "shows closed state" do
      transport, client = setup_client_with_session

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64))
      end

      session = ACP::Session.create(client, cwd: "/tmp")
      session.close
      session.to_s.should contain("closed")

      transport.close
    end
  end

  describe "#mode=" do
    it "sends session/set_mode request" do
      transport, client = setup_client_with_session

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64))
      end

      session = ACP::Session.create(client, cwd: "/tmp")

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(<<-JSON
          {
          "jsonrpc": "2.0",
          "id": #{sent["id"].as_i64},
          "result": {}
          }
          JSON
        )
      end

      session.mode = "chat"

      sent = transport.sent_messages.last
      sent["method"].as_s.should eq("session/set_mode")
      sent["params"]["modeId"].as_s.should eq("chat")

      transport.close
    end
  end
end

# ═══════════════════════════════════════════════════════════════════════
# PromptBuilder Specs
# ═══════════════════════════════════════════════════════════════════════

describe ACP::PromptBuilder do
  it "starts empty" do
    builder = ACP::PromptBuilder.new
    builder.empty?.should be_true
    builder.size.should eq(0)
  end

  it "builds text blocks" do
    builder = ACP::PromptBuilder.new
    builder.text("Hello")
    builder.text("World")

    blocks = builder.build
    blocks.size.should eq(2)
    blocks[0].should be_a(ACP::Protocol::TextContentBlock)
    blocks[0].as(ACP::Protocol::TextContentBlock).content.should eq("Hello")
    blocks[1].as(ACP::Protocol::TextContentBlock).content.should eq("World")
  end

  it "builds mixed content blocks" do
    builder = ACP::PromptBuilder.new
    builder
      .text("Look at this image:")
      .image("base64data==", "image/png")
      .resource_link("/path/to/code.cr")

    blocks = builder.build
    blocks.size.should eq(3)
    blocks[0].should be_a(ACP::Protocol::TextContentBlock)
    blocks[1].should be_a(ACP::Protocol::ImageContentBlock)
    blocks[2].should be_a(ACP::Protocol::ResourceLinkContentBlock)
  end

  it "supports method chaining" do
    builder = ACP::PromptBuilder.new
    result = builder.text("a").text("b").text("c")
    result.should be(builder)
    builder.size.should eq(3)
  end

  it "builds image blocks via DSL alias replacement" do
    builder = ACP::PromptBuilder.new
    builder.image("base64==", "image/jpeg")
    blocks = builder.build
    blocks.size.should eq(1)
    img = blocks[0].as(ACP::Protocol::ImageContentBlock)
    img.data.should eq("base64==")
    img.mime_type.should eq("image/jpeg")
  end

  it "builds audio blocks" do
    builder = ACP::PromptBuilder.new
    builder.audio("base64audio==", "audio/mp3")
    builder.audio("base64audio2==", "audio/wav")
    blocks = builder.build
    blocks.size.should eq(2)
    blocks[0].should be_a(ACP::Protocol::AudioContentBlock)
    blocks[1].should be_a(ACP::Protocol::AudioContentBlock)
  end
end

# ═══════════════════════════════════════════════════════════════════════
# Version Specs
# ═══════════════════════════════════════════════════════════════════════

describe ACP do
  it "has a version constant" do
    ACP::VERSION.should_not be_empty
    ACP::VERSION.should match(/\d+\.\d+\.\d+/)
  end

  it "has a protocol version constant" do
    ACP::PROTOCOL_VERSION.should eq(1_u16)
  end
end

# ═══════════════════════════════════════════════════════════════════════
# Integration-style Specs (Full flow without real agent)
# ═══════════════════════════════════════════════════════════════════════

describe "Full ACP flow simulation" do
  it "completes a full initialize → session → prompt cycle" do
    transport = TestTransport.new
    client = ACP::Client.new(transport, client_name: "integration-test", client_version: "0.1")

    # Track updates received during the prompt
    updates_received = [] of ACP::Protocol::SessionUpdate
    client.on_update = ->(update : ACP::Protocol::SessionUpdateParams) do
      updates_received << update.update
      nil
    end

    # Simulate agent responses in a fiber
    spawn do
      loop do
        sleep 5.milliseconds
        break if transport.closed?

        last = transport.last_sent
        next unless last

        method = last["method"]?.try(&.as_s?)
        id = last["id"]?.try(&.as_i64?)

        case method
        when "initialize"
          next unless id
          transport.inject_raw(build_init_response(id))
          transport.clear_sent
        when "session/new"
          next unless id
          transport.inject_raw(build_session_new_response(id, "integration-sess"))
          transport.clear_sent
        when "session/prompt"
          next unless id

          # Simulate streaming response: start → chunks → end → result
          transport.inject_raw(<<-JSON
            {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
              "sessionId": "integration-sess",
              "update": {"type": "agent_message_start", "messageId": "m1", "role": "assistant"}
            }
            }
            JSON
          )

          sleep 5.milliseconds

          transport.inject_raw(<<-JSON
            {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
              "sessionId": "integration-sess",
              "update": {"sessionUpdate": "agent_message_chunk", "content": "Hello, ", "messageId": "m1"}
            }
            }
            JSON
          )

          sleep 5.milliseconds

          transport.inject_raw(<<-JSON
            {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
              "sessionId": "integration-sess",
              "update": {"sessionUpdate": "agent_message_chunk", "content": "world!", "messageId": "m1"}
            }
            }
            JSON
          )

          sleep 5.milliseconds

          transport.inject_raw(<<-JSON
            {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
              "sessionId": "integration-sess",
              "update": {"type": "agent_message_end", "messageId": "m1", "stopReason": "end_turn"}
            }
            }
            JSON
          )

          sleep 5.milliseconds

          # Finally send the prompt result
          transport.inject_raw(build_prompt_response(id, "end_turn"))
          transport.clear_sent
        end
      end
    end

    # Execute the full flow
    init_result = client.initialize_connection
    init_result.agent_info.as(ACP::Protocol::AgentInfo).name.should eq("test-agent")

    session = ACP::Session.create(client, cwd: "/tmp/integration")
    session.id.should eq("integration-sess")

    result = session.prompt("Say hello")
    result.stop_reason.should eq("end_turn")

    # Verify we received the expected stream of updates
    # Give a moment for all updates to be processed
    sleep 50.milliseconds

    # Should have received: start, chunk, chunk, end
    updates_received.size.should be >= 3

    # Find the chunks and concatenate them
    chunks = updates_received.select(ACP::Protocol::AgentMessageChunkUpdate)
    full_message = chunks.map { |chunk| chunk.as(ACP::Protocol::AgentMessageChunkUpdate).text }.join
    full_message.should eq("Hello, world!")

    # Verify message start and end
    updates_received.any?(ACP::Protocol::AgentMessageStartUpdate).should be_true
    updates_received.any?(ACP::Protocol::AgentMessageEndUpdate).should be_true

    # Clean up
    session.close
    client.close
    client.closed?.should be_true
  end

  it "handles permission request during a prompt" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    # Set up permission handler
    permission_requests_received = 0
    client.on_agent_request = ->(method : String, _params : JSON::Any) do
      if method == "session/request_permission"
        permission_requests_received += 1
        JSON.parse(%({"outcome": {"selected": "allow_once"}}))
      else
        JSON.parse(%({}))
      end
    end

    # Simulate agent
    spawn do
      loop do
        sleep 5.milliseconds
        break if transport.closed?

        last = transport.last_sent
        next unless last

        method = last["method"]?.try(&.as_s?)
        id = last["id"]?.try(&.as_i64?)

        case method
        when "initialize"
          next unless id
          transport.inject_raw(build_init_response(id))
          transport.clear_sent
        when "session/new"
          next unless id
          transport.inject_raw(build_session_new_response(id, "perm-sess"))
          transport.clear_sent
        when "session/prompt"
          next unless id

          # Agent asks for permission before proceeding
          transport.inject_raw(<<-JSON
            {
            "jsonrpc": "2.0",
            "id": "perm-req-1",
            "method": "session/request_permission",
            "params": {
              "sessionId": "perm-sess",
              "toolCall": {"toolCallId": "tc-write-1", "toolName": "fs.write_text_file", "title": "Write to output.txt"},
              "options": [
                {"id": "allow_once", "label": "Allow Once"},
                {"id": "deny", "label": "Deny"}
              ]
            }
            }
            JSON
          )

          sleep 30.milliseconds

          # After permission granted, send the prompt result
          transport.inject_raw(build_prompt_response(id, "end_turn"))
          # NOTE: Do NOT clear_sent here — we need to inspect the
          # permission response in sent_messages after the prompt returns.
        end
      end
    end

    client.initialize_connection
    session = ACP::Session.create(client, cwd: "/tmp")
    result = session.prompt("Write a file")

    result.stop_reason.should eq("end_turn")
    permission_requests_received.should eq(1)

    # Verify the permission response was sent back
    perm_response = transport.sent_messages.find { |msg| msg["id"]?.try(&.as_s?) == "perm-req-1" }
    perm_response.should_not be_nil
    perm_response.as(JSON::Any)["result"]["outcome"]["selected"].as_s.should eq("allow_once")

    client.close
  end
end

# ═══════════════════════════════════════════════════════════════════════
# Protocol Enum Specs
# ═══════════════════════════════════════════════════════════════════════

describe ACP::Protocol::StopReason do
  it "serializes to wire-format strings" do
    ACP::Protocol::StopReason::EndTurn.to_s.should eq("end_turn")
    ACP::Protocol::StopReason::MaxTokens.to_s.should eq("max_tokens")
    ACP::Protocol::StopReason::MaxTurnRequests.to_s.should eq("max_turn_requests")
    ACP::Protocol::StopReason::Refusal.to_s.should eq("refusal")
    ACP::Protocol::StopReason::Cancelled.to_s.should eq("cancelled")
  end

  it "parses from wire-format strings" do
    ACP::Protocol::StopReason.parse("end_turn").should eq(ACP::Protocol::StopReason::EndTurn)
    ACP::Protocol::StopReason.parse("max_tokens").should eq(ACP::Protocol::StopReason::MaxTokens)
    ACP::Protocol::StopReason.parse("max_turn_requests").should eq(ACP::Protocol::StopReason::MaxTurnRequests)
    ACP::Protocol::StopReason.parse("refusal").should eq(ACP::Protocol::StopReason::Refusal)
    ACP::Protocol::StopReason.parse("cancelled").should eq(ACP::Protocol::StopReason::Cancelled)
  end

  it "returns nil for unknown values via parse?" do
    ACP::Protocol::StopReason.parse?("unknown").should be_nil
  end

  it "raises on unknown values via parse" do
    expect_raises(ArgumentError) do
      ACP::Protocol::StopReason.parse("unknown")
    end
  end

  it "round-trips through JSON" do
    json = ACP::Protocol::StopReason::EndTurn.to_json
    json.should eq(%("end_turn"))
    ACP::Protocol::StopReason.from_json(json).should eq(ACP::Protocol::StopReason::EndTurn)
  end
end

describe ACP::Protocol::ToolKind do
  it "serializes all variants to wire-format strings" do
    ACP::Protocol::ToolKind::Read.to_s.should eq("read")
    ACP::Protocol::ToolKind::Edit.to_s.should eq("edit")
    ACP::Protocol::ToolKind::Delete.to_s.should eq("delete")
    ACP::Protocol::ToolKind::Move.to_s.should eq("move")
    ACP::Protocol::ToolKind::Search.to_s.should eq("search")
    ACP::Protocol::ToolKind::Execute.to_s.should eq("execute")
    ACP::Protocol::ToolKind::Think.to_s.should eq("think")
    ACP::Protocol::ToolKind::Fetch.to_s.should eq("fetch")
    ACP::Protocol::ToolKind::SwitchMode.to_s.should eq("switch_mode")
    ACP::Protocol::ToolKind::Other.to_s.should eq("other")
  end

  it "parses all variants from wire-format strings" do
    ACP::Protocol::ToolKind.parse("read").should eq(ACP::Protocol::ToolKind::Read)
    ACP::Protocol::ToolKind.parse("edit").should eq(ACP::Protocol::ToolKind::Edit)
    ACP::Protocol::ToolKind.parse("switch_mode").should eq(ACP::Protocol::ToolKind::SwitchMode)
    ACP::Protocol::ToolKind.parse("other").should eq(ACP::Protocol::ToolKind::Other)
  end

  it "round-trips through JSON" do
    json = ACP::Protocol::ToolKind::Execute.to_json
    json.should eq(%("execute"))
    ACP::Protocol::ToolKind.from_json(json).should eq(ACP::Protocol::ToolKind::Execute)
  end
end

describe ACP::Protocol::ToolCallStatus do
  it "serializes to wire-format strings" do
    ACP::Protocol::ToolCallStatus::Pending.to_s.should eq("pending")
    ACP::Protocol::ToolCallStatus::InProgress.to_s.should eq("in_progress")
    ACP::Protocol::ToolCallStatus::Completed.to_s.should eq("completed")
    ACP::Protocol::ToolCallStatus::Failed.to_s.should eq("failed")
  end

  it "parses from wire-format strings" do
    ACP::Protocol::ToolCallStatus.parse("pending").should eq(ACP::Protocol::ToolCallStatus::Pending)
    ACP::Protocol::ToolCallStatus.parse("in_progress").should eq(ACP::Protocol::ToolCallStatus::InProgress)
    ACP::Protocol::ToolCallStatus.parse("completed").should eq(ACP::Protocol::ToolCallStatus::Completed)
    ACP::Protocol::ToolCallStatus.parse("failed").should eq(ACP::Protocol::ToolCallStatus::Failed)
  end

  it "round-trips through JSON" do
    json = ACP::Protocol::ToolCallStatus::InProgress.to_json
    json.should eq(%("in_progress"))
    ACP::Protocol::ToolCallStatus.from_json(json).should eq(ACP::Protocol::ToolCallStatus::InProgress)
  end
end

describe ACP::Protocol::PermissionOptionKind do
  it "serializes to wire-format strings" do
    ACP::Protocol::PermissionOptionKind::AllowOnce.to_s.should eq("allow_once")
    ACP::Protocol::PermissionOptionKind::AllowAlways.to_s.should eq("allow_always")
    ACP::Protocol::PermissionOptionKind::RejectOnce.to_s.should eq("reject_once")
    ACP::Protocol::PermissionOptionKind::RejectAlways.to_s.should eq("reject_always")
  end

  it "parses from wire-format strings" do
    ACP::Protocol::PermissionOptionKind.parse("allow_once").should eq(ACP::Protocol::PermissionOptionKind::AllowOnce)
    ACP::Protocol::PermissionOptionKind.parse("reject_always").should eq(ACP::Protocol::PermissionOptionKind::RejectAlways)
  end

  it "round-trips through JSON" do
    json = ACP::Protocol::PermissionOptionKind::AllowAlways.to_json
    json.should eq(%("allow_always"))
    ACP::Protocol::PermissionOptionKind.from_json(json).should eq(ACP::Protocol::PermissionOptionKind::AllowAlways)
  end
end

describe ACP::Protocol::PlanEntryPriority do
  it "serializes to wire-format strings" do
    ACP::Protocol::PlanEntryPriority::High.to_s.should eq("high")
    ACP::Protocol::PlanEntryPriority::Medium.to_s.should eq("medium")
    ACP::Protocol::PlanEntryPriority::Low.to_s.should eq("low")
  end

  it "round-trips through JSON" do
    json = ACP::Protocol::PlanEntryPriority::High.to_json
    ACP::Protocol::PlanEntryPriority.from_json(json).should eq(ACP::Protocol::PlanEntryPriority::High)
  end
end

describe ACP::Protocol::PlanEntryStatus do
  it "serializes to wire-format strings" do
    ACP::Protocol::PlanEntryStatus::Pending.to_s.should eq("pending")
    ACP::Protocol::PlanEntryStatus::InProgress.to_s.should eq("in_progress")
    ACP::Protocol::PlanEntryStatus::Completed.to_s.should eq("completed")
  end

  it "round-trips through JSON" do
    json = ACP::Protocol::PlanEntryStatus::Completed.to_json
    ACP::Protocol::PlanEntryStatus.from_json(json).should eq(ACP::Protocol::PlanEntryStatus::Completed)
  end
end

describe ACP::Protocol::SessionConfigOptionCategory do
  it "serializes to wire-format strings" do
    ACP::Protocol::SessionConfigOptionCategory::Mode.to_s.should eq("mode")
    ACP::Protocol::SessionConfigOptionCategory::Model.to_s.should eq("model")
    ACP::Protocol::SessionConfigOptionCategory::ThoughtLevel.to_s.should eq("thought_level")
    ACP::Protocol::SessionConfigOptionCategory::Other.to_s.should eq("other")
  end

  it "round-trips through JSON" do
    json = ACP::Protocol::SessionConfigOptionCategory::Model.to_json
    ACP::Protocol::SessionConfigOptionCategory.from_json(json).should eq(ACP::Protocol::SessionConfigOptionCategory::Model)
  end
end

describe ACP::Protocol::Role do
  it "serializes to wire-format strings" do
    ACP::Protocol::Role::Assistant.to_s.should eq("assistant")
    ACP::Protocol::Role::User.to_s.should eq("user")
  end

  it "round-trips through JSON" do
    json = ACP::Protocol::Role::Assistant.to_json
    json.should eq(%("assistant"))
    ACP::Protocol::Role.from_json(json).should eq(ACP::Protocol::Role::Assistant)
  end
end

# ═══════════════════════════════════════════════════════════════════════
# Tool Call Content Specs
# ═══════════════════════════════════════════════════════════════════════

describe ACP::Protocol::ToolCallContent do
  describe "ToolCallContentBlock" do
    it "deserializes from JSON with type=content" do
      json = <<-JSON
        {
        "type": "content",
        "content": {
          "type": "text",
          "text": "Analysis complete. Found 3 issues."
        }
        }
        JSON
      block = ACP::Protocol::ToolCallContent.from_json(json)
      block.should be_a(ACP::Protocol::ToolCallContentBlock)
      block.type.should eq("content")

      content_block = block.as(ACP::Protocol::ToolCallContentBlock)
      content_block.text.should eq("Analysis complete. Found 3 issues.")
    end

    it "serializes back to JSON" do
      inner = ACP::Protocol::TextContentBlock.new("Hello")
      block = ACP::Protocol::ToolCallContentBlock.new(content: inner)
      parsed = JSON.parse(block.to_json)
      parsed["type"].as_s.should eq("content")
      parsed["content"]["type"].as_s.should eq("text")
      parsed["content"]["text"].as_s.should eq("Hello")
    end
  end

  describe "ToolCallDiff" do
    it "deserializes from JSON with type=diff" do
      json = <<-JSON
        {
        "type": "diff",
        "path": "/home/user/project/src/config.json",
        "oldText": "{\\"debug\\": false}",
        "newText": "{\\"debug\\": true}"
        }
        JSON
      block = ACP::Protocol::ToolCallContent.from_json(json)
      block.should be_a(ACP::Protocol::ToolCallDiff)

      diff = block.as(ACP::Protocol::ToolCallDiff)
      diff.path.should eq("/home/user/project/src/config.json")
      diff.old_text.should eq("{\"debug\": false}")
      diff.new_text.should eq("{\"debug\": true}")
      diff.new_file?.should be_false
      diff.deletion?.should be_false
    end

    it "detects new file diffs" do
      diff = ACP::Protocol::ToolCallDiff.new(
        path: "/new/file.txt",
        new_text: "content",
        old_text: nil
      )
      diff.new_file?.should be_true
    end

    it "detects deletion diffs" do
      diff = ACP::Protocol::ToolCallDiff.new(
        path: "/old/file.txt",
        new_text: "",
        old_text: "was here"
      )
      diff.deletion?.should be_true
    end

    it "serializes with camelCase field names" do
      diff = ACP::Protocol::ToolCallDiff.new(
        path: "/a/b.txt",
        new_text: "new",
        old_text: "old"
      )
      parsed = JSON.parse(diff.to_json)
      parsed["type"].as_s.should eq("diff")
      parsed["path"].as_s.should eq("/a/b.txt")
      parsed["oldText"].as_s.should eq("old")
      parsed["newText"].as_s.should eq("new")
    end
  end

  describe "ToolCallTerminal" do
    it "deserializes from JSON with type=terminal" do
      json = %({"type": "terminal", "terminalId": "term_xyz789"})
      block = ACP::Protocol::ToolCallContent.from_json(json)
      block.should be_a(ACP::Protocol::ToolCallTerminal)

      terminal = block.as(ACP::Protocol::ToolCallTerminal)
      terminal.terminal_id.should eq("term_xyz789")
    end

    it "serializes with camelCase field names" do
      term = ACP::Protocol::ToolCallTerminal.new("term_abc")
      parsed = JSON.parse(term.to_json)
      parsed["type"].as_s.should eq("terminal")
      parsed["terminalId"].as_s.should eq("term_abc")
    end
  end
end

describe ACP::Protocol::ToolCallLocation do
  it "deserializes from JSON" do
    json = %({"path": "/home/user/project/src/main.py", "line": 42})
    loc = ACP::Protocol::ToolCallLocation.from_json(json)
    loc.path.should eq("/home/user/project/src/main.py")
    loc.line.should eq(42)
  end

  it "handles missing optional line" do
    json = %({"path": "/home/user/file.cr"})
    loc = ACP::Protocol::ToolCallLocation.from_json(json)
    loc.path.should eq("/home/user/file.cr")
    loc.line.should be_nil
  end

  it "renders to_s with path and line" do
    loc = ACP::Protocol::ToolCallLocation.new(path: "/a/b.cr", line: 10)
    loc.to_s.should eq("/a/b.cr:10")
  end

  it "renders to_s with path only" do
    loc = ACP::Protocol::ToolCallLocation.new(path: "/a/b.cr")
    loc.to_s.should eq("/a/b.cr")
  end
end

describe ACP::Protocol::TerminalExitStatus do
  it "deserializes exit code" do
    json = %({"exitCode": 0, "signal": null})
    status = ACP::Protocol::TerminalExitStatus.from_json(json)
    status.exit_code.should eq(0)
    status.signal.should be_nil
    status.success?.should be_true
    status.signaled?.should be_false
  end

  it "deserializes signal termination" do
    json = %({"exitCode": null, "signal": "SIGKILL"})
    status = ACP::Protocol::TerminalExitStatus.from_json(json)
    status.exit_code.should be_nil
    status.signal.should eq("SIGKILL")
    status.success?.should be_false
    status.signaled?.should be_true
  end

  it "handles non-zero exit codes" do
    json = %({"exitCode": 1})
    status = ACP::Protocol::TerminalExitStatus.from_json(json)
    status.exit_code.should eq(1)
    status.success?.should be_false
  end
end

# ═══════════════════════════════════════════════════════════════════════
# Client Method Type Specs
# ═══════════════════════════════════════════════════════════════════════

describe ACP::Protocol::ReadTextFileParams do
  it "serializes with correct camelCase keys" do
    params = ACP::Protocol::ReadTextFileParams.new(
      session_id: "sess-001",
      path: "/home/user/file.py",
      line: 10,
      limit: 50
    )
    parsed = JSON.parse(params.to_json)
    parsed["sessionId"].as_s.should eq("sess-001")
    parsed["path"].as_s.should eq("/home/user/file.py")
    parsed["line"].as_i.should eq(10)
    parsed["limit"].as_i.should eq(50)
  end

  it "deserializes from JSON" do
    json = %({"sessionId": "s1", "path": "/a/b.txt"})
    params = ACP::Protocol::ReadTextFileParams.from_json(json)
    params.session_id.should eq("s1")
    params.path.should eq("/a/b.txt")
    params.line.should be_nil
    params.limit.should be_nil
  end
end

describe ACP::Protocol::ReadTextFileResult do
  it "serializes and deserializes" do
    result = ACP::Protocol::ReadTextFileResult.new(content: "hello world\n")
    parsed = JSON.parse(result.to_json)
    parsed["content"].as_s.should eq("hello world\n")

    rt = ACP::Protocol::ReadTextFileResult.from_json(result.to_json)
    rt.content.should eq("hello world\n")
  end
end

describe ACP::Protocol::WriteTextFileParams do
  it "serializes with correct camelCase keys" do
    params = ACP::Protocol::WriteTextFileParams.new(
      session_id: "sess-002",
      path: "/home/user/config.json",
      content: "{\"debug\": true}"
    )
    parsed = JSON.parse(params.to_json)
    parsed["sessionId"].as_s.should eq("sess-002")
    parsed["path"].as_s.should eq("/home/user/config.json")
    parsed["content"].as_s.should eq("{\"debug\": true}")
  end
end

describe ACP::Protocol::CreateTerminalParams do
  it "serializes all fields with correct keys" do
    params = ACP::Protocol::CreateTerminalParams.new(
      session_id: "sess-003",
      command: "npm",
      args: ["test", "--coverage"],
      cwd: "/home/user/project",
      output_byte_limit: 1048576_i64
    )
    parsed = JSON.parse(params.to_json)
    parsed["sessionId"].as_s.should eq("sess-003")
    parsed["command"].as_s.should eq("npm")
    parsed["args"].as_a.map(&.as_s).should eq(["test", "--coverage"])
    parsed["cwd"].as_s.should eq("/home/user/project")
    parsed["outputByteLimit"].as_i64.should eq(1048576)
  end

  it "deserializes from JSON" do
    json = %({"sessionId": "s1", "command": "ls", "args": ["-la"]})
    params = ACP::Protocol::CreateTerminalParams.from_json(json)
    params.session_id.should eq("s1")
    params.command.should eq("ls")
    params.args.should eq(["la".gsub("la", "-la")] || ["-la"])
    params.cwd.should be_nil
    params.output_byte_limit.should be_nil
  end
end

describe ACP::Protocol::CreateTerminalResult do
  it "serializes and deserializes" do
    result = ACP::Protocol::CreateTerminalResult.new(terminal_id: "term_xyz789")
    parsed = JSON.parse(result.to_json)
    parsed["terminalId"].as_s.should eq("term_xyz789")

    rt = ACP::Protocol::CreateTerminalResult.from_json(result.to_json)
    rt.terminal_id.should eq("term_xyz789")
  end
end

describe ACP::Protocol::TerminalOutputResult do
  it "serializes output without exit status" do
    result = ACP::Protocol::TerminalOutputResult.new(
      output: "Running tests...\n",
      truncated: false
    )
    parsed = JSON.parse(result.to_json)
    parsed["output"].as_s.should eq("Running tests...\n")
    parsed["truncated"].as_bool.should be_false
    result.exited?.should be_false
  end

  it "serializes output with exit status" do
    exit_status = ACP::Protocol::TerminalExitStatus.new(exit_code: 0)
    result = ACP::Protocol::TerminalOutputResult.new(
      output: "All tests passed\n",
      truncated: false,
      exit_status: exit_status
    )
    parsed = JSON.parse(result.to_json)
    parsed["exitStatus"]["exitCode"].as_i.should eq(0)
    result.exited?.should be_true
  end

  it "deserializes with truncation flag" do
    json = %({"output": "truncated...", "truncated": true})
    result = ACP::Protocol::TerminalOutputResult.from_json(json)
    result.output.should eq("truncated...")
    result.truncated?.should be_true
  end
end

describe ACP::Protocol::WaitForTerminalExitResult do
  it "serializes and deserializes exit code" do
    result = ACP::Protocol::WaitForTerminalExitResult.new(exit_code: 0)
    result.success?.should be_true
    result.signaled?.should be_false

    parsed = JSON.parse(result.to_json)
    parsed["exitCode"].as_i.should eq(0)
  end

  it "serializes and deserializes signal termination" do
    result = ACP::Protocol::WaitForTerminalExitResult.new(signal: "SIGTERM")
    result.success?.should be_false
    result.signaled?.should be_true
  end
end

describe ACP::Protocol::ClientMethod do
  it "recognizes known client methods" do
    ACP::Protocol::ClientMethod.known?("fs/read_text_file").should be_true
    ACP::Protocol::ClientMethod.known?("fs/write_text_file").should be_true
    ACP::Protocol::ClientMethod.known?("terminal/create").should be_true
    ACP::Protocol::ClientMethod.known?("terminal/output").should be_true
    ACP::Protocol::ClientMethod.known?("terminal/release").should be_true
    ACP::Protocol::ClientMethod.known?("terminal/wait_for_exit").should be_true
    ACP::Protocol::ClientMethod.known?("terminal/kill").should be_true
    ACP::Protocol::ClientMethod.known?("session/request_permission").should be_true
  end

  it "returns false for unknown methods" do
    ACP::Protocol::ClientMethod.known?("unknown/method").should be_false
    ACP::Protocol::ClientMethod.known?("session/prompt").should be_false
  end

  it "classifies fs methods" do
    ACP::Protocol::ClientMethod.fs_method?("fs/read_text_file").should be_true
    ACP::Protocol::ClientMethod.fs_method?("fs/write_text_file").should be_true
    ACP::Protocol::ClientMethod.fs_method?("terminal/create").should be_false
  end

  it "classifies terminal methods" do
    ACP::Protocol::ClientMethod.terminal_method?("terminal/create").should be_true
    ACP::Protocol::ClientMethod.terminal_method?("terminal/output").should be_true
    ACP::Protocol::ClientMethod.terminal_method?("terminal/release").should be_true
    ACP::Protocol::ClientMethod.terminal_method?("terminal/wait_for_exit").should be_true
    ACP::Protocol::ClientMethod.terminal_method?("terminal/kill").should be_true
    ACP::Protocol::ClientMethod.terminal_method?("fs/read_text_file").should be_false
  end
end

# ═══════════════════════════════════════════════════════════════════════
# ACP Error Code Specs
# ═══════════════════════════════════════════════════════════════════════

describe ACP::Protocol::ErrorCode do
  it "defines standard JSON-RPC 2.0 error codes" do
    ACP::Protocol::ErrorCode::PARSE_ERROR.should eq(-32700)
    ACP::Protocol::ErrorCode::INVALID_REQUEST.should eq(-32600)
    ACP::Protocol::ErrorCode::METHOD_NOT_FOUND.should eq(-32601)
    ACP::Protocol::ErrorCode::INVALID_PARAMS.should eq(-32602)
    ACP::Protocol::ErrorCode::INTERNAL_ERROR.should eq(-32603)
  end

  it "defines ACP-specific error codes" do
    ACP::Protocol::ErrorCode::AUTH_REQUIRED.should eq(-32000)
    ACP::Protocol::ErrorCode::RESOURCE_NOT_FOUND.should eq(-32002)
  end
end

describe ACP::JsonRpcError do
  it "detects auth_required errors" do
    error = ACP::JsonRpcError.new(-32000, "Authentication required")
    error.auth_required?.should be_true
    error.resource_not_found?.should be_false
  end

  it "detects resource_not_found errors" do
    error = ACP::JsonRpcError.new(-32002, "File not found")
    error.resource_not_found?.should be_true
    error.auth_required?.should be_false
  end
end

# ═══════════════════════════════════════════════════════════════════════
# SessionUpdate config_options_update alias Spec
# ═══════════════════════════════════════════════════════════════════════

describe "SessionUpdate config_options_update alias" do
  it "parses config_option_update (schema name)" do
    json = <<-JSON
      {
      "sessionId": "sess-001",
      "update": {
        "sessionUpdate": "config_option_update",
        "configOptions": []
      }
      }
      JSON
    params = ACP::Protocol::SessionUpdateParams.from_json(json)
    params.update.should be_a(ACP::Protocol::ConfigOptionUpdate)
  end

  it "parses config_options_update (doc alias)" do
    json = <<-JSON
      {
      "sessionId": "sess-001",
      "update": {
        "sessionUpdate": "config_options_update",
        "configOptions": []
      }
      }
      JSON
    params = ACP::Protocol::SessionUpdateParams.from_json(json)
    params.update.should be_a(ACP::Protocol::ConfigOptionUpdate)
  end
end

# ═══════════════════════════════════════════════════════════════════════
# Typed Client Method Handler Dispatch Specs
# ═══════════════════════════════════════════════════════════════════════

describe "Client typed handler dispatch" do
  it "dispatches fs/read_text_file to typed handler" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    handler_called = false
    received_path = ""

    client.on_read_text_file = ->(params : ACP::Protocol::ReadTextFileParams) do
      handler_called = true
      received_path = params.path
      ACP::Protocol::ReadTextFileResult.new(content: "file content here")
    end

    # Initialize
    spawn do
      sleep 10.milliseconds
      if msg = transport.last_sent
        transport.inject_raw(build_init_response(msg["id"].as_i64))
      end
    end
    client.initialize_connection

    # Simulate agent sending fs/read_text_file request
    transport.inject_raw(<<-JSON
      {
      "jsonrpc": "2.0",
      "id": "agent-req-1",
      "method": "fs/read_text_file",
      "params": {
        "sessionId": "sess-001",
        "path": "/home/user/main.py"
      }
      }
      JSON
    )

    sleep 50.milliseconds

    handler_called.should be_true
    received_path.should eq("/home/user/main.py")

    # Verify the response was sent back
    response = transport.sent_messages.find { |msg| msg["id"]?.try(&.as_s?) == "agent-req-1" }
    response.should_not be_nil
    response.as(JSON::Any)["result"]["content"].as_s.should eq("file content here")

    client.close
  end

  it "dispatches fs/write_text_file to typed handler" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    written_path = ""
    written_content = ""

    client.on_write_text_file = ->(params : ACP::Protocol::WriteTextFileParams) do
      written_path = params.path
      written_content = params.content
      ACP::Protocol::WriteTextFileResult.new
    end

    spawn do
      sleep 10.milliseconds
      if msg = transport.last_sent
        transport.inject_raw(build_init_response(msg["id"].as_i64))
      end
    end
    client.initialize_connection

    transport.inject_raw(<<-JSON
      {
      "jsonrpc": "2.0",
      "id": "agent-req-2",
      "method": "fs/write_text_file",
      "params": {
        "sessionId": "sess-001",
        "path": "/home/user/output.txt",
        "content": "hello world"
      }
      }
      JSON
    )

    sleep 50.milliseconds

    written_path.should eq("/home/user/output.txt")
    written_content.should eq("hello world")

    client.close
  end

  it "dispatches terminal/create to typed handler" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    received_command = ""

    client.on_create_terminal = ->(params : ACP::Protocol::CreateTerminalParams) do
      received_command = params.command
      ACP::Protocol::CreateTerminalResult.new(terminal_id: "term_001")
    end

    spawn do
      sleep 10.milliseconds
      if msg = transport.last_sent
        transport.inject_raw(build_init_response(msg["id"].as_i64))
      end
    end
    client.initialize_connection

    transport.inject_raw(<<-JSON
      {
      "jsonrpc": "2.0",
      "id": "agent-req-3",
      "method": "terminal/create",
      "params": {
        "sessionId": "sess-001",
        "command": "npm",
        "args": ["test"]
      }
      }
      JSON
    )

    sleep 50.milliseconds

    received_command.should eq("npm")

    response = transport.sent_messages.find { |msg| msg["id"]?.try(&.as_s?) == "agent-req-3" }
    response.should_not be_nil
    response.as(JSON::Any)["result"]["terminalId"].as_s.should eq("term_001")

    client.close
  end

  it "falls back to on_agent_request when typed handler not set" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    fallback_called = false
    fallback_method = ""

    client.on_agent_request = ->(method : String, _params : JSON::Any) do
      fallback_called = true
      fallback_method = method
      JSON.parse(%({"content": "fallback response"}))
    end

    spawn do
      sleep 10.milliseconds
      if msg = transport.last_sent
        transport.inject_raw(build_init_response(msg["id"].as_i64))
      end
    end
    client.initialize_connection

    transport.inject_raw(<<-JSON
      {
      "jsonrpc": "2.0",
      "id": "agent-req-4",
      "method": "fs/read_text_file",
      "params": {
        "sessionId": "sess-001",
        "path": "/some/file.txt"
      }
      }
      JSON
    )

    sleep 50.milliseconds

    fallback_called.should be_true
    fallback_method.should eq("fs/read_text_file")

    client.close
  end

  it "returns method-not-found error when no handler is set" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    spawn do
      sleep 10.milliseconds
      if msg = transport.last_sent
        transport.inject_raw(build_init_response(msg["id"].as_i64))
      end
    end
    client.initialize_connection

    transport.inject_raw(<<-JSON
      {
      "jsonrpc": "2.0",
      "id": "agent-req-5",
      "method": "terminal/create",
      "params": {
        "sessionId": "sess-001",
        "command": "ls"
      }
      }
      JSON
    )

    sleep 50.milliseconds

    response = transport.sent_messages.find { |msg| msg["id"]?.try(&.as_s?) == "agent-req-5" }
    response.should_not be_nil
    response.as(JSON::Any)["error"]["code"].as_i.should eq(-32601)

    client.close
  end
end

# ═══════════════════════════════════════════════════════════════════════
# Extension Method Specs
# ═══════════════════════════════════════════════════════════════════════

describe "Extension Methods" do
  # ─── ExtensionMethod Helpers ──────────────────────────────────────

  describe ACP::Protocol::ExtensionMethod do
    it "detects extension methods by prefix" do
      ACP::Protocol::ExtensionMethod.extension?("_my_method").should be_true
      ACP::Protocol::ExtensionMethod.extension?("_custom").should be_true
      ACP::Protocol::ExtensionMethod.extension?("session/prompt").should be_false
      ACP::Protocol::ExtensionMethod.extension?("initialize").should be_false
    end

    it "strips the extension prefix" do
      ACP::Protocol::ExtensionMethod.strip_prefix("_my_method").should eq("my_method")
      ACP::Protocol::ExtensionMethod.strip_prefix("_custom").should eq("custom")
      ACP::Protocol::ExtensionMethod.strip_prefix("session/prompt").should be_nil
    end

    it "adds the extension prefix" do
      ACP::Protocol::ExtensionMethod.add_prefix("my_method").should eq("_my_method")
      ACP::Protocol::ExtensionMethod.add_prefix("custom").should eq("_custom")
    end
  end

  # ─── ExtRequest / ExtResponse / ExtNotification Types ─────────────

  describe ACP::Protocol::ExtRequest do
    it "creates with method and params" do
      req = ACP::Protocol::ExtRequest.new(
        method: "my_custom",
        params: JSON.parse(%({"key": "value"}))
      )
      req.method.should eq("my_custom")
      req.params["key"].as_s.should eq("value")
    end

    it "defaults params to nil" do
      req = ACP::Protocol::ExtRequest.new(method: "test")
      req.method.should eq("test")
      req.params.raw.should be_nil
    end

    it "serializes params (method is ignored in JSON)" do
      req = ACP::Protocol::ExtRequest.new(
        method: "test",
        params: JSON.parse(%({"foo": "bar"}))
      )
      json = JSON.parse(req.to_json)
      json["params"]["foo"].as_s.should eq("bar")
      # method is marked JSON::Field(ignore: true)
      json["method"]?.should be_nil
    end
  end

  describe ACP::Protocol::ExtResponse do
    it "creates with result" do
      resp = ACP::Protocol::ExtResponse.new(
        result: JSON.parse(%({"status": "ok"}))
      )
      resp.result["status"].as_s.should eq("ok")
    end

    it "serializes to JSON" do
      resp = ACP::Protocol::ExtResponse.new(
        result: JSON.parse(%({"data": 42}))
      )
      json = JSON.parse(resp.to_json)
      json["result"]["data"].as_i.should eq(42)
    end
  end

  describe ACP::Protocol::ExtNotification do
    it "creates with method and params" do
      notif = ACP::Protocol::ExtNotification.new(
        method: "my_event",
        params: JSON.parse(%({"event": "click"}))
      )
      notif.method.should eq("my_event")
      notif.params["event"].as_s.should eq("click")
    end
  end

  # ─── Client ext_method ────────────────────────────────────────────

  describe "Client#ext_method" do
    it "sends extension request with _ prefix on wire" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      # Initialize
      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64))
        end
      end
      client.initialize_connection

      # Set up response for the extension request
      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        sent["method"].as_s.should eq("_my_custom_method")
        transport.inject_raw(%({"jsonrpc": "2.0", "id": #{sent["id"].as_i64}, "result": {"answer": 42}}))
      end

      result = client.ext_method("my_custom_method", JSON.parse(%({"question": "meaning"})))
      result["answer"].as_i.should eq(42)

      client.close
    end
  end

  # ─── Client ext_notification ──────────────────────────────────────

  describe "Client#ext_notification" do
    it "sends extension notification with _ prefix on wire" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      # Initialize
      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64))
        end
      end
      client.initialize_connection

      client.ext_notification("my_event", JSON.parse(%({"status": "ok"})))

      sleep 20.milliseconds

      notif = transport.sent_messages.find { |msg| msg["method"]?.try(&.as_s?) == "_my_event" }
      notif.should_not be_nil
      notif = notif.as(JSON::Any)
      notif["method"].as_s.should eq("_my_event")
      notif["params"]["status"].as_s.should eq("ok")
      # Notifications have no "id" field
      notif["id"]?.should be_nil

      client.close
    end
  end

  # ─── Extension method dispatching (agent → client) ────────────────

  describe "Extension method dispatching" do
    it "routes extension requests to on_agent_request handler" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64))
        end
      end
      client.initialize_connection

      received_method = ""
      received_params = JSON::Any.new(nil)
      client.on_agent_request = ->(method : String, params : JSON::Any) : JSON::Any {
        received_method = method
        received_params = params
        JSON.parse(%({"handled": true}))
      }

      # Simulate agent sending an extension request
      transport.inject_raw(%({"jsonrpc": "2.0", "id": "ext-1", "method": "_custom_tool", "params": {"data": "test"}}))
      sleep 50.milliseconds

      received_method.should eq("_custom_tool")
      received_params["data"].as_s.should eq("test")

      response = transport.sent_messages.find { |msg| msg["id"]?.try(&.as_s?) == "ext-1" }
      response.should_not be_nil
      response.as(JSON::Any)["result"]["handled"].as_bool.should be_true

      client.close
    end

    it "returns null response for extension requests without handler" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64))
        end
      end
      client.initialize_connection

      # No on_agent_request handler set — extension methods get null response
      transport.inject_raw(%({"jsonrpc": "2.0", "id": "ext-2", "method": "_unknown_ext", "params": {}}))
      sleep 50.milliseconds

      response = transport.sent_messages.find { |msg| msg["id"]?.try(&.as_s?) == "ext-2" }
      response.should_not be_nil
      # Extension methods without handler get a null result, not method_not_found error
      response.as(JSON::Any)["result"]?.should_not be_nil
      response.as(JSON::Any)["error"]?.should be_nil

      client.close
    end

    it "routes extension notifications to on_notification handler" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64))
        end
      end
      client.initialize_connection

      received_method = ""
      received_params : JSON::Any? = nil
      client.on_notification = ->(method : String, params : JSON::Any?) : Nil {
        received_method = method
        received_params = params
      }

      transport.inject_raw(%({"jsonrpc": "2.0", "method": "_custom_event", "params": {"info": "test"}}))
      sleep 50.milliseconds

      received_method.should eq("_custom_event")
      received_params.try(&.["info"]?.try(&.as_s?)).should eq("test")

      client.close
    end
  end

  # ─── Session extension methods ────────────────────────────────────

  describe "Session extension methods" do
    it "delegates ext_method to client" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64))
        end
      end
      client.initialize_connection

      spawn do
        sleep 10.milliseconds
        if msg = transport.sent_messages.find { |m_item| m_item["method"]?.try(&.as_s?) == "session/new" }
          transport.inject_raw(build_session_new_response(msg["id"].as_i64))
        end
      end

      session = ACP::Session.create(client, cwd: "/tmp")

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(%({"jsonrpc": "2.0", "id": #{sent["id"].as_i64}, "result": {"custom": true}}))
      end

      result = session.ext_method("my_tool", JSON.parse(%({"input": "data"})))
      result["custom"].as_bool.should be_true

      client.close
    end

    it "delegates ext_notification to client" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64))
        end
      end
      client.initialize_connection

      spawn do
        sleep 10.milliseconds
        if msg = transport.sent_messages.find { |m_item| m_item["method"]?.try(&.as_s?) == "session/new" }
          transport.inject_raw(build_session_new_response(msg["id"].as_i64))
        end
      end

      session = ACP::Session.create(client, cwd: "/tmp")
      session.ext_notification("my_event", JSON.parse(%({"key": "val"})))

      sleep 20.milliseconds

      notif = transport.sent_messages.find { |msg| msg["method"]?.try(&.as_s?) == "_my_event" }
      notif.should_not be_nil

      client.close
    end

    it "raises on closed session" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64))
        end
      end
      client.initialize_connection

      spawn do
        sleep 10.milliseconds
        if msg = transport.sent_messages.find { |m_item| m_item["method"]?.try(&.as_s?) == "session/new" }
          transport.inject_raw(build_session_new_response(msg["id"].as_i64))
        end
      end

      session = ACP::Session.create(client, cwd: "/tmp")
      session.close

      expect_raises(ACP::InvalidStateError) do
        session.ext_method("test")
      end

      expect_raises(ACP::InvalidStateError) do
        session.ext_notification("test")
      end

      client.close
    end
  end
end

# ═══════════════════════════════════════════════════════════════════════
# Agent Method Constants Specs
# ═══════════════════════════════════════════════════════════════════════

describe ACP::Protocol::AgentMethod do
  it "has correct method name constants" do
    ACP::Protocol::AgentMethod::INITIALIZE.should eq("initialize")
    ACP::Protocol::AgentMethod::AUTHENTICATE.should eq("authenticate")
    ACP::Protocol::AgentMethod::SESSION_NEW.should eq("session/new")
    ACP::Protocol::AgentMethod::SESSION_LOAD.should eq("session/load")
    ACP::Protocol::AgentMethod::SESSION_PROMPT.should eq("session/prompt")
    ACP::Protocol::AgentMethod::SESSION_CANCEL.should eq("session/cancel")
    ACP::Protocol::AgentMethod::SESSION_SET_MODE.should eq("session/set_mode")
    ACP::Protocol::AgentMethod::SESSION_SET_CONFIG_OPTION.should eq("session/set_config_option")
    ACP::Protocol::AgentMethod::SESSION_UPDATE.should eq("session/update")
  end

  it "detects known methods" do
    ACP::Protocol::AgentMethod.known?("initialize").should be_true
    ACP::Protocol::AgentMethod.known?("session/prompt").should be_true
    ACP::Protocol::AgentMethod.known?("session/cancel").should be_true
    ACP::Protocol::AgentMethod.known?("unknown_method").should be_false
    ACP::Protocol::AgentMethod.known?("_extension").should be_false
  end

  it "detects session methods" do
    ACP::Protocol::AgentMethod.session_method?("session/new").should be_true
    ACP::Protocol::AgentMethod.session_method?("session/prompt").should be_true
    ACP::Protocol::AgentMethod.session_method?("session/set_config_option").should be_true
    ACP::Protocol::AgentMethod.session_method?("initialize").should be_false
    ACP::Protocol::AgentMethod.session_method?("authenticate").should be_false
  end
end

# ═══════════════════════════════════════════════════════════════════════
# ContentChunk Specs
# ═══════════════════════════════════════════════════════════════════════

describe ACP::Protocol::ContentChunk do
  it "wraps a text content block" do
    block = ACP::Protocol::TextContentBlock.new("Hello!")
    chunk = ACP::Protocol::ContentChunk.new(block)
    chunk.text.should eq("Hello!")
  end

  it "wraps an image content block" do
    block = ACP::Protocol::ImageContentBlock.new(data: "base64data", mime_type: "image/png")
    chunk = ACP::Protocol::ContentChunk.new(block)
    chunk.content.should be_a(ACP::Protocol::ImageContentBlock)
    chunk.text.should be_nil
  end

  it "serializes to JSON" do
    block = ACP::Protocol::TextContentBlock.new("test content")
    chunk = ACP::Protocol::ContentChunk.new(block)
    json = JSON.parse(chunk.to_json)
    json["content"]["type"].as_s.should eq("text")
    json["content"]["text"].as_s.should eq("test content")
  end

  it "deserializes from JSON" do
    json_str = %({"content": {"type": "text", "text": "hello world"}})
    chunk = ACP::Protocol::ContentChunk.from_json(json_str)
    chunk.text.should eq("hello world")
  end

  it "supports meta field" do
    block = ACP::Protocol::TextContentBlock.new("test")
    meta = {"source" => JSON::Any.new("test")}
    chunk = ACP::Protocol::ContentChunk.new(block, meta)
    chunk.meta.should_not be_nil
    chunk.meta.try(&.["source"]?.try(&.as_s?)).should eq("test")
  end
end

describe "ChunkUpdate#to_content_chunk" do
  it "converts AgentMessageChunkUpdate to ContentChunk" do
    json_str = %({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Hello agent!"}})
    update = ACP::Protocol::AgentMessageChunkUpdate.from_json(json_str)
    chunk = update.to_content_chunk
    chunk.should_not be_nil
    chunk.try(&.text).should eq("Hello agent!")
  end

  it "converts UserMessageChunkUpdate to ContentChunk" do
    json_str = %({"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "Hello user!"}})
    update = ACP::Protocol::UserMessageChunkUpdate.from_json(json_str)
    chunk = update.to_content_chunk
    chunk.should_not be_nil
    chunk.try(&.text).should eq("Hello user!")
  end

  it "converts AgentThoughtChunkUpdate to ContentChunk" do
    json_str = %({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "Thinking..."}})
    update = ACP::Protocol::AgentThoughtChunkUpdate.from_json(json_str)
    chunk = update.to_content_chunk
    chunk.should_not be_nil
    chunk.try(&.text).should eq("Thinking...")
  end

  it "returns nil for non-ContentBlock content" do
    json_str = %({"sessionUpdate": "agent_message_chunk", "content": "raw text"})
    update = ACP::Protocol::AgentMessageChunkUpdate.from_json(json_str)
    update.to_content_chunk.should be_nil
    # but text helper still works
    update.text.should eq("raw text")
  end
end

# ═══════════════════════════════════════════════════════════════════════
# ConfigOptionGroup Specs
# ═══════════════════════════════════════════════════════════════════════

describe ACP::Protocol::ConfigOptionGroup do
  it "creates a group with values" do
    group = ACP::Protocol::ConfigOptionGroup.new(
      id: "openai",
      name: "OpenAI Models",
      options: [
        ACP::Protocol::ConfigOptionValue.new(value: "gpt-4", name: "GPT-4"),
        ACP::Protocol::ConfigOptionValue.new(value: "gpt-3.5", name: "GPT-3.5"),
      ]
    )
    group.id.should eq("openai")
    group.name.should eq("OpenAI Models")
    group.options.size.should eq(2)
  end

  it "serializes to JSON" do
    group = ACP::Protocol::ConfigOptionGroup.new(
      id: "anthropic",
      name: "Anthropic",
      options: [
        ACP::Protocol::ConfigOptionValue.new(value: "claude-4", name: "Claude 4"),
      ]
    )
    json = JSON.parse(group.to_json)
    json["id"].as_s.should eq("anthropic")
    json["name"].as_s.should eq("Anthropic")
    json["options"].as_a.size.should eq(1)
    json["options"][0]["value"].as_s.should eq("claude-4")
  end

  it "deserializes from JSON" do
    json_str = %({"id": "g1", "name": "Group 1", "options": [{"value": "v1", "name": "Value 1"}]})
    group = ACP::Protocol::ConfigOptionGroup.from_json(json_str)
    group.id.should eq("g1")
    group.options.first.value.should eq("v1")
  end
end

describe "ConfigOption with groups" do
  it "supports flat options (backward compatible)" do
    opt = ACP::Protocol::ConfigOption.new(
      id: "model",
      name: "Model",
      options: [
        ACP::Protocol::ConfigOptionValue.new(value: "gpt-4", name: "GPT-4"),
      ]
    )
    opt.grouped?.should be_false
    opt.all_values.size.should eq(1)
    opt.all_values.first.value.should eq("gpt-4")
  end

  it "supports grouped options" do
    opt = ACP::Protocol::ConfigOption.new(
      id: "model",
      name: "Model",
      category: "model",
      groups: [
        ACP::Protocol::ConfigOptionGroup.new(
          id: "openai",
          name: "OpenAI",
          options: [
            ACP::Protocol::ConfigOptionValue.new(value: "gpt-4", name: "GPT-4"),
            ACP::Protocol::ConfigOptionValue.new(value: "gpt-3.5", name: "GPT-3.5"),
          ]
        ),
        ACP::Protocol::ConfigOptionGroup.new(
          id: "anthropic",
          name: "Anthropic",
          options: [
            ACP::Protocol::ConfigOptionValue.new(value: "claude-4", name: "Claude 4"),
          ]
        ),
      ]
    )
    opt.grouped?.should be_true
    opt.all_values.size.should eq(3)
    opt.all_values.map(&.value).should contain("gpt-4")
    opt.all_values.map(&.value).should contain("claude-4")
  end

  it "serializes grouped options to JSON" do
    opt = ACP::Protocol::ConfigOption.new(
      id: "model",
      name: "Model",
      current_value: "gpt-4",
      groups: [
        ACP::Protocol::ConfigOptionGroup.new(
          id: "openai",
          name: "OpenAI",
          options: [
            ACP::Protocol::ConfigOptionValue.new(value: "gpt-4", name: "GPT-4"),
          ]
        ),
      ]
    )
    json = JSON.parse(opt.to_json)
    json["groups"].as_a.size.should eq(1)
    json["groups"][0]["id"].as_s.should eq("openai")
    json["groups"][0]["options"][0]["value"].as_s.should eq("gpt-4")
    json["currentValue"].as_s.should eq("gpt-4")
  end

  it "deserializes grouped options from JSON" do
    json_str = <<-JSON
      {
        "id": "model",
        "name": "Model Selector",
        "type": "select",
        "category": "model",
        "currentValue": "claude-4",
        "groups": [
          {
            "id": "anthropic",
            "name": "Anthropic",
            "options": [
              {"value": "claude-4", "name": "Claude 4"},
              {"value": "claude-3.5", "name": "Claude 3.5"}
            ]
          },
          {
            "id": "openai",
            "name": "OpenAI",
            "options": [
              {"value": "gpt-4", "name": "GPT-4"}
            ]
          }
        ]
      }
      JSON
    opt = ACP::Protocol::ConfigOption.from_json(json_str)
    opt.grouped?.should be_true
    opt.category.should eq("model")
    opt.current_value.should eq("claude-4")
    opt.all_values.size.should eq(3)
  end

  it "returns empty array when no options or groups" do
    opt = ACP::Protocol::ConfigOption.new(id: "empty", name: "Empty")
    opt.grouped?.should be_false
    opt.all_values.should be_empty
  end
end

# ═══════════════════════════════════════════════════════════════════════
# Type Aliases Specs
# ═══════════════════════════════════════════════════════════════════════

describe "Type aliases" do
  it "SessionConfigSelectOption is alias for ConfigOptionValue" do
    val = ACP::Protocol::SessionConfigSelectOption.new(value: "v1", name: "V1")
    val.should be_a(ACP::Protocol::ConfigOptionValue)
  end

  it "SessionConfigSelectGroup is alias for ConfigOptionGroup" do
    group = ACP::Protocol::SessionConfigSelectGroup.new(id: "g1", name: "G1")
    group.should be_a(ACP::Protocol::ConfigOptionGroup)
  end

  it "SessionConfigOption is alias for ConfigOption" do
    opt = ACP::Protocol::SessionConfigOption.new(id: "o1", name: "O1")
    opt.should be_a(ACP::Protocol::ConfigOption)
  end
end

# ═══════════════════════════════════════════════════════════════════════
# build_notification_raw Specs
# ═══════════════════════════════════════════════════════════════════════

describe "Protocol.build_notification_raw" do
  it "builds a notification with raw JSON params" do
    params = JSON.parse(%({"key": "value"}))
    msg = ACP::Protocol.build_notification_raw("_my_event", params)
    msg["jsonrpc"].as(JSON::Any).as_s.should eq("2.0")
    msg["method"].as(JSON::Any).as_s.should eq("_my_event")
    msg["params"].as(JSON::Any)["key"].as_s.should eq("value")
    msg["id"]?.should be_nil
  end
end
