require "./spec_helper"

describe "ACP v2 Preview initialization" do
  it "builds initialize and auth/login requests using the v2 wire names" do
    client_info = ACP::Protocol::V2::Implementation.new("editor", "1", title: "Editor")
    capabilities = ACP::Protocol::V2::ClientCapabilities.new(
      auth: ACP::Protocol::V2::ClientAuthCapabilities.new(terminal: ACP::Protocol::V2::Capability.new)
    )
    params = ACP::Protocol::V2::InitializeParams.new(client_info, capabilities: capabilities)
    request = ACP::Protocol.build_request(1_i64, ACP::Protocol::V2::AgentMethod::INITIALIZE, params)
    request["params"].should eq(JSON.parse(%({"protocolVersion":2,"info":{"name":"editor","version":"1","title":"Editor"},"capabilities":{"auth":{"terminal":{}}}})))
    expect_raises(JSON::SerializableError) do
      ACP::Protocol::V2::InitializeParams.from_json(%({"protocolVersion":2,"capabilities":{}}))
    end

    login = ACP::Protocol::V2::AuthLoginParams.new("local-login")
    request = ACP::Protocol.build_request(2_i64, ACP::Protocol::V2::AgentMethod::AUTH_LOGIN, login)
    request["method"].should eq("auth/login")
    request["params"].should eq(JSON.parse(%({"methodId":"local-login"})))
  end

  it "decodes nested capabilities and preserves unknown authentication variants" do
    wire = JSON.parse(<<-JSON)
      {
        "protocolVersion": 2,
        "info": {"name":"agent","version":"2","_meta":{"example.test/info":1}},
        "capabilities": {
          "session": {
            "prompt": {"image":{},"embeddedContext":{}},
            "mcp": {"stdio":{},"http":{}},
            "systemPrompt": {"mode":{"override":{}}},
            "delete": {}
          }
        },
        "authMethods": [
          {"type":"agent","methodId":"desktop","name":"Desktop sign-in"},
          {"type":"terminal","methodId":"local","name":"Terminal sign-in","args":["--login"],"env":[{"name":"MODE","value":"base"},{"name":"MODE","value":"login"}]},
          {"type":"_future","methodId":"later","name":"Future sign-in","description":{"details":true},"payload":[1,2]}
        ]
      }
      JSON
    result = ACP::Protocol::V2::InitializeResult.from_json(wire.to_json)
    result.protocol_version.should eq(2_u16)
    result.info.meta.not_nil!["example.test/info"].should eq(1)
    session = result.capabilities.session.not_nil!
    session.prompt.not_nil!.image.should be_a(ACP::Protocol::V2::Capability)
    session.prompt.not_nil!.audio.should be_nil
    session.mcp.not_nil!.stdio.should be_a(ACP::Protocol::V2::Capability)
    session.system_prompt.not_nil!.override?.should be_true
    result.auth_methods[0].agent?.should be_true
    terminal = result.auth_methods[1].terminal_settings.not_nil!
    terminal.args.should eq(["--login"])
    terminal.env.map(&.value).should eq(["base", "login"])
    terminal.environment.should eq({"MODE" => "login"})
    result.auth_methods[2].terminal_settings.should be_nil
    JSON.parse(result.to_json).should eq(wire)
  end

  it "exposes structured unsupported-version errors without changing v1 defaults" do
    error = ACP::JsonRpcError.from_json_any(JSON.parse(%({"code":-32022,"message":"Unsupported protocol version","data":{"requested":1,"supported":[2]}})))
    error.unsupported_protocol_version?.should be_true
    data = ACP::Protocol::V2::UnsupportedProtocolVersionData.from_json(error.data.not_nil!.to_json)
    data.requested.should eq(1_u16)
    data.supported.should eq([2_u16])
    ACP::PROTOCOL_VERSION.should eq(1_u16)
    ACP.supports_protocol_version?(2_u16).should be_false
  end
end

describe "ACP v2 Preview session types" do
  it "creates a session with just a working directory" do
    params = ACP::Protocol::V2::SessionNewParams.new("/work")
    request = ACP::Protocol.build_request(1_i64, ACP::Protocol::V2::AgentMethod::SESSION_NEW, params)
    request["params"].should eq(JSON.parse(%({"cwd":"/work"})))
    result = ACP::Protocol::V2::SessionNewResult.from_json(%({"sessionId":"s","availableCommands":[{"type":"_next","name":"inspect","description":"Inspect","payload":1}]}))
    result.session_id.should eq("s")
    result.config_options.should be_empty
    result.available_commands.first["payload"].should eq(1)
  end

  it "encodes tagged MCP transports and retains future transport settings" do
    base_server = ACP::Protocol::McpServerStdio.new("local", "/work/mcp")
    server = ACP::Protocol::V2::McpServer.stdio(base_server)
    server.stdio_config.should eq(base_server)
    params = ACP::Protocol::V2::SessionNewParams.new("/work", mcp_servers: [server])
    JSON.parse(params.to_json)["mcpServers"][0]["type"].should eq("stdio")

    base_http = ACP::Protocol::McpServerHttp.new("service", "https://example.test/mcp")
    http = ACP::Protocol::V2::McpServer.http(base_http)
    http.http_config.should eq(base_http)

    wire = JSON.parse(%({"type":"_future","settings":{"endpoint":"custom"}}))
    unknown = ACP::Protocol::V2::McpServer.from_json(wire.to_json)
    unknown.http_config.should be_nil
    JSON.parse(unknown.to_json).should eq(wire)
  end

  it "resumes with the start cursor and preserves future replay cursors" do
    params = ACP::Protocol::V2::SessionResumeParams.new("s", "/work",
      replay_from: ACP::Protocol::V2::ReplayFrom.start,
      additional_directories: ["/docs"])
    JSON.parse(params.to_json).should eq(JSON.parse(%({"sessionId":"s","cwd":"/work","replayFrom":{"type":"start"},"additionalDirectories":["/docs"]})))

    wire = JSON.parse(%({"sessionId":"s","cwd":"/work","replayFrom":{"type":"_bookmark","at":{"segment":8}}}))
    decoded = ACP::Protocol::V2::SessionResumeParams.from_json(wire.to_json)
    decoded.replay_from.not_nil!.cursor_type.should eq("_bookmark")
    JSON.parse(decoded.to_json).should eq(wire)
  end

  it "sends idempotency keys and reads the inserted message ID from the acknowledgement" do
    blocks = [ACP::Protocol::TextContentBlock.new("Review tests")] of ACP::Protocol::ContentBlock
    params = ACP::Protocol::V2::SessionPromptParams.new("s", blocks, idempotency_key: "once")
    request = ACP::Protocol.build_request(1_i64, ACP::Protocol::V2::AgentMethod::SESSION_PROMPT, params)
    request["params"].should eq(JSON.parse(%({"sessionId":"s","prompt":[{"type":"text","text":"Review tests"}],"idempotencyKey":"once"})))
    result = ACP::Protocol::V2::SessionPromptResult.from_json(%({"messageId":"inserted-message"}))
    result.message_id.should eq("inserted-message")
    expect_raises(JSON::SerializableError) do
      ACP::Protocol::V2::SessionPromptResult.from_json(%({"stopReason":"end_turn"}))
    end
  end

  it "encodes select and boolean changes with the v2 configuration discriminators" do
    selection = ACP::Protocol::V2::SessionSetConfigOptionParams.new("s", "model", "fast")
    JSON.parse(selection.to_json).should eq(JSON.parse(%({"sessionId":"s","configId":"model","type":"id","value":"fast"})))
    toggle = ACP::Protocol::V2::SessionSetConfigOptionParams.new("s", "feature", false)
    JSON.parse(toggle.to_json).should eq(JSON.parse(%({"sessionId":"s","configId":"feature","type":"boolean","value":false})))

    future = JSON.parse(%({"sessionId":"s","configId":"example","type":"_next","value":2,"extra":"retained"}))
    parsed = ACP::Protocol::V2::SessionSetConfigOptionParams.from_json(future.to_json)
    JSON.parse(parsed.to_json).should eq(future)

    wire = JSON.parse(%({"configOptions":[{"configId":"example","name":"Example","type":"_future","data":{"value":"next"}}]}))
    result = ACP::Protocol::V2::SessionSetConfigOptionResult.from_json(wire.to_json)
    JSON.parse(result.to_json).should eq(wire)
  end
end

describe "ACP v2 Preview prompt lifecycle updates" do
  it "decodes idle failures and background work separately" do
    wire = JSON.parse(%({"sessionId":"s","update":{"sessionUpdate":"state_update","state":"idle","stopReason":"error","error":{"code":-32603,"message":"Failed"},"background":[{"type":"terminal","terminalId":"t"},{"type":"subagent","sessionId":"child"},{"type":"_future","payload":[1]}]}}))
    notification = ACP::Protocol::V2::SessionUpdateParams.from_json(wire.to_json)
    state = notification.update.typed.as(ACP::Protocol::V2::StateUpdate)
    state.idle?.should be_true
    state.stop_reason.should eq("error")
    state.error.not_nil!.code.should eq(-32603)
    state.background.not_nil!.map(&.entity_id).should eq(["t", "child", nil])
    state.background.not_nil!.last.json_unmapped["payload"].should eq(JSON.parse("[1]"))
    JSON.parse(notification.to_json).should eq(wire)

    ACP::Protocol::V2::StateUpdate.from_json(%({"state":"running"})).background.should be_nil
    ACP::Protocol::V2::StateUpdate.from_json(%({"state":"running","background":[]})).background.should eq([] of ACP::Protocol::V2::BackgroundWork)
  end

  it "preserves omitted and cleared message fields and applies metadata by key" do
    wire = JSON.parse(%({"sessionUpdate":"agent_message","messageId":"m","content":null,"_meta":{"drop":null,"replace":{"new":true}}}))
    update = ACP::Protocol::V2::SessionUpdate.from_json(wire.to_json).typed.as(ACP::Protocol::V2::MessageUpdate)
    update.content_present?.should be_true
    update.content.should be_nil
    update.meta_present?.should be_true
    previous = JSON.parse(%({"drop":1,"keep":2,"replace":{"old":true}})).as_h
    update.apply_metadata(previous).should eq(JSON.parse(%({"keep":2,"replace":{"new":true}})).as_h)
    previous.has_key?("drop").should be_true
    JSON.parse(update.to_json).should eq(wire)

    omitted = ACP::Protocol::V2::MessageUpdate.new("user_message", "m")
    omitted.content_present?.should be_false
    omitted.apply_metadata(previous).should eq(previous)
    omitted.meta = nil
    omitted.apply_metadata(previous).should be_nil
    JSON.parse(omitted.to_json)["_meta"].raw.should be_nil
  end

  it "decodes correlated chunks and explicit replay completion" do
    wire = %({"sessionUpdate":"user_message_chunk","messageId":"m","content":{"type":"text","text":"part"}})
    chunk = ACP::Protocol::V2::SessionUpdate.from_json(wire).typed.as(ACP::Protocol::V2::MessageChunkUpdate)
    typed = chunk.to_content_chunk.not_nil!
    typed.message_id.should eq("m")
    typed.text.should eq("part")
    replay = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"replay_complete"})).typed
    replay.should be_a(ACP::Protocol::V2::ReplayCompleteUpdate)
  end

  it "retains future update variants and their fields" do
    wire = JSON.parse(%({"sessionUpdate":"_future","data":{"field":"retained"}}))
    update = ACP::Protocol::V2::SessionUpdate.from_json(wire.to_json)
    update.typed.should be_nil
    JSON.parse(update.to_json).should eq(wire)
  end
end

describe "ACP v2 tool call and terminal updates" do
  it "preserves omitted and cleared tool-call fields and open content" do
    wire = JSON.parse(%({"sessionUpdate":"tool_call_update","toolCallId":"tool","status":"paused","rawInput":null,"content":[{"type":"terminal","terminalId":"t"},{"type":"_future","details":{"key":"value"}}],"capabilities":{"cancel":{}},"_meta":{"remove":null}}))
    update = ACP::Protocol::V2::SessionUpdate.from_json(wire.to_json).typed.as(ACP::Protocol::V2::ToolCallUpdate)
    update.tool_call_id.should eq("tool")
    update.status.should eq("paused")
    update.title_present?.should be_false
    update.raw_input_present?.should be_true
    update.raw_input.should be_nil
    update.content.not_nil!.first.terminal_id.should eq("t")
    update.content.not_nil!.last.json_unmapped["details"]["key"].should eq("value")
    update.capabilities.not_nil!.cancel.should be_a(ACP::Protocol::V2::Capability)
    update.apply_metadata({"remove" => JSON::Any.new(true), "keep" => JSON::Any.new(true)}).should eq({"keep" => JSON::Any.new(true)})
    JSON.parse(update.to_json).should eq(wire)
  end

  it "decodes structured file changes and patch text from a tool-call chunk" do
    wire = JSON.parse(%({"sessionUpdate":"tool_call_content_chunk","toolCallId":"tool","content":{"type":"diff","changes":[{"operation":"move","path":"/work/new","oldPath":"/work/old"},{"operation":"_future","details":[1]}],"patch":{"format":"git_patch","text":"example"}}}))
    update = ACP::Protocol::V2::SessionUpdate.from_json(wire.to_json).typed.as(ACP::Protocol::V2::ToolCallContentChunk)
    diff = update.content.diff.not_nil!
    diff.changes.first.old_path.should eq("/work/old")
    diff.changes.first.path.should eq("/work/new")
    diff.changes.last.json_unmapped["details"].should eq(JSON.parse("[1]"))
    diff.patch.not_nil!.format.should eq("git_patch")
    diff.patch.not_nil!.text.should eq("example")
    JSON.parse(update.to_json).should eq(wire)
  end

  it "decodes Agent-owned terminal snapshots and preserves signed exit codes" do
    wire = JSON.parse(%({"sessionUpdate":"terminal_update","terminalId":"t","output":{"data":"AP9B"},"size":{"cols":80,"rows":24},"exitStatus":{"exitCode":-9},"capabilities":null}))
    update = ACP::Protocol::V2::SessionUpdate.from_json(wire.to_json).typed.as(ACP::Protocol::V2::TerminalUpdate)
    update.terminal_id.should eq("t")
    update.output.not_nil!.bytes.should eq(Bytes[0, 255, 65])
    update.size.not_nil!.cols.should eq(80_u16)
    update.exit_status.not_nil!.exit_code.should eq(-9_i64)
    update.command_present?.should be_false
    update.capabilities_present?.should be_true
    update.capabilities.should be_nil
    JSON.parse(update.to_json).should eq(wire)
  end

  it "decodes streamed terminal bytes and separate output metadata" do
    wire = JSON.parse(%({"sessionUpdate":"terminal_output_chunk","terminalId":"t","data":"AAE=","_meta":{"sequence":2}}))
    update = ACP::Protocol::V2::SessionUpdate.from_json(wire.to_json).typed.as(ACP::Protocol::V2::TerminalOutputChunk)
    update.terminal_id.should eq("t")
    update.bytes.should eq(Bytes[0, 1])
    update.meta.not_nil!["sequence"].should eq(2)
    JSON.parse(update.to_json).should eq(wire)
  end
end

describe "ACP v2 session detail updates" do
  it "decodes a child state snapshot without adding a notification discriminator" do
    wire = JSON.parse(%({"sessionUpdate":"subagent_update","sessionId":"child","cwd":null,"additionalDirectories":[],"state":{"state":"idle","stopReason":"end_turn","background":[{"type":"tool_call","toolCallId":"tool"}]},"capabilities":{"cancel":{}},"_meta":{"old":null,"nested":{"new":true}}}))
    update = ACP::Protocol::V2::SessionUpdate.from_json(wire.to_json).typed.as(ACP::Protocol::V2::SubagentUpdate)
    update.session_id.should eq("child")
    update.state.not_nil!.stop_reason.should eq("end_turn")
    update.state.not_nil!.background.not_nil!.first.entity_id.should eq("tool")
    update.capabilities.not_nil!.cancel.should be_a(ACP::Protocol::V2::Capability)
    update.cwd_present?.should be_true
    update.cwd.should be_nil
    update.additional_directories.should eq([] of String)
    update.apply_metadata(JSON.parse(%({"old":1,"nested":{"old":true},"keep":2})).as_h).should eq(JSON.parse(%({"nested":{"new":true},"keep":2})).as_h)
    JSON.parse(update.to_json).should eq(wire)
  end

  it "preserves links and open content for inter-session messages and chunks" do
    wire = JSON.parse(%({"sessionUpdate":"session_message","messageId":"local","senderSessionId":"sender","recipientMessageId":null,"content":[{"type":"_future","value":1}]}))
    update = ACP::Protocol::V2::SessionUpdate.from_json(wire.to_json).typed.as(ACP::Protocol::V2::SessionMessageUpdate)
    update.message_id.should eq("local")
    update.sender_session_id.should eq("sender")
    update.sender_message_id_present?.should be_false
    update.recipient_message_id_present?.should be_true
    update.content.not_nil!.first["value"].should eq(1)
    JSON.parse(update.to_json).should eq(wire)

    chunk = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"session_message_chunk","messageId":"local","content":{"type":"text","text":"Hello"}})).typed.as(ACP::Protocol::V2::MessageChunkUpdate)
    chunk.to_content_chunk.not_nil!.message_id.should eq("local")
  end

  it "preserves session info, cost, and compaction clears through serialization" do
    info_wire = JSON.parse(%({"sessionUpdate":"session_info_update","updatedAt":null,"_meta":null}))
    info = ACP::Protocol::V2::SessionUpdate.from_json(info_wire.to_json).typed.as(ACP::Protocol::V2::SessionInfoUpdate)
    info.title_present?.should be_false
    info.updated_at_present?.should be_true
    info.apply_metadata({"keep" => JSON::Any.new(true)}).should be_nil
    JSON.parse(info.to_json).should eq(info_wire)

    usage_wire = JSON.parse(%({"sessionUpdate":"usage_update","used":10,"size":100,"cost":null}))
    usage = ACP::Protocol::V2::SessionUpdate.from_json(usage_wire.to_json).typed.as(ACP::Protocol::V2::UsageUpdate)
    usage.used.should eq(10)
    usage.cost_present?.should be_true
    usage.cost.should be_nil
    JSON.parse(usage.to_json).should eq(usage_wire)

    compaction_wire = JSON.parse(%({"sessionUpdate":"compaction_update","compactionId":"compact","status":null,"summary":[]}))
    compaction = ACP::Protocol::V2::SessionUpdate.from_json(compaction_wire.to_json).typed.as(ACP::Protocol::V2::CompactionUpdate)
    compaction.compaction_id.should eq("compact")
    compaction.status_present?.should be_true
    compaction.error_present?.should be_false
    JSON.parse(compaction.to_json).should eq(compaction_wire)
  end

  it "decodes compaction chunks, notices, and plan removal" do
    chunk = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"compaction_summary_chunk","compactionId":"compact","content":{"type":"text","text":"Summary"}})).typed.as(ACP::Protocol::CompactionSummaryChunkUpdate)
    chunk.compaction_id.should eq("compact")
    chunk.content_block.should be_a(ACP::Protocol::TextContentBlock)
    notice = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"notice","severity":"info","title":"Welcome"})).typed.as(ACP::Protocol::NoticeUpdate)
    notice.title.should eq("Welcome")
    removed = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"plan_removed","planId":"plan"})).typed.as(ACP::Protocol::PlanRemovedUpdate)
    removed.plan_id.should eq("plan")
  end

  it "decodes known plans and retains unknown replacements with their ID" do
    markdown = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"plan_update","plan":{"type":"markdown","planId":"plan","content":"# Plan"}})).typed.as(ACP::Protocol::V2::PlanUpdate)
    markdown.plan.typed.as(ACP::Protocol::PlanMarkdown).content.should eq("# Plan")
    wire = JSON.parse(%({"sessionUpdate":"plan_update","plan":{"type":"_future","planId":"plan","ordered":true}}))
    update = ACP::Protocol::V2::SessionUpdate.from_json(wire.to_json).typed.as(ACP::Protocol::V2::PlanUpdate)
    update.plan.plan_id.should eq("plan")
    update.plan.typed.should be_nil
    JSON.parse(update.to_json).should eq(wire)
  end
end

