require "./spec_helper"

# ═══════════════════════════════════════════════════════════════════════
# Regression Specs
#
# One section per fixed bug. Each example fails before the corresponding
# fix and passes after it.
# ═══════════════════════════════════════════════════════════════════════

# ─── R1: concurrent sends must not interleave within a frame ───────────
#
# A write to a pipe can block part-way through and yield to another fiber.
# `YieldingIO` makes that deterministic: every `write` hands control to
# another fiber before the bytes land. Without a write lock the second
# sender splices its bytes into the middle of the first frame.
class YieldingIO < IO
  getter sink : IO::Memory = IO::Memory.new

  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    # Simulate a partially-blocking write handing off to the scheduler.
    Fiber.yield
    @sink.write(slice)
  end
end

describe "ACP::StdioTransport#send (concurrent senders)" do
  it "never interleaves bytes from two frames" do
    writer = YieldingIO.new
    transport = ACP::StdioTransport.new(IO::Memory.new, writer)

    done = Channel(Nil).new(2)

    2.times do |i|
      spawn do
        msg = Hash(String, JSON::Any).new
        msg["jsonrpc"] = JSON::Any.new("2.0")
        msg["id"] = JSON::Any.new(i.to_i64)
        # A long payload guarantees several write() calls per frame.
        msg["method"] = JSON::Any.new("m#{i}" * 200)
        transport.send(msg)
        done.send(nil)
      end
    end

    2.times { done.receive }

    lines = writer.sink.to_s.split('\n').reject(&.empty?)
    lines.size.should eq(2)
    # Each line must be a complete, parseable JSON-RPC frame.
    ids = lines.map { |line| JSON.parse(line)["id"].as_i }
    ids.sort.should eq([0, 1])

    transport.close
  end
end

# ─── R2: session/update must reach on_notification when on_update is unset ──
describe "ACP::Client session/update fallback" do
  it "delivers session/update to on_notification when no on_update is set" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    received = [] of {String, JSON::Any?}
    client.on_notification = ->(method : String, params : JSON::Any?) do
      received << {method, params}
      nil
    end

    transport.inject_raw(<<-JSON
      {
      "jsonrpc": "2.0",
      "method": "session/update",
      "params": {
        "sessionId": "sess-r2",
        "update": {"sessionUpdate": "agent_message_chunk", "content": "hi"}
      }
      }
      JSON
    )

    sleep 50.milliseconds

    received.size.should eq(1)
    received[0][0].should eq("session/update")
    received[0][1].as(JSON::Any)["sessionId"].as_s.should eq("sess-r2")

    transport.close
  end

  it "still prefers on_update when both handlers are registered" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    typed = 0
    raw = 0
    client.on_update = ->(_u : ACP::Protocol::SessionUpdateParams) { typed += 1; nil }
    client.on_notification = ->(_m : String, _p : JSON::Any?) { raw += 1; nil }

    transport.inject_raw(<<-JSON
      {
      "jsonrpc": "2.0",
      "method": "session/update",
      "params": {
        "sessionId": "sess-r2b",
        "update": {"sessionUpdate": "agent_message_chunk", "content": "hi"}
      }
      }
      JSON
    )

    sleep 50.milliseconds

    typed.should eq(1)
    raw.should eq(0)

    transport.close
  end
end

# ─── R3: extract_id must not coerce unrepresentable JSON-RPC ids ───────
describe "ACP::Protocol.extract_id (malformed ids)" do
  it "accepts a float that is exactly integral" do
    ACP::Protocol.extract_id(JSON.parse(%({"id": 7.0}))).should eq(7_i64)
  end

  it "rejects a fractional id instead of truncating it onto another request" do
    ACP::Protocol.extract_id(JSON.parse(%({"id": 1.9}))).should be_nil
  end

  it "does not raise OverflowError on an out-of-range numeric id" do
    ACP::Protocol.extract_id(JSON.parse(%({"id": 1e300}))).should be_nil
  end

  it "rejects a null id" do
    ACP::Protocol.extract_id(JSON.parse(%({"id": null}))).should be_nil
  end

  it "rejects container and boolean ids rather than stringifying them" do
    ACP::Protocol.extract_id(JSON.parse(%({"id": true}))).should be_nil
    ACP::Protocol.extract_id(JSON.parse(%({"id": [1]}))).should be_nil
    ACP::Protocol.extract_id(JSON.parse(%({"id": {"a": 1}}))).should be_nil
  end

  it "does not tear the dispatcher down when the agent sends such ids" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    # More than MAX_CONSECUTIVE_DISPATCH_ERRORS malformed frames.
    15.times { transport.inject_raw(%({"jsonrpc": "2.0", "id": 1e300, "result": {}})) }
    sleep 50.milliseconds

    client.closed?.should be_false

    transport.close
  end
