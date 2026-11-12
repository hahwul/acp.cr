require "./spec_helper"

# ═══════════════════════════════════════════════════════════════════════
# Stable v1 features added for schema 1.31: session/delete, logout,
# elicitation, systemPrompt, additionalDirectories, session notices,
# compaction, boolean config options and `$/cancel_request`.
# ═══════════════════════════════════════════════════════════════════════

# Answers each client request from a per-method table (a `result` or an
# `error` JSON object), so tests can drive request/response methods inline.
class AutoReplyTransport < TestTransport
  getter replies = {} of String => String

  def send(message : Hash(String, JSON::Any)) : Nil
    super
    method = message["method"]?.try(&.as_s?)
    id = message["id"]?
    return unless method && id && (reply = @replies[method]?)
    inject_raw(%({"jsonrpc":"2.0","id":#{id.to_json},#{reply}}))
  end
end

private def v1_client(agent_caps : String = "{}", client_caps = ACP::Protocol::ClientCapabilities.new)
  transport = AutoReplyTransport.new
  transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":#{agent_caps}})
  client = ACP::Client.new(transport, client_capabilities: client_caps)
  client.request_timeout = 2.0
  client.initialize_connection
  {transport, client}
end

private def sent(transport : TestTransport, method : String) : JSON::Any
  transport.sent_messages.find! { |m| m["method"]?.try(&.as_s?) == method }
end

# Waits until the transport has sent something matching the block.
private def wait_for_sent(transport : TestTransport, & : JSON::Any -> Bool) : JSON::Any
  200.times do
    if found = transport.sent_messages.find { |m| yield m }
      return found
    end
    sleep 5.milliseconds
  end
  raise "expected message was never sent"
end

private def answers_to(transport : TestTransport, id) : Array(JSON::Any)
  transport.sent_messages.select { |m| m["id"]? == id && !m["method"]? }
end

describe "ACP stable v1 capabilities" do
  it "advertises no new client capability by default" do
    json = JSON.parse(ACP::Protocol::ClientCapabilities.new.to_json)
    json.as_h.has_key?("session").should be_false
    json.as_h.has_key?("elicitation").should be_false
  end

  it "serializes session and elicitation client capabilities under their schema keys" do
    caps = ACP::Protocol::ClientCapabilities.new(
      session: ACP::Protocol::ClientSessionCapabilities.new(
        compaction: ACP::Protocol::CompactionCapabilities.new,
        config_options: ACP::Protocol::SessionConfigOptionsCapabilities.new(
          boolean: ACP::Protocol::BooleanConfigOptionCapabilities.new
        ),
        notices: ACP::Protocol::NoticeCapabilities.new,
      ),
      elicitation: ACP::Protocol::ElicitationCapabilities.new(form: ACP::Protocol::ElicitationFormCapabilities.new),
    )
    JSON.parse(caps.to_json).should eq(JSON.parse(
      %({"terminal":false,"session":{"compaction":{},"configOptions":{"boolean":{}},"notices":{}},"elicitation":{"form":{}}})
    ))
  end

  it "only treats an explicitly present elicitation mode as supported" do
    caps = ACP::Protocol::ElicitationCapabilities.from_json(%({"form":null,"url":{}}))
    caps.supports?("form").should be_false
    caps.supports?("url").should be_true
    caps.supports?("other").should be_false
    ACP::Protocol::ElicitationCapabilities.from_json("{}").supports?("form").should be_false
  end

  it "reads session/delete, additionalDirectories, systemPrompt and logout agent capabilities" do
    caps = ACP::Protocol::AgentCapabilities.from_json(
      %({"sessionCapabilities":{"delete":{},"additionalDirectories":{},"systemPrompt":{"mode":{"override":{}}}},"auth":{"logout":{}}})
    )
    session = caps.session_capabilities.as(ACP::Protocol::SessionCapabilities)
    session.delete?.should be_true
    session.additional_directories?.should be_true
    session.system_prompt?.should be_true
    session.system_prompt.as(ACP::Protocol::SessionSystemPromptCapabilities).override?.should be_true
    caps.auth.as(ACP::Protocol::AgentAuthCapabilities).logout?.should be_true

    bare = ACP::Protocol::AgentCapabilities.from_json(%({"sessionCapabilities":{"systemPrompt":{}},"auth":{"logout":null}}))
    bare.session_capabilities.as(ACP::Protocol::SessionCapabilities).delete?.should be_false
    bare.session_capabilities.as(ACP::Protocol::SessionCapabilities).system_prompt.as(ACP::Protocol::SessionSystemPromptCapabilities).override?.should be_false
    bare.auth.as(ACP::Protocol::AgentAuthCapabilities).logout?.should be_false
  end
end

describe "ACP::Client#session_delete" do
  it "sends session/delete with the session ID" do
    transport, client = v1_client(%({"sessionCapabilities":{"delete":{}}}))
    transport.replies["session/delete"] = %("result":{})
    client.session_delete("sess-1").should be_a(ACP::Protocol::SessionDeleteResult)
    sent(transport, "session/delete")["params"].should eq(JSON.parse(%({"sessionId":"sess-1"})))
    client.close
  end

  it "treats -32002 as a successful delete and raises other errors" do
    transport, client = v1_client
    transport.replies["session/delete"] = %("error":{"code":-32002,"message":"Resource not found"})
    client.session_delete("gone").should be_a(ACP::Protocol::SessionDeleteResult)

    transport.replies["session/delete"] = %("error":{"code":-32603,"message":"boom"})
    expect_raises(ACP::JsonRpcError) { client.session_delete("x") }
    client.close
  end
end

describe "ACP::Client#logout" do
  it "sends logout with empty params" do
    transport, client = v1_client(%({"auth":{"logout":{}}}))
    transport.replies["logout"] = %("result":{})
    client.agent_capabilities.as(ACP::Protocol::AgentCapabilities).auth.as(ACP::Protocol::AgentAuthCapabilities).logout?.should be_true
    client.logout.should be_a(ACP::Protocol::LogoutResult)
    sent(transport, "logout")["params"].should eq(JSON.parse("{}"))
    client.close
  end
end

describe "ACP additionalDirectories and systemPrompt" do
  it "sends them on session/new, session/load and session/resume" do
    transport, client = v1_client
    transport.replies["session/new"] = %("result":{"sessionId":"s1"})
    transport.replies["session/load"] = %("result":{})
    transport.replies["session/resume"] = %("result":{})
    prompt = ACP::Protocol::SystemPrompt.append("Focus on security.")
    dirs = ["/srv/lib"]

    client.session_new("/w", additional_directories: dirs, system_prompt: prompt)
    client.session_load("s1", "/w", additional_directories: dirs, system_prompt: prompt)
    client.session_resume("s1", "/w", additional_directories: dirs, system_prompt: prompt)

    expected_prompt = JSON.parse(%({"mode":"append","content":[{"type":"text","text":"Focus on security."}]}))
    %w[session/new session/load session/resume].each do |method|
      params = sent(transport, method)["params"]
      params["additionalDirectories"].should eq(JSON.parse(%(["/srv/lib"])))
      params["systemPrompt"].should eq(expected_prompt)
    end
    client.close
  end

  it "omits them when not given, as agents that don't advertise them require" do
    params = JSON.parse(ACP::Protocol::SessionNewParams.new("/w").to_json).as_h
    params.has_key?("additionalDirectories").should be_false
    params.has_key?("systemPrompt").should be_false
    typed = ACP::Protocol::SessionNewParams.new("/w", [] of ACP::Protocol::McpServer, additional_directories: ["/a"])
    JSON.parse(typed.to_json)["additionalDirectories"].should eq(JSON.parse(%(["/a"])))
  end

  it "reads additionalDirectories from session/list entries" do
    result = ACP::Protocol::SessionListResult.from_json(
      %({"sessions":[{"sessionId":"s1","cwd":"/w","additionalDirectories":["/a","/b"]},{"sessionId":"s2","cwd":"/w"}]})
    )
    result.sessions[0].additional_directories.should eq(["/a", "/b"])
    result.sessions[1].additional_directories.should be_nil
  end
end

describe "ACP boolean config options" do
  bool_json = %({"id":"brave","name":"Brave Mode","type":"boolean","currentValue":true})
  select_json = %({"id":"model","name":"Model","type":"select","currentValue":"a","options":[{"value":"a","name":"A"}]})

  it "parses a boolean option next to select options" do
    opts = ACP::Protocol::SessionNewResult.from_json(%({"sessionId":"s","configOptions":[#{bool_json},#{select_json}]})).config_options.as(Array(ACP::Protocol::ConfigOption))
    opts.map(&.id).should eq(["brave", "model"])
    opts[0].boolean?.should be_true
    opts[0].boolean_value.should be_true
    opts[0].current_value.should be_nil
    opts[0].options.should be_nil
    opts[1].boolean_value.should be_nil
    opts[1].current_value.should eq("a")
    JSON.parse(opts[0].to_json).should eq(JSON.parse(bool_json))
  end

  it "skips an option whose currentValue doesn't match its type" do
    bad = [
      %({"id":"x","name":"X","type":"boolean","currentValue":"yes"}),
      %({"id":"y","name":"Y","type":"select","currentValue":true,"options":[]}),
    ]
    items = (bad + [select_json]).map { |j| JSON.parse(j) }
    ACP::Protocol.parse_config_options(items).map(&.id).should eq(["model"])
  end

  it "sets a boolean option with type: boolean, and a select one without a type" do
    transport, client = v1_client
    transport.replies["session/new"] = %("result":{"sessionId":"s1"})
    transport.replies["session/set_config_option"] = %("result":{"configOptions":[#{bool_json}]})
    client.session_new("/w")

    client.session_set_config_option("brave", false)
    params = sent(transport, "session/set_config_option")["params"]
    params.should eq(JSON.parse(%({"sessionId":"s1","configId":"brave","type":"boolean","value":false})))
    client.session_config_options.as(Array(ACP::Protocol::ConfigOption))[0].boolean_value.should be_true

    transport.clear_sent
    client.session_set_config_option("model", "b")
    sent(transport, "session/set_config_option")["params"].should eq(JSON.parse(%({"sessionId":"s1","configId":"model","value":"b"})))
    client.close
  end
end

describe "ACP notice and compaction session updates" do
  it "parses a notice" do
    update = ACP::Protocol::SessionUpdate.from_json(
      %({"sessionUpdate":"notice","severity":"warning","title":"MCP server unavailable","description":"Continuing without it."})
    ).as(ACP::Protocol::NoticeUpdate)
    update.severity.should eq("warning")
    update.title.should eq("MCP server unavailable")
    update.description.should eq("Continuing without it.")
  end

  it "keeps unknown open-enum values" do
    ACP::Protocol::SessionUpdate.from_json(%({"sessionUpdate":"notice","severity":"_custom","title":"t"}))
      .as(ACP::Protocol::NoticeUpdate).severity.should eq("_custom")
    ACP::Protocol::SessionUpdate.from_json(%({"sessionUpdate":"compaction_update","compactionId":"c","status":"_paused"}))
      .as(ACP::Protocol::CompactionUpdate).status.should eq("_paused")
  end

  it "tells an omitted compaction patch field from a cleared one" do
    omitted = ACP::Protocol::SessionUpdate.from_json(%({"sessionUpdate":"compaction_update","compactionId":"c1","status":"in_progress"}))
      .as(ACP::Protocol::CompactionUpdate)
    omitted.summary_present?.should be_false
    omitted.error_present?.should be_false

    cleared = ACP::Protocol::SessionUpdate.from_json(
      %({"sessionUpdate":"compaction_update","compactionId":"c1","status":"failed","summary":null,"error":"out of tokens"})
    ).as(ACP::Protocol::CompactionUpdate)
    cleared.summary.should be_nil
    cleared.summary_present?.should be_true
    cleared.error.should eq("out of tokens")

    # A clear survives re-serialization; an omitted field stays omitted.
    JSON.parse(cleared.to_json).as_h.has_key?("summary").should be_true
    JSON.parse(cleared.to_json)["summary"].raw.should be_nil
    JSON.parse(omitted.to_json).as_h.has_key?("summary").should be_false
  end

  it "parses a compaction summary and summary chunks into content blocks" do
    update = ACP::Protocol::SessionUpdate.from_json(
      %({"sessionUpdate":"compaction_update","compactionId":"c1","status":"completed","summary":[{"type":"text","text":"kept"}]})
    ).as(ACP::Protocol::CompactionUpdate)
    update.typed_summary.as(Array(ACP::Protocol::ContentBlock)).first.as(ACP::Protocol::TextContentBlock).text.should eq("kept")

    chunk = ACP::Protocol::SessionUpdate.from_json(
      %({"sessionUpdate":"compaction_summary_chunk","compactionId":"c1","content":{"type":"text","text":"## Retained"}})
    ).as(ACP::Protocol::CompactionSummaryChunkUpdate)
    chunk.compaction_id.should eq("c1")
    chunk.text.should eq("## Retained")
  end

  it "delivers them to on_update" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)
    got = Channel(ACP::Protocol::SessionUpdate).new(1)
    client.on_update = ->(u : ACP::Protocol::SessionUpdateParams) { got.send(u.update); nil }
    transport.inject_raw(%({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"notice","severity":"info","title":"hi"}}}))
    got.receive.should be_a(ACP::Protocol::NoticeUpdate)
    client.close
  end
end

describe "ACP elicitation" do
  form_request = %({"jsonrpc":"2.0","id":43,"method":"elicitation/create","params":{"sessionId":"s1","mode":"form","message":"How?","requestedSchema":{"type":"object","properties":{"strategy":{"type":"string","enum":["a","b"]}},"required":["strategy"]}}})

  it "answers a form elicitation through on_create_elicitation" do
    caps = ACP::Protocol::ClientCapabilities.new(elicitation: ACP::Protocol::ElicitationCapabilities.new(form: ACP::Protocol::ElicitationFormCapabilities.new))
    transport = TestTransport.new
    client = ACP::Client.new(transport, client_capabilities: caps)
    seen = Channel(ACP::Protocol::CreateElicitationParams).new(1)
    client.on_create_elicitation = ->(p : ACP::Protocol::CreateElicitationParams) do
      seen.send(p)
      ACP::Protocol::CreateElicitationResult.accept({"strategy" => "a"} of String => ACP::Protocol::ElicitationContentValue)
    end

    transport.inject_raw(form_request)
    params = seen.receive
    params.form?.should be_true
    params.session_id.should eq("s1")
    params.requested_schema.as(ACP::Protocol::ElicitationSchema).properties["strategy"].enum_values.should eq(["a", "b"])

    answer = wait_for_sent(transport) { |m| m["id"]? == 43 }
    answer["result"].should eq(JSON.parse(%({"action":"accept","content":{"strategy":"a"}})))
    client.close
  end

  it "answers a mode the client did not advertise with -32602, without calling the handler" do
    caps = ACP::Protocol::ClientCapabilities.new(elicitation: ACP::Protocol::ElicitationCapabilities.new(url: ACP::Protocol::ElicitationUrlCapabilities.new))
    transport = TestTransport.new
    client = ACP::Client.new(transport, client_capabilities: caps)
    called = false
    client.on_create_elicitation = ->(_p : ACP::Protocol::CreateElicitationParams) do
      called = true
      ACP::Protocol::CreateElicitationResult.decline
    end

    transport.inject_raw(form_request)
    answer = wait_for_sent(transport) { |m| m["id"]? == 43 }
    answer["error"]["code"].as_i.should eq(-32602)
    called.should be_false
    client.close
  end

  it "answers -32602 when elicitation isn't advertised at all" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)
    transport.inject_raw(form_request)
    wait_for_sent(transport) { |m| m["id"]? == 43 }["error"]["code"].as_i.should eq(-32602)
    client.close
  end

  it "delivers elicitation/complete to on_elicitation_complete, else to on_notification" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)
    raw = Channel(String).new(1)
    client.on_notification = ->(m : String, _p : JSON::Any?) { raw.send(m); nil }
    note = %({"jsonrpc":"2.0","method":"elicitation/complete","params":{"elicitationId":"github-oauth-001"}})

    transport.inject_raw(note)
    raw.receive.should eq("elicitation/complete")

    typed = Channel(String).new(1)
    client.on_elicitation_complete = ->(p : ACP::Protocol::CompleteElicitationParams) { typed.send(p.elicitation_id); nil }
    transport.inject_raw(note)
    typed.receive.should eq("github-oauth-001")
    client.close
  end

  it "parses a request-scoped URL elicitation" do
    params = ACP::Protocol::CreateElicitationParams.from_json(
      %({"requestId":12,"mode":"url","elicitationId":"e1","url":"https://agent.example.com/connect","message":"Authorize"})
    )
    params.url?.should be_true
    params.request_id.should eq(12_i64)
    params.elicitation_id.should eq("e1")
    params.session_id.should be_nil
  end
end

describe "ACP $/cancel_request" do
  it "sends $/cancel_request for one of our requests" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)
    client.cancel_request(5_i64)
    transport.last_sent.should eq(JSON.parse(%({"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":5}})))
    client.close
  end

  it "cancels a request that timed out" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)
    client.request_timeout = 0.05
    expect_raises(ACP::RequestTimeoutError) { client.initialize_connection }
    request_id = sent(transport, "initialize")["id"]
    sent(transport, "$/cancel_request")["params"]["requestId"].should eq(request_id)
    client.close
  end

  it "answers a waiting request with -32800 at once, drops the late answer, and tells on_notification" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)
    release = Channel(Nil).new(1)
    entered = Channel(Nil).new(1)
    notified = Channel(JSON::Any?).new(1)
    client.on_notification = ->(_m : String, p : JSON::Any?) { notified.send(p); nil }
    client.on_wait_for_terminal_exit = ->(_p : ACP::Protocol::WaitForTerminalExitParams) do
      entered.send(nil)
      release.receive
      ACP::Protocol::WaitForTerminalExitResult.new(exit_code: 0)
    end

    transport.inject_raw(%({"jsonrpc":"2.0","id":2,"method":"terminal/wait_for_exit","params":{"sessionId":"s","terminalId":"t"}}))
    entered.receive
    transport.inject_raw(%({"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":2}}))

    notified.receive.as(JSON::Any)["requestId"].as_i.should eq(2)
    answers_to(transport, 2).map(&.["error"].["code"].as_i).should eq([-32800])

    release.send(nil)
    sleep 20.milliseconds
    answers_to(transport, 2).size.should eq(1)
    client.close
  end

  it "answers a cancelled permission request with the cancelled outcome" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)
    release = Channel(Nil).new(1)
    entered = Channel(Nil).new(1)
    client.on_agent_request = ->(_m : String, _p : JSON::Any) do
      entered.send(nil)
      release.receive
      JSON.parse(ACP::Protocol::RequestPermissionResult.selected("allow").to_json)
    end

    transport.inject_raw(%({"jsonrpc":"2.0","id":"p1","method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"t"},"options":[]}}))
    entered.receive
    transport.inject_raw(%({"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":"p1"}}))

    answer = wait_for_sent(transport) { |m| m["id"]? == "p1" }
    answer["result"]["outcome"]["outcome"].as_s.should eq("cancelled")
    release.send(nil)
    sleep 20.milliseconds
    answers_to(transport, "p1").size.should eq(1)
    client.close
  end

  it "leaves a request with side effects to its handler" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)
    release = Channel(Nil).new(1)
    entered = Channel(Nil).new(1)
    client.on_write_text_file = ->(_p : ACP::Protocol::WriteTextFileParams) do
      entered.send(nil)
      release.receive
      ACP::Protocol::WriteTextFileResult.new
    end

    transport.inject_raw(%({"jsonrpc":"2.0","id":3,"method":"fs/write_text_file","params":{"sessionId":"s","path":"/f","content":"x"}}))
    entered.receive
    transport.inject_raw(%({"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":3}}))
    sleep 20.milliseconds
    answers_to(transport, 3).should be_empty

    release.send(nil)
    answer = wait_for_sent(transport) { |m| m["id"]? == 3 }
    answer["result"].should eq(JSON.parse("{}"))
    client.close
  end

  it "still answers both requests when the agent reuses an in-flight ID" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)
    release = Channel(Nil).new(2)
    entered = Channel(Nil).new(2)
    client.on_read_text_file = ->(p : ACP::Protocol::ReadTextFileParams) do
      entered.send(nil)
      release.receive
      ACP::Protocol::ReadTextFileResult.new(p.path)
    end

    2.times { transport.inject_raw(%({"jsonrpc":"2.0","id":9,"method":"fs/read_text_file","params":{"sessionId":"s","path":"/f"}})) }
    2.times { entered.receive }
    2.times { release.send(nil) }
    sleep 30.milliseconds
    answers_to(transport, 9).size.should eq(2)
    client.close
  end

  it "answers the older of two same-ID requests when the newer one finishes first" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)
    releases = [Channel(Nil).new(1), Channel(Nil).new(1)]
    entered = Channel(Nil).new(2)
    calls = Atomic(Int32).new(0)
    client.on_read_text_file = ->(p : ACP::Protocol::ReadTextFileParams) do
      release = releases[calls.add(1)]
      entered.send(nil)
      release.receive
      ACP::Protocol::ReadTextFileResult.new(p.path)
    end

    2.times { transport.inject_raw(%({"jsonrpc":"2.0","id":9,"method":"fs/read_text_file","params":{"sessionId":"s","path":"/f"}})) }
    2.times { entered.receive }
    releases[1].send(nil)
    sleep 20.milliseconds
    releases[0].send(nil)
    sleep 20.milliseconds
    answers_to(transport, 9).size.should eq(2)
    client.close
  end
end

describe "ACP terminal exit codes (schema uint32)" do
  it "decodes an exit code above Int32::MAX and rejects a negative one" do
    ACP::Protocol::WaitForTerminalExitResult.from_json(%({"exitCode":4294967295})).exit_code.should eq(UInt32::MAX)
    ACP::Protocol::TerminalExitStatus.from_json(%({"exitCode":3000000000})).exit_code.should eq(3_000_000_000_u32)
    expect_raises(JSON::ParseException) { ACP::Protocol::TerminalExitStatus.from_json(%({"exitCode":-1})) }
  end
end

describe "ACP::Protocol::SessionSetConfigOptionParams#value=" do
  it "keeps type: boolean in step with the value" do
    params = ACP::Protocol::SessionSetConfigOptionParams.new("s", "c", "x")
    params.value = true
    JSON.parse(params.to_json)["type"].as_s.should eq("boolean")
    params.value = "y"
    JSON.parse(params.to_json).as_h.has_key?("type").should be_false
  end
end