describe "ACP v2 configuration and command updates" do
  it "decodes grouped and flat select options, boolean values, and custom variants" do
    wire = JSON.parse(<<-JSON)
      {"sessionUpdate":"config_option_update","configOptions":[
        {"type":"select","configId":"model","name":"Model","category":"model","currentValue":"a","options":[{"groupId":"provider","name":"Provider","options":[{"value":"a","name":"Model A"},false]}]},
        {"type":"select","configId":"mode","name":"Mode","currentValue":"chat","options":[{"value":"chat","name":"Chat"}]},
        {"type":"boolean","configId":"enabled","name":"Enabled","currentValue":false},
        {"type":"_custom","configId":"custom","name":"Custom","currentValue":{"flag":true}},
        {"type":"boolean","id":"v1-only","name":"Invalid"}
      ]}
      JSON
    update = ACP::Protocol::V2::SessionUpdate.from_json(wire.to_json).typed.as(ACP::Protocol::V2::ConfigOptionUpdate)
    grouped, flat, toggle, custom = update.typed_config_options
    grouped.config_id.should eq("model")
    grouped.category.should eq("model")
    grouped.selected_value.should eq("a")
    group = grouped.select_options.as(Array(ACP::Protocol::V2::ConfigOptionGroup)).first
    group.group_id.should eq("provider")
    group.values.map(&.value).should eq(["a"])
    flat.select_options.as(Array(ACP::Protocol::ConfigOptionValue)).first.name.should eq("Chat")
    toggle.boolean_value.should be_false
    custom.type.should eq("_custom")
    custom.json_unmapped["currentValue"]["flag"].should eq(true)
    update.typed_config_options.size.should eq(4)
    JSON.parse(update.to_json).should eq(wire)
  end

  it "distinguishes slash commands and their input from future command variants" do
    wire = JSON.parse(<<-JSON)
      {"sessionUpdate":"available_commands_update","availableCommands":[
        {"type":"command","name":"plan","description":"Plan work","input":{"type":"text","hint":"topic"}},
        {"type":"command","name":"edit","description":"Edit work","input":{"type":"_structured","schema":{"flag":true}}},
        {"type":"_future","name":"future","description":"Future command","payload":[1]},
        {"name":"missing-type","description":"Invalid"}
      ]}
      JSON
    update = ACP::Protocol::V2::SessionUpdate.from_json(wire.to_json).typed.as(ACP::Protocol::V2::AvailableCommandsUpdate)
    plan, edit, future = update.typed_available_commands
    plan.slash_command?.should be_true
    plan.input.not_nil!.text_hint.should eq("topic")
    edit.input.not_nil!.type.should eq("_structured")
    edit.input.not_nil!.json_unmapped["schema"]["flag"].should eq(true)
    future.slash_command?.should be_false
    future.json_unmapped["payload"].should eq(JSON.parse("[1]"))
    update.typed_available_commands.size.should eq(3)
    JSON.parse(update.to_json).should eq(wire)
  end

  it "uses the same typed projections in session setup and option change results" do
    state = %({"configOptions":[{"type":"boolean","configId":"flag","name":"Flag","currentValue":true}],"availableCommands":[{"type":"command","name":"plan","description":"Plan work"}]})
    new_session = ACP::Protocol::V2::SessionNewResult.from_json(state.sub("{", %({"sessionId":"session",)))
    resumed = ACP::Protocol::V2::SessionResumeResult.from_json(state)
    changed = ACP::Protocol::V2::SessionSetConfigOptionResult.from_json(state)
    new_session.typed_config_options.first.config_id.should eq("flag")
    new_session.typed_available_commands.first.name.should eq("plan")
    resumed.typed_available_commands.first.input.should be_nil
    changed.typed_config_options.first.boolean_value.should be_true
  end
end

describe "ACP authentication descriptors" do
  it "decodes agent and terminal methods and keeps unknown wire entries accessible" do
    response = ACP::Protocol::InitializeResult.from_json(%({
      "protocolVersion": 1,
      "authMethods": [
        {"id": "agent", "name": "Agent sign-in"},
        {"type": "agent", "id": "agent-explicit", "name": "Explicit sign-in"},
        {"type": "terminal", "id": "terminal", "name": "Terminal sign-in",
         "args": ["--login"], "env": {"ACP_LOGIN_MODE": "terminal"}},
        {"type": "terminal", "id": "default-terminal", "name": "Default terminal", "args": null},
        {"type": "next", "id": "next", "name": "Future flow"}
      ]
    }))
    response.auth_methods.not_nil!.size.should eq(5)
    methods = response.typed_auth_methods
    methods.map(&.id).should eq(["agent", "agent-explicit", "terminal", "default-terminal"])
    methods[0].as(ACP::Protocol::AuthMethod).method_type.should be_nil
    methods[1].as(ACP::Protocol::AuthMethod).method_type.should eq("agent")
    terminal = methods[2].as(ACP::Protocol::TerminalAuthMethod)
    terminal.args.should eq(["--login"])
    terminal.env.should eq({"ACP_LOGIN_MODE" => "terminal"})
    JSON.parse(terminal.to_json)["type"].should eq("terminal")
    methods[3].as(ACP::Protocol::TerminalAuthMethod).args.should be_empty
    methods[3].as(ACP::Protocol::TerminalAuthMethod).env.should be_empty
  end
end

describe "ACP MCP transport metadata" do
  it "round-trips server, environment and header metadata for every transport" do
    wire = [
      %({"name":"local","command":"mcp","args":[],"env":[{"name":"MODE","value":"test","_meta":{"example.test/env":1}}],"_meta":{"example.test/server":true}}),
      %({"type":"http","name":"http","url":"https://example.test/mcp","headers":[{"name":"Accept","value":"application/json","_meta":{"example.test/header":1}}],"_meta":{"example.test/server":true}}),
      %({"type":"sse","name":"sse","url":"https://example.test/sse","headers":[{"name":"Accept","value":"text/event-stream","_meta":{"example.test/header":2}}],"_meta":{"example.test/server":true}}),
    ].map { |json| JSON.parse(json) }
    servers = wire.map { |value| ACP::Protocol::McpServerParser.from_json_any(value) }
    servers.each do |server|
      server.meta.not_nil!["example.test/server"].should eq(true)
    end
    params = ACP::Protocol::SessionNewParams.new("/work", servers)
    JSON.parse(params.to_json)["mcpServers"].as_a.should eq(wire)
  end
end

describe "ACP identified plan types" do
  it "round-trips checklist plans with independent plan and update metadata" do
    wire = JSON.parse(<<-JSON)
      {
        "sessionUpdate": "plan_update",
        "plan": {
          "type": "items",
          "planId": "checklist",
          "entries": [{"content": "Check formatting", "priority": "high", "status": "completed"}],
          "_meta": {"example.test/plan": true}
        },
        "_meta": {"example.test/update": 1}
      }
      JSON
    update = ACP::Protocol::SessionUpdate.from_json(wire.to_json).as(ACP::Protocol::IdentifiedPlanUpdate)
    plan = update.plan.as(ACP::Protocol::PlanItems)
    plan.plan_id.should eq("checklist")
    plan.entries.map(&.content).should eq(["Check formatting"])
    JSON.parse(update.to_json).should eq(wire)
  end

  it "serializes Markdown replacements and removal using the schema discriminators" do
    replacement = ACP::Protocol::IdentifiedPlanUpdate.new(
      ACP::Protocol::PlanMarkdown.new("shared-id", "# Revised", path: "/work/PLAN.md")
    )
    wire = JSON.parse(replacement.to_json)
    wire.should eq(JSON.parse(%({"sessionUpdate":"plan_update","plan":{"type":"markdown","planId":"shared-id","content":"# Revised","path":"/work/PLAN.md"}})))
    update = ACP::Protocol::SessionUpdate.from_json(wire.to_json).as(ACP::Protocol::IdentifiedPlanUpdate)
    update.plan.as(ACP::Protocol::PlanMarkdown).path.should eq("/work/PLAN.md")
    removal = ACP::Protocol::PlanRemovedUpdate.new("shared-id")
    JSON.parse(removal.to_json).should eq(JSON.parse(%({"sessionUpdate":"plan_removed","planId":"shared-id"})))
  end
end

describe "ACP subagent update types" do
  it "preserves omitted, cleared and empty child fields independently" do
    wire = JSON.parse(%({
      "sessionId": "parent",
      "update": {
        "sessionUpdate": "subagent_update",
        "sessionId": "child",
        "title": null,
        "capabilities": {"cancel": {}},
        "cwd": "/work/child",
        "additionalDirectories": [],
        "_meta": null
      }
    }))
    params = ACP::Protocol::SessionUpdateParams.from_json(wire.to_json)
    params.session_id.should eq("parent")
    update = params.update.as(ACP::Protocol::SubagentUpdate)
    update.session_id.should eq("child")
    update.title_present?.should be_true
    update.title.should be_nil
    update.description_present?.should be_false
    update.capabilities.not_nil!.cancel.should be_a(ACP::Protocol::SessionCancelCapabilities)
    update.cwd.should eq("/work/child")
    update.additional_directories.should eq([] of String)
    JSON.parse(params.to_json).should eq(wire)
  end

  it "retains the payload of an unrecognized state or stop reason" do
    future = JSON.parse(%({"state":"_waiting","stopReason":"_deferred","hint":{"priority":2}}))
    snapshot = ACP::Protocol::SubagentState.from_json(future.to_json)
    snapshot.state.should eq("_waiting")
    snapshot.stop_reason.should eq("_deferred")
    JSON.parse(snapshot.to_json).should eq(future)

    failed = ACP::Protocol::SubagentState.from_json(%({"state":"idle","stopReason":"error","error":{"code":-32000,"message":"Authentication required"}}))
    failed.error.not_nil!["code"].as_i.should eq(-32000)
  end

  it "round-trips message views, content clears and typed chunks" do
    update = ACP::Protocol::SessionMessageUpdate.new("incoming")
    update.sender_session_id = "parent"
    update.recipient_session_id = "child"
    update.sender_message_id = "outgoing"
    update.recipient_message_id = nil
    update.content = [ACP::Protocol::TextContentBlock.new("Review tests")] of ACP::Protocol::ContentBlock
    wire = JSON.parse(%({
      "sessionUpdate": "session_message",
      "messageId": "incoming",
      "senderSessionId": "parent",
      "recipientSessionId": "child",
      "senderMessageId": "outgoing",
      "recipientMessageId": null,
      "content": [{"type":"text","text":"Review tests"}]
    }))
    JSON.parse(update.to_json).should eq(wire)
    decoded = ACP::Protocol::SessionUpdate.from_json(wire.to_json).as(ACP::Protocol::SessionMessageUpdate)
    decoded.recipient_message_id_present?.should be_true
    decoded.recipient_message_id.should be_nil
    decoded.content.not_nil!.first.as(ACP::Protocol::TextContentBlock).text.should eq("Review tests")
    decoded.content = nil
    JSON.parse(decoded.to_json)["content"].raw.should be_nil

    chunk_wire = JSON.parse(%({"sessionUpdate":"session_message_chunk","messageId":"incoming","content":{"type":"text","text":" now"},"_meta":{"example.test/chunk":true}}))
    chunk = ACP::Protocol::SessionUpdate.from_json(chunk_wire.to_json).as(ACP::Protocol::SessionMessageChunkUpdate)
    chunk.message_id.should eq("incoming")
    chunk.content.as(ACP::Protocol::TextContentBlock).text.should eq(" now")
    JSON.parse(chunk.to_json).should eq(chunk_wire)
  end

  it "decodes a typed session reference inside tool call content" do
    update = ACP::Protocol::SessionUpdate.from_json(%({
      "sessionUpdate": "tool_call", "toolCallId": "call", "title": "Review tests",
      "content": [{"type": "session", "sessionId": "child", "_meta": {"example.test/ref": true}}]
    })).as(ACP::Protocol::ToolCallUpdate)
    reference = update.typed_content.not_nil!.first.as(ACP::Protocol::ToolCallSessionReference)
    reference.session_id.should eq("child")
    JSON.parse(reference.to_json).should eq(update.content.not_nil!.first)
  end
end

# A transport whose `send` always fails. Used to force dispatch errors
# (the dispatcher's reply attempts raise), so we can exercise the
# consecutive-error protection. `receive` keeps delivering injected messages.
class FailingSendTransport < TestTransport
  def send(message : Hash(String, JSON::Any)) : Nil
    raise IO::Error.new("simulated write failure")
  end
end

# A transport whose first `fail_first` sends raise, then all later sends
# succeed. Used to verify the dispatcher's consecutive-error counter resets
# after a success so transient errors do not tear down the connection.
class CountingFailTransport < TestTransport
  def initialize(@fail_first : Int32 = 3)
    super()
    @send_count = 0
  end

  def send(message : Hash(String, JSON::Any)) : Nil
    @send_count += 1
    raise IO::Error.new("simulated transient write failure") if @send_count <= @fail_first
    super
  end
end

# Like build_init_response, but advertises sessionCapabilities.close so the
# agent is treated as supporting session/close.
def build_init_response_with_close(id : Int64, protocol_version : UInt16 = 1_u16) : String
  <<-JSON
    {
      "jsonrpc": "2.0",
      "id": #{id},
      "result": {
        "protocolVersion": #{protocol_version},
        "agentCapabilities": {
          "loadSession": true,
          "sessionCapabilities": {
            "close": {}
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

  it "drops oversized incoming lines and re-syncs at the next message boundary" do
    reader_r, reader_w = IO.pipe
    writer_io = IO::Memory.new

    transport = ACP::StdioTransport.new(reader_r, writer_io, max_line_bytes: 256)

    # First line exceeds the limit; second line is well-formed.
    huge = "{\"junk\":\"" + ("x" * 1024) + "\"}"
    reader_w.puts huge
    reader_w.puts %({"id": 42, "method": "valid"})
    reader_w.flush

    msg = transport.receive(500.milliseconds)
    msg.should_not be_nil
    msg.as(JSON::Any)["id"].as_i.should eq(42)

    reader_w.close
    transport.close
  end

  it "redacts sensitive params from outgoing DEBUG-level frame logs" do
    reader_io = IO::Memory.new
    writer_io = IO::Memory.new

    captured = IO::Memory.new
    backend = ::Log::IOBackend.new(captured, dispatcher: ::Log::DispatchMode::Sync)
    backend.formatter = ::Log::Formatter.new do |entry, io|
      io << entry.message
    end
    ::Log.setup do |c|
      c.bind "acp.transport", :debug, backend
    end

    transport = ACP::StdioTransport.new(reader_io, writer_io)

    msg = Hash(String, JSON::Any).new
    msg["jsonrpc"] = JSON::Any.new("2.0")
    creds = Hash(String, JSON::Any).new
    creds["token"] = JSON::Any.new("super-secret-bearer-token")
    msg["params"] = JSON::Any.new(creds)
    {"authenticate", "logout", "auth/login", "auth/logout", "auth/status"}.each do |method|
      msg["method"] = JSON::Any.new(method)
      transport.send(msg)
    end

    log_output = captured.to_s
    log_output.should_not contain("super-secret-bearer-token")
    log_output.scan("[REDACTED]").size.should eq(5)
    log_output.should contain("authenticate")

    # Restore default logging so subsequent tests aren't affected.
    ::Log.setup(:none)
    transport.close
  end

  it "redacts provider requests and correlated replies from frame logs" do
    reader, feed = IO.pipe
    writer = IO::Memory.new
    captured = IO::Memory.new
    backend = ::Log::IOBackend.new(captured, dispatcher: ::Log::DispatchMode::Sync)
    backend.formatter = ::Log::Formatter.new { |entry, io| io << entry.message << '\n' }
    ::Log.setup { |config| config.bind "acp.transport", :debug, backend }
    transport = ACP::StdioTransport.new(reader, writer)
    secret = "fixture-provider-credential"
    params = ACP::Protocol::SetProviderParams.new("model", "openai", "https://llm.example.test",
      headers: {"Authorization" => secret})
    transport.send(ACP::Protocol.build_request(4_i64, "providers/set", params))
    transport.send(ACP::Protocol.build_request(5_i64, "providers/list", ACP::Protocol::ListProvidersParams.new))
    feed.puts %({"jsonrpc":"2.0","id":5,"result":{"providers":[],"_meta":{"echo":"#{secret}"}}})
    feed.puts %("#{secret}")
    feed.puts %({"jsonrpc":"2.0","id" "#{secret}"})
    feed.puts %({"jsonrpc":"2.0","id":14,"result":{"unrelated":"ordinary-result"}})
    feed.puts %({"jsonrpc":"1.0","id":4,"error":{"code":-32602,"message":"Unusable #{secret}"}})
    feed.puts %({"jsonrpc":"2.0","id":"4","error":{"code":-32602,"message":"Rejected #{secret}","data":{"echo":"#{secret}"}}})
    feed.puts %({"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"Repeated #{secret}"}})
    feed.puts %({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Unknown ID #{secret}"}})
    transport.receive(2.seconds).not_nil!["result"]["_meta"]["echo"].should eq(secret)
    transport.receive(2.seconds).not_nil!.as_s.should eq(secret)
    transport.receive(2.seconds).not_nil!["id"].should eq(14)
    transport.receive(2.seconds).not_nil!["jsonrpc"].should eq("1.0")
    transport.receive(2.seconds).not_nil!["error"]["data"]["echo"].should eq(secret)
    transport.receive(2.seconds).not_nil!["id"].should eq(4)
    transport.receive(2.seconds).not_nil!["error"]["code"].should eq(-32700)

    writer.to_s.should contain(secret)
    params.inspect.should_not contain(secret)
    params.to_s.should_not contain(secret)
    captured.to_s.should contain("providers/set")
    captured.to_s.should contain("ordinary-result")
    captured.to_s.should contain("Failed to parse incoming JSON")
    captured.to_s.scan("[REDACTED response]").size.should eq(5)
    captured.to_s.should_not contain(secret)

    (100_i64..356_i64).each do |id|
      transport.send(ACP::Protocol.build_request(id, "providers/list", ACP::Protocol::ListProvidersParams.new))
    end
    feed.puts %({"jsonrpc":"2.0","id":500,"result":{"unrelated":"overflow-result"}})
    transport.receive(2.seconds).not_nil!["result"]["unrelated"].should eq("overflow-result")
    captured.to_s.scan("[REDACTED response]").size.should eq(6)
    captured.to_s.should_not contain("overflow-result")
  ensure
    ::Log.setup(:none)
    transport.try(&.close)
    feed.try(&.close)
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

  it "delivers a line whose length is exactly max_line_bytes (not dropped as oversize)" do
    reader_r, reader_w = IO.pipe
    writer_io = IO::Memory.new

    # A valid JSON line; cap the limit at exactly its byte length. The full
    # logical line is `line.bytesize + 1` bytes including the trailing newline,
    # so it must still be delivered (the boundary `==` is NOT oversize).
    line = %({"id":1,"p":"#{"x" * 40}"})
    transport = ACP::StdioTransport.new(reader_r, writer_io, max_line_bytes: line.bytesize)

    reader_w.puts line
    reader_w.flush

    msg = transport.receive(500.milliseconds)
    msg.should_not be_nil
    msg.as(JSON::Any)["id"].as_i.should eq(1)

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

    it "accepts a negotiated protocol version the client still supports" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          id = msg["id"].as_i64
          # Agent selects MIN_PROTOCOL_VERSION (a version we still support);
          # the handshake is a negotiation, not an equality check.
          transport.inject_raw(build_init_response(id, protocol_version: ACP::MIN_PROTOCOL_VERSION))
        end
      end

      result = client.initialize_connection
      result.protocol_version.should eq(ACP::MIN_PROTOCOL_VERSION)
      client.negotiated_protocol_version.should eq(ACP::MIN_PROTOCOL_VERSION)
      client.state.should eq(ACP::ClientState::Initialized)

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

  describe "#session_resume" do
    it "sends session/resume request, sets active session, and surfaces returned mode state" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64, session_capabilities: %({"resume":{}})))
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
              "currentModeId": "chat",
              "availableModes": [
                {"id": "chat", "name": "Chat"},
                {"id": "code", "name": "Code"}
              ]
            }
          }
          }
          JSON
        )
      end

      result = client.session_resume("sess-resumed", "/tmp")
      result.modes.try(&.current_mode_id).should eq("chat")

      sent = transport.sent_messages.last
      sent["method"].as_s.should eq("session/resume")
      sent["params"].as_h["sessionId"].as_s.should eq("sess-resumed")
      sent["params"].as_h["cwd"].as_s.should eq("/tmp")

      client.session_id.should eq("sess-resumed")
      client.state.should eq(ACP::ClientState::SessionActive)

      transport.close
    end
  end

  describe "#session_load" do
    it "sends session/load, adopts the given id, and surfaces returned state" do
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
              "availableModes": [{"id": "code", "name": "Code"}]
            },
            "configOptions": [
              {"id": "model", "name": "Model", "type": "select", "currentValue": "fast"}
            ]
          }
          }
          JSON
        )
      end

      result = client.session_load("sess-loaded", "/work", [] of JSON::Any)
      result.modes.try(&.current_mode_id).should eq("code")
      result.config_options.try(&.size).should eq(1)

      sent = transport.sent_messages.last
      sent["method"].as_s.should eq("session/load")
      sent["params"].as_h["sessionId"].as_s.should eq("sess-loaded")
      sent["params"].as_h["cwd"].as_s.should eq("/work")
      sent["params"].as_h["mcpServers"].as_a.should be_empty

      # session/load carries no sessionId in its result; the client keeps
      # the id the caller supplied.
      client.session_id.should eq("sess-loaded")
      client.session_modes.try(&.current_mode_id).should eq("code")
      client.session_config_options.try(&.size).should eq(1)
      client.state.should eq(ACP::ClientState::SessionActive)

      transport.close
    end

    it "raises InvalidStateError before the handshake" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      expect_raises(ACP::InvalidStateError) do
        client.session_load("sess-x", "/work")
      end

      transport.close
    end
  end

  describe "#session_set_config_option" do
    it "sends session/set_config_option and caches the returned option set" do
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
        transport.inject_raw(%({"jsonrpc":"2.0","id":#{sent["id"].as_i64},"result":{"sessionId":"sess-cfg","configOptions":[{"id":"model","name":"Model","type":"select","currentValue":"fast","options":[{"value":"fast","name":"Fast"},{"value":"smart","name":"Smart"}]}]}}))
      end
      client.session_new("/tmp")

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(<<-JSON
          {
          "jsonrpc": "2.0",
          "id": #{sent["id"].as_i64},
          "result": {
            "configOptions": [
              {
                "id": "model",
                "name": "Model",
                "category": "model",
                "type": "select",
                "currentValue": "smart",
                "options": [
                  {"value": "fast", "name": "Fast"},
                  {"value": "smart", "name": "Smart"}
                ]
              }
            ]
          }
          }
          JSON
        )
      end

      result = client.session_set_config_option("model", "smart")

      sent = transport.sent_messages.last
      sent["method"].as_s.should eq("session/set_config_option")
      sent["params"].as_h["sessionId"].as_s.should eq("sess-cfg")
      sent["params"].as_h["configId"].as_s.should eq("model")
      sent["params"].as_h["value"].as_s.should eq("smart")

      result.config_options.size.should eq(1)
      result.config_options[0].current_value.should eq("smart")
      # The client caches the full option set returned by the agent.
      client.session_config_options.try(&.[0].current_value).should eq("smart")

      transport.close
    end

    it "raises NoActiveSessionError without a session" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      expect_raises(ACP::NoActiveSessionError) do
        client.session_set_config_option("model", "smart")
      end

      transport.close
    end
  end

  describe "#forget_session" do
    it "drops cached state for the active session and steps back to Initialized" do
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
            "sessionId": "sess-forget",
            "modes": {"currentModeId": "chat", "availableModes": [{"id": "chat", "name": "Chat"}]}
          }
          }
          JSON
        )
      end
      client.session_new("/tmp")
      client.session_active?.should be_true

      client.forget_session("sess-forget").should be_true

      client.session_id.should be_nil
      client.session_modes.should be_nil
      client.session_config_options.should be_nil
      client.state.should eq(ACP::ClientState::Initialized)
      client.session_active?.should be_false

      # With no active session, an id-less call must raise rather than
      # silently target the dead session.
      expect_raises(ACP::NoActiveSessionError) { client.session_cancel }

      transport.close
    end

    it "is a no-op for a session that is not the active one" do
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
        transport.inject_raw(%({"jsonrpc":"2.0","id":#{sent["id"].as_i64},"result":{"sessionId":"sess-a"}}))
      end
      client.session_new("/tmp")

      client.forget_session("sess-other").should be_false
      client.session_id.should eq("sess-a")
      client.state.should eq(ACP::ClientState::SessionActive)

      transport.close
    end

    it "never resurrects a client the caller already closed" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)
      client.close

      client.forget_session("sess-anything").should be_false
      client.state.should eq(ACP::ClientState::Closed)

      transport.close
    end
  end

  describe "#session_close" do
    it "sends session/close, resets active session, and returns to Initialized state" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64, session_capabilities: %({"close":{}})))
        end
      end
      client.initialize_connection

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64))
      end
      client.session_new("/tmp")
      client.state.should eq(ACP::ClientState::SessionActive)

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(<<-JSON
          {"jsonrpc": "2.0", "id": #{sent["id"].as_i64}, "result": {}}
          JSON
        )
      end

      _result = client.session_close
      sent = transport.sent_messages.last
      sent["method"].as_s.should eq("session/close")
      sent["params"].as_h["sessionId"].as_s.should eq("sess-001")

      client.session_id.should be_nil
      client.state.should eq(ACP::ClientState::Initialized)

      transport.close
    end

    it "raises NoActiveSessionError when no session is active and no id is given" do
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
        client.session_close
      end

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

  describe "#session_list" do
    it "sends session/list request and returns result" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64, session_capabilities: %({"list":{}})))
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
            "sessions": [
              {"sessionId": "sess-001", "cwd": "/home/user/project1", "title": "First Session"},
              {"sessionId": "sess-002", "cwd": "/home/user/project2"}
            ],
            "nextCursor": "cursor_page2"
          }
          }
          JSON
        )
      end

      result = client.session_list
      result.sessions.size.should eq(2)
      result.sessions[0].session_id.should eq("sess-001")
      result.sessions[0].cwd.should eq("/home/user/project1")
      result.sessions[0].title.should eq("First Session")
      result.sessions[1].session_id.should eq("sess-002")
      result.sessions[1].title.should be_nil
      result.next_cursor.should eq("cursor_page2")
      result.has_more?.should be_true

      transport.close
    end

    it "sends cwd and cursor parameters" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64, session_capabilities: %({"list":{}})))
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
            "sessions": []
          }
          }
          JSON
        )
      end

      result = client.session_list(cwd: "/my/project", cursor: "page2")
      result.sessions.should be_empty
      result.has_more?.should be_false

      # Verify params were sent correctly
      list_req = transport.sent_messages.find { |msg| msg["method"]?.try(&.as_s?) == "session/list" }
      list_req.should_not be_nil
      params = list_req.as(JSON::Any)["params"]
      params["cwd"].as_s.should eq("/my/project")
      params["cursor"].as_s.should eq("page2")

      transport.close
    end

    it "returns empty list when no sessions exist" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64, session_capabilities: %({"list":{}})))
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
            "sessions": []
          }
          }
          JSON
        )
      end

      result = client.session_list
      result.sessions.should be_empty
      result.next_cursor.should be_nil
      result.has_more?.should be_false

      transport.close
    end

    it "raises InvalidStateError if not initialized" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      expect_raises(ACP::InvalidStateError) do
        client.session_list
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

  describe "dispatcher error protection" do
    it "tears down the connection after too many consecutive dispatch errors" do
      transport = FailingSendTransport.new
      client = ACP::Client.new(transport)

      client.closed?.should be_false

      # Each agent request triggers a reply via the transport, which fails;
      # that failure counts as a dispatch error. After the threshold the
      # dispatcher closes the client instead of spinning forever.
      ACP::Client::MAX_CONSECUTIVE_DISPATCH_ERRORS.times do |i|
        transport.inject_raw(<<-JSON
          {"jsonrpc": "2.0", "id": #{i + 1}, "method": "agent/does_not_exist", "params": {}}
          JSON
        )
      end

      # Wait for the dispatcher to process the messages and react.
      deadline = Time.instant + 2.seconds
      while !client.closed? && Time.instant < deadline
        sleep 5.milliseconds
      end

      client.closed?.should be_true
      client.state.should eq(ACP::ClientState::Closed)
      transport.closed?.should be_true
    end

    it "fires on_disconnect when tearing down after protocol corruption" do
      transport = FailingSendTransport.new
      client = ACP::Client.new(transport)

      # A corruption teardown is an UNEXPECTED loss, so on_disconnect must fire
      # (unlike an intentional close()).
      disconnected = Channel(Nil).new(1)
      client.on_disconnect = -> { disconnected.send(nil) rescue nil; nil }

      ACP::Client::MAX_CONSECUTIVE_DISPATCH_ERRORS.times do |i|
        transport.inject_raw(%({"jsonrpc":"2.0","id":#{i + 1},"method":"agent/does_not_exist","params":{}}))
      end

      select
      when disconnected.receive
        # fired as expected
      when timeout(2.seconds)
        fail "on_disconnect was not called on protocol-corruption teardown"
      end
    end

    it "resets the error counter after a successful dispatch" do
      # A transport that fails the first few sends, then succeeds, so the
      # counter never reaches the threshold and the client stays open.
      transport = CountingFailTransport.new(fail_first: 3)
      client = ACP::Client.new(transport)

      # Send well over the threshold worth of requests, but successes are
      # interleaved so consecutive failures never reach the limit.
      total = ACP::Client::MAX_CONSECUTIVE_DISPATCH_ERRORS * 2
      total.times do |i|
        transport.inject_raw(<<-JSON
          {"jsonrpc": "2.0", "id": #{i + 1}, "method": "agent/does_not_exist", "params": {}}
          JSON
        )
        sleep 1.millisecond
      end

      sleep 30.milliseconds
      client.closed?.should be_false

      transport.close
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
      response.as(JSON::Any)["result"]["outcome"].should eq(JSON.parse(%({"outcome":"selected","optionId":"allow_once"})))

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
      # The ACP spec requires the outcome to be a nested RequestPermissionOutcome
      # object: {"outcome": {"outcome": "cancelled"}}.
      response.as(JSON::Any)["result"]["outcome"]["outcome"].as_s.should eq("cancelled")

      transport.close
    end

    it "responds with error when handler raises error" do
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
      error = response.as(JSON::Any)["error"]
      error["code"].as_i.should eq(-32603)
      error["message"].as_s.should contain("Permission handler error")

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

    it "does NOT call on_disconnect on an intentional close()" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      disconnected = false
      client.on_disconnect = -> do
        disconnected = true
        nil
      end

      # An explicit close is not a lost connection; the callback must stay
      # silent so reconnect/error logic isn't triggered on a clean shutdown.
      client.close

      sleep 50.milliseconds

      disconnected.should be_false
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
def setup_client_with_session(*, session_capabilities : String? = nil)
  transport = TestTransport.new
  client = ACP::Client.new(transport)

  # Initialize
  spawn do
    sleep 10.milliseconds
    if msg = transport.last_sent
      transport.inject_raw(build_init_response(msg["id"].as_i64, session_capabilities: session_capabilities))
    end
  end
  client.initialize_connection

  {transport, client}
end

# Same as setup_client_with_session, but the agent advertises the
# session/close capability.
def setup_client_with_session_and_close
  transport = TestTransport.new
  client = ACP::Client.new(transport)

  spawn do
    sleep 10.milliseconds
    if msg = transport.last_sent
      transport.inject_raw(build_init_response_with_close(msg["id"].as_i64))
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

  describe ".list" do
    it "lists sessions through the client" do
      transport, client = setup_client_with_session(session_capabilities: %({"list":{}}))

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(<<-JSON
          {
          "jsonrpc": "2.0",
          "id": #{sent["id"].as_i64},
          "result": {
            "sessions": [
              {"sessionId": "sess-list-1", "cwd": "/project/a", "title": "Session A"},
              {"sessionId": "sess-list-2", "cwd": "/project/b"}
            ],
            "nextCursor": "next_page"
          }
          }
          JSON
        )
      end

      result = ACP::Session.list(client)
      result.sessions.size.should eq(2)
      result.sessions[0].session_id.should eq("sess-list-1")
      result.sessions[0].cwd.should eq("/project/a")
      result.sessions[0].title.should eq("Session A")
      result.sessions[1].session_id.should eq("sess-list-2")
      result.sessions[1].title.should be_nil
      result.next_cursor.should eq("next_page")
      result.has_more?.should be_true

      transport.close
    end

    it "passes cwd and cursor to client.session_list" do
      transport, client = setup_client_with_session(session_capabilities: %({"list":{}}))

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        sent["method"].as_s.should eq("session/list")
        params = sent["params"]
        params["cwd"].as_s.should eq("/filtered/path")
        params["cursor"].as_s.should eq("cursor_abc")
        transport.inject_raw(<<-JSON
          {
          "jsonrpc": "2.0",
          "id": #{sent["id"].as_i64},
          "result": {
            "sessions": []
          }
          }
          JSON
        )
      end

      result = ACP::Session.list(client, cwd: "/filtered/path", cursor: "cursor_abc")
      result.sessions.should be_empty
      result.has_more?.should be_false

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

    it "does NOT send session/close when the agent lacks the capability" do
      transport, client = setup_client_with_session

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64))
      end

      session = ACP::Session.create(client, cwd: "/tmp")
      session.agent_supports_close?.should be_false
      transport.clear_sent

      session.close
      session.closed?.should be_true
      # No session/close request should have been sent.
      transport.sent_messages.any? { |m| m["method"]?.try(&.as_s?) == "session/close" }.should be_false

      transport.close
    end

    it "sends session/close when the agent advertises the capability" do
      transport, client = setup_client_with_session_and_close

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64, "sess-closable"))
      end

      session = ACP::Session.create(client, cwd: "/tmp")
      session.agent_supports_close?.should be_true
      transport.clear_sent

      # Respond to the session/close request the close call will send.
      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(<<-JSON
          {"jsonrpc": "2.0", "id": #{sent["id"].as_i64}, "result": {}}
          JSON
        )
      end

      session.close
      session.closed?.should be_true

      close_req = transport.sent_messages.find { |m| m["method"]?.try(&.as_s?) == "session/close" }
      close_req.should_not be_nil
      close_req.as(JSON::Any)["params"]["sessionId"].as_s.should eq("sess-closable")

      transport.close
    end

    it "honors notify_agent: false to skip the remote close even when supported" do
      transport, client = setup_client_with_session_and_close

      spawn do
        sleep 10.milliseconds
        sent = transport.sent_messages.last
        transport.inject_raw(build_session_new_response(sent["id"].as_i64))
      end

      session = ACP::Session.create(client, cwd: "/tmp")
      transport.clear_sent

      session.close(notify_agent: false)
      session.closed?.should be_true
      transport.sent_messages.any? { |m| m["method"]?.try(&.as_s?) == "session/close" }.should be_false

      transport.close
    end

    it "is idempotent: a second close does not send another request" do
      transport, client = setup_client_with_session_and_close

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
          {"jsonrpc": "2.0", "id": #{sent["id"].as_i64}, "result": {}}
          JSON
        )
      end
      session.close
      transport.clear_sent

      session.close # second call — should be a no-op
      session.closed?.should be_true
      transport.sent_messages.should be_empty

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

  it "has a minimum protocol version no greater than the latest" do
    ACP::MIN_PROTOCOL_VERSION.should be <= ACP::PROTOCOL_VERSION
  end

  describe ".supports_protocol_version?" do
    it "accepts every version in the negotiable range" do
      (ACP::MIN_PROTOCOL_VERSION..ACP::PROTOCOL_VERSION).each do |version|
        ACP.supports_protocol_version?(version).should be_true
      end
    end

    it "rejects a version below the minimum" do
      unless ACP::MIN_PROTOCOL_VERSION.zero?
        ACP.supports_protocol_version?(ACP::MIN_PROTOCOL_VERSION - 1).should be_false
      end
    end

    it "rejects a version newer than this client implements" do
      ACP.supports_protocol_version?(ACP::PROTOCOL_VERSION + 1).should be_false
      ACP.supports_protocol_version?(UInt16::MAX).should be_false
    end
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
                {"optionId": "allow_once", "name": "Allow Once", "kind": "allow_once"},
                {"optionId": "deny", "name": "Deny", "kind": "reject_once"}
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
    perm_response.as(JSON::Any)["result"]["outcome"].should eq(JSON.parse(%({"outcome":"selected","optionId":"allow_once"})))

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
      output_byte_limit: 1048576_u64
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
    caps = ACP::Protocol::ClientCapabilities.new(fs: ACP::Protocol::FsCapabilities.new(read_text_file: true))
    client = ACP::Client.new(transport, client_capabilities: caps)

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
    caps = ACP::Protocol::ClientCapabilities.new(fs: ACP::Protocol::FsCapabilities.new(write_text_file: true))
    client = ACP::Client.new(transport, client_capabilities: caps)

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
    client = ACP::Client.new(transport, client_capabilities: ACP::Protocol::ClientCapabilities.new(terminal: true))

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
    caps = ACP::Protocol::ClientCapabilities.new(fs: ACP::Protocol::FsCapabilities.new(read_text_file: true))
    client = ACP::Client.new(transport, client_capabilities: caps)

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
    client = ACP::Client.new(transport, client_capabilities: ACP::Protocol::ClientCapabilities.new(terminal: true))

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

    it "returns method not found for extension requests without handler" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 10.milliseconds
        if msg = transport.last_sent
          transport.inject_raw(build_init_response(msg["id"].as_i64))
        end
      end
      client.initialize_connection

      # No on_agent_request handler set — an unrecognized extension request
      # gets -32601 (extensibility#custom-requests), like any unknown method.
      transport.inject_raw(%({"jsonrpc": "2.0", "id": "ext-2", "method": "_unknown_ext", "params": {}}))
      sleep 50.milliseconds

      response = transport.sent_messages.find { |msg| msg["id"]?.try(&.as_s?) == "ext-2" }
      response.should_not be_nil
      response.as(JSON::Any)["result"]?.should be_nil
      response.as(JSON::Any)["error"]["code"].as_i.should eq(ACP::JsonRpcError::METHOD_NOT_FOUND)
      response.as(JSON::Any)["error"]["data"].as_s.should eq("_unknown_ext")

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
    json_str = %({"content": {"type": "text", "text": "hello world"}, "messageId": "msg-1"})
    chunk = ACP::Protocol::ContentChunk.from_json(json_str)
    chunk.text.should eq("hello world")
    chunk.message_id.should eq("msg-1")
    JSON.parse(chunk.to_json).should eq(JSON.parse(json_str))
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
      group: "openai",
      name: "OpenAI Models",
      options: [
        ACP::Protocol::ConfigOptionValue.new(value: "gpt-4", name: "GPT-4"),
        ACP::Protocol::ConfigOptionValue.new(value: "gpt-3.5", name: "GPT-3.5"),
      ]
    )
    group.group.should eq("openai")
    group.id.should eq("openai") # backward-compatible alias
    group.name.should eq("OpenAI Models")
    group.options.size.should eq(2)
  end

  it "serializes to JSON with the spec-required \"group\" key" do
    group = ACP::Protocol::ConfigOptionGroup.new(
      group: "anthropic",
      name: "Anthropic",
      options: [
        ACP::Protocol::ConfigOptionValue.new(value: "claude-4", name: "Claude 4"),
      ]
    )
    json = JSON.parse(group.to_json)
    json["group"].as_s.should eq("anthropic")
    json.as_h.has_key?("id").should be_false
    json["name"].as_s.should eq("Anthropic")
    json["options"].as_a.size.should eq(1)
    json["options"][0]["value"].as_s.should eq("claude-4")
  end

  it "deserializes from JSON using the \"group\" key" do
    json_str = %({"group": "g1", "name": "Group 1", "options": [{"value": "v1", "name": "Value 1"}]})
    group = ACP::Protocol::ConfigOptionGroup.from_json(json_str)
    group.group.should eq("g1")
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
          group: "openai",
          name: "OpenAI",
          options: [
            ACP::Protocol::ConfigOptionValue.new(value: "gpt-4", name: "GPT-4"),
            ACP::Protocol::ConfigOptionValue.new(value: "gpt-3.5", name: "GPT-3.5"),
          ]
        ),
        ACP::Protocol::ConfigOptionGroup.new(
          group: "anthropic",
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

  it "serializes grouped options under the single spec \"options\" key" do
    opt = ACP::Protocol::ConfigOption.new(
      id: "model",
      name: "Model",
      current_value: "gpt-4",
      groups: [
        ACP::Protocol::ConfigOptionGroup.new(
          group: "openai",
          name: "OpenAI",
          options: [
            ACP::Protocol::ConfigOptionValue.new(value: "gpt-4", name: "GPT-4"),
          ]
        ),
      ]
    )
    json = JSON.parse(opt.to_json)
    # Per the ACP schema, grouped values live inside the single "options" key
    # (each element is a SessionConfigSelectGroup), NOT a separate "groups" key.
    json.as_h.has_key?("groups").should be_false
    json["options"].as_a.size.should eq(1)
    json["options"][0]["group"].as_s.should eq("openai")
    json["options"][0]["options"][0]["value"].as_s.should eq("gpt-4")
    json["currentValue"].as_s.should eq("gpt-4")
  end

  it "deserializes grouped options from the spec \"options\" key" do
    json_str = <<-JSON
      {
        "id": "model",
        "name": "Model Selector",
        "type": "select",
        "category": "model",
        "currentValue": "claude-4",
        "options": [
          {
            "group": "anthropic",
            "name": "Anthropic",
            "options": [
              {"value": "claude-4", "name": "Claude 4"},
              {"value": "claude-3.5", "name": "Claude 3.5"}
            ]
          },
          {
            "group": "openai",
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
    opt.groups.as(Array(ACP::Protocol::ConfigOptionGroup)).first.group.should eq("anthropic")
    opt.category.should eq("model")
    opt.current_value.should eq("claude-4")
    opt.all_values.size.should eq(3)
  end

  it "returns empty array when no options or groups" do
    opt = ACP::Protocol::ConfigOption.new(id: "empty", name: "Empty")
    opt.grouped?.should be_false
    opt.all_values.should be_empty
  end

  it "raises if constructed with both options and groups" do
    expect_raises(ArgumentError, /either .options. or .groups./) do
      ACP::Protocol::ConfigOption.new(
        id: "model",
        name: "Model",
        options: [ACP::Protocol::ConfigOptionValue.new(value: "a", name: "A")],
        groups: [ACP::Protocol::ConfigOptionGroup.new(
          group: "g", name: "G",
          options: [ACP::Protocol::ConfigOptionValue.new(value: "b", name: "B")]
        )]
      )
    end
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
    group = ACP::Protocol::SessionConfigSelectGroup.new(group: "g1", name: "G1")
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

# ═══════════════════════════════════════════════════════════════════════
# Typed Accessor Specs — ToolCallUpdate
# ═══════════════════════════════════════════════════════════════════════

describe "ToolCallUpdate typed accessors" do
  describe "#typed_content" do
    it "parses content items into ToolCallContent values" do
      json_str = <<-JSON
        {
          "sessionUpdate": "tool_call",
          "toolCallId": "tc-typed-1",
          "title": "Edit file",
          "content": [
            {
              "type": "content",
              "content": { "type": "text", "text": "Analysis done." }
            },
            {
              "type": "diff",
              "path": "/tmp/file.txt",
              "oldText": "old",
              "newText": "new"
            }
          ]
        }
        JSON
      update = ACP::Protocol::SessionUpdate.from_json(json_str)
      u = update.as(ACP::Protocol::ToolCallUpdate)

      typed = u.typed_content
      typed.size.should eq(2)
      typed[0].should be_a(ACP::Protocol::ToolCallContentBlock)
      typed[0].as(ACP::Protocol::ToolCallContentBlock).text.should eq("Analysis done.")
      typed[1].should be_a(ACP::Protocol::ToolCallDiff)
      typed[1].as(ACP::Protocol::ToolCallDiff).path.should eq("/tmp/file.txt")
    end

    it "returns empty array when content is nil" do
      json_str = %({"sessionUpdate": "tool_call", "toolCallId": "tc-nil", "title": "No content"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str).as(ACP::Protocol::ToolCallUpdate)
      update.typed_content.should be_empty
    end

    it "skips entries that fail to deserialize" do
      json_str = <<-JSON
        {
          "sessionUpdate": "tool_call",
          "toolCallId": "tc-skip",
          "title": "Partial",
          "content": [
            { "type": "content", "content": { "type": "text", "text": "ok" } },
            { "type": "unknown_type", "foo": "bar" }
          ]
        }
        JSON
      update = ACP::Protocol::SessionUpdate.from_json(json_str).as(ACP::Protocol::ToolCallUpdate)
      typed = update.typed_content
      typed.size.should eq(1)
      typed[0].should be_a(ACP::Protocol::ToolCallContentBlock)
    end
  end

  describe "#typed_locations" do
    it "parses locations into ToolCallLocation values" do
      json_str = <<-JSON
        {
          "sessionUpdate": "tool_call",
          "toolCallId": "tc-loc",
          "title": "Edit",
          "locations": [
            { "path": "/home/user/main.py", "line": 42 },
            { "path": "/home/user/utils.py" }
          ]
        }
        JSON
      update = ACP::Protocol::SessionUpdate.from_json(json_str).as(ACP::Protocol::ToolCallUpdate)
      locs = update.typed_locations
      locs.size.should eq(2)
      locs[0].path.should eq("/home/user/main.py")
      locs[0].line.should eq(42)
      locs[1].path.should eq("/home/user/utils.py")
      locs[1].line.should be_nil
    end

    it "returns empty array when locations is nil" do
      json_str = %({"sessionUpdate": "tool_call", "toolCallId": "tc-noloc", "title": "No locs"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str).as(ACP::Protocol::ToolCallUpdate)
      update.typed_locations.should be_empty
    end
  end
end

# ═══════════════════════════════════════════════════════════════════════
# Typed Accessor Specs — ToolCallStatusUpdate
# ═══════════════════════════════════════════════════════════════════════

describe "ToolCallStatusUpdate typed accessors" do
  describe "#typed_content" do
    it "parses content items into ToolCallContent values" do
      json_str = <<-JSON
        {
          "sessionUpdate": "tool_call_update",
          "toolCallId": "tc-su-1",
          "content": [
            {
              "type": "terminal",
              "terminalId": "term-001"
            }
          ]
        }
        JSON
      update = ACP::Protocol::SessionUpdate.from_json(json_str).as(ACP::Protocol::ToolCallStatusUpdate)
      typed = update.typed_content
      typed.size.should eq(1)
      typed[0].should be_a(ACP::Protocol::ToolCallTerminal)
      typed[0].as(ACP::Protocol::ToolCallTerminal).terminal_id.should eq("term-001")
    end

    it "returns empty array when content is nil" do
      json_str = %({"sessionUpdate": "tool_call_update", "toolCallId": "tc-su-nil"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str).as(ACP::Protocol::ToolCallStatusUpdate)
      update.typed_content.should be_empty
    end
  end

  describe "#typed_locations" do
    it "parses locations into ToolCallLocation values" do
      json_str = <<-JSON
        {
          "sessionUpdate": "tool_call_update",
          "toolCallId": "tc-su-loc",
          "locations": [
            { "path": "/src/app.cr", "line": 10 }
          ]
        }
        JSON
      update = ACP::Protocol::SessionUpdate.from_json(json_str).as(ACP::Protocol::ToolCallStatusUpdate)
      locs = update.typed_locations
      locs.size.should eq(1)
      locs[0].path.should eq("/src/app.cr")
      locs[0].line.should eq(10)
    end

    it "returns empty array when locations is nil" do
      json_str = %({"sessionUpdate": "tool_call_update", "toolCallId": "tc-su-noloc"})
      update = ACP::Protocol::SessionUpdate.from_json(json_str).as(ACP::Protocol::ToolCallStatusUpdate)
      update.typed_locations.should be_empty
    end
  end
end

# ═══════════════════════════════════════════════════════════════════════
# Typed Accessor Specs — ConfigOptionUpdate
# ═══════════════════════════════════════════════════════════════════════

describe "ConfigOptionUpdate typed accessors" do
  describe "#typed_config_options" do
    it "parses config_options into ConfigOption values" do
      json_str = <<-JSON
        {
          "sessionUpdate": "config_option_update",
          "configOptions": [
            {
              "id": "model",
              "name": "Model",
              "configType": "select",
              "currentValue": "gpt-4",
              "options": [
                { "value": "gpt-4", "name": "GPT-4" },
                { "value": "gpt-3.5", "name": "GPT-3.5" }
              ]
            },
            {
              "id": "mode",
              "name": "Mode",
              "configType": "select",
              "currentValue": "code"
            }
          ]
        }
        JSON
      update = ACP::Protocol::SessionUpdate.from_json(json_str).as(ACP::Protocol::ConfigOptionUpdate)
      typed = update.typed_config_options
      typed.size.should eq(2)
      typed[0].id.should eq("model")
      typed[0].current_value.should eq("gpt-4")
      typed[0].options.try(&.size).should eq(2)
      typed[1].id.should eq("mode")
      typed[1].current_value.should eq("code")
    end

    it "returns empty array when config_options is empty" do
      json_str = %({"sessionUpdate": "config_option_update", "configOptions": []})
      update = ACP::Protocol::SessionUpdate.from_json(json_str).as(ACP::Protocol::ConfigOptionUpdate)
      update.typed_config_options.should be_empty
    end

    it "skips entries that fail to deserialize" do
      json_str = <<-JSON
        {
          "sessionUpdate": "config_option_update",
          "configOptions": [
            { "id": "valid", "name": "Valid Option", "configType": "select" },
            "not_an_object"
          ]
        }
        JSON
      update = ACP::Protocol::SessionUpdate.from_json(json_str).as(ACP::Protocol::ConfigOptionUpdate)
      typed = update.typed_config_options
      typed.size.should eq(1)
      typed[0].id.should eq("valid")
    end
  end
end

# ═══════════════════════════════════════════════════════════════════════
# ErrorCode references JsonRpcError constants
# ═══════════════════════════════════════════════════════════════════════

describe "Protocol::ErrorCode references JsonRpcError" do
  it "PARSE_ERROR matches JsonRpcError::PARSE_ERROR" do
    ACP::Protocol::ErrorCode::PARSE_ERROR.should eq(ACP::JsonRpcError::PARSE_ERROR)
    ACP::Protocol::ErrorCode::PARSE_ERROR.should eq(-32700)
  end

  it "INVALID_REQUEST matches JsonRpcError::INVALID_REQUEST" do
    ACP::Protocol::ErrorCode::INVALID_REQUEST.should eq(ACP::JsonRpcError::INVALID_REQUEST)
    ACP::Protocol::ErrorCode::INVALID_REQUEST.should eq(-32600)
  end

  it "METHOD_NOT_FOUND matches JsonRpcError::METHOD_NOT_FOUND" do
    ACP::Protocol::ErrorCode::METHOD_NOT_FOUND.should eq(ACP::JsonRpcError::METHOD_NOT_FOUND)
    ACP::Protocol::ErrorCode::METHOD_NOT_FOUND.should eq(-32601)
  end

  it "INVALID_PARAMS matches JsonRpcError::INVALID_PARAMS" do
    ACP::Protocol::ErrorCode::INVALID_PARAMS.should eq(ACP::JsonRpcError::INVALID_PARAMS)
    ACP::Protocol::ErrorCode::INVALID_PARAMS.should eq(-32602)
  end

  it "INTERNAL_ERROR matches JsonRpcError::INTERNAL_ERROR" do
    ACP::Protocol::ErrorCode::INTERNAL_ERROR.should eq(ACP::JsonRpcError::INTERNAL_ERROR)
    ACP::Protocol::ErrorCode::INTERNAL_ERROR.should eq(-32603)
  end

  it "AUTH_REQUIRED matches JsonRpcError::AUTH_REQUIRED" do
    ACP::Protocol::ErrorCode::AUTH_REQUIRED.should eq(ACP::JsonRpcError::AUTH_REQUIRED)
    ACP::Protocol::ErrorCode::AUTH_REQUIRED.should eq(-32000)
  end

  it "RESOURCE_NOT_FOUND matches JsonRpcError::RESOURCE_NOT_FOUND" do
    ACP::Protocol::ErrorCode::RESOURCE_NOT_FOUND.should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)
    ACP::Protocol::ErrorCode::RESOURCE_NOT_FOUND.should eq(-32002)
  end
end

# ─── SessionInfo ───────────────────────────────────────────────────────

describe ACP::Protocol::SessionInfo do
  it "deserializes from JSON with all fields" do
    json_str = %({"sessionId": "sess-001", "cwd": "/home/user/project", "title": "My Session", "updatedAt": "2026-03-19T12:00:00Z"})
    info = ACP::Protocol::SessionInfo.from_json(json_str)
    info.session_id.should eq("sess-001")
    info.cwd.should eq("/home/user/project")
    info.title.should eq("My Session")
    info.updated_at.should eq("2026-03-19T12:00:00Z")
  end

  it "deserializes with only required fields" do
    json_str = %({"sessionId": "sess-002", "cwd": "/tmp"})
    info = ACP::Protocol::SessionInfo.from_json(json_str)
    info.session_id.should eq("sess-002")
    info.cwd.should eq("/tmp")
    info.title.should be_nil
    info.updated_at.should be_nil
  end

  it "serializes with correct JSON keys" do
    info = ACP::Protocol::SessionInfo.new(session_id: "sess-001", cwd: "/tmp", title: "Test")
    json = JSON.parse(info.to_json)
    json["sessionId"].as_s.should eq("sess-001")
    json["cwd"].as_s.should eq("/tmp")
    json["title"].as_s.should eq("Test")
  end
end

# ─── SessionListParams / SessionListResult ─────────────────────────────

describe ACP::Protocol::SessionListParams do
  it "serializes with optional fields" do
    params = ACP::Protocol::SessionListParams.new(cwd: "/home/user", cursor: "page2")
    json = JSON.parse(params.to_json)
    json["cwd"].as_s.should eq("/home/user")
    json["cursor"].as_s.should eq("page2")
  end

  it "serializes with nil optional fields" do
    params = ACP::Protocol::SessionListParams.new
    json = JSON.parse(params.to_json)
    json["cwd"]?.try(&.raw).should be_nil
    json["cursor"]?.try(&.raw).should be_nil
  end
end

describe ACP::Protocol::SessionListResult do
  it "deserializes with sessions and nextCursor" do
    json_str = <<-JSON
      {
        "sessions": [
          {"sessionId": "sess-001", "cwd": "/home/user/project1", "title": "First"},
          {"sessionId": "sess-002", "cwd": "/home/user/project2"}
        ],
        "nextCursor": "cursor_abc123"
      }
      JSON
    result = ACP::Protocol::SessionListResult.from_json(json_str)
    result.sessions.size.should eq(2)
    result.sessions[0].session_id.should eq("sess-001")
    result.sessions[0].title.should eq("First")
    result.sessions[1].session_id.should eq("sess-002")
    result.sessions[1].title.should be_nil
    result.next_cursor.should eq("cursor_abc123")
    result.has_more?.should be_true
  end

  it "deserializes without nextCursor" do
    json_str = %({"sessions": []})
    result = ACP::Protocol::SessionListResult.from_json(json_str)
    result.sessions.should be_empty
    result.next_cursor.should be_nil
    result.has_more?.should be_false
  end
end

# ─── SessionCapabilities with list ─────────────────────────────────────

describe ACP::Protocol::SessionCapabilities do
  it "deserializes with list capability present" do
    json_str = %({"list": {}})
    caps = ACP::Protocol::SessionCapabilities.from_json(json_str)
    caps.list?.should be_true
    caps.list.should_not be_nil
  end

  it "deserializes with list capability absent" do
    json_str = %({})
    caps = ACP::Protocol::SessionCapabilities.from_json(json_str)
    caps.list?.should be_false
    caps.list.should be_nil
  end

  it "deserializes with list capability null" do
    json_str = %({"list": null})
    caps = ACP::Protocol::SessionCapabilities.from_json(json_str)
    caps.list?.should be_false
    caps.list.should be_nil
  end

  it "deserializes resume and close capabilities" do
    json_str = %({"resume": {}, "close": {}})
    caps = ACP::Protocol::SessionCapabilities.from_json(json_str)
    caps.resume?.should be_true
    caps.close?.should be_true
    caps.list?.should be_false
  end

  it "treats absent resume and close as unsupported" do
    json_str = %({"list": {}})
    caps = ACP::Protocol::SessionCapabilities.from_json(json_str)
    caps.resume?.should be_false
    caps.close?.should be_false
  end
end

# ─── SessionInfoUpdate ─────────────────────────────────────────────────

describe ACP::Protocol::SessionInfoUpdate do
  it "deserializes from JSON" do
    json_str = %({"sessionUpdate": "session_info_update", "title": "My Conversation", "updatedAt": "2026-03-19T12:00:00Z"})
    update = ACP::Protocol::SessionUpdate.from_json(json_str)
    update.should be_a(ACP::Protocol::SessionInfoUpdate)
    info = update.as(ACP::Protocol::SessionInfoUpdate)
    info.title.should eq("My Conversation")
    info.updated_at.should eq("2026-03-19T12:00:00Z")
  end

  it "deserializes with only title" do
    json_str = %({"sessionUpdate": "session_info_update", "title": "Test"})
    update = ACP::Protocol::SessionUpdate.from_json(json_str)
    info = update.as(ACP::Protocol::SessionInfoUpdate)
    info.title.should eq("Test")
    info.updated_at.should be_nil
  end

  it "works within SessionUpdateParams" do
    json_str = %({"sessionId": "sess-001", "update": {"sessionUpdate": "session_info_update", "title": "Updated Title"}})
    params = ACP::Protocol::SessionUpdateParams.from_json(json_str)
    params.session_id.should eq("sess-001")
    params.update.should be_a(ACP::Protocol::SessionInfoUpdate)
  end
end

# ─── AgentMethod includes session/list ─────────────────────────────────

describe ACP::Protocol::AgentMethod do
  it "recognizes session/list as a known method" do
    ACP::Protocol::AgentMethod.known?("session/list").should be_true
  end

  it "recognizes session/list as a session method" do
    ACP::Protocol::AgentMethod.session_method?("session/list").should be_true
  end
end

# ═══════════════════════════════════════════════════════════════════════
# Edge Case Specs
# ═══════════════════════════════════════════════════════════════════════

describe "Edge Cases" do
  describe "classify_message with malformed messages" do
    it "treats empty object as notification" do
      msg = JSON.parse(%({}))
      ACP::Protocol.classify_message(msg).should eq(ACP::Protocol::MessageKind::Notification)
    end

    it "treats message with null id as a request if method present (JSON-RPC 2.0 §4.1)" do
      msg = JSON.parse(%({"id": null, "method": "test"}))
      ACP::Protocol.classify_message(msg).should eq(ACP::Protocol::MessageKind::Request)
    end

    it "treats message with null id and no method as a response" do
      msg = JSON.parse(%({"id": null}))
      ACP::Protocol.classify_message(msg).should eq(ACP::Protocol::MessageKind::Response)
    end
  end

  describe "extract_id edge cases" do
    it "returns nil when id is absent" do
      msg = JSON.parse(%({"method": "test"}))
      ACP::Protocol.extract_id(msg).should be_nil
    end

    it "returns nil when id is null" do
      msg = JSON.parse(%({"id": null}))
      ACP::Protocol.extract_id(msg).should be_nil
    end

    it "handles float ID by coercing to Int64" do
      msg = JSON.parse(%({"id": 42.0}))
      ACP::Protocol.extract_id(msg).should eq(42_i64)
    end
  end

  describe "Client double close" do
    it "is safe to call close multiple times" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)
      client.close
      client.close
      client.close
      client.closed?.should be_true
    end
  end

  describe "Client close cancels pending requests" do
    it "raises ConnectionClosedError for pending requests when client is closed" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      # Simulate that a request is pending by injecting an init response
      # after init starts, then close the client during a second request.
      spawn do
        sleep 50.milliseconds
        transport.inject_raw(build_init_response(1))
      end
      client.initialize_connection

      # Start a session_new request that will hang, then close
      done = Channel(Exception?).new(1)
      spawn do
        client.session_new("/tmp")
        done.send(nil)
      rescue ex
        done.send(ex)
      end

      sleep 50.milliseconds
      client.close

      result = done.receive
      result.should_not be_nil
      result.should be_a(ACP::ConnectionClosedError)
    end
  end

  describe "Session ensure_open! checks" do
    it "raises InvalidStateError on prompt after session close" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 50.milliseconds
        transport.inject_raw(build_init_response(1))
      end
      client.initialize_connection

      spawn do
        sleep 50.milliseconds
        transport.inject_raw(build_session_new_response(2))
      end
      session = ACP::Session.create(client, cwd: "/tmp")
      session.close

      expect_raises(ACP::InvalidStateError) do
        session.prompt("test")
      end

      client.close
    end

    it "raises ConnectionClosedError on prompt when client is closed" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 50.milliseconds
        transport.inject_raw(build_init_response(1))
      end
      client.initialize_connection

      spawn do
        sleep 50.milliseconds
        transport.inject_raw(build_session_new_response(2))
      end
      session = ACP::Session.create(client, cwd: "/tmp")
      client.close

      expect_raises(ACP::ConnectionClosedError) do
        session.prompt("test")
      end
    end
  end

  describe "PromptBuilder edge cases" do
    it "resource_link with explicit URI and name" do
      builder = ACP::PromptBuilder.new
      builder.resource_link("file:///tmp/test.cr", "test.cr", "text/x-crystal")
      blocks = builder.build
      blocks.size.should eq(1)
      rl = blocks[0].as(ACP::Protocol::ResourceLinkContentBlock)
      rl.uri.should eq("file:///tmp/test.cr")
      rl.name.should eq("test.cr")
      rl.mime_type.should eq("text/x-crystal")
    end

    it "resource_link from a path takes mime_type as a named argument" do
      builder = ACP::PromptBuilder.new
      builder.resource_link("/tmp/test.cr", mime_type: "text/x-crystal")
      rl = builder.build[0].as(ACP::Protocol::ResourceLinkContentBlock)
      rl.uri.should eq("file:///tmp/test.cr")
      rl.name.should eq("test.cr")
      rl.mime_type.should eq("text/x-crystal")
    end

    it "resource with text content" do
      builder = ACP::PromptBuilder.new
      builder.resource("file:///tmp/data.txt", "file content here", "text/plain")
      blocks = builder.build
      blocks.size.should eq(1)
      blocks[0].should be_a(ACP::Protocol::ResourceContentBlock)
    end
  end

  describe "JsonRpcError predicates" do
    it "identifies parse error" do
      err = ACP::JsonRpcError.new(ACP::JsonRpcError::PARSE_ERROR, "parse")
      err.parse_error?.should be_true
      err.server_error?.should be_false
    end

    it "identifies invalid request" do
      err = ACP::JsonRpcError.new(ACP::JsonRpcError::INVALID_REQUEST, "invalid")
      err.invalid_request?.should be_true
    end

    it "identifies method not found" do
      err = ACP::JsonRpcError.new(ACP::JsonRpcError::METHOD_NOT_FOUND, "not found")
      err.method_not_found?.should be_true
    end

    it "identifies invalid params" do
      err = ACP::JsonRpcError.new(ACP::JsonRpcError::INVALID_PARAMS, "params")
      err.invalid_params?.should be_true
    end

    it "identifies internal error" do
      err = ACP::JsonRpcError.new(ACP::JsonRpcError::INTERNAL_ERROR, "internal")
      err.internal_error?.should be_true
    end

    it "identifies server error range" do
      err = ACP::JsonRpcError.new(-32050, "server error")
      err.server_error?.should be_true
    end

    it "identifies auth required" do
      err = ACP::JsonRpcError.new(ACP::JsonRpcError::AUTH_REQUIRED, "auth")
      err.auth_required?.should be_true
    end

    it "identifies resource not found" do
      err = ACP::JsonRpcError.new(ACP::JsonRpcError::RESOURCE_NOT_FOUND, "not found")
      err.resource_not_found?.should be_true
    end

    it "has correct to_s format" do
      err = ACP::JsonRpcError.new(-32603, "Internal error", JSON.parse(%({"detail": "oops"})))
      err.to_s.should contain("JsonRpcError(-32603)")
      err.to_s.should contain("Internal error")
      err.to_s.should contain("detail")
    end

    it "builds from JSON::Any with missing fields" do
      obj = JSON.parse(%({}))
      err = ACP::JsonRpcError.from_json_any(obj)
      err.code.should eq(ACP::JsonRpcError::INTERNAL_ERROR)
      err.message.should eq("Unknown error")
    end
  end

  describe "StdioTransport double close" do
    it "is safe to close multiple times" do
      reader_r, reader_w = IO.pipe
      writer_r, writer_w = IO.pipe
      transport = ACP::StdioTransport.new(reader: reader_r, writer: writer_w)
      transport.close
      transport.close
      transport.closed?.should be_true
      reader_w.close rescue nil
      writer_r.close rescue nil
    end
  end

  describe "TestTransport close and receive" do
    it "returns nil on receive after close" do
      transport = TestTransport.new
      transport.close
      transport.receive.should be_nil
    end
  end

  describe "Session.to_s and inspect" do
    it "includes session id and modes" do
      transport = TestTransport.new
      client = ACP::Client.new(transport)

      spawn do
        sleep 50.milliseconds
        transport.inject_raw(build_init_response(1))
      end
      client.initialize_connection

      spawn do
        sleep 50.milliseconds
        transport.inject_raw(build_session_new_response(2))
      end
      session = ACP::Session.create(client, cwd: "/tmp")

      session.to_s.should contain("sess-001")
      session.inspect.should contain("sess-001")

      client.close
    end
  end
end

# The Agent side of a v2 connection, driven by scripted responses and updates.
private class V2TestTransport < TestTransport
  getter outgoing = Channel(JSON::Any).new(64)
  getter replies = {} of String => String
  property response_version = "2.0"
  property before_reply : (String -> Nil)?
  property after_reply : (String -> Nil)?

  def initialize
    super
    @replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
  end

  def send(message : Hash(String, JSON::Any)) : Nil
    super
    @outgoing.send(JSON::Any.new(message))
    if (method = message["method"]?.try(&.as_s?)) && (id = message["id"]?) && (payload = @replies[method]?)
      @before_reply.try(&.call(method))
      inject_raw(%({"jsonrpc":#{@response_version.to_json},"id":#{id.to_json},#{payload}}))
      @after_reply.try(&.call(method))
    end
  end

  def update(session_id : String, fields : String) : Nil
    inject_raw(%({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":#{session_id.to_json},"update":#{fields}}}))
  end
end

private def take_v2_frame(channel : Channel(T)) : T forall T
  select
  when item = channel.receive
    item
  when timeout(2.seconds)
    raise "expected v2 protocol frame"
  end
end

private def mcp_params(detail : String = "", version : String = ACP::MCP_PROTOCOL_VERSION) : String
  %({"_meta":{"io.modelcontextprotocol/protocolVersion":#{version.to_json},"io.modelcontextprotocol/clientCapabilities":{}}#{detail}})
end

private def mcp_request(transport : V2TestTransport, server : ACP::Protocol::McpServerAcp, id : Int32,
                        logical : String = "logical-#{id}", method : String = "tools/call",
                        params : String = mcp_params) : Nil
  transport.inject_raw(%({"jsonrpc":"2.0","id":#{id},"method":"mcp/message","params":{"serverId":#{server.server_id.to_json},"requestId":#{logical.to_json},"method":#{method.to_json},"params":#{params}}}))
end

private class PausedMcpRejectionTransport < V2TestTransport
  getter blocked = Channel(Nil).new(1)
  getter resume_write = Channel(Nil).new
  property blocked_code = -33001

  def send(message : Hash(String, JSON::Any)) : Nil
    if message["error"]?.try(&.["code"]?) == JSON::Any.new(@blocked_code.to_i64)
      @blocked.send(nil)
      @resume_write.receive?
    end
    super
  end

  def close : Nil
    super
    @resume_write.close
  end
end

describe "ACP draft native MCP binding" do
  it "preserves explicit nulls, exact numbers, and inner error extensions" do
    wire = %({"error":{"code":-32000,"message":"Inner","data":null,"extension":18446744073709551615,"decimal":0.123456789012345678901}})
    carrier = ACP::Protocol::V2::MessageMcpResponse.from_json(wire)
    carrier.error.not_nil!.data.not_nil!.json.should eq("null")
    carrier.error.not_nil!.raw_field("extension").should eq("18446744073709551615")
    carrier.error.not_nil!.raw_field("decimal").should eq("0.123456789012345678901")
    ACP::Protocol::MessageMcpResponse.from_json(carrier.to_json).error.not_nil!.code.should eq(-32000)

    both = ACP::Protocol::MessageMcpResponse.from_json(%({"result":null,"error":false,"_meta":{"exact":18446744073709551615}}))
    both.result.not_nil!.json.should eq("null")
    both.error.should be_nil
    both.meta.not_nil!.field("exact").not_nil!.json.should eq("18446744073709551615")
    ACP::Protocol::MessageMcpResponse.from_json(%({"result":null,"_meta":false})).meta.should be_nil
    expect_raises(JSON::ParseException) { ACP::Protocol::MessageMcpResponse.from_json("{}") }
    expect_raises(JSON::ParseException) { ACP::Protocol::MessageMcpResponse.from_json(%({"error":null})) }
    ACP::Protocol::McpCapabilities.from_json(%({"acp":{}})).acp?.should be_false
    duplicate = ACP::Protocol::WireFrame.new(%({"params":{"wide":18446744073709551615},"params":{"last":true}}))
    duplicate.params_json.should be_nil
    duplicate.project_for_routing["params"]["last"].should eq(true)
  end

  {"v1", "v2"}.each do |version|
    it "serves registered operations before the session setup reply on #{version}" do
      transport = V2TestTransport.new
      if version == "v1"
        transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"mcpCapabilities":{"acp":true}}})
        client = ACP::Client.new(transport)
      else
        transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"mcp":{"acp":{}}}}})
        client = ACP::V2::Client.new(transport)
      end
      server = client.register_mcp_server("fixture") do |ctx|
        ctx.notify("notifications/progress", ACP::Protocol::McpJson.from_json(%({"progress":1})))
        ACP::Protocol::MessageMcpResponse.success(ctx.request.params.not_nil!.field("arguments").not_nil!)
      end
      client.initialize_connection
      take_v2_frame(transport.outgoing)
      mcp_request(transport, server, 410)
      take_v2_frame(transport.outgoing)["error"]["code"].should eq(-33001)

      transport.replies["session/new"] = %("result":{"sessionId":"s"})
      transport.before_reply = ->(method : String) do
        if method == "session/new"
          mcp_request(transport, server, 411, params: mcp_params(%(,"arguments":{"text":"fixture"})))
        end
        nil
      end
      case client
      when ACP::Client
        client.session_new("/work", [server.to_json_any])
      when ACP::V2::Client
        wire = ACP::Protocol::V2::McpServer.acp(server)
        client.session_new(ACP::Protocol::V2::SessionNewParams.new("/work", mcp_servers: [wire]))
      end
      setup = take_v2_frame(transport.outgoing)
      setup["params"]["mcpServers"][0]["serverId"].should eq(server.server_id)
      progress = take_v2_frame(transport.outgoing)
      progress["method"].should eq("mcp/message")
      progress["id"]?.should be_nil
      progress["params"]["requestId"].should eq("logical-411")
      result = take_v2_frame(transport.outgoing)
      result["id"].should eq(411)
      result["result"]["result"]["text"].should eq("fixture")

      mcp_request(transport, server, 412, params: "[]")
      take_v2_frame(transport.outgoing)["error"]["code"].should eq(-32602)
      mcp_request(transport, server, 413, params: "{}")
      take_v2_frame(transport.outgoing)["result"]["error"]["code"].should eq(-32602)
      mcp_request(transport, server, 414, params: mcp_params(version: "2025-11-25"))
      error = take_v2_frame(transport.outgoing)["result"]["error"]
      error["code"].should eq(-32022)
      error["data"]["supported"][0].should eq("2026-07-28")
      transport.inject_raw(%({"jsonrpc":"1.0","id":414,"method":"mcp/message","params":{"serverId":#{server.server_id.to_json},"requestId":"invalid-rpc","method":"tools/list","params":#{mcp_params}}}))
      rejected = take_v2_frame(transport.outgoing)
      rejected["id"].raw.should be_nil
      rejected["error"]["code"].should eq(-32600)
      transport.inject_raw(%({"jsonrpc":"2.0","id":#{("x" * 1025).to_json},"method":"mcp/message","params":{"serverId":#{server.server_id.to_json},"requestId":"oversize-id","method":"tools/list","params":#{mcp_params}}}))
      rejected = take_v2_frame(transport.outgoing)
      rejected["id"].raw.should be_nil
      rejected["error"]["code"].should eq(-33000)
      client.unregister_mcp_server(server.server_id).should be_true
      mcp_request(transport, server, 415)
      take_v2_frame(transport.outgoing)["error"]["code"].should eq(-33001)
    ensure
      client.try(&.close)
    end
  end

  it "rejects an unnegotiated or foreign declaration before any setup is sent" do
    transport = V2TestTransport.new
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    server = ACP::Protocol::McpServerAcp.new("fixture", "foreign")
    params = ACP::Protocol::V2::SessionNewParams.new("/work", mcp_servers: [ACP::Protocol::V2::McpServer.acp(server)])
    expect_raises(ACP::InvalidStateError, /did not advertise/) { client.session_new(params) }
    transport.sent_messages.size.should eq(1)
    client.close

    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"mcp":{"acp":{}}}}})
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    expect_raises(ACP::InvalidStateError, /must be registered/) { client.session_new(params) }
    transport.sent_messages.size.should eq(1)
  ensure
    client.try(&.close)
  end

  it "holds the logical ID and permit until cancellation cleanup finishes" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"mcpCapabilities":{"acp":true}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s"})
    client = ACP::Client.new(transport, mcp_request_limit: 1)
    started = Channel(ACP::McpRequestContext).new(1)
    cancelled = Channel(Nil).new(1)
    cleanup = Channel(Nil).new
    server = client.register_mcp_server("fixture") do |ctx|
      if ctx.request.request_id == "active"
        started.send(ctx)
        ctx.cancellation.receive?
        cancelled.send(nil)
        cleanup.receive?
      end
      ACP::Protocol::MessageMcpResponse.success(JSON::Any.new(nil))
    end
    client.initialize_connection
    client.session_new("/work", [server.to_json_any])
    take_v2_frame(transport.outgoing)
    take_v2_frame(transport.outgoing)

    mcp_request(transport, server, 420, "active")
    context = take_v2_frame(started)
    transport.inject_raw(%({"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":420}}))
    take_v2_frame(cancelled)
    context.cancelled?.should be_true
    expect_raises(ACP::RequestCancelledError) { context.notify("notifications/progress") }
    mcp_request(transport, server, 421, "active")
    duplicate = take_v2_frame(transport.outgoing)
    duplicate["id"].should eq(421)
    duplicate["error"]["code"].should eq(-32602)
    mcp_request(transport, server, 422, "next")
    take_v2_frame(transport.outgoing)["error"]["code"].should eq(-33000)

    cleanup.send(nil)
    response = take_v2_frame(transport.outgoing)
    response["id"].should eq(420)
    response["error"]["code"].should eq(-32800)
    # Let the writer return and release admission after the response.
    Fiber.yield
    mcp_request(transport, server, 423, "next")
    take_v2_frame(transport.outgoing)["result"]["result"].raw.should be_nil
  ensure
    cleanup.try(&.close)
    client.try(&.close)
  end

  it "scopes subscription notifications and preserves opaque multi-round-trip state" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"mcpCapabilities":{"acp":true}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s"})
    client = ACP::Client.new(transport)
    server = client.register_mcp_server("fixture") do |ctx|
      result = case ctx.request.method
               when "subscriptions/listen"
                 ctx.notify("notifications/subscriptions/acknowledged", ACP::Protocol::McpJson.from_json(%({"notifications":{"toolsListChanged":true}})))
                 ctx.notify("notifications/tools/list_changed")
                 %({"_meta":{"fixture":"kept"}})
               when "server/discover"
                 %({"supportedVersions":["2025-11-25","2026-07-28"],"capabilities":{}})
               else
                 if state = ctx.request.params.try(&.field("requestState"))
                   %({"resultType":"complete","echo":#{state.json}})
                 else
                   %({"resultType":"input_required","requestState":"fixture-only"})
                 end
               end
      ACP::Protocol::MessageMcpResponse.success(ACP::Protocol::McpJson.from_json(result))
    end
    client.initialize_connection
    client.session_new("/work", [server.to_json_any])
    take_v2_frame(transport.outgoing)
    take_v2_frame(transport.outgoing)
    mcp_request(transport, server, 430, method: "subscriptions/listen")
    ack = take_v2_frame(transport.outgoing)
    ack["params"]["method"].should eq("notifications/subscriptions/acknowledged")
    ack["params"]["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"].should eq("logical-430")
    take_v2_frame(transport.outgoing)["params"]["method"].should eq("notifications/tools/list_changed")
    meta = take_v2_frame(transport.outgoing)["result"]["result"]["_meta"]
    meta["io.modelcontextprotocol/subscriptionId"].should eq("logical-430")
    meta["fixture"].should eq("kept")
    mcp_request(transport, server, 431, method: "server/discover")
    take_v2_frame(transport.outgoing)["result"]["result"]["supportedVersions"].as_a.map(&.as_s).should eq(["2026-07-28"])
    mcp_request(transport, server, 432)
    state = take_v2_frame(transport.outgoing)["result"]["result"]["requestState"]
    mcp_request(transport, server, 433, params: mcp_params(%(,"requestState":#{state.to_json},"inputResponses":{})))
    take_v2_frame(transport.outgoing)["result"]["result"]["echo"].should eq(state)
  ensure
    client.try(&.close)
  end

  it "preserves wide MCP parameters and replies over stdio during setup" do
    reader, feed = IO.pipe
    outgoing, writer = IO.pipe
    outgoing.read_timeout = 2.seconds
    client = ACP::V2::Client.new(ACP::StdioTransport.new(reader, writer))
    client.request_timeout = 3.0
    transcript = Channel(Array(String) | Exception).new(1)
    server = client.register_mcp_server("fixture") do |ctx|
      value = ctx.request.params.not_nil!.field("counter").not_nil!
      ctx.notify("notifications/progress", ACP::Protocol::McpJson.from_json(%({"progress":#{value.json}})))
      ACP::Protocol::MessageMcpResponse.success(value, ctx.request.meta)
    end
    spawn do
      init = JSON.parse(outgoing.gets.not_nil!)
      feed.puts %({"jsonrpc":"2.0","id":#{init["id"].to_json},"result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"mcp":{"acp":{}}}}}})
      setup = JSON.parse(outgoing.gets.not_nil!)
      id = setup["params"]["mcpServers"][0]["serverId"]
      feed.puts %({"jsonrpc":"2.0","id":"outer","method":"mcp/message","params":{"serverId":#{id.to_json},"requestId":"inner","method":"tools/call","params":#{mcp_params(%(,"counter":18446744073709551615))},"_meta":{"opaque":18446744073709551615}}})
      messages = [outgoing.gets.not_nil!, outgoing.gets.not_nil!]
      feed.puts %({"jsonrpc":"2.0","id":"decimal","method":"mcp/message","params":{"serverId":#{id.to_json},"requestId":"decimal","method":"tools/call","params":#{mcp_params(%(,"counter":0.123456789012345678901))}}})
      messages << outgoing.gets.not_nil! << outgoing.gets.not_nil!
      feed.puts %({"jsonrpc":"2.0","id":"decimal-wide-envelope","method":"mcp/message","future":18446744073709551615,"params":{"serverId":#{id.to_json},"requestId":"wide-envelope","method":"tools/call","params":#{mcp_params(%(,"counter":0.123456789012345678901))}}})
      messages << outgoing.gets.not_nil! << outgoing.gets.not_nil!
      feed.puts %({"jsonrpc":"2.0","id":#{setup["id"].to_json},"result":{"sessionId":"s"}})
      transcript.send(messages)
    rescue ex
      transcript.send(ex)
    end
    client.initialize_connection
    wire = ACP::Protocol::V2::McpServer.acp(server)
    client.session_new(ACP::Protocol::V2::SessionNewParams.new("/work", mcp_servers: [wire]))
    outcome = take_v2_frame(transcript)
    raise outcome if outcome.is_a?(Exception)

    progress, result, decimal_progress, decimal_result, exact_progress, exact_result = outcome
    progress.should contain(%("requestId":"inner"))
    progress.should contain(%("progress":18446744073709551615))
    result.should contain(%("id":"outer"))
    result.should contain(%("result":{"result":18446744073709551615,"_meta":{"opaque":18446744073709551615}}))
    decimal_progress.should contain(%("progress":0.123456789012345678901))
    decimal_result.should contain(%("result":{"result":0.123456789012345678901}))
    exact_progress.should contain(%("progress":0.123456789012345678901))
    exact_result.should contain(%("result":{"result":0.123456789012345678901}))
  ensure
    client.try(&.close)
    feed.try(&.close)
    outgoing.try(&.close)
  end

  it "cancels only work owned by a released registration and never rebinds its ID" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"mcpCapabilities":{"acp":true},"sessionCapabilities":{"resume":{}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s"})
    transport.replies["session/resume"] = %("result":{})
    client = ACP::Client.new(transport)
    started = Channel(ACP::McpRequestContext).new(2)
    handler = ->(ctx : ACP::McpRequestContext) do
      started.send(ctx)
      ctx.cancellation.receive?
      ACP::Protocol::MessageMcpResponse.success(JSON::Any.new(nil))
    end
    first = client.register_mcp_server("fixture", &handler)
    second = client.register_mcp_server("sibling", &handler)
    client.initialize_connection
    client.session_new("/work", [first.to_json_any])
    client.session_resume("s", "/work", [second.to_json_any])
    3.times { take_v2_frame(transport.outgoing) }
    mcp_request(transport, first, 440, "same")
    mcp_request(transport, second, 441, "same")
    contexts = [take_v2_frame(started), take_v2_frame(started)]
    client.unregister_mcp_server(first.server_id).should be_true
    take_v2_frame(transport.outgoing)["id"].should eq(440)
    contexts.find! { |ctx| ctx.outer_id == 441 }.cancelled?.should be_false

    replacement = client.register_mcp_server("fixture", &handler)
    replacement.server_id.should_not eq(first.server_id)
    mcp_request(transport, first, 442)
    take_v2_frame(transport.outgoing)["error"]["code"].should eq(-33001)
    client.close
    contexts.find! { |ctx| ctx.outer_id == 441 }.cancelled?.should be_true
  ensure
    client.try(&.close)
  end

  it "reserves an outer ID while its rejection is still writing" do
    transport = PausedMcpRejectionTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"mcpCapabilities":{"acp":true}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s"})
    client = ACP::Client.new(transport)
    server = client.register_mcp_server("fixture") do |_ctx|
      ACP::Protocol::MessageMcpResponse.success(JSON::Any.new(nil))
    end
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    barrier = Channel(String).new(1)
    client.on_notification = ->(method : String, _params : JSON::Any?) do
      barrier.send(method)
      nil
    end
    mcp_request(transport, server, 450)
    take_v2_frame(transport.blocked)
    client.session_new("/work", [server.to_json_any])
    take_v2_frame(transport.outgoing)
    mcp_request(transport, server, 450)
    transport.inject_raw(%({"jsonrpc":"2.0","method":"_fixture/barrier"}))
    take_v2_frame(barrier).should eq("_fixture/barrier")
    transport.resume_write.send(nil)
    take_v2_frame(transport.outgoing)["error"]["code"].should eq(-33001)
    collision = take_v2_frame(transport.outgoing)
    collision["id"].raw.should be_nil
    collision["error"]["code"].should eq(-32600)
  ensure
    transport.try(&.resume_write.close)
    client.try(&.close)
  end

  it "interrupts a blocked MCP notification when the Agent closes its output" do
    reader, feed = IO.pipe
    outgoing, writer = IO.pipe
    outgoing.read_timeout = 2.seconds
    client = ACP::Client.new(ACP::StdioTransport.new(reader, writer))
    client.request_timeout = 3.0
    cleaned = Channel(Bool).new(1)
    payload = ACP::Protocol::McpJson.from_json(%({"under_pressure":"#{"a" * (1024 * 1024)}"}))
    server = client.register_mcp_server("fixture") do |ctx|
      begin
        ctx.notify("notifications/progress", payload)
        ACP::Protocol::MessageMcpResponse.success(JSON::Any.new(nil))
      ensure
        cleaned.send(ctx.cancelled?)
      end
    end
    spawn do
      init = JSON.parse(outgoing.gets.not_nil!)
      feed.puts %({"jsonrpc":"2.0","id":#{init["id"].to_json},"result":{"protocolVersion":1,"agentCapabilities":{"mcpCapabilities":{"acp":true}}}})
      setup = JSON.parse(outgoing.gets.not_nil!)
      feed.puts %({"jsonrpc":"2.0","id":#{setup["id"].to_json},"result":{"sessionId":"s"}})
    end
    client.initialize_connection
    client.session_new("/work", [server.to_json_any])
    feed.puts %({"jsonrpc":"2.0","id":451,"method":"mcp/message","params":{"serverId":#{server.server_id.to_json},"requestId":"blocked","method":"tools/list","params":#{mcp_params}}})
    outgoing.read_byte.should eq('{'.ord.to_u8)
    feed.close
    take_v2_frame(cleaned).should be_true
  ensure
    client.try(&.close)
    feed.try(&.close)
    outgoing.try(&.close)
  end

  it "aborts the writer on EOF while an ID-less MCP rejection is pending" do
    transport = PausedMcpRejectionTransport.new
    transport.blocked_code = -32600
    disconnected = Channel(Nil).new(1)
    client = ACP::Client.new(transport)
    client.on_disconnect = -> do
      disconnected.send(nil)
      nil
    end
    transport.inject_raw(%({"jsonrpc":"2.0","id":null,"method":"mcp/message","params":{}}))
    take_v2_frame(transport.blocked)
    transport.inject_message(nil)
    take_v2_frame(disconnected)
    transport.closed?.should be_true
  ensure
    client.try(&.close)
  end
end

describe "ACP draft authentication status" do
  {"v1", "v2"}.each do |version|
    it "receives early status changes and queries status on #{version}" do
      transport = V2TestTransport.new
      transport.replies["initialize"] = if version == "v1"
                                          %("result":{"protocolVersion":1,"agentCapabilities":{"auth":{"status":{}}}})
                                        else
                                          %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"auth":{"status":{}}}})
                                        end
      transport.replies["auth/status"] = %("result":{"state":"authenticated","accounts":[{"label":"Workspace account","active":true,"organization":"Team"},{"description":"Missing label"}],"_meta":{"example.test/source":"fixture"}})
      transport.after_reply = ->(method : String) do
        if method == "initialize"
          transport.inject_raw(%({"jsonrpc":"2.0","method":"auth/status_update","params":{"state":"_later","accounts":[]}}))
        end
      end
      client = version == "v1" ? ACP::Client.new(transport) : ACP::V2::Client.new(transport)
      updates = Channel(ACP::Protocol::AuthStatusUpdateParams).new(1)
      client.on_auth_status_update = ->(status : ACP::Protocol::AuthStatusUpdateParams) do
        updates.send(status)
        nil
      end
      client.initialize_connection
      take_v2_frame(transport.outgoing)
      update = take_v2_frame(updates)
      update.state.should eq("unknown")
      update.raw_state.should eq("_later")
      update.accounts.should be_empty

      result = client.auth_status
      result.state.should eq("authenticated")
      result.accounts.size.should eq(1)
      account = result.accounts.first
      account.label.should eq("Workspace account")
      account.active.should be_true
      account.organization.should eq("Team")
      result.meta.not_nil!["example.test/source"].should eq("fixture")
      request = take_v2_frame(transport.outgoing)
      request["method"].should eq("auth/status")
      request["params"].should eq(JSON.parse("{}"))
    ensure
      client.try(&.close)
    end
  end

  it "treats invalid or absent status markers as unsupported" do
    wire = %({"protocolVersion":1,"agentCapabilities":{"auth":{"status":true}}})
    ACP::Protocol::InitializeResult.from_json(wire).agent_capabilities.auth.not_nil!.status.should be_nil
    supported = ACP::Protocol::AgentAuthCapabilities.new(status: ACP::Protocol::AuthStatusCapabilities.new)
    JSON.parse(supported.to_json)["status"].should eq(JSON.parse("{}"))

    transport = V2TestTransport.new
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    expect_raises(ACP::InvalidStateError, /auth.status/) { client.auth_status }
    transport.sent_messages.size.should eq(1)
  ensure
    client.try(&.close)
  end

  it "keeps account details available to the client while redacting frame logs" do
    result = %({"jsonrpc":"2.0","id":1,"result":{"state":"authenticated","accounts":[{"label":"Display account"}]}})
    malformed_result = %({"jsonrpc":"2.0","id":2,"result":{"accounts":[{"label":"Display account"}]}})
    notification = %({"jsonrpc":"2.0","method":"auth/status_update","params":{"state":"unauthenticated","accounts":[{"label":"Display account"}]}})
    Log.capture("acp.transport", level: :debug) do |logs|
      transport = ACP::StdioTransport.new(IO::Memory.new([result, malformed_result, notification].join("\n") + "\n"), IO::Memory.new)
      transport.receive.not_nil!["result"]["accounts"][0]["label"].should eq("Display account")
      transport.receive.not_nil!["result"]["accounts"][0]["label"].should eq("Display account")
      transport.receive.not_nil!["params"]["accounts"][0]["label"].should eq("Display account")
      logs.check(:debug, /\[REDACTED frame\]/)
      logs.entry.message.should_not contain("Display account")
      logs.check(:debug, /"accounts":"\[REDACTED\]"/)
      logs.entry.message.should_not contain("Display account")
      logs.check(:debug, /\[REDACTED frame\]/)
      logs.entry.message.should_not contain("Display account")
    ensure
      transport.try(&.close)
    end
  end
end

describe "ACP draft session status" do
  it "queries a v1 session without making it active and supports a closed wrapper" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"status":{}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"active"})
    transport.replies["session/status"] = %("result":{"status":"_future","_meta":{"example.test/source":"fixture"}})
    client = ACP::Client.new(transport)
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    ACP::Session.create(client, "/work")
    take_v2_frame(transport.outgoing)
    other = ACP::Session.new(client, "other")
    other.close(notify_agent: false)

    metadata = {"example.test/source" => JSON::Any.new("client")}
    result = other.status(meta: metadata)
    result.status.should eq("saved")
    result.raw_status.should eq("_future")
    result.open?.should be_false
    result.meta.not_nil!["example.test/source"].should eq("fixture")
    wire = take_v2_frame(transport.outgoing)
    wire["method"].should eq("session/status")
    wire["params"].should eq(JSON.parse(%({"sessionId":"other","_meta":{"example.test/source":"client"}})))
    client.session_id.should eq("active")
    client.state.should eq(ACP::ClientState::SessionActive)

    transport.replies["session/status"] = %("error":{"code":-32002,"message":"Resource not found","data":{"sessionId":"missing"}})
    error = expect_raises(ACP::JsonRpcError) { client.session_status("missing") }
    error.code.should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)
    error.received?.should be_true
    error.data.not_nil!["sessionId"].should eq("missing")
  ensure
    client.try(&.close)
  end

  it "keeps a v2 foreground snapshot local to its response" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"status":{}}}})
    transport.replies["session/status"] = %("result":{"status":"open","state":{"state":"idle","stopReason":"end_turn"}})
    updates = Channel(String).new(2)
    client = ACP::V2::Client.new(transport)
    client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
      updates.send(note.update.session_update)
      nil
    end
    client.initialize_connection
    take_v2_frame(transport.outgoing)

    result = client.session_status("elsewhere")
    result.open?.should be_true
    result.state.not_nil!.stop_reason.should eq("end_turn")
    JSON.parse(result.to_json)["state"].should eq(JSON.parse(%({"state":"idle","stopReason":"end_turn"})))
    request = take_v2_frame(transport.outgoing)
    request["method"].should eq("session/status")
    request["params"]["sessionId"].should eq("elsewhere")

    transport.update("root", %({"sessionUpdate":"subagent_update","sessionId":"child"}))
    take_v2_frame(updates).should eq("subagent_update")
    expect_raises(ACP::InvalidStateError) { client.session_status("child") }
    transport.sent_messages.size.should eq(2)
  ensure
    client.try(&.close)
  end

  it "leaves omitted, null, and malformed v2 foreground state unknown" do
    {"", %(,"state":null), %(,"state":[]), %(,"state":{}), %(,"state":{"state":42})}.each do |state|
      result = ACP::Protocol::V2::SessionStatusResult.from_json(%({"status":"open"#{state},"_meta":true}))
      result.open?.should be_true
      result.state.should be_nil
      result.meta.should be_nil
    end
  end

  it "decodes v2 status over stdio before interpreting wide foreground fields" do
    reader, feed = IO.pipe
    outgoing, writer = IO.pipe
    outgoing.read_timeout = 2.seconds
    client = ACP::V2::Client.new(ACP::StdioTransport.new(reader, writer))
    client.request_timeout = 2.0
    spawn do
      {
        %({"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"status":{}}}}),
        %({"status":"open","state":18446744073709551615}),
        %({"status":"open","state":{"state":"running","_meta":{"counter":18446744073709551615}}}),
      }.each do |result|
        break unless line = outgoing.gets

        id = JSON.parse(line)["id"]
        feed.puts %({"jsonrpc":"2.0","id":#{id.to_json},"result":#{result}})
      end
    end
    client.initialize_connection
    client.session_status("s").state.should be_nil
    snapshot = client.session_status("s").state.not_nil!
    snapshot.state.should eq("running")
    snapshot.raw_field("_meta").should eq(%({"counter":18446744073709551615}))
  ensure
    client.try(&.close)
    feed.try(&.close)
    outgoing.try(&.close)
  end

  it "does not send requests without a capability marker object" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"status":true}}})
    v1 = ACP::Client.new(transport)
    v1.initialize_connection
    expect_raises(ACP::InvalidStateError, /sessionCapabilities.status/) { v1.session_status("s") }
    transport.sent_messages.size.should eq(1)

    v2_transport = V2TestTransport.new
    v2 = ACP::V2::Client.new(v2_transport)
    v2.initialize_connection
    expect_raises(ACP::InvalidStateError, /session.status/) { v2.session_status("s") }
    v2_transport.sent_messages.size.should eq(1)

    marker = ACP::Protocol::SessionStatusCapabilities.new
    v1_caps = ACP::Protocol::SessionCapabilities.new(status: marker)
    v2_caps = ACP::Protocol::V2::SessionCapabilities.new(status: marker)
    JSON.parse(v1_caps.to_json)["status"].should eq(JSON.parse("{}"))
    JSON.parse(v2_caps.to_json)["status"].should eq(JSON.parse("{}"))
    ACP::Protocol::SessionCapabilities.from_json(%({"status":{"_meta":true}})).status.not_nil!.meta.should be_nil
    ACP::Protocol::V2::SessionCapabilities.from_json(%({"status":{"_meta":null}})).status.not_nil!.meta.should be_nil
  ensure
    v1.try(&.close)
    v2.try(&.close)
  end
end

describe "ACP draft session titles" do
  {"v1", "v2"}.each do |version|
    it "returns the title the Agent stored for an inactive #{version} session" do
      transport = V2TestTransport.new
      transport.replies["initialize"] = if version == "v1"
                                          %("result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"title":{}}}})
                                        else
                                          %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"title":{}}}})
                                        end
      transport.replies["session/set_title"] = %("result":{"title":"New title","_meta":false})
      client = version == "v1" ? ACP::Client.new(transport) : ACP::V2::Client.new(transport)
      client.initialize_connection
      take_v2_frame(transport.outgoing)

      metadata = {"example.test/source" => JSON::Any.new("editor")}
      original = " New   title "
      result = if client.is_a?(ACP::Client)
                 session = ACP::Session.new(client, "saved")
                 session.close(notify_agent: false)
                 session.set_title(original, meta: metadata)
               else
                 client.session_set_title("saved", original, meta: metadata)
               end
      result.title.should eq("New title")
      result.meta.should be_nil
      wire = take_v2_frame(transport.outgoing)
      wire["method"].should eq("session/set_title")
      wire["params"]["sessionId"].should eq("saved")
      wire["params"]["title"].should eq(original)
      wire["params"]["_meta"]["example.test/source"].should eq("editor")

      transport.replies["session/set_title"] = %("error":{"code":-32602,"message":"Title must not be empty."})
      error = expect_raises(ACP::JsonRpcError) { client.session_set_title("saved", " ") }
      error.received?.should be_true
      error.invalid_params?.should be_true
      take_v2_frame(transport.outgoing)["params"]["title"].should eq(" ")
    ensure
      client.try(&.close)
    end
  end

  it "rejects omitted, null, and non-string stored titles" do
    {"{}", %({"title":null}), %({"title":42})}.each do |wire|
      expect_raises(JSON::ParseException) { ACP::Protocol::SetSessionTitleResult.from_json(wire) }
    end
  end

  it "treats an invalid title marker as unsupported" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"title":true}}})
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    expect_raises(ACP::InvalidStateError, /session.title/) { client.session_set_title("s", "Title") }
    transport.sent_messages.size.should eq(1)

    marker = ACP::Protocol::SessionTitleCapabilities.new
    capabilities = ACP::Protocol::SessionCapabilities.new(title: marker)
    JSON.parse(capabilities.to_json)["title"].should eq(JSON.parse("{}"))
    ACP::Protocol::SessionCapabilities.from_json(%({"title":{"_meta":true}})).title.not_nil!.meta.should be_nil
  ensure
    client.try(&.close)
  end
end

describe "ACP draft session archive" do
  it "preserves archive filters and treats invalid reported flags as unknown" do
    params = ACP::Protocol::SessionListParams.from_json(%({"archived":"_future"}))
    JSON.parse(params.to_json)["archived"].should eq("_future")
    expect_raises(JSON::ParseException) { ACP::Protocol::SessionListParams.from_json(%({"archived":true})) }

    {"", %(,"archived":null), %(,"archived":{}), %(,"archived":"false")}.each do |field|
      ACP::Protocol::SessionInfo.from_json(%({"sessionId":"s","cwd":"/work"#{field}})).archived.should be_nil
    end
    row = ACP::Protocol::SessionInfo.new("s", "/work", archived: false)
    JSON.parse(row.to_json)["archived"].should eq(false)
  end

  it "preserves v1 runtime on archive failure and closes it on success" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"list":{},"archive":{}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s"})
    transport.replies["session/archive"] = %("error":{"code":-32002,"message":"Unknown session","data":{"sessionId":"s"}})
    client = ACP::Client.new(transport)
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    session = ACP::Session.create(client, "/work")
    take_v2_frame(transport.outgoing)

    error = expect_raises(ACP::JsonRpcError) { session.archive }
    error.resource_not_found?.should be_true
    error.data.not_nil!["sessionId"].should eq("s")
    take_v2_frame(transport.outgoing)["method"].should eq("session/archive")
    session.closed?.should be_false
    client.session_id.should eq("s")

    transport.replies["session/archive"] = %("result":[])
    expect_raises(ACP::ProtocolError) { session.archive }
    take_v2_frame(transport.outgoing)["method"].should eq("session/archive")
    client.session_id.should eq("s")

    meta = {"example.test/source" => JSON::Any.new("editor")}
    transport.replies["session/archive"] = %("result":{"_meta":{"example.test/source":"agent"}})
    session.archive(meta: meta).meta.not_nil!["example.test/source"].should eq("agent")
    take_v2_frame(transport.outgoing)["params"].should eq(JSON.parse(%({"sessionId":"s","_meta":{"example.test/source":"editor"}})))
    session.closed?.should be_true
    client.session_id.should be_nil
    expect_raises(ACP::NoActiveSessionError) { client.session_prompt_text("hello") }

    transport.replies["session/unarchive"] = %("result":{})
    session.unarchive
    take_v2_frame(transport.outgoing)["method"].should eq("session/unarchive")
    session.closed?.should be_true
    client.session_id.should be_nil
  ensure
    client.try(&.close)
  end

  it "passes archive filters and pagination to v1 and v2 Agents" do
    {"v1", "v2"}.each do |version|
      transport = V2TestTransport.new
      transport.replies["initialize"] = if version == "v1"
                                          %("result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"list":{},"archive":{}}}})
                                        else
                                          %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"archive":{}}}})
                                        end
      transport.replies["session/list"] = %("result":{"sessions":[{"sessionId":"saved","cwd":"/work","archived":true}],"nextCursor":"page3"})
      client = version == "v1" ? ACP::Client.new(transport) : ACP::V2::Client.new(transport)
      begin
        client.initialize_connection
        take_v2_frame(transport.outgoing)
        page = if client.is_a?(ACP::Client)
                 ACP::Session.list(client, "/work", "page2", archived: "only")
               else
                 client.session_list(ACP::Protocol::V2::SessionListParams.new(cwd: "/work", cursor: "page2", archived: "only"))
               end
        page.sessions.first.archived.should be_true
        page.next_cursor.should eq("page3")
        take_v2_frame(transport.outgoing)["params"].should eq(JSON.parse(%({"cwd":"/work","cursor":"page2","archived":"only"})))
      ensure
        client.close
      end
    end
  end

  it "cancels v1 user input for the archived session only" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"list":{},"archive":{}}}})
    transport.replies["session/archive"] = %("result":{})
    client = ACP::Client.new(transport)
    entered = Channel(String).new(2)
    release = Channel(Nil).new
    selected = JSON.parse(%({"outcome":{"outcome":"selected","optionId":"allow"}}))
    client.on_agent_request = ->(_method : String, params : JSON::Any) do
      entered.send(params["sessionId"].as_s)
      release.receive?
      selected
    end
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    {"kept", "archived"}.each do |sid|
      transport.inject_raw(%({"jsonrpc":"2.0","id":#{sid.to_json},"method":"session/request_permission","params":{"sessionId":#{sid.to_json},"toolCall":{"toolCallId":"t"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"}]}}))
      take_v2_frame(entered).should eq(sid)
    end

    client.session_archive("archived")
    take_v2_frame(transport.outgoing)["method"].should eq("session/archive")
    cancelled = take_v2_frame(transport.outgoing)
    cancelled["id"].should eq("archived")
    cancelled["result"]["outcome"]["outcome"].should eq("cancelled")

    release.close
    remaining = take_v2_frame(transport.outgoing)
    remaining["id"].should eq("kept")
    remaining["result"].should eq(selected)
  ensure
    release.try(&.close)
    client.try(&.close)
  end

  it "applies overlapping v1 resume and archive results in receive order" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"list":{},"resume":{},"archive":{}}}})
    client = ACP::Client.new(transport)
    client.request_timeout = 2.0
    active_sessions = Channel(String?).new(2)
    client.on_notification = ->(_method : String, _params : JSON::Any?) do
      active_sessions.send(client.session_id)
      nil
    end
    client.initialize_connection
    take_v2_frame(transport.outgoing)

    completed = Channel(Nil).new(2)
    spawn do
      client.session_resume("s", "/work")
      completed.send(nil)
    end
    resume = take_v2_frame(transport.outgoing)
    spawn do
      client.session_archive("s")
      completed.send(nil)
    end
    archive = take_v2_frame(transport.outgoing)

    {resume, archive}.each do |request|
      transport.inject_raw(%({"jsonrpc":"2.0","id":#{request["id"].to_json},"result":{}}))
      transport.inject_raw(%({"jsonrpc":"2.0","method":"_check_state","params":{}}))
    end
    take_v2_frame(active_sessions).should eq("s")
    take_v2_frame(active_sessions).should be_nil
    2.times { take_v2_frame(completed) }
    client.session_id.should be_nil
  ensure
    client.try(&.close)
  end

  it "keeps a v1 attachment received after an overlapping remote close" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"close":{},"resume":{}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s"})
    client = ACP::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    session = ACP::Session.create(client, "/work")
    take_v2_frame(transport.outgoing)

    completed = Channel(Nil).new(2)
    spawn do
      session.close(raise_on_error: true)
      completed.send(nil)
    end
    close = take_v2_frame(transport.outgoing)
    spawn do
      client.session_resume("s", "/work")
      completed.send(nil)
    end
    resume = take_v2_frame(transport.outgoing)

    transport.inject_raw(%({"jsonrpc":"2.0","id":#{close["id"].to_json},"result":{}}))
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{resume["id"].to_json},"result":{}}))
    2.times { take_v2_frame(completed) }
    session.closed?.should be_true
    client.session_id.should eq("s")
  ensure
    client.try(&.close)
  end

  it "keeps a v2 stdio list page when an invalid archive flag exceeds Int64" do
    reader, feed = IO.pipe
    outgoing, writer = IO.pipe
    outgoing.read_timeout = 2.seconds
    client = ACP::V2::Client.new(ACP::StdioTransport.new(reader, writer))
    client.request_timeout = 2.0
    spawn do
      {
        %({"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"archive":{}}}}),
        %({"sessions":[{"sessionId":"s","cwd":"/work","archived":18446744073709551615}],"nextCursor":"page2"}),
      }.each do |result|
        break unless line = outgoing.gets

        id = JSON.parse(line)["id"]
        feed.puts %({"jsonrpc":"2.0","id":#{id.to_json},"result":#{result}})
      end
    end
    client.initialize_connection
    page = client.session_list(ACP::Protocol::V2::SessionListParams.new(archived: "include"))
    page.sessions.first.session_id.should eq("s")
    page.sessions.first.archived.should be_nil
    page.next_cursor.should eq("page2")
  ensure
    client.try(&.close)
    feed.try(&.close)
    outgoing.try(&.close)
  end

  it "blocks archive operations and list filters unless advertised" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"archive":true}}})
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    expect_raises(ACP::InvalidStateError, /session.archive/) { client.session_archive("s") }
    expect_raises(ACP::InvalidStateError, /session.archive/) { client.session_unarchive("s") }
    expect_raises(ACP::InvalidStateError, /session.archive/) do
      client.session_list(ACP::Protocol::V2::SessionListParams.new(archived: "exclude"))
    end
    transport.sent_messages.size.should eq(1)
  ensure
    client.try(&.close)
  end

  it "revokes v2 runtime and descendant control on a successful archive" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"archive":{}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"root"})
    transport.replies["session/archive"] = %("result":{})
    transport.replies["session/unarchive"] = %("result":{})
    client = ACP::V2::Client.new(transport)
    updates = Channel(Nil).new(1)
    client.on_update = ->(_note : ACP::Protocol::V2::SessionUpdateParams) do
      updates.send(nil)
      nil
    end
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    client.session_new("/work")
    take_v2_frame(transport.outgoing)
    transport.update("root", %({"sessionUpdate":"subagent_update","sessionId":"child","capabilities":{"cancel":{}}}))
    take_v2_frame(updates)
    client.session_workspace("child").not_nil!.cwd.should eq("/work")
    client.subagent("child").not_nil!.cancel?.should be_true
    expect_raises(ACP::InvalidStateError) { client.session_archive("child") }

    client.session_archive("root")
    take_v2_frame(transport.outgoing)["method"].should eq("session/archive")
    client.subagent("child").not_nil!.cancel?.should be_false
    client.session_workspace("root").should be_nil
    client.session_unarchive("root")
    take_v2_frame(transport.outgoing)["method"].should eq("session/unarchive")
    client.session_workspace("root").should be_nil
  ensure
    client.try(&.close)
  end
end

describe "ACP draft session cursors" do
  it "decodes all known anchor types and keeps unknown positions open" do
    {
      "user_message"    => "messageId",
      "agent_message"   => "messageId",
      "agent_thought"   => "messageId",
      "session_message" => "messageId",
      "tool_call"       => "toolCallId",
      "compaction"      => "compactionId",
    }.each do |kind, key|
      anchor = ACP::Protocol::CursorAnchor.from_json(%({"type":#{kind.to_json},#{key.to_json}:"entity","position":"after"}))
      anchor.entity_id.should eq("entity")
      anchor.known_position?.should be_true
      expect_raises(JSON::ParseException) do
        ACP::Protocol::CursorAnchor.from_json(%({"type":#{kind.to_json},#{key.to_json}:true,"position":"after"}))
      end
    end
    future = ACP::Protocol::CursorAnchor.from_json(%({"type":"_future","position":{},"quantity":18446744073709551615}))
    future.known_position?.should be_false
    future.raw_field("quantity").should eq("18446744073709551615")
    side = ACP::Protocol::CursorAnchor.from_json(%({"type":"tool_call","toolCallId":"t","position":"_future"}))
    side.entity_id.should eq("t")
    side.position.should eq("_future")
    side.known_position?.should be_false
  end

  it "distinguishes omitted, null, malformed, and replacement fields" do
    malformed = ACP::Protocol::CursorUpdate.from_json(%({"sessionUpdate":"cursor_update","cursorId":"c","capabilities":true,"_meta":[]}))
    malformed.capabilities_present?.should be_false
    malformed.meta_present?.should be_false
    invalid_fork = ACP::Protocol::CursorUpdate.from_json(%({"sessionUpdate":"cursor_update","cursorId":"c","capabilities":{"fork":true}}))
    invalid_fork.capabilities_present?.should be_true
    invalid_fork.capabilities.not_nil!.fork.should be_nil
    clear = ACP::Protocol::CursorUpdate.new("c")
    clear.capabilities = nil
    clear.meta = nil
    wire = JSON.parse(clear.to_json)
    wire["capabilities"].raw.should be_nil
    wire["_meta"].raw.should be_nil
    parsed = ACP::Protocol::SessionUpdate.from_json(clear.to_json).as(ACP::Protocol::CursorUpdate)
    parsed.capabilities_present?.should be_true
    parsed.meta_present?.should be_true
  end

  it "advertises v1 cursor support and tracks patches in session order" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1})
    capabilities = ACP::Protocol::ClientCapabilities.new(session: ACP::Protocol::ClientSessionCapabilities.new(cursors: ACP::Protocol::SessionCursorsCapabilities.new))
    client = ACP::Client.new(transport, client_capabilities: capabilities)
    client.initialize_connection
    take_v2_frame(transport.outgoing)["params"]["clientCapabilities"]["session"]["cursors"].should eq(JSON.parse("{}"))

    seen = Channel(ACP::SessionCursor?).new(1)
    client.on_update = ->(note : ACP::Protocol::SessionUpdateParams) do
      update = note.update.as(ACP::Protocol::CursorUpdate)
      seen.send(client.session_cursor(note.session_id, update.cursor_id))
      nil
    end
    transport.update("s", %({"sessionUpdate":"cursor_update","cursorId":"c","anchor":{"type":"agent_message","messageId":"a","position":"after"},"capabilities":{"fork":{}},"_meta":{"one":1}}))
    report = take_v2_frame(seen).not_nil!
    report.fork?.should be_true
    report.anchor.not_nil!.entity_id.should eq("a")
    transport.update("s", %({"sessionUpdate":"cursor_update","cursorId":"c","anchor":{"type":"tool_call","toolCallId":"b","position":"before"},"_meta":{"two":2}}))
    report = take_v2_frame(seen).not_nil!
    report.anchor.not_nil!.entity_id.should eq("a")
    report.fork?.should be_true
    report.meta.not_nil!.keys.should eq(["two"])
    report.anchor.not_nil!.json_unmapped["messageId"] = JSON::Any.new("modified locally")
    client.session_cursor("s", "c").not_nil!.anchor.not_nil!.entity_id.should eq("a")
    client.session_cursor("other", "c").should be_nil

    transport.update("s", %({"sessionUpdate":"cursor_update","cursorId":"c","capabilities":null}))
    take_v2_frame(seen).not_nil!.fork?.should be_false
    ACP::Session.new(client, "s").cursors.map(&.cursor_id).should eq(["c"])
  ensure
    client.try(&.close)
  end

  it "ignores unadvertised v1 cursor updates" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1})
    client = ACP::Client.new(transport)
    client.initialize_connection
    updates = Channel(String).new(2)
    client.on_update = ->(note : ACP::Protocol::SessionUpdateParams) do
      updates.send(note.update.session_update)
      nil
    end
    transport.update("s", %({"sessionUpdate":"cursor_update","cursorId":"c","capabilities":{"fork":{}}}))
    transport.update("s", %({"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"after"}}))
    take_v2_frame(updates).should eq("agent_message_chunk")
    client.session_cursors("s").should be_empty
  ensure
    client.try(&.close)
  end

  it "keeps v2 cursor capability and top-level metadata patches distinct" do
    transport = V2TestTransport.new
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    seen = Channel(ACP::SessionCursor?).new(1)
    client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
      update = note.update.typed.as(ACP::Protocol::V2::CursorUpdate)
      seen.send(client.session_cursor(note.session_id, update.cursor_id))
      nil
    end
    transport.update("s", %({"sessionUpdate":"cursor_update","cursorId":"c","anchor":{"type":"_future","position":"_later"},"capabilities":{"fork":{}},"_meta":{"keep":1,"drop":2,"nested":{"old":true}}}))
    take_v2_frame(seen).not_nil!.fork?.should be_true
    transport.update("s", %({"sessionUpdate":"cursor_update","cursorId":"c","capabilities":{},"_meta":{"drop":null,"nested":{"new":true}}}))
    report = take_v2_frame(seen).not_nil!
    report.anchor.not_nil!.known_position?.should be_false
    report.fork?.should be_false
    report.meta.should eq(JSON.parse(%({"keep":1,"nested":{"new":true}})).as_h)
  ensure
    client.try(&.close)
  end

  it "preserves future capabilities and exact metadata beside a deletion over v2 stdio" do
    reader, feed = IO.pipe
    outgoing, writer = IO.pipe
    outgoing.read_timeout = 2.seconds
    client = ACP::V2::Client.new(ACP::StdioTransport.new(reader, writer))
    client.request_timeout = 2.0
    seen = Channel(ACP::SessionCursor).new(2)
    client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
      update = note.update.typed.as(ACP::Protocol::V2::CursorUpdate)
      seen.send(client.session_cursor(note.session_id, update.cursor_id).not_nil!)
      nil
    end
    spawn do
      if line = outgoing.gets
        id = JSON.parse(line)["id"]
        feed.puts %({"jsonrpc":"2.0","id":#{id.to_json},"result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}}})
      end
    end
    client.initialize_connection
    nested = "[" * 120 + "true" + "]" * 120
    feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"cursor_update","cursorId":"c","capabilities":{"_future":{"count":18446744073709551615},"_nested":#{nested}},"_meta":{"drop":true,"keep":1}}}})
    first = take_v2_frame(seen)
    first.capabilities.not_nil!.raw_field("_future").should eq(%({"count":18446744073709551615}))
    value = first.capabilities.not_nil!.json_unmapped["_nested"]
    120.times { value = value[0] }
    value.as_bool.should be_true

    feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"cursor_update","cursorId":"c","_meta":{"drop":null,"counter":18446744073709551615}}}})
    second = take_v2_frame(seen)
    second.meta.should eq({"keep" => JSON::Any.new(1_i64)})
    second.raw_meta_field("counter").should eq("18446744073709551615")
  ensure
    client.try(&.close)
    feed.try(&.close)
    outgoing.try(&.close)
  end

  it "publishes post-marker live v2 changes even when resume fails" do
    transport = V2TestTransport.new
    transport.replies["session/resume"] = %("result":{})
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    announcement = %({"sessionUpdate":"cursor_update","cursorId":"c","anchor":{"type":"user_message","messageId":"old","position":"before"},"capabilities":{"fork":{}},"_meta":{"previous":true}})
    transport.update("s", announcement)
    client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("s", "/work"))
    client.session_cursor("s", "c").not_nil!.anchor.not_nil!.entity_id.should eq("old")
    transport.replies["session/resume"] = %("error":{"code":-32603,"message":"Attach failed"})
    transport.before_reply = ->(method : String) do
      if method == "session/resume"
        # The first frame may have been sent before the Agent saw the request.
        transport.update("s", announcement)
        transport.update("s", %({"sessionUpdate":"cursor_update","cursorId":"c","anchor":{"type":"user_message","messageId":"replayed","position":"before"},"capabilities":{"fork":{}}}))
        transport.update("s", %({"sessionUpdate":"cursor_update","cursorId":"c","anchor":{"type":"user_message","messageId":"conflict","position":"before"}}))
        transport.update("s", %({"sessionUpdate":"replay_complete"}))
        transport.update("s", %({"sessionUpdate":"cursor_update","cursorId":"c","capabilities":null}))
      end
      nil
    end
    params = ACP::Protocol::V2::SessionResumeParams.new("s", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start)
    expect_raises(ACP::JsonRpcError) { client.session_resume(params) }
    cursor = client.session_cursor("s", "c").not_nil!
    cursor.anchor.not_nil!.entity_id.should eq("replayed")
    cursor.meta.not_nil!["previous"].should eq(true)
    cursor.fork?.should be_false
  ensure
    client.try(&.close)
  end

  it "isolates a timed-out v2 replay until the Agent answers" do
    transport = V2TestTransport.new
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    observed = Channel(String).new(2)
    client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
      observed.send(note.update.session_update)
      nil
    end
    transport.update("s", %({"sessionUpdate":"cursor_update","cursorId":"c","capabilities":{"fork":{}}}))
    take_v2_frame(observed)

    client.request_timeout = 0.02
    params = ACP::Protocol::V2::SessionResumeParams.new("s", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.new("_partial"))
    expect_raises(ACP::RequestTimeoutError) { client.session_resume(params) }
    request = take_v2_frame(transport.outgoing)
    take_v2_frame(transport.outgoing)["method"].should eq("$/cancel_request")
    transport.update("s", %({"sessionUpdate":"cursor_update","cursorId":"c","capabilities":null}))
    take_v2_frame(observed)
    client.session_cursor("s", "c").not_nil!.fork?.should be_true

    transport.inject_raw(%({"jsonrpc":"2.0","id":#{request["id"].to_json},"error":{"code":-32800,"message":"Cancelled"}}))
    transport.update("s", %({"sessionUpdate":"notice","message":"Cancelled"}))
    take_v2_frame(observed)
    transport.replies["session/resume"] = %("result":{})
    client.request_timeout = 2.0
    client.session_resume(params)
    client.session_cursor("s", "c").not_nil!.fork?.should be_true
  ensure
    client.try(&.close)
  end

  it "preserves cursors on v1 resume and failed load, and rebuilds on successful load" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"resume":{}}}})
    transport.replies["session/resume"] = %("result":{})
    transport.replies["session/load"] = %("error":{"code":-32603,"message":"Replay failed"})
    caps = ACP::Protocol::ClientCapabilities.new(session: ACP::Protocol::ClientSessionCapabilities.new(cursors: ACP::Protocol::SessionCursorsCapabilities.new))
    client = ACP::Client.new(transport, client_capabilities: caps)
    client.initialize_connection
    old_cursor = %({"sessionUpdate":"cursor_update","cursorId":"old","anchor":{"type":"tool_call","toolCallId":"old-tool","position":"after"}})
    new_cursor = %({"sessionUpdate":"cursor_update","cursorId":"new","anchor":{"type":"tool_call","toolCallId":"new-tool","position":"after"}})
    transport.update("s", old_cursor)
    client.session_resume("s", "/work")
    client.session_cursors("s").map(&.cursor_id).should eq(["old"])
    transport.before_reply = ->(method : String) do
      transport.update("s", new_cursor) if method == "session/load"
      nil
    end
    expect_raises(ACP::JsonRpcError) { client.session_load("s", "/work") }
    client.session_cursors("s").map(&.cursor_id).should eq(["old"])
    transport.replies["session/load"] = %("result":{})
    client.session_load("s", "/work")
    client.session_cursors("s").map(&.cursor_id).should eq(["new"])
  ensure
    client.try(&.close)
  end

  it "rebuilds v2 full replay cursors for the root and announced children" do
    transport = V2TestTransport.new
    transport.replies["session/resume"] = %("result":{})
    transport.replies["session/close"] = %("result":{})
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    transport.update("root", %({"sessionUpdate":"subagent_update","sessionId":"child"}))
    transport.update("root", %({"sessionUpdate":"cursor_update","cursorId":"keep","anchor":{"type":"user_message","messageId":"old","position":"after"}}))
    transport.update("root", %({"sessionUpdate":"cursor_update","cursorId":"removed"}))
    transport.update("child", %({"sessionUpdate":"cursor_update","cursorId":"child-old"}))
    client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("root", "/work"))
    client.session_cursors("root").size.should eq(2)
    client.session_close("root")
    client.session_cursors("root").size.should eq(2)
    transport.before_reply = ->(method : String) do
      if method == "session/resume"
        transport.update("root", %({"sessionUpdate":"subagent_update","sessionId":"child"}))
        transport.update("root", %({"sessionUpdate":"cursor_update","cursorId":"keep","anchor":{"type":"user_message","messageId":"new","position":"after"}}))
        transport.update("child", %({"sessionUpdate":"replay_complete"}))
        transport.update("root", %({"sessionUpdate":"replay_complete"}))
      end
      nil
    end
    client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("root", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start))
    client.session_cursors("root").map(&.cursor_id).should eq(["keep"])
    client.session_cursor("root", "keep").not_nil!.anchor.not_nil!.entity_id.should eq("new")
    client.session_cursors("child").should be_empty
  ensure
    client.try(&.close)
  end
end

describe "ACP draft session options" do
  it "previews v1 modes and configuration without switching the active session" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"options":{}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"active","configOptions":[{"id":"model","name":"Model","type":"select","currentValue":"fast","options":[]}]})
    transport.replies["session/options"] = %("result":{"modes":{"currentModeId":"review","availableModes":[{"id":"review","name":"Review"}]},"configOptions":[null,{"id":"model","name":"Model","type":"select","currentValue":"large","options":[]}],"_meta":{"example.test/source":"saved"}})
    client = ACP::Client.new(transport)
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    client.session_new("/work")
    take_v2_frame(transport.outgoing)["params"].as_h.has_key?("configOptions").should be_false

    preview = ACP::Session.new(client, "saved").options("/work", additional_directories: ["/shared"])
    preview.modes.not_nil!.current_mode_id.should eq("review")
    preview.config_options.not_nil!.map(&.current_value).should eq(["large"])
    preview.meta.not_nil!["example.test/source"].should eq("saved")
    client.session_id.should eq("active")
    client.session_config_options.not_nil!.map(&.current_value).should eq(["fast"])
    wire = take_v2_frame(transport.outgoing)
    wire["method"].should eq("session/options")
    wire["params"].should eq(JSON.parse(%({"cwd":"/work","sessionId":"saved","additionalDirectories":["/shared"]})))
  ensure
    client.try(&.close)
  end

  it "allows v1 previews of saved sessions with any advertised restore or fork method" do
    {
      { %(,"loadSession":true), "" },
      {"", %(,"resume":{})},
      {"", %(,"fork":{})},
    }.each do |(root, nested)|
      transport = V2TestTransport.new
      transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"options":{}#{nested}}#{root}}})
      transport.replies["session/options"] = %("error":{"code":-32002,"message":"Unknown session"})
      client = ACP::Client.new(transport)
      begin
        client.initialize_connection
        error = expect_raises(ACP::JsonRpcError) { client.session_options(ACP::Protocol::SessionOptionsParams.new("/work", session_id: "unknown")) }
        error.resource_not_found?.should be_true
        transport.sent_messages.size.should eq(2)
      ensure
        client.close
      end
    end
  end

  it "requires v1 support for saved-session previews and advertised boolean choices" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"options":{}}}})
    client = ACP::Client.new(transport)
    client.initialize_connection
    expect_raises(ACP::InvalidStateError, /load, resume, or fork/) do
      client.session_options(ACP::Protocol::SessionOptionsParams.new("/work", session_id: "s"))
    end
    expect_raises(ArgumentError, /absolute/) do
      client.session_options(ACP::Protocol::SessionOptionsParams.new("/work", additional_directories: ["relative"]))
    end
    expect_raises(ACP::InvalidStateError, /boolean/) do
      client.session_new("/work", config_options: [ACP::Protocol::InitialSessionConfigOption.new("reviews", false)])
    end
    transport.sent_messages.size.should eq(1)
  ensure
    client.try(&.close)
  end

  it "forwards v1 options through create, load, and resume in list order" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"options":{},"resume":{}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"new"})
    transport.replies["session/load"] = %("result":{})
    transport.replies["session/resume"] = %("result":{})
    config_caps = ACP::Protocol::SessionConfigOptionsCapabilities.new(boolean: ACP::Protocol::BooleanConfigOptionCapabilities.new)
    caps = ACP::Protocol::ClientCapabilities.new(session: ACP::Protocol::ClientSessionCapabilities.new(config_options: config_caps))
    client = ACP::Client.new(transport, client_capabilities: caps)
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    choices = [ACP::Protocol::InitialSessionConfigOption.new("model", "large"), ACP::Protocol::InitialSessionConfigOption.new("review", false)]
    expected = JSON.parse(%([{"configId":"model","value":"large"},{"configId":"review","type":"boolean","value":false}]))
    ACP::Session.create(client, "/work", config_options: choices)
    take_v2_frame(transport.outgoing)["params"]["configOptions"].should eq(expected)
    ACP::Session.load(client, "saved", "/work", config_options: choices)
    take_v2_frame(transport.outgoing)["params"]["configOptions"].should eq(expected)
    client.session_resume("saved", "/work", config_options: choices)
    take_v2_frame(transport.outgoing)["params"]["configOptions"].should eq(expected)
    expect_raises(ArgumentError, /unique/) { client.session_new("/work", config_options: [choices.first, choices.first]) }
    transport.sent_messages.size.should eq(4)
  ensure
    client.try(&.close)
  end

  it "previews v2 commands and forwards typed initial choices to new and resume" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"options":{}}}})
    transport.replies["session/options"] = %("result":{"configOptions":[false,{"configId":"review","name":"Review mode","type":"boolean","currentValue":false}],"availableCommands":[{"type":"command","name":"review","description":"Review changes"}]})
    transport.replies["session/new"] = %("result":{"sessionId":"new"})
    transport.replies["session/resume"] = %("result":{})
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    preview = client.session_options(ACP::Protocol::V2::SessionOptionsParams.new("C:/repo", session_id: "saved"))
    take_v2_frame(transport.outgoing)["params"]["sessionId"].should eq("saved")
    preview.typed_config_options.first.boolean_value.should be_false
    preview.typed_available_commands.first.name.should eq("review")
    client.session_workspace("saved").should be_nil

    custom = ACP::Protocol::V2::InitialSessionConfigOption.new("custom", "_future", JSON.parse(%({"selected":true})))
    choices = [ACP::Protocol::V2::InitialSessionConfigOption.new("model", "large"), ACP::Protocol::V2::InitialSessionConfigOption.new("review", false), custom]
    expected = JSON.parse(%([{"configId":"model","type":"id","value":"large"},{"configId":"review","type":"boolean","value":false},{"configId":"custom","type":"_future","value":{"selected":true}}]))
    client.session_new("C:/repo", config_options: choices)
    take_v2_frame(transport.outgoing)["params"]["configOptions"].should eq(expected)
    client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("saved", "C:/repo", config_options: choices))
    take_v2_frame(transport.outgoing)["params"]["configOptions"].should eq(expected)
  ensure
    client.try(&.close)
  end

  it "gates v1 and v2 preview and setup options on the capability" do
    v1_transport = V2TestTransport.new
    v1_transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"options":false}}})
    v1 = ACP::Client.new(v1_transport)
    v1.initialize_connection
    expect_raises(ACP::InvalidStateError, /options/) { v1.session_options("/work") }
    expect_raises(ACP::InvalidStateError, /options/) { v1.session_new("/work", config_options: [] of ACP::Protocol::InitialSessionConfigOption) }
    v1_transport.sent_messages.size.should eq(1)

    v2_transport = V2TestTransport.new
    v2 = ACP::V2::Client.new(v2_transport)
    v2.initialize_connection
    expect_raises(ACP::InvalidStateError, /options/) { v2.session_options("/work") }
    expect_raises(ACP::InvalidStateError, /options/) { v2.session_new("/work", config_options: [] of ACP::Protocol::V2::InitialSessionConfigOption) }
    v2_transport.sent_messages.size.should eq(1)
  ensure
    v1.try(&.close)
    v2.try(&.close)
  end

  it "defaults invalid optional snapshots and rejects malformed initial values" do
    v1 = ACP::Protocol::SessionOptionsResult.from_json(%({"modes":true,"configOptions":[]}))
    v1.modes.should be_nil
    v1.config_options.not_nil!.should be_empty
    ACP::Protocol::SessionOptionsResult.from_json(%({"configOptions":true})).config_options.should be_nil
    malformed = ACP::Protocol::SessionOptionsResult.from_json(%({"configOptions":[{"id":"invalid","name":"Invalid","type":"select","currentValue":"missing"}]}))
    malformed.config_options.not_nil!.should be_empty
    v2 = ACP::Protocol::V2::SessionOptionsResult.from_json(%({"availableCommands":null,"configOptions":true}))
    v2.available_commands.should be_empty
    v2.config_options.should be_empty
    options = ACP::Protocol::V2::SessionOptionsResult.from_json(%({"configOptions":[{"configId":"bad","name":"Bad","type":"boolean","currentValue":"yes"},{"configId":"missing","name":"Missing","type":"select","currentValue":"x"},{"configId":"future","name":"Future","type":"_future","currentValue":{"label":"One"}}]}))
    options.typed_config_options.map(&.config_id).should eq(["future"])
    reference = ACP::Protocol::V2::SessionOptionsResult.from_json(%({"configOptions":[{"configId":"model","name":"Model","type":"select","currentValue":"small","options":[{"value":"small","name":"Small","description":false,"_meta":true}]}]}))
    value = reference.typed_config_options.first.select_options.as(Array(ACP::Protocol::ConfigOptionValue)).first
    value.value.should eq("small")
    value.description.should be_nil
    value.meta.should be_nil
    expect_raises(JSON::ParseException) do
      ACP::Protocol::InitialSessionConfigOption.from_json(%({"configId":"review","value":false}))
    end
    expect_raises(JSON::ParseException) do
      ACP::Protocol::V2::InitialSessionConfigOption.from_json(%({"configId":"review","type":"boolean","value":"yes"}))
    end
    expect_raises(JSON::ParseException) do
      ACP::Protocol::V2::InitialSessionConfigOption.from_json(%({"configId":"model","value":"small"}))
    end
  end

  it "leaves the active v1 config cache intact after a malformed setter response" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1})
    transport.replies["session/new"] = %("result":{"sessionId":"s","configOptions":[{"id":"model","name":"Model","type":"select","currentValue":"fast","options":[{"value":"fast","name":"Fast"}]}]})
    transport.replies["session/set_config_option"] = %("result":{"configOptions":true})
    client = ACP::Client.new(transport)
    client.initialize_connection
    client.session_new("/work")
    expect_raises(ACP::ProtocolError) { client.session_set_config_option("model", "fast") }
    client.session_config_options.not_nil!.first.current_value.should eq("fast")
  ensure
    client.try(&.close)
  end

  it "commits successful v1 and v2 setup responses with malformed wide list entries over stdio" do
    {"v1", "v2"}.each do |version|
      reader, feed = IO.pipe
      outgoing, writer = IO.pipe
      outgoing.read_timeout = 2.seconds
      transport = ACP::StdioTransport.new(reader, writer)
      config_caps = ACP::Protocol::SessionConfigOptionsCapabilities.new(boolean: ACP::Protocol::BooleanConfigOptionCapabilities.new)
      caps = ACP::Protocol::ClientCapabilities.new(session: ACP::Protocol::ClientSessionCapabilities.new(config_options: config_caps))
      client = version == "v1" ? ACP::Client.new(transport, client_capabilities: caps) : ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      begin
        spawn do
          initialize_result = if version == "v1"
                                %({"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"resume":{}}}})
                              else
                                %({"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
                              end
          created_result = if version == "v1"
                             %({"sessionId":"s","_meta":{"counter":18446744073709551615},"configOptions":[18446744073709551615,{"id":"review","name":"Review","type":"boolean","currentValue":false}]})
                           else
                             nested = "[" * 120 + "true" + "]" * 120
                             %({"sessionId":"s","_meta":{"nested":#{nested}},"configOptions":[{"configId":"review","name":"Review","type":"boolean","currentValue":false}]})
                           end
          {
            initialize_result,
            created_result,
            %({"configOptions":[18446744073709551615,{"id":"review","configId":"review","name":"Review","type":"boolean","currentValue":true}]}),
          }.each do |result|
            break unless line = outgoing.gets

            id = JSON.parse(line)["id"]
            feed.puts %({"jsonrpc":"2.0","id":#{id.to_json},"result":#{result}})
          end
        end
        client.initialize_connection
        client.session_new("/work").session_id.should eq("s")
        if client.is_a?(ACP::Client)
          client.session_config_options.not_nil!.first.boolean_value.should be_false
          client.session_resume("s", "/work/restored")
          client.session_config_options.not_nil!.first.boolean_value.should be_true
        else
          result = client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("s", "/work/restored"))
          result.typed_config_options.first.boolean_value.should be_true
          client.session_workspace("s").not_nil!.cwd.should eq("/work/restored")
        end
      ensure
        client.close
        feed.close
        outgoing.close
      end
    end
  end
end

private class QueuedRequestTransport < V2TestTransport
  getter queued = Channel(Nil).new(1)
  getter ready_to_write = Channel(Nil).new
  property pause_initialize = false
  property pause_only : String?
  getter queued_message : JSON::Any?

  def send_checked(message : Hash(String, JSON::Any), &preflight : -> Nil) : Nil
    method = message["method"]?.try(&.as_s?)
    if (@pause_initialize || method != "initialize") && (!@pause_only || @pause_only == method)
      @queued_message = JSON::Any.new(message)
      @queued.send(nil)
      @ready_to_write.receive
    end
    super(message, &preflight)
  end
end

private def mode_from_fixture_extension(mode : String, advertised : ACP::Protocol::SessionSystemPromptCapabilities) : Bool
  names = advertised.meta.try(&.["example.com/modes"]?).try(&.as_a?)
  !!names.try(&.any? { |value| value.as_s? == mode })
end

describe "ACP draft session fork" do
  it "uses the same optional cursor wire shape on v1 and v2" do
    {
      ACP::Protocol::SessionForkParams,
      ACP::Protocol::V2::SessionForkParams,
    }.each do |type|
      params = type.from_json(%({"sessionId":"parent","cwd":"/work","cursorId":null}))
      params.cursor_id.should be_nil
      JSON.parse(params.to_json).should eq(JSON.parse(%({"sessionId":"parent","cwd":"/work"})))
      expect_raises(JSON::ParseException) do
        type.from_json(%({"sessionId":"parent","cwd":"/work","cursorId":123}))
      end
    end
  end

  it "sets the v1 fork active in wire order and forwards initial choices from Session" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"fork":{},"options":{},"additionalDirectories":{},"systemPrompt":{"_meta":{"example.com/modes":["_concise"]}}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"source"})
    transport.replies["session/fork"] = %("result":{"sessionId":"forked","configOptions":[{"id":"model","name":"Model","type":"select","currentValue":"large","options":[]}]})
    transport.replies["session/prompt"] = %("result":{"stopReason":"end_turn"})
    client = ACP::Client.new(transport)
    client.on_system_prompt_mode = ->mode_from_fixture_extension(String, ACP::Protocol::SessionSystemPromptCapabilities)
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    source = ACP::Session.create(client, "/work")
    take_v2_frame(transport.outgoing)
    prompt = ACP::Protocol::SystemPrompt.new("_concise", [ACP::Protocol::TextContentBlock.new("Keep it short.").as(ACP::Protocol::ContentBlock)])
    choices = [ACP::Protocol::InitialSessionConfigOption.new("model", "large"), ACP::Protocol::InitialSessionConfigOption.new("mode", "review")]
    forked = source.fork("/tree", additional_directories: ["/shared"], config_options: choices, system_prompt: prompt)

    forked.id.should eq("forked")
    forked.config_options.not_nil!.first.current_value.should eq("large")
    source.closed?.should be_false
    source.id.should eq("source")
    client.session_id.should eq("forked")
    wire = take_v2_frame(transport.outgoing)
    wire["method"].should eq("session/fork")
    wire["params"].should eq(JSON.parse(%({"sessionId":"source","cwd":"/tree","additionalDirectories":["/shared"],"systemPrompt":{"mode":"_concise","content":[{"type":"text","text":"Keep it short."}]},"configOptions":[{"configId":"model","value":"large"},{"configId":"mode","value":"review"}]})))
    client.session_prompt_text("Hello")
    take_v2_frame(transport.outgoing)["params"]["sessionId"].should eq("forked")
  ensure
    client.try(&.close)
  end

  it "forks a v2 cursor with a distinct workspace and cursors" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"fork":{},"options":{},"additionalDirectories":{},"systemPrompt":{"_meta":{"example.com/modes":["_concise"]}}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"source"})
    transport.replies["session/fork"] = %("result":{"sessionId":"forked","availableCommands":[{"type":"command","name":"review","description":"Review the fork"}]})
    transport.replies["session/prompt"] = %("result":{"messageId":"prompt"})
    client = ACP::V2::Client.new(transport)
    client.on_system_prompt_mode = ->mode_from_fixture_extension(String, ACP::Protocol::SessionSystemPromptCapabilities)
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    prompt = ACP::Protocol::SystemPrompt.new("_concise", [ACP::Protocol::TextContentBlock.new("Keep it short.").as(ACP::Protocol::ContentBlock)])
    client.session_new(ACP::Protocol::V2::SessionNewParams.new("/source", system_prompt: prompt))
    take_v2_frame(transport.outgoing)["params"]["systemPrompt"]["mode"].should eq("_concise")
    seen = Channel(String).new(2)
    client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
      seen.send(note.update.session_update)
      nil
    end
    transport.update("source", %({"sessionUpdate":"cursor_update","cursorId":"c","anchor":{"type":"agent_message","messageId":"m","position":"after"},"capabilities":{"fork":{}}}))
    transport.update("source", %({"sessionUpdate":"subagent_update","sessionId":"child","capabilities":{"cancel":{}}}))
    take_v2_frame(seen).should eq("cursor_update")
    take_v2_frame(seen).should eq("subagent_update")
    expect_raises(ACP::InvalidStateError, /Cursor/) { client.session_fork("different", "/fork", cursor_id: "c") }
    expect_raises(ACP::InvalidStateError, /child/) { client.session_fork("child", "/fork") }

    choices = [ACP::Protocol::V2::InitialSessionConfigOption.new("fast", false)]
    params = ACP::Protocol::V2::SessionForkParams.new("source", "/fork", cursor_id: "c", additional_directories: ["/extra"], config_options: choices, system_prompt: prompt)
    result = client.session_fork(params)
    result.session_id.should eq("forked")
    result.typed_available_commands.first.name.should eq("review")
    wire = take_v2_frame(transport.outgoing)
    wire["method"].should eq("session/fork")
    wire["params"].should eq(JSON.parse(%({"sessionId":"source","cwd":"/fork","cursorId":"c","additionalDirectories":["/extra"],"configOptions":[{"configId":"fast","type":"boolean","value":false}],"systemPrompt":{"mode":"_concise","content":[{"type":"text","text":"Keep it short."}]}})))
    client.session_workspace("source").not_nil!.cwd.should eq("/source")
    client.session_workspace("forked").not_nil!.cwd.should eq("/fork")
    client.session_cursor("source", "c").not_nil!.fork?.should be_true
    client.session_cursors("forked").should be_empty
    client.subagent("child").not_nil!.cancel?.should be_true
    client.session_prompt_text(result.session_id, "Hello").message_id.should eq("prompt")
    take_v2_frame(transport.outgoing)["params"]["sessionId"].should eq("forked")
  ensure
    client.try(&.close)
  end

  it "revokes only the cursor grant rejected by the Agent" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"fork":{}}}})
    transport.replies["session/fork"] = %("error":{"code":-32602,"message":"Cursor has expired","data":{"cursorId":"c"}})
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    seen = Channel(Nil).new(2)
    client.on_update = ->(_note : ACP::Protocol::V2::SessionUpdateParams) do
      seen.send(nil)
      nil
    end
    grant_update = %({"sessionUpdate":"cursor_update","cursorId":"c","capabilities":{"fork":{},"_future":{"enabled":true}}})
    transport.update("source", grant_update)
    take_v2_frame(seen)
    # A fresh grant can arrive before the rejection of an earlier request.
    transport.before_reply = ->(method : String) do
      transport.update("source", grant_update) if method == "session/fork"
      nil
    end
    error = expect_raises(ACP::JsonRpcError) { client.session_fork("source", "/work", cursor_id: "c") }
    error.invalid_params?.should be_true
    error.data.not_nil!["cursorId"].should eq("c")
    take_v2_frame(transport.outgoing)
    take_v2_frame(seen)
    client.session_cursor("source", "c").not_nil!.fork?.should be_true

    transport.before_reply = nil
    expect_raises(ACP::JsonRpcError) { client.session_fork("source", "/work", cursor_id: "c") }
    take_v2_frame(transport.outgoing)
    cursor = client.session_cursor("source", "c").not_nil!
    cursor.fork?.should be_false
    cursor.capabilities.not_nil!.json_unmapped["_future"]["enabled"].should eq(true)
    expect_raises(ACP::InvalidStateError, /Cursor/) { client.session_fork("source", "/work", cursor_id: "c") }
    transport.sent_messages.size.should eq(3)
  ensure
    client.try(&.close)
  end

  it "keeps v1 cursor forks opt-in and rejects unsupported setup features" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"fork":{}}}})
    client = ACP::Client.new(transport)
    client.initialize_connection
    expect_raises(ACP::InvalidStateError, /Cursor/) { client.session_fork("source", "/work", cursor_id: "unknown") }
    expect_raises(ArgumentError, /absolute/) { client.session_fork("source", "relative") }
    expect_raises(ACP::InvalidStateError, /additionalDirectories/) do
      client.session_fork(ACP::Protocol::SessionForkParams.new("source", "/work", additional_directories: ["/extra"]))
    end
    expect_raises(ACP::InvalidStateError, /options/) do
      config = [ACP::Protocol::InitialSessionConfigOption.new("model", "large")]
      client.session_fork(ACP::Protocol::SessionForkParams.new("source", "/work", config_options: config))
    end
    expect_raises(ACP::InvalidStateError, /MCP HTTP/) do
      servers = [JSON.parse(%({"type":"http","name":"helper","url":"https://example.test/mcp","headers":[]}))]
      client.session_fork(ACP::Protocol::SessionForkParams.new("source", "/work", mcp_servers: servers))
    end
    transport.sent_messages.size.should eq(1)
  ensure
    client.try(&.close)
  end

  it "rejects v2 fork attempts when the Agent omits the fork marker" do
    transport = V2TestTransport.new
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    expect_raises(ACP::InvalidStateError, /session.fork/) { client.session_fork("source", "/work") }
    transport.sent_messages.size.should eq(1)
  ensure
    client.try(&.close)
  end

  it "rejects a fork response that returns the source ID without changing its workspace" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"fork":{}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"source"})
    transport.replies["session/fork"] = %("result":{"sessionId":"source"})
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    client.session_new("/source")
    expect_raises(ACP::ProtocolError, /source session ID/) { client.session_fork("source", "/fork") }
    client.session_workspace("source").not_nil!.cwd.should eq("/source")
  ensure
    client.try(&.close)
  end

  it "keeps existing v1 sessions active and v2 child payloads scoped after reused IDs" do
    v1_transport = V2TestTransport.new
    v1_transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"fork":{}}}})
    v1_transport.replies["session/new"] = %("result":{"sessionId":"existing"})
    v1_transport.replies["session/fork"] = %("result":{"sessionId":"existing"})
    v1 = ACP::Client.new(v1_transport)
    v1.initialize_connection
    v1.session_new("/old")
    v1_transport.replies["session/new"] = %("result":{"sessionId":"source"})
    v1.session_new("/source")
    expect_raises(ACP::ProtocolError, /existing session ID/) { v1.session_fork("source", "/fork") }
    v1.session_id.should eq("source")

    v2_transport = V2TestTransport.new
    v2_transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"fork":{}}}})
    v2_transport.replies["session/new"] = %("result":{"sessionId":"source"})
    v2_transport.replies["session/fork"] = %("result":{"sessionId":"child"})
    v2 = ACP::V2::Client.new(v2_transport)
    v2.initialize_connection
    v2.session_new("/source")
    v2_transport.update("source", %({"sessionUpdate":"subagent_update","sessionId":"child","cwd":"/child"}))
    expect_raises(ACP::ProtocolError, /existing session ID/) { v2.session_fork("source", "/fork") }
    v2.session_workspace("child").not_nil!.cwd.should eq("/child")
    v2.subagent("child").not_nil!.parent_session_id.should eq("source")
  ensure
    v1.try(&.close)
    v2.try(&.close)
  end

  it "rechecks the cursor grant when a queued fork reaches the writer" do
    transport = QueuedRequestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"fork":{}}}})
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    seen = Channel(Nil).new(1)
    client.on_update = ->(_note : ACP::Protocol::V2::SessionUpdateParams) do
      seen.send(nil)
      nil
    end
    transport.update("source", %({"sessionUpdate":"cursor_update","cursorId":"c","capabilities":{"fork":{}}}))
    take_v2_frame(seen)
    rejected = Channel(Exception?).new(1)
    spawn do
      client.session_fork("source", "/work", cursor_id: "c")
      rejected.send(nil)
    rescue ex
      rejected.send(ex)
    end
    take_v2_frame(transport.queued)
    transport.update("source", %({"sessionUpdate":"cursor_update","cursorId":"c","capabilities":null}))
    take_v2_frame(seen)
    transport.ready_to_write.send(nil)
    take_v2_frame(rejected).should be_a(ACP::InvalidStateError)
    transport.sent_messages.size.should eq(1)
  ensure
    transport.try(&.ready_to_write.close)
    client.try(&.close)
  end

  it "leaves untracked cursor forwarding available to a v1 caller using raw requests" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"fork":{}}}})
    transport.replies["session/fork"] = %("result":{"sessionId":"forked"})
    client = ACP::Client.new(transport)
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    params = JSON.parse(%({"sessionId":"source","cwd":"/work","cursorId":"persisted"}))
    client.send_request_raw("session/fork", params)["sessionId"].should eq("forked")
    take_v2_frame(transport.outgoing)["params"].should eq(params)
  ensure
    client.try(&.close)
  end

  it "records Windows workspace roots for a v1 fork on any host" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"fork":{},"additionalDirectories":{}}}})
    transport.replies["session/fork"] = %("result":{"sessionId":"forked"})
    caps = ACP::Protocol::ClientCapabilities.new(subagents: ACP::Protocol::SubagentCapabilities.new)
    client = ACP::Client.new(transport, client_capabilities: caps)
    client.initialize_connection
    client.session_fork(ACP::Protocol::SessionForkParams.new("source", "C:/fork", additional_directories: ["C:/extra"]))
    workspace = client.session_workspace("forked").not_nil!
    workspace.cwd.should eq("C:/fork")
    workspace.additional_directories.should eq(["C:/extra"])
  ensure
    client.try(&.close)
  end