end

# ─── R4: omitted collection fields must not fail whole-message parsing ──
describe "lenient parsing of omitted optional-in-practice fields" do
  it "parses an initialize result without agentCapabilities" do
    result = ACP::Protocol::InitializeResult.from_json(%({"protocolVersion": 1}))
    result.protocol_version.should eq(1_u16)
    result.agent_capabilities.load_session?.should be_false
  end

  it "completes the handshake when the agent omits agentCapabilities" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    spawn do
      sleep 10.milliseconds
      if msg = transport.last_sent
        transport.inject_raw(%({"jsonrpc":"2.0","id":#{msg["id"].as_i64},"result":{"protocolVersion":1}}))
      end
    end

    result = client.initialize_connection
    result.protocol_version.should eq(1_u16)
    client.state.should eq(ACP::ClientState::Initialized)

    transport.close
  end

  it "parses a session/list result with no sessions key" do
    ACP::Protocol::SessionListResult.from_json("{}").sessions.should be_empty
  end

  it "parses a set_config_option result with no configOptions key" do
    ACP::Protocol::SessionSetConfigOptionResult.from_json("{}").config_options.should be_empty
  end

  it "parses a mode state with no availableModes key" do
    state = ACP::Protocol::SessionModeState.from_json(%({"currentModeId": "ask"}))
    state.available_modes.should be_empty
  end

  it "parses a plan update with entries missing priority/status" do
    update = ACP::Protocol::SessionUpdate.from_json(
      %({"sessionUpdate": "plan", "entries": [{"content": "step one"}]})
    )
    plan = update.as(ACP::Protocol::PlanUpdate)
    plan.entries.size.should eq(1)
    plan.entries[0].priority.should eq("medium")
    plan.entries[0].status.should eq("pending")
  end

  it "parses an available_commands_update with no availableCommands key" do
    update = ACP::Protocol::SessionUpdate.from_json(%({"sessionUpdate": "available_commands_update"}))
    update.as(ACP::Protocol::AvailableCommandsUpdate).available_commands.should be_empty
  end

  it "parses a config_option_update with no configOptions key" do
    update = ACP::Protocol::SessionUpdate.from_json(%({"sessionUpdate": "config_option_update"}))
    update.as(ACP::Protocol::ConfigOptionUpdate).config_options.should be_empty
  end

  it "parses a terminal/output result that omits truncated" do
    result = ACP::Protocol::TerminalOutputResult.from_json(%({"output": "hi"}))
    result.output.should eq("hi")
    result.truncated?.should be_false
  end
end

# ─── R5: AgentMethod must cover every method the client implements ─────
describe ACP::Protocol::AgentMethod do
  it "defines constants for session/resume and session/close" do
    ACP::Protocol::AgentMethod::SESSION_RESUME.should eq("session/resume")
    ACP::Protocol::AgentMethod::SESSION_CLOSE.should eq("session/close")
  end

  it "recognizes every method ACP::Client can send" do
    %w[
      initialize authenticate
      session/new session/load session/list session/resume session/close
      session/prompt session/cancel session/set_mode session/set_config_option
      session/update
    ].each do |method|
      ACP::Protocol::AgentMethod.known?(method).should be_true
    end
  end

  it "classifies session/resume and session/close as session methods" do
    ACP::Protocol::AgentMethod.session_method?("session/resume").should be_true
    ACP::Protocol::AgentMethod.session_method?("session/close").should be_true
    ACP::Protocol::AgentMethod.session_method?("initialize").should be_false
  end

  it "still rejects unknown methods" do
    ACP::Protocol::AgentMethod.known?("session/bogus").should be_false
    ACP::Protocol::AgentMethod.known?("fs/read_text_file").should be_false
  end
end

# ─── R6: extension prefixing must be idempotent ────────────────────────
describe ACP::Protocol::ExtensionMethod do
  it "does not double-prefix an already-prefixed method name" do
    ACP::Protocol::ExtensionMethod.add_prefix("ping").should eq("_ping")
    ACP::Protocol::ExtensionMethod.add_prefix("_ping").should eq("_ping")
  end

  it "round-trips a wire name back onto the wire unchanged" do
    wire = "_vendor/ping"
    ACP::Protocol::ExtensionMethod.add_prefix(wire).should eq(wire)
  end

  it "puts a single prefix on the wire when echoing an agent's method name" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    spawn do
      sleep 10.milliseconds
      if msg = transport.last_sent
        transport.inject_raw(%({"jsonrpc":"2.0","id":#{msg["id"].as_i64},"result":{}}))
      end
    end

    # The name an agent-initiated extension request would arrive under.
    client.ext_method("_vendor/ping")

    transport.last_sent.as(JSON::Any)["method"].as_s.should eq("_vendor/ping")

    transport.close
  end
end

# ─── R7: ProcessTransport lifecycle ────────────────────────────────────
describe "ACP::ProcessTransport lifecycle" do
  it "forwards max_line_bytes to the underlying stdio transport" do
    # Emit one line well over the cap, then a small valid one. The oversized
    # line must be dropped and the reader must re-sync on the next message.
    cmd = %(printf '{"big":"%0999d"}\\n{"ok":1}\\n' 0)
    transport = ACP::ProcessTransport.new("sh", ["-c", cmd], max_line_bytes: 64)

    msg = transport.receive
    msg.should_not be_nil
    msg.as(JSON::Any)["ok"].as_i.should eq(1)

    transport.close
  end

  it "returns the same status from repeated waits after close" do
    transport = ACP::ProcessTransport.new("cat")
    transport.close

    first = transport.wait
    second = transport.wait
    second.should eq(first)
    transport.exit_status.should eq(first)
  end

  it "does not raise when wait races the reaper fiber spawned by close" do
    transport = ACP::ProcessTransport.new("cat")
    transport.close

    results = Channel(Process::Status | Exception).new(4)
    4.times do
      spawn do
        results.send(transport.wait)
      rescue ex
        results.send(ex)
      end
    end

    statuses = Array(Process::Status | Exception).new(4) { results.receive }
    statuses.each(&.should be_a(Process::Status))
    statuses.uniq.size.should eq(1)
  end
end

# ─── R8: closing a session must clear the client's active-session state ──
private def r8_client_with_session : {TestTransport, ACP::Client, ACP::Session}
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
    if msg = transport.last_sent
      transport.inject_raw(
        %({"jsonrpc":"2.0","id":#{msg["id"].as_i64},"result":{"sessionId":"sess-r8"}})
      )
    end
  end
  session = ACP::Session.create(client, cwd: "/tmp")

  {transport, client, session}
end

describe "ACP::Session#close (client state)" do
  it "clears the client's active session when the agent lacks session/close" do
    transport, client, session = r8_client_with_session

    client.session_id.should eq("sess-r8")
    client.session_active?.should be_true

    session.agent_supports_close?.should be_false
    session.close

    client.session_id.should be_nil
    client.session_active?.should be_false
    client.state.should eq(ACP::ClientState::Initialized)

    transport.close
  end

  it "makes a subsequent id-less prompt raise instead of targeting the dead session" do
    transport, client, session = r8_client_with_session
    session.close

    expect_raises(ACP::NoActiveSessionError) do
      client.session_prompt_text("still there?")
    end

    transport.close
  end

  it "clears the cached state when notify_agent is false" do
    transport, client, session = r8_client_with_session
    session.close(notify_agent: false)

    client.session_id.should be_nil

    transport.close
  end

  it "leaves an unrelated active session alone" do
    transport, client, _session = r8_client_with_session

    other = ACP::Session.new(client, "sess-other")
    other.close

    client.session_id.should eq("sess-r8")
    client.session_active?.should be_true

    transport.close
  end

  it "does not resurrect a closed client" do
    transport, client, session = r8_client_with_session
    client.close
    session.close(notify_agent: false)

    client.state.should eq(ACP::ClientState::Closed)

    transport.close
  end
end

# ─── R9: file:// URIs must percent-encode / decode ─────────────────────
describe "ACP::Protocol::ResourceLinkContentBlock file:// URIs" do
  it "leaves an ordinary path untouched" do
    block = ACP::Protocol::ResourceLinkContentBlock.from_path("/path/to/file.txt")
    block.uri.should eq("file:///path/to/file.txt")
    block.path.should eq("/path/to/file.txt")
  end

  it "percent-encodes characters that are not URI-safe" do
    block = ACP::Protocol::ResourceLinkContentBlock.from_path("/My Docs/report #2.md")
    block.uri.should eq("file:///My%20Docs/report%20%232.md")
  end

  it "round-trips a path containing spaces, '#', '?' and '%'" do
    original = "/tmp/a b/c#d?e%f.cr"
    ACP::Protocol::ResourceLinkContentBlock.from_path(original).path.should eq(original)
  end

  it "decodes an encoded URI supplied by the agent" do
    block = ACP::Protocol::ResourceLinkContentBlock.new(
      uri: "file:///My%20Docs/a.cr", name: "a.cr"
    )
    block.path.should eq("/My Docs/a.cr")
  end

  it "returns nil for a non-file scheme" do
    block = ACP::Protocol::ResourceLinkContentBlock.new(
      uri: "https://example.com/a.cr", name: "a.cr"
    )
    block.path.should be_nil
  end

  it "keeps the display name as the raw, unencoded basename" do
    block = ACP::Protocol::ResourceLinkContentBlock.from_path("/My Docs/report #2.md")
    block.name.should eq("report #2.md")
  end
end

# ─── R10: non-object JSON-RPC frames must not raise or kill the link ───
#
# JSON-RPC 2.0 messages are always objects, and ACP v1 does not use batch
# (array) requests. Probing a bare array / number / string / bool / null
# with `JSON::Any#[]?` raises a bare `Exception`, which the dispatcher
# counted as a corrupt-stream error — ten such frames tore down an
# otherwise healthy connection.
describe "ACP::Protocol.classify_message (non-object frames)" do
  it "classifies a non-object frame instead of raising" do
    ["[]", "[1,2,3]", "42", %("hello"), "true", "null"].each do |raw|
      ACP::Protocol.classify_message(JSON.parse(raw))
        .should eq(ACP::Protocol::MessageKind::Notification)
    end
  end
end

describe "ACP::Protocol.extract_id (non-object frames)" do
  it "reports no id for a non-object frame instead of raising" do
    ["[]", "[1,2,3]", "42", %("hello"), "true", "null"].each do |raw|
      ACP::Protocol.extract_id(JSON.parse(raw)).should be_nil
    end
  end
end

describe "ACP::Client dispatch (non-object frames)" do
  it "drops non-object frames without tearing down the connection" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    disconnected = false
    client.on_disconnect = -> { disconnected = true; nil }

    # Twice the dispatcher's consecutive-error budget.
    (ACP::Client::MAX_CONSECUTIVE_DISPATCH_ERRORS * 2).times do
      transport.inject_raw("[]")
    end

    sleep 100.milliseconds

    client.closed?.should be_false
    disconnected.should be_false
    transport.closed?.should be_false

    # The link is still usable for a real message.
    seen = 0
    client.on_notification = ->(_m : String, _p : JSON::Any?) { seen += 1; nil }
    transport.inject_raw(%({"jsonrpc":"2.0","method":"_ping","params":{}}))
    sleep 50.milliseconds
    seen.should eq(1)

    client.close
  end
end

# ─── R11: malformed agent results must raise an ACP error ──────────────
#
# JSON-RPC 2.0 §5 requires exactly one of `result` / `error`. A result
# that is missing, or that does not match the ACP schema, used to escape
# public `Client` methods as a raw `JSON::SerializableError`, breaking the
# contract that everything the library raises is an `ACP::Error`.
describe "ACP::Client typed result decoding" do
  it "raises ProtocolError when the agent result has the wrong field type" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)
    client.request_timeout = 2.0

    spawn do
      sleep 10.milliseconds
      transport.inject_raw(%({"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"one"}}))
    end

    ex = expect_raises(ACP::ProtocolError, /malformed result for 'initialize'/) do
      client.initialize_connection
    end
    ex.cause.should be_a(JSON::SerializableError)

    client.close
  end

  it "raises ProtocolError when the response carries neither result nor error" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)
    client.request_timeout = 2.0

    spawn do
      sleep 10.milliseconds
      transport.inject_raw(%({"jsonrpc":"2.0","id":1}))
    end

    expect_raises(ACP::ProtocolError, /malformed result for 'initialize'/) do
      client.initialize_connection
    end

    client.close
  end

  it "raises ProtocolError when session/new omits the sessionId" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)
    client.request_timeout = 2.0

    spawn do
      sleep 10.milliseconds
      transport.inject_raw(build_init_response(1_i64))
      sleep 10.milliseconds
      transport.inject_raw(%({"jsonrpc":"2.0","id":2,"result":{}}))
    end

    client.initialize_connection

    expect_raises(ACP::ProtocolError, /malformed result for 'session\/new'/) do
      client.session_new("/tmp")
    end

    client.close
  end
end

# ─── R12: an on_update handler must not be mistaken for a parse failure ──
#
# Parsing and invoking used to share one `begin`, so a
# `JSON::SerializableError` raised by user code inside `on_update` was
# read as "the update failed to parse" and the same notification was
# delivered to `on_notification` a second time.
describe "ACP::Client session/update handler errors" do
  it "does not re-deliver an update when the handler raises a JSON error" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    raw_calls = 0
    client.on_notification = ->(_m : String, _p : JSON::Any?) { raw_calls += 1; nil }
    client.on_update = ->(_u : ACP::Protocol::SessionUpdateParams) do
      raise JSON::SerializableError.new("handler boom", "Whatever", nil, 1, 1, nil)
    end

    transport.inject_raw(<<-JSON
      {
      "jsonrpc": "2.0",
      "method": "session/update",
      "params": {
        "sessionId": "sess-r12",
        "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hi"}}
      }
      }
      JSON
    )

    sleep 50.milliseconds

    raw_calls.should eq(0)
    client.closed?.should be_false

    client.close
  end

  it "still falls back to on_notification when the update itself is unparseable" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    raw_calls = 0
    client.on_notification = ->(_m : String, _p : JSON::Any?) { raw_calls += 1; nil }
    client.on_update = ->(_u : ACP::Protocol::SessionUpdateParams) { nil }

    transport.inject_raw(<<-JSON
      {
      "jsonrpc": "2.0",
      "method": "session/update",
      "params": {"sessionId": "sess-r12b", "update": {"sessionUpdate": "no_such_kind"}}
      }
      JSON
    )

    sleep 50.milliseconds
    raw_calls.should eq(1)

    client.close
  end
end

# ─── R13: unusable session/update params must not be dropped silently ──
describe "ACP::Client session/update with unusable params" do
  it "hands non-object params to on_notification" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    raw_calls = 0
    client.on_notification = ->(_m : String, _p : JSON::Any?) { raw_calls += 1; nil }
    client.on_update = ->(_u : ACP::Protocol::SessionUpdateParams) { nil }

    transport.inject_raw(%({"jsonrpc":"2.0","method":"session/update","params":"not-an-object"}))
    sleep 50.milliseconds
    raw_calls.should eq(1)

    client.close
  end

  it "hands a non-object update payload to on_notification" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    raw_calls = 0
    client.on_notification = ->(_m : String, _p : JSON::Any?) { raw_calls += 1; nil }
    client.on_update = ->(_u : ACP::Protocol::SessionUpdateParams) { nil }

    transport.inject_raw(
      %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":"nope"}})
    )
    sleep 50.milliseconds
    raw_calls.should eq(1)

    client.close
  end
end

# ─── R14: JSON-RPC error responses may carry a `data` member ───────────
describe "ACP::Client#respond_to_agent_error" do
  it "omits `data` when none is given" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    client.respond_to_agent_error(1_i64, ACP::JsonRpcError::INVALID_PARAMS, "bad")

    error = transport.last_sent.as(JSON::Any)["error"]
    error["code"].as_i.should eq(ACP::JsonRpcError::INVALID_PARAMS)
    error["message"].as_s.should eq("bad")
    error.as_h.has_key?("data").should be_false

    client.close
  end

  it "attaches structured `data` when given (JSON-RPC 2.0 §5.1)" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    client.respond_to_agent_error(
      "req-1", ACP::JsonRpcError::INVALID_PARAMS, "bad",
      JSON.parse(%({"field":"path"}))
    )

    sent = transport.last_sent.as(JSON::Any)
    # The string id must be echoed back as a string, not coerced to a number.
    sent["id"].as_s.should eq("req-1")
    sent["error"]["data"]["field"].as_s.should eq("path")

    client.close
  end
end

# ─── R15: ACP v1 wire values the library did not know ──────────────────
describe "ACP v1 wire coverage" do
  it "parses the `usage_update` session update" do
    update = ACP::Protocol::SessionUpdate.from_json(
      %({"sessionUpdate":"usage_update","used":1200,"size":200000,"cost":{"amount":0.42,"currency":"USD"}})
    )
    usage = update.as(ACP::Protocol::UsageUpdate)
    usage.used.should eq(1200_i64)
    usage.size.should eq(200_000_i64)
    usage.cost.try(&.amount).should eq(0.42)
    usage.cost.try(&.currency).should eq("USD")
    usage.usage_ratio.should be_close(0.006, 1e-9)
  end

  it "reports a zero usage ratio rather than dividing by zero" do
    ACP::Protocol::UsageUpdate.new(used: 0_i64, size: 0_i64).usage_ratio.should eq(0.0)
  end

  it "parses `usage_update` without a cost" do
    update = ACP::Protocol::SessionUpdate.from_json(
      %({"sessionUpdate":"usage_update","used":10,"size":100})
    )
    update.as(ACP::Protocol::UsageUpdate).cost.should be_nil
  end

  it "keeps `messageId` on streamed message chunks" do
    update = ACP::Protocol::SessionUpdate.from_json(
      %({"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"hi"}})
    )
    chunk = update.as(ACP::Protocol::AgentMessageChunkUpdate)
    chunk.message_id.should eq("m1")
    JSON.parse(chunk.to_json)["messageId"].as_s.should eq("m1")
  end

  it "leaves `messageId` out of the wire form when unset" do
    chunk = ACP::Protocol::AgentMessageChunkUpdate.new(JSON.parse(%({"type":"text","text":"hi"})))
    JSON.parse(chunk.to_json).as_h.has_key?("messageId").should be_false
  end

  it "knows the `model_config` session config option category" do
    ACP::Protocol::SessionConfigOptionCategory.parse("model_config")
      .should eq(ACP::Protocol::SessionConfigOptionCategory::ModelConfig)
    ACP::Protocol::SessionConfigOptionCategory::ModelConfig.to_s.should eq("model_config")
  end

  it "knows the -32800 request-cancelled error code" do
    ACP::JsonRpcError::REQUEST_CANCELLED.should eq(-32800)
    ACP::Protocol::ErrorCode::REQUEST_CANCELLED.should eq(-32800)

    error = ACP::JsonRpcError.new(-32800, "cancelled")
    error.request_cancelled?.should be_true
    error.server_error?.should be_false
    ACP::JsonRpcError.new(-32000, "auth").request_cancelled?.should be_false
  end
end
