require "./spec_helper"
require "log/spec"

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
private def r8_client_with_session(*, session_capabilities : String? = nil) : {TestTransport, ACP::Client, ACP::Session}
  transport = TestTransport.new
  client = ACP::Client.new(transport)

  spawn do
    sleep 10.milliseconds
    if msg = transport.last_sent
      transport.inject_raw(build_init_response(msg["id"].as_i64, session_capabilities: session_capabilities))
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
    ACP::Protocol::UsageUpdate.new(used: 0_u64, size: 0_u64).usage_ratio.should eq(0.0)
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

# ─── R16: close must release the IOs even after the stream ended ───────
describe "ACP::StdioTransport#close after the stream ended" do
  it "closes both IOs after the reader hit EOF" do
    reader, agent_out = IO.pipe
    _agent_in, writer = IO.pipe
    transport = ACP::StdioTransport.new(reader, writer)

    agent_out.close
    transport.receive.should be_nil
    transport.close

    reader.closed?.should be_true
    writer.closed?.should be_true
  end

  it "closes both IOs after a write failure" do
    reader, _agent_out = IO.pipe
    agent_in, writer = IO.pipe
    agent_in.close
    transport = ACP::StdioTransport.new(reader, writer)

    expect_raises(ACP::ConnectionClosedError) do
      transport.send({"jsonrpc" => JSON::Any.new("2.0")})
    end
    transport.close

    reader.closed?.should be_true
    writer.closed?.should be_true
  end
end