end

describe "ACP draft prompt suggestions" do
  it "negotiates nullable object capabilities in both versions" do
    {
      ACP::Protocol::ClientCapabilities,
      ACP::Protocol::V2::ClientCapabilities,
    }.each do |type|
      type.from_json(%({"session":null})).session.should be_nil
      type.from_json(%({"session":{"promptSuggestions":null}})).session.not_nil!.prompt_suggestions.should be_nil
      type.from_json(%({"session":{"promptSuggestions":true}})).session.not_nil!.prompt_suggestions.should be_nil

      wire = %({"session":{"promptSuggestions":{"image":{"_meta":{"example.test/mime":"png"}},"audio":true,"embeddedContext":{},"_meta":null}}})
      caps = type.from_json(wire)
      suggestions = caps.session.not_nil!.prompt_suggestions.not_nil!
      suggestions.image.not_nil!.meta.not_nil!["example.test/mime"].should eq("png")
      suggestions.audio.should be_nil
      suggestions.embedded_context.should_not be_nil
      JSON.parse(caps.to_json)["session"]["promptSuggestions"].should eq(
        JSON.parse(%({"image":{"_meta":{"example.test/mime":"png"}},"embeddedContext":{}})))
    end
  end

  it "decodes candidates independently and requires a replacement list" do
    wire = <<-JSON
      {"sessionUpdate":"prompt_suggestions_update","_meta":{"example.test/rank":1},"suggestions":[
        {"prompt":[{"type":"text","text":"Keep this"}],"_meta":null},
        {"prompt":[{"type":"text","text":"Must skip entire candidate"},{"type":"_unknown"}]},
        {"prompt":[{"type":"text","text":"   "}]},
        {"prompt":[]},
        {"prompt":null},
        {"prompt":[{"type":"resource","resource":false}]},
        {"prompt":[{"type":"resource","resource":18446744073709551615}]},
        null,
        {"prompt":[{"type":"resource_link","uri":"file:///work/fixture","name":"Fixture","futureField":{"key":1}}],"_meta":{"example.test/rank":2}}
      ]}
      JSON
    v1 = ACP::Protocol::SessionUpdate.from_json(wire).as(ACP::Protocol::PromptSuggestionsUpdate)
    v1.suggestions.size.should eq(2)
    v1.suggestions[0].prompt[0].as(ACP::Protocol::TextContentBlock).text.should eq("Keep this")
    v1.suggestions[1].prompt[0].as(ACP::Protocol::ResourceLinkContentBlock).uri.should eq("file:///work/fixture")
    v1.suggestions[0].meta.should be_nil
    v1.meta.not_nil!["example.test/rank"].should eq(1)

    v2 = ACP::Protocol::V2::SessionUpdate.from_json(wire).typed.as(ACP::Protocol::V2::PromptSuggestionsUpdate)
    v2.suggestions.size.should eq(2)
    v2.suggestions[1].prompt[0]["futureField"]["key"].should eq(1)
    v2.suggestions[1].meta.not_nil!["example.test/rank"].should eq(2)

    missing = %({"sessionUpdate":"prompt_suggestions_update"})
    invalid = %({"sessionUpdate":"prompt_suggestions_update","suggestions":null})
    {missing, invalid}.each do |json|
      expect_raises(JSON::ParseException) { ACP::Protocol::SessionUpdate.from_json(json) }
      ACP::Protocol::V2::SessionUpdate.from_json(json).typed.should be_nil
    end
  end

  {"v1", "v2"}.each do |version|
    it "delivers live, usable replacements and withdraws suggestions on #{version}" do
      transport = V2TestTransport.new
      nested = "[" * 115 + "null" + "]" * 115
      initial_update = <<-JSON
        {"sessionUpdate":"prompt_suggestions_update","suggestions":[
          {"prompt":[{"type":"text","text":"first"},{"type":"resource_link","uri":"file:///work/notes","name":"notes"}]},
          {"prompt":[{"type":"image","data":"YQ==","mimeType":"image/png"}]},
          {"prompt":[{"type":"text","text":"discard me"},{"type":"audio","data":"YQ==","mimeType":"audio/wav"}]},
          {"prompt":{"invalid":#{nested}}},
          {"prompt":[{"type":"resource","resource":{"uri":"file:///work/notes","text":"notes"}}]}
        ]}
        JSON
      media = ACP::Protocol::PromptSuggestionsCapabilities.new(
        image: ACP::Protocol::PromptSuggestionsImageCapabilities.new,
        audio: ACP::Protocol::PromptSuggestionsAudioCapabilities.new)
      updates = Channel(Tuple(String, JSON::Any)).new(16)
      if version == "v1"
        transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"promptCapabilities":{"image":true,"embeddedContext":true},"loadSession":true}})
        transport.replies["session/load"] = %("result":{})
        capabilities = ACP::Protocol::ClientCapabilities.new(session: ACP::Protocol::ClientSessionCapabilities.new(prompt_suggestions: media))
        client = ACP::Client.new(transport, client_capabilities: capabilities)
        client.on_update = ->(note : ACP::Protocol::SessionUpdateParams) do
          if update = note.update.as?(ACP::Protocol::PromptSuggestionsUpdate)
            updates.send({note.session_id, JSON.parse(update.to_json)["suggestions"]})
          end
          nil
        end
        setup_method = "session/load"
        handshake_group = "clientCapabilities"
      else
        transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"prompt":{"image":{},"embeddedContext":{}}}}})
        transport.replies["session/resume"] = %("result":{})
        capabilities = ACP::Protocol::V2::ClientCapabilities.new(session: ACP::Protocol::V2::ClientSessionCapabilities.new(prompt_suggestions: media))
        client = ACP::V2::Client.new(transport, capabilities: capabilities)
        client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
          if update = note.update.typed.as?(ACP::Protocol::V2::PromptSuggestionsUpdate)
            updates.send({note.session_id, JSON.parse(update.to_json)["suggestions"]})
          end
          nil
        end
        setup_method = "session/resume"
        handshake_group = "capabilities"
      end
      transport.before_reply = ->(method : String) do
        if method == setup_method
          transport.update("saved", initial_update)
          transport.update("other", initial_update)
          transport.update("saved", %({"sessionUpdate":"replay_complete"})) if version == "v2"
        end
        nil
      end
      transport.after_reply = ->(method : String) do
        transport.update("saved", initial_update) if method == setup_method
      end

      client.initialize_connection
      advertised = take_v2_frame(transport.outgoing)["params"][handshake_group]["session"]["promptSuggestions"]
      advertised.should eq(JSON.parse(%({"image":{},"audio":{}})))
      case client
      when ACP::Client
        client.session_load("saved", "/work")
      when ACP::V2::Client
        client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("saved", "/work",
          replay_from: ACP::Protocol::V2::ReplayFrom.start))
      end
      take_v2_frame(transport.outgoing)["method"].should eq(setup_method)

      other_session, other_suggestions = take_v2_frame(updates)
      other_session.should eq("other")
      main_session, suggestions = take_v2_frame(updates)
      main_session.should eq("saved")
      suggestions.should eq(other_suggestions)
      suggestions.as_a.size.should eq(2)
      suggestions[0]["prompt"][1]["type"].should eq("resource_link")
      suggestions[1]["prompt"][0]["type"].should eq("image")

      transport.update("saved", %({"sessionUpdate":"prompt_suggestions_update","suggestions":[{"prompt":[]}]}))
      take_v2_frame(updates).should eq({"saved", JSON.parse("[]")})
      transport.update("other", %({"sessionUpdate":"prompt_suggestions_update","suggestions":[]}))
      take_v2_frame(updates).should eq({"other", JSON.parse("[]")})
      transport.sent_messages.size.should eq(2)
    ensure
      client.try(&.close)
    end

    it "ignores unadvertised suggestions on #{version}" do
      transport = V2TestTransport.new
      if version == "v1"
        transport.replies["initialize"] = %("result":{"protocolVersion":1})
        client = ACP::Client.new(transport)
      else
        client = ACP::V2::Client.new(transport, capabilities: ACP::Protocol::V2::ClientCapabilities.new(
          session: ACP::Protocol::V2::ClientSessionCapabilities.new))
      end
      received = Channel(String).new(2)
      client.on_notification = ->(method : String, _params : JSON::Any?) do
        received.send(method)
        nil
      end
      client.initialize_connection
      transport.update("s", %({"sessionUpdate":"prompt_suggestions_update","suggestions":[]}))
      transport.inject_raw(%({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","_meta":true,"update":{"sessionUpdate":"prompt_suggestions_update","suggestions":[]}}}))
      transport.inject_raw(%({"jsonrpc":"2.0","method":"_fixture/barrier"}))
      take_v2_frame(received).should eq("_fixture/barrier")
    ensure
      client.try(&.close)
    end

    it "filters generic callbacks and suppresses history until a timed-out replay ends on #{version}" do
      transport = V2TestTransport.new
      media = ACP::Protocol::PromptSuggestionsCapabilities.new
      if version == "v1"
        transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true}})
        capabilities = ACP::Protocol::ClientCapabilities.new(session: ACP::Protocol::ClientSessionCapabilities.new(prompt_suggestions: media))
        client = ACP::Client.new(transport, client_capabilities: capabilities)
      else
        capabilities = ACP::Protocol::V2::ClientCapabilities.new(session: ACP::Protocol::V2::ClientSessionCapabilities.new(prompt_suggestions: media))
        client = ACP::V2::Client.new(transport, capabilities: capabilities)
      end
      received = Channel(Tuple(String, JSON::Any?)).new(4)
      client.on_notification = ->(method : String, params : JSON::Any?) do
        received.send({method, params})
        nil
      end
      client.initialize_connection
      take_v2_frame(transport.outgoing)
      client.request_timeout = 0.02
      expect_raises(ACP::RequestTimeoutError) do
        case client
        when ACP::Client
          client.session_load("s", "/work")
        when ACP::V2::Client
          client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("s", "/work",
            replay_from: ACP::Protocol::V2::ReplayFrom.start))
        end
      end
      request = take_v2_frame(transport.outgoing)
      take_v2_frame(transport.outgoing)["method"].should eq("$/cancel_request")
      transport.update("s", %({"sessionUpdate":"prompt_suggestions_update","suggestions":[]}))
      transport.inject_raw(%({"jsonrpc":"2.0","method":"_fixture/barrier"}))
      take_v2_frame(received).first.should eq("_fixture/barrier")
      transport.inject_raw(%({"jsonrpc":"2.0","id":#{request["id"].to_json},"error":{"code":-32800,"message":"Cancelled"}}))
      transport.update("s", %({"sessionUpdate":"prompt_suggestions_update","futureField":true,"suggestions":[{"prompt":[{"type":"text","text":"Live"}]},{"prompt":[{"type":"image","mimeType":"image/png","data":"YQ=="}]}]}))
      method, params = take_v2_frame(received)
      method.should eq("session/update")
      update = params.not_nil!["update"]
      update["futureField"].should eq(true)
      update["suggestions"].should eq(JSON.parse(%([{"prompt":[{"type":"text","text":"Live"}]}])))
    ensure
      client.try(&.close)
    end

    it "delivers a filtered replacement to generic callbacks from a wide stdio frame on #{version}" do
      reader, feed = IO.pipe
      outgoing, writer = IO.pipe
      outgoing.read_timeout = 2.seconds
      transport = ACP::StdioTransport.new(reader, writer)
      media = ACP::Protocol::PromptSuggestionsCapabilities.new
      if version == "v1"
        client = ACP::Client.new(transport, client_capabilities: ACP::Protocol::ClientCapabilities.new(
          session: ACP::Protocol::ClientSessionCapabilities.new(prompt_suggestions: media)))
        result = %({"protocolVersion":1})
      else
        client = ACP::V2::Client.new(transport, capabilities: ACP::Protocol::V2::ClientCapabilities.new(
          session: ACP::Protocol::V2::ClientSessionCapabilities.new(prompt_suggestions: media)))
        result = %({"protocolVersion":2,"info":{"name":"fixture","version":"1"}})
      end
      received = Channel(JSON::Any).new(2)
      client.on_notification = ->(method : String, params : JSON::Any?) do
        received.send(params.not_nil!) if method == "session/update"
        nil
      end
      client.request_timeout = 2.0
      spawn do
        if line = outgoing.gets
          id = JSON.parse(line)["id"]
          feed.puts %({"jsonrpc":"2.0","id":#{id.to_json},"result":#{result}})
        end
      end
      client.initialize_connection
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","futureField":123,"update":{"sessionUpdate":"prompt_suggestions_update","suggestions":[{"prompt":[{"type":"resource","resource":18446744073709551615}]},{"prompt":[{"type":"text","text":"Keep"}]}]}}})
      replaced = take_v2_frame(received)
      replaced["futureField"].should eq(123)
      replaced["update"]["suggestions"].should eq(JSON.parse(%([{"prompt":[{"type":"text","text":"Keep"}]}])))
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"prompt_suggestions_update","suggestions":[18446744073709551615]}}})
      take_v2_frame(received)["update"]["suggestions"].as_a.should be_empty
    ensure
      client.try(&.close)
      feed.try(&.close)
      outgoing.try(&.close)
    end
  end
end

describe "ACP v2 live session state" do
  it "keeps an early state and gives new sessions without a report an idle snapshot" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"fork":{}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"one"})
    transport.before_reply = ->(method : String) do
      if method == "session/new"
        transport.update("one", %({"sessionUpdate":"state_update","state":"running","background":[]}))
      end
      nil
    end
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    client.session_state("one").should be_nil
    client.session_new("/work")
    client.session_state("one").not_nil!.state.should eq("running")
    client.session_state("one").not_nil!.background.should eq([] of ACP::Protocol::V2::BackgroundWork)

    transport.before_reply = nil
    transport.replies["session/new"] = %("result":{"sessionId":"two"})
    client.session_new("/work")
    client.session_state("two").not_nil!.idle?.should be_true
    client.session_state("two").not_nil!.background.should be_nil
    client.session_state("one").not_nil!.state.should eq("running")

    transport.replies["session/fork"] = %("result":{"sessionId":"branch"})
    client.session_fork("one", "/branch")
    client.session_state("branch").not_nil!.idle?.should be_true
  ensure
    client.try(&.close)
  end

  it "starts observing early states only when creation reaches the writer" do
    transport = QueuedRequestTransport.new
    transport.pause_only = "session/new"
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s"})
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    seen = Channel(Nil).new(1)
    client.on_update = ->(_params : ACP::Protocol::V2::SessionUpdateParams) do
      seen.send(nil)
      nil
    end

    result = Channel(ACP::Protocol::V2::SessionNewResult | Exception).new(1)
    spawn do
      result.send(client.session_new("/work"))
    rescue ex
      result.send(ex)
    end
    take_v2_frame(transport.queued)
    id = transport.queued_message.not_nil!["id"]
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{id},"result":{"sessionId":"premature"}}))
    transport.update("s", %({"sessionUpdate":"state_update","state":"running"}))
    take_v2_frame(seen)
    transport.ready_to_write.send(nil)
    take_v2_frame(result).as(ACP::Protocol::V2::SessionNewResult).session_id.should eq("s")
    client.session_state("s").not_nil!.idle?.should be_true
    client.session_state("premature").should be_nil
  ensure
    transport.try(&.ready_to_write.close)
    client.try(&.close)
  end

  it "keeps live reports while a resume is queued and then fails to write" do
    transport = QueuedRequestTransport.new
    transport.pause_only = "session/resume"
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"mcp":{"acp":{}}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s"})
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    client.session_new("/work")
    seen = Channel(String).new(1)
    client.on_update = ->(params : ACP::Protocol::V2::SessionUpdateParams) do
      seen.send(client.session_state(params.session_id).not_nil!.state)
      nil
    end

    failure = Channel(Exception?).new(1)
    spawn do
      declaration = ACP::Protocol::McpServerAcp.new("missing", "unknown-server")
      server = ACP::Protocol::V2::McpServer.acp(declaration)
      params = ACP::Protocol::V2::SessionResumeParams.new("s", "/work", mcp_servers: [server], replay_from: ACP::Protocol::V2::ReplayFrom.start)
      client.session_resume(params)
      failure.send(nil)
    rescue ex
      failure.send(ex)
    end
    take_v2_frame(transport.queued)
    transport.update("s", %({"sessionUpdate":"state_update","state":"requires_action"}))
    take_v2_frame(seen).should eq("requires_action")
    transport.ready_to_write.send(nil)
    take_v2_frame(failure).should be_a(ACP::InvalidStateError)
    transport.sent_messages.map(&.["method"].as_s).should eq(["initialize", "session/new"])
    client.session_state("s").not_nil!.state.should eq("requires_action")
  ensure
    transport.try(&.ready_to_write.close)
    client.try(&.close)
  end

  it "ignores replay markers that arrive before a queued resume is written" do
    transport = QueuedRequestTransport.new
    transport.pause_only = "session/resume"
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s"})
    transport.replies["session/resume"] = %("result":{})
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    client.session_new("/work")
    seen = Channel({String, String, Bool}).new(4)
    client.on_update = ->(params : ACP::Protocol::V2::SessionUpdateParams) do
      seen.send({params.update.session_update, client.session_state("s").not_nil!.state, !client.session_cursor("s", "replayed").nil?})
      nil
    end
    transport.before_reply = ->(method : String) do
      if method == "session/resume"
        transport.update("s", %({"sessionUpdate":"state_update","state":"running"}))
        transport.update("s", %({"sessionUpdate":"cursor_update","cursorId":"replayed"}))
        transport.update("s", %({"sessionUpdate":"replay_complete"}))
        transport.update("s", %({"sessionUpdate":"state_update","state":"requires_action"}))
      end
      nil
    end

    result = Channel(ACP::Protocol::V2::SessionResumeResult | Exception).new(1)
    spawn do
      params = ACP::Protocol::V2::SessionResumeParams.new("s", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start)
      result.send(client.session_resume(params))
    rescue ex
      result.send(ex)
    end
    take_v2_frame(transport.queued)
    transport.update("s", %({"sessionUpdate":"replay_complete"}))
    take_v2_frame(seen).should eq({"replay_complete", "idle", false})
    transport.ready_to_write.send(nil)
    take_v2_frame(result).should be_a(ACP::Protocol::V2::SessionResumeResult)
    take_v2_frame(seen).should eq({"state_update", "idle", false})
    take_v2_frame(seen).should eq({"cursor_update", "idle", false})
    take_v2_frame(seen).should eq({"replay_complete", "idle", true})
    take_v2_frame(seen).should eq({"state_update", "requires_action", true})
  ensure
    transport.try(&.ready_to_write.close)
    client.try(&.close)
  end

  it "applies whole snapshots before callbacks and does not infer state from prompt replies" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"status":{},"delete":{}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s"})
    transport.replies["session/status"] = %("result":{"status":"active","state":{"state":"running"}})
    transport.replies["session/prompt"] = %("result":{"messageId":"m"})
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    client.session_new("/work")
    client.session_prompt_text("s", "hello").message_id.should eq("m")
    client.session_state("s").not_nil!.idle?.should be_true

    snapshots = Channel(ACP::Protocol::V2::StateSnapshot).new(4)
    client.on_update = ->(params : ACP::Protocol::V2::SessionUpdateParams) do
      if params.update.session_update == "state_update"
        snapshots.send(client.session_state(params.session_id).not_nil!)
      end
      nil
    end
    transport.update("s", %({"sessionUpdate":"terminal_update","terminalId":"t"}))
    transport.update("s", %({"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn","background":[{"type":"terminal","terminalId":"t"}]}))
    first = take_v2_frame(snapshots)
    first.stop_reason.should eq("end_turn")
    first.background.not_nil!.first.entity_id.should eq("t")
    first.json_unmapped.clear
    client.session_state("s").not_nil!.stop_reason.should eq("end_turn")

    transport.update("s", %({"sessionUpdate":"state_update","state":"_future","background":null}))
    second = take_v2_frame(snapshots)
    second.state.should eq("_future")
    second.idle?.should be_false
    second.background.should be_nil
    second.stop_reason.should be_nil
    client.session_status("s").state.not_nil!.state.should eq("running")
    client.session_state("s").not_nil!.state.should eq("_future")

    transport.replies["session/delete"] = %("result":{})
    client.session_delete("s")
    client.session_state("s").should be_nil
  ensure
    client.try(&.close)
  end

  it "keeps a resume synchronization and rejects replayed state as current" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/resume"] = %("result":{})
    transport.before_reply = ->(method : String) do
      if method == "session/resume"
        transport.update("s", %({"sessionUpdate":"state_update","state":"running"}))
        transport.update("s", %({"sessionUpdate":"replay_complete"}))
        transport.update("s", %({"sessionUpdate":"state_update","state":"requires_action"}))
      end
      nil
    end
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    client.session_state("s").should be_nil
    resume = ACP::Protocol::V2::SessionResumeParams.new("s", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start)
    client.session_resume(resume)
    client.session_state("s").not_nil!.state.should eq("requires_action")

    seen = Channel(String).new(2)
    client.on_update = ->(params : ACP::Protocol::V2::SessionUpdateParams) do
      if params.update.session_update == "state_update"
        seen.send(client.session_state(params.session_id).not_nil!.state)
      end
      nil
    end
    transport.replies["session/resume"] = %("error":{"code":-32603,"message":"Resume failed"})
    transport.before_reply = ->(method : String) do
      if method == "session/resume"
        transport.update("s", %({"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn"}))
        transport.update("s", %({"sessionUpdate":"replay_complete"}))
        transport.update("s", %({"sessionUpdate":"state_update","state":"unknown"}))
      end
      nil
    end
    expect_raises(ACP::JsonRpcError, /Resume failed/) { client.session_resume(resume) }
    take_v2_frame(seen).should eq("requires_action")
    take_v2_frame(seen).should eq("unknown")
    client.session_state("s").not_nil!.state.should eq("unknown")

    transport.before_reply = nil
    transport.replies["session/resume"] = %("result":{})
    client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("s", "/work"))
    client.session_state("s").not_nil!.state.should eq("unknown")
    client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("legacy", "/work"))
    client.session_state("legacy").not_nil!.state.should eq("unknown")

    transport.replies["session/close"] = %("result":{})
    client.session_close("s")
    client.session_state_raw("s").should be_nil
    client.session_state("legacy").not_nil!.state.should eq("unknown")
  ensure
    client.try(&.close)
  end
