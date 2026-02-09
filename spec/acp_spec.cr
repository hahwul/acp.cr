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
    return nil if @closed
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
  %({
    "jsonrpc": "2.0",
    "id": #{id},
    "result": {
      "protocolVersion": #{protocol_version},
      "agentCapabilities": {
        "loadSession": true,
        "promptCapabilities": {
          "image": true,
          "audio": false,
          "file": true
        }
      },
      "authMethods": [],
      "agentInfo": {
        "name": "test-agent",
        "version": "1.0.0"
      }
    }
  })
end

def build_session_new_response(id : Int64, session_id : String = "sess-001") : String
  %({
    "jsonrpc": "2.0",
    "id": #{id},
    "result": {
      "sessionId": "#{session_id}",
      "modes": [
        {"id": "code", "label": "Code Mode", "description": "Write code"},
        {"id": "chat", "label": "Chat Mode", "description": "Just chat"}
      ],
      "configOptions": []
    }
  })
end

def build_prompt_response(id : Int64, stop_reason : String = "end_turn") : String
  %({
    "jsonrpc": "2.0",
    "id": #{id},
    "result": {
      "stopReason": "#{stop_reason}"
    }
  })
end

def build_error_response(id : Int64, code : Int32 = -32600, message : String = "Invalid Request") : String
  %({
    "jsonrpc": "2.0",
    "id": #{id},
    "error": {
      "code": #{code},
      "message": "#{message}"
    }
  })
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
        list_directory: true
      )
      json = JSON.parse(fs.to_json)
      json["readTextFile"].as_bool.should eq(true)
      json["writeTextFile"].as_bool.should eq(false)
      json["listDirectory"].as_bool.should eq(true)
    end

    it "deserializes from JSON" do
      json_str = %({"readTextFile": true, "writeTextFile": true, "listDirectory": false})
      fs = ACP::Protocol::FsCapabilities.from_json(json_str)
      fs.read_text_file.should eq(true)
      fs.write_text_file.should eq(true)
      fs.list_directory.should eq(false)
    end

    it "defaults all capabilities to false" do
      fs = ACP::Protocol::FsCapabilities.new
      fs.read_text_file.should eq(false)
      fs.write_text_file.should eq(false)
      fs.list_directory.should eq(false)
    end
  end

  describe ACP::Protocol::ClientCapabilities do
    it "serializes with fs and terminal" do
      caps = ACP::Protocol::ClientCapabilities.new(
        fs: ACP::Protocol::FsCapabilities.new(read_text_file: true),
        terminal: true
      )
      json = JSON.parse(caps.to_json)
      json["terminal"].as_bool.should eq(true)
      json["fs"]["readTextFile"].as_bool.should eq(true)
    end

    it "serializes with nil fs" do
      caps = ACP::Protocol::ClientCapabilities.new(terminal: false)
      json = JSON.parse(caps.to_json)
      json["terminal"].as_bool.should eq(false)
      json["fs"]?.try(&.raw).should be_nil
    end
  end

  describe ACP::Protocol::AgentCapabilities do
    it "deserializes from JSON" do
      json_str = %({"loadSession": true, "promptCapabilities": {"image": true, "audio": false, "file": true}})
      caps = ACP::Protocol::AgentCapabilities.from_json(json_str)
      caps.load_session.should eq(true)
      caps.prompt_capabilities.should_not be_nil
      caps.prompt_capabilities.not_nil!.image.should eq(true)
      caps.prompt_capabilities.not_nil!.audio.should eq(false)
      caps.prompt_capabilities.not_nil!.file.should eq(true)
    end

    it "defaults to no capabilities" do
      caps = ACP::Protocol::AgentCapabilities.new
      caps.load_session.should eq(false)
      caps.prompt_capabilities.should be_nil
    end
  end

  describe ACP::Protocol::PromptCapabilities do
    it "round-trips through JSON" do
      original = ACP::Protocol::PromptCapabilities.new(image: true, audio: true, file: false)
      json_str = original.to_json
      restored = ACP::Protocol::PromptCapabilities.from_json(json_str)
      restored.image.should eq(true)
      restored.audio.should eq(true)
      restored.file.should eq(false)
    end
  end

  describe ACP::Protocol::ClientInfo do
    it "serializes name and version" do
      info = ACP::Protocol::ClientInfo.new("my-editor", "2.1.0")
      json = JSON.parse(info.to_json)
      json["name"].as_s.should eq("my-editor")
      json["version"].as_s.should eq("2.1.0")
    end
  end

  describe ACP::Protocol::AgentInfo do
    it "deserializes from JSON" do
      info = ACP::Protocol::AgentInfo.from_json(%({"name": "cool-agent", "version": "3.0"}))
      info.name.should eq("cool-agent")
      info.version.should eq("3.0")
    end
  end

  describe ACP::Protocol::McpServer do
    it "serializes with optional auth" do
      server = ACP::Protocol::McpServer.new("https://mcp.example.com", auth: "token-123")
      json = JSON.parse(server.to_json)
      json["url"].as_s.should eq("https://mcp.example.com")
      json["auth"].as_s.should eq("token-123")
    end

    it "serializes without auth" do
      server = ACP::Protocol::McpServer.new("https://mcp.example.com")
      json = JSON.parse(server.to_json)
      json["url"].as_s.should eq("https://mcp.example.com")
      json["auth"]?.try(&.raw).should be_nil
    end
  end

  # ─── Content Blocks ─────────────────────────────────────────────────

  describe ACP::Protocol::TextContentBlock do
    it "serializes with type discriminator" do
      block = ACP::Protocol::TextContentBlock.new("Hello, world!")
      json = JSON.parse(block.to_json)
      json["type"].as_s.should eq("text")
      json["content"].as_s.should eq("Hello, world!")
    end

    it "deserializes via ContentBlock discriminator" do
      json_str = %({"type": "text", "content": "Test content"})
      block = ACP::Protocol::ContentBlock.from_json(json_str)
      block.should be_a(ACP::Protocol::TextContentBlock)
      block.as(ACP::Protocol::TextContentBlock).content.should eq("Test content")
    end
  end

  describe ACP::Protocol::ImageContentBlock do
    it "serializes with URL" do
      block = ACP::Protocol::ImageContentBlock.new(url: "https://example.com/img.png", mime_type: "image/png")
      json = JSON.parse(block.to_json)
      json["type"].as_s.should eq("image")
      json["url"].as_s.should eq("https://example.com/img.png")
      json["mimeType"].as_s.should eq("image/png")
    end

    it "deserializes via ContentBlock discriminator" do
      json_str = %({"type": "image", "url": "file:///tmp/img.jpg"})
      block = ACP::Protocol::ContentBlock.from_json(json_str)
      block.should be_a(ACP::Protocol::ImageContentBlock)
      block.as(ACP::Protocol::ImageContentBlock).url.should eq("file:///tmp/img.jpg")
    end
  end

  describe ACP::Protocol::AudioContentBlock do
    it "serializes with data" do
      block = ACP::Protocol::AudioContentBlock.new(data: "base64data==", mime_type: "audio/wav")
      json = JSON.parse(block.to_json)
      json["type"].as_s.should eq("audio")
      json["data"].as_s.should eq("base64data==")
      json["mimeType"].as_s.should eq("audio/wav")
    end

    it "deserializes via ContentBlock discriminator" do
      json_str = %({"type": "audio", "url": "https://example.com/audio.mp3"})
      block = ACP::Protocol::ContentBlock.from_json(json_str)
      block.should be_a(ACP::Protocol::AudioContentBlock)
    end
  end

  describe ACP::Protocol::FileContentBlock do
    it "serializes with path" do
      block = ACP::Protocol::FileContentBlock.new("/home/user/code.cr", "text/x-crystal")
      json = JSON.parse(block.to_json)
      json["type"].as_s.should eq("file")
      json["path"].as_s.should eq("/home/user/code.cr")
      json["mimeType"].as_s.should eq("text/x-crystal")
    end

    it "deserializes via ContentBlock discriminator" do
      json_str = %({"type": "file", "path": "/tmp/test.txt"})
      block = ACP::Protocol::ContentBlock.from_json(json_str)
      block.should be_a(ACP::Protocol::FileContentBlock)
      block.as(ACP::Protocol::FileContentBlock).path.should eq("/tmp/test.txt")
    end
  end

  describe ACP::Protocol::ContentBlocks do
    it "creates text blocks" do
      block = ACP::Protocol::ContentBlocks.text("hello")
      block.should be_a(ACP::Protocol::TextContentBlock)
      block.content.should eq("hello")
    end

    it "creates image URL blocks" do
      block = ACP::Protocol::ContentBlocks.image_url("https://img.com/pic.png", "image/png")
      block.should be_a(ACP::Protocol::ImageContentBlock)
      block.url.should eq("https://img.com/pic.png")
      block.mime_type.should eq("image/png")
    end

    it "creates file blocks" do
      block = ACP::Protocol::ContentBlocks.file("/path/to/file.txt")
      block.should be_a(ACP::Protocol::FileContentBlock)
      block.path.should eq("/path/to/file.txt")
    end
  end

  # ─── Session Update Types ──────────────────────────────────────────

  describe ACP::Protocol::SessionUpdate do
    it "deserializes agent_message_chunk" do
      json_str = %({"type": "agent_message_chunk", "content": "Hello from agent"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::AgentMessageChunkUpdate)
      update.as(ACP::Protocol::AgentMessageChunkUpdate).content.should eq("Hello from agent")
    end

    it "deserializes agent_message_start" do
      json_str = %({"type": "agent_message_start", "messageId": "msg-1", "role": "assistant"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::AgentMessageStartUpdate)
      u = update.as(ACP::Protocol::AgentMessageStartUpdate)
      u.message_id.should eq("msg-1")
      u.role.should eq("assistant")
    end

    it "deserializes agent_message_end" do
      json_str = %({"type": "agent_message_end", "stopReason": "end_turn"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::AgentMessageEndUpdate)
      update.as(ACP::Protocol::AgentMessageEndUpdate).stop_reason.should eq("end_turn")
    end

    it "deserializes thought" do
      json_str = %({"type": "thought", "content": "Let me think...", "title": "Reasoning"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::ThoughtUpdate)
      u = update.as(ACP::Protocol::ThoughtUpdate)
      u.content.should eq("Let me think...")
      u.title.should eq("Reasoning")
    end

    it "deserializes tool_call_start" do
      json_str = %({"type": "tool_call_start", "toolCallId": "tc-1", "title": "Read file", "toolName": "fs.read", "status": "pending"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::ToolCallStartUpdate)
      u = update.as(ACP::Protocol::ToolCallStartUpdate)
      u.tool_call_id.should eq("tc-1")
      u.title.should eq("Read file")
      u.tool_name.should eq("fs.read")
      u.status.should eq("pending")
    end

    it "deserializes tool_call_chunk" do
      json_str = %({"type": "tool_call_chunk", "toolCallId": "tc-1", "content": "file data", "kind": "output"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::ToolCallChunkUpdate)
      u = update.as(ACP::Protocol::ToolCallChunkUpdate)
      u.tool_call_id.should eq("tc-1")
      u.content.should eq("file data")
      u.kind.should eq("output")
    end

    it "deserializes tool_call_end" do
      json_str = %({"type": "tool_call_end", "toolCallId": "tc-1", "status": "completed", "result": "done"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::ToolCallEndUpdate)
      u = update.as(ACP::Protocol::ToolCallEndUpdate)
      u.tool_call_id.should eq("tc-1")
      u.status.should eq("completed")
      u.result.should eq("done")
    end

    it "deserializes plan with steps" do
      json_str = %({"type": "plan", "title": "Implementation Plan", "steps": [{"title": "Step 1", "status": "completed"}, {"title": "Step 2", "status": "pending"}]})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::PlanUpdate)
      u = update.as(ACP::Protocol::PlanUpdate)
      u.title.should eq("Implementation Plan")
      steps = u.steps.not_nil!
      steps.size.should eq(2)
      steps[0].title.should eq("Step 1")
      steps[0].status.should eq("completed")
      steps[1].title.should eq("Step 2")
      steps[1].status.should eq("pending")
    end

    it "deserializes status" do
      json_str = %({"type": "status", "status": "thinking", "message": "Processing your request"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::StatusUpdate)
      u = update.as(ACP::Protocol::StatusUpdate)
      u.status.should eq("thinking")
      u.message.should eq("Processing your request")
    end

    it "deserializes error" do
      json_str = %({"type": "error", "message": "Something went wrong", "code": -1, "detail": "stack trace here"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      update.should be_a(ACP::Protocol::ErrorUpdate)
      u = update.as(ACP::Protocol::ErrorUpdate)
      u.message.should eq("Something went wrong")
      u.code.should eq(-1)
      u.detail.should eq("stack trace here")
    end
  end

  describe ACP::Protocol::SessionUpdateParams do
    it "deserializes full update notification params" do
      json_str = %({"sessionId": "sess-001", "update": {"type": "agent_message_chunk", "content": "Hi"}})
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
      json["clientCapabilities"]["terminal"].as_bool.should eq(true)
      json["clientInfo"]["name"].as_s.should eq("test")
      json["clientInfo"]["version"].as_s.should eq("0.1")
    end
  end

  describe ACP::Protocol::InitializeResult do
    it "deserializes from JSON" do
      json_str = %({
        "protocolVersion": 1,
        "agentCapabilities": {"loadSession": true, "promptCapabilities": {"image": true, "audio": false, "file": false}},
        "authMethods": ["oauth"],
        "agentInfo": {"name": "agent", "version": "1.0"}
      })
      result = ACP::Protocol::InitializeResult.from_json(json_str)
      result.protocol_version.should eq(1)
      result.agent_capabilities.load_session.should eq(true)
      result.agent_capabilities.prompt_capabilities.not_nil!.image.should eq(true)
      result.auth_methods.should eq(["oauth"])
      result.agent_info.not_nil!.name.should eq("agent")
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
      servers = [ACP::Protocol::McpServer.new("https://mcp.example.com")]
      params = ACP::Protocol::SessionNewParams.new("/home/user/project", servers)
      json = JSON.parse(params.to_json)
      json["cwd"].as_s.should eq("/home/user/project")
      json["mcpServers"].as_a.size.should eq(1)
      json["mcpServers"][0]["url"].as_s.should eq("https://mcp.example.com")
    end

    it "serializes without mcpServers" do
      params = ACP::Protocol::SessionNewParams.new("/tmp")
      json = JSON.parse(params.to_json)
      json["cwd"].as_s.should eq("/tmp")
      json["mcpServers"]?.try(&.raw).should be_nil
    end
  end

  describe ACP::Protocol::SessionNewResult do
    it "deserializes session ID with modes" do
      json_str = %({
        "sessionId": "sess-abc",
        "modes": [{"id": "code", "label": "Code"}],
        "configOptions": [{"id": "opt1", "label": "Option 1"}]
      })
      result = ACP::Protocol::SessionNewResult.from_json(json_str)
      result.session_id.should eq("sess-abc")
      result.modes.not_nil!.size.should eq(1)
      result.modes.not_nil![0].id.should eq("code")
      result.config_options.not_nil!.size.should eq(1)
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
    it "serializes with session ID and cwd" do
      params = ACP::Protocol::SessionLoadParams.new("sess-123", "/tmp")
      json = JSON.parse(params.to_json)
      json["sessionId"].as_s.should eq("sess-123")
      json["cwd"].as_s.should eq("/tmp")
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
      json["prompt"][0]["content"].as_s.should eq("hello")
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
        label: "Theme",
        config_type: "enum",
        value: JSON::Any.new("dark"),
        options: [JSON::Any.new("light"), JSON::Any.new("dark")],
        description: "UI Theme"
      )
      json_str = opt.to_json
      restored = ACP::Protocol::ConfigOption.from_json(json_str)
      restored.id.should eq("theme")
      restored.label.should eq("Theme")
      restored.config_type.should eq("enum")
      restored.value.not_nil!.as_s.should eq("dark")
      restored.options.not_nil!.size.should eq(2)
      restored.description.should eq("UI Theme")
    end
  end

  describe ACP::Protocol::RequestPermissionParams do
    it "deserializes permission request" do
      json_str = %({
        "sessionId": "sess-001",
        "toolCall": {
          "toolCallId": "tc-1",
          "title": "Write to file",
          "toolName": "fs.write",
          "input": {"path": "/tmp/file.txt", "content": "data"}
        },
        "options": [
          {"id": "allow_once", "label": "Allow Once"},
          {"id": "allow_always", "label": "Allow Always"},
          {"id": "deny", "label": "Deny"}
        ]
      })
      params = ACP::Protocol::RequestPermissionParams.from_json(json_str)
      params.session_id.should eq("sess-001")
      params.tool_call.tool_call_id.should eq("tc-1")
      params.tool_call.tool_name.should eq("fs.write")
      params.options.size.should eq(3)
      params.options[0].id.should eq("allow_once")
      params.options[1].label.should eq("Allow Always")
    end
  end

  describe ACP::Protocol::ModeOption do
    it "round-trips through JSON" do
      mode = ACP::Protocol::ModeOption.new("code", "Code Mode", "Write and edit code")
      json_str = mode.to_json
      restored = ACP::Protocol::ModeOption.from_json(json_str)
      restored.id.should eq("code")
      restored.label.should eq("Code Mode")
      restored.description.should eq("Write and edit code")
    end
  end

  describe ACP::Protocol::PlanStep do
    it "round-trips through JSON" do
      step = ACP::Protocol::PlanStep.new("Implement feature", id: "s1", status: "in_progress")
      json_str = step.to_json
      restored = ACP::Protocol::PlanStep.from_json(json_str)
      restored.title.should eq("Implement feature")
      restored.id.should eq("s1")
      restored.status.should eq("in_progress")
    end

    it "defaults status to pending" do
      step = ACP::Protocol::PlanStep.new("Some step")
      step.status.should eq("pending")
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
      msg.has_key?("id").should eq(false)
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
    error.message.not_nil!.should contain("1")
    error.message.not_nil!.should contain("2")
  end

  it "handles nil agent version" do
    error = ACP::VersionMismatchError.new(1_u16)
    error.agent_version.should be_nil
    error.message.not_nil!.should contain("unknown")
  end
end

describe ACP::InvalidStateError do
  it "has a default message" do
    error = ACP::InvalidStateError.new
    error.message.not_nil!.should contain("Invalid client state")
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
    ACP::JsonRpcError.new(-32700, "Parse error").parse_error?.should eq(true)
    ACP::JsonRpcError.new(-32600, "Invalid Request").invalid_request?.should eq(true)
    ACP::JsonRpcError.new(-32601, "Method not found").method_not_found?.should eq(true)
    ACP::JsonRpcError.new(-32602, "Invalid params").invalid_params?.should eq(true)
    ACP::JsonRpcError.new(-32603, "Internal error").internal_error?.should eq(true)
  end

  it "identifies server errors" do
    ACP::JsonRpcError.new(-32000, "Server error").server_error?.should eq(true)
    ACP::JsonRpcError.new(-32050, "Server error").server_error?.should eq(true)
    ACP::JsonRpcError.new(-32099, "Server error").server_error?.should eq(true)
    ACP::JsonRpcError.new(-32100, "Not server error").server_error?.should eq(false)
    ACP::JsonRpcError.new(-31999, "Not server error").server_error?.should eq(false)
  end

  it "creates from JSON::Any" do
    obj = JSON.parse(%({"code": -32601, "message": "Method not found", "data": {"method": "foo"}}))
    error = ACP::JsonRpcError.from_json_any(obj)
    error.code.should eq(-32601)
    error.message.should eq("Method not found")
    error.data.not_nil!["method"].as_s.should eq("foo")
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
    error.message.not_nil!.should contain("sess-123")
  end
end

describe ACP::NoActiveSessionError do
  it "has a default message" do
    error = ACP::NoActiveSessionError.new
    error.message.not_nil!.should contain("No active session")
  end
end

describe ACP::RequestTimeoutError do
  it "includes request ID and timeout" do
    error = ACP::RequestTimeoutError.new(42_i64, 30.0)
    error.request_id.should eq(42_i64)
    error.message.not_nil!.should contain("42")
    error.message.not_nil!.should contain("30.0")
  end
end

describe ACP::RequestCancelledError do
  it "includes request ID" do
    error = ACP::RequestCancelledError.new(7_i64)
    error.request_id.should eq(7_i64)
    error.message.not_nil!.should contain("7")
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
    transport.closed?.should eq(false)
    transport.close
    transport.closed?.should eq(true)
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
    msg.not_nil!["method"].as_s.should eq("test")

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
    msg.not_nil!["method"].as_s.should eq("valid")

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

    msg1.not_nil!["id"].as_i.should eq(1)
    msg2.not_nil!["id"].as_i.should eq(2)
    msg3.not_nil!["id"].as_i.should eq(3)

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
    t.last_sent.not_nil!["test"].as_s.should eq("hello")
  end

  it "delivers injected messages" do
    t = TestTransport.new
    t.inject_raw(%({"method": "test"}))
    msg = t.receive
    msg.should_not be_nil
    msg.not_nil!["method"].as_s.should eq("test")
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
      client.closed?.should eq(false)
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
      result.agent_info.not_nil!.name.should eq("test-agent")
      result.agent_capabilities.load_session.should eq(true)

      client.state.should eq(ACP::ClientState::Initialized)
      client.agent_capabilities.not_nil!.load_session.should eq(true)
      client.agent_info.not_nil!.name.should eq("test-agent")
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
      params["clientCapabilities"]["terminal"].as_bool.should eq(true)
      params["clientCapabilities"]["fs"]["readTextFile"].as_bool.should eq(true)

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
      result.modes.not_nil!.size.should eq(2)

      client.state.should eq(ACP::ClientState::SessionActive)
      client.session_id.should eq("sess-test-001")
      client.session_active?.should eq(true)

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

      servers = [ACP::Protocol::McpServer.new("https://mcp.test")]
      client.session_new("/my/project", servers)

      # Find the session/new request
      session_req = transport.sent_messages.find { |m| m["method"]?.try(&.as_s?) == "session/new" }
      session_req.should_not be_nil
      params = session_req.not_nil!["params"]
      params["cwd"].as_s.should eq("/my/project")
      params["mcpServers"].as_a.size.should eq(1)

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
        transport.inject_raw(build_session_new_response(sent["id"].as_i64, "sess-loaded"))
      end

      result = client.session_load("sess-loaded")
      result.session_id.should eq("sess-loaded")
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
        transport.inject_raw(%({
          "jsonrpc": "2.0",
          "id": #{sent["id"].as_i64},
          "result": {}
        }))
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
      prompt_req = transport.sent_messages.find { |m| m["method"]?.try(&.as_s?) == "session/prompt" }
      prompt_req.should_not be_nil
      params = prompt_req.not_nil!["params"]
      params["sessionId"].as_s.should_not be_empty
      params["prompt"].as_a.size.should eq(1)
      params["prompt"][0]["type"].as_s.should eq("text")
      params["prompt"][0]["content"].as_s.should eq("Hello!")

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
      cancel_msg.not_nil!["method"].as_s.should eq("session/cancel")
      cancel_msg.not_nil!.as_h.has_key?("id").should eq(false)
      cancel_msg.not_nil!["params"]["sessionId"].as_s.should eq("sess-cancel-test")

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
      client.closed?.should eq(true)
      client.state.should eq(ACP::ClientState::Closed)
    end

    it "is idempotent" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)
      client.close
      client.close # Should not raise
      client.closed?.should eq(true)
    end

    it "closes the transport" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)
      client.close
      transport.closed?.should eq(true)
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
      transport.inject_raw(%({
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {
          "sessionId": "sess-001",
          "update": {
            "type": "agent_message_chunk",
            "content": "Hello from agent"
          }
        }
      }))

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
      transport.inject_raw(%({
        "jsonrpc": "2.0",
        "method": "_custom/event",
        "params": {"data": "test"}
      }))

      sleep 50.milliseconds

      received_notifications.size.should eq(1)
      received_notifications[0][0].should eq("_custom/event")
      received_notifications[0][1].not_nil!["data"].as_s.should eq("test")

      transport.close
    end
  end

  describe "agent request handling" do
    it "handles session/request_permission via on_agent_request" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      client.on_agent_request = ->(method : String, params : JSON::Any) do
        if method == "session/request_permission"
          JSON.parse(%({"outcome": {"selected": "allow_once"}}))
        else
          JSON.parse(%({"error": "unknown method"}))
        end
      end

      # Inject a permission request from the agent
      transport.inject_raw(%({
        "jsonrpc": "2.0",
        "id": "perm-1",
        "method": "session/request_permission",
        "params": {
          "sessionId": "sess-001",
          "toolCall": {"toolCallId": "tc-1", "toolName": "fs.write"},
          "options": [{"id": "allow_once", "label": "Allow Once"}]
        }
      }))

      sleep 50.milliseconds

      # Check that the client sent a response
      response = transport.sent_messages.find { |m| m["id"]?.try(&.as_s?) == "perm-1" }
      response.should_not be_nil
      response.not_nil!["result"]["outcome"]["selected"].as_s.should eq("allow_once")

      transport.close
    end

    it "auto-cancels permission requests when no handler is set" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      # No on_agent_request handler set

      transport.inject_raw(%({
        "jsonrpc": "2.0",
        "id": "perm-2",
        "method": "session/request_permission",
        "params": {
          "sessionId": "sess-001",
          "toolCall": {"toolCallId": "tc-1"},
          "options": [{"id": "allow_once", "label": "Allow"}]
        }
      }))

      sleep 50.milliseconds

      response = transport.sent_messages.find { |m| m["id"]?.try(&.as_s?) == "perm-2" }
      response.should_not be_nil
      response.not_nil!["result"]["outcome"].as_s.should eq("cancelled")

      transport.close
    end

    it "returns method-not-found for unknown agent methods without handler" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      transport.inject_raw(%({
        "jsonrpc": "2.0",
        "id": "unk-1",
        "method": "unknown/method",
        "params": {}
      }))

      sleep 50.milliseconds

      response = transport.sent_messages.find { |m| m["id"]?.try(&.as_s?) == "unk-1" }
      response.should_not be_nil
      response.not_nil!["error"]["code"].as_i.should eq(-32601)

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

      disconnected.should eq(true)

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
      session.closed?.should eq(false)
      session.modes.not_nil!.size.should eq(2)

      transport.close
    end
  end

  describe ".load" do
    it "loads an existing session" do
      transport, client = setup_client_with_session

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64, "sess-existing"))
      end

      session = ACP::Session.load(client, session_id: "sess-existing")
      session.id.should eq("sess-existing")
      session.closed?.should eq(false)

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
      cancel_msg.not_nil!["method"].as_s.should eq("session/cancel")
      cancel_msg.not_nil!["params"]["sessionId"].as_s.should eq("sess-cancel")

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
      session.closed?.should eq(false)
      session.close
      session.closed?.should eq(true)

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
        transport.inject_raw(%({
          "jsonrpc": "2.0",
          "id": #{sent["id"].as_i64},
          "result": {"sessionId": "sess-no-modes"}
        }))
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

  describe "#set_mode" do
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
        transport.inject_raw(%({
          "jsonrpc": "2.0",
          "id": #{sent["id"].as_i64},
          "result": {}
        }))
      end

      session.set_mode("chat")

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
    builder.empty?.should eq(true)
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
      .image("https://example.com/img.png", "image/png")
      .file("/path/to/code.cr")

    blocks = builder.build
    blocks.size.should eq(3)
    blocks[0].should be_a(ACP::Protocol::TextContentBlock)
    blocks[1].should be_a(ACP::Protocol::ImageContentBlock)
    blocks[2].should be_a(ACP::Protocol::FileContentBlock)
  end

  it "supports method chaining" do
    builder = ACP::PromptBuilder.new
    result = builder.text("a").text("b").text("c")
    result.should be(builder)
    builder.size.should eq(3)
  end

  it "builds image_data blocks" do
    builder = ACP::PromptBuilder.new
    builder.image_data("base64==", "image/jpeg")
    blocks = builder.build
    blocks.size.should eq(1)
    img = blocks[0].as(ACP::Protocol::ImageContentBlock)
    img.data.should eq("base64==")
    img.mime_type.should eq("image/jpeg")
  end

  it "builds audio blocks" do
    builder = ACP::PromptBuilder.new
    builder.audio("https://example.com/sound.mp3")
    builder.audio_data("base64audio==", "audio/mp3")
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
          transport.inject_raw(%({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
              "sessionId": "integration-sess",
              "update": {"type": "agent_message_start", "messageId": "m1", "role": "assistant"}
            }
          }))

          sleep 5.milliseconds

          transport.inject_raw(%({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
              "sessionId": "integration-sess",
              "update": {"type": "agent_message_chunk", "content": "Hello, ", "messageId": "m1"}
            }
          }))

          sleep 5.milliseconds

          transport.inject_raw(%({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
              "sessionId": "integration-sess",
              "update": {"type": "agent_message_chunk", "content": "world!", "messageId": "m1"}
            }
          }))

          sleep 5.milliseconds

          transport.inject_raw(%({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
              "sessionId": "integration-sess",
              "update": {"type": "agent_message_end", "messageId": "m1", "stopReason": "end_turn"}
            }
          }))

          sleep 5.milliseconds

          # Finally send the prompt result
          transport.inject_raw(build_prompt_response(id, "end_turn"))
          transport.clear_sent
        end
      end
    end

    # Execute the full flow
    init_result = client.initialize_connection
    init_result.agent_info.not_nil!.name.should eq("test-agent")

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
    chunks = updates_received.select(&.is_a?(ACP::Protocol::AgentMessageChunkUpdate))
    full_message = chunks.map { |c| c.as(ACP::Protocol::AgentMessageChunkUpdate).content }.join
    full_message.should eq("Hello, world!")

    # Verify message start and end
    updates_received.any?(&.is_a?(ACP::Protocol::AgentMessageStartUpdate)).should eq(true)
    updates_received.any?(&.is_a?(ACP::Protocol::AgentMessageEndUpdate)).should eq(true)

    # Clean up
    session.close
    client.close
    client.closed?.should eq(true)
  end

  it "handles permission request during a prompt" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    # Set up permission handler
    permission_requests_received = 0
    client.on_agent_request = ->(method : String, params : JSON::Any) do
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
          transport.inject_raw(%({
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
          }))

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
    perm_response = transport.sent_messages.find { |m| m["id"]?.try(&.as_s?) == "perm-req-1" }
    perm_response.should_not be_nil
    perm_response.not_nil!["result"]["outcome"]["selected"].as_s.should eq("allow_once")

    client.close
  end
end