# ─── R17: an out-of-range error code must not raise OverflowError ──────
describe "ACP::JsonRpcError.from_json_any (out-of-range code)" do
  it "falls back to INTERNAL_ERROR for a code outside int32" do
    error = ACP::JsonRpcError.from_json_any(JSON.parse(%({"code":99999999999,"message":"boom"})))
    error.code.should eq(ACP::JsonRpcError::INTERNAL_ERROR)
    error.message.should eq("boom")
  end

  it "surfaces as a JsonRpcError from a request" do
    transport = SignalingTransport.new
    client = ACP::Client.new(transport)
    client.request_timeout = 2.0
    spawn do
      id = transport.written.receive["id"]
      transport.inject_raw(%({"jsonrpc":"2.0","id":#{id.to_json},"error":{"code":-99999999999,"message":"boom"}}))
    end

    expect_raises(ACP::JsonRpcError, "boom") { client.initialize_connection }
  ensure
    client.try(&.close)
  end
end

# ─── R18: a null `params` must be omitted, not sent ────────────────────
describe "ACP::Client extension messages without params" do
  it "omits `params` from an ext notification" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)

    client.ext_notification("vendor/ping")

    transport.last_sent.as(JSON::Any).as_h.has_key?("params").should be_false
    client.close
  end

  it "omits `params` from an ext request" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)
    spawn do
      sleep 10.milliseconds
      transport.inject_raw(%({"jsonrpc":"2.0","id":1,"result":{}}))
    end

    client.ext_method("vendor/ping")

    transport.last_sent.as(JSON::Any).as_h.has_key?("params").should be_false
    client.close
  end
end

# ─── R19: tool call fields the typed structs dropped ───────────────────
describe "ACP v1 tool call fields" do
  it "keeps name, locations, rawInput and rawOutput on a permission request's toolCall" do
    params = ACP::Protocol::RequestPermissionParams.from_json(
      %({"sessionId":"s","options":[],"toolCall":{"toolCallId":"t","name":"bash","locations":[{"path":"/a"}],"rawInput":{"cmd":"ls"},"rawOutput":"ok"}})
    )
    tool_call = params.tool_call
    tool_call.name.should eq("bash")
    tool_call.locations.try(&.size).should eq(1)
    tool_call.raw_input.try(&.["cmd"].as_s).should eq("ls")
    tool_call.raw_output.try(&.as_s).should eq("ok")
  end

  it "keeps `name` on tool_call and tool_call_update" do
    call = ACP::Protocol::SessionUpdate.from_json(
      %({"sessionUpdate":"tool_call","toolCallId":"t","title":"List","name":"bash"})
    )
    call.as(ACP::Protocol::ToolCallUpdate).name.should eq("bash")

    update = ACP::Protocol::SessionUpdate.from_json(
      %({"sessionUpdate":"tool_call_update","toolCallId":"t","name":"bash"})
    )
    update.as(ACP::Protocol::ToolCallStatusUpdate).name.should eq("bash")
  end
end

# ─── R20: one unrecognized config option must not sink the whole result ──
#
# session-config-options: "If a Client receives an option with an
# unrecognized `type`, it SHOULD ignore that option." Such an option (here
# one whose `currentValue` is a number) used to fail the whole session/new
# result with ProtocolError even though the session was created agent-side.
describe "ACP config options with an unrecognized type" do
  unknown_option = %({"id":"temp","name":"Temperature","type":"slider","currentValue":0.5})
  select_option = %({"id":"model","name":"Model","type":"select","currentValue":"a","options":[{"value":"a","name":"A"}]})

  it "skips the option in session/new instead of failing the result" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)
    client.request_timeout = 2.0

    spawn do
      sleep 10.milliseconds
      transport.inject_raw(build_init_response(1_i64))
      sleep 10.milliseconds
      transport.inject_raw(%({"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1","configOptions":[#{unknown_option},#{select_option}]}}))
    end

    client.initialize_connection
    result = client.session_new("/tmp")

    result.session_id.should eq("s1")
    result.config_options.try(&.map(&.id)).should eq(["model"])
    client.session_active?.should be_true
    client.close
  end

  it "skips it in every result that carries configOptions" do
    json = %({"sessionId":"s1","configOptions":[#{unknown_option},#{select_option}]})
    ACP::Protocol::SessionLoadResult.from_json(json).config_options.try(&.size).should eq(1)
    ACP::Protocol::SessionResumeResult.from_json(json).config_options.try(&.size).should eq(1)
    ACP::Protocol::SessionSetConfigOptionResult.from_json(json).config_options.size.should eq(1)
  end

  it "skips an unrecognized type even when its fields happen to parse" do
    text_option = %({"id":"note","name":"Note","type":"text","currentValue":"hi"})
    json = %({"sessionId":"s1","configOptions":[#{text_option},#{select_option}]})
    ACP::Protocol::SessionNewResult.from_json(json).config_options.try(&.map(&.id)).should eq(["model"])

    update = ACP::Protocol::SessionUpdate.from_json(
      %({"sessionUpdate":"config_option_update","configOptions":[#{unknown_option},#{text_option},#{select_option}]})
    ).as(ACP::Protocol::ConfigOptionUpdate)
    update.typed_config_options.map(&.id).should eq(["model"])
  end

  it "still round-trips configOptions and accepts null" do
    result = ACP::Protocol::SessionNewResult.from_json(%({"sessionId":"s1","configOptions":[#{select_option}]}))
    JSON.parse(result.to_json)["configOptions"][0]["id"].as_s.should eq("model")
    ACP::Protocol::SessionNewResult.from_json(%({"sessionId":"s1","configOptions":null})).config_options.should be_nil
  end
end

# ─── R21: session/cancel must answer pending permission requests ─────────
#
# prompt-turn#cancellation: "The Client MUST respond to all pending
# `session/request_permission` requests with the `cancelled` outcome."
# The permission handler runs on the dispatcher fiber, so while it waits
# for the user nothing answered the agent; once it returned, its (possibly
# "selected") answer went out even though the turn had been cancelled.
describe "ACP::Client#session_cancel with a pending permission request" do
  it "answers the request with `cancelled` and drops the late handler result" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)
    release = Channel(Nil).new
    entered = Channel(Nil).new(1)

    client.on_agent_request = ->(_method : String, _params : JSON::Any) do
      entered.send(nil)
      release.receive
      JSON.parse(ACP::Protocol::RequestPermissionResult.selected("allow").to_json)
    end

    transport.inject_raw(%({"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t"},"options":[]}}))
    entered.receive

    client.session_cancel("s1")

    responses = transport.sent_messages.select { |m| m["id"]?.try(&.as_s?) == "perm-1" }
    responses.size.should eq(1)
    responses[0]["result"]["outcome"]["outcome"].as_s.should eq("cancelled")

    release.send(nil)
    sleep 20.milliseconds

    transport.sent_messages.count { |m| m["id"]?.try(&.as_s?) == "perm-1" }.should eq(1)
    client.close
  end

  it "leaves permission requests of other sessions alone" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)
    release = Channel(Nil).new
    entered = Channel(Nil).new(1)

    client.on_agent_request = ->(_method : String, _params : JSON::Any) do
      entered.send(nil)
      release.receive
      JSON.parse(ACP::Protocol::RequestPermissionResult.selected("allow").to_json)
    end

    transport.inject_raw(%({"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{"sessionId":"other","toolCall":{"toolCallId":"t"},"options":[]}}))
    entered.receive

    client.session_cancel("s1")
    transport.sent_messages.any? { |m| m["id"]? == 7 }.should be_false

    release.send(nil)
    sleep 20.milliseconds

    answer = transport.sent_messages.find! { |m| m["id"]? == 7 }
    answer["result"]["outcome"]["outcome"].as_s.should eq("selected")
    client.close
  end
end

# ─── R22: session_info_update must distinguish `null` from omitted ───────
#
# session-list#updating-session-metadata: "Omitted fields are left
# unchanged" but `title` / `updatedAt` "Set to `null` to clear". Both used
# to parse to nil, so a client could not tell a clear from no change.
describe "ACP::Protocol::SessionInfoUpdate field presence" do
  it "reports whether title and updatedAt were sent" do
    cleared = ACP::Protocol::SessionUpdate.from_json(%({"sessionUpdate":"session_info_update","title":null})).as(ACP::Protocol::SessionInfoUpdate)
    cleared.title.should be_nil
    cleared.title_present?.should be_true
    cleared.updated_at_present?.should be_false

    unchanged = ACP::Protocol::SessionUpdate.from_json(%({"sessionUpdate":"session_info_update","updatedAt":"2026-01-01T00:00:00Z"})).as(ACP::Protocol::SessionInfoUpdate)
    unchanged.title_present?.should be_false
    unchanged.updated_at_present?.should be_true
  end

  it "treats fields given to the constructor as present" do
    update = ACP::Protocol::SessionInfoUpdate.new(title: "T")
    update.title_present?.should be_true
    update.updated_at_present?.should be_false

    update.updated_at = nil
    update.updated_at_present?.should be_true
  end
end

# ─── R23: a blocked agent-request handler must not stall the dispatcher ──
#
# prompt-turn#cancellation: after `session/cancel` the Agent answers the
# prompt with `cancelled`. Handlers ran on the dispatcher fiber, so one
# still blocked (here: a permission prompt the user never answers, already
# answered `cancelled` by `session_cancel`) kept that response unread until
# `prompt_timeout`.

# Signals every frame the client writes, so the "agent" side can react to
# it without sleeping.
class SignalingTransport < TestTransport
  getter written : Channel(JSON::Any) = Channel(JSON::Any).new(64)

  def send(message : Hash(String, JSON::Any)) : Nil
    super
    @written.send(sent_messages.last)
  end
end

describe "ACP::Client agent request handlers" do
  it "keeps reading responses while a handler is blocked" do
    transport = SignalingTransport.new
    client = ACP::Client.new(transport)
    client.prompt_timeout = 2.0   # bounds the failure mode; never waited on when passing
    release = Channel(Nil).new(1) # buffered: the ensure must not block if the handler never ran
    entered = Channel(Nil).new(1)

    spawn do
      request = next_answer(transport)
      transport.inject_raw(build_init_response(request["id"].as_i64))
    end
    client.initialize_connection

    client.on_agent_request = ->(_method : String, _params : JSON::Any) do
      entered.send(nil)
      release.receive
      JSON.parse(ACP::Protocol::RequestPermissionResult.selected("allow").to_json)
    end

    spawn do
      prompt_id = transport.written.receive["id"].as_i64
      transport.inject_raw(%({"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t"},"options":[]}}))
      entered.receive
      client.session_cancel("s1")
      transport.inject_raw(%({"jsonrpc":"2.0","id":#{prompt_id},"result":{"stopReason":"cancelled"}}))
    end

    begin
      result = client.session_prompt_text("hi", "s1")
      result.stop_reason.should eq("cancelled")
    ensure
      release.send(nil)
    end

    answers = transport.sent_messages.select { |m| m["id"]?.try(&.as_s?) == "perm-1" }
    answers.size.should eq(1)
    answers[0]["result"]["outcome"]["outcome"].as_s.should eq("cancelled")
    client.close
  end

  it "still answers a raising handler with a JSON-RPC error" do
    transport = SignalingTransport.new
    client = ACP::Client.new(transport)
    client.on_agent_request = ->(_method : String, _params : JSON::Any) : JSON::Any { raise "boom" }

    transport.inject_raw(%({"jsonrpc":"2.0","id":5,"method":"_x/y","params":{}}))
    answer = transport.written.receive
    answer["id"].as_i.should eq(5)
    answer["error"]["code"].as_i.should eq(ACP::JsonRpcError::INTERNAL_ERROR)
    client.close
  end

  it "drops, without counting a dispatch error, the answer of a handler that outlives the connection" do
    transport = SignalingTransport.new
    client = ACP::Client.new(transport)
    release = Channel(Nil).new(1)
    entered = Channel(Nil).new(1)
    done = Channel(Nil).new
    disconnected = Channel(Nil).new(1)
    client.on_disconnect = -> { disconnected.send(nil); nil }

    client.on_agent_request = ->(_method : String, _params : JSON::Any) do
      entered.send(nil)
      release.receive
      done.send(nil)
      JSON::Any.new(nil)
    end

    Log.capture("acp.client", level: :warn) do |logs|
      transport.inject_raw(%({"jsonrpc":"2.0","id":9,"method":"_x/y","params":{}}))
      entered.receive
      transport.close # the agent went away (EOF), not a user close
      disconnected.receive
      release.send(nil)
      done.receive # the handler fiber runs on to its failed write before we resume

      logs.empty # the failed write is dropped quietly, not reported as stream corruption
    end
    transport.sent_messages.any? { |m| m["id"]? == 9 }.should be_false
  end
end

# ─── R24: uint32 / uint64 schema fields must decode their full range ────
#
# schema.json: ReadTextFileRequest.line/limit and ToolCallLocation.line are
# `uint32`, CreateTerminalRequest.outputByteLimit and UsageUpdate.used/size
# are `uint64`. They were Int32/Int64, so valid values above the signed
# maximum failed to parse and negative values were accepted.
describe "ACP unsigned protocol integers" do
  it "decodes values above the signed maximum" do
    params = ACP::Protocol::ReadTextFileParams.from_json(%({"sessionId":"s","path":"/a","line":4294967295,"limit":2147483648}))
    params.line.should eq(UInt32::MAX)
    params.limit.should eq(2147483648_u32)

    ACP::Protocol::ToolCallLocation.from_json(%({"path":"/a","line":4294967295})).line.should eq(UInt32::MAX)
    ACP::Protocol::CreateTerminalParams.from_json(%({"sessionId":"s","command":"c","outputByteLimit":18446744073709551615})).output_byte_limit.should eq(UInt64::MAX)

    usage = ACP::Protocol::SessionUpdate.from_json(%({"sessionUpdate":"usage_update","used":9223372036854775808,"size":18446744073709551615})).as(ACP::Protocol::UsageUpdate)
    usage.used.should eq(9223372036854775808_u64)
    usage.size.should eq(UInt64::MAX)
  end

  it "rejects a negative fs/read_text_file line with INVALID_PARAMS" do
    transport = SignalingTransport.new
    client = ACP::Client.new(transport)
    called = false
    client.on_read_text_file = ->(_p : ACP::Protocol::ReadTextFileParams) do
      called = true
      ACP::Protocol::ReadTextFileResult.new(content: "")
    end

    transport.inject_raw(%({"jsonrpc":"2.0","id":3,"method":"fs/read_text_file","params":{"sessionId":"s","path":"/a","line":-1}}))
    answer = transport.written.receive
    answer["id"].as_i.should eq(3)
    answer["error"]["code"].as_i.should eq(ACP::JsonRpcError::INVALID_PARAMS)
    called.should be_false
    client.close
  end
end

# The next frame the client writes, or a failure instead of a hang.
private def next_answer(transport : SignalingTransport) : JSON::Any
  select
  when frame = transport.written.receive
    frame
  when timeout(2.seconds)
    fail "the client sent no answer"
  end
end

# ─── R25: a request with `"id": null` must be answered, not dropped ─────
#
# JSON-RPC 2.0 §4.1: "A Notification is a Request object without an "id"
# member." ACP's `RequestId` includes `null`, and the Rust SDK echoes it.
# The client treated `"id": null` like a missing id, so the request was
# never answered and the agent waited forever.
describe "ACP::Client agent request with a null id" do
  it "answers it with \"id\": null" do
    transport = SignalingTransport.new
    client = ACP::Client.new(transport)
    client.on_agent_request = ->(_method : String, _params : JSON::Any) { JSON.parse(%({"ok":true})) }

    transport.inject_raw(%({"jsonrpc":"2.0","id":null,"method":"_x/echo","params":{}}))
    answer = next_answer(transport)
    answer.as_h.has_key?("id").should be_true
    answer["id"].raw.should be_nil
    answer["result"]["ok"].as_bool.should be_true
    client.close
  end

  it "auto-cancels a null-id permission request when no handler is set" do
    transport = SignalingTransport.new
    client = ACP::Client.new(transport)

    transport.inject_raw(%({"jsonrpc":"2.0","id":null,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"t"},"options":[]}}))
    answer = next_answer(transport)
    answer["id"].raw.should be_nil
    answer["result"]["outcome"]["outcome"].as_s.should eq("cancelled")
    client.close
  end

  it "answers every one of several null-id permission requests" do
    transport = SignalingTransport.new
    client = ACP::Client.new(transport)
    client.on_agent_request = ->(_m : String, _p : JSON::Any) { JSON.parse(ACP::Protocol::RequestPermissionResult.selected("ok").to_json) }

    2.times do
      transport.inject_raw(%({"jsonrpc":"2.0","id":null,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"t"},"options":[]}}))
    end
    2.times { next_answer(transport)["result"]["outcome"]["optionId"].as_s.should eq("ok") }
    client.close
  end

  it "still delivers a session/update that carries \"id\": null, without answering it" do
    transport = SignalingTransport.new
    client = ACP::Client.new(transport)
    got = Channel(String).new(1)
    client.on_update = ->(p : ACP::Protocol::SessionUpdateParams) { got.send(p.session_id); nil }

    transport.inject_raw(%({"jsonrpc":"2.0","id":null,"method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}}))
    got.receive.should eq("s1")
    transport.sent_messages.should be_empty
    client.close
  end
end

# ─── R26: unreadable frames get a JSON-RPC error with `"id": null` ──────
#
# JSON-RPC 2.0 §5: when the id of a request can't be detected (Invalid
# Request), the error response's id MUST be null; §6: a batch the server
# doesn't accept gets a single error. The client dropped all of these, so a
# peer that sent one never got an answer. Matches the Rust SDK, which
# answers -32600 unless the value is shaped like a response.
describe "ACP::Client invalid JSON-RPC frames" do
  it "answers a request whose id can't be represented with -32600" do
    transport = SignalingTransport.new
    client = ACP::Client.new(transport)
    called = false
    client.on_agent_request = ->(_m : String, _p : JSON::Any) { called = true; JSON::Any.new(nil) }

    [%(1.5), %(true), %([1]), %(1e300), %(9223372036854775807.0)].each do |id|
      transport.inject_raw(%({"jsonrpc":"2.0","id":#{id},"method":"_x/y","params":{}}))
      answer = next_answer(transport)
      answer["id"].raw.should be_nil
      answer["error"]["code"].as_i.should eq(ACP::JsonRpcError::INVALID_REQUEST)
    end
    called.should be_false
    client.close
  end

  it "answers batches, scalars and envelope-less objects with -32600" do
    transport = SignalingTransport.new
    client = ACP::Client.new(transport)

    ["[]", %([{"jsonrpc":"2.0","id":1,"method":"_x"}]), "17", "null", "{}", %({"jsonrpc":"2.0","method":5}), %({"jsonrpc":"2.0","id":3,"method":5})].each do |raw|
      transport.inject_raw(raw)
      answer = next_answer(transport)
      answer["id"].raw.should be_nil
      answer["error"]["code"].as_i.should eq(ACP::JsonRpcError::INVALID_REQUEST)
    end
    client.close
  end

  it "does not answer a response, even one without a usable id" do
    transport = SignalingTransport.new
    client = ACP::Client.new(transport)

    transport.inject_raw(%({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}))
    transport.inject_raw(%({"jsonrpc":"2.0","result":{}}))
    transport.inject_raw(%({"jsonrpc":"2.0","method":"_ping"})) # a notification, to sync on
    sleep 50.milliseconds
    transport.sent_messages.should be_empty
    client.close
  end
end

describe "ACP::StdioTransport unparseable input" do
  it "answers a line that is not JSON with -32700 and \"id\": null" do
    agent_out_r, agent_out_w = IO.pipe # agent stdout → client
    agent_in_r, agent_in_w = IO.pipe   # client → agent stdin
    transport = ACP::StdioTransport.new(agent_out_r, agent_in_w)

    agent_out_w.puts %({"jsonrpc":"2.0","id":1,"method":"x", INVALID})
    lines = Channel(String).new(1)
    spawn { lines.send(agent_in_r.gets || "") }
    line = select
    when l = lines.receive then l
    when timeout(2.seconds) then fail "no parse error was sent"
    end
    answer = JSON.parse(line)
    answer["id"].raw.should be_nil
    answer["error"]["code"].as_i.should eq(ACP::JsonRpcError::PARSE_ERROR)
    line.includes?("INVALID").should be_false # the raw line is not echoed

    # The stream stays usable.
    agent_out_w.puts %({"jsonrpc":"2.0","method":"_ping"})
    transport.receive.try(&.["method"].as_s).should eq("_ping")

    transport.close
    agent_out_w.close
    agent_in_r.close
  end
end

# ─── R27: a handler's JsonRpcError must reach the agent unchanged ───────
#
# error#unknown-sessions: "Clients SHOULD respond with -32002 when
# fs/read_text_file names a file that does not exist, or a terminal/* method
# names an unknown terminal." cancellation: a cancelled request MUST get a
# valid response or -32800. Every handler exception became -32603, so a
# handler had no way to send either.
describe "ACP::Client handler JSON-RPC errors" do
  it "sends the code, message and data of a JsonRpcError raised by a typed handler" do
    transport = SignalingTransport.new
    client = ACP::Client.new(transport)
    client.on_read_text_file = ->(p : ACP::Protocol::ReadTextFileParams) : ACP::Protocol::ReadTextFileResult do
      raise ACP::JsonRpcError.new(ACP::JsonRpcError::RESOURCE_NOT_FOUND, "Resource not found", JSON.parse(%({"uri":"#{p.path}"})))
    end

    transport.inject_raw(%({"jsonrpc":"2.0","id":4,"method":"fs/read_text_file","params":{"sessionId":"s","path":"/nope"}}))
    answer = next_answer(transport)
    answer["id"].as_i.should eq(4)
    answer["error"]["code"].as_i.should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)
    answer["error"]["message"].as_s.should eq("Resource not found")
    answer["error"]["data"]["uri"].as_s.should eq("/nope")
    client.close
  end

  it "does so for on_agent_request and permission handlers too" do
    transport = SignalingTransport.new
    client = ACP::Client.new(transport)
    client.on_agent_request = ->(_m : String, _p : JSON::Any) : JSON::Any do
      raise ACP::JsonRpcError.new(ACP::JsonRpcError::REQUEST_CANCELLED, "Request cancelled")
    end

    transport.inject_raw(%({"jsonrpc":"2.0","id":5,"method":"_x/y","params":{}}))
    next_answer(transport)["error"]["code"].as_i.should eq(ACP::JsonRpcError::REQUEST_CANCELLED)

    transport.inject_raw(%({"jsonrpc":"2.0","id":6,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"t"},"options":[]}}))
    next_answer(transport)["error"]["code"].as_i.should eq(ACP::JsonRpcError::REQUEST_CANCELLED)
    client.close
  end

  it "does not echo an error the agent returned to the handler's own request" do
    transport = SignalingTransport.new
    client = ACP::Client.new(transport)
    client.on_agent_request = ->(_m : String, _p : JSON::Any) : JSON::Any do
      raise ACP::JsonRpcError.from_json_any(JSON.parse(%({"code":-32601,"message":"Method not found"})))
    end

    transport.inject_raw(%({"jsonrpc":"2.0","id":8,"method":"_x/y","params":{}}))
    next_answer(transport)["error"]["code"].as_i.should eq(ACP::JsonRpcError::INTERNAL_ERROR)
    client.close
  end

  it "reports a JSON error from the handler's own code as -32603, not invalid params" do
    transport = SignalingTransport.new
    client = ACP::Client.new(transport)
    client.on_read_text_file = ->(_p : ACP::Protocol::ReadTextFileParams) do
      ACP::Protocol::ReadTextFileResult.from_json(%({"wrong":1}))
    end

    transport.inject_raw(%({"jsonrpc":"2.0","id":7,"method":"fs/read_text_file","params":{"sessionId":"s","path":"/a"}}))
    next_answer(transport)["error"]["code"].as_i.should eq(ACP::JsonRpcError::INTERNAL_ERROR)
    client.close
  end
end

# ─── R28: -32002 to session/close is a successful close ─────────────────
#
# session-setup#closing-active-sessions: "Clients SHOULD treat a -32002
# response to session/close as a successful close." It raised instead, and
# the client kept reporting the gone session as active.
private def r28_close_with_error(code : Int32) : {ACP::Client, Exception?}
  transport, client, _session = r8_client_with_session(session_capabilities: %({"close":{}}))
  spawn do
    sleep 10.milliseconds
    if msg = transport.last_sent
      transport.inject_raw(%({"jsonrpc":"2.0","id":#{msg["id"].as_i64},"error":{"code":#{code},"message":"Resource not found","data":{"sessionId":"sess-r8"}}}))
    end
  end
  error = begin
    client.session_close
    nil
  rescue ex
    ex
  end
  {client, error}
end

describe "ACP::Client#session_close with -32002" do
  it "treats -32002 as a successful close" do
    client, error = r28_close_with_error(ACP::JsonRpcError::RESOURCE_NOT_FOUND)
    error.should be_nil
    client.session_id.should be_nil
    client.state.should eq(ACP::ClientState::Initialized)
    client.close
  end

  it "still raises other errors" do
    client, error = r28_close_with_error(ACP::JsonRpcError::INTERNAL_ERROR)
    error.should be_a(ACP::JsonRpcError)
    client.session_id.should eq("sess-r8")
    client.close
  end
end

# ─── R29: a repeated response must not stall the dispatcher ─────────────
#
# JSON-RPC 2.0 §5: the Server replies to a request with exactly one
# Response. The dispatcher pushed every response for a still-registered id
# into that request's one-slot channel, so a third copy read in the same
# burst blocked the dispatcher fiber forever: no later response or
# notification was ever delivered.
describe "ACP::Client repeated responses" do
  it "keeps dispatching after the agent answers one request three times" do
    transport = SignalingTransport.new
    client = ACP::Client.new(transport)
    client.request_timeout = 2.0
    pings = Channel(Nil).new(1)
    client.on_notification = ->(_m : String, _p : JSON::Any?) { pings.send(nil) }

    first = Channel(JSON::Any).new(1)
    spawn { first.send(client.send_request_raw("_a", JSON::Any.new(nil))) }
    transport.written.receive
    3.times { transport.inject_raw(%({"jsonrpc":"2.0","id":1,"result":{"n":1}})) }
    transport.inject_raw(%({"jsonrpc":"2.0","method":"_ping"}))

    select
    when pings.receive
    when timeout(1.second) then fail "the dispatcher stopped after a repeated response"
    end
    first.receive["n"].as_i.should eq(1)

    spawn do
      transport.written.receive
      transport.inject_raw(%({"jsonrpc":"2.0","id":2,"result":{"n":2}}))
    end
    client.send_request_raw("_b", JSON::Any.new(nil))["n"].as_i.should eq(2)
    client.close
  end
end

# ─── R30: losing the connection mid-request raises ConnectionClosedError ─
#
# `Client#send_request` documents "Raises `ConnectionClosedError` if the
# transport is closed", and the error guide rescues it as "Connection
# lost". A request still waiting when the agent died (or `close` ran) got a
# made-up `JsonRpcError` -32603 instead, flagged `received?` as if the agent
# had sent it.
describe "ACP::Client requests pending at disconnect" do
  it "raise ConnectionClosedError when the agent's stdout ends" do
    transport = SignalingTransport.new
    client = ACP::Client.new(transport)
    client.request_timeout = 2.0
    spawn do
      transport.written.receive
      transport.inject_message(nil) # EOF
    end
    expect_raises(ACP::ConnectionClosedError, /Connection lost/) do
      client.send_request_raw("_a", JSON::Any.new(nil))
    end
    client.close
  end

  it "refuse a request made after the connection was lost, even if the transport still accepts writes" do
    transport = TestTransport.new
    client = ACP::Client.new(transport)
    client.request_timeout = 2.0
    transport.inject_message(nil) # EOF; TestTransport#send keeps working
    sleep 20.milliseconds
    expect_raises(ACP::ConnectionClosedError) do
      client.send_request_raw("_a", JSON::Any.new(nil))
    end
    transport.sent_messages.should be_empty
    client.close
  end

  it "raise ConnectionClosedError when the client is closed, with or without a timeout" do
    [2.0, nil].each do |timeout|
      transport = SignalingTransport.new
      client = ACP::Client.new(transport)
      client.request_timeout = timeout
      spawn do
        transport.written.receive
        client.close
      end
      expect_raises(ACP::ConnectionClosedError, /Client closed/) do
        client.send_request_raw("_a", JSON::Any.new(nil))
      end
    end
  end

  it "does so for a real agent process that exits mid-request" do
    transport = ACP::ProcessTransport.new("sh", ["-c", "read line; exit 3"])
    client = ACP::Client.new(transport)
    client.request_timeout = 5.0
    expect_raises(ACP::ConnectionClosedError) do
      client.send_request_raw("_a", JSON::Any.new(nil))
    end
    client.close
    transport.wait.exit_code.should eq(3)
  end
end

# Debug logs need to hide launch descriptors while keeping the actual
# initialize response available to the application.
describe "ACP terminal authentication logging" do
  it "redacts authentication methods from transport logs only" do
    frame = %({"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"authMethods":[{"type":"terminal","id":"t","name":"Terminal","env":{"EXAMPLE_VALUE":"sample-value"}}]}})
    Log.capture("acp.transport", level: :debug) do |logs|
      transport = ACP::StdioTransport.new(IO::Memory.new(frame + "\n"), IO::Memory.new)
      transport.receive.not_nil!["result"]["authMethods"][0]["env"]["EXAMPLE_VALUE"].should eq("sample-value")
      logs.check(:debug, /"authMethods":"\[REDACTED\]"/)
      logs.entry.message.should_not contain("sample-value")
    ensure
      transport.try(&.close)
    end
  end
end

# Launch settings contain environment values and HTTP headers. Debug logs
# must redact those while the Agent still receives the original request.
describe "ACP MCP configuration logging" do
  it "redacts MCP configurations without altering the outgoing frames" do
    reader, feed = IO.pipe
    writer = IO::Memory.new
    Log.capture("acp.transport", level: :debug) do |logs|
      transport = ACP::StdioTransport.new(reader, writer)
      ["session/new", "session/load", "session/resume", "session/fork"].each do |method|
        frame = JSON.parse(%({"jsonrpc":"2.0","id":1,"method":#{method.to_json},"params":{"cwd":"/work","mcpServers":[{"type":"stdio","env":[{"name":"API_KEY","value":"example-secret"}]},{"type":"http","headers":[{"name":"Authorization","value":"example-token"}]}]}}))
        transport.send(frame.as_h)
        logs.check(:debug, /"mcpServers":"\[REDACTED\]"/)
        logs.entry.message.should contain(%("method":#{method.to_json}))
        logs.entry.message.should contain(%("cwd":"/work"))
        logs.entry.message.should_not contain("example-secret")
        logs.entry.message.should_not contain("example-token")
        JSON.parse(writer.to_s.lines.last).should eq(frame)
      end
    ensure
      transport.try(&.close)
    end
  ensure
    reader.try(&.close)
    feed.try(&.close)
  end
end

describe "ACP typed content chunks" do
  it "retains the message ID and metadata from each message update" do
    %w(agent_message_chunk user_message_chunk agent_thought_chunk).each do |kind|
      wire = %({"sessionUpdate":#{kind.to_json},"messageId":"message-1","content":{"type":"text","text":"chunk"},"_meta":{"example.test/chunk":true}})
      update = ACP::Protocol::SessionUpdate.from_json(wire)
      wire_chunk = case update
                   when ACP::Protocol::AgentMessageChunkUpdate, ACP::Protocol::UserMessageChunkUpdate, ACP::Protocol::AgentThoughtChunkUpdate
                     JSON.parse(update.to_content_chunk.not_nil!.to_json)
                   else
                     raise "expected a chunk update"
                   end

      wire_chunk["messageId"].should eq("message-1")
      wire_chunk["_meta"].should eq(JSON.parse(%({"example.test/chunk":true})))
    end
  end
end

# ACP v2 restricts the requests a Client may send. In particular, invalid
# params must be caught before an Agent can insert a prompt or start a session.
describe "ACP v2 outgoing requests" do
  it "rejects empty prompts, malformed content, and invalid idempotency keys before sending" do
    with_v2_request_client do |client, transport|
      expect_raises(ArgumentError, /at least one content block/) do
        client.session_prompt(ACP::Protocol::V2::SessionPromptParams.new("session", [] of JSON::Any))
      end
      [{"type" => "text"}, {"text" => "Missing type"}].each do |fields|
        block = JSON.parse(fields.to_json)
        expect_raises(ArgumentError, /content block/) do
          client.session_prompt(ACP::Protocol::V2::SessionPromptParams.new("session", [block]))
        end
      end
      ["", "한" * 256].each do |key|
        expect_raises(ArgumentError, /1 to 255 characters/) { client.session_prompt_text("session", "Hello", key) }
      end
      transport.sent_messages.size.should eq(1)

      valid_key = "한" * 255
      spawn do
        frame = next_answer(transport)
        transport.inject_raw(%({"jsonrpc":"2.0","id":#{frame["id"].to_json},"result":{"messageId":"m"}}))
      end
      client.session_prompt_text("session", "Hello", valid_key).message_id.should eq("m")
      transport.sent_messages.last["params"]["idempotencyKey"].should eq(valid_key)
    end
  end

  it "validates advertised setup options and absolute paths on both setup methods" do
    caps = %({"mcp":{"stdio":{},"http":{}},"systemPrompt":{}})
    with_v2_request_client(caps) do |client, transport|
      stdio = ACP::Protocol::V2::McpServer.stdio(ACP::Protocol::McpServerStdio.new("tools", "/bin/true"))
      relative = ACP::Protocol::V2::McpServer.stdio(ACP::Protocol::McpServerStdio.new("tools", "server"))
      http = ACP::Protocol::V2::McpServer.http(ACP::Protocol::McpServerHttp.new("tools", "https://example.test/mcp"))
      malformed_http = ACP::Protocol::V2::McpServer.new("http", {"name" => JSON::Any.new("missing-url")})
      expect_raises(ArgumentError, /commands must be absolute/) do
        client.session_new(ACP::Protocol::V2::SessionNewParams.new("/work", mcp_servers: [relative]))
      end
      expect_raises(ArgumentError, /names must be unique/) do
        client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("session", "/work", mcp_servers: [stdio, http]))
      end
      expect_raises(ArgumentError, /MCP HTTP configuration/) do
        client.session_new(ACP::Protocol::V2::SessionNewParams.new("/work", mcp_servers: [malformed_http]))
      end
      invalid_url = ACP::Protocol::V2::McpServer.http(ACP::Protocol::McpServerHttp.new("tools", "/mcp"))
      expect_raises(ArgumentError, /absolute HTTP\(S\) URL/) do
        client.session_new(ACP::Protocol::V2::SessionNewParams.new("/work", mcp_servers: [invalid_url]))
      end
      expect_raises(ArgumentError, /MCP SSE/) do
        client.session_new(ACP::Protocol::V2::SessionNewParams.new("/work", mcp_servers: [ACP::Protocol::V2::McpServer.new("sse")]))
      end
      expect_raises(ACP::InvalidStateError, /additionalDirectories/) do
        client.session_new(ACP::Protocol::V2::SessionNewParams.new("/work", additional_directories: [] of String))
      end
      expect_raises(ArgumentError, /list directory must be absolute/) do
        client.session_list(ACP::Protocol::V2::SessionListParams.new(cwd: "relative"))
      end
      system_prompt = ACP::Protocol::SystemPrompt.new("append", [] of ACP::Protocol::ContentBlock)
      expect_raises(ArgumentError, /system prompts require/) do
        client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("session", "/work", system_prompt: system_prompt))
      end
      transport.sent_messages.size.should eq(1)

      windows_server = ACP::Protocol::V2::McpServer.stdio(ACP::Protocol::McpServerStdio.new("win", "C:/tools/mcp.exe"))
      spawn do
        frame = next_answer(transport)
        transport.inject_raw(%({"jsonrpc":"2.0","id":#{frame["id"].to_json},"result":{"sessionId":"win"}}))
      end
      client.session_new(ACP::Protocol::V2::SessionNewParams.new("C:/work", mcp_servers: [windows_server])).session_id.should eq("win")
      client.session_workspace("win").not_nil!.cwd.should eq("C:/work")
      transport.sent_messages.last["params"]["mcpServers"][0]["command"].should eq("C:/tools/mcp.exe")
    end
  end

  it "checks configuration value types and sends false as a valid boolean" do
    with_v2_request_client do |client, transport|
      expect_raises(ArgumentError, /IDs must be strings/) do
        client.session_set_config_option(ACP::Protocol::V2::SessionSetConfigOptionParams.new("session", "mode", "id", JSON::Any.new(false)))
      end
      expect_raises(ArgumentError, /must be booleans/) do
        client.session_set_config_option(ACP::Protocol::V2::SessionSetConfigOptionParams.new("session", "toggle", "boolean", JSON::Any.new("false")))
      end
      transport.sent_messages.size.should eq(1)

      spawn do
        setup = next_answer(transport)
        transport.inject_raw(%({"jsonrpc":"2.0","id":#{setup["id"]},"result":{"sessionId":"session","configOptions":[{"configId":"toggle","name":"Toggle","type":"boolean","currentValue":true}]}}))
        frame = next_answer(transport)
        transport.inject_raw(%({"jsonrpc":"2.0","id":#{frame["id"].to_json},"result":{"configOptions":[]}}))
      end
      client.session_new("/work")
      client.session_set_config_option(ACP::Protocol::V2::SessionSetConfigOptionParams.new("session", "toggle", false))
      transport.sent_messages.last["params"]["value"].should eq(false)
    end
  end
end

private def with_v2_request_client(session_capabilities : String = "{}", &)
  transport = SignalingTransport.new
  client = ACP::V2::Client.new(transport)
  client.request_timeout = 2.0
  client.prompt_timeout = 2.0
  spawn do
    frame = next_answer(transport)
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{frame["id"].to_json},"result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":#{session_capabilities}}}}))
  end
  client.initialize_connection
  yield client, transport
ensure
  client.try(&.close)
end

describe "ACP stdio messages with wide integers" do
  it "distinguishes malformed frames from valid deeply nested wire JSON" do
    with_wide_stdio do |transport, feed, outgoing|
      ["1 2", "1:2"].each do |invalid|
        feed.puts invalid
        JSON.parse(outgoing.gets.not_nil!)["error"]["code"].should eq(-32700)
      end
      payload = "[" * 110 + "18446744073709551615" + "]" * 110
      valid = %({"jsonrpc":"2.0","method":"_wide","params":{"nested":#{payload}}})
      feed.puts valid
      frame = transport.receive_frame(2.seconds).as(ACP::Protocol::WireFrame)
      frame.json.should eq(valid)
      feed.puts %({"jsonrpc":"2.0","method":"_after"})
      transport.receive(2.seconds).not_nil!["method"].should eq("_after")
    end
  end

  it "delivers v1 usage updates with exact counts, including legacy discriminators" do
    with_wide_stdio do |transport, feed, _outgoing|
      client = ACP::Client.new(transport)
      updates = Channel(ACP::Protocol::SessionUpdate).new(1)
      client.on_update = ->(note : ACP::Protocol::SessionUpdateParams) do
        updates.send(note.update)
        nil
      end
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"type":"usage_update","used":9223372036854775808,"size":18446744073709551615}}})
      select
      when update = updates.receive
        usage = update.as(ACP::Protocol::UsageUpdate)
        usage.used.should eq(9223372036854775808_u64)
        usage.size.should eq(UInt64::MAX)
      when timeout(2.seconds)
        fail "the wide v1 usage update was dropped"
      end
    ensure
      client.try(&.close)
    end
  end

  it "passes a full unsigned byte limit to the typed terminal handler" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::Client.new(transport)
      client.on_create_terminal = ->(params : ACP::Protocol::CreateTerminalParams) do
        ACP::Protocol::CreateTerminalResult.new(params.output_byte_limit.to_s)
      end
      feed.puts %({"jsonrpc":"2.0","id":"term","method":"terminal/create","params":{"sessionId":"s","command":"echo","outputByteLimit":18446744073709551615}})
      reply = JSON.parse(outgoing.gets.not_nil!)
      reply["id"].should eq("term")
      reply["result"]["terminalId"].should eq("18446744073709551615")
    ensure
      client.try(&.close)
    end
  end

  it "delivers v2 usage updates and preserves their original numeric JSON" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      updates = Channel(ACP::Protocol::V2::SessionUpdate).new(1)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        updates.send(note.update)
        nil
      end
      initialize_wide_v2(client, feed, outgoing)
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"usage_update","used":9223372036854775808,"size":18446744073709551615}}})
      select
      when update = updates.receive
        usage = update.typed.as(ACP::Protocol::V2::UsageUpdate)
        usage.used.should eq(9223372036854775808_u64)
        usage.size.should eq(UInt64::MAX)
        update.raw_field("size").should eq("18446744073709551615")
        update.to_json.should contain(%("size":18446744073709551615))
      when timeout(2.seconds)
        fail "the wide v2 usage update was dropped"
      end
    ensure
      client.try(&.close)
    end
  end

  it "decodes exact v2 form limits and rejects an out-of-range request ID" do
    with_wide_stdio do |transport, feed, outgoing|
      capabilities = ACP::Protocol::V2::ClientCapabilities.new(
        elicitation: ACP::Protocol::ElicitationCapabilities.from_json(%({"form":{}})),
      )
      client = ACP::V2::Client.new(transport, capabilities: capabilities)
      client.request_timeout = 2.0
      limits = Channel(UInt64?).new(1)
      client.on_create_elicitation = ->(params : ACP::Protocol::CreateElicitationParams) do
        limits.send(params.requested_schema.not_nil!.properties.not_nil!["choices"].max_items)
        ACP::Protocol::CreateElicitationResult.decline
      end
      initialize_wide_v2(client, feed, outgoing)
      feed.puts %({"jsonrpc":"2.0","id":18446744073709551615,"method":"_test","params":{}})
      rejection = JSON.parse(outgoing.gets.not_nil!)
      rejection["id"].raw.should be_nil
      rejection["error"]["code"].should eq(-32600)
      feed.puts %({"jsonrpc":"2.0","id":"form","method":"elicitation/create","params":{"sessionId":"s","mode":"form","message":"Choose","requestedSchema":{"type":"object","properties":{"choices":{"type":"array","items":{"type":"string","enum":["one"]},"maxItems":18446744073709551615}}}}})
      reply = JSON.parse(outgoing.gets.not_nil!)
      reply["id"].should eq("form")
      reply["result"]["action"].should eq("decline")
      select
      when limit = limits.receive
        limit.should eq(UInt64::MAX)
      else
        fail "the elicitation handler was not invoked"
      end
    ensure
      client.try(&.close)
    end
  end

  it "preserves rather than projects wide fields in cached v2 subagent state" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      updates = Channel(Nil).new(2)
      client.on_update = ->(_note : ACP::Protocol::V2::SessionUpdateParams) do
        updates.send(nil)
        nil
      end
      initialize_wide_v2(client, feed, outgoing)
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":{"sessionUpdate":"subagent_update","sessionId":"child","state":{"state":"running","_meta":{"counter":18446744073709551615}}}}})
      await_wide_update(updates)
      first = client.subagent("child").not_nil!.state.not_nil!
      first.state.should eq("running")
      first.meta.should be_nil
      first.raw_field("_meta").should eq(%({"counter":18446744073709551615}))
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"child","update":{"sessionUpdate":"state_update","state":"idle","stopReason":"error","error":{"code":-32603,"message":"Failed","data":{"counter":18446744073709551615}}}}})
      await_wide_update(updates)
      second = client.subagent("child").not_nil!.state.not_nil!
      second.stop_reason.should eq("error")
      second.error.should be_nil
      second.raw_field("error").not_nil!.should contain(%("counter":18446744073709551615))
    ensure
      client.try(&.close)
    end
  end

  it "reports a local representation error for a wide JSON::Any response and keeps dispatching" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::Client.new(transport)
      client.request_timeout = 2.0
      spawn do
        wide = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{wide["id"].to_json},"result":18446744073709551615})
        ordinary = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{ordinary["id"].to_json},"result":42})
      end
      expect_raises(ACP::ProtocolError, /outside the range/) { client.send_request_raw("_wide", JSON.parse("{}")) }
      client.send_request_raw("_ordinary", JSON.parse("{}")).as_i.should eq(42)
    ensure
      client.try(&.close)
    end
  end
end

private def with_wide_stdio(&)
  reader, feed = IO.pipe
  outgoing, writer = IO.pipe
  outgoing.read_timeout = 2.seconds
  transport = ACP::StdioTransport.new(reader, writer)
  yield transport, feed, outgoing
ensure
  transport.try(&.close)
  feed.try(&.close)
  outgoing.try(&.close)
end

private def initialize_wide_v2(client : ACP::V2::Client, feed : IO, outgoing : IO)
  spawn do
    request = JSON.parse(outgoing.gets.not_nil!)
    feed.puts %({"jsonrpc":"2.0","id":#{request["id"].to_json},"result":{"protocolVersion":2,"info":{"name":"agent","version":"1"}}})
  end
  client.initialize_connection
end

private def await_wide_update(updates : Channel(Nil))
  select
  when updates.receive
  when timeout(2.seconds)
    fail "the wide state update was dropped"
  end
end

# ACP v1 optional methods and content depend on the Agent's initialization
# response. The typed client used to send requests even without those grants.
private def with_v1_validation_client(capabilities : String = "{}", &)
  transport = SignalingTransport.new
  client = ACP::Client.new(transport)
  client.request_timeout = 2.0
  client.prompt_timeout = 2.0
  spawn do
    request = next_answer(transport)
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{request["id"]},"result":{"protocolVersion":1,"agentCapabilities":#{capabilities}}}))
  end
  client.initialize_connection
  yield client, transport
ensure
  client.try(&.close)
end

describe "ACP v1 outgoing requests" do
  it "keeps capability-gated session operations off the wire when the Agent omitted support" do
    with_v1_validation_client do |client, transport|
      expect_raises(ACP::InvalidStateError, /loadSession/) { client.session_load("old", "/work") }
      expect_raises(ACP::InvalidStateError, /sessionCapabilities.resume/) { client.session_resume("old", "/work") }
      expect_raises(ACP::InvalidStateError, /sessionCapabilities.list/) { client.session_list }
      expect_raises(ACP::InvalidStateError, /sessionCapabilities.close/) { client.session_close("old") }
      expect_raises(ACP::InvalidStateError, /sessionCapabilities.delete/) { client.session_delete("old") }
      expect_raises(ACP::InvalidStateError, /additionalDirectories/) do
        client.session_new("/work", additional_directories: [] of String)
      end
      expect_raises(ACP::InvalidStateError, /systemPrompt/) do
        client.session_new("/work", system_prompt: ACP::Protocol::SystemPrompt.append("Keep it short"))
      end
      http = JSON.parse(%({"type":"http","name":"catalog","url":"https://example.test/mcp","headers":[]}))
      sse = JSON.parse(%({"type":"sse","name":"events","url":"https://example.test/sse","headers":[]}))
      expect_raises(ACP::InvalidStateError, /MCP HTTP/) { client.session_new("/work", [http]) }
      expect_raises(ACP::InvalidStateError, /MCP SSE/) { client.session_new("/work", [sse]) }
      transport.sent_messages.size.should eq(1)
    end
  end

  it "checks absolute Agent paths and system prompt modes on setup" do
    caps = %({"loadSession":true,"sessionCapabilities":{"list":{},"resume":{},"additionalDirectories":{},"systemPrompt":{"mode":{"_concise":{},"_invalid":false}}},"mcpCapabilities":{"http":true,"sse":true}})
    with_v1_validation_client(caps) do |client, transport|
      expect_raises(ArgumentError, /directories must be absolute/) { client.session_new("C:project") }
      expect_raises(ArgumentError, /directories must be absolute/) do
        client.session_load("old", "/work", additional_directories: ["relative"])
      end
      expect_raises(ArgumentError, /directories must be absolute/) { client.session_resume("old", "relative") }
      expect_raises(ArgumentError, /list directory must be absolute/) { client.session_list(cwd: "relative") }
      expect_raises(ArgumentError, /directories must be absolute/) { client.session_new("/work\0invalid") }

      expect_raises(ACP::InvalidStateError, /systemPrompt.*override/) do
        client.session_new("/work", system_prompt: ACP::Protocol::SystemPrompt.override("Override"))
      end
      empty = ACP::Protocol::SystemPrompt.new("append", [] of ACP::Protocol::ContentBlock)
      expect_raises(ArgumentError, /system prompts require/) { client.session_new("/work", system_prompt: empty) }
      image = ACP::PromptBuilder.new.image("YQ==").build
      expect_raises(ArgumentError, /system prompts require/) do
        client.session_new("/work", system_prompt: ACP::Protocol::SystemPrompt.new("append", image))
      end
      %w(_invalid _undeclared).each do |mode|
        prompt = ACP::Protocol::SystemPrompt.new(mode, ACP::PromptBuilder.new.text("Be concise").build)
        expect_raises(ACP::InvalidStateError, /systemPrompt/) { client.session_resume("old", "/work", system_prompt: prompt) }
      end

      relative = JSON.parse(%({"name":"local","command":"relative-server","args":[],"env":[]}))
      malformed_type = JSON.parse(%({"type":false,"name":"local","command":"/bin/true","args":[],"env":[]}))
      expect_raises(ArgumentError, /transport type must be a string/) { client.session_new("/work", [malformed_type]) }
      invalid_url = JSON.parse(%({"type":"sse","name":"events","url":"/sse","headers":[]}))
      expect_raises(ArgumentError, /stdio commands must be absolute/) { client.session_new("/work", [relative]) }
      expect_raises(ArgumentError, /absolute HTTP\(S\) URL/) { client.session_new("/work", [invalid_url]) }
      [
        "https://example.test/invalid path",
        "https://exa%00mple.test/mcp",
        "https://exa%20mple.test/mcp",
        "https://example.test:65536/mcp",
        "https://example.test:9999999999999999999999999/mcp",
      ].each do |url|
        invalid = ACP::Protocol::McpServerHttp.new("catalog", url)
        expect_raises(ArgumentError, /absolute HTTP\(S\) URL/) do
          client.session_new("/work", [JSON.parse(invalid.to_json)])
        end
      end
      malformed = [
        %({"command":"/bin/true","args":[],"env":[]}),
        %({"name":"local","command":"/bin/true","args":[0],"env":[]}),
        %({"name":"local","command":"/bin/true","args":[],"env":["bad"]}),
        %({"type":"http","name":"remote","url":"https://example.test/mcp","headers":[{"name":"Accept","value":true}]}),
        %({"type":"http","name":"remote","url":"https://example.test/mcp"}),
      ]
      malformed.each do |server|
        expect_raises(ArgumentError) { client.session_new("/work", [JSON.parse(server)]) }
      end
      transport.sent_messages.size.should eq(1)

      stdio = JSON.parse(%({"name":"local","command":"C:/tools/server.exe","args":[],"env":[]}))
      http = JSON.parse(%({"type":"http","name":"catalog","url":"https://example.test/mcp","headers":[],"_meta":{"fixture":true}}))
      legacy_stdio = JSON.parse(%({"name":"nullable","command":"C:/tools/nullable.exe","args":null,"env":null}))
      future = JSON.parse(%({"type":"_extension","name":"future","_meta":{"opaque":true}}))
      prompt = ACP::Protocol::SystemPrompt.new("_concise", ACP::PromptBuilder.new.text("Be concise").build)
      spawn do
        request = next_answer(transport)
        transport.inject_raw(%({"jsonrpc":"2.0","id":#{request["id"]},"result":{"sessionId":"new"}}))
      end
      client.session_new("C:/work", [stdio, http, legacy_stdio, future], additional_directories: ["D:/docs"], system_prompt: prompt).session_id.should eq("new")
      wire = transport.sent_messages.last["params"]
      wire["additionalDirectories"].should eq(JSON.parse(%(["D:/docs"])))
      wire["systemPrompt"]["mode"].should eq("_concise")
      wire["mcpServers"].as_a.should eq([stdio, http, legacy_stdio, future])
    end
  end

  it "enforces negotiated prompt content types through the regular prompt API" do
    caps = %({"promptCapabilities":{"image":true,"audio":"yes","embeddedContext":false}})
    with_v1_validation_client(caps) do |client, transport|
      expect_raises(ACP::InvalidStateError, /audio prompts/) do
        client.session_prompt(ACP::PromptBuilder.new.audio("YQ==").build, "s")
      end
      expect_raises(ACP::InvalidStateError, /embedded context/) do
        client.session_prompt(ACP::PromptBuilder.new.resource("file:///work/source.cr", "source").build, "s")
      end
      transport.sent_messages.size.should eq(1)

      spawn do
        setup = next_answer(transport)
        transport.inject_raw(%({"jsonrpc":"2.0","id":#{setup["id"]},"result":{"sessionId":"s"}}))
        prompt = next_answer(transport)
        transport.inject_raw(%({"jsonrpc":"2.0","id":#{prompt["id"]},"result":{"stopReason":"end_turn"}}))
      end
      session = ACP::Session.create(client, "/work")
      blocks = ACP::PromptBuilder.new.text("Question").image("YQ==").resource_link("file:///work/source.cr", "Source").build
      session.prompt(blocks).stop_reason.should eq("end_turn")
      transport.sent_messages.last["params"]["prompt"].as_a.map(&.["type"].as_s).should eq(["text", "image", "resource_link"])
    end
  end

  it "defaults malformed optional fields in the initialize response" do
    response = ACP::Protocol::InitializeResult.from_json(%({"protocolVersion":1,"agentCapabilities":[],"authMethods":false,"agentInfo":["bad"],"_meta":false}))
    response.protocol_version.should eq(1_u16)
    response.agent_capabilities.load_session?.should be_false
    response.auth_methods.should be_nil
    response.agent_info.should be_nil
    response.meta.should be_nil
  end

  it "retains valid capabilities next to invalid optional fields" do
    caps = %({"loadSession":{},"auth":false,"mcpCapabilities":{"http":[]},"sessionCapabilities":{"list":{"_meta":false},"resume":false,"additionalDirectories":[],"systemPrompt":{"mode":{"override":[]}}}})
    with_v1_validation_client(caps) do |client, transport|
      expect_raises(ACP::InvalidStateError, /loadSession/) { client.session_load("old", "/work") }
      expect_raises(ACP::InvalidStateError, /sessionCapabilities.resume/) { client.session_resume("old", "/work") }
      expect_raises(ACP::InvalidStateError, /systemPrompt.*override/) do
        client.session_new("/work", system_prompt: ACP::Protocol::SystemPrompt.override("Replace"))
      end
      spawn do
        request = next_answer(transport)
        transport.inject_raw(%({"jsonrpc":"2.0","id":#{request["id"]},"result":{"sessions":[]}}))
      end
      client.session_list.sessions.should be_empty
      transport.sent_messages.last["method"].should eq("session/list")
    end
  end

  it "preserves wide advertised modes and serializes native ACP MCP server declarations" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::Client.new(transport)
      client.request_timeout = 2.0
      declaration = client.register_mcp_server("local") { |_request| ACP::Protocol::MessageMcpResponse.success(JSON::Any.new(nil)) }
      spawn do
        request = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{request["id"]},"result":{"protocolVersion":1,"agentCapabilities":{"mcpCapabilities":{"acp":true},"sessionCapabilities":{"systemPrompt":{"mode":{"_future":{"counter":18446744073709551615}}}}}}})
        setup = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{setup["id"]},"result":{"sessionId":"new"}})
      end
      result = client.initialize_connection
      modes = result.agent_capabilities.not_nil!.session_capabilities.not_nil!.system_prompt.not_nil!
      modes.supports_mode?("_future").should be_true
      modes.mode.not_nil!.raw_field("_future").should eq(%({"counter":18446744073709551615}))

      prompt = ACP::Protocol::SystemPrompt.new("_future", ACP::PromptBuilder.new.text("Read source").build)
      servers = [declaration] of ACP::Protocol::McpServer
      params = ACP::Protocol::SessionNewParams.new("/work", servers, system_prompt: prompt)
      params.mcp_servers.should eq([declaration.to_json_any])
      client.session_new("/work", params.mcp_servers, system_prompt: prompt).session_id.should eq("new")
    ensure
      client.try(&.close)
    end
  end
end

# The Agent's configuration snapshots are per session and replace the prior
# list at the receive boundary, even without an application update handler.
private class ChoiceStateTransport < SignalingTransport
  getter replies = {} of String => String
  property before_reply : (String, Hash(String, JSON::Any) -> Nil)?
  property after_reply : (String, Hash(String, JSON::Any) -> Nil)?

  def send(message : Hash(String, JSON::Any)) : Nil
    super
    if (method = message["method"]?.try(&.as_s?)) && (id = message["id"]?) && (reply = @replies[method]?)
      @before_reply.try(&.call(method, message))
      inject_raw(%({"jsonrpc":"2.0","id":#{id},#{reply}}))
      @after_reply.try(&.call(method, message))
    end
  end

  def update(session_id : String, update : String) : Nil
    inject_raw(%({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":#{session_id.to_json},"update":#{update}}}))
  end
end

private class QueuedChoiceStateTransport < ChoiceStateTransport
  getter queued = Channel(Int64).new(1)
  getter write = Channel(Nil).new(1)

  def send_checked(message : Hash(String, JSON::Any), &preflight : -> Nil) : Nil
    if message["method"]?.try(&.as_s?) == "session/set_config_option"
      @queued.send(message["id"].as_i64)
      @write.receive
    end
    super(message, &preflight)
  end
end

private def choice_state_barrier(client : ACP::Client | ACP::V2::Client, transport : ChoiceStateTransport) : Nil
  transport.replies["_barrier"] = %("result":{})
  client.ext_method("barrier")
end

private def choice_state_option(key : String, value : String, alternatives : Array(String)) : String
  options = alternatives.map { |name| {"value" => name, "name" => name} }.to_json
  %({#{key.to_json}:"model","name":"Model","type":"select","currentValue":#{value.to_json},"options":#{options}})
end

describe "ACP session choice state" do
  it "keeps v1 choices per session and applies Agent updates without a typed callback" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1})
    original = choice_state_option("id", "fast", ["fast", "large"])
    modes = %({"currentModeId":"ask","availableModes":[{"id":"ask","name":"Ask"},{"id":"code","name":"Code"}]})
    transport.replies["session/new"] = %("result":{"sessionId":"one","modes":#{modes},"configOptions":[#{original}]})
    client = ACP::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    one = ACP::Session.create(client, "/work/one")
    transport.replies["session/new"] = %("result":{"sessionId":"two","configOptions":[#{choice_state_option("id", "quiet", ["quiet"])}]})
    two = ACP::Session.create(client, "/work/two")

    transport.replies["session/set_mode"] = %("result":{})
    one.mode = "code"
    one.modes.not_nil!.current_mode_id.should eq("code")
    transport.before_reply = ->(method : String, _message : Hash(String, JSON::Any)) do
      if method == "session/set_mode"
        transport.update("one", %({"sessionUpdate":"current_mode_update","currentModeId":"code"}))
      end
      nil
    end
    one.mode = "ask"
    one.modes.not_nil!.current_mode_id.should eq("code")
    expect_raises(ACP::InvalidStateError, /session mode/) { one.mode = "unadvertised" }

    grouped = %({"id":"model","name":"Model","type":"select","currentValue":"cheap","options":[{"group":"test","name":"Test","options":[{"value":"cheap","name":"Cheap"},{"value":"deep","name":"Deep"}]}]})
    transport.update("one", %({"sessionUpdate":"config_option_update","configOptions":[#{grouped}]}))
    choice_state_barrier(client, transport)
    one.config_options.not_nil!.first.current_value.should eq("cheap")
    two.config_options.not_nil!.first.current_value.should eq("quiet")
    client.session_config_options.not_nil!.first.current_value.should eq("quiet")
    expect_raises(ArgumentError, /advertised value ID/) { one.set_config_option("model", "fast") }

    transport.replies["session/set_config_option"] = %("result":{"configOptions":[#{choice_state_option("id", "deep", ["deep"])}]})
    one.set_config_option("model", "deep")
    one.config_options.not_nil!.first.current_value.should eq("deep")
    client.session_config_options.not_nil!.first.current_value.should eq("quiet")
  ensure
    client.try(&.close)
  end

  it "keeps replayed v1 choices out of live state until a successful attachment" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true}})
    initial = choice_state_option("id", "live", ["live"])
    transport.replies["session/new"] = %("result":{"sessionId":"s","configOptions":[#{initial}]})
    client = ACP::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    session = ACP::Session.create(client, "/work")
    snapshots = Channel(Tuple(Bool, String?)).new(2)
    client.on_update = ->(params : ACP::Protocol::SessionUpdateParams) do
      current = client.session_config_options("s").try(&.first?).try(&.current_value)
      snapshots.send({params.before_load_response?, current})
    end
    transport.before_reply = ->(method : String, _message : Hash(String, JSON::Any)) do
      if method == "session/load"
        transport.update("s", %({"sessionUpdate":"config_option_update","configOptions":[#{choice_state_option("id", "history", ["history"])}]}))
      end
      nil
    end
    transport.replies["session/load"] = %("error":{"code":-32603,"message":"Replay failed"})
    expect_raises(ACP::JsonRpcError, /Replay failed/) { client.session_load("s", "/work") }
    snapshots.receive.should eq({true, "live"})
    session.config_options.not_nil!.first.current_value.should eq("live")

    transport.replies["session/load"] = %("result":{"configOptions":[#{choice_state_option("id", "restored", ["restored"])}]})
    client.session_load("s", "/work")
    snapshots.receive.should eq({true, "live"})
    session.config_options.not_nil!.first.current_value.should eq("restored")
  ensure
    client.try(&.close)
  end

  it "applies v2 replies and notifications as complete replacements in receive order" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
    original = choice_state_option("configId", "fast", ["fast", "large"])
    transport.replies["session/new"] = %("result":{"sessionId":"s","configOptions":[#{original}]})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")
    expect_raises(ACP::InvalidStateError, /offer/) do
      client.session_set_config_option(ACP::Protocol::V2::SessionSetConfigOptionParams.new("s", "unknown", "large"))
    end
    expect_raises(ArgumentError, /advertised value ID/) do
      client.session_set_config_option(ACP::Protocol::V2::SessionSetConfigOptionParams.new("s", "model", "other"))
    end

    updated = choice_state_option("configId", "large", ["large"])
    transport.replies["session/set_config_option"] = %("result":{"configOptions":[#{updated}]})
    transport.after_reply = ->(method : String, _message : Hash(String, JSON::Any)) do
      if method == "session/set_config_option"
        transport.update("s", %({"sessionUpdate":"config_option_update","configOptions":[#{choice_state_option("configId", "latest", ["latest"])}]}))
      end
      nil
    end
    result = client.session_set_config_option(ACP::Protocol::V2::SessionSetConfigOptionParams.new("s", "model", "large"))
    result.typed_config_options.first.selected_value.should eq("large")
    choice_state_barrier(client, transport)
    client.session_config_options("s").not_nil!.first.selected_value.should eq("latest")

    transport.replies["session/resume"] = %("result":{})
    client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("s", "/work"))
    expect_raises(ACP::InvalidStateError, /offer/) do
      client.session_set_config_option(ACP::Protocol::V2::SessionSetConfigOptionParams.new("s", "model", "latest"))
    end
  ensure
    client.try(&.close)
  end

  it "applies a late typed setter response and observes raw v1 changes" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1})
    original = choice_state_option("id", "fast", ["fast", "large"])
    transport.replies["session/new"] = %("result":{"sessionId":"s","configOptions":[#{original}]})
    client = ACP::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")

    client.request_timeout = 0.01
    expect_raises(ACP::RequestTimeoutError) { client.session_set_config_option("model", "large") }
    next_answer(transport)["method"].as_s.should eq("initialize")
    next_answer(transport)["method"].as_s.should eq("session/new")
    request = next_answer(transport)
    request["method"].as_s.should eq("session/set_config_option")
    late = choice_state_option("id", "latest", ["latest"])
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{request["id"]},"result":{"configOptions":[#{late}]}}))
    client.request_timeout = 2.0
    choice_state_barrier(client, transport)
    client.session_config_options.not_nil!.first.current_value.should eq("latest")

    transport.replies["session/set_config_option"] = %("result":{"configOptions":[]})
    client.send_request("session/set_config_option", ACP::Protocol::SessionSetConfigOptionParams.new("s", "model", "latest"))
    client.session_config_options.should eq([] of ACP::Protocol::ConfigOption)
  ensure
    client.try(&.close)
  end

  it "keeps the newer v1 mode choice when acknowledgements arrive out of order" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1})
    modes = %({"currentModeId":"ask","availableModes":[{"id":"ask","name":"Ask"},{"id":"code","name":"Code"},{"id":"plan","name":"Plan"}]})
    transport.replies["session/new"] = %("result":{"sessionId":"s","modes":#{modes}})
    client = ACP::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")
    next_answer(transport)
    next_answer(transport)

    done = Channel(Exception?).new(2)
    spawn do
      client.session_set_mode("code")
      done.send(nil)
    rescue ex
      done.send(ex)
    end
    older = next_answer(transport)
    spawn do
      client.session_set_mode("plan")
      done.send(nil)
    rescue ex
      done.send(ex)
    end
    newer = next_answer(transport)
    newer["params"]["modeId"].as_s.should eq("plan")
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{newer["id"]},"result":{"_meta":false}}))
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{older["id"]},"result":{}}))
    2.times do
      select
      when error = done.receive
        error.should be_nil
      when timeout(2.seconds)
        fail "mode setter did not finish"
      end
    end
    client.session_modes.not_nil!.current_mode_id.should eq("plan")
  ensure
    client.try(&.close)
  end

  it "keeps post-replay config updates when a v2 resume fails" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
    original = choice_state_option("configId", "fast", ["fast"])
    transport.replies["session/new"] = %("result":{"sessionId":"s","configOptions":[#{original}]})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")

    observed = [] of String?
    client.on_update = ->(params : ACP::Protocol::V2::SessionUpdateParams) do
      if params.update.session_update == "config_option_update"
        observed << client.session_config_options("s").try(&.first?.try(&.selected_value))
      end
      nil
    end
    transport.before_reply = ->(method : String, _message : Hash(String, JSON::Any)) do
      if method == "session/resume"
        transport.update("s", %({"sessionUpdate":"config_option_update","configOptions":[#{choice_state_option("configId", "old", ["old"])}]}))
        transport.update("s", %({"sessionUpdate":"replay_complete"}))
        transport.update("s", %({"sessionUpdate":"config_option_update","configOptions":[#{choice_state_option("configId", "live", ["live"])}]}))
      end
      nil
    end
    transport.replies["session/resume"] = %("error":{"code":-32603,"message":"resume failed"})
    params = ACP::Protocol::V2::SessionResumeParams.new("s", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start)
    expect_raises(ACP::JsonRpcError, /resume failed/) { client.session_resume(params) }
    observed.should eq(["fast", "live"])
    client.session_config_options("s").not_nil!.first.selected_value.should eq("live")

    transport.replies["session/resume"] = %("result":{"configOptions":[#{choice_state_option("configId", "resumed", ["resumed"])}]})
    client.session_resume(params)
    client.session_config_options("s").not_nil!.first.selected_value.should eq("resumed")
  ensure
    client.try(&.close)
  end

  it "applies a v2 setter reply after resuming the same active session" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
    original = choice_state_option("configId", "fast", ["fast", "large"])
    transport.replies["session/new"] = %("result":{"sessionId":"s","configOptions":[#{original}]})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")
    next_answer(transport)
    next_answer(transport)

    completed = Channel(Exception?).new(1)
    spawn do
      client.session_set_config_option(ACP::Protocol::V2::SessionSetConfigOptionParams.new("s", "model", "large"))
      completed.send(nil)
    rescue ex
      completed.send(ex)
    end
    original_request = next_answer(transport)
    original_request["method"].as_s.should eq("session/set_config_option")
    transport.replies["session/resume"] = %("result":{"configOptions":[#{original}]})
    client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("s", "/work"))
    latest = choice_state_option("configId", "large", ["large"])
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{original_request["id"]},"result":{"configOptions":[#{latest}]}}))
    select
    when error = completed.receive
      error.should be_nil
    when timeout(2.seconds)
      fail "setter did not finish"
    end
    client.session_config_options("s").not_nil!.first.selected_value.should eq("large")
  ensure
    client.try(&.close)
  end

  it "keeps a newer v2 attachment after an earlier setter reply" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
    original = choice_state_option("configId", "fast", ["fast", "large"])
    transport.replies["session/new"] = %("result":{"sessionId":"s","configOptions":[#{original}]})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")

    transport.replies["_barrier"] = %("result":{})
    completed = Channel(Exception?).new(1)
    spawn do
      client.session_set_config_option(ACP::Protocol::V2::SessionSetConfigOptionParams.new("s", "model", "large"))
      completed.send(nil)
    rescue ex
      completed.send(ex)
    end
    next_answer(transport)["method"].as_s.should eq("initialize")
    next_answer(transport)["method"].as_s.should eq("session/new")
    original_request = next_answer(transport)
    original_request["method"].as_s.should eq("session/set_config_option")
    transport.replies["session/close"] = %("result":{})
    client.session_close("s")
    client.session_config_options("s").should be_nil
    attached = choice_state_option("configId", "resumed", ["resumed"])
    transport.replies["session/resume"] = %("result":{"configOptions":[#{attached}]})
    client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("s", "/work"))
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{original_request["id"]},"result":{"configOptions":[#{original}]}}))
    select
    when error = completed.receive
      error.should be_nil
    when timeout(2.seconds)
      fail "setter did not finish"
    end
    client.session_config_options("s").not_nil!.first.selected_value.should eq("resumed")
  ensure
    client.try(&.close)
  end

  it "rechecks v2 config choices when the transport reaches a queued request" do
    transport = QueuedChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s","configOptions":[#{choice_state_option("configId", "fast", ["fast", "large"])}]})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")

    failure = Channel(Exception?).new(1)
    spawn do
      client.session_set_config_option(ACP::Protocol::V2::SessionSetConfigOptionParams.new("s", "model", "large"))
      failure.send(nil)
    rescue ex
      failure.send(ex)
    end
    queued_id = select
    when id = transport.queued.receive
      id
    when timeout(2.seconds)
      fail "setter did not reach the send queue"
    end
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{queued_id},"result":{"configOptions":[]}}))
    transport.update("s", %({"sessionUpdate":"config_option_update","configOptions":[#{choice_state_option("configId", "fast", ["fast"])}]}))
    choice_state_barrier(client, transport)
    transport.write.send(nil)
    select
    when error = failure.receive
      error.should be_a(ArgumentError)
    when timeout(2.seconds)
      fail "setter did not finish"
    end
    transport.sent_messages.any? { |message| message["method"]?.try(&.as_s?) == "session/set_config_option" }.should be_false
  ensure
    transport.try(&.write.close)
    client.try(&.close)
  end

  it "keeps representable configuration responses available to raw stdio consumers" do
    with_wide_stdio do |transport, feed, _outgoing|
      feed.puts %({"jsonrpc":"2.0","id":1,"result":{"configOptions":[]}})
      transport.receive(2.seconds).not_nil!["result"]["configOptions"].as_a.should be_empty
    end
  end

  it "delivers exact but representable config notifications to raw callbacks" do
    {false, true}.each do |v2|
      with_wide_stdio do |transport, feed, outgoing|
        client = v2 ? ACP::V2::Client.new(transport) : ACP::Client.new(transport)
        client.request_timeout = 2.0
        observed = Channel(JSON::Any).new(1)
        client.on_notification = ->(method : String, params : JSON::Any?) do
          observed.send(params) if params && method == "session/update"
          nil
        end
        spawn do
          init = JSON.parse(outgoing.gets.not_nil!)
          version = v2 ? 2 : 1
          feed.puts %({"jsonrpc":"2.0","id":#{init["id"]},"result":{"protocolVersion":#{version},"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}}})
          setup = JSON.parse(outgoing.gets.not_nil!)
          feed.puts %({"jsonrpc":"2.0","id":#{setup["id"]},"result":{"sessionId":"s"}})
          feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"config_option_update","configOptions":[]}}})
        end
        client.initialize_connection
        client.session_new("/work")
        select
        when params = observed.receive
          params["update"]["configOptions"].as_a.should be_empty
        when timeout(2.seconds)
          fail "configuration update did not reach the legacy callback"
        end
      ensure
        client.try(&.close)
      end
    end
  end

  it "preserves exact v2 extension options next to a normal selector over stdio" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      select_option = %({"configId":"model","name":"Model","type":"select","currentValue":"fast","options":[{"value":"fast","name":"Fast","_meta":{"counter":18446744073709551615}},{"value":"large","name":"Large"}]})
      extension = %({"configId":"custom","name":"Custom","type":"_future","currentValue":{"wide":18446744073709551615}})
      exact_fraction = %({"configId":"custom","name":"Custom","type":"_future","currentValue":0.12345678901234567891})
      spawn do
        init = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{init["id"]},"result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}}})
        setup = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{setup["id"]},"result":{"sessionId":"s","configOptions":[#{exact_fraction}]}})
        snapshot = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{snapshot["id"]},"result":{"configOptions":[#{extension},#{select_option}]}})
        set = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{set["id"]},"result":{"configOptions":[#{extension},#{select_option}]}})
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"config_option_update","configOptions":[#{extension}]}}})
        barrier = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{barrier["id"]},"result":{}})
      end
      client.initialize_connection
      client.session_new("/work")
      client.session_config_options_raw("s").not_nil!.json.should eq("[#{exact_fraction}]")
      client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("s", "/work"))
      options = client.session_config_options("s").not_nil!
      options.map(&.config_id).should eq(["custom", "model"])
      options.last.select_options.as(Array(ACP::Protocol::ConfigOptionValue)).map(&.value).should eq(["fast", "large"])
      client.session_config_options_raw("s").not_nil!.json.should contain("18446744073709551615")
      client.session_set_config_option(ACP::Protocol::V2::SessionSetConfigOptionParams.new("s", "model", "large"))
      client.ext_method("barrier")
      exact = client.session_config_options_raw("s").not_nil!
      exact.elements?.not_nil!.size.should eq(1)
      exact.json.should eq("[#{extension}]")
      client.session_config_options("s").not_nil!.first.raw_field("currentValue").should eq(%({"wide":18446744073709551615}))
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP v2 command snapshot retirement" do
  it "retires workspace and commands on wide success metadata and a missing session error" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      spawn do
        init = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{init["id"]},"result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"delete":{}}}}})
        setup = JSON.parse(outgoing.gets.not_nil!)
        commands = %([{"type":"command","name":"status","description":"Status"}])
        feed.puts %({"jsonrpc":"2.0","id":#{setup["id"]},"result":{"sessionId":"s","availableCommands":#{commands}}})
        close = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{close["id"]},"result":{"_meta":{"wide":18446744073709551615}}})
        resume = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"state_update","state":"idle"}}})
        feed.puts %({"jsonrpc":"2.0","id":#{resume["id"]},"result":{"availableCommands":#{commands}}})
        remove = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{remove["id"]},"error":{"code":-32002,"message":"Missing","data":{"sessionId":"s","extension":18446744073709551615}}})
      end
      client.initialize_connection
      client.session_new("/work")
      client.session_close("s").meta.should be_nil
      client.session_available_commands("s").should be_nil
      client.session_workspace("s").should be_nil

      client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("s", "/work"))
      client.session_available_commands("s").not_nil!.first.name.should eq("status")
      client.session_delete("s").meta.should be_nil
      client.session_available_commands_raw("s").should be_nil
      client.session_workspace("s").should be_nil
    ensure
      client.try(&.close)
    end
  end

  it "invalidates commands on a timed-out close and retires state on the late reply" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s","availableCommands":[{"type":"command","name":"status","description":"Status"}]})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")
    client.session_available_commands("s").not_nil!.first.name.should eq("status")

    client.request_timeout = 0.01
    expect_raises(ACP::RequestTimeoutError) { client.session_close("s") }
    client.session_available_commands("s").should be_nil
    next_answer(transport)["method"].as_s.should eq("initialize")
    next_answer(transport)["method"].as_s.should eq("session/new")
    close = next_answer(transport)
    close["method"].as_s.should eq("session/close")
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{close["id"]},"result":{}}))
    client.request_timeout = 2.0
    choice_state_barrier(client, transport)
    client.session_workspace("s").should be_nil
    client.session_available_commands_raw("s").should be_nil
  ensure
    client.try(&.close)
  end

  it "publishes staged live commands after a late retirement failure" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s","availableCommands":[{"type":"command","name":"old","description":"Old"}]})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")
    next_answer(transport)
    next_answer(transport)

    client.request_timeout = 0.01
    expect_raises(ACP::RequestTimeoutError) { client.session_close("s") }
    close = next_answer(transport)
    close["method"].as_s.should eq("session/close")
    transport.update("s", %({"sessionUpdate":"available_commands_update","availableCommands":[{"type":"command","name":"live","description":"Live"}]}))
    client.request_timeout = 2.0
    choice_state_barrier(client, transport)
    client.session_available_commands("s").should be_nil

    transport.inject_raw(%({"jsonrpc":"2.0","id":#{close["id"]},"error":{"code":-32800,"message":"Cancelled"}}))
    choice_state_barrier(client, transport)
    client.session_available_commands("s").not_nil!.map(&.name).should eq(["live"])
    client.session_workspace("s").not_nil!.cwd.should eq("/work")

    # A malformed response proves neither failure nor successful retirement.
    client.request_timeout = 0.01
    expect_raises(ACP::RequestTimeoutError) { client.session_close("s") }
    close = transport.sent_messages.reverse.find! { |frame| frame["method"]?.try(&.as_s?) == "session/close" }
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{close["id"]},"result":{},"error":{"code":-32800}}))
    client.request_timeout = 2.0
    choice_state_barrier(client, transport)
    client.session_available_commands("s").should be_nil
  ensure
    client.try(&.close)
  end

  it "keeps a newer attachment when an earlier retirement eventually succeeds" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s","availableCommands":[{"type":"command","name":"old","description":"Old"}]})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")
    next_answer(transport)
    next_answer(transport)

    client.request_timeout = 0.01
    expect_raises(ACP::RequestTimeoutError) { client.session_close("s") }
    close = next_answer(transport)
    close["method"].as_s.should eq("session/close")
    client.request_timeout = 2.0
    transport.replies["session/resume"] = %("result":{"availableCommands":[{"type":"command","name":"new","description":"New"}]})
    client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("s", "/work"))
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{close["id"]},"result":{}}))
    choice_state_barrier(client, transport)
    client.session_workspace("s").not_nil!.cwd.should eq("/work")
    client.session_available_commands("s").not_nil!.map(&.name).should eq(["new"])
  ensure
    client.try(&.close)
  end
end

describe "Exact ACP v2 command advertisements" do
  it "keeps precise commands over stdio and still delivers ordinary raw notifications" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      slash = %({"type":"command","name":"review","description":"Review","input":{"type":"text","hint":"branch","extra":18446744073709551615}})
      extension = %({"type":"_future","name":"next","description":"Next","value":0.12345678901234567891})
      live = %({"type":"_future","name":"live","description":"Live","value":0.12345678901234567892})
      delivered = Channel(JSON::Any).new(1)
      client.on_notification = ->(method : String, params : JSON::Any?) do
        delivered.send(params) if params && method == "session/update"
        nil
      end
      spawn do
        init = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{init["id"]},"result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}}})
        setup = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{setup["id"]},"result":{"sessionId":"s","availableCommands":[#{slash},#{extension}]}})
      end
      client.initialize_connection
      setup = client.session_new("/work")
      setup.typed_available_commands.map(&.name).should eq(["review", "next"])
      setup.typed_available_commands.first.input.not_nil!.text_hint.should eq("branch")
      client.session_available_commands_raw("s").not_nil!.json.should eq("[#{slash},#{extension}]")
      input = client.session_available_commands("s").not_nil!.first.input.not_nil!
      input.raw_field("extra").should eq("18446744073709551615")
      input.text_hint.should eq("branch")

      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"available_commands_update","availableCommands":[#{live}]}}})
      select
      when params = delivered.receive
        params["update"]["availableCommands"][0]["name"].as_s.should eq("live")
      when timeout(2.seconds)
        fail "command update did not reach the generic notification handler"
      end
      client.session_available_commands_raw("s").not_nil!.json.should eq("[#{live}]")
      client.session_available_commands("s").not_nil!.map(&.name).should eq(["live"])

      feed.puts %({"jsonrpc":"2.0","method":"session/update","futureEnvelopeField":18446744073709551615,"params":{"sessionId":"s","update":{"sessionUpdate":"available_commands_update","availableCommands":[#{extension}]}}})
      select
      when params = delivered.receive
        params["update"]["availableCommands"][0]["name"].as_s.should eq("next")
      when timeout(2.seconds)
        fail "representable params did not reach the generic notification handler"
      end
      client.session_available_commands_raw("s").not_nil!.json.should eq("[#{extension}]")
    ensure
      client.try(&.close)
    end
  end
end

describe "Exact ACP v2 foreground state" do
  it "retires the root on a late close even if a resume timed out in the meantime" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s"})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")
    client.session_state("s").not_nil!.idle?.should be_true

    client.request_timeout = 0.01
    expect_raises(ACP::RequestTimeoutError) { client.session_close("s") }
    expect_raises(ACP::RequestTimeoutError) do
      client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("s", "/work"))
    end
    client.session_available_commands("s").should be_nil
    client.session_state("s").not_nil!.idle?.should be_true

    close = transport.sent_messages.find! { |frame| frame["method"]?.try(&.as_s?) == "session/close" }
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{close["id"]},"result":{}}))
    client.request_timeout = 2.0
    choice_state_barrier(client, transport)
    client.session_state("s").should be_nil
    client.session_workspace("s").should be_nil
  ensure
    client.try(&.close)
  end

  it "keeps usable background and error fields beside wide extension values" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      received = Channel(ACP::Protocol::V2::StateUpdate).new(1)
      client.on_update = ->(params : ACP::Protocol::V2::SessionUpdateParams) do
        if update = params.update.typed.as?(ACP::Protocol::V2::StateUpdate)
          received.send(update)
        end
        nil
      end
      spawn do
        init = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{init["id"]},"result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}}})
        setup = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{setup["id"]},"result":{"sessionId":"s"}})
      end
      client.initialize_connection
      client.session_new("/work")
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"terminal_update","terminalId":"t"}}})
      update = %({"sessionUpdate":"state_update","state":"idle","stopReason":"error","error":{"code":-32603,"message":"Failed","data":{"big":18446744073709551615}},"background":[{"type":"terminal","terminalId":"t","extension":18446744073709551615},{"type":"_future","precise":0.1234567890123456789}]})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":#{update},"_meta":{"wide":18446744073709551615}}})
      select
      when observed = received.receive
        observed.error.not_nil!.code.should eq(-32603)
        observed.background.not_nil!.map(&.entity_type).should eq(["terminal", "_future"])
      when timeout(2.seconds)
        fail "state update was not delivered"
      end
      snapshot = client.session_state("s").not_nil!
      snapshot.error.not_nil!.message.should eq("Failed")
      snapshot.background.not_nil!.first.raw_field("extension").should eq("18446744073709551615")
      exact = client.session_state_raw("s").not_nil!
      exact.field("sessionUpdate").should be_nil
      exact.field("error").not_nil!.field("data").not_nil!.field("big").not_nil!.json.should eq("18446744073709551615")
      exact.json.should contain("0.1234567890123456789")

      narrow = %({"sessionUpdate":"state_update","state":"running","background":[{"type":"tool_call"}],"extension":0.9876543210987654321})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":#{narrow}}})
      select
      when observed = received.receive
        observed.state.should eq("running")
        observed.background.should be_nil
      when timeout(2.seconds)
        fail "next state update was not delivered"
      end
      client.session_state_raw("s").not_nil!.json.should contain("0.9876543210987654321")
    ensure
      client.try(&.close)
    end
  end
end

private class QueuedCancellationTransport < ACP::Transport
  getter agent = ChoiceStateTransport.new
  getter queued = Channel(String).new(1)
  getter ready_to_write = Channel(Nil).new(1)
  property pause_method : String?

  def receive : JSON::Any?
    @agent.receive
  end

  def closed? : Bool
    @agent.closed?
  end

  def close : Nil
    @agent.close
  end

  def send(message : Hash(String, JSON::Any)) : Nil
    wait_to_write(message)
    @agent.send(message)
  end

  def send_checked(message : Hash(String, JSON::Any), &preflight : -> Nil) : Nil
    wait_to_write(message)
    preflight.call
    @agent.send(message)
  end

  private def wait_to_write(message : Hash(String, JSON::Any)) : Nil
    if (method = message["method"]?.try(&.as_s?)) && method == @pause_method
      @queued.send(method)
      @ready_to_write.receive
    end
  end
end

describe "ACP cancellation grants at the writer" do
  {
    {"tool_call/cancel", "child", %({"sessionUpdate":"tool_call_update","toolCallId":"t","capabilities":{"cancel":{}}}), %({"sessionUpdate":"tool_call_update","toolCallId":"t","capabilities":null})},
    {"terminal/cancel", "child", %({"sessionUpdate":"terminal_update","terminalId":"t","capabilities":{"cancel":{}}}), %({"sessionUpdate":"terminal_update","terminalId":"t","capabilities":{}})},
    {"session/cancel", "root", %({"sessionUpdate":"subagent_update","sessionId":"child","capabilities":{"cancel":{}}}), %({"sessionUpdate":"subagent_update","sessionId":"child","capabilities":{"cancel":null}})},
  }.each do |method, owner, grant, revoke|
    it "withholds #{method} when the Agent revokes it before the write" do
      transport = QueuedCancellationTransport.new
      transport.agent.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
      transport.agent.replies["session/new"] = %("result":{"sessionId":"root"})
      transport.agent.replies[method] = %("result":{})
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      client.initialize_connection
      client.session_new("/work")
      transport.agent.update("root", %({"sessionUpdate":"subagent_update","sessionId":"child"}))
      transport.agent.update(owner, grant)
      choice_state_barrier(client, transport.agent)

      transport.pause_method = method
      result = Channel(Exception?).new(1)
      spawn do
        case method
        when "tool_call/cancel" then client.tool_call_cancel("child", "t")
        when "terminal/cancel"  then client.terminal_cancel("child", "t")
        when "session/cancel"   then client.session_cancel("child")
        end
        result.send(nil)
      rescue ex
        result.send(ex)
      end
      select
      when queued = transport.queued.receive
        queued.should eq(method)
      when timeout(2.seconds)
        fail "cancellation did not reach the write queue"
      end

      transport.agent.update(owner, revoke)
      choice_state_barrier(client, transport.agent)
      transport.ready_to_write.send(nil)
      select
      when error = result.receive
        if error.nil? && transport.agent.sent_messages.any? { |frame| frame["method"]?.try(&.as_s?) == method }
          fail "#{method} crossed the writer after its revocation was processed"
        end
        error.should be_a(ACP::InvalidStateError)
      when timeout(2.seconds)
        fail "queued cancellation did not finish"
      end
      transport.agent.sent_messages.none? { |frame| frame["method"]?.try(&.as_s?) == method }.should be_true
    ensure
      transport.try(&.ready_to_write.close)
      client.try(&.close)
    end
  end
end

describe "ACP v2 cancellation grants during session synchronization" do
  it "preserves current root grants across a resume without replay" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/new"] = %("result":{"sessionId":"root"})
    transport.replies["session/resume"] = %("result":{})
    transport.replies["tool_call/cancel"] = %("result":{})
    transport.replies["terminal/cancel"] = %("result":{})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")
    transport.update("root", %({"sessionUpdate":"tool_call_update","toolCallId":"x","capabilities":{"cancel":{}}}))
    transport.update("root", %({"sessionUpdate":"terminal_update","terminalId":"x","capabilities":{}}))
    choice_state_barrier(client, transport)

    transport.before_reply = ->(method : String, _message : Hash(String, JSON::Any)) do
      if method == "session/resume"
        transport.update("root", %({"sessionUpdate":"tool_call_update","toolCallId":"x","status":"in_progress"}))
        transport.update("root", %({"sessionUpdate":"state_update","state":"running"}))
      end
      nil
    end
    client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("root", "/work"))
    client.tool_call_cancel("root", "x")
    expect_raises(ACP::InvalidStateError, /current cancel capability/) { client.terminal_cancel("root", "x") }
  ensure
    client.try(&.close)
  end

  it "keeps historical cancel grants inert after a local replay timeout" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/new"] = %("result":{"sessionId":"root"})
    transport.replies["tool_call/cancel"] = %("result":{})
    transport.replies["terminal/cancel"] = %("result":{})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")

    client.request_timeout = 0.01
    expect_raises(ACP::RequestTimeoutError) do
      params = ACP::Protocol::V2::SessionResumeParams.new("root", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start)
      client.session_resume(params)
    end
    transport.update("root", %({"sessionUpdate":"subagent_update","sessionId":"child","capabilities":{"cancel":{}}}))
    transport.update("root", %({"sessionUpdate":"terminal_update","terminalId":"term","capabilities":{"cancel":{}}}))
    transport.update("child", %({"sessionUpdate":"tool_call_update","toolCallId":"x","capabilities":{"cancel":{}}}))
    client.request_timeout = 2.0
    choice_state_barrier(client, transport)
    expect_raises(ACP::InvalidStateError) { client.session_cancel("child") }
    expect_raises(ACP::InvalidStateError) { client.terminal_cancel("root", "term") }
    expect_raises(ACP::InvalidStateError) { client.tool_call_cancel("child", "x") }

    transport.update("root", %({"sessionUpdate":"replay_complete"}))
    transport.update("root", %({"sessionUpdate":"subagent_update","sessionId":"child","capabilities":{"cancel":{}}}))
    transport.update("root", %({"sessionUpdate":"terminal_update","terminalId":"term","capabilities":{"cancel":{}}}))
    transport.update("child", %({"sessionUpdate":"replay_complete"}))
    transport.update("child", %({"sessionUpdate":"tool_call_update","toolCallId":"x","capabilities":{"cancel":{}}}))
    choice_state_barrier(client, transport)
    expect_raises(ACP::InvalidStateError) { client.session_cancel("child") }
    expect_raises(ACP::InvalidStateError) { client.tool_call_cancel("child", "x") }
    expect_raises(ACP::InvalidStateError) { client.terminal_cancel("root", "term") }

    resume = transport.sent_messages.find! { |frame| frame["method"]?.try(&.as_s?) == "session/resume" }
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{resume["id"]},"result":{}}))
    choice_state_barrier(client, transport)
    client.terminal_cancel("root", "term")
    client.tool_call_cancel("child", "x")
    client.session_cancel("child")
  ensure
    client.try(&.close)
  end
  it "keeps a descendant's replay isolated while a newer resume is waiting to write" do
    transport = QueuedCancellationTransport.new
    agent = transport.agent
    agent.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"mcp":{"acp":{}}}}})
    agent.replies["session/new"] = %("result":{"sessionId":"root"})
    agent.replies["terminal/cancel"] = %("result":{})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")
    client.request_timeout = 0.01
    expect_raises(ACP::RequestTimeoutError) do
      client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("root", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start))
    end
    old_resume = agent.sent_messages.find! { |frame| frame["method"]?.try(&.as_s?) == "session/resume" }
    agent.update("root", %({"sessionUpdate":"subagent_update","sessionId":"child"}))
    agent.update("root", %({"sessionUpdate":"replay_complete"}))
    client.request_timeout = 2.0
    choice_state_barrier(client, agent)

    transport.pause_method = "session/resume"
    rejected = Channel(Exception?).new(1)
    spawn do
      declaration = ACP::Protocol::McpServerAcp.new("missing", "unknown-server")
      server = ACP::Protocol::V2::McpServer.acp(declaration)
      params = ACP::Protocol::V2::SessionResumeParams.new("root", "/work", mcp_servers: [server])
      client.session_resume(params)
      rejected.send(nil)
    rescue ex
      rejected.send(ex)
    end
    select
    when queued = transport.queued.receive
      queued.should eq("session/resume")
    when timeout(2.seconds)
      fail "resume did not reach the write queue"
    end
    agent.update("child", %({"sessionUpdate":"terminal_update","terminalId":"historical","capabilities":{"cancel":{}}}))
    agent.update("child", %({"sessionUpdate":"replay_complete"}))
    agent.update("child", %({"sessionUpdate":"terminal_update","terminalId":"live","capabilities":{"cancel":{}}}))
    agent.inject_raw(%({"jsonrpc":"2.0","id":#{old_resume["id"]},"result":{}}))
    choice_state_barrier(client, agent)
    transport.ready_to_write.send(nil)
    select
    when error = rejected.receive
      error.should be_a(ACP::InvalidStateError)
    when timeout(2.seconds)
      fail "resume preflight did not finish"
    end
    expect_raises(ACP::InvalidStateError) { client.terminal_cancel("child", "historical") }
    client.terminal_cancel("child", "live")
  ensure
    transport.try(&.ready_to_write.close)
    client.try(&.close)
  end

  it "discards provisional child grants after a late resume rejection" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/new"] = %("result":{"sessionId":"root"})
    transport.replies["tool_call/cancel"] = %("result":{})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")

    client.request_timeout = 0.01
    expect_raises(ACP::RequestTimeoutError) do
      client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("root", "/work"))
    end
    transport.update("root", %({"sessionUpdate":"subagent_update","sessionId":"child","state":{"state":"running"},"capabilities":{"cancel":{}}}))
    transport.update("child", %({"sessionUpdate":"tool_call_update","toolCallId":"t","capabilities":{"cancel":{}}}))
    client.request_timeout = 2.0
    choice_state_barrier(client, transport)
    client.subagent("child").not_nil!.cancel?.should be_false
    client.subagent("child").not_nil!.state.should be_nil
    expect_raises(ACP::InvalidStateError) { client.session_cancel("child") }

    resume = transport.sent_messages.find! { |frame| frame["method"]?.try(&.as_s?) == "session/resume" }
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{resume["id"]},"error":{"code":-32800,"message":"Cancelled"}}))
    choice_state_barrier(client, transport)
    expect_raises(ACP::InvalidStateError) { client.session_cancel("child") }
    expect_raises(ACP::InvalidStateError) { client.tool_call_cancel("child", "t") }
    client.subagent("child").not_nil!.state.should be_nil
  ensure
    client.try(&.close)
  end
  {true, false}.each do |close_reply_first|
    order = close_reply_first ? "before" : "after"
    it "keeps confirmed resume grants when an earlier close replies #{order} the resume" do
      transport = ChoiceStateTransport.new
      transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
      transport.replies["session/new"] = %("result":{"sessionId":"root"})
      transport.replies["terminal/cancel"] = %("result":{})
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      client.initialize_connection
      client.session_new("/work")
      next_answer(transport)["method"].as_s.should eq("initialize")
      next_answer(transport)["method"].as_s.should eq("session/new")

      transport.update("root", %({"sessionUpdate":"terminal_update","terminalId":"old","capabilities":{"cancel":{}}}))
      choice_state_barrier(client, transport)
      next_answer(transport)["method"].as_s.should eq("_barrier")
      client.request_timeout = 0.01
      expect_raises(ACP::RequestTimeoutError) { client.session_close("root") }
      close = next_answer(transport)
      close["method"].as_s.should eq("session/close")
      next_answer(transport)["method"].as_s.should eq("$/cancel_request")

      client.request_timeout = 0.1
      outcome = Channel(Exception?).new(1)
      seen = Channel(Nil).new(1)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        seen.send(nil) if note.update.session_update == "terminal_update"
        nil
      end
      spawn do
        client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("root", "/work"))
        outcome.send(nil)
      rescue ex
        outcome.send(ex)
      end
      resume = next_answer(transport)
      resume["method"].as_s.should eq("session/resume")
      transport.update("root", %({"sessionUpdate":"state_update","state":"running"}))
      transport.update("root", %({"sessionUpdate":"subagent_update","sessionId":"child","state":{"state":"running"},"capabilities":{"cancel":{}}}))
      transport.update("child", %({"sessionUpdate":"terminal_update","terminalId":"t","capabilities":{"cancel":{}}}))
      select
      when seen.receive
      when timeout(2.seconds)
        fail "terminal advertisement did not arrive"
      end
      select
      when outcome.receive
        fail "the resume timed out before the provisional advertisement"
      else
      end
      client.subagent("child").not_nil!.cancel?.should be_false
      select
      when error = outcome.receive
        error.should be_a(ACP::RequestTimeoutError)
      when timeout(2.seconds)
        fail "resume did not time out"
      end

      commands = %([{"type":"command","name":"status","description":"Status"}])
      resumed = %({"jsonrpc":"2.0","id":#{resume["id"]},"result":{"availableCommands":#{commands}}})
      closed = %({"jsonrpc":"2.0","id":#{close["id"]},"result":{}})
      replies = close_reply_first ? [closed, resumed] : [resumed, closed]
      replies.each { |reply| transport.inject_raw(reply) }
      client.request_timeout = 2.0
      choice_state_barrier(client, transport)
      client.session_available_commands("root").not_nil!.first.name.should eq("status")
      client.session_state("root").not_nil!.state.should eq("running")
      expect_raises(ACP::InvalidStateError) { client.terminal_cancel("root", "old") }
      client.subagent("child").not_nil!.state.not_nil!.state.should eq("running")
      client.session_cancel("child")
      client.terminal_cancel("child", "t")
    ensure
      client.try(&.close)
    end
  end

  it "keeps an older pending resume gated if a newer retry is rejected" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    params = ACP::Protocol::V2::SessionResumeParams.new("root", "/work")
    client.request_timeout = 0.01
    expect_raises(ACP::RequestTimeoutError) { client.session_resume(params) }
    first = transport.sent_messages.find! { |frame| frame["method"]?.try(&.as_s?) == "session/resume" }

    client.request_timeout = 2.0
    transport.replies["session/resume"] = %("error":{"code":-32603,"message":"Retry failed"})
    expect_raises(ACP::JsonRpcError, /Retry failed/) { client.session_resume(params) }
    transport.update("root", %({"sessionUpdate":"state_update","state":"running"}))
    transport.update("root", %({"sessionUpdate":"subagent_update","sessionId":"child","capabilities":{"cancel":{}}}))
    choice_state_barrier(client, transport)
    expect_raises(ACP::InvalidStateError) { client.session_cancel("child") }

    transport.inject_raw(%({"jsonrpc":"2.0","id":#{first["id"]},"result":{}}))
    choice_state_barrier(client, transport)
    client.session_state("root").not_nil!.state.should eq("running")
    client.session_workspace("child").not_nil!.cwd.should eq("/work")
    client.session_cancel("child")
  ensure
    client.try(&.close)
  end
  it "reserves a detached root ID while its timed-out resume is still on the wire" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/new"] = %("result":{"sessionId":"other"})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/other")

    client.request_timeout = 0.01
    expect_raises(ACP::RequestTimeoutError) do
      client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("saved", "/saved"))
    end
    resume = transport.sent_messages.find! { |frame| frame["method"]?.try(&.as_s?) == "session/resume" }

    client.request_timeout = 2.0
    transport.update("other", %({"sessionUpdate":"subagent_update","sessionId":"saved","capabilities":{"cancel":{}}}))
    choice_state_barrier(client, transport)
    client.subagent("saved").should be_nil

    transport.replies["session/new"] = %("result":{"sessionId":"saved"})
    expect_raises(ACP::ProtocolError, /existing session ID/) { client.session_new("/competing") }
    client.session_workspace("saved").should be_nil
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{resume["id"]},"result":{}}))
    choice_state_barrier(client, transport)
    client.session_workspace("saved").not_nil!.cwd.should eq("/saved")
    client.subagent("saved").should be_nil
  ensure
    client.try(&.close)
  end
  {true, false}.each do |resume_reply_first|
    order = resume_reply_first ? "before" : "after"
    it "releases a deleted root when an older resume reply arrives #{order} deletion completes" do
      transport = ChoiceStateTransport.new
      transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"delete":{}}}})
      transport.replies["session/new"] = %("result":{"sessionId":"root"})
      transport.replies["session/delete"] = %("result":{})
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      client.initialize_connection
      client.session_new("/work")

      client.request_timeout = 0.01
      expect_raises(ACP::RequestTimeoutError) do
        client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("root", "/work"))
      end
      request = transport.sent_messages.find! { |frame| frame["method"]?.try(&.as_s?) == "session/resume" }
      reply = %({"jsonrpc":"2.0","id":#{request["id"]},"result":{"availableCommands":[{"type":"command","name":"stale","description":"Stale"}]}})
      if resume_reply_first
        transport.before_reply = ->(method : String, _message : Hash(String, JSON::Any)) do
          transport.inject_raw(reply) if method == "session/delete"
          nil
        end
      end

      client.request_timeout = 2.0
      client.session_delete("root")
      transport.inject_raw(reply) unless resume_reply_first
      choice_state_barrier(client, transport)
      client.session_state("root").should be_nil
      client.session_workspace("root").should be_nil
      client.session_available_commands("root").should be_nil
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP v2 cancellation replies" do
  it "accepts a terminal cancel result with wide optional metadata" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      advertised = Channel(Nil).new(1)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        advertised.send(nil) if note.update.session_update == "terminal_update"
        nil
      end
      spawn do
        init = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{init["id"]},"result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}}})
        setup = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{setup["id"]},"result":{"sessionId":"root"}})
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":{"sessionUpdate":"terminal_update","terminalId":"term","capabilities":{"cancel":{}}}}})
        cancel = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{cancel["id"]},"result":{"_meta":{"wide":18446744073709551615}}})
      end
      client.initialize_connection
      client.session_new("/work")
      select
      when advertised.receive
      when timeout(2.seconds)
        fail "the Agent's terminal advertisement did not arrive"
      end
      client.terminal_cancel("root", "term").meta.should be_nil
    ensure
      client.try(&.close)
    end
  end
end