end

describe "ACP v2 live command advertisements" do
  it "keeps complete command lists per attached session through setup, preview, resume, and close" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"options":{},"fork":{},"delete":{}}}})
    first = %({"type":"command","name":"review","description":"Review","input":{"type":"text","hint":"branch"}})
    second = %({"type":"command","name":"plan","description":"Plan"})
    invalid = %({"type":"command","name":"invalid name","description":"Invalid"})
    duplicate = %({"type":"_custom","name":"review","description":"Duplicate"})
    extension = %({"type":"_future","name":"show","description":"Extension"})
    skill = %({"type":"skill","name":"skill","description":"Not negotiated"})
    transport.replies["session/new"] = %("result":{"sessionId":"s","availableCommands":[#{first},#{second},#{invalid},#{duplicate},#{extension},#{skill}]})
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    client.session_available_commands("s").should be_nil
    client.session_available_commands_raw("s").should be_nil
    client.session_new("/work")
    client.session_available_commands("s").not_nil!.map(&.name).should eq(["plan", "show"])
    client.session_available_commands("s").not_nil!.last.slash_command?.should be_false
    client.session_available_commands_raw("s").not_nil!.elements?.not_nil!.size.should eq(6)

    transport.replies["session/options"] = %("result":{"availableCommands":[#{first}]})
    result = client.session_options(ACP::Protocol::V2::SessionOptionsParams.new("/work", session_id: "s"))
    result.typed_available_commands.first.name.should eq("review")
    client.session_available_commands("s").not_nil!.map(&.name).should eq(["plan", "show"])

    transport.replies["session/fork"] = %("result":{"sessionId":"branch","availableCommands":[#{first}]})
    client.session_fork("s", "/branch")
    branch = client.session_available_commands("branch").not_nil!
    branch.first.input.not_nil!.text_hint.should eq("branch")
    branch.clear
    client.session_available_commands("branch").not_nil!.map(&.name).should eq(["review"])

    transport.replies["session/resume"] = %("result":{})
    client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("s", "/work"))
    client.session_available_commands("s").should eq([] of ACP::Protocol::V2::AvailableCommand)
    client.session_available_commands_raw("s").not_nil!.json.should eq("[]")
    client.session_available_commands("branch").not_nil!.map(&.name).should eq(["review"])

    transport.replies["session/close"] = %("result":{})
    client.session_close("s")
    client.session_available_commands("s").should be_nil
    transport.replies["session/delete"] = %("result":{})
    client.session_delete("branch")
    client.session_available_commands_raw("branch").should be_nil
  ensure
    client.try(&.close)
  end

  it "applies live replacements before callbacks and keeps replay from replacing live commands" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s","availableCommands":[{"type":"command","name":"original","description":"Original"}]})
    transport.replies["session/resume"] = %("error":{"code":-32603,"message":"failed"})
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    client.session_new("/work")
    seen = Channel(Array(String)).new(4)
    client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
      if note.update.session_update == "available_commands_update"
        seen.send(client.session_available_commands(note.session_id).not_nil!.map(&.name))
      end
      nil
    end
    transport.before_reply = ->(method : String) do
      if method == "session/resume"
        transport.update("s", %({"sessionUpdate":"available_commands_update","availableCommands":[{"type":"command","name":"historical","description":"History"}]}))
        transport.update("s", %({"sessionUpdate":"replay_complete"}))
        transport.update("s", %({"sessionUpdate":"available_commands_update","availableCommands":[{"type":"command","name":"current","description":"Current"}]}))
      end
      nil
    end
    resume = ACP::Protocol::V2::SessionResumeParams.new("s", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start)
    expect_raises(ACP::JsonRpcError) { client.session_resume(resume) }
    take_v2_frame(seen).should eq(["original"])
    take_v2_frame(seen).should eq(["current"])
    transport.update("s", %({"sessionUpdate":"available_commands_update","availableCommands":true}))
    take_v2_frame(seen).should eq(["current"])
    transport.update("s", %({"sessionUpdate":"available_commands_update","availableCommands":[]}))
    take_v2_frame(seen).should be_empty
  ensure
    client.try(&.close)
  end
end

private def v2_skill_client(transport : V2TestTransport) : ACP::V2::Client
  commands = ACP::Protocol::V2::CommandsCapabilities.new(skill: ACP::Protocol::V2::CommandsSkillCapabilities.new)
  session = ACP::Protocol::V2::ClientSessionCapabilities.new(commands: commands)
  ACP::V2::Client.new(transport, capabilities: ACP::Protocol::V2::ClientCapabilities.new(session: session))
end

private def v2_skill_prompt(session_id : String, name : String, key : String? = nil) : ACP::Protocol::V2::SessionPromptParams
  blocks = [ACP::Protocol::V2::SkillReference.new(name), ACP::Protocol::TextContentBlock.new("Review the fixture")] of ACP::Protocol::V2::PromptContentBlock
  ACP::Protocol::V2::SessionPromptParams.new(session_id, blocks, idempotency_key: key)
end

describe "ACP v2 draft agent skills" do
  it "models opt-in command and prompt capabilities" do
    caps = ACP::Protocol::V2::ClientCapabilities.from_json(%({"session":{"commands":{"skill":{"_meta":false}},"promptSuggestions":{}}}))
    caps.session.not_nil!.commands.not_nil!.skill.not_nil!.meta.should be_nil
    JSON.parse(caps.to_json)["session"].should eq(JSON.parse(%({"commands":{"skill":{}},"promptSuggestions":{}})))
    {"null", "true", "[]"}.each do |value|
      caps = ACP::Protocol::V2::ClientCapabilities.from_json(%({"session":{"commands":{"skill":#{value}}}}))
      caps.session.not_nil!.commands.not_nil!.skill.should be_nil
    end
    leading = ACP::Protocol::V2::PromptCapabilities.from_json(%({"skill":{"inline":true}}))
    leading.skill.not_nil!.inline.should be_nil
    inline = ACP::Protocol::V2::PromptCapabilities.from_json(%({"skill":{"inline":{}}}))
    inline.skill.not_nil!.inline.should_not be_nil
  end

  it "projects known skills and skips ambiguous names in setup and command updates" do
    commands = <<-JSON
      [
        {"type":"command","name":"shared","description":"A command"},
        {"type":"skill","name":"shared","description":"Ambiguous"},
        {"type":"skill","name":"needs space","description":"Invalid"},
        {"type":"skill","name":"broken"},
        {"type":"skill","name":18446744073709551615},
        {"type":"_future","name":"next","description":"An extension","futureField":true},
        {"type":"skill","name":"notes","description":"Notes","path":"C:/skills/notes/SKILL.md","_meta":{"example.test/source":"built-in"}},
        {"type":"skill","name":"relative","description":"Relative path","path":"./SKILL.md"},
        {"type":"skill","name":"wide","description":"Wide optional fields","path":18446744073709551615,"_meta":{"counter":18446744073709551615}}
      ]
      JSON
    setup = ACP::Protocol::V2::SessionNewResult.from_json(%({"sessionId":"s","availableCommands":#{commands}}))
    update = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"available_commands_update","availableCommands":#{commands}})).typed.as(ACP::Protocol::V2::AvailableCommandsUpdate)
    {setup, update}.each do |value|
      skills = value.typed_available_skills
      skills.map(&.name).should eq(["notes", "relative", "wide"])
      skills[0].path.should eq("C:/skills/notes/SKILL.md")
      skills[0].meta.not_nil!["example.test/source"].should eq("built-in")
      skills[1].path.should be_nil
      skills[2].path.should be_nil
      skills[2].meta.should be_nil
      value.typed_available_commands.select(&.slash_command?).should be_empty
      value.available_commands_raw.elements?.not_nil!.count { |entry| entry.field("name").try(&.as_s?) == "shared" }.should eq(2)
      value.typed_available_commands.find!(&.type.==("_future")).json_unmapped["futureField"].should eq(true)
    end
  end

  it "decodes user-message skill references without changing future block payloads" do
    message = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"user_message","messageId":"m","content":[{"type":"skill","name":"plugin:notes","_meta":{"example.test/id":1}},{"type":"skill","name":42},{"type":"_future","value":true}]})).typed.as(ACP::Protocol::V2::MessageUpdate)
    skill = message.skill_references.first
    skill.name.should eq("plugin:notes")
    skill.meta.not_nil!["example.test/id"].should eq(1)
    message.skill_references.size.should eq(1)
    message.content.not_nil!.last["value"].should eq(true)

    chunk = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"user_message_chunk","messageId":"m","content":{"type":"skill","name":"notes"}})).typed.as(ACP::Protocol::V2::MessageChunkUpdate)
    chunk.skill_reference.not_nil!.name.should eq("notes")
    agent = ACP::Protocol::V2::MessageChunkUpdate.new("agent_message_chunk", "m", chunk.content)
    agent.skill_reference.should be_nil
    expect_raises(JSON::ParseException) { ACP::Protocol::ContentBlock.from_json(chunk.content.to_json) }
  end

  it "guards leading-only skills and sends exact keyed retries after command replacement" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"prompt":{"skill":{}}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s","availableCommands":[{"type":"skill","name":"notes","description":"Notes"}]})
    transport.replies["session/prompt"] = %("result":{"messageId":"message"})
    client = v2_skill_client(transport)
    updates = Channel(ACP::Protocol::V2::AvailableCommandsUpdate).new(2)
    client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
      if update = note.update.typed.as?(ACP::Protocol::V2::AvailableCommandsUpdate)
        updates.send(update)
      end
      nil
    end
    client.initialize_connection
    take_v2_frame(transport.outgoing)["params"]["capabilities"]["session"]["commands"]["skill"].should eq(JSON.parse("{}"))
    client.session_new("/work").typed_available_skills.first.name.should eq("notes")
    client.session_available_commands("s").not_nil!.first.skill.not_nil!.name.should eq("notes")
    take_v2_frame(transport.outgoing)
    prompt = v2_skill_prompt("s", "notes")
    expect_raises(ArgumentError, /first prompt block/) { client.session_prompt(ACP::Protocol::V2::SessionPromptParams.new("s", prompt.prompt.reverse)) }
    expect_raises(ArgumentError, /Malformed/) do
      client.session_prompt(ACP::Protocol::V2::SessionPromptParams.new("s", [JSON.parse(%({"type":"skill","name":42}))]))
    end
    expect_raises(ACP::InvalidStateError, /not currently advertised/) { client.session_prompt(v2_skill_prompt("other", "notes")) }
    expect_raises(ACP::InvalidStateError, /not currently advertised/) { client.session_prompt(v2_skill_prompt("s", "missing")) }
    expect_raises(ACP::InvalidStateError, /not currently advertised/) { client.session_prompt(v2_skill_prompt("s", "missing", "fresh")) }
    expect_raises(ArgumentError, /original idempotency key/) { client.session_prompt(prompt, retry_submission: true) }
    client.session_prompt(prompt).message_id.should eq("message")
    take_v2_frame(transport.outgoing)["params"]["prompt"][0].should eq(JSON.parse(%({"type":"skill","name":"notes"})))
    keyed = v2_skill_prompt("s", "notes", "same-input")
    client.session_prompt(keyed).message_id.should eq("message")
    original = take_v2_frame(transport.outgoing)["params"]

    transport.update("s", %({"sessionUpdate":"available_commands_update","availableCommands":[]}))
    take_v2_frame(updates).typed_available_skills.should be_empty
    client.session_available_commands("s").not_nil!.should be_empty
    expect_raises(ACP::InvalidStateError) { client.session_prompt(prompt) }
    expect_raises(ACP::InvalidStateError) { client.session_prompt(keyed) }
    client.session_prompt(keyed, retry_submission: true).message_id.should eq("message")
    take_v2_frame(transport.outgoing)["params"].should eq(original)
  ensure
    client.try(&.close)
  end

  it "keeps inline skill lists scoped across setup, preview, fork, and close" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"fork":{},"options":{},"prompt":{"skill":{"inline":{}}}}}})
    first = %({"type":"skill","name":"notes","description":"Notes"})
    second = %({"type":"skill","name":"chart","description":"Chart"})
    transport.replies["session/new"] = %("result":{"sessionId":"s","availableCommands":[#{first},#{second}]})
    transport.replies["session/options"] = %("result":{"availableCommands":[{"type":"skill","name":"preview","description":"Preview"}]})
    transport.replies["session/fork"] = %("result":{"sessionId":"branch"})
    transport.replies["session/resume"] = %("result":{"availableCommands":[#{second}]})
    transport.replies["session/close"] = %("result":{})
    transport.replies["session/prompt"] = %("result":{"messageId":"message"})
    client = v2_skill_client(transport)
    client.initialize_connection
    client.session_new("/work")
    blocks = [ACP::Protocol::TextContentBlock.new("Use"), ACP::Protocol::V2::SkillReference.new("notes"),
              ACP::Protocol::V2::SkillReference.new("chart")] of ACP::Protocol::V2::PromptContentBlock
    client.session_prompt(ACP::Protocol::V2::SessionPromptParams.new("s", blocks))
    client.session_options(ACP::Protocol::V2::SessionOptionsParams.new("/work", session_id: "s")).typed_available_skills.first.name.should eq("preview")
    expect_raises(ACP::InvalidStateError) { client.session_prompt(v2_skill_prompt("s", "preview")) }
    client.session_fork("s", "/branch")
    expect_raises(ACP::InvalidStateError) { client.session_prompt(v2_skill_prompt("branch", "notes")) }
    client.session_prompt(v2_skill_prompt("s", "notes"))
    client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("s", "/work"))
    expect_raises(ACP::InvalidStateError) { client.session_prompt(v2_skill_prompt("s", "notes")) }
    client.session_prompt(v2_skill_prompt("s", "chart"))
    client.session_close("s")
    expect_raises(ACP::InvalidStateError) { client.session_prompt(v2_skill_prompt("s", "chart")) }
  ensure
    client.try(&.close)
  end

  it "requires both peers to enable skill references" do
    {true, false}.each do |advertise|
      transport = V2TestTransport.new
      transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"prompt":{"skill":#{advertise ? "null" : "{}"}}}}})
      client = advertise ? v2_skill_client(transport) : ACP::V2::Client.new(transport)
      begin
        client.initialize_connection
        expect_raises(ACP::InvalidStateError, /did not advertise/) { client.session_prompt(v2_skill_prompt("s", "notes", "retry")) }
        transport.sent_messages.size.should eq(1)
      ensure
        client.close
      end
    end
  end

  it "keeps live command replacements received after the replay marker if resume fails" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"prompt":{"skill":{}}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s","availableCommands":[{"type":"skill","name":"notes","description":"Notes"}]})
    transport.replies["session/resume"] = %("error":{"code":-32603,"message":"Resume failed"})
    transport.replies["session/prompt"] = %("result":{"messageId":"message"})
    transport.before_reply = ->(method : String) do
      if method == "session/resume"
        transport.update("s", %({"sessionUpdate":"available_commands_update","availableCommands":[{"type":"skill","name":"history","description":"History"}]}))
        transport.update("s", %({"sessionUpdate":"replay_complete"}))
        transport.update("s", %({"sessionUpdate":"available_commands_update","availableCommands":[{"type":"skill","name":"live","description":"Live"}]}))
      end
      nil
    end
    client = v2_skill_client(transport)
    client.initialize_connection
    client.session_new("/work")
    resume = ACP::Protocol::V2::SessionResumeParams.new("s", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start)
    expect_raises(ACP::JsonRpcError) { client.session_resume(resume) }
    expect_raises(ACP::InvalidStateError) { client.session_prompt(v2_skill_prompt("s", "history")) }
    expect_raises(ACP::InvalidStateError) { client.session_prompt(v2_skill_prompt("s", "notes")) }
    client.session_prompt(v2_skill_prompt("s", "live")).message_id.should eq("message")

    transport.replies["session/resume"] = %("result":{})
    client.session_resume(resume)
    expect_raises(ACP::InvalidStateError) { client.session_prompt(v2_skill_prompt("s", "live")) }
  ensure
    client.try(&.close)
  end

  it "keeps an existing session's list when another setup reuses its ID" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"prompt":{"skill":{}}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s","availableCommands":[{"type":"skill","name":"notes","description":"Notes"}]})
    transport.replies["session/prompt"] = %("result":{"messageId":"message"})
    client = v2_skill_client(transport)
    client.initialize_connection
    client.session_new("/workspace")
    transport.replies["session/new"] = %("result":{"sessionId":"s","availableCommands":[{"type":"skill","name":"other","description":"Other"}]})
    expect_raises(ACP::ProtocolError, /existing session ID/) { client.session_new("/wrong") }
    client.session_workspace("s").not_nil!.cwd.should eq("/workspace")
    expect_raises(ACP::InvalidStateError) { client.session_prompt(v2_skill_prompt("s", "other")) }
    client.session_prompt(v2_skill_prompt("s", "notes")).message_id.should eq("message")
  ensure
    client.try(&.close)
  end

  it "rechecks queued references when the Agent withdraws the skill" do
    transport = QueuedRequestTransport.new
    transport.pause_only = "session/prompt"
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"prompt":{"skill":{}}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s","availableCommands":[{"type":"skill","name":"notes","description":"Notes"}]})
    client = v2_skill_client(transport)
    client.initialize_connection
    client.session_new("/work")
    observed = Channel(Nil).new(1)
    client.on_update = ->(_note : ACP::Protocol::V2::SessionUpdateParams) do
      observed.send(nil)
      nil
    end
    failure = Channel(Exception?).new(1)
    spawn do
      client.session_prompt(v2_skill_prompt("s", "notes"))
      failure.send(nil)
    rescue ex
      failure.send(ex)
    end
    take_v2_frame(transport.queued)
    transport.update("s", %({"sessionUpdate":"available_commands_update","availableCommands":[]}))
    take_v2_frame(observed)
    transport.ready_to_write.send(nil)
    take_v2_frame(failure).should be_a(ACP::InvalidStateError)
    transport.sent_messages.size.should eq(2)
  ensure
    client.try(&.close)
    transport.try(&.ready_to_write.close)
  end
end

describe "ACP draft model providers" do
  it "uses nullable capability objects and preserves open protocol names" do
    {ACP::Protocol::AgentCapabilities, ACP::Protocol::V2::AgentCapabilities}.each do |type|
      type.from_json(%({"providers":{}})).providers.should_not be_nil
      type.from_json(%({"providers":false})).providers.should be_nil
      type.from_json(%({"providers":null})).providers.should be_nil
      type.from_json(%({})).providers.should be_nil
    end
    result = ACP::Protocol::ListProvidersResult.from_json(<<-JSON)
      {"providers":[
        {"providerId":"main","supported":["anthropic",false,18446744073709551615,"future","_custom"],"required":true,"current":{"apiType":"future","baseUrl":"https://model.example.test","_meta":0}},
        {"providerId":"optional","supported":null,"required":false,"current":null,"_meta":{"bad":18446744073709551615}}
      ]}
      JSON
    result.providers.first.supported.should eq(["anthropic", "future", "_custom"])
    result.providers.first.current.not_nil!.api_type.should eq("future")
    result.providers.last.supported.should be_empty
    result.providers.last.current.should be_nil
    result.providers.last.meta.should be_nil
    result.required?("main").should be_true
    result.required?("optional").should be_false
  end

  it "registers provider method names as connection-scoped requests" do
    {ACP::Protocol::AgentMethod::PROVIDERS_LIST, ACP::Protocol::AgentMethod::PROVIDERS_SET, ACP::Protocol::AgentMethod::PROVIDERS_DISABLE}.each do |method|
      ACP::Protocol::AgentMethod.known?(method).should be_true
      ACP::Protocol::AgentMethod.session_method?(method).should be_false
    end
  end

  {"v1", "v2"}.each do |version|
    it "lists, replaces, and disables providers before creating a session on #{version}" do
      transport = V2TestTransport.new
      if version == "v1"
        transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"providers":{}}})
        client = ACP::Client.new(transport)
      else
        transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"providers":{}}})
        client = ACP::V2::Client.new(transport)
      end
      transport.replies["providers/list"] = %("result":{"providers":[{"providerId":"main","supported":["openai"],"required":true},{"providerId":"gateway","supported":["_gateway"],"required":false,"current":null}]})
      transport.replies["providers/set"] = %("result":{"_meta":{"example.test/applied":true}})
      transport.replies["providers/disable"] = %("result":{})
      expect_raises(ACP::InvalidStateError) { client.providers_list }
      client.initialize_connection
      take_v2_frame(transport.outgoing)["method"].should eq("initialize")

      meta = {"example.test/source" => JSON::Any.new("fixture")}
      list = client.providers_list(ACP::Protocol::ListProvidersParams.new(meta))
      list.providers.map(&.provider_id).should eq(["main", "gateway"])
      request = take_v2_frame(transport.outgoing)
      request["method"].should eq("providers/list")
      request["params"]["_meta"]["example.test/source"].should eq("fixture")

      params = ACP::Protocol::SetProviderParams.new("gateway", "_gateway", "https://llm.example.test/v1",
        headers: {"Authorization" => "fixture-token", "X-Model-Route" => "fixture"})
      client.providers_set(params).meta.not_nil!["example.test/applied"].should eq(true)
      request = take_v2_frame(transport.outgoing)
      request["method"].should eq("providers/set")
      request["params"].should eq(JSON.parse(%({"providerId":"gateway","apiType":"_gateway","baseUrl":"https://llm.example.test/v1","headers":{"Authorization":"fixture-token","X-Model-Route":"fixture"}})))

      client.providers_set(ACP::Protocol::SetProviderParams.new("gateway", "_gateway", "https://llm.example.test/v1"))
      take_v2_frame(transport.outgoing)["params"]["headers"]?.should be_nil
      client.providers_set(ACP::Protocol::SetProviderParams.new("gateway", "_gateway", "https://llm.example.test/v1", headers: {} of String => String))
      take_v2_frame(transport.outgoing)["params"]["headers"].should eq(JSON.parse("{}"))

      expect_raises(ACP::InvalidStateError, /requires this provider/) { client.providers_disable("main") }
      take_v2_frame(transport.outgoing)["method"].should eq("providers/list")
      client.providers_disable(ACP::Protocol::DisableProviderParams.new("gateway", meta))
      take_v2_frame(transport.outgoing)["method"].should eq("providers/list")
      request = take_v2_frame(transport.outgoing)
      request["method"].should eq("providers/disable")
      request["params"]["providerId"].should eq("gateway")
      request["params"]["_meta"]["example.test/source"].should eq("fixture")
      client.providers_disable("unknown")
      take_v2_frame(transport.outgoing)["method"].should eq("providers/list")
      take_v2_frame(transport.outgoing)["params"]["providerId"].should eq("unknown")

      transport.replies["providers/list"] = %("result":{"providers":[{"providerId":"uncertain","supported":[]}]})
      expect_raises(ACP::ProtocolError) { client.providers_disable("uncertain") }
      take_v2_frame(transport.outgoing)["method"].should eq("providers/list")
      transport.sent_messages.size.should eq(11)
    ensure
      client.try(&.close)
    end

    it "does not send provider methods without a negotiated capability on #{version}" do
      transport = V2TestTransport.new
      if version == "v1"
        transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"providers":false}})
        client = ACP::Client.new(transport)
      else
        client = ACP::V2::Client.new(transport)
      end
      client.initialize_connection
      expect_raises(ACP::InvalidStateError, /did not advertise providers/) { client.providers_list }
      expect_raises(ACP::InvalidStateError, /did not advertise providers/) do
        client.providers_set(ACP::Protocol::SetProviderParams.new("optional", "openai", "https://llm.example.test"))
      end
      expect_raises(ACP::InvalidStateError, /did not advertise providers/) { client.providers_disable("optional") }
      transport.sent_messages.size.should eq(1)
    ensure
      client.try(&.close)
    end
  end

  it "checks v2 provider URLs locally and preserves Agent errors" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"providers":{}}})
    transport.replies["providers/set"] = %("error":{"code":-32602,"message":"Unsupported protocol","data":{"providerId":"gateway"}})
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    {"/relative", "https:///no-host", "https://llm.example.test/with space"}.each do |base_url|
      expect_raises(ArgumentError, /absolute URIs/) do
        client.providers_set(ACP::Protocol::V2::SetProviderParams.new("gateway", "openai", base_url))
      end
    end
    transport.sent_messages.size.should eq(1)
    error = expect_raises(ACP::JsonRpcError) do
      client.providers_set(ACP::Protocol::V2::SetProviderParams.new("gateway", "_custom", "https://llm.example.test"))
    end
    error.invalid_params?.should be_true
    error.data.not_nil!["providerId"].should eq("gateway")
  ensure
    client.try(&.close)
  end
end

describe "ACP version negotiation" do
  it "keeps the first transport and returns the v2 client when v2 is selected" do
    transport = V2TestTransport.new
    opens = 0
    capabilities = ACP::Protocol::V2::ClientCapabilities.new(
      auth: ACP::Protocol::V2::ClientAuthCapabilities.new(terminal: ACP::Protocol::V2::Capability.new)
    )
    client = ACP.connect_negotiated(v2_capabilities: capabilities) do
      opens += 1
      transport
    end
    client.should be_a(ACP::V2::Client)
    client.negotiated_protocol_version.should eq(2_u16)
    opens.should eq(1)
    params = take_v2_frame(transport.outgoing)["params"]
    params["protocolVersion"].should eq(2)
    params["capabilities"]["auth"]["terminal"].should eq(JSON.parse("{}"))
  ensure
    client.try(&.close)
  end

  it "closes the first transport and negotiates v1 with its own capabilities" do
    first = V2TestTransport.new
    first.replies["initialize"] = %("result":{"protocolVersion":1,"agentInfo":{"name":"probe","version":"1"}})
    second = V2TestTransport.new
    second.replies["initialize"] = %("result":{"protocolVersion":1,"agentInfo":{"name":"legacy","version":"1"}})
    second.replies["session/new"] = %("result":{"sessionId":"legacy-session"})
    info = ACP::Protocol::ClientInfo.new("test-editor", "1.2", title: "Test Editor")
    caps = ACP::Protocol::ClientCapabilities.new(fs: ACP::Protocol::FsCapabilities.new(read_text_file: true))
    transports = [first, second]
    client = ACP.connect_negotiated(info: info, v1_capabilities: caps) do
      next_transport = transports.shift
      first.closed?.should be_true if next_transport == second
      next_transport
    end.as(ACP::Client)
    client.negotiated_protocol_version.should eq(1_u16)
    client.agent_info.not_nil!.name.should eq("legacy")
    first_params = take_v2_frame(first.outgoing)["params"]
    first_params["info"]["title"].should eq("Test Editor")
    first_params["capabilities"]["fs"]?.should be_nil
    second_params = take_v2_frame(second.outgoing)["params"]
    second_params["protocolVersion"].should eq(1)
    second_params["clientInfo"]["name"].should eq("test-editor")
    second_params["clientCapabilities"]["fs"]["readTextFile"].should eq(true)
    client.session_new("/work").session_id.should eq("legacy-session")
  ensure
    client.try(&.close)
  end

  it "surfaces an initialize error without reopening the transport" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("error":{"code":-32022,"message":"Unsupported","data":{"requested":2,"supported":[3]}})
    opens = 0
    error = expect_raises(ACP::JsonRpcError) do
      ACP.connect_negotiated do
        opens += 1
        transport
      end
    end
    error.data.not_nil!["supported"].should eq(JSON.parse("[3]"))
    opens.should eq(1)
    transport.closed?.should be_true
  end

  it "falls back to v1 when the response has malformed optional capabilities" do
    first = V2TestTransport.new
    first.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":[]})
    second = V2TestTransport.new
    second.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":[]})
    transports = [first, second]
    client = ACP.connect_negotiated { transports.shift }.as(ACP::Client)
    client.negotiated_protocol_version.should eq(1_u16)
    client.agent_capabilities.not_nil!.load_session?.should be_false
    first.closed?.should be_true
  ensure
    client.try(&.close)
  end

  it "rejects a malformed required protocol version before retrying" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":"1"})
    opens = 0
    error = expect_raises(ACP::VersionMismatchError) do
      ACP.connect_negotiated do
        opens += 1
        transport
      end
    end
    error.agent_version.should be_nil
    opens.should eq(1)
    transport.closed?.should be_true
  end

  it "closes the v1 transport when its handshake fails" do
    first = V2TestTransport.new
    first.replies["initialize"] = %("result":{"protocolVersion":1})
    second = V2TestTransport.new
    second.replies["initialize"] = %("error":{"code":-32603,"message":"Agent setup failed"})
    transports = [first, second]
    expect_raises(ACP::JsonRpcError, /Agent setup failed/) do
      ACP.connect_negotiated { transports.shift }
    end
    first.closed?.should be_true
    second.closed?.should be_true
  end
end

describe ACP::V2::Client do
  it "rejects Agent requests before the successful initialize response" do
    transport = V2TestTransport.new
    transport.before_reply = ->(method : String) do
      if method == "initialize"
        transport.inject_raw(%({"jsonrpc":"2.0","id":"early","method":"_early","params":{}}))
      end
    end
    transport.after_reply = ->(method : String) do
      if method == "initialize"
        transport.inject_raw(%({"jsonrpc":"2.0","id":"later","method":"_early","params":{}}))
      end
    end
    client = ACP::V2::Client.new(transport)
    client.on_extension_request = ->(_method : String, _params : JSON::Any) do
      JSON::Any.new(client.initialization_result.not_nil!.info.name)
    end
    client.initialize_connection
    take_v2_frame(transport.outgoing)["method"].should eq("initialize")
    take_v2_frame(transport.outgoing)["error"]["code"].should eq(-32600)
    take_v2_frame(transport.outgoing)["result"].should eq("agent")
    transport.inject_raw(%({"jsonrpc":"1.0","id":"invalid","method":"_early","params":{}}))
    take_v2_frame(transport.outgoing)["error"]["code"].should eq(-32600)
  ensure
    client.try(&.close)
  end

  it "negotiates v2 and acknowledges prompt insertion separately from foreground completion" do
    transport = V2TestTransport.new
    transport.replies["session/new"] = %("result":{"sessionId":"s"})
    transport.replies["session/prompt"] = %("result":{"messageId":"m"})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.prompt_timeout = 2.0
    updates = Channel(ACP::Protocol::V2::SessionUpdateParams).new(2)
    client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
      updates.send(note)
      nil
    end
    expect_raises(ACP::InvalidStateError) { client.session_new("/work") }

    client.initialize_connection.protocol_version.should eq(2_u16)
    initialize = take_v2_frame(transport.outgoing)
    initialize["params"]["protocolVersion"].should eq(2)
    initialize["params"]["info"]["name"].should eq("acp-crystal")
    initialize["params"]["capabilities"].should eq(JSON.parse("{}"))

    session = client.session_new("/work")
    session.session_id.should eq("s")
    client.session_workspace("s").not_nil!.cwd.should eq("/work")
    take_v2_frame(transport.outgoing)["method"].should eq("session/new")
    transport.before_reply = ->(method : String) do
      transport.update("s", %({"sessionUpdate":"state_update","state":"running"})) if method == "session/prompt"
    end
    acknowledgement = client.session_prompt_text("s", "hello", "insert-once")
    acknowledgement.message_id.should eq("m")
    take_v2_frame(transport.outgoing)["params"]["idempotencyKey"].should eq("insert-once")
    take_v2_frame(updates).update.typed.as(ACP::Protocol::V2::StateUpdate).state.should eq("running")
    transport.update("s", %({"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn"}))
    take_v2_frame(updates).update.typed.as(ACP::Protocol::V2::StateUpdate).stop_reason.should eq("end_turn")
  ensure
    client.try(&.close)
  end

  it "reports the negotiated version on a v1 response without trying to decode v2 info" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{}})
    client = ACP::V2::Client.new(transport)
    mismatch = expect_raises(ACP::VersionMismatchError) { client.initialize_connection }
    mismatch.agent_version.should eq(1_u16)
    transport.closed?.should be_true
  ensure
    client.try(&.close)
  end

  it "uses the v2 list, configuration, close, and optional delete operations" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"delete":{}}}})
    transport.replies["session/list"] = %("result":{"sessions":[{"sessionId":"s","cwd":"/work"}],"nextCursor":"next"})
    config = %({"configId":"model","name":"Model","type":"select","currentValue":"fast","options":[{"value":"fast","name":"Fast"}]})
    transport.replies["session/resume"] = %("result":{"configOptions":[#{config}]})
    transport.replies["session/set_config_option"] = %("result":{"configOptions":[#{config}]})
    transport.replies["session/close"] = %("result":{})
    transport.replies["session/delete"] = %("result":{})
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    listing = client.session_list
    listing.sessions.first.cwd.should eq("/work")
    listing.next_cursor.should eq("next")
    take_v2_frame(transport.outgoing)["method"].should eq("session/list")
    client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("s", "/work"))
    take_v2_frame(transport.outgoing)["method"].should eq("session/resume")
    updated = client.session_set_config_option(ACP::Protocol::V2::SessionSetConfigOptionParams.new("s", "model", "fast"))
    updated.config_options.first["currentValue"].should eq("fast")
    take_v2_frame(transport.outgoing)["params"]["type"].should eq("id")
    client.session_close("s")
    take_v2_frame(transport.outgoing)["method"].should eq("session/close")
    client.session_delete("s")
    take_v2_frame(transport.outgoing)["method"].should eq("session/delete")
  ensure
    client.try(&.close)
  end

  it "applies a permission tool patch in wire order before calling the handler" do
    transport = V2TestTransport.new
    transport.replies["tool_call/cancel"] = %("result":{})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    events = Channel(String).new(4)
    client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
      patch = note.update.typed.as(ACP::Protocol::V2::ToolCallUpdate)
      events.send(patch.capabilities_present? ? "permission patch" : "notification")
      nil
    end
    client.on_request_permission = ->(permission : ACP::Protocol::V2::RequestPermissionParams) do
      permission.request_id.should eq("p-1")
      patch = permission.typed_subject.not_nil!.tool_call.not_nil!
      patch.title_present?.should be_true
      patch.title.should be_nil
      JSON.parse(patch.to_json)["sessionUpdate"]?.should be_nil
      events.send("permission handler")
      client.tool_call_cancel(permission.session_id, patch.tool_call_id)
      ACP::Protocol::V2::RequestPermissionResult.cancelled
    end
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    transport.update("s", %({"sessionUpdate":"tool_call_update","toolCallId":"t","title":"First title"}))
    transport.inject_raw(%({"jsonrpc":"2.0","id":"p-1","method":"session/request_permission","params":{"sessionId":"s","title":"Cancel tool?","subject":{"type":"tool_call","toolCall":{"toolCallId":"t","title":null,"capabilities":{"cancel":{}}}},"options":[{"optionId":"once","name":"Allow","kind":"allow_once"}]}}))
    take_v2_frame(events).should eq("notification")
    take_v2_frame(events).should eq("permission patch")
    take_v2_frame(events).should eq("permission handler")
    cancel = take_v2_frame(transport.outgoing)
    cancel["method"].should eq("tool_call/cancel")
    cancel["params"]["toolCallId"].should eq("t")
    take_v2_frame(transport.outgoing)["result"]["outcome"]["outcome"].should eq("cancelled")
  ensure
    client.try(&.close)
  end

  it "delivers typed command details and rejects malformed known permission subjects" do
    transport = V2TestTransport.new
    client = ACP::V2::Client.new(transport)
    entered = Channel(ACP::Protocol::V2::RequestPermissionParams).new(4)
    client.on_request_permission = ->(permission : ACP::Protocol::V2::RequestPermissionParams) do
      entered.send(permission)
      ACP::Protocol::V2::RequestPermissionResult.cancelled
    end
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    options = %([{"optionId":"once","name":"Allow","kind":"allow_once"}])
    transport.inject_raw(%({"jsonrpc":"2.0","id":1,"method":"session/request_permission","params":{"sessionId":"s","title":"Run tests?","subject":{"type":"command","command":"crystal spec","cwd":"C:/work","toolCallId":"t","terminalId":"term"},"options":#{options}}}))
    take_v2_frame(transport.outgoing)["result"]["outcome"]["outcome"].should eq("cancelled")
    request = take_v2_frame(entered)
    command = request.typed_subject.not_nil!.command.not_nil!
    request.request_id.should eq(1_i64)
    JSON.parse(request.to_json)["requestId"]?.should be_nil
    command.command.should eq("crystal spec")
    command.cwd.should eq("C:/work")
    command.tool_call_id.should eq("t")
    command.terminal_id.should eq("term")

    [
      %({"type":"command","command":"crystal spec","cwd":"relative"}),
      %({"type":"tool_call","toolCall":{"title":"Missing ID"}}),
      %({"type":false}),
    ].each do |subject|
      transport.inject_raw(%({"jsonrpc":"2.0","id":2,"method":"session/request_permission","params":{"sessionId":"s","title":"Malformed","subject":#{subject},"options":#{options}}}))
      take_v2_frame(transport.outgoing)["error"]["code"].should eq(-32602)
    end
    transport.inject_raw(%({"jsonrpc":"2.0","id":2,"method":"session/request_permission","params":{"sessionId":"s","title":"No options","options":[]}}))
    take_v2_frame(transport.outgoing)["error"]["code"].should eq(-32602)
    select
    when entered.receive
      raise "malformed permission reached the handler"
    else
    end
  ensure
    client.try(&.close)
  end

  it "uses v2 auth method IDs and the v2 permission request shape" do
    transport = V2TestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"authMethods":[{"type":"agent","methodId":"credentials","name":"Agent login"},{"type":"terminal","methodId":"terminal","name":"Terminal login"}]})
    transport.replies["auth/login"] = %("result":{})
    transport.replies["auth/logout"] = %("result":{})
    client = ACP::V2::Client.new(transport)
    client.on_request_permission = ->(params : ACP::Protocol::V2::RequestPermissionParams) do
      params.session_id.should eq("child")
      params.title.should eq("Review access")
      params.subject.not_nil!["type"].should eq("_future")
      params.typed_subject.not_nil!.type.should eq("_future")
      ACP::Protocol::V2::RequestPermissionResult.selected(params.options.first.option_id)
    end
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    expect_raises(ACP::InvalidStateError) { client.auth_login("terminal") }
    expect_raises(ACP::InvalidStateError) { client.session_new("/work") }
    client.auth_login("credentials")
    take_v2_frame(transport.outgoing)["params"]["methodId"].should eq("credentials")
    client.auth_logout
    take_v2_frame(transport.outgoing)["method"].should eq("auth/logout")

    transport.inject_raw(%({"jsonrpc":"2.0","id":"permission","method":"session/request_permission","params":{"sessionId":"child","title":"Review access","subject":{"type":"_future"},"options":[{"optionId":"ok","name":"Allow","kind":"allow_once"}]}}))
    take_v2_frame(transport.outgoing)["result"]["outcome"]["optionId"].should eq("ok")
    transport.inject_raw(%({"jsonrpc":"2.0","id":"removed","method":"fs/read_text_file","params":{}}))
    take_v2_frame(transport.outgoing)["error"]["code"].should eq(-32601)
    transport.inject_raw(%({"jsonrpc":"2.0","id":null,"method":"session/update","params":{}}))
    take_v2_frame(transport.outgoing)["error"]["code"].should eq(-32600)
  ensure
    client.try(&.close)
  end

  it "applies child and entity capabilities only after their replay boundaries" do
    transport = V2TestTransport.new
    transport.replies["session/resume"] = %("result":{})
    transport.replies["tool_call/cancel"] = %("result":{})
    transport.replies["terminal/cancel"] = %("result":{})
    transport.before_reply = ->(method : String) do
      if method == "session/resume"
        transport.update("root", %({"sessionUpdate":"subagent_update","sessionId":"child","capabilities":{"cancel":{}}}))
        transport.update("child", %({"sessionUpdate":"tool_call_update","toolCallId":"historical","capabilities":{"cancel":{}}}))
        transport.update("root", %({"sessionUpdate":"replay_complete"}))
        transport.update("child", %({"sessionUpdate":"replay_complete"}))
        transport.update("child", %({"sessionUpdate":"tool_call_update","toolCallId":"live","capabilities":{"cancel":{}}}))
        transport.update("child", %({"sessionUpdate":"terminal_update","terminalId":"term","capabilities":{"cancel":{}}}))
      end
    end

    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("root", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start))
    take_v2_frame(transport.outgoing)["params"]["replayFrom"]["type"].should eq("start")
    client.subagent("child").not_nil!.parent_session_id.should eq("root")
    client.subagent("child").not_nil!.cancel?.should be_false
    client.session_workspace("child").not_nil!.cwd.should eq("/work")

    expect_raises(ACP::InvalidStateError) { client.session_cancel("child") }
    expect_raises(ACP::InvalidStateError) { client.session_prompt_text("child", "hello") }
    expect_raises(ACP::InvalidStateError) { client.tool_call_cancel("child", "historical") }
    client.tool_call_cancel("child", "live")
    take_v2_frame(transport.outgoing)["params"]["toolCallId"].should eq("live")
    client.terminal_cancel("child", "term")
    take_v2_frame(transport.outgoing)["params"]["terminalId"].should eq("term")

    updates = Channel(Nil).new(1)
    client.on_update = ->(_note : ACP::Protocol::V2::SessionUpdateParams) do
      updates.send(nil)
      nil
    end
    transport.update("child", %({"sessionUpdate":"terminal_update","terminalId":"term","capabilities":null}))
    take_v2_frame(updates)
    expect_raises(ACP::InvalidStateError) { client.terminal_cancel("child", "term") }
  ensure
    client.try(&.close)
  end

  it "answers only the individual permission cancelled by the Agent" do
    transport = V2TestTransport.new
    client = ACP::V2::Client.new(transport)
    entered = Channel(String).new(2)
    release = Channel(Nil).new(2)
    client.on_request_permission = ->(params : ACP::Protocol::V2::RequestPermissionParams) do
      entered.send(params.title)
      release.receive
      ACP::Protocol::V2::RequestPermissionResult.selected("ok")
    end
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    {"stopped", "kept"}.each do |id|
      transport.inject_raw(%({"jsonrpc":"2.0","id":#{id.to_json},"method":"session/request_permission","params":{"sessionId":"s","title":#{id.to_json},"options":[{"optionId":"ok","name":"Allow","kind":"allow_once"}]}}))
    end
    [take_v2_frame(entered), take_v2_frame(entered)].sort.should eq(["kept", "stopped"])
    client.session_cancel("s")
    take_v2_frame(transport.outgoing)["method"].should eq("session/cancel")

    transport.inject_raw(%({"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":"stopped"}}))
    stopped = take_v2_frame(transport.outgoing)
    stopped["id"].should eq("stopped")
    stopped["result"]["outcome"]["outcome"].should eq("cancelled")
    2.times { release.send(nil) }
    kept = take_v2_frame(transport.outgoing)
    kept["id"].should eq("kept")
    kept["result"]["outcome"]["optionId"].should eq("ok")
  ensure
    release.try(&.close)
    client.try(&.close)
  end

  it "checks v2 elicitation capabilities and replies with cancel to a pending elicitation" do
    transport = V2TestTransport.new
    caps = ACP::Protocol::V2::ClientCapabilities.new(elicitation: ACP::Protocol::ElicitationCapabilities.new(form: ACP::Protocol::ElicitationFormCapabilities.new))
    client = ACP::V2::Client.new(transport, capabilities: caps)
    entered = Channel(Nil).new(1)
    release = Channel(Nil).new(1)
    client.on_create_elicitation = ->(_params : ACP::Protocol::CreateElicitationParams) do
      entered.send(nil)
      release.receive
      ACP::Protocol::CreateElicitationResult.decline
    end
    client.initialize_connection
    take_v2_frame(transport.outgoing)

    transport.inject_raw(%({"jsonrpc":"2.0","id":"mode","method":"elicitation/create","params":{"sessionId":"s","mode":"url","message":"Open","elicitationId":"url","url":"https://example.test"}}))
    take_v2_frame(transport.outgoing)["error"]["code"].should eq(-32602)
    transport.inject_raw(%({"jsonrpc":"2.0","id":"scope","method":"elicitation/create","params":{"requestId":null,"mode":"form","message":"Answer","requestedSchema":{"type":"object","properties":{}}}}))
    take_v2_frame(transport.outgoing)["error"]["code"].should eq(-32602)

    transport.inject_raw(%({"jsonrpc":"2.0","id":"question","method":"elicitation/create","params":{"sessionId":"s","mode":"form","message":"Answer","requestedSchema":{"type":"object","properties":{}}}}))
    take_v2_frame(entered)
    transport.inject_raw(%({"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":"question"}}))
    take_v2_frame(transport.outgoing)["result"]["action"].should eq("cancel")
  ensure
    release.try(&.close)
    client.try(&.close)
  end
end

# Uses the actual stdio decoder so the tests cover JSON values beyond JSON::Any.
private class ProxyTestPeer
  getter transport : ACP::StdioTransport
  getter feed : IO::FileDescriptor
  getter outgoing : IO::FileDescriptor

  def initialize(max_line_bytes : Int32 = ACP::StdioTransport::DEFAULT_MAX_LINE_BYTES)
    reader, @feed = IO.pipe
    @outgoing, writer = IO.pipe
    @outgoing.read_timeout = 2.seconds
    @transport = ACP::StdioTransport.new(reader, writer, max_line_bytes: max_line_bytes, exact_frames: true)
  end

  def send(json : String) : Nil
    @feed.puts(json)
    @feed.flush
  end

  def receive : String
    @outgoing.gets || raise "ACP peer closed before replying"
  end

  def read_json : JSON::Any
    JSON.parse(receive)
  end

  def close : Nil
    @feed.close
    @outgoing.close
  end
end

private def proxy_test_link : Tuple(ACP::StdioTransport, ACP::StdioTransport)
  reader, conductor_writer = IO.pipe
  conductor_reader, writer = IO.pipe
  {
    ACP::StdioTransport.new(conductor_reader, conductor_writer, exact_frames: true),
    ACP::StdioTransport.new(reader, writer, exact_frames: true),
  }
end

private def proxy_test_chain(client : ProxyTestPeer, agent : ProxyTestPeer, proxy_count : Int32) : ACP::Conductor
  proxies = Array.new(proxy_count) do
    outward, inward = proxy_test_link
    proxy = ACP::Proxy.new(inward)
    spawn proxy.run
    outward
  end
  conductor = ACP::Conductor.new(client.transport, agent.transport, proxies: proxies)
  spawn conductor.run
  conductor
end

private def proxy_test_initialize(client : ProxyTestPeer, agent : ProxyTestPeer, request : String) : JSON::Any
  client.send(request)
  forwarded = agent.read_json
  forwarded["method"].as_s.should eq("initialize")
  agent.send(%({"jsonrpc":"2.0","id":#{forwarded["id"]},"result":{"protocolVersion":#{forwarded["params"]["protocolVersion"]}}}))
  forwarded["params"]
end

describe ACP::Conductor do
  it "negotiates v2 and routes requests and notifications both ways across two proxies" do
    client, agent = ProxyTestPeer.new, ProxyTestPeer.new
    conductor = proxy_test_chain(client, agent, 2)
    begin
      params = proxy_test_initialize(client, agent, %({"jsonrpc":"2.0","id":"start","method":"initialize","params":{"protocolVersion":2,"info":{"name":"crystal","version":"1"},"_meta":{"exampleExtension":true}}}))
      params["info"]["name"].as_s.should eq("crystal")
      params["_meta"]["exampleExtension"].as_bool.should be_true
      initialized = client.read_json
      initialized["id"].as_s.should eq("start")
      initialized["result"]["protocolVersion"].as_i.should eq(2)

      client.send(%({"jsonrpc":"2.0","id":"shared","method":"_down","params":[18446744073709551615,0.12345678901234567890,null]}))
      agent.send(%({"jsonrpc":"2.0","id":"shared","method":"_up","params":{"_meta":{"exampleExtension":true}}}))
      downstream = agent.receive
      downstream.should contain(%("method":"_down"))
      downstream.should contain(%("params":[18446744073709551615,0.12345678901234567890,null]))
      upstream = client.read_json
      upstream["method"].as_s.should eq("_up")
      upstream["params"]["_meta"]["exampleExtension"].as_bool.should be_true
      downstream_id = ACP::Protocol::RawJson.from_json(downstream).field("id").not_nil!.as_i64?.not_nil!
      upstream_id = upstream["id"].as_i64
      upstream_id.should_not eq(downstream_id)

      agent.send(%({"jsonrpc":"2.0","id":#{downstream_id},"error":{"code":-32040,"message":"Unavailable","data":{"large":18446744073709551615,"precise":0.12345678901234567890},"extra":null}}))
      client.send(%({"jsonrpc":"2.0","id":#{upstream_id},"result":null}))
      client.receive.should eq(%({"jsonrpc":"2.0","id":"shared","error":{"code":-32040,"message":"Unavailable","data":{"large":18446744073709551615,"precise":0.12345678901234567890},"extra":null}}))
      agent.receive.should eq(%({"jsonrpc":"2.0","id":"shared","result":null}))

      agent.send(%({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"extension"}}}))
      client.read_json["method"].as_s.should eq("session/update")
      client.send(%({"jsonrpc":"2.0","method":"_note","params":null}))
      notify = agent.read_json
      notify["method"].as_s.should eq("_note")
      notify["id"]?.should be_nil
      notify["params"]?.should be_nil
    ensure
      conductor.close
      client.close
      agent.close
    end
  end

  it "translates cancellation in both directions and preserves the request reply" do
    client, agent = ProxyTestPeer.new, ProxyTestPeer.new
    conductor = proxy_test_chain(client, agent, 1)
    begin
      proxy_test_initialize(client, agent, %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}))
      client.read_json
      client.send(%({"jsonrpc":"2.0","id":19,"method":"session/prompt","params":{"sessionId":"s"}}))
      agent.send(%({"jsonrpc":"2.0","id":19,"method":"session/request_permission","params":{"sessionId":"s"}}))
      client_request = client.read_json["id"].as_i64
      agent_request = agent.read_json["id"].as_i64
      client.send(%({"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":19,"_meta":{"hop":true}}}))
      agent.send(%({"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":19}}))
      agent_cancel, client_cancel = agent.read_json, client.read_json
      agent_cancel["method"].as_s.should eq("$/cancel_request")
      client_cancel["method"].as_s.should eq("$/cancel_request")
      agent_cancel["params"].as_h.should eq({"requestId" => JSON::Any.new(agent_request)})
      client_cancel["params"].as_h.should eq({"requestId" => JSON::Any.new(client_request)})

      agent.send(%({"jsonrpc":"2.0","id":#{agent_request},"error":{"code":-32800,"message":"Cancelled","data":null}}))
      client.send(%({"jsonrpc":"2.0","id":#{client_request},"result":{}}))
      reply = client.read_json
      reply["id"].as_i.should eq(19)
      reply["error"]["code"].as_i.should eq(-32800)
      reply["error"]["data"].raw.should be_nil
      agent.read_json["id"].as_i.should eq(19)
    ensure
      conductor.close
      client.close
      agent.close
    end
  end
  it "routes nested chains and lets a proxy handle a request and transform capabilities" do
    client, agent = ProxyTestPeer.new, ProxyTestPeer.new
    outside, inside = proxy_test_link
    local, proxy_transport = proxy_test_link
    nested = ACP::Conductor.new(inside, nil, proxies: [local])
    proxy = ACP::Proxy.new(proxy_transport, versions: [1_u16])
    proxy.on_initialize_result = ->(result : ACP::Protocol::RawJson) do
      result.with_field("_meta", ACP::Protocol::RawJson.from_json(%({"local":true})))
    end
    proxy.on_message = ACP::Conductor::MessageHandler.new do |message, direction, request|
      if direction.downstream? && request && message.method == "_local"
        ACP::Protocol::ProxyReply.success(ACP::Protocol::RawJson.from_json(%({"ok":true})))
      else
        message
      end
    end
    conductor = ACP::Conductor.new(client.transport, agent.transport, proxies: [outside])
    spawn conductor.run
    spawn nested.run
    spawn proxy.run
    begin
      received = proxy_test_initialize(client, agent, %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2,"info":{"name":"crystal","version":"1"},"capabilities":{"auth":{"terminal":{}}},"_meta":{"preserved":true}}}))
      received["protocolVersion"].as_i.should eq(1)
      received["info"]?.should be_nil
      received["capabilities"]?.should be_nil
      received["_meta"]["preserved"].as_bool.should be_true
      initial = client.read_json["result"]
      initial["protocolVersion"].as_i.should eq(1)
      initial["_meta"]["local"].as_bool.should be_true

      client.send(%({"jsonrpc":"2.0","id":2,"method":"_local"}))
      client.read_json["result"]["ok"].as_bool.should be_true
      agent.send(%({"jsonrpc":"2.0","id":3,"method":"_back","params":{"nested":true}}))
      forwarded = client.read_json
      forwarded["params"]["nested"].as_bool.should be_true
      client.send(%({"jsonrpc":"2.0","id":#{forwarded["id"]},"result":{"nested":true}}))
      reply = agent.read_json
      reply["id"].as_i.should eq(3)
      reply["result"]["nested"].as_bool.should be_true
    ensure
      conductor.close
      nested.close
      proxy.close
      client.close
      agent.close
    end
  end

  it "retries malformed and failed initialization while retaining a previous successful version" do
    client, agent = ProxyTestPeer.new, ProxyTestPeer.new
    conductor = proxy_test_chain(client, agent, 1)
    begin
      client.send(%({"jsonrpc":"2.0","id":1,"method":"_premature"}))
      client.read_json["error"]["code"].as_i.should eq(-32600)
      client.send(%({"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":2.0}}))
      client.read_json["error"]["code"].as_i.should eq(-32602)
      proxy_test_initialize(client, agent, %({"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":2}}))
      client.read_json["result"]["protocolVersion"].as_i.should eq(2)

      client.send(%({"jsonrpc":"2.0","id":4,"method":"initialize","params":{"protocolVersion":1,"clientInfo":{"name":"crystal","version":"1"}}}))
      request = agent.read_json
      request["params"]["clientInfo"]["name"].as_s.should eq("crystal")
      agent.send(%({"jsonrpc":"2.0","id":#{request["id"]},"error":{"code":-32602,"message":"Initialization refused"}}))
      client.read_json["error"]["message"].as_s.should eq("Initialization refused")

      proxy_test_initialize(client, agent, %({"jsonrpc":"2.0","id":5,"method":"initialize","params":{"protocolVersion":2}}))
      client.read_json["result"]["protocolVersion"].as_i.should eq(2)
      client.send(%({"jsonrpc":"2.0","id":null,"method":"_null_id"}))
      client.read_json["error"]["code"].as_i.should eq(-32600)
      client.send(%({"jsonrpc":"2.0","id":6,"method":"_ready"}))
      forwarded = agent.read_json
      forwarded["method"].as_s.should eq("_ready")
      agent.send(%({"jsonrpc":"2.0","id":#{forwarded["id"]},"result":{}}))
      client.read_json["id"].as_i.should eq(6)
      client.send(%({"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":2}}))
      client.read_json["error"]["code"].as_i.should eq(-32600)
    ensure
      conductor.close
      client.close
      agent.close
    end
  end

  it "rejects wrong successor peers and invalid wrapper params and translates wrapped cancellation" do
    client, agent, proxy = ProxyTestPeer.new, ProxyTestPeer.new, ProxyTestPeer.new
    conductor = ACP::Conductor.new(client.transport, agent.transport, proxies: [proxy.transport])
    spawn conductor.run
    begin
      client.send(%({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2}}))
      proxy_init = proxy.read_json
      proxy_init["method"].as_s.should eq("proxy/initialize")
      proxy.send(%({"jsonrpc":"2.0","id":"p-init","method":"proxy/successor","params":{"method":"initialize","params":{"protocolVersion":2}}}))
      agent_init = agent.read_json
      agent_init["method"].as_s.should eq("initialize")
      agent.send(%({"jsonrpc":"2.0","id":#{agent_init["id"]},"result":{"protocolVersion":2}}))
      proxy.read_json["id"].as_s.should eq("p-init")
      proxy.send(%({"jsonrpc":"2.0","id":#{proxy_init["id"]},"result":{"protocolVersion":2}}))
      client.read_json["result"]["protocolVersion"].as_i.should eq(2)

      client.send(%({"jsonrpc":"2.0","id":2,"method":"proxy/successor","params":{"method":"_bad"}}))
      agent.send(%({"jsonrpc":"2.0","id":3,"method":"proxy/successor","params":{"method":"_bad"}}))
      proxy.send(%({"jsonrpc":"2.0","id":4,"method":"proxy/successor","params":{"method":"_bad","params":45}}))
      client.read_json["error"]["code"].as_i.should eq(-32600)
      agent.read_json["error"]["code"].as_i.should eq(-32600)
      proxy.read_json["error"]["code"].as_i.should eq(-32602)

      proxy.send(%({"jsonrpc":"2.0","id":5,"method":"proxy/successor","params":{"method":"proxy/initialize"}}))
      proxy.read_json["error"]["code"].as_i.should eq(-32600)
      proxy.send(%({"jsonrpc":"2.0","id":"p-call","method":"proxy/successor","params":{"method":"_call","params":{"_meta":{"inner":true}},"_meta":{"outer":true}}}))
      call = agent.read_json
      call["method"].as_s.should eq("_call")
      call["params"]["_meta"].as_h.should eq({"inner" => JSON::Any.new(true)})
      proxy.send(%({"jsonrpc":"2.0","method":"proxy/successor","params":{"method":"$/cancel_request","params":{"requestId":"p-call"},"_meta":{"outer":true}}}))
      cancellation = agent.read_json
      cancellation["method"].as_s.should eq("$/cancel_request")
      cancellation["params"]["requestId"].should eq(call["id"])
      cancellation["params"]["_meta"]?.should be_nil
      agent.send(%({"jsonrpc":"2.0","id":#{call["id"]},"result":[1,2,3]}))
      reply = proxy.read_json
      reply["id"].as_s.should eq("p-call")
      reply["result"].as_a.size.should eq(3)
    ensure
      conductor.close
      client.close
      agent.close
      proxy.close
    end
  end

  it "closes the chain when a proxy rejects a successful repeated initialization" do
    client, agent = ProxyTestPeer.new, ProxyTestPeer.new
    outside, inside = proxy_test_link
    proxy = ACP::Proxy.new(inside)
    conductor = ACP::Conductor.new(client.transport, agent.transport, proxies: [outside])
    spawn conductor.run
    spawn proxy.run
    begin
      proxy_test_initialize(client, agent, %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2}}))
      client.read_json["result"]["protocolVersion"].as_i.should eq(2)
      proxy.on_initialize_result = ->(result : ACP::Protocol::RawJson) do
        result.with_field("protocolVersion", ACP::Protocol::RawJson.from_json("2"))
      end
      proxy_test_initialize(client, agent, %({"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":1}}))
      client.outgoing.gets.should be_nil
      agent.outgoing.gets.should be_nil
    ensure
      conductor.close
      proxy.close
      client.close
      agent.close
    end
  end
  it "reports supported versions and lets a client retry the same connection" do
    client, agent = ProxyTestPeer.new, ProxyTestPeer.new
    conductor = ACP::Conductor.new(client.transport, agent.transport, versions: [2_u16])
    spawn conductor.run
    begin
      client.send(%({"jsonrpc":"2.0","id":"wrong","method":"initialize","params":{"protocolVersion":1}}))
      error = client.read_json["error"]
      error["code"].as_i.should eq(-32022)
      error["data"]["requested"].as_i.should eq(1)
      error["data"]["supported"].as_a.map(&.as_i).should eq([2])
      params = proxy_test_initialize(client, agent, %({"jsonrpc":"2.0","id":"right","method":"initialize","params":{"protocolVersion":2}}))
      params["protocolVersion"].as_i.should eq(2)
      client.read_json["id"].as_s.should eq("right")
    ensure
      conductor.close
      client.close
      agent.close
    end
  end

  it "closes the chain when a forwarded frame exceeds a peer's wire limit" do
    client, agent = ProxyTestPeer.new, ProxyTestPeer.new(128)
    conductor = proxy_test_chain(client, agent, 0)
    begin
      proxy_test_initialize(client, agent, %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}))
      client.read_json
      client.send(%({"jsonrpc":"2.0","id":2,"method":"_large","params":{"payload":"#{"x" * 128}"}}))
      client.outgoing.gets.should be_nil
      agent.outgoing.gets.should be_nil
    ensure
      conductor.close
      client.close
      agent.close
    end
  end
  it "closes on a malformed correlated initialization response" do
    client, agent = ProxyTestPeer.new, ProxyTestPeer.new
    conductor = proxy_test_chain(client, agent, 0)
    begin
      proxy_test_initialize(client, agent, %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2}}))
      client.read_json
      client.send(%({"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":1}}))
      forwarded = agent.read_json
      agent.send(%({"jsonrpc":"2.0","id":#{forwarded["id"]},"result":{"protocolVersion":1},"error":{"code":-32602,"message":"Ambiguous outcome"}}))
      client.outgoing.gets.should be_nil
      agent.outgoing.gets.should be_nil
    ensure
      conductor.close
      client.close
      agent.close
    end
  end
end

describe ACP::Protocol::Usage do
  it "handles optional counts and preserves prompt-result constructor compatibility" do
    metadata = {"test" => JSON::Any.new(true)}
    usage = ACP::Protocol::Usage.new(13_u64, 10_u64, 3_u64, cached_write_tokens: 0_u64, meta: metadata)
    result = ACP::Protocol::SessionPromptResult.new("end_turn", metadata, usage: usage)
    decoded = ACP::Protocol::SessionPromptResult.from_json(result.to_json)
    decoded.stop_reason.should eq("end_turn")
    decoded.meta.should eq(metadata)
    decoded.usage.not_nil!.cached_write_tokens.should eq(0_u64)
    decoded.usage.not_nil!.meta.should eq(metadata)

    parsed = ACP::Protocol::Usage.from_json(%({"totalTokens":3,"inputTokens":2,"outputTokens":1,"thoughtTokens":-1,"cachedReadTokens":"4","cachedWriteTokens":18446744073709551616}))
    parsed.thought_tokens.should be_nil
    parsed.cached_read_tokens.should be_nil
    parsed.cached_write_tokens.should be_nil

    [%({}), "null", %({"totalTokens":1,"inputTokens":1}), %({"totalTokens":-1,"inputTokens":1,"outputTokens":0}), %({"totalTokens":18446744073709551616,"inputTokens":1,"outputTokens":0})].each do |json|
      response = ACP::Protocol::SessionPromptResult.from_json(%({"stopReason":"end_turn","usage":#{json}}))
      response.stop_reason.should eq("end_turn")
      response.usage.should be_nil
    end
  end

  it "decodes wide usage from an ordinary v1 prompt response over stdio" do
    reader, feed = IO.pipe
    outgoing, writer = IO.pipe
    outgoing.read_timeout = 2.seconds
    client = ACP::Client.new(ACP::StdioTransport.new(reader, writer))
    client.request_timeout = 2.0
    client.prompt_timeout = 2.0
    outcome = Channel(Exception?).new(1)
    spawn do
      init = JSON.parse(outgoing.gets.not_nil!)
      feed.puts %({"jsonrpc":"2.0","id":#{init["id"]},"result":{"protocolVersion":1}})
      setup = JSON.parse(outgoing.gets.not_nil!)
      feed.puts %({"jsonrpc":"2.0","id":#{setup["id"]},"result":{"sessionId":"s"}})
      prompt = JSON.parse(outgoing.gets.not_nil!)
      prompt["method"].as_s.should eq("session/prompt")
      feed.puts %({"jsonrpc":"2.0","id":#{prompt["id"]},"result":{"stopReason":"end_turn","usage":{"totalTokens":18446744073709551615,"inputTokens":9223372036854775808,"outputTokens":10,"thoughtTokens":4,"cachedReadTokens":0,"cachedWriteTokens":null}}})
      outcome.send(nil)
    rescue ex
      outcome.send(ex)
    end

    client.initialize_connection
    session = ACP::Session.create(client, cwd: "/work")
    result = session.prompt("hello")
    result.stop_reason.should eq("end_turn")
    usage = result.usage.not_nil!
    usage.total_tokens.should eq(UInt64::MAX)
    usage.input_tokens.should eq(9223372036854775808_u64)
    usage.output_tokens.should eq(10_u64)
    usage.thought_tokens.should eq(4_u64)
    usage.cached_read_tokens.should eq(0_u64)
    usage.cached_write_tokens.should be_nil
    error = take_v2_frame(outcome)
    raise error if error
  ensure
    client.try(&.close)
    feed.try(&.close)
    outgoing.try(&.close)
  end

  it "exposes exact v2 usage only on idle snapshots and preserves repeated updates" do
    reader, feed = IO.pipe
    outgoing, writer = IO.pipe
    outgoing.read_timeout = 2.seconds
    client = ACP::V2::Client.new(ACP::StdioTransport.new(reader, writer))
    client.request_timeout = 2.0
    updates = Channel(ACP::Protocol::V2::StateUpdate | ACP::Protocol::V2::SubagentUpdate).new(4)
    client.on_update = ->(update : ACP::Protocol::V2::SessionUpdateParams) do
      case typed = update.update.typed
      when ACP::Protocol::V2::StateUpdate, ACP::Protocol::V2::SubagentUpdate
        updates.send(typed)
      end
      nil
    end
    outcome = Channel(Exception?).new(1)
    spawn do
      init = JSON.parse(outgoing.gets.not_nil!)
      feed.puts %({"jsonrpc":"2.0","id":#{init["id"]},"result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}}})
      setup = JSON.parse(outgoing.gets.not_nil!)
      feed.puts %({"jsonrpc":"2.0","id":#{setup["id"]},"result":{"sessionId":"s"}})
      notification = %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn","usage":{"totalTokens":18446744073709551615,"inputTokens":2,"outputTokens":1}}}})
      feed.puts notification
      feed.puts notification
      nested_meta = "[" * 110 + "true" + "]" * 110
      state = %("state":"idle","usage":{"totalTokens":3,"inputTokens":2,"outputTokens":1,"_meta":{"nested":#{nested_meta}}})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"subagent_update","sessionId":"child","state":{#{state}}}}})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"child","update":{"sessionUpdate":"state_update",#{state}}}})
      outcome.send(nil)
    rescue ex
      outcome.send(ex)
    end
    client.initialize_connection
    client.session_new("/work")
    2.times do
      state = take_v2_frame(updates).as(ACP::Protocol::V2::StateUpdate)
      state.stop_reason.should eq("end_turn")
      state.usage.not_nil!.total_tokens.should eq(UInt64::MAX)
      state.to_json.should contain(%("totalTokens":18446744073709551615))
    end
    subagent = take_v2_frame(updates).as(ACP::Protocol::V2::SubagentUpdate)
    subagent.state.not_nil!.usage.not_nil!.total_tokens.should eq(3_u64)
    child = take_v2_frame(updates).as(ACP::Protocol::V2::StateUpdate)
    child.usage.not_nil!.meta.not_nil!.has_key?("nested").should be_true
    error = take_v2_frame(outcome)
    raise error if error

    idle = ACP::Protocol::V2::StateSnapshot.from_json(%({"state":"idle","usage":{"totalTokens":3,"inputTokens":2,"outputTokens":1}}))
    idle.usage.not_nil!.total_tokens.should eq(3_u64)
    running = ACP::Protocol::V2::StateSnapshot.from_json(%({"state":"running","usage":{"totalTokens":3,"inputTokens":2,"outputTokens":1}}))
    running.usage.should be_nil
    empty = ACP::Protocol::V2::StateSnapshot.from_json(%({"state":"idle","usage":null}))
    empty.usage.should be_nil
  ensure
    client.try(&.close)
    feed.try(&.close)
    outgoing.try(&.close)
  end
end

private class V2InitializationDispatchTransport < V2TestTransport
  property read_barrier : Channel(Nil)?

  def receive : JSON::Any?
    @read_barrier.try(&.send(nil))
    super
  end
end

describe "ACP v2 repeated initialization" do
  it "replaces the advertised identity and capabilities before dispatching the next Agent request" do
    transport = V2TestTransport.new
    client = ACP::V2::Client.new(transport)
    client.initialize_connection.info.name.should eq("agent")
    take_v2_frame(transport.outgoing)
    client.ext_notification("hello")
    take_v2_frame(transport.outgoing)["method"].should eq("_hello")

    info = ACP::Protocol::ClientInfo.new("updated-client", "2")
    caps = ACP::Protocol::V2::ClientCapabilities.new(
      elicitation: ACP::Protocol::ElicitationCapabilities.new(form: ACP::Protocol::ElicitationFormCapabilities.new)
    )
    observed = Channel(String).new(1)
    client.on_create_elicitation = ->(_request : ACP::Protocol::CreateElicitationParams) do
      observed.send(client.info.name + "/" + client.initialization_result.not_nil!.info.name)
      ACP::Protocol::CreateElicitationResult.decline
    end
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"new-agent","version":"2"},"capabilities":{"session":{"delete":{}}}})
    transport.after_reply = ->(method : String) do
      if method == "initialize"
        transport.inject_raw(%({"jsonrpc":"2.0","id":"form","method":"elicitation/create","params":{"sessionId":"s","mode":"form","message":"Confirm","requestedSchema":{"type":"object","properties":{}}}}))
      end
    end
    result = client.initialize_connection(info: info, capabilities: caps, meta: {"test" => JSON::Any.new(true)})
    result.info.name.should eq("new-agent")
    result.capabilities.session.not_nil!.delete.should_not be_nil
    request = take_v2_frame(transport.outgoing)
    request["params"]["info"]["name"].should eq("updated-client")
    request["params"]["capabilities"]["elicitation"]["form"].should eq(JSON.parse("{}"))
    request["params"]["_meta"]["test"].should eq(true)
    take_v2_frame(observed).should eq("updated-client/new-agent")
    take_v2_frame(transport.outgoing)["result"]["action"].should eq("decline")

    transport.after_reply = nil
    client.initialize_connection
    request = take_v2_frame(transport.outgoing)
    request["params"]["info"]["name"].should eq("updated-client")
    request["params"]["capabilities"]["elicitation"]["form"].should eq(JSON.parse("{}"))
    request["params"]["_meta"]["test"].should eq(true)

    transport.after_reply = ->(method : String) do
      if method == "initialize"
        transport.inject_raw(%({"jsonrpc":"2.0","id":"withdrawn","method":"elicitation/create","params":{"sessionId":"s","mode":"form","message":"Confirm","requestedSchema":{"type":"object","properties":{}}}}))
      end
    end
    client.initialize_connection(capabilities: ACP::Protocol::V2::ClientCapabilities.new, meta: nil)
    request = take_v2_frame(transport.outgoing)
    request["params"]["_meta"]?.should be_nil
    take_v2_frame(transport.outgoing)["error"]["code"].should eq(-32601)
  ensure
    client.try(&.close)
  end

  it "retains the previous negotiation after a peer error and permits another attempt" do
    transport = V2TestTransport.new
    client = ACP::V2::Client.new(transport)
    previous = client.initialize_connection
    take_v2_frame(transport.outgoing)
    original = client.info
    transport.replies["initialize"] = %("error":{"code":-32022,"message":"Request refused","data":{"requested":2,"supported":[]}})
    error = expect_raises(ACP::JsonRpcError, "Request refused") do
      client.initialize_connection(info: ACP::Protocol::ClientInfo.new("rejected", "1"))
    end
    error.unsupported_protocol_version?.should be_true
    error.received?.should be_true
    error.data.not_nil!["requested"].should eq(2)
    client.info.should eq(original)
    client.initialization_result.should eq(previous)
    client.closed?.should be_false
    take_v2_frame(transport.outgoing)

    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"accepted","version":"1"},"capabilities":{"session":{}}})
    client.initialize_connection.info.name.should eq("accepted")
    take_v2_frame(transport.outgoing)["params"]["info"]["name"].should eq(original.name)

    transport.replies["_diagnostics"] = %("error":{"code":-32601,"message":"Unknown method"})
    expect_raises(ACP::JsonRpcError, /Unknown method/) { client.ext_method("diagnostics") }
    expect_raises(ACP::InvalidStateError, /precede other requests/) { client.initialize_connection }
    transport.sent_messages.map(&.["method"].as_s).should eq(["initialize", "initialize", "initialize", "_diagnostics"])
  ensure
    client.try(&.close)
  end

  it "prevents regular requests and a second handshake while a repeat is awaiting its response" do
    transport = V2TestTransport.new
    client = ACP::V2::Client.new(transport)
    initial = client.initialize_connection
    take_v2_frame(transport.outgoing)
    transport.replies.delete("initialize")

    response = Channel(ACP::Protocol::V2::InitializeResult | Exception).new(1)
    spawn do
      result = client.initialize_connection
      response.send(result)
    rescue ex
      response.send(ex)
    end
    repeat = take_v2_frame(transport.outgoing)
    client.initialization_result.should eq(initial)
    expect_raises(ACP::InvalidStateError, /in progress/) { client.initialize_connection }
    expect_raises(ACP::InvalidStateError, /in progress/) { client.ext_method("premature") }
    transport.sent_messages.size.should eq(2)

    transport.inject_raw(%({"jsonrpc":"2.0","id":#{repeat["id"]},"result":{"protocolVersion":2,"info":{"name":"new-agent","version":"2"},"capabilities":{"session":{}}}}))
    take_v2_frame(response).as(ACP::Protocol::V2::InitializeResult).info.name.should eq("new-agent")
    transport.replies["session/new"] = %("result":{"sessionId":"s"})
    client.session_new("/work").session_id.should eq("s")
    expect_raises(ACP::InvalidStateError, /precede other requests/) { client.initialize_connection }
  ensure
    client.try(&.close)
  end

  it "keeps the repeat window open when the first regular request fails its local write check" do
    transport = QueuedRequestTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"mcp":{"acp":{}}}}})
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    take_v2_frame(transport.outgoing)

    outcome = Channel(Exception?).new(1)
    spawn do
      declaration = ACP::Protocol::McpServerAcp.new("missing", "unknown-server")
      server = ACP::Protocol::V2::McpServer.acp(declaration)
      client.session_new(ACP::Protocol::V2::SessionNewParams.new("/work", mcp_servers: [server]))
      outcome.send(nil)
    rescue ex
      outcome.send(ex)
    end
    take_v2_frame(transport.queued)
    expect_raises(ACP::InvalidStateError, /precede other requests/) { client.initialize_connection }
    transport.ready_to_write.send(nil)
    failure = take_v2_frame(outcome)
    failure.should be_a(ACP::InvalidStateError)
    failure.not_nil!.message.should match(/registered/)
    client.initialize_connection.info.name.should eq("agent")
    transport.sent_messages.map(&.["method"].as_s).should eq(["initialize", "initialize"])
  ensure
    client.try(&.close)
    transport.try(&.ready_to_write.close)
  end

  it "ignores initialize replies until the request reaches the writer and matches the numeric ID" do
    transport = QueuedRequestTransport.new
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    take_v2_frame(transport.outgoing)

    checkpoint = Channel(Nil).new(1)
    client.on_notification = ->(method : String, _params : JSON::Any?) do
      checkpoint.send(nil) if method == "_checkpoint"
    end
    transport.pause_initialize = true
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"accepted","version":"1"}})
    outcome = Channel(ACP::Protocol::V2::InitializeResult | Exception).new(1)
    spawn do
      outcome.send(client.initialize_connection)
    rescue ex
      outcome.send(ex)
    end
    take_v2_frame(transport.queued)
    id = transport.queued_message.not_nil!["id"]
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{id},"result":{"protocolVersion":2,"info":{"name":"early","version":"1"}}}))
    transport.inject_raw(%({"jsonrpc":"2.0","method":"_checkpoint"}))
    take_v2_frame(checkpoint)
    client.initialization_result.not_nil!.info.name.should eq("agent")

    transport.before_reply = ->(_method : String) do
      transport.inject_raw(%({"jsonrpc":"2.0","id":"#{id}","result":{"protocolVersion":2,"info":{"name":"string-id","version":"1"}}}))
      transport.inject_raw(%({"jsonrpc":"2.0","id":#{id}.00000000000000001,"result":{"protocolVersion":2,"info":{"name":"fractional-id","version":"1"}}}))
    end
    transport.ready_to_write.send(nil)
    take_v2_frame(outcome).as(ACP::Protocol::V2::InitializeResult).info.name.should eq("accepted")
  ensure
    client.try(&.close)
    transport.try(&.ready_to_write.close)
  end

  it "stops dispatch before returning a malformed initialization outcome" do
    result = %("result":{"protocolVersion":2,"info":{"name":"new-agent","version":"1"}})
    {"2.0" => result + %(,"error":{"code":-32602,"message":"ambiguous"}), "1.0" => result}.each do |version, reply|
      transport = V2InitializationDispatchTransport.new
      client = ACP::V2::Client.new(transport)
      client.initialize_connection
      take_v2_frame(transport.outgoing)

      received_notification = false
      client.on_notification = ->(method : String, _params : JSON::Any?) do
        received_notification = true if method == "_after_invalid"
        nil
      end
      barrier = Channel(Nil).new(2)
      transport.before_reply = ->(_method : String) do
        transport.read_barrier = barrier
        nil
      end
      transport.after_reply = ->(_method : String) do
        transport.inject_raw(%({"jsonrpc":"2.0","method":"_after_invalid"}))
        take_v2_frame(barrier)
        take_v2_frame(barrier)
        transport.read_barrier = nil
        nil
      end
      transport.response_version = version
      transport.replies["initialize"] = reply
      expect_raises(ACP::ProtocolError, /malformed initialization response/) { client.initialize_connection }
      received_notification.should be_false
      client.closed?.should be_true
    ensure
      barrier.try(&.close)
      client.try(&.close)
    end
  end

  it "rechecks queued notifications at write time after an ambiguous repeat" do
    transport = QueuedRequestTransport.new
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    transport.replies.delete("initialize")

    initialization = Channel(Exception?).new(1)
    spawn do
      client.initialize_connection
      initialization.send(nil)
    rescue ex
      initialization.send(ex)
    end
    repeat = take_v2_frame(transport.outgoing)
    notification = Channel(Exception?).new(1)
    spawn do
      client.ext_notification("queued")
      notification.send(nil)
    rescue ex
      notification.send(ex)
    end
    take_v2_frame(transport.queued)
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{repeat["id"]},"result":{"protocolVersion":2}}))
    take_v2_frame(initialization).should be_a(ACP::ProtocolError)
    transport.ready_to_write.send(nil)
    take_v2_frame(notification).should be_a(ACP::ConnectionClosedError)
    transport.sent_messages.map(&.["method"].as_s).should eq(["initialize", "initialize"])
  ensure
    client.try(&.close)
    transport.try(&.ready_to_write.close)
  end

  it "closes a connection immediately if a repeat times out" do
    transport = V2TestTransport.new
    client = ACP::V2::Client.new(transport)
    client.initialize_connection
    take_v2_frame(transport.outgoing)
    transport.replies.delete("initialize")
    client.request_timeout = 0.02
    expect_raises(ACP::RequestTimeoutError) { client.initialize_connection }
    take_v2_frame(transport.outgoing)["method"].should eq("initialize")
    transport.sent_messages.map(&.["method"].as_s).should eq(["initialize", "initialize"])
    client.closed?.should be_true
  ensure
    client.try(&.close)
  end
end

describe ACP::V2::TerminalStore do
  it "accumulates received bytes before a tool references the terminal" do
    transport = V2TestTransport.new
    transport.replies["session/new"] = %("result":{"sessionId":"session"})
    client = ACP::V2::Client.new(transport)
    store = ACP::V2::TerminalStore.new
    observed = Channel(Bool).new(1)
    client.on_update = ->(params : ACP::Protocol::V2::SessionUpdateParams) do
      observed.send(store.observe(params))
      nil
    end
    client.initialize_connection
    client.session_new("/work")
    store.terminal("session", "term").should be_nil

    transport.update("session", %({"sessionUpdate":"terminal_output_chunk","terminalId":"term","data":"4g=="}))
    take_v2_frame(observed).should be_true
    store.terminal("session", "term").not_nil!.output.should eq(Bytes[0xe2])
    transport.update("session", %({"sessionUpdate":"tool_call_update","toolCallId":"term","content":[{"type":"terminal","terminalId":"term"}]}))
    take_v2_frame(observed).should be_false
    transport.update("session", %({"sessionUpdate":"terminal_update","terminalId":"term","exitStatus":{"exitCode":0}}))
    take_v2_frame(observed).should be_true
    transport.update("session", %({"sessionUpdate":"terminal_output_chunk","terminalId":"term","data":"gqw="}))
    take_v2_frame(observed).should be_true
    snapshot = store.terminal("session", "term").not_nil!
    snapshot.exit_status.not_nil!.exit_code.should eq(0)
    snapshot.output.should eq("€".to_slice)

    transport.update("session", %({"sessionUpdate":"terminal_output_chunk","terminalId":"term","data":"YQ"}))
    take_v2_frame(observed).should be_false
    store.terminal("session", "term").not_nil!.output.should eq("€".to_slice)
  ensure
    client.try(&.close)
  end

  it "replaces snapshots and patches only the addressed terminal while preserving exact metadata" do
    store = ACP::V2::TerminalStore.new
    observe = ->(session : String, update : String) do
      store.observe(ACP::Protocol::V2::SessionUpdateParams.from_json(%({"sessionId":#{session.to_json},"update":#{update}})))
    end
    id = "term"
    wide = "18446744073709551615"
    fraction = "0.123456789012345678901"
    observe.call("other", %({"sessionUpdate":"terminal_output_chunk","terminalId":"term","data":"WA=="})).should be_true
    observe.call("main", %({"sessionUpdate":"terminal_output_chunk","terminalId":"term","data":"YQ==","_meta":{"chunk":true}})).should be_true
    observe.call("main", %({"sessionUpdate":"terminal_update","terminalId":"term","command":"fixture","cwd":"/work","size":{"cols":80,"rows":24,"_meta":{"wide":#{wide}}},"output":{"data":"Yg==","_meta":{"fraction":#{fraction}}},"capabilities":{"cancel":{}},"_meta":{"wide":#{wide},"drop":1}})).should be_true
    observe.call("main", %({"sessionUpdate":"terminal_output_chunk","terminalId":"term","data":"Yw==","_meta":{"fraction":0}})).should be_true
    observe.call("main", %({"sessionUpdate":"terminal_update","terminalId":"term","cwd":"relative","size":{"cols":0,"rows":24},"output":{"data":"YQ"},"exitStatus":{"signal":"SIGTERM","_meta":{"wide":#{wide}}},"_meta":{"drop":null,"new":#{fraction}}})).should be_true

    snapshot = store.terminal("main", id).not_nil!
    snapshot.session_id.should eq("main")
    snapshot.terminal_id.should eq(id)
    snapshot.command.should eq("fixture")
    snapshot.cwd.should eq("/work")
    snapshot.size.not_nil!.cols.should eq(80)
    snapshot.size.not_nil!.meta_raw.not_nil!.field("wide").not_nil!.json.should eq(wide)
    snapshot.output.should eq("bc".to_slice)
    snapshot.output_meta_raw.not_nil!.field("fraction").not_nil!.json.should eq(fraction)
    snapshot.exit_status.not_nil!.signal.should eq("SIGTERM")
    snapshot.exit_status.not_nil!.meta_raw.not_nil!.field("wide").not_nil!.json.should eq(wide)
    snapshot.capabilities.not_nil!.cancel.should_not be_nil
    snapshot.meta_raw.not_nil!.field("wide").not_nil!.json.should eq(wide)
    snapshot.meta_raw.not_nil!.field("new").not_nil!.json.should eq(fraction)
    snapshot.meta_raw.not_nil!.field("drop").should be_nil
    snapshot.meta_raw.not_nil!.field("chunk").should be_nil
    snapshot.output.not_nil![0] = 0_u8
    snapshot.size.not_nil!.meta.not_nil!["injected"] = JSON::Any.new(true)
    store.terminal("main", id).not_nil!.output.should eq("bc".to_slice)
    store.terminal("main", id).not_nil!.size.not_nil!.meta.not_nil!.has_key?("injected").should be_false
    store.terminal("other", id).not_nil!.output.should eq("X".to_slice)

    observe.call("main", %({"sessionUpdate":"terminal_update","terminalId":"term","command":null,"cwd":null,"size":null,"output":null,"exitStatus":null,"capabilities":null,"_meta":null})).should be_true
    cleared = store.terminal("main", id).not_nil!
    cleared.command.should be_nil
    cleared.cwd.should be_nil
    cleared.size.should be_nil
    cleared.output.should be_nil
    cleared.exit_status.should be_nil
    cleared.capabilities.should be_nil
    cleared.meta_raw.should be_nil
    cleared.output_meta_raw.should be_nil
    observe.call("main", %({"sessionUpdate":"terminal_output_chunk","terminalId":"term","data":""})).should be_true
    store.terminal("main", id).not_nil!.output.should eq(Bytes.empty)
    store.forget_session("main").should be_true
    store.forget_session("main").should be_false
    store.terminal("main", id).should be_nil
    store.terminal("other", id).not_nil!.output.should eq("X".to_slice)
  end

  it "retains the newest bytes within the configured limit after append and replacement" do
    expect_raises(ArgumentError, /non-negative/) { ACP::V2::TerminalStore.new(output_byte_limit: -1) }
    {0, 4}.each do |limit|
      store = ACP::V2::TerminalStore.new(output_byte_limit: limit)
      observe = ->(fields : String) do
        store.observe(ACP::Protocol::V2::SessionUpdateParams.from_json(%({"sessionId":"session","update":#{fields}})))
      end
      observe.call(%({"sessionUpdate":"terminal_output_chunk","terminalId":"t","data":"QUJD"})).should be_true
      observe.call(%({"sessionUpdate":"terminal_output_chunk","terminalId":"t","data":"REU="})).should be_true
      store.terminal("session", "t").not_nil!.output.should eq(limit.zero? ? Bytes.empty : "BCDE".to_slice)
      observe.call(%({"sessionUpdate":"terminal_update","terminalId":"t","output":{"data":"MDEyMzQ1"}})).should be_true
      store.terminal("session", "t").not_nil!.output.should eq(limit.zero? ? Bytes.empty : "2345".to_slice)
      observe.call(%({"sessionUpdate":"terminal_output_chunk","terminalId":"t","data":"eA=="})).should be_true
      store.terminal("session", "t").not_nil!.output.should eq(limit.zero? ? Bytes.empty : "345x".to_slice)
    end
  end

  it "bounds new entries and cumulative terminal metadata without dropping other patch fields" do
    store = ACP::V2::TerminalStore.new(terminal_limit: 1, terminal_metadata_byte_limit: 16)
    observe = ->(session : String, fields : String) do
      store.observe(ACP::Protocol::V2::SessionUpdateParams.from_json(%({"sessionId":#{session.to_json},"update":#{fields}})))
    end
    observe.call("main", %({"sessionUpdate":"terminal_update","terminalId":"t","_meta":{"a":"abc"}})).should be_true
    observe.call("other", %({"sessionUpdate":"terminal_update","terminalId":"t"})).should be_false
    store.terminal("other", "t").should be_nil
    observe.call("main", %({"sessionUpdate":"terminal_update","terminalId":"t","command":"fixture","_meta":{"b":"def"}})).should be_true
    snapshot = store.terminal("main", "t").not_nil!
    snapshot.command.should eq("fixture")
    snapshot.meta_raw.not_nil!.json.should eq(%({"a":"abc"}))
    observe.call("main", %({"sessionUpdate":"terminal_update","terminalId":"t","_meta":{"a":null,"b":"def"}})).should be_true
    store.terminal("main", "t").not_nil!.meta_raw.not_nil!.json.should eq(%({"b":"def"}))
    store.forget_session("main").should be_true
    observe.call("other", %({"sessionUpdate":"terminal_update","terminalId":"t"})).should be_true
  end
end

describe ACP::V2::ToolCallStore do
  it "applies permission tool patches between streamed items and before the permission handler" do
    transport = V2TestTransport.new
    client = ACP::V2::Client.new(transport)
    store = ACP::V2::ToolCallStore.new
    observed = Channel(Bool).new(4)
    permission_snapshot = Channel(ACP::V2::ToolCallSnapshot?).new(1)
    client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
      observed.send(store.observe(note))
      nil
    end
    client.on_request_permission = ->(permission : ACP::Protocol::V2::RequestPermissionParams) do
      permission_snapshot.send(store.tool_call(permission.session_id, "t"))
      ACP::Protocol::V2::RequestPermissionResult.cancelled
    end
    client.initialize_connection
    take_v2_frame(transport.outgoing)

    transport.update("s", %({"sessionUpdate":"tool_call_content_chunk","toolCallId":"t","content":{"type":"content","content":{"type":"text","text":"old"}},"_meta":{"chunk":true}}))
    take_v2_frame(observed).should be_true
    first = store.tool_call("s", "t").not_nil!
    first.kind.should eq("other")
    first.status.should eq("pending")
    first.title.should be_nil
    first.locations.should be_empty
    first.meta_raw.should be_nil
    first.content.first.meta_raw.should be_nil
    first.content.first.content_block.as(ACP::Protocol::TextContentBlock).text.should eq("old")

    transport.inject_raw(%({"jsonrpc":"2.0","id":"p","method":"session/request_permission","params":{"sessionId":"s","title":"Review tool","subject":{"type":"tool_call","toolCall":{"toolCallId":"t","title":"Review","status":"in_progress","content":[{"type":"content","content":{"type":"text","text":"new"}}]}},"options":[{"optionId":"deny","name":"Deny","kind":"reject_once"}]}}))
    take_v2_frame(observed).should be_true
    during_permission = take_v2_frame(permission_snapshot).not_nil!
    during_permission.title.should eq("Review")
    during_permission.status.should eq("in_progress")
    during_permission.content.map(&.content_block.as(ACP::Protocol::TextContentBlock).text).should eq(["new"])
    take_v2_frame(transport.outgoing)["result"]["outcome"]["outcome"].should eq("cancelled")

    transport.update("s", %({"sessionUpdate":"tool_call_content_chunk","toolCallId":"t","content":{"type":"content","content":{"type":"text","text":"er"}}}))
    take_v2_frame(observed).should be_true
    store.tool_call("s", "t").not_nil!.content.map(&.content_block.as(ACP::Protocol::TextContentBlock).text).should eq(["new", "er"])
  ensure
    client.try(&.close)
  end

  it "preserves exact open data, patches fields, and isolates detached snapshots by session" do
    store = ACP::V2::ToolCallStore.new
    observe = ->(session : String, fields : String) do
      store.observe(ACP::Protocol::V2::SessionUpdateParams.from_json(%({"sessionId":#{session.to_json},"update":#{fields}})))
    end
    wide = "18446744073709551615"
    fraction = "0.123456789012345678901"
    observe.call("other", %({"sessionUpdate":"tool_call_update","toolCallId":"t","title":"Other"})).should be_true
    observe.call("main", %({"sessionUpdate":"tool_call_update","toolCallId":"t","name":"fixture","title":"Main","kind":"_fixture","status":"completed","locations":[{"path":"/work/file","line":3}],"rawInput":{"wide":#{wide}},"rawOutput":#{fraction},"capabilities":{"cancel":{}},"content":[{"type":"_fixture","wide":#{wide},"_meta":{"exact":#{fraction}}}],"_meta":{"wide":#{wide},"drop":1}})).should be_true
    store.tool_call("main", "t").not_nil!.raw_input.not_nil!.field("wide").not_nil!.json.should eq(wide)
    observe.call("main", %({"sessionUpdate":"tool_call_update","toolCallId":"t","name":null,"locations":{},"rawInput":null,"_meta":{"drop":null,"new":#{fraction}}})).should be_true
    snapshot = store.tool_call("main", "t").not_nil!
    snapshot.session_id.should eq("main")
    snapshot.tool_call_id.should eq("t")
    snapshot.name.should be_nil
    snapshot.title.should eq("Main")
    snapshot.kind.should eq("_fixture")
    snapshot.status.should eq("completed")
    snapshot.locations.first.line.should eq(3)
    snapshot.raw_input.should be_nil
    snapshot.raw_output.not_nil!.json.should eq(fraction)
    snapshot.capabilities.not_nil!.cancel.should_not be_nil
    snapshot.content.first.raw.field("wide").not_nil!.json.should eq(wide)
    snapshot.content.first.meta_raw.not_nil!.field("exact").not_nil!.json.should eq(fraction)
    snapshot.meta_raw.not_nil!.field("wide").not_nil!.json.should eq(wide)
    snapshot.meta_raw.not_nil!.field("new").not_nil!.json.should eq(fraction)
    snapshot.meta_raw.not_nil!.field("drop").should be_nil
    snapshot.content.clear
    snapshot.locations.clear
    store.tool_call("main", "t").not_nil!.content.size.should eq(1)
    store.tool_call("main", "t").not_nil!.locations.size.should eq(1)
    observe.call("main", %({"sessionUpdate":"tool_call_update","toolCallId":"t","title":"Multiple","title":"Values"})).should be_false
    store.tool_call("main", "t").not_nil!.title.should eq("Main")

    observe.call("main", %({"sessionUpdate":"tool_call_update","toolCallId":"t","kind":null,"status":null,"content":null,"locations":[],"rawOutput":null,"capabilities":null,"_meta":null})).should be_true
    cleared = store.tool_call("main", "t").not_nil!
    cleared.kind.should eq("other")
    cleared.status.should eq("pending")
    cleared.content.should be_empty
    cleared.locations.should be_empty
    cleared.raw_output.should be_nil
    cleared.capabilities.should be_nil
    cleared.meta_raw.should be_nil
    store.tool_call("other", "t").not_nil!.title.should eq("Other")
    store.forget_session("main").should be_true
    store.forget_session("main").should be_false
    store.tool_call("main", "t").should be_nil
    store.tool_call("other", "t").not_nil!.title.should eq("Other")
  end

  it "limits accumulated state and applies rejected updates atomically" do
    store = ACP::V2::ToolCallStore.new(call_limit: 1, call_byte_limit: 140)
    params = ->(session : String, fields : String) do
      ACP::Protocol::V2::SessionUpdateParams.from_json(%({"sessionId":#{session.to_json},"update":#{fields}}))
    end
    chunk = %({"sessionUpdate":"tool_call_content_chunk","toolCallId":"t","content":{"type":"_fixture","data":#{("x" * 32).to_json}}})
    large_patch = %({"sessionUpdate":"tool_call_update","toolCallId":"t","title":"Discarded","content":[],"rawInput":#{("m" * 200).to_json}})
    store.observe(params.call("main", chunk)).should be_true
    store.observe(params.call("main", chunk)).should be_false
    store.observe(params.call("other", chunk)).should be_false
    store.observe(params.call("main", large_patch)).should be_false
    store.tool_call("main", "t").not_nil!.content.size.should eq(1)
    store.tool_call("main", "t").not_nil!.title.should be_nil
    store.tool_call("other", "t").should be_nil
    store.observe(params.call("main", %({"sessionUpdate":"tool_call_update","toolCallId":"t","content":[]}))).should be_true
    store.tool_call("main", "t").not_nil!.content.should be_empty
    store.observe(params.call("main", chunk)).should be_true
    store.forget_session("main").should be_true
    store.observe(params.call("m" * 150, chunk)).should be_false
    store.observe(params.call("other", chunk)).should be_true

    unlimited = ACP::V2::ToolCallStore.new(call_limit: nil, call_byte_limit: nil)
    unlimited.observe(params.call("main", large_patch)).should be_true
    unlimited.tool_call("main", "t").not_nil!.title.should eq("Discarded")
  end
end

describe ACP::V2::PlanStore do
  it "observes received plan replacements and removals for the addressed session" do
    transport = V2TestTransport.new
    transport.replies["session/new"] = %("result":{"sessionId":"main"})
    client = ACP::V2::Client.new(transport)
    store = ACP::V2::PlanStore.new
    observed = Channel(Bool).new(2)
    client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
      observed.send(store.observe(note))
      nil
    end
    client.initialize_connection
    client.session_new("/work")
    transport.replies["session/new"] = %("result":{"sessionId":"other"})
    client.session_new("/work")

    items = %({"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p","entries":[{"content":"First","priority":"high","status":"pending"}]}})
    transport.update("main", items)
    take_v2_frame(observed).should be_true
    transport.update("other", items)
    take_v2_frame(observed).should be_true
    initial = store.plan("main", "p").not_nil!.plan.typed.as(ACP::Protocol::PlanItems)
    initial.entries.map(&.content).should eq(["First"])
    transport.update("main", %({"sessionUpdate":"plan_update","plan":{"type":"markdown","planId":"p","content":"# Replacement"}}))
    take_v2_frame(observed).should be_true
    store.plan("main", "p").not_nil!.plan.typed.as(ACP::Protocol::PlanMarkdown).content.should eq("# Replacement")
    transport.update("main", %({"sessionUpdate":"plan_update","plan":{"type":"_diagram","planId":"p","nodes":[1]}}))
    take_v2_frame(observed).should be_true
    replacement = store.plan("main", "p").not_nil!
    replacement.plan.type.should eq("_diagram")
    replacement.plan.typed.should be_nil
    replacement.plan_raw.field("nodes").not_nil!.json.should eq("[1]")

    transport.update("main", %({"sessionUpdate":"plan_removed","planId":"p"}))
    take_v2_frame(observed).should be_true
    store.plan("main", "p").should be_nil
    store.plan("other", "p").not_nil!.plan.type.should eq("items")
  ensure
    client.try(&.close)
  end

  it "keeps exact plan and envelope metadata and returns detached snapshots" do
    store = ACP::V2::PlanStore.new
    observe = ->(update : String) do
      store.observe(ACP::Protocol::V2::SessionUpdateParams.from_json(%({"sessionId":"session","update":#{update}})))
    end
    wide = "18446744073709551615"
    fraction = "0.123456789012345678901"
    observe.call(%({"sessionUpdate":"plan_update","plan":{"type":"items","planId":"a","entries":[{"content":"First","priority":"high","status":"_queued","_meta":{"wide":#{wide}}}],"_meta":{"fraction":#{fraction}}},"_meta":{"wide":#{wide}}})).should be_true
    observe.call(%({"sessionUpdate":"plan_update","plan":{"type":"items","planId":"b","entries":[]}})).should be_true
    observe.call(%({"sessionUpdate":"plan_removed","planId":"unknown"})).should be_false
    snapshots = store.plans("session")
    snapshots.map(&.plan_id).should eq(["a", "b"])
    snapshot = snapshots.first
    snapshot.session_id.should eq("session")
    snapshot.meta_raw.not_nil!.field("wide").not_nil!.json.should eq(wide)
    snapshot.plan.meta_raw.not_nil!.field("fraction").not_nil!.json.should eq(fraction)
    entries = snapshot.plan.typed.as(ACP::Protocol::PlanItems).entries
    entries.first.status.should eq("_queued")
    entries.first.meta_raw.not_nil!.field("wide").not_nil!.json.should eq(wide)
    entries.clear
    snapshots.clear
    snapshot.plan.typed.as(ACP::Protocol::PlanItems).entries.size.should eq(1)
    store.plans("session").size.should eq(2)

    observe.call(%({"sessionUpdate":"plan_update","plan":{"type":"items","planId":"a","entries":[]}})).should be_true
    current = store.plan("session", "a").not_nil!
    current.meta_raw.should be_nil
    current.plan.meta_raw.should be_nil
    current.plan.typed.as(ACP::Protocol::PlanItems).entries.should be_empty
    store.forget_session("session").should be_true
    store.forget_session("session").should be_false
    store.plans("session").should be_empty
  end

  it "bounds retained plans and clears a stale snapshot after an over-budget replacement" do
    store = ACP::V2::PlanStore.new(plan_limit: 1, plan_byte_limit: 128)
    params = ->(update : String) do
      ACP::Protocol::V2::SessionUpdateParams.from_json(%({"sessionId":"session","update":#{update}}))
    end
    a = %({"type":"items","planId":"a","entries":[]})
    b = %({"type":"items","planId":"b","entries":[]})
    update = ->(plan : String) { params.call(%({"sessionUpdate":"plan_update","plan":#{plan}})) }
    store.observe(update.call(a)).should be_true
    store.observe(update.call(b)).should be_false
    store.observe(params.call(%({"sessionUpdate":"plan_update","plan":#{a},"plan":#{b}}))).should be_false
    store.observe(update.call(%({"type":"markdown","planId":"a","content":null}))).should be_false
    store.plan("session", "a").not_nil!.plan.type.should eq("items")
    large = update.call(%({"type":"markdown","planId":"a","content":#{("x" * 200).to_json}}))
    store.observe(large).should be_true
    store.plan("session", "a").should be_nil
    store.observe(large).should be_false
    store.observe(update.call(b)).should be_true

    unlimited = ACP::V2::PlanStore.new(plan_limit: nil, plan_byte_limit: nil)
    unlimited.observe(large).should be_true
    unlimited.plan("session", "a").not_nil!.plan.type.should eq("markdown")
  end
end

describe ACP::V2::MessageStore do
  it "applies replay replacements and subsequent chunks by message kind in receive order" do
    transport = V2TestTransport.new
    transport.replies["session/new"] = %("result":{"sessionId":"s"})
    transport.replies["session/resume"] = %("result":{})
    client = ACP::V2::Client.new(transport)
    store = ACP::V2::MessageStore.new
    observed = Channel(Bool).new(12)
    client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
      observed.send(store.observe(note))
      nil
    end
    client.initialize_connection
    client.session_new("/work")

    transport.update("s", %({"sessionUpdate":"agent_message_chunk","messageId":"m","content":{"type":"text","text":"old"},"_meta":{"chunk":true}}))
    take_v2_frame(observed).should be_true
    transport.update("s", %({"sessionUpdate":"agent_message","messageId":"m","_meta":{"retained":true}}))
    take_v2_frame(observed).should be_true
    transport.update("s", %({"sessionUpdate":"user_message_chunk","messageId":"m","content":{"type":"skill","name":"describe"}}))
    take_v2_frame(observed).should be_true
    transport.update("s", %({"sessionUpdate":"agent_thought","messageId":"m"}))
    take_v2_frame(observed).should be_true
    transport.update("s", %({"sessionUpdate":"session_message","messageId":"m","recipientSessionId":"child"}))
    take_v2_frame(observed).should be_true
    store.messages("s").map(&.kind).should eq([ACP::V2::MessageKind::Agent, ACP::V2::MessageKind::User, ACP::V2::MessageKind::Thought, ACP::V2::MessageKind::Session])
    store.message("s", ACP::V2::MessageKind::Agent, "m").not_nil!.content_blocks.first.as(ACP::Protocol::TextContentBlock).text.should eq("old")

    transport.before_reply = ->(method : String) do
      if method == "session/resume"
        transport.update("s", %({"sessionUpdate":"agent_message","messageId":"m","content":[],"_meta":{"replayed":true}}))
        transport.update("s", %({"sessionUpdate":"agent_message_chunk","messageId":"m","content":{"type":"text","text":"replayed"}}))
        transport.update("s", %({"sessionUpdate":"replay_complete"}))
        transport.update("s", %({"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn"}))
      end
      nil
    end
    client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("s", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start))
    take_v2_frame(observed).should be_true
    take_v2_frame(observed).should be_true
    take_v2_frame(observed).should be_false
    take_v2_frame(observed).should be_false
    transport.update("s", %({"sessionUpdate":"agent_message_chunk","messageId":"m","content":{"type":"text","text":" live"}}))
    take_v2_frame(observed).should be_true
    agent = store.message("s", ACP::V2::MessageKind::Agent, "m").not_nil!
    agent.content_blocks.map(&.as(ACP::Protocol::TextContentBlock).text).should eq(["replayed", " live"])
    agent.meta_raw.not_nil!.field("retained").not_nil!.json.should eq("true")
    agent.meta_raw.not_nil!.field("replayed").not_nil!.json.should eq("true")
    agent.meta_raw.not_nil!.field("chunk").should be_nil
    store.message("s", ACP::V2::MessageKind::User, "m").not_nil!.skill_references.map(&.name).should eq(["describe"])
  ensure
    client.try(&.close)
  end

  it "patches directed links, preserves exact blocks, and keeps separate transcripts" do
    store = ACP::V2::MessageStore.new
    observe = ->(sid : String, fields : String) do
      store.observe(ACP::Protocol::V2::SessionUpdateParams.from_json(%({"sessionId":#{sid.to_json},"update":#{fields}})))
    end
    kind = ACP::V2::MessageKind::Session
    wide = "18446744073709551615"
    fraction = "0.123456789012345678901"
    observe.call("main", %({"sessionUpdate":"session_message_chunk","messageId":"m","content":{"type":"_diagram","count":#{wide}}})).should be_true
    observe.call("main", %({"sessionUpdate":"session_message","messageId":"m","senderSessionId":"main","recipientSessionId":"child","senderMessageId":"m","recipientMessageId":"peer","_meta":{"fraction":#{fraction},"drop":1}})).should be_true
    observe.call("child", %({"sessionUpdate":"session_message","messageId":"m","senderSessionId":"main","recipientSessionId":"child","senderMessageId":"m"})).should be_true
    observe.call("main", %({"sessionUpdate":"session_message","messageId":"m","recipientSessionId":false,"recipientMessageId":null,"content":{},"_meta":{"drop":null}})).should be_true

    message = store.message("main", kind, "m").not_nil!
    message.session_id.should eq("main")
    message.sender_session_id.should eq("main")
    message.sender_message_id.should eq("m")
    message.recipient_session_id.should eq("child")
    message.recipient_message_id.should be_nil
    message.content_blocks.first.as(ACP::Protocol::UnknownContentBlock).raw.field("count").not_nil!.json.should eq(wide)
    message.meta_raw.not_nil!.field("fraction").not_nil!.json.should eq(fraction)
    message.meta_raw.not_nil!.field("drop").should be_nil
    message.content_raw.clear
    store.message("main", kind, "m").not_nil!.content_raw.size.should eq(1)

    observe.call("main", %({"sessionUpdate":"session_message","messageId":"m","content":[false,{"type":"_diagram","count":#{wide}}]})).should be_true
    replacement = store.message("main", kind, "m").not_nil!
    replacement.content_raw.map(&.json).should eq(["false", %({"type":"_diagram","count":#{wide}})])
    replacement.content_blocks.first.as(ACP::Protocol::UnknownContentBlock).raw.field("count").not_nil!.json.should eq(wide)

    observe.call("main", %({"sessionUpdate":"session_message","messageId":"m","content":null,"_meta":null})).should be_true
    store.message("main", kind, "m").not_nil!.content_raw.should be_empty
    store.message("main", kind, "m").not_nil!.meta_raw.should be_nil
    store.forget_session("main").should be_true
    store.forget_session("main").should be_false
    store.message("child", kind, "m").not_nil!.sender_session_id.should eq("main")
  end

  it "records retention gaps and resumes appending after an accepted content replacement" do
    store = ACP::V2::MessageStore.new(message_limit: 1, message_byte_limit: 160)
    params = ->(fields : String) do
      ACP::Protocol::V2::SessionUpdateParams.from_json(%({"sessionId":"main","update":#{fields}}))
    end
    kind = ACP::V2::MessageKind::Session
    chunk = ->(text : String) { params.call(%({"sessionUpdate":"session_message_chunk","messageId":"m","content":{"type":"text","text":#{text.to_json}}})) }
    excess = "x" * 200
    oversized_link = params.call(%({"sessionUpdate":"session_message","messageId":"m","recipientSessionId":#{excess.to_json}}))
    oversized_replacement = params.call(%({"sessionUpdate":"session_message","messageId":"m","content":[{"type":"text","text":#{excess.to_json}}]}))
    store.observe(chunk.call("start")).should be_true
    store.observe(oversized_link).should be_false
    store.observe(params.call(%({"sessionUpdate":"user_message","messageId":"m"}))).should be_false
    store.messages("main").size.should eq(1)
    store.message("main", kind, "m").not_nil!.recipient_session_id.should be_nil
    store.message("main", kind, "m").not_nil!.content_incomplete?.should be_false

    store.observe(chunk.call(excess)).should be_true
    store.observe(chunk.call("suffix")).should be_false
    snapshot = store.message("main", kind, "m").not_nil!
    snapshot.content_incomplete?.should be_true
    snapshot.content_blocks.first.as(ACP::Protocol::TextContentBlock).text.should eq("start")

    store.observe(oversized_replacement).should be_true
    store.observe(chunk.call("suffix")).should be_false
    store.message("main", kind, "m").not_nil!.content_raw.should be_empty
    store.observe(params.call(%({"sessionUpdate":"session_message","messageId":"m","content":[{"type":"text","text":"new"}]}))).should be_true
    store.observe(chunk.call(" suffix")).should be_true
    recovered = store.message("main", kind, "m").not_nil!
    recovered.content_incomplete?.should be_false
    recovered.content_blocks.map(&.as(ACP::Protocol::TextContentBlock).text).should eq(["new", " suffix"])

    oversized_link_with_clear = params.call(%({"sessionUpdate":"session_message","messageId":"m","recipientSessionId":#{excess.to_json},"content":[]}))
    store.observe(oversized_link_with_clear).should be_true
    store.message("main", kind, "m").not_nil!.content_raw.should be_empty
    store.message("main", kind, "m").not_nil!.content_incomplete?.should be_false
    store.observe(chunk.call("again")).should be_true
    store.message("main", kind, "m").not_nil!.recipient_session_id.should be_nil

    store.forget_session("main").should be_true
    store.observe(chunk.call(excess)).should be_true
    store.observe(chunk.call("suffix")).should be_false
    store.message("main", kind, "m").not_nil!.content_incomplete?.should be_true

    unlimited = ACP::V2::MessageStore.new(message_limit: nil, message_byte_limit: nil)
    unlimited.observe(oversized_link).should be_true
    unlimited.message("main", kind, "m").not_nil!.recipient_session_id.should eq(excess)
  end
end

describe ACP::V2::CompactionStore do
  it "retains streamed compactions and replaces replayed summaries in first-seen order" do
    transport = V2TestTransport.new
    transport.replies["session/new"] = %("result":{"sessionId":"s"})
    transport.replies["session/resume"] = %("result":{})
    client = ACP::V2::Client.new(transport)
    store = ACP::V2::CompactionStore.new
    observed = Channel(Bool).new(8)
    client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
      observed.send(store.observe(note))
      nil
    end
    client.initialize_connection
    client.session_new("/work")

    transport.update("s", %({"sessionUpdate":"compaction_summary_chunk","compactionId":"first","content":{"type":"text","text":"Earlier"},"_meta":{"chunk":true}}))
    take_v2_frame(observed).should be_true
    original = store.compaction("s", "first").not_nil!
    original.status.should eq("in_progress")
    original.meta_raw.should be_nil
    transport.update("s", %({"sessionUpdate":"compaction_update","compactionId":"second","status":"completed"}))
    take_v2_frame(observed).should be_true
    transport.update("s", %({"sessionUpdate":"compaction_update","compactionId":"first","status":"completed","_meta":{"original":true}}))
    take_v2_frame(observed).should be_true
    store.compaction("s", "first").not_nil!.summary_blocks.first.as(ACP::Protocol::TextContentBlock).text.should eq("Earlier")

    transport.before_reply = ->(method : String) do
      if method == "session/resume"
        transport.update("s", %({"sessionUpdate":"compaction_update","compactionId":"first","summary":[]}))
        transport.update("s", %({"sessionUpdate":"compaction_summary_chunk","compactionId":"first","content":{"type":"text","text":"Replayed"}}))
        transport.update("s", %({"sessionUpdate":"replay_complete"}))
        transport.update("s", %({"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn"}))
      end
      nil
    end
    client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("s", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start))
    take_v2_frame(observed).should be_true
    take_v2_frame(observed).should be_true
    take_v2_frame(observed).should be_false
    take_v2_frame(observed).should be_false
    entries = store.compactions("s")
    entries.map(&.compaction_id).should eq(["first", "second"])
    entries.first.status.should eq("completed")
    entries.first.summary_blocks.map(&.as(ACP::Protocol::TextContentBlock).text).should eq(["Replayed"])
    entries.first.meta_raw.not_nil!.field("original").not_nil!.json.should eq("true")
  ensure
    client.try(&.close)
  end

  it "preserves open values, distinguishes patches from clears, and isolates sessions" do
    store = ACP::V2::CompactionStore.new
    observe = ->(sid : String, fields : String) do
      store.observe(ACP::Protocol::V2::SessionUpdateParams.from_json(%({"sessionId":#{sid.to_json},"update":#{fields}})))
    end
    wide = UInt64::MAX.to_s
    observe.call("main", %({"sessionUpdate":"compaction_update","compactionId":"c","status":"_paused","error":"waiting","summary":[{"type":"_diagram","nodes":#{wide}}],"_meta":{"wide":#{wide},"drop":1}})).should be_true
    observe.call("other", %({"sessionUpdate":"compaction_update","compactionId":"c","status":"cancelled"})).should be_true
    observe.call("main", %({"sessionUpdate":"compaction_update","compactionId":"c","status":false,"error":{},"summary":true,"_meta":{"drop":null,"new":true}})).should be_true
    snapshot = store.compaction("main", "c").not_nil!
    snapshot.session_id.should eq("main")
    snapshot.status.should eq("_paused")
    snapshot.error.should eq("waiting")
    snapshot.meta_raw.not_nil!.field("wide").not_nil!.json.should eq(wide)
    snapshot.meta_raw.not_nil!.field("new").not_nil!.json.should eq("true")
    snapshot.meta_raw.not_nil!.field("drop").should be_nil
    snapshot.summary_blocks.first.as(ACP::Protocol::UnknownContentBlock).raw.field("nodes").not_nil!.json.should eq(wide)
    snapshot.summary_raw.clear
    store.compaction("main", "c").not_nil!.summary_raw.size.should eq(1)

    observe.call("main", %({"sessionUpdate":"compaction_update","compactionId":"c","status":null,"error":null,"summary":null,"_meta":null})).should be_true
    cleared = store.compaction("main", "c").not_nil!
    cleared.status.should eq("in_progress")
    cleared.error.should be_nil
    cleared.meta_raw.should be_nil
    cleared.summary_raw.should be_empty
    store.forget_session("main").should be_true
    store.forget_session("main").should be_false
    store.compaction("main", "c").should be_nil
    store.compaction("other", "c").not_nil!.status.should eq("cancelled")
  end

  it "retains fitting status and prevents summary splicing after a budget gap" do
    store = ACP::V2::CompactionStore.new(compaction_limit: 1, compaction_byte_limit: 160)
    observe = ->(fields : String) do
      store.observe(ACP::Protocol::V2::SessionUpdateParams.from_json(%({"sessionId":"main","update":#{fields}})))
    end
    chunk = %({"sessionUpdate":"compaction_summary_chunk","compactionId":"c","content":{"type":"text","text":"Start"}})
    suffix = %({"sessionUpdate":"compaction_summary_chunk","compactionId":"c","content":{"type":"text","text":" suffix"}})
    observe.call(chunk).should be_true
    observe.call(%({"sessionUpdate":"compaction_update","compactionId":"other"})).should be_false
    excess = "x" * 200
    observe.call(%({"sessionUpdate":"compaction_update","compactionId":"c","status":"cancelled","error":#{excess.to_json}})).should be_true
    status_only = store.compaction("main", "c").not_nil!
    status_only.status.should eq("cancelled")
    status_only.error.should be_nil
    status_only.summary_blocks.first.as(ACP::Protocol::TextContentBlock).text.should eq("Start")
    observe.call(%({"sessionUpdate":"compaction_update","compactionId":"c","status":"failed","error":"interrupted","summary":[{"type":"text","text":#{excess.to_json}}]})).should be_true
    observe.call(suffix).should be_false
    gap = store.compaction("main", "c").not_nil!
    gap.status.should eq("failed")
    gap.error.should eq("interrupted")
    gap.summary_incomplete?.should be_true
    gap.summary_raw.should be_empty

    observe.call(%({"sessionUpdate":"compaction_update","compactionId":"c","summary":[{"type":"text","text":"Replacement"}]})).should be_true
    observe.call(suffix).should be_true
    restored = store.compaction("main", "c").not_nil!
    restored.summary_incomplete?.should be_false
    restored.summary_blocks.map(&.as(ACP::Protocol::TextContentBlock).text).should eq(["Replacement", " suffix"])

    observe.call(%({"sessionUpdate":"compaction_update","compactionId":"c","status":"completed","error":#{excess.to_json},"summary":[]})).should be_true
    cleared = store.compaction("main", "c").not_nil!
    cleared.status.should eq("completed")
    cleared.error.should eq("interrupted")
    cleared.summary_raw.should be_empty

    tight_store = ACP::V2::CompactionStore.new(compaction_byte_limit: 11)
    tight_store.observe(ACP::Protocol::V2::SessionUpdateParams.from_json(%({"sessionId":"main","update":{"sessionUpdate":"compaction_update","compactionId":"c","status":"failed"}}))).should be_true
    tight_store.compaction("main", "c").not_nil!.status.should eq("failed")
  end
end

describe ACP::V2::SessionDetailsStore do
  it "applies current session details delivered after replay and before the resume reply" do
    transport = V2TestTransport.new
    transport.replies["session/new"] = %("result":{"sessionId":"s"})
    transport.replies["session/resume"] = %("result":{})
    client = ACP::V2::Client.new(transport)
    store = ACP::V2::SessionDetailsStore.new
    observed = Channel(Bool).new(8)
    client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
      observed.send(store.observe(note))
      nil
    end
    client.initialize_connection
    client.session_new("/work")
    store.session_info("s").should be_nil
    store.session_usage("s").should be_nil
    transport.update("s", %({"sessionUpdate":"session_info_update","title":"Original","updatedAt":"2026-11-22T07:00:00Z"}))
    take_v2_frame(observed).should be_true
    transport.update("s", %({"sessionUpdate":"usage_update","used":2,"size":10,"cost":{"amount":0.5,"currency":"USD"}}))
    take_v2_frame(observed).should be_true

    transport.before_reply = ->(method : String) do
      if method == "session/resume"
        transport.update("s", %({"sessionUpdate":"replay_complete"}))
        transport.update("s", %({"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn"}))
        transport.update("s", %({"sessionUpdate":"session_info_update","title":null}))
        transport.update("s", %({"sessionUpdate":"usage_update","used":4,"size":8}))
      end
      nil
    end
    client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("s", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start))
    take_v2_frame(observed).should be_false
    take_v2_frame(observed).should be_false
    take_v2_frame(observed).should be_true
    take_v2_frame(observed).should be_true
    store.session_info("s").not_nil!.title.should be_nil
    store.session_info("s").not_nil!.updated_at.should eq("2026-11-22T07:00:00Z")
    usage = store.session_usage("s").not_nil!
    usage.used.should eq(4_u64)
    usage.size.should eq(8_u64)
    usage.usage_ratio.should eq(0.5)
    usage.cost.not_nil!.currency.should eq("USD")
  ensure
    client.try(&.close)
  end

  it "keeps exact usage counts, cost, and independently patched metadata by session" do
    store = ACP::V2::SessionDetailsStore.new
    observe = ->(session : String, fields : String) do
      store.observe(ACP::Protocol::V2::SessionUpdateParams.from_json(%({"sessionId":#{session.to_json},"update":#{fields}})))
    end
    wide = UInt64::MAX.to_s
    precise = "0.123456789012345678901"
    observe.call("main", %({"sessionUpdate":"session_info_update","title":"Title","updatedAt":"2026-11-22T09:00:00+09:00","_meta":{"wide":#{wide}}})).should be_true
    observe.call("main", %({"sessionUpdate":"session_info_update","title":false,"updatedAt":"invalid","_meta":{"detail":#{precise}}})).should be_true
    observe.call("main", %({"sessionUpdate":"usage_update","used":1,"size":2,"cost":{"amount":#{precise},"currency":"USD"},"_meta":{"drop":true}})).should be_true
    observe.call("main", %({"sessionUpdate":"usage_update","used":#{wide},"size":0,"cost":{"amount":"invalid","currency":"USD"},"_meta":{"drop":null,"wide":#{wide}}})).should be_true
    observe.call("child", %({"sessionUpdate":"usage_update","used":2,"size":8,"cost":{"amount":1.0,"currency":"credits"}})).should be_true
    info = store.session_info("main").not_nil!
    usage = store.session_usage("main").not_nil!
    info.title.should eq("Title")
    info.updated_at.should eq("2026-11-22T09:00:00+09:00")
    info.meta_raw.not_nil!.field("wide").not_nil!.json.should eq(wide)
    info.meta_raw.not_nil!.field("detail").not_nil!.json.should eq(precise)
    usage.used.should eq(UInt64::MAX)
    usage.usage_ratio.should eq(0.0)
    usage.cost_raw.not_nil!.field("amount").not_nil!.json.should eq(precise)
    usage.meta_raw.not_nil!.field("wide").not_nil!.json.should eq(wide)
    usage.meta_raw.not_nil!.field("drop").should be_nil
    usage.meta_raw.not_nil!.field("detail").should be_nil

    observe.call("main", %({"sessionUpdate":"usage_update","used":1,"size":2,"cost":{"amount":2.0,"currency":"tokens"}})).should be_true
    store.session_usage("main").not_nil!.cost.not_nil!.currency.should eq("tokens")
    observe.call("main", %({"sessionUpdate":"usage_update","used":2,"size":2,"cost":null,"_meta":null})).should be_true
    store.session_usage("main").not_nil!.cost_raw.should be_nil
    store.session_usage("main").not_nil!.meta_raw.should be_nil
    store.forget_session("main").should be_true
    store.forget_session("main").should be_false
    store.session_info("main").should be_nil
    store.session_usage("main").should be_nil
    store.session_usage("child").not_nil!.cost.not_nil!.currency.should eq("credits")
  end

  it "bounds retained details while keeping current counts when optional usage fields exceed the budget" do
    store = ACP::V2::SessionDetailsStore.new(session_limit: 1, session_byte_limit: 80)
    observe = ->(session : String, fields : String) do
      store.observe(ACP::Protocol::V2::SessionUpdateParams.from_json(%({"sessionId":#{session.to_json},"update":#{fields}})))
    end
    observe.call("main", %({"sessionUpdate":"session_info_update","title":"Title"})).should be_true
    observe.call("other", %({"sessionUpdate":"session_info_update","title":"Other"})).should be_false
    observe.call("main", %({"sessionUpdate":"usage_update","used":5,"size":10,"cost":{"amount":1,"currency":"USD"}})).should be_true
    excess = ("x" * 100).to_json
    observe.call("main", %({"sessionUpdate":"session_info_update","title":#{excess}})).should be_false
    observe.call("main", %({"sessionUpdate":"usage_update","used":8,"size":10,"cost":{"amount":5,"currency":"USD"},"_meta":{"large":#{excess}}})).should be_true
    store.session_info("main").not_nil!.title.should eq("Title")
    usage = store.session_usage("main").not_nil!
    usage.used.should eq(8_u64)
    usage.cost.not_nil!.amount.should eq(5.0)
    usage.meta_raw.should be_nil
    observe.call("main", %({"sessionUpdate":"usage_update","used":9,"size":10,"cost":null,"_meta":{"large":#{excess}}})).should be_true
    store.session_usage("main").not_nil!.cost_raw.should be_nil
    store.session_usage("other").should be_nil
  end
end
