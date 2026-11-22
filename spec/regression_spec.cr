require "./spec_helper"
require "log/spec"
require "colorize"
require "../examples/terminal_display"

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

    expect_raises(ACP::ProtocolError, /exactly one.*result.*error/) do
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

    transport.inject_raw(%({"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{"sessionId":"other","toolCall":{"toolCallId":"t"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"}]}}))
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

  it "round-trips explicit clears separately from omitted fields" do
    type = ACP::Protocol::SessionInfoUpdate
    clear = type.from_json(%({"sessionUpdate":"session_info_update","title":null}))
    fields = JSON.parse(clear.to_json).as_h
    fields.has_key?("title").should be_true
    fields["title"].raw.should be_nil
    fields.has_key?("updatedAt").should be_false
    type.from_json(clear.to_json).should eq(clear)
    type.new.should_not eq(clear)

    update = type.new(title: "")
    update.updated_at = nil
    fields = JSON.parse(update.to_json).as_h
    fields["title"].should eq("")
    fields["updatedAt"].raw.should be_nil
    type.from_json(update.to_json).should eq(update)
  end

  it "preserves valid fields when other supplied fields are malformed or repeated" do
    type = ACP::Protocol::SessionInfoUpdate
    update = type.from_json(%({"sessionUpdate":"session_info_update","title":null,"updatedAt":false,"_meta":false}))
    update.title_present?.should be_true
    update.title.should be_nil
    update.updated_at_present?.should be_false
    update.meta.should be_nil

    date = "2026-11-22T09:00:00Z"
    [%("title":false), %("title":"old","title":null)].each do |fields|
      update = type.from_json(%({"sessionUpdate":"session_info_update",#{fields},"updatedAt":#{date.to_json}}))
      update.title_present?.should be_false
      update.updated_at_present?.should be_true
      update.updated_at.should eq(date)
      JSON.parse(update.to_json).as_h.has_key?("title").should be_false
    end
  end

  it "delivers a partial patch with exact metadata through the typed stdio callback" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::Client.new(transport)
      client.request_timeout = 2.0
      answer_identity_request(feed, outgoing, %({"protocolVersion":1}))
      client.initialize_connection
      answer_identity_request(feed, outgoing, %({"sessionId":"root"}))
      client.session_new("/work")

      updates = Channel(ACP::Protocol::SessionInfoUpdate).new(1)
      client.on_update = ->(note : ACP::Protocol::SessionUpdateParams) do
        if patch = note.update.as?(ACP::Protocol::SessionInfoUpdate)
          updates.send(patch)
        end
        nil
      end
      metadata = %({"example.test/count":18446744073709551615,"example.test/ratio":1.23000000000000000001})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":{"type":"session_info_update","title":null,"updatedAt":false,"_meta":#{metadata}}}})
      answer_identity_request(feed, outgoing, "{}")
      client.ext_method("barrier")
      select
      when update = updates.receive
        update.title_present?.should be_true
        update.updated_at_present?.should be_false
        update.meta_raw.not_nil!.json.should eq(metadata)
        wire = ACP::Protocol::RawJson.from_json(update.to_json)
        wire.field("title").not_nil!.null?.should be_true
        wire.field("updatedAt").should be_nil
        wire.field("_meta").not_nil!.json.should eq(metadata)
      else
        fail "session info patch did not reach the typed callback"
      end
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP v1 raw tool call notifications" do
  it "delivers tool input and output with exact JSON through the typed stdio callback" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::Client.new(transport)
      client.request_timeout = 2.0
      answer_identity_request(feed, outgoing, %({"protocolVersion":1}))
      client.initialize_connection
      answer_identity_request(feed, outgoing, %({"sessionId":"root"}))
      client.session_new("/work")

      updates = Channel(ACP::Protocol::SessionUpdate).new(3)
      client.on_update = ->(note : ACP::Protocol::SessionUpdateParams) do
        updates.send(note.update)
        nil
      end
      input = %({"count":18446744073709551615,"label":"inventory"})
      output = %([18446744073709551615,0.123456789012345678901])
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":{"sessionUpdate":"tool_call","toolCallId":"tool","title":"Count inventory","rawInput":#{input}}}})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":{"type":"tool_call_update","toolCallId":"tool","status":"completed","rawOutput":#{output}}}})
      decimal = "0.123456789012345678901"
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":{"sessionUpdate":"tool_call_update","toolCallId":"tool","rawOutput":#{decimal}}}})
      answer_identity_request(feed, outgoing, "{}")
      client.ext_method("barrier")
      select
      when update = updates.receive
        started = update.as(ACP::Protocol::ToolCallUpdate)
        started.title.should eq("Count inventory")
        started.raw_input.should be_nil
        started.raw_input_raw.not_nil!.json.should eq(input)
        ACP::Protocol::RawJson.from_json(started.to_json).field("rawInput").should eq(started.raw_input_raw)
        ACP::Protocol::ToolCallUpdate.from_json(started.to_json).should eq(started)
      else
        fail "tool call did not reach the typed callback"
      end
      select
      when update = updates.receive
        completed = update.as(ACP::Protocol::ToolCallStatusUpdate)
        completed.status.should eq("completed")
        completed.raw_output.should be_nil
        completed.raw_output_raw.not_nil!.json.should eq(output)
        ACP::Protocol::RawJson.from_json(completed.to_json).field("rawOutput").should eq(completed.raw_output_raw)
      else
        fail "tool call update did not reach the typed callback"
      end
      select
      when update = updates.receive
        completed = update.as(ACP::Protocol::ToolCallStatusUpdate)
        completed.raw_output.should eq(JSON.parse(decimal))
        completed.raw_output_raw.not_nil!.json.should eq(decimal)
      else
        fail "tool call update with a decimal did not reach the typed callback"
      end
    ensure
      client.try(&.close)
    end
  end

  it "keeps the existing construction, comparison, and null semantics" do
    type = ACP::Protocol::ToolCallStatusUpdate
    update = type.from_json(%({"sessionUpdate":"tool_call_update","toolCallId":"tool","rawInput":null,"rawOutput":false}))
    built = type.new("tool", raw_output: JSON::Any.new(false))
    update.should eq(built)
    update.hash.should eq(built.hash)
    update.raw_input.should be_nil
    update.raw_input_raw.should be_nil
    update.raw_output_raw.not_nil!.json.should eq("false")
    JSON.parse(update.to_json)["rawInput"]?.should be_nil

    update.raw_input = JSON::Any.new(nil)
    update.raw_input_raw.not_nil!.null?.should be_true
    JSON.parse(update.to_json)["rawInput"]?.should eq(JSON::Any.new(nil))
    update.raw_input = nil
    JSON.parse(update.to_json)["rawInput"]?.should be_nil
  end

  it "keeps the original decimals when a representable input object is edited" do
    update = ACP::Protocol::ToolCallStatusUpdate.from_json(%({"sessionUpdate":"tool_call_update","toolCallId":"tool","rawInput":{"ratio":0.123456789012345678901,"label":"old"}}))
    update.raw_input.not_nil!.as_h["label"] = JSON::Any.new("new")
    input = ACP::Protocol::RawJson.from_json(update.to_json).field("rawInput").not_nil!
    input.field("ratio").not_nil!.json.should eq("0.123456789012345678901")
    input.field("label").not_nil!.as_s?.should eq("new")
  end
end

describe "ACP v1 tool call collections" do
  it "delivers exact content and locations through the typed stdio callback" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::Client.new(transport)
      client.request_timeout = 2.0
      answer_identity_request(feed, outgoing, %({"protocolVersion":1}))
      client.initialize_connection
      answer_identity_request(feed, outgoing, %({"sessionId":"root"}))
      client.session_new("/work")

      updates = Channel(ACP::Protocol::ToolCallStatusUpdate).new(1)
      client.on_update = ->(note : ACP::Protocol::SessionUpdateParams) do
        updates.send(note.update.as(ACP::Protocol::ToolCallStatusUpdate))
        nil
      end
      nested = "[" * 105 + "1" + "]" * 105
      metadata = %({"example.test/count":18446744073709551615,"example.test/nested":#{nested}})
      content = %([{"type":"content","content":{"type":"text","text":"Done"},"_meta":#{metadata}},false,{"type":"future"}])
      locations = %([{"path":"/report","line":12,"_meta":#{metadata}},{"path":"/summary","line":"unknown"},{}])
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":{"sessionUpdate":"tool_call_update","toolCallId":"tool","status":"completed","content":#{content},"locations":#{locations},"_meta":#{metadata}}}})
      answer_identity_request(feed, outgoing, "{}")
      client.ext_method("barrier")
      select
      when update = updates.receive
        update.status.should eq("completed")
        update.typed_content.size.should eq(1)
        block = update.typed_content.first.as(ACP::Protocol::ToolCallContentBlock)
        block.text.should eq("Done")
        block.meta_raw.not_nil!.json.should eq(metadata)
        update.typed_locations.map(&.path).should eq(["/report", "/summary"])
        update.typed_locations.map(&.line).should eq([12_u32, nil])
        update.typed_locations.first.meta_raw.not_nil!.json.should eq(metadata)
        update.meta_raw.not_nil!.json.should eq(metadata)
        update.content_raw.not_nil!.json.should eq(content)
        update.locations_raw.not_nil!.json.should eq(locations)
        wire = ACP::Protocol::RawJson.from_json(update.to_json)
        wire.field("content").not_nil!.json.should eq(content)
        wire.field("locations").not_nil!.json.should eq(locations)
      else
        fail "collection update did not reach the typed callback"
      end
    ensure
      client.try(&.close)
    end
  end

  it "keeps the other updates when optional collections have the wrong shape" do
    update = ACP::Protocol::ToolCallUpdate.from_json(%({"sessionUpdate":"tool_call","toolCallId":"tool","title":"Write report","content":{},"locations":false}))
    update.title.should eq("Write report")
    update.content.should be_nil
    update.locations.should be_nil
    update.typed_content.should be_empty
    update.typed_locations.should be_empty
  end

  it "keeps exact metadata attached to the edited content item" do
    type = ACP::Protocol::ToolCallUpdate
    metadata = %({"example.test/count":18446744073709551615})
    update = type.from_json(%({"sessionUpdate":"tool_call","toolCallId":"tool","title":"Report","content":[{"type":"terminal","terminalId":"first","_meta":#{metadata}},{"type":"terminal","terminalId":"second"}]}))
    entries = update.content.not_nil!
    entries.reverse!
    entries.last.as_h["terminalId"] = JSON::Any.new("changed")
    items = update.typed_content.map(&.as(ACP::Protocol::ToolCallTerminal))
    items.map(&.terminal_id).should eq(["second", "changed"])
    items.first.meta_raw.should be_nil
    items.last.meta_raw.not_nil!.json.should eq(metadata)
    type.from_json(update.to_json).should eq(update)

    update.content = [] of JSON::Any
    update.typed_content.should be_empty
    update.content_raw.not_nil!.json.should eq("[]")
    update.content = nil
    update.content_raw.should be_nil
  end
end

describe "ACP v1 typed permission requests" do
  it "decodes exact metadata and tool contents from permission parameters" do
    metadata = %({"example.test/count":18446744073709551615})
    wire = %({"sessionId":"s","toolCall":{"toolCallId":"tool","name":"inspect","toolName":false,"rawInput":18446744073709551615,"content":[{"type":"terminal","terminalId":"terminal","_meta":#{metadata}}],"_meta":#{metadata}},"options":[{"optionId":"reject","name":"Reject","kind":"reject_once","_meta":#{metadata}}],"_meta":#{metadata}})
    input = ACP::Protocol::RequestPermissionParams.from_json(wire)
    input.tool_call.tool_call_id.should eq("tool")
    input.tool_call.name.should eq("inspect")
    input.tool_call.tool_name.should be_nil
    parsed = ACP::Protocol::RawJson.from_json(input.to_json)
    parsed.field("toolCall").not_nil!.field("rawInput").not_nil!.json.should eq("18446744073709551615")
    parsed.field("options").not_nil!.elements?.not_nil!.first.field("_meta").not_nil!.json.should eq(metadata)
    parsed.field("_meta").not_nil!.json.should eq(metadata)
  end

  it "gives the typed handler exact input and checks its choice against the original options" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::Client.new(transport)
      client.request_timeout = 2.0
      answer_identity_request(feed, outgoing, %({"protocolVersion":1}))
      client.initialize_connection
      answer_identity_request(feed, outgoing, %({"sessionId":"s"}))
      client.session_new("/work")

      requests = Channel(ACP::Protocol::RequestPermissionParams).new(2)
      fallback_calls = 0
      client.on_agent_request = ->(_method : String, _params : JSON::Any) do
        fallback_calls += 1
        JSON.parse(ACP::Protocol::RequestPermissionResult.cancelled.to_json)
      end
      client.on_request_permission = ->(request : ACP::Protocol::RequestPermissionParams) do
        requests.send(request)
        option = request.options.first
        request.options.clear
        selected = request.request_id == "choose" ? option.option_id : "unavailable"
        ACP::Protocol::RequestPermissionResult.selected(selected)
      end
      params = %({"sessionId":"s","toolCall":{"toolCallId":"tool","title":"Inspect count","rawInput":{"count":18446744073709551615},"rawOutput":0.123456789012345678901},"options":[{"optionId":"reject","name":"Reject","kind":"reject_once"}]})
      feed.puts %({"jsonrpc":"2.0","id":"choose","method":"session/request_permission","params":#{params}})
      reply = JSON.parse(outgoing.gets.not_nil!)
      reply["id"].should eq("choose")
      reply["result"]["outcome"]["optionId"].should eq("reject")
      received = requests.receive
      received.session_id.should eq("s")
      received.request_id.should eq("choose")
      received.tool_call.raw_input_raw.not_nil!.field("count").not_nil!.json.should eq("18446744073709551615")
      received.tool_call.raw_output_raw.not_nil!.json.should eq("0.123456789012345678901")
      ACP::Protocol::RawJson.from_json(received.to_json).field("requestId").should be_nil

      feed.puts %({"jsonrpc":"2.0","id":"other","method":"session/request_permission","params":#{params}})
      JSON.parse(outgoing.gets.not_nil!)["error"]["code"].should eq(ACP::JsonRpcError::INTERNAL_ERROR)
      other = requests.receive
      other.request_id.should eq("other")
      received.should_not eq(other)
      fallback_calls.should eq(0)

      client.on_request_permission = nil
      ordinary = %({"sessionId":"s","toolCall":{"toolCallId":"tool"},"options":[{"optionId":"reject","name":"Reject","kind":"reject_once"}]})
      feed.puts %({"jsonrpc":"2.0","id":"legacy","method":"session/request_permission","params":#{ordinary}})
      JSON.parse(outgoing.gets.not_nil!)["result"]["outcome"]["outcome"].should eq("cancelled")
      fallback_calls.should eq(1)
    ensure
      client.try(&.close)
    end
  end
  it "correlates cancellation and sends only the cancelled outcome" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::Client.new(transport)
      client.request_timeout = 2.0
      answer_identity_request(feed, outgoing, %({"protocolVersion":1}))
      client.initialize_connection
      answer_identity_request(feed, outgoing, %({"sessionId":"s"}))
      client.session_new("/work")

      started = Channel(ACP::Protocol::RequestId?).new(1)
      released = Channel(Nil).new
      completed = Channel(Nil).new(1)
      client.on_request_permission = ->(request : ACP::Protocol::RequestPermissionParams) do
        started.send(request.request_id)
        released.receive?
        completed.send(nil)
        ACP::Protocol::RequestPermissionResult.selected(request.options.first.option_id)
      end
      feed.puts %({"jsonrpc":"2.0","id":"review","method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"tool","rawInput":18446744073709551615},"options":[{"optionId":"reject","name":"Reject","kind":"reject_once"}]}})
      next_permission_event(started).should eq("review")
      feed.puts %({"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":"review"}})
      reply = JSON.parse(outgoing.gets.not_nil!)
      reply["id"].should eq("review")
      reply["result"]["outcome"]["outcome"].should eq("cancelled")

      released.close
      next_permission_event(completed)
      spawn do
        frame = JSON.parse(outgoing.gets.not_nil!)
        if frame["method"]? == "_barrier"
          reply = %({"jsonrpc":"2.0","id":#{frame["id"]},"result":{}})
        else
          barrier = JSON.parse(outgoing.gets.not_nil!)
          reply = %({"jsonrpc":"2.0","id":#{barrier["id"]},"result":{"unexpectedReply":true}})
        end
        feed.puts reply
      end
      client.ext_method("barrier").should eq(JSON.parse("{}"))
    ensure
      released.try(&.close)
      client.try(&.close)
    end
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
    client = initialized_read_client(transport)
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

private def initialized_read_client(transport : SignalingTransport) : ACP::Client
  caps = ACP::Protocol::ClientCapabilities.new(fs: ACP::Protocol::FsCapabilities.new(read_text_file: true))
  client = ACP::Client.new(transport, client_capabilities: caps)
  spawn do
    request = next_answer(transport)
    transport.inject_raw(build_init_response(request["id"].as_i64))
  end
  client.initialize_connection
  client
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
      transport.inject_raw(%({"jsonrpc":"2.0","id":null,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"t"},"options":[{"optionId":"ok","name":"OK","kind":"allow_once"}]}}))
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
    client = initialized_read_client(transport)
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
    client = initialized_read_client(transport)
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
  it "delivers all v1 message chunks with exact content and envelope metadata" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::Client.new(transport)
      client.request_timeout = 2.0
      answer_identity_request(feed, outgoing, %({"protocolVersion":1}))
      client.initialize_connection
      notes = Channel(ACP::Protocol::SessionUpdateParams).new(3)
      client.on_update = ->(note : ACP::Protocol::SessionUpdateParams) do
        notes.send(note)
        nil
      end
      metadata = %({"example.test/count":18446744073709551615,"example.test/ratio":0.123456789012345678901})
      fragments = {"agent_message_chunk", "user_message_chunk", "agent_thought_chunk"}
      fragments.each do |kind|
        id = kind == "agent_thought_chunk" ? "false" : %("message-1")
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","_meta":#{metadata},"update":{"sessionUpdate":#{kind.to_json},"messageId":#{id},"content":{"type":"text","text":#{kind.to_json},"_meta":#{metadata}},"_meta":#{metadata}}}})
      end
      answer_identity_request(feed, outgoing, "{}")
      client.ext_method("barrier")
      fragments.each do |kind|
        select
        when note = notes.receive
          note.meta_raw.not_nil!.json.should eq(metadata)
          case update = note.update
          when ACP::Protocol::AgentMessageChunkUpdate, ACP::Protocol::UserMessageChunkUpdate, ACP::Protocol::AgentThoughtChunkUpdate
            update.text.should eq(kind)
            chunk = update.to_content_chunk.not_nil!
            chunk.text.should eq(kind)
            chunk.meta_raw.not_nil!.json.should eq(metadata)
            chunk.content.as(ACP::Protocol::TextContentBlock).meta_raw.not_nil!.json.should eq(metadata)
            chunk.message_id.should eq(kind == "agent_thought_chunk" ? nil : "message-1")
            chunk.meta.not_nil!["example.test/edited"] = JSON::Any.new(true)
            update.meta.not_nil!["example.test/edited"].should eq(true)
            chunk.meta_raw.not_nil!.field("example.test/count").not_nil!.json.should eq("18446744073709551615")
          else
            fail "expected a message chunk update"
          end
        else
          fail "#{kind} did not reach the typed callback"
        end
      end
    ensure
      client.try(&.close)
    end
  end

  it "preserves exact content when the JSON::Any view is edited" do
    type = ACP::Protocol::AgentMessageChunkUpdate
    metadata = %({"example.test/count":18446744073709551615})
    update = type.from_json(%({"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"before","_meta":#{metadata}}}))
    update.content.as_h["text"] = JSON::Any.new("after")
    update.content_raw.field("_meta").not_nil!.json.should eq(metadata)
    update.text.should eq("after")
    type.from_json(update.to_json).should eq(update)

    update.content = JSON::Any.new("legacy text")
    update.content_raw.as_s?.should eq("legacy text")
    update.text.should eq("legacy text")
    update.to_content_chunk.should be_nil
  end

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
      client = initialized_v1_terminal_client(transport, feed, outgoing)
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

private def with_wide_stdio(*, exact_frames : Bool = false, &)
  reader, feed = IO.pipe
  outgoing, writer = IO.pipe
  outgoing.read_timeout = 2.seconds
  transport = ACP::StdioTransport.new(reader, writer, exact_frames: exact_frames)
  yield transport, feed, outgoing
ensure
  transport.try(&.close)
  feed.try(&.close)
  outgoing.try(&.close)
end

private def initialize_wide_v2(client : ACP::V2::Client, feed : IO, outgoing : IO, *, session_id : String? = nil)
  spawn do
    request = JSON.parse(outgoing.gets.not_nil!)
    capabilities = session_id ? %(,"capabilities":{"session":{}}) : ""
    feed.puts %({"jsonrpc":"2.0","id":#{request["id"].to_json},"result":{"protocolVersion":2,"info":{"name":"agent","version":"1"}#{capabilities}}})
    if session_id
      setup = JSON.parse(outgoing.gets.not_nil!)
      feed.puts %({"jsonrpc":"2.0","id":#{setup["id"].to_json},"result":{"sessionId":#{session_id.to_json}}})
    end
  end
  client.initialize_connection
  client.session_new("/work") if session_id
end

private def initialized_v1_terminal_client(transport : ACP::Transport, feed : IO, outgoing : IO) : ACP::Client
  client = ACP::Client.new(transport, client_capabilities: ACP::Protocol::ClientCapabilities.new(terminal: true))
  spawn do
    request = JSON.parse(outgoing.gets.not_nil!)
    feed.puts build_init_response(request["id"].as_i64).delete('\n')
  end
  client.initialize_connection
  client
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

  def initialize(@queued_method : String = "session/set_config_option")
    super()
  end

  def send_checked(message : Hash(String, JSON::Any), &preflight : -> Nil) : Nil
    if message["method"]?.try(&.as_s?) == @queued_method
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
      client.session_close("s").meta_raw.not_nil!.field("wide").not_nil!.json.should eq("18446744073709551615")
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

  {true, false}.each do |attached|
    scope = attached ? "attached" : "detached"
    it "preserves newer live state when an older resume confirms the #{scope} root" do
      transport = ChoiceStateTransport.new
      transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"additionalDirectories":{}}}})
      transport.replies["session/new"] = %("result":{"sessionId":"root"})
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      client.initialize_connection
      client.session_new("/work") if attached

      client.request_timeout = 0.01
      older = ACP::Protocol::V2::SessionResumeParams.new("root", "/work", additional_directories: ["/old"])
      expect_raises(ACP::RequestTimeoutError) { client.session_resume(older) }
      first = transport.sent_messages.find! { |frame| frame["method"]?.try(&.as_s?) == "session/resume" }
      transport.update("root", %({"sessionUpdate":"state_update","state":"running"}))
      client.request_timeout = 2.0
      choice_state_barrier(client, transport)

      observed = Channel(String?).new(1)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        if note.update.session_update == "_inspect"
          observed.send(client.session_state("root").try(&.state))
        end
        nil
      end
      transport.before_reply = ->(method : String, _request : Hash(String, JSON::Any)) do
        if method == "session/resume"
          transport.update("root", %({"sessionUpdate":"state_update","state":"requires_action"}))
          transport.inject_raw(%({"jsonrpc":"2.0","id":#{first["id"]},"result":{}}))
          transport.update("root", %({"sessionUpdate":"_inspect"}))
        end
        nil
      end
      transport.replies["session/resume"] = %("error":{"code":-32603,"message":"Retry failed"})
      newer = ACP::Protocol::V2::SessionResumeParams.new("root", "/work", additional_directories: ["/new"])
      expect_raises(ACP::JsonRpcError, /Retry failed/) { client.session_resume(newer) }
      select
      when state = observed.receive
        state.should eq("requires_action")
      when timeout(2.seconds)
        fail "did not observe state between resume replies"
      end
      client.session_state("root").not_nil!.state.should eq("requires_action")
      client.session_workspace("root").not_nil!.additional_directories.should eq(["/old"])
    ensure
      client.try(&.close)
    end
  end

  {true, false}.each do |oversized|
    expected = oversized ? "unknown" : "requires_action"
    it "reports #{expected} when the newer detached resume has also timed out" do
      transport = ChoiceStateTransport.new
      transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      client.initialize_connection
      params = ACP::Protocol::V2::SessionResumeParams.new("root", "/work")
      client.request_timeout = 0.01
      expect_raises(ACP::RequestTimeoutError) { client.session_resume(params) }
      first = transport.sent_messages.find! { |frame| frame["method"]?.try(&.as_s?) == "session/resume" }
      transport.update("root", %({"sessionUpdate":"state_update","state":"running"}))
      client.request_timeout = 2.0
      choice_state_barrier(client, transport)

      client.request_timeout = 0.01
      expect_raises(ACP::RequestTimeoutError) { client.session_resume(params) }
      padding = oversized ? "x" * (64 * 1024) : ""
      transport.update("root", %({"sessionUpdate":"state_update","state":"requires_action","_meta":{"padding":#{padding.to_json}}}))
      transport.inject_raw(%({"jsonrpc":"2.0","id":#{first["id"]},"result":{}}))
      client.request_timeout = 2.0
      choice_state_barrier(client, transport)
      client.session_state("root").not_nil!.state.should eq(expected)
    ensure
      client.try(&.close)
    end
  end

  it "keeps the latest observed state while a third resume has not sent a snapshot" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    params = ACP::Protocol::V2::SessionResumeParams.new("root", "/work")
    {"running", "requires_action"}.each do |state|
      client.request_timeout = 0.01
      expect_raises(ACP::RequestTimeoutError) { client.session_resume(params) }
      transport.update("root", %({"sessionUpdate":"state_update","state":#{state.to_json}}))
      client.request_timeout = 2.0
      choice_state_barrier(client, transport)
    end
    first, second = transport.sent_messages.select { |frame| frame["method"]?.try(&.as_s?) == "session/resume" }
    observed = Channel(String?).new(2)
    client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
      observed.send(client.session_state("root").try(&.state)) if note.update.session_update == "_inspect"
      nil
    end
    transport.before_reply = ->(method : String, _request : Hash(String, JSON::Any)) do
      if method == "session/resume"
        {first, second}.each do |resume|
          transport.inject_raw(%({"jsonrpc":"2.0","id":#{resume["id"]},"result":{}}))
          transport.update("root", %({"sessionUpdate":"_inspect"}))
        end
      end
      nil
    end
    transport.replies["session/resume"] = %("error":{"code":-32603,"message":"Retry failed"})
    expect_raises(ACP::JsonRpcError, /Retry failed/) { client.session_resume(params) }
    2.times do
      select
      when state = observed.receive
        state.should eq("requires_action")
      when timeout(2.seconds)
        fail "did not observe state between resume replies"
      end
    end
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

describe "ACP v2 replay retirement" do
  {"a confirmed close", "a newer resume"}.each do |retirement|
    it "releases a timed-out replay after #{retirement} and ignores its late reply" do
      transport = ChoiceStateTransport.new
      transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"additionalDirectories":{}}}})
      transport.replies["session/new"] = %("result":{"sessionId":"root"})
      transport.replies["session/close"] = %("result":{})
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      client.initialize_connection
      client.session_new("/work")

      client.request_timeout = 0.01
      expect_raises(ACP::RequestTimeoutError) do
        client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("root", "/work", additional_directories: ["/old"], replay_from: ACP::Protocol::V2::ReplayFrom.start))
      end
      old = transport.sent_messages.find! { |frame| frame["method"]?.try(&.as_s?) == "session/resume" }
      transport.update("root", %({"sessionUpdate":"subagent_update","sessionId":"child"}))
      transport.update("child", %({"sessionUpdate":"agent_message","messageId":"old","content":[]}))
      transport.update("child", %({"sessionUpdate":"cursor_update","cursorId":"stale","anchor":{"type":"agent_message","messageId":"old","position":"after"}}))
      client.request_timeout = 2.0
      choice_state_barrier(client, transport)
      client.session_cursor("child", "stale").should be_nil

      if retirement == "a confirmed close"
        client.session_close("root")
        client.session_workspace("root").should be_nil
        transport.update("child", %({"sessionUpdate":"cursor_update","cursorId":"late","anchor":{"type":"agent_message","messageId":"old","position":"after"}}))
        choice_state_barrier(client, transport)
        client.session_cursor("child", "late").should be_nil
      else
        transport.update("root", %({"sessionUpdate":"replay_complete"}))
        choice_state_barrier(client, transport)
        transport.replies["session/resume"] = %("result":{})
        client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("root", "/work", additional_directories: ["/new"]))
      end

      transport.replies["session/resume"] = %("result":{"availableCommands":[{"type":"command","name":"fresh","description":"Fresh"}]})
      transport.before_reply = ->(method : String, _request : Hash(String, JSON::Any)) do
        if method == "session/resume"
          transport.update("root", %({"sessionUpdate":"subagent_update","sessionId":"child"}))
          transport.update("child", %({"sessionUpdate":"agent_message","messageId":"new","content":[]}))
          transport.update("child", %({"sessionUpdate":"cursor_update","cursorId":"fresh","anchor":{"type":"agent_message","messageId":"new","position":"after"}}))
          transport.inject_raw(%({"jsonrpc":"2.0","id":#{old["id"]},"result":{"availableCommands":[{"type":"command","name":"stale","description":"Stale"}]}}))
          transport.update("child", %({"sessionUpdate":"replay_complete"}))
          transport.update("root", %({"sessionUpdate":"replay_complete"}))
          transport.update("root", %({"sessionUpdate":"state_update","state":"running"}))
        end
        nil
      end
      client.session_resume(ACP::Protocol::V2::SessionResumeParams.new("root", "/work", additional_directories: ["/new"], replay_from: ACP::Protocol::V2::ReplayFrom.start))
      client.session_state("root").not_nil!.state.should eq("running")
      client.session_workspace("root").not_nil!.additional_directories.should eq(["/new"])
      client.session_available_commands("root").not_nil!.map(&.name).should eq(["fresh"])
      client.session_cursors("child").map(&.cursor_id).should eq(["fresh"])
    ensure
      client.try(&.close)
    end
  end

  it "releases the replay reservation when the late setup is evicted" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    next_answer(transport)

    client.request_timeout = 0.001
    129.times do |index|
      params = ACP::Protocol::V2::SessionResumeParams.new("saved-#{index}", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start)
      expect_raises(ACP::RequestTimeoutError) { client.session_resume(params) }
      next_answer(transport)["method"].should eq("session/resume")
      next_answer(transport)["method"].should eq("$/cancel_request")
    end

    client.request_timeout = 2.0
    transport.update("saved-0", %({"sessionUpdate":"agent_message","messageId":"old","content":[]}))
    transport.update("saved-0", %({"sessionUpdate":"cursor_update","cursorId":"stale","anchor":{"type":"agent_message","messageId":"old","position":"after"}}))
    choice_state_barrier(client, transport)
    client.session_cursor("saved-0", "stale").should be_nil

    transport.replies["session/resume"] = %("result":{})
    transport.before_reply = ->(method : String, _request : Hash(String, JSON::Any)) do
      if method == "session/resume"
        transport.update("saved-0", %({"sessionUpdate":"replay_complete"}))
        transport.update("saved-0", %({"sessionUpdate":"state_update","state":"idle"}))
      end
      nil
    end
    params = ACP::Protocol::V2::SessionResumeParams.new("saved-0", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start)
    client.session_resume(params)
    client.session_state("saved-0").not_nil!.state.should eq("idle")
  ensure
    client.try(&.close)
  end

  it "discards staged cursors when a still-pending resume is retired by close" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/new"] = %("result":{"sessionId":"root"})
    transport.replies["session/close"] = %("result":{})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")
    next_answer(transport)
    next_answer(transport)
    transport.update("root", %({"sessionUpdate":"agent_message","messageId":"existing","content":[]}))
    transport.update("root", %({"sessionUpdate":"cursor_update","cursorId":"published","anchor":{"type":"agent_message","messageId":"existing","position":"after"}}))
    choice_state_barrier(client, transport)
    next_answer(transport)["method"].should eq("_barrier")
    client.session_cursor("root", "published").should_not be_nil

    outcome = Channel(ACP::Protocol::V2::SessionResumeResult | Exception).new(1)
    spawn do
      params = ACP::Protocol::V2::SessionResumeParams.new("root", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start)
      outcome.send(client.session_resume(params))
    rescue ex
      outcome.send(ex)
    end
    resume = next_answer(transport)
    resume["method"].should eq("session/resume")
    transport.update("root", %({"sessionUpdate":"agent_message","messageId":"old","content":[]}))
    transport.update("root", %({"sessionUpdate":"cursor_update","cursorId":"stale","anchor":{"type":"agent_message","messageId":"old","position":"after"}}))
    choice_state_barrier(client, transport)
    client.session_cursor("root", "stale").should be_nil

    client.session_close("root")
    transport.update("root", %({"sessionUpdate":"replay_complete"}))
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{resume["id"]},"result":{}}))
    select
    when result = outcome.receive
      result.should be_a(ACP::Protocol::V2::SessionResumeResult)
    when timeout(2.seconds)
      fail "resume response was not delivered"
    end
    client.session_cursor("root", "stale").should be_nil
    client.session_cursors("root").map(&.cursor_id).should eq(["published"])
    client.session_state("root").should be_nil
  ensure
    client.try(&.close)
  end
end

describe "ACP exact session management replies" do
  {1, 2}.each do |version|
    {"set_title", "archive", "unarchive", "close", "delete", "status", "options"}.each do |operation|
      it "preserves metadata in a v#{version} session/#{operation} reply" do
        with_wide_stdio do |transport, feed, outgoing|
          client = version == 1 ? ACP::Client.new(transport) : ACP::V2::Client.new(transport)
          client.request_timeout = 2.0
          count = operation == "status" ? "42" : "18446744073709551615"
          spawn do
            init = JSON.parse(outgoing.gets.not_nil!)
            supports = %({"title":{},"archive":{},"close":{},"delete":{},"status":{},"options":{}})
            result = if version == 1
                       %({"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":#{supports}}})
                     else
                       %({"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":#{supports}}})
                     end
            feed.puts %({"jsonrpc":"2.0","id":#{init["id"]},"result":#{result}})
            setup = JSON.parse(outgoing.gets.not_nil!)
            feed.puts %({"jsonrpc":"2.0","id":#{setup["id"]},"result":{"sessionId":"root"}})
            request = JSON.parse(outgoing.gets.not_nil!)
            fields = case operation
                     when "set_title" then %("title":"Stored title",)
                     when "status"    then %("status":"open","state":{"state":"idle"},)
                     else                  ""
                     end
            feed.puts %({"jsonrpc":"2.0","id":#{request["id"]},"result":{#{fields}"_meta":{"example.test/source":"agent","example.test/count":#{count},"example.test/ratio":1.23000000000000000001}}})
          end

          client.initialize_connection
          client.session_new("/work")
          result = case operation
                   when "set_title" then client.session_set_title("root", "Proposed title")
                   when "archive"   then client.session_archive("root")
                   when "unarchive" then client.session_unarchive("root")
                   when "close"     then client.session_close("root")
                   when "delete"    then client.session_delete("root")
                   when "status"    then client.session_status("root")
                   else                  client.session_options("/work")
                   end
          result.meta.try(&.["example.test/source"]?).should eq("agent")
          result.title.should eq("Stored title") if result.is_a?(ACP::Protocol::SetSessionTitleResult)
          metadata = result.meta_raw.not_nil!
          metadata.field("example.test/count").not_nil!.json.should eq(count)
          metadata.field("example.test/ratio").not_nil!.json.should eq("1.23000000000000000001")
          result.to_json.should contain(%("example.test/count":#{count}))
          retired = operation.in?("archive", "close") || (version == 2 && operation == "delete")
          client.session_workspace("root").nil?.should eq(retired)
        ensure
          client.try(&.close)
        end
      end
    end
  end
end

describe "ACP v2 cancellation replies" do
  {"terminal" => "terminalId", "tool_call" => "toolCallId"}.each do |kind, id_field|
    {"wide integer" => "18446744073709551615", "precise decimal" => "1.23000000000000000001"}.each do |label, number|
      it "preserves a #{label} in a #{kind} cancel reply" do
        with_wide_stdio do |transport, feed, outgoing|
          client = ACP::V2::Client.new(transport)
          client.request_timeout = 2.0
          advertised = Channel(Nil).new(1)
          update = "#{kind}_update"
          client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
            advertised.send(nil) if note.update.session_update == update
            nil
          end
          spawn do
            init = JSON.parse(outgoing.gets.not_nil!)
            feed.puts %({"jsonrpc":"2.0","id":#{init["id"]},"result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}}})
            setup = JSON.parse(outgoing.gets.not_nil!)
            feed.puts %({"jsonrpc":"2.0","id":#{setup["id"]},"result":{"sessionId":"root"}})
            feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":{"sessionUpdate":#{update.to_json},#{id_field.to_json}:"entity","capabilities":{"cancel":{}}}}})
            cancel = JSON.parse(outgoing.gets.not_nil!)
            feed.puts %({"jsonrpc":"2.0","id":#{cancel["id"]},"result":{"_meta":{"number":#{number}}}})
          end
          client.initialize_connection
          client.session_new("/work")
          select
          when advertised.receive
          when timeout(2.seconds)
            fail "the Agent's cancellation capability did not arrive"
          end
          result = kind == "terminal" ? client.terminal_cancel("root", "entity") : client.tool_call_cancel("root", "entity")
          result.meta_raw.not_nil!.field("number").not_nil!.json.should eq(number)
        ensure
          client.try(&.close)
        end
      end
    end
  end
end

private def next_permission_event(channel : Channel(T)) : T forall T
  select
  when value = channel.receive
    value
  when timeout(2.seconds)
    fail "did not receive permission event"
  end
end

describe "ACP v2 exact permission subjects" do
  it "applies a wide tool-call subject before the permission handler and answers the request" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      events = Channel(String).new(3)
      updates = Channel(ACP::Protocol::V2::ToolCallUpdate).new(2)
      chunks = Channel(ACP::Protocol::V2::ToolCallContentChunk).new(1)
      requests = Channel(ACP::Protocol::V2::RequestPermissionParams).new(1)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        case update = note.update.typed
        when ACP::Protocol::V2::ToolCallUpdate
          events.send("patch:#{update.tool_call_id}")
          updates.send(update)
        when ACP::Protocol::V2::ToolCallContentChunk
          chunks.send(update)
        end
        nil
      end
      client.on_request_permission = ->(params : ACP::Protocol::V2::RequestPermissionParams) do
        requests.send(params)
        events.send("request:#{params.typed_subject.not_nil!.tool_call.not_nil!.tool_call_id}")
        client.tool_call_cancel("s", "t")
        ACP::Protocol::V2::RequestPermissionResult.selected(params.options.first.option_id)
      end
      spawn do
        init = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{init["id"]},"result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{}}}})
        setup = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{setup["id"]},"result":{"sessionId":"s"}})
      end
      client.initialize_connection
      client.session_new("/work")

      tool = %({"toolCallId":"t","title":null,"capabilities":{"cancel":{"_meta":{"wide":18446744073709551615}}},"rawInput":{"wide":18446744073709551615},"rawOutput":0.1234567890123456789,"_meta":{"wide":18446744073709551615,"label":"new","remove":null},"vendorExtra":0.11111111111111111111,"content":[{"type":"diff","changes":[{"operation":"create","path":"/work/file","vendor":0.22222222222222222222}],"patch":{"format":"unified","text":"+change","_meta":{"wide":18446744073709551615}}}]})
      subject = %({"type":"tool_call","toolCall":#{tool},"extension":18446744073709551616})
      feed.puts %({"jsonrpc":"2.0","id":"permission-wide","method":"session/request_permission","params":{"sessionId":"s","title":"Inspect metadata","description":false,"options":[{"optionId":"approve","name":"Approve","kind":"allow_once","_meta":{"wide":18446744073709551615}}],"subject":#{subject}}})
      cancel = JSON.parse(outgoing.gets.not_nil!)
      cancel["method"]?.try(&.as_s?).should eq("tool_call/cancel")
      cancel["params"]["toolCallId"].as_s.should eq("t")
      feed.puts %({"jsonrpc":"2.0","id":#{cancel["id"]},"result":{}})
      reply = JSON.parse(outgoing.gets.not_nil!)
      reply["id"].as_s.should eq("permission-wide")
      reply["result"]?.try(&.["outcome"].["optionId"].as_s).should eq("approve")
      next_permission_event(events).should eq("patch:t")
      next_permission_event(events).should eq("request:t")

      request = next_permission_event(requests)
      request.request_id.should eq("permission-wide")
      request.description.should be_nil
      request.subject.should be_nil
      request.subject_raw.not_nil!.json.should eq(subject)
      request.typed_subject.not_nil!.tool_call_raw.not_nil!.json.should eq(tool)

      patch = next_permission_event(updates)
      patch.title_present?.should be_true
      patch.title.should be_nil
      patch.raw_input_present?.should be_true
      patch.raw_input.should be_nil
      patch.raw_input_raw.not_nil!.field("wide").not_nil!.json.should eq("18446744073709551615")
      patch.raw_output_raw.not_nil!.json.should eq("0.1234567890123456789")
      patch.meta_raw.not_nil!.field("wide").not_nil!.json.should eq("18446744073709551615")
      previous = JSON.parse(%({"wide":"old","label":"before","remove":"yes","preserve":"keep"})).as_h
      patch.apply_metadata(previous).should eq(JSON.parse(%({"label":"new","preserve":"keep"})).as_h)
      patch.meta.not_nil!["label"] = JSON::Any.new("edited")
      patch.meta.not_nil!["label"].as_s.should eq("edited")
      patch.meta_raw.not_nil!.field("wide").not_nil!.json.should eq("18446744073709551615")
      patch.apply_metadata(previous).should eq(JSON.parse(%({"label":"edited","preserve":"keep"})).as_h)
      diff = patch.content.not_nil!.first.diff.not_nil!
      diff.changes.first.path.should eq("/work/file")
      diff.patch.not_nil!.text.should eq("+change")
      encoded = ACP::Protocol::WireFrame.encode(patch)
      encoded.should contain(%("rawOutput":0.1234567890123456789))
      encoded.should contain(%("vendorExtra":0.11111111111111111111))
      encoded.should contain(%("vendor":0.22222222222222222222))

      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"toolCallId":"t","vendorExtra":0.11111111111111111111,"sessionUpdate":"tool_call_update","rawInput":0.9876543210987654321}}})
      next_permission_event(events).should eq("patch:t")
      ordinary = next_permission_event(updates)
      ordinary.raw_input_raw.not_nil!.json.should eq("0.9876543210987654321")
      ACP::Protocol::WireFrame.encode(ordinary).should contain(%("vendorExtra":0.11111111111111111111))

      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_content_chunk","toolCallId":"t","content":{"type":"_future","vendor":0.22222222222222222222}}}})
      chunk = next_permission_event(chunks)
      chunk.tool_call_id.should eq("t")
      chunk.content.to_json.should contain(%("vendor":0.22222222222222222222))
    ensure
      client.try(&.close)
    end
  end

  it "preserves exact decimals behind existing mutable subject and tool payload views" do
    input = %({"sessionId":"s","title":"Permission","options":[{"optionId":"go","name":"Go","kind":"allow_once"}],"subject":{"type":"tool_call","toolCall":{"toolCallId":"t","rawInput":{"count":0.12345678901234567,"unchanged":[0.9876543210987654321]},"rawOutput":null}}})
    request = ACP::Protocol::V2::RequestPermissionParams.from_json(input)
    request.subject.should_not be_nil
    request.subject_raw.not_nil!.json.should contain("0.12345678901234567")
    patch = request.typed_subject.not_nil!.tool_call.not_nil!
    patch.raw_input_raw.not_nil!.field("count").not_nil!.json.should eq("0.12345678901234567")
    patch.raw_output_present?.should be_true
    patch.raw_output.should be_nil

    patch.raw_input.not_nil!.as_h["count"] = JSON::Any.new(8_i64)
    patch.raw_input_raw.not_nil!.field("count").not_nil!.as_i64?.should eq(8)
    patch.raw_input_raw.not_nil!.field("unchanged").not_nil!.json.should eq("[0.9876543210987654321]")
    patch.to_json.should contain(%("rawOutput":null))

    request.subject.not_nil!["toolCall"]["rawInput"].as_h["count"] = JSON::Any.new(9_i64)
    changed_input = request.typed_subject.not_nil!.tool_call.not_nil!.raw_input_raw.not_nil!
    changed_input.field("count").not_nil!.as_i64?.should eq(9)
    changed_input.field("unchanged").not_nil!.json.should eq("[0.9876543210987654321]")

    typed_subject = request.typed_subject.not_nil!
    typed_subject.json_unmapped["toolCall"]["rawInput"].as_h["count"] = JSON::Any.new(10_i64)
    changed_input = typed_subject.tool_call.not_nil!.raw_input_raw.not_nil!
    changed_input.field("count").not_nil!.as_i64?.should eq(10)
    changed_input.field("unchanged").not_nil!.json.should eq("[0.9876543210987654321]")
    request.subject = JSON.parse(%({"type":"_replacement","note":true}))
    request.typed_subject.not_nil!.type.should eq("_replacement")

    array_patch = ACP::Protocol::V2::ToolCallUpdate.from_json(%({"toolCallId":"t","rawInput":[{"id":"first","value":0.1234567890123456701},{"id":"second","value":0.1234567890123456702}]}))
    array_patch.raw_input.not_nil!.as_a.shift
    array_patch.raw_input_raw.not_nil!.json.should eq(array_patch.raw_input.not_nil!.to_json)
  end

  it "decodes future subjects and optional command metadata" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      observed = Channel(ACP::Protocol::V2::RequestPermissionParams).new(2)
      client.on_request_permission = ->(request : ACP::Protocol::V2::RequestPermissionParams) do
        observed.send(request)
        ACP::Protocol::V2::RequestPermissionResult.cancelled
      end
      initialize_wide_v2(client, feed, outgoing)
      options = %([{"optionId":"no","name":"No","kind":"reject_once"}])
      command = %({"type":"command","command":"true","cwd":"/work","toolCallId":false,"_meta":{"wide":18446744073709551615}})
      future = %({"type":"_future","payload":18446744073709551615,"precise":0.12345678901234567})
      {command, future}.each_with_index do |subject, index|
        feed.puts %({"jsonrpc":"2.0","id":#{index},"method":"session/request_permission","params":{"sessionId":"s","title":"Review","options":#{options},"subject":#{subject}}})
        reply = JSON.parse(outgoing.gets.not_nil!)
        reply["result"]?.try(&.["outcome"].["outcome"].as_s).should eq("cancelled")
        request = next_permission_event(observed)
        request.subject_raw.not_nil!.json.should eq(subject)
        if details = request.typed_subject.not_nil!.command
          details.cwd.should eq("/work")
          details.tool_call_id.should be_nil
        end
      end
    ensure
      client.try(&.close)
    end
  end

  it "keeps the v1 generic permission handler on representable stdio requests" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::Client.new(transport)
      observed = Channel(JSON::Any).new(1)
      client.on_agent_request = ->(_method : String, params : JSON::Any) do
        observed.send(params)
        JSON.parse(ACP::Protocol::RequestPermissionResult.cancelled.to_json)
      end
      feed.puts %({"jsonrpc":"2.0","id":1,"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"t"},"options":[]}})
      answer = JSON.parse(outgoing.gets.not_nil!)
      answer["result"]?.try(&.["outcome"].["outcome"].as_s).should eq("cancelled")
      next_permission_event(observed)["toolCall"]["toolCallId"].as_s.should eq("t")
    ensure
      client.try(&.close)
    end
  end
end

private class ClosedChannelStdioDiagnostics < IO
  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    raise Channel::ClosedError.new
  end
end

private class PausedStdioDiagnostics < IO
  getter resumed = Channel(Nil).new

  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    @resumed.receive?
  end
end

private def await_stdio_termination(transport : ACP::ProcessTransport) : Nil
  deadline = Time.instant + 2.seconds
  until transport.terminated?
    fail "Agent did not exit" if Time.instant >= deadline
    sleep 10.milliseconds
  end
end

private def await_stdio_exit(transport : ACP::ProcessTransport) : Process::Status
  result = Channel(Process::Status | Exception).new(1)
  spawn do
    result.send(transport.wait)
  rescue ex
    result.send(ex)
  end

  select
  when status = result.receive
    raise status if status.is_a?(Exception)
    status
  when timeout(5.seconds)
    transport.process.terminate(graceful: false) unless transport.terminated?
    fail "Agent did not exit after shutdown"
  end
end

describe "ACP stdio shutdown" do
  it "gives the Agent time to finish EOF cleanup and drains stdout while it exits" do
    script = <<-'SH'
      trap 'exit 95' TERM
      printf '{"ready":true}\n'
      read -r line
      printf '{"cleanup":"%01048576d"}\n' 0 || exit 96
      exit 17
      SH
    transport = ACP::ProcessTransport.new("sh", ["-c", script])
    transport.receive(2.seconds).not_nil!["ready"].as_bool.should be_true

    transport.close
    transport.closed?.should be_true
    transport.receive(10.milliseconds).should be_nil
    status = await_stdio_exit(transport)
    status.exit_signal?.should be_nil
    status.exit_code.should eq(17)
    transport.exit_status.should eq(status)
  ensure
    transport.try(&.close)
  end

  it "reaps an Agent that already exited when close is called" do
    transport = ACP::ProcessTransport.new("sh", ["-c", "exit 23"])
    await_stdio_termination(transport)

    transport.close
    transport.exit_status.not_nil!.exit_code.should eq(23)
  ensure
    transport.try(&.close)
  end

  it "closes an already exited process while its stderr consumer is paused" do
    diagnostics = PausedStdioDiagnostics.new
    transport = ACP::ProcessTransport.new("sh", ["-c", "printf diagnostic >&2; exit 24"], stderr: diagnostics)
    await_stdio_termination(transport)

    closed = Channel(Nil).new
    spawn do
      transport.close
      closed.close
    end
    select
    when closed.receive?
    when timeout(1.second)
      fail "close waited for the stderr consumer"
    end
    transport.process.output.closed?.should be_true

    diagnostics.resumed.close
    await_stdio_exit(transport).exit_code.should eq(24)
  ensure
    diagnostics.try(&.resumed.close)
    transport.try(&.close)
  end

  it "still stops the Agent when its stderr consumer makes wait fail" do
    script = <<-'SH'
      trap 'exit 27' TERM
      printf '{"ready":true}\n'
      read -r line
      printf 'diagnostic\n' >&2
      while :; do sleep 0.05; done
      SH
    transport = ACP::ProcessTransport.new("sh", ["-c", script], stderr: ClosedChannelStdioDiagnostics.new)
    transport.receive(2.seconds).not_nil!["ready"].as_bool.should be_true

    transport.close
    transport.terminated?.should be_true
    error = expect_raises(ACP::TransportError) { await_stdio_exit(transport) }
    error.cause.should be_a(Channel::ClosedError)
    expect_raises(ACP::TransportError) { await_stdio_exit(transport) }.should be(error)
  ensure
    if transport && !transport.terminated?
      transport.process.terminate(graceful: false) rescue nil
    end
    transport.try(&.close)
  end

  it "sends SIGTERM before force-killing an Agent that stays alive" do
    script = <<-'SH'
      trap 'printf "term\n" >&2' TERM
      printf '{"ready":true}\n'
      read -r line
      while :; do sleep 0.05; done
      SH
    diagnostics = IO::Memory.new
    transport = ACP::ProcessTransport.new("sh", ["-c", script], stderr: diagnostics)
    transport.receive(2.seconds).not_nil!["ready"].as_bool.should be_true

    transport.close
    transport.close
    status = await_stdio_exit(transport)
    status.exit_signal?.should eq(Signal::KILL)
    diagnostics.to_s.should eq("term\n")
    transport.wait.should eq(status)
  ensure
    transport.try(&.close)
  end
end

private def next_exact_session_update(channel : Channel(ACP::Protocol::V2::SessionUpdateParams)) : ACP::Protocol::V2::SessionUpdateParams
  select
  when value = channel.receive
    value
  when timeout(2.seconds)
    fail "did not receive the session update"
  end
end

describe "ACP v2 exact session update delivery" do
  it "keeps ordered custom and standard updates with exact extension numbers over stdio" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(2)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "s")

      extension = %({"details":{"fraction":0.1234567890123456789,"empty":null},"sessionUpdate":"_example.test/transcript_marker"})
      terminal = %({"sessionUpdate":"terminal_output_chunk","terminalId":"t","data":"YQ==","_meta":{"example.test/time":0.9876543210987654321}})
      {extension, terminal}.each do |update|
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":#{update}}})
      end

      marker = next_exact_session_update(observed).update
      marker.session_update.should eq("_example.test/transcript_marker")
      marker.typed.should be_nil
      marker.to_json.should contain(%("fraction":0.1234567890123456789))
      marker.to_json.should contain(%("empty":null))

      chunk = next_exact_session_update(observed).update
      chunk.typed.as(ACP::Protocol::V2::TerminalOutputChunk).bytes.should eq("a".to_slice)
      chunk.to_json.should contain(%("example.test/time":0.9876543210987654321))
    ensure
      client.try(&.close)
    end
  end

  it "retains notification metadata and unknown fields at both levels" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(1)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "s")

      meta = %({"example.test/precise":0.3210987654321098765,"example.test/wide":18446744073709551615,"example.test/label":"initial","example.test/empty":null})
      update = %({"sessionUpdate":"future_update","value":[1e1000,18446744073709551616]})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","futureParam":0.4567890123456789123,"_meta":#{meta},"update":#{update}}})

      note = next_exact_session_update(observed)
      note.session_id.should eq("s")
      note.update.typed.should be_nil
      note.raw.field("futureParam").not_nil!.json.should eq("0.4567890123456789123")
      note.meta_raw.not_nil!.json.should eq(meta)
      note.raw.field("update").not_nil!.field("value").not_nil!.json.should eq("[1e1000,18446744073709551616]")

      note.meta.not_nil!["example.test/label"] = JSON::Any.new("edited")
      metadata = note.raw.field("_meta").not_nil!
      metadata.field("example.test/label").not_nil!.as_s?.should eq("edited")
      metadata.field("example.test/precise").not_nil!.json.should eq("0.3210987654321098765")
      metadata.field("example.test/wide").not_nil!.json.should eq("18446744073709551615")
      metadata.field("example.test/empty").not_nil!.null?.should be_true
      note.meta = nil
      note.raw.field("_meta").should be_nil
    ensure
      client.try(&.close)
    end
  end

  it "keeps original JSON for suggestions that pass capability filtering" do
    with_wide_stdio do |transport, feed, outgoing|
      suggestions = ACP::Protocol::PromptSuggestionsCapabilities.new
      caps = ACP::Protocol::V2::ClientCapabilities.new(session: ACP::Protocol::V2::ClientSessionCapabilities.new(prompt_suggestions: suggestions))
      client = ACP::V2::Client.new(transport, capabilities: caps)
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(1)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "s")

      allowed = %({"prompt":[{"type":"text","text":"Keep"}],"futureField":0.4321098765432109876,"_meta":{"example.test/count":18446744073709551615}})
      disallowed = %({"prompt":[{"type":"image","mimeType":"image/png","data":"YQ=="}]})
      ambiguous = %({"prompt":[{"type":"image","mimeType":"image/png","data":"YQ==","type":"text","text":"Ambiguous"}]})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"prompt_suggestions_update","suggestions":[#{allowed},#{disallowed},#{ambiguous}]}}})

      filtered = next_exact_session_update(observed)
      filtered.raw.field("update").not_nil!.field("suggestions").not_nil!.json.should eq("[#{allowed}]")
      filtered.update.json_unmapped["suggestions"].should eq(JSON.parse(%([{"prompt":[{"type":"text","text":"Keep"}]}])))
      surviving = filtered.update.typed.as(ACP::Protocol::V2::PromptSuggestionsUpdate).suggestions
      surviving.map { |suggestion| suggestion.prompt.first["text"].as_s }.should eq(["Keep"])
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP v2 negotiated prompt content" do
  it "blocks an unadvertised custom block before sending a prompt" do
    with_v2_request_client do |client, transport|
      block = JSON.parse(%({"type":"_example.test/diagram","source":"flow"}))
      params = ACP::Protocol::V2::SessionPromptParams.new("session", [block])
      client.prompt_timeout = 0.05

      expect_raises(ACP::InvalidStateError, /custom prompt content/) { client.session_prompt(params) }
      transport.sent_messages.map { |frame| frame["method"].as_s }.should eq(["initialize"])
    end
  end

  it "rejects malformed embedded resources and image payloads even when advertised" do
    with_v2_request_client(%({"prompt":{"embeddedContext":{},"image":{}}})) do |client, transport|
      client.prompt_timeout = 0.05
      invalid = [
        %({"type":"resource","resource":{"uri":"file:///work/notes","value":"unknown"}}),
        %({"type":"resource","resource":{"text":"no URI"}}),
        %({"type":"resource","resource":[1]}),
        %({"type":"resource","resource":{"uri":"/work/not-a-uri","text":"source"}}),
        %({"type":"resource","resource":{"uri":"file:///work/invalid%ZZ","text":"source"}}),
        %({"type":"resource","resource":{"uri":"file:///work/notes","blob":"***"}}),
      ]
      invalid.each do |input|
        params = ACP::Protocol::V2::SessionPromptParams.new("session", [JSON.parse(input)])
        expect_raises(ArgumentError, /embedded resource/) { client.session_prompt(params) }
      end
      malformed_images = [
        %({"type":"image","mimeType":"image/png","data":"YQ="}),
        %({"type":"image","mimeType":"image/png","data":"YQ==","uri":"file:///work/[draft]"}),
      ]
      malformed_images.each do |input|
        params = ACP::Protocol::V2::SessionPromptParams.new("session", [JSON.parse(input)])
        expect_raises(ArgumentError) { client.session_prompt(params) }
      end
      transport.sent_messages.map { |frame| frame["method"].as_s }.should eq(["initialize"])

      spawn do
        request = next_answer(transport)
        transport.inject_raw(%({"jsonrpc":"2.0","id":#{request["id"]},"result":{"messageId":"image"}}))
      end
      image = JSON.parse(%({"type":"image","mimeType":"image/png","data":"YQ==","uri":"https://[2001:db8::1]/a%20b.png#preview"}))
      client.prompt_timeout = 2.0
      client.session_prompt(ACP::Protocol::V2::SessionPromptParams.new("session", [image])).message_id.should eq("image")
    end
  end

  it "keeps baseline and advertised media available beside invalid optional markers" do
    with_v2_request_client(%({"prompt":{"image":true,"audio":{},"embeddedContext":{}}})) do |client, transport|
      image = JSON.parse(%({"type":"image","mimeType":"image/png","data":"YQ=="}))
      future = JSON.parse(%({"type":"future_type","value":"unrecognized"}))
      expect_raises(ACP::InvalidStateError, /image prompts/) do
        client.session_prompt(ACP::Protocol::V2::SessionPromptParams.new("session", [image]))
      end
      expect_raises(ArgumentError, /Unknown ACP v2 prompt content type/) do
        client.session_prompt(ACP::Protocol::V2::SessionPromptParams.new("session", [future]))
      end
      malformed = [
        { %({"type":"audio","mimeType":"audio/wav","data":"YQ="}), /Base64 data/ },
        { %({"type":"audio","mimeType":"audio/wav","data":"!!!!"}), /Base64 data/ },
        { %({"type":"resource_link","name":"notes","uri":"file:///work/with space"}), /absolute URI/ },
        { %({"type":"resource_link","name":"notes","uri":"https://example.test/notes#one#two"}), /absolute URI/ },
        { %({"type":"resource_link","name":"notes","uri":"https://example.test:999999999999999999999/notes"}), /absolute URI/ },
        { %({"type":"resource_link","name":"notes","uri":"https://[draft]/notes"}), /absolute URI/ },
      ]
      malformed.each do |raw, message|
        params = ACP::Protocol::V2::SessionPromptParams.new("session", [JSON.parse(raw)])
        expect_raises(ArgumentError, message) { client.session_prompt(params) }
      end
      transport.sent_messages.size.should eq(1)

      blocks = [
        %({"type":"text","text":"hello"}),
        %({"type":"resource_link","name":"notes","uri":"file:///work/notes"}),
        %({"type":"resource_link","name":"escaped URI","uri":"https://user%5Bname%5D@example.test/file"}),
        %({"type":"audio","mimeType":"audio/wav","data":"YQ=="}),
        %({"type":"resource","resource":{"uri":"file:///work/notes","text":""}}),
        %({"type":"resource","resource":{"uri":"file:///work/data","blob":"YQ=="}}),
      ].map { |raw| JSON.parse(raw) }
      spawn do
        request = next_answer(transport)
        transport.inject_raw(%({"jsonrpc":"2.0","id":#{request["id"]},"result":{"messageId":"m"}}))
      end

      client.session_prompt(ACP::Protocol::V2::SessionPromptParams.new("session", blocks)).message_id.should eq("m")
      transport.sent_messages.last["params"]["prompt"].as_a.should eq(blocks)
    end
  end

  it "uses the current exact Agent advertisement and sends the validated prompt snapshot" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      client.prompt_timeout = 2.0

      first = %({"session":{"mcp":false,"prompt":{"_meta":{"example.test/diagram":{"version":0.1234567890123456789}}}}})
      second = %({"_meta":{"example.test/sequence":18446744073709551615},"session":{"mcp":{"stdio":{},"http":true,"_meta":{"example.test/count":18446744073709551615}},"prompt":{"_meta":{"example.test/diagram":{"version":0.9876543210987654321}}}}})
      auth = %([false,{"type":"agent","methodId":"optional","name":"Sign in","_meta":{"example.test/count":18446744073709551615}}])
      used = Channel(JSON::Any).new(1)
      spawn do
        {first, second}.each_with_index do |advertised, index|
          request = JSON.parse(outgoing.gets.not_nil!)
          methods = index == 0 ? "false" : auth
          feed.puts %({"jsonrpc":"2.0","id":#{request["id"]},"result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":#{advertised},"authMethods":#{methods}}})
        end
        setup = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{setup["id"]},"result":{"sessionId":"session"}})
        request = JSON.parse(outgoing.gets.not_nil!)
        used.send(request)
        feed.puts %({"jsonrpc":"2.0","id":#{request["id"]},"result":{"messageId":"inserted","_meta":{"example.test/sequence":18446744073709551615}}})
      end

      diagram = JSON.parse(%({"type":"_example.test/diagram","source":"hello"}))
      blocks = [diagram]
      observed = [] of String
      client.on_prompt_content_type = ->(kind : String, caps : ACP::Protocol::RawJson) do
        prompt = caps.field("session").not_nil!.field("prompt").not_nil!
        version = prompt.field("_meta").not_nil!.field("example.test/diagram").not_nil!.field("version").not_nil!.json
        observed << version
        sequence = caps.field("_meta").try(&.field("example.test/sequence")).try(&.json)
        if kind == "_example.test/diagram" && sequence == "18446744073709551615"
          blocks[0] = JSON.parse(%({"type":"_example.test/unadvertised"}))
          true
        else
          false
        end
      end

      params = ACP::Protocol::V2::SessionPromptParams.new("session", blocks)
      initial = client.initialize_connection
      initial.capabilities.session.not_nil!.mcp.should be_nil
      initial.auth_methods.should be_empty
      expect_raises(ACP::InvalidStateError, /custom prompt content/) { client.session_prompt(params) }
      renewed = client.initialize_connection
      mcp = renewed.capabilities.session.not_nil!.mcp.not_nil!
      mcp.stdio.should_not be_nil
      mcp.http.should be_nil
      renewed.auth_methods.map(&.method_id).should eq(["optional"])
      client.session_new("/work").session_id.should eq("session")
      client.session_prompt(params).message_id.should eq("inserted")
      select
      when request = used.receive
        request["method"].as_s.should eq("session/prompt")
        request["params"]["prompt"].as_a.should eq([diagram])
      when timeout(2.seconds)
        fail "the validated prompt was not sent"
      end
      observed.should eq(["0.1234567890123456789", "0.9876543210987654321"])
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP v2 resource link icons" do
  it "preserves icons when a typed link is parsed and serialized" do
    input = %({"type":"resource_link","uri":"file:///work/notes","name":"notes","icons":[{"src":"https://example.test/icons/note.png","mimeType":"image/png","sizes":["48x48","any"],"theme":"_night","_meta":{"example.test/revision":0.1234567890123456789}}]})
    link = ACP::Protocol::ContentBlock.from_json(input).as(ACP::Protocol::ResourceLinkContentBlock)

    icon = link.icons.not_nil!.first
    icon.src.should eq("https://example.test/icons/note.png")
    icon.mime_type.should eq("image/png")
    icon.sizes.should eq(["48x48", "any"])
    icon.theme.should eq("_night")
    icon.meta_raw.not_nil!.field("example.test/revision").not_nil!.json.should eq("0.1234567890123456789")
    link.to_json.should contain(%("theme":"_night"))
    link.to_json.should contain(%("example.test/revision":0.1234567890123456789))
  end

  it "keeps wide icon metadata and link sizes through stdio message and tool callbacks" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(5)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "s")

      link = %({"type":"resource_link","uri":"file:///work/notes","name":"notes","size":18446744073709551615,"icons":[{"src":"https://example.test/notes.png","_meta":{"example.test/revision":18446744073709551615}}]})
      skill = %({"type":"skill","name":"notes","_meta":{"example.test/revision":18446744073709551615}})
      outer = %({"example.test/sequence":18446744073709551615,"example.test/label":"event"})
      updates = [
        %({"sessionUpdate":"agent_message_chunk","messageId":"m","content":#{link},"_meta":#{outer}}),
        %({"sessionUpdate":"user_message","messageId":"m2","content":[#{link},#{skill}],"_meta":#{outer}}),
        %({"sessionUpdate":"session_message","messageId":"m3","content":[#{link}],"_meta":#{outer}}),
        %({"sessionUpdate":"tool_call_content_chunk","toolCallId":"t","content":{"type":"content","content":#{link}}}),
      ]
      updates.each do |update|
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":#{update}}})
      end

      chunk = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::MessageChunkUpdate)
      chunk.content["name"].should eq("notes")
      chunk.content_raw.json.should eq(link)
      chunk.meta_raw.not_nil!.json.should eq(outer)
      full = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::MessageUpdate)
      full.content_present?.should be_true
      full.content.not_nil!.map { |item| item["type"].as_s }.should eq(["resource_link", "skill"])
      full.meta_raw.not_nil!.json.should eq(outer)
      full.skill_references.map(&.name).should eq(["notes"])
      session_message = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::SessionMessageUpdate)
      session_message.content.not_nil!.first["name"].should eq("notes")
      session_message.meta_raw.not_nil!.json.should eq(outer)
      tool_chunk = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::ToolCallContentChunk)

      received = [
        chunk.to_content_chunk.not_nil!.content,
        full.content_blocks.not_nil!.first,
        session_message.content_blocks.not_nil!.first,
        tool_chunk.content.content_block.not_nil!,
      ]
      received.each do |value|
        resource = value.as(ACP::Protocol::ResourceLinkContentBlock)
        resource.size.should be_nil
        resource.size_bytes.should eq(UInt64::MAX)
        resource.icons.not_nil!.first.meta_raw.not_nil!.field("example.test/revision").not_nil!.json.should eq(UInt64::MAX.to_s)
      end
    ensure
      client.try(&.close)
    end
  end

  it "keeps usable icon entries when neighboring display fields are malformed" do
    input = %({"type":"resource_link","uri":"file:///work/notes","name":"notes","size":"bad","annotations":{"audience":["user",false,"_reviewer"],"lastModified":42},"icons":[false,{"theme":"light"},{"src":"data:image/png;base64,YQ==","mimeType":{},"sizes":["any",false,"48x48"],"theme":7},{"src":"https://example.test/dark.png","theme":"dark","future":0.9876543210987654321}]})
    link = ACP::Protocol::ContentBlock.from_json(input).as(ACP::Protocol::ResourceLinkContentBlock)

    link.size_bytes.should be_nil
    link.annotations.not_nil!.audience.should eq(["user", "_reviewer"])
    link.annotations.not_nil!.last_modified.should be_nil
    inline_icon, dark_icon = link.icons.not_nil!
    inline_icon.mime_type.should be_nil
    inline_icon.sizes.should eq(["any", "48x48"])
    inline_icon.theme.should be_nil
    dark_icon.theme.should eq("dark")
    dark_icon.to_json.should contain(%("future":0.9876543210987654321))
  end

  it "keeps the legacy signed size and sends builder-created icons in a v2 prompt" do
    legacy = ACP::Protocol::ResourceLinkContentBlock.new("file:///work/old", "old", size: -1_i64)
    legacy.size.should eq(-1_i64)
    legacy.size_bytes.should be_nil
    JSON.parse(legacy.to_json)["size"].as_i64.should eq(-1_i64)
    legacy.size_bytes = UInt64::MAX
    legacy.to_json.should contain(%("size":18446744073709551615))

    with_v2_request_client do |client, transport|
      icon = ACP::Protocol::Icon.new("https://example.test/notes.png", sizes: ["any"], theme: "light")
      blocks = ACP::PromptBuilder.new.resource_link("/work/notes", icons: [icon]).build
      negative = ACP::Protocol::ResourceLinkContentBlock.new("file:///work/notes", "notes", size: -1_i64)
      expect_raises(ArgumentError, /non-negative/) do
        client.session_prompt(ACP::Protocol::V2::SessionPromptParams.new("session", [negative.as(ACP::Protocol::ContentBlock)]))
      end
      ["1.5", %("123"), "true", "18446744073709551616"].each do |size|
        params = ACP::Protocol::V2::SessionPromptParams.from_json(%({"sessionId":"session","prompt":[{"type":"resource_link","uri":"file:///work/notes","name":"notes","size":#{size}}]}))
        expect_raises(ArgumentError, /non-negative UInt64/) { client.session_prompt(params) }
      end
      ambiguous = ACP::Protocol::V2::SessionPromptParams.from_json(%({"sessionId":"session","prompt":[{"type":"image","type":"text","text":"hello"}]}))
      expect_raises(ArgumentError, /unique JSON member names/) { client.session_prompt(ambiguous) }
      transport.sent_messages.size.should eq(1)
      spawn do
        request = next_answer(transport)
        transport.inject_raw(%({"jsonrpc":"2.0","id":#{request["id"]},"result":{"messageId":"m"}}))
      end
      client.session_prompt(ACP::Protocol::V2::SessionPromptParams.new("session", blocks)).message_id.should eq("m")
      transport.sent_messages.last["params"]["prompt"][0]["icons"].as_a.should eq([JSON.parse(icon.to_json)])

      spawn do
        request = next_answer(transport)
        transport.inject_raw(%({"jsonrpc":"2.0","id":#{request["id"]},"result":{"messageId":"zero"}}))
      end
      zero = ACP::Protocol::V2::SessionPromptParams.from_json(%({"sessionId":"session","prompt":[{"type":"resource_link","uri":"file:///work/notes","name":"notes","size":-0}]}))
      client.session_prompt(zero).message_id.should eq("zero")
      transport.sent_messages.last["params"]["prompt"][0]["size"].as_i64.should eq(0)
    end
  end

  it "sends a typed link's wide size and icon metadata on the stdio wire" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      initialize_wide_v2(client, feed, outgoing, session_id: "s")

      icon = ACP::Protocol::Icon.from_json(%({"src":"https://example.test/note.png","_meta":{"example.test/sequence":18446744073709551615,"example.test/revision":0.1234567890123456789}}))
      link = ACP::Protocol::ResourceLinkContentBlock.new("file:///work/notes", "notes", icons: [icon], size_bytes: UInt64::MAX)
      params = ACP::Protocol::V2::SessionPromptParams.new("s", [link.as(ACP::Protocol::ContentBlock)])
      params.prompt.first["name"].should eq("notes")
      requests = Channel(ACP::Protocol::RawJson).new(1)
      spawn do
        request = ACP::Protocol::RawJson.from_json(outgoing.gets.not_nil!)
        requests.send(request)
        id = request.field("id").not_nil!.json
        feed.puts %({"jsonrpc":"2.0","id":#{id},"result":{"messageId":"inserted"}})
      end

      client.session_prompt(params).message_id.should eq("inserted")
      select
      when request = requests.receive
        request.field("method").not_nil!.as_s?.should eq("session/prompt")
        sent = request.field("params").not_nil!.field("prompt").not_nil!
        sent.json.should eq(params.prompt_raw.json)
        payload = sent.elements?.not_nil!.first
        payload.field("size").not_nil!.json.should eq(UInt64::MAX.to_s)
        payload.field("icons").not_nil!.elements?.not_nil!.first.field("_meta").not_nil!.json.should eq(icon.meta_raw.not_nil!.json)
      when timeout(2.seconds)
        fail "the exact prompt did not arrive"
      end
    ensure
      client.try(&.close)
    end
  end

  it "keeps exact fields with the same projected objects after edits and reordering" do
    first = %({"type":"resource_link","uri":"file:///work/notes","name":"notes","size":18446744073709551615})
    second = %({"type":"resource_link","uri":"file:///work/notes","name":"notes","size":18446744073709551614})
    params = ACP::Protocol::V2::SessionPromptParams.from_json(%({"sessionId":"s","prompt":[#{first},#{second}]}))
    params.prompt.first.should eq(params.prompt.last)

    params.prompt.reverse!
    params.prompt_raw.json.should eq("[#{second},#{first}]")
    params.prompt.last.as_h["name"] = JSON::Any.new("edited")
    blocks = params.prompt_raw.elements?.not_nil!
    blocks.first.field("size").not_nil!.json.should eq("18446744073709551614")
    blocks.last.field("size").not_nil!.json.should eq("18446744073709551615")
    blocks.last.field("name").not_nil!.as_s?.should eq("edited")

    params.prompt.shift
    params.prompt_raw.elements?.not_nil!.first.field("size").not_nil!.json.should eq("18446744073709551615")
  end

  it "keeps valid deep icon content and later message blocks" do
    details = "[" * 120 + "0" + "]" * 120
    block = %({"type":"resource_link","uri":"file:///work/notes","name":"notes","icons":[{"src":"https://example.test/notes.png","future":#{details}}]})
    update = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"agent_message","messageId":"m","content":[#{block},{"type":"text","text":"next"}]}))
    blocks = update.typed.as(ACP::Protocol::V2::MessageUpdate).content_blocks.not_nil!
    blocks.size.should eq(2)
    icon = blocks.first.as(ACP::Protocol::ResourceLinkContentBlock).icons.not_nil!.first
    ACP::Protocol::WireFrame.encode(icon).should contain(details)
    blocks.last.as(ACP::Protocol::TextContentBlock).text.should eq("next")
  end
end

describe "ACP v2 open content blocks" do
  it "retains unrecognized blocks between standard blocks in a full message" do
    custom = %({"type":"_example.test/chart","series":[18446744073709551615,0.1234567890123456789],"empty":null})
    future = %({"type":"future_content","opaque":{"nested":true}})
    update = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"agent_message","messageId":"m","content":[{"type":"text","text":"before"},#{custom},{"type":"image","mimeType":"image/png"},#{future},{"type":"text","text":"after"}]}))
    blocks = update.typed.as(ACP::Protocol::V2::MessageUpdate).content_blocks.not_nil!
    blocks.map(&.type).should eq(["text", "_example.test/chart", "future_content", "text"])
    extension = blocks[1].as(ACP::Protocol::UnknownContentBlock)
    extension.custom?.should be_true
    extension.raw.json.should eq(custom)
    extension.to_json.should eq(custom)
    reserved = blocks[2].as(ACP::Protocol::UnknownContentBlock)
    reserved.custom?.should be_false
    ACP::Protocol::UnknownContentBlock.from_json(future).raw.json.should eq(future)
  end

  it "converts an open message chunk and tool result without narrowing their payload" do
    block = %({"type":"_example.test/chart","value":18446744073709551615})
    meta = %({"example.test/large":18446744073709551615,"example.test/precise":0.1234567890123456789})
    message = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"agent_message_chunk","messageId":"m","content":#{block},"_meta":#{meta}}))
    chunk = message.typed.as(ACP::Protocol::V2::MessageChunkUpdate).to_content_chunk.not_nil!
    chunk.content.to_json.should eq(block)
    chunk.to_json.should contain(%("_meta":#{meta}))
    restored = ACP::Protocol::ContentChunk.from_v2_json(chunk.to_json)
    restored.message_id.should eq("m")
    restored.content.to_json.should eq(block)
    restored.meta_raw.not_nil!.json.should eq(meta)
    expect_raises(JSON::ParseException) { ACP::Protocol::ContentChunk.from_json(chunk.to_json) }

    tool = ACP::Protocol::V2::ToolCallContent.from_json(%({"type":"content","content":#{block}}))
    tool.content_block.not_nil!.to_json.should eq(block)
  end

  it "validates the fallback envelope and handles malformed known types without falling back" do
    [
      "[]",
      %({"payload":true}),
      %({"type":42}),
      %({"type":"image","mimeType":"image/png"}),
      %({"type":"image","type":"future_content","mimeType":"image/png"}),
      %({"type":"skill","name":42}),
      %({"type":"resource","resource":{"uri":"file:///work/no-body"}}),
    ].each do |invalid|
      expect_raises(JSON::ParseException) { ACP::Protocol::ContentBlock.from_v2_json(invalid) }
    end
    expect_raises(JSON::ParseException) { ACP::Protocol::UnknownContentBlock.from_json(%({"type":"text","text":"known"})) }
    expect_raises(JSON::ParseException) { ACP::Protocol::ContentBlock.from_json(%({"type":"future_content","name":"open only in v2"})) }

    block = ACP::Protocol::ContentBlock.from_v2_json(%({"type":"text","text":"standard","_meta":{"example.test/sequence":18446744073709551615}}))
    typed = block.as(ACP::Protocol::TextContentBlock)
    typed.text.should eq("standard")
    typed.meta_raw.not_nil!.field("example.test/sequence").not_nil!.json.should eq(UInt64::MAX.to_s)
  end

  it "ignores ambiguous skill references in user messages and chunks" do
    ambiguous_type = %({"type":"other","type":"skill","name":"ambiguous"})
    ambiguous_name = %({"type":"skill","name":"ambiguous","name":"duplicate"})
    valid = %({"type":"skill","name":"notes"})
    full = ACP::Protocol::V2::MessageUpdate.from_json(%({"sessionUpdate":"user_message","messageId":"m","content":[#{ambiguous_type},#{valid},#{ambiguous_name}]}))
    full.skill_references.map(&.name).should eq(["notes"])
    [ambiguous_type, ambiguous_name].each do |block|
      wire = %({"sessionUpdate":"user_message_chunk","messageId":"m","content":#{block}})
      expect_raises(JSON::ParseException) { ACP::Protocol::V2::MessageChunkUpdate.from_json(wire) }
      ACP::Protocol::V2::SessionUpdate.from_json(wire).typed.should be_nil
    end
  end

  it "keeps display blocks and the surrounding metadata in stdio callbacks" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(4)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "s")

      custom = %({"type":"future_content","empty":null,"value":18446744073709551615})
      decimals = %({"example.test/precise":0.1234567890123456789})
      resource = %({"type":"resource","resource":{"uri":"file:///work/notes","text":"body","_meta":{"example.test/sequence":18446744073709551615}}})
      outer = %({"example.test/count":18446744073709551615,"example.test/label":"compacted"})
      updates = [
        %({"sessionUpdate":"session_message","messageId":"m","content":[#{custom},#{resource}]}),
        %({"sessionUpdate":"compaction_update","compactionId":"c","summary":[#{custom},#{resource}],"_meta":#{outer}}),
        %({"sessionUpdate":"compaction_summary_chunk","compactionId":"c","content":#{custom},"_meta":#{decimals}}),
        %({"sessionUpdate":"tool_call_content_chunk","toolCallId":"t","content":{"type":"content","content":#{custom}}}),
      ]
      updates.each do |update|
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":#{update}}})
      end

      message = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::SessionMessageUpdate)
      content = message.content_blocks.not_nil!
      content.first.as(ACP::Protocol::UnknownContentBlock).raw.json.should eq(custom)
      embedded = content.last.as(ACP::Protocol::ResourceContentBlock)
      embedded.text.should eq("body")
      embedded.resource_raw.field("_meta").not_nil!.field("example.test/sequence").not_nil!.json.should eq(UInt64::MAX.to_s)

      compaction = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::CompactionUpdate)
      compaction.summary_present?.should be_true
      compaction.meta_raw.not_nil!.json.should eq(outer)
      compaction.typed_summary.not_nil!.map(&.type).should eq(["future_content", "resource"])
      compaction.typed_summary.not_nil!.first.to_json.should eq(custom)

      chunk = next_exact_session_update(observed).update.typed.as(ACP::Protocol::CompactionSummaryChunkUpdate)
      chunk.meta_raw.not_nil!.json.should eq(decimals)
      restored = ACP::Protocol::ContentChunk.from_v2_json(chunk.to_content_chunk.not_nil!.to_json)
      restored.message_id.should be_nil
      restored.content.to_json.should eq(custom)
      restored.meta_raw.not_nil!.json.should eq(decimals)
      tool = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::ToolCallContentChunk)
      tool.content.content_block.not_nil!.to_json.should eq(custom)
    ensure
      client.try(&.close)
    end
  end

  it "distinguishes compaction summary omission, clear, and replacement" do
    compact = ACP::Protocol::V2::CompactionUpdate.from_json(%({"compactionId":"c"}))
    compact.summary_present?.should be_false
    compact.typed_summary.should be_nil

    cleared = ACP::Protocol::V2::CompactionUpdate.from_json(%({"compactionId":"c","summary":null}))
    cleared.summary_present?.should be_true
    cleared.typed_summary.should be_nil
    cleared.to_json.should contain(%("summary":null))

    malformed = ACP::Protocol::V2::CompactionUpdate.from_json(%({"compactionId":"c","summary":false,"status":"running"}))
    malformed.summary_present?.should be_false
    malformed.to_json.should_not contain(%("summary"))
    compact.summary = [] of JSON::Any
    compact.summary_present?.should be_true
    compact.typed_summary.should eq([] of ACP::Protocol::ContentBlock)
  end
end

describe "ACP v2 exact upsert metadata" do
  it "keeps typed terminal, session info, and usage updates when metadata exceeds JSON::Any" do
    wide = %({"example.test/sequence":18446744073709551615})
    updates = [
      %({"sessionUpdate":"terminal_update","terminalId":"t","command":"build","_meta":#{wide}}),
      %({"sessionUpdate":"terminal_output_chunk","terminalId":"t","data":"AP9B","_meta":#{wide}}),
      %({"sessionUpdate":"session_info_update","title":"Demo","_meta":#{wide}}),
      %({"sessionUpdate":"usage_update","used":4,"size":8,"_meta":#{wide}}),
      %({"sessionUpdate":"subagent_update","sessionId":"child","_meta":#{wide}}),
      %({"sessionUpdate":"user_message","messageId":"m","_meta":#{wide}}),
      %({"sessionUpdate":"agent_message","messageId":"m","_meta":#{wide}}),
      %({"sessionUpdate":"agent_thought","messageId":"m","_meta":#{wide}}),
      %({"sessionUpdate":"session_message","messageId":"m","_meta":#{wide}}),
      %({"sessionUpdate":"tool_call_update","toolCallId":"call","_meta":#{wide}}),
      %({"sessionUpdate":"compaction_update","compactionId":"compact","_meta":#{wide}}),
    ]

    updates.each do |wire|
      update = ACP::Protocol::V2::SessionUpdate.from_json(wire)
      typed = update.typed.not_nil!
      ACP::Protocol::RawJson.from_json(typed.to_json).field("_meta").not_nil!.json.should eq(wide)
    end
  end

  it "applies exact metadata by key, handling omission, clears, and nested replacements" do
    previous = ACP::Protocol::RawJson.from_json(%({"example.test/keep":18446744073709551615,"example.test/replace":{"old":true},"example.test/remove":true}))
    wire = %({"terminalId":"t","_meta":{"example.test/replace":{"value":0.1234567890123456789,"nested":null},"example.test/remove":null,"example.test/added":-9223372036854775809}})
    update = ACP::Protocol::V2::TerminalUpdate.from_json(wire)
    result = update.apply_metadata_raw(previous).not_nil!
    result.field("example.test/keep").not_nil!.json.should eq(UInt64::MAX.to_s)
    result.field("example.test/replace").not_nil!.json.should eq(%({"value":0.1234567890123456789,"nested":null}))
    result.field("example.test/remove").should be_nil
    result.field("example.test/added").not_nil!.json.should eq("-9223372036854775809")
    previous.field("example.test/remove").not_nil!.json.should eq("true")

    ["", %(,"_meta":false), %(,"_meta":18446744073709551615)].each do |field|
      ignored = ACP::Protocol::V2::TerminalUpdate.from_json(%({"terminalId":"t"#{field}}))
      ignored.meta_present?.should be_false
      ignored.apply_metadata_raw(previous).should eq(previous)
      ignored.to_json.should_not contain(%("_meta"))
    end

    empty = ACP::Protocol::V2::TerminalUpdate.from_json(%({"terminalId":"t","_meta":{}}))
    empty.meta_present?.should be_true
    empty.apply_metadata_raw(previous).should eq(previous)
    empty.apply_metadata_raw(nil).should be_nil

    clear = ACP::Protocol::V2::TerminalUpdate.new("t")
    clear.meta = nil
    clear.meta_present?.should be_true
    clear.to_json.should contain(%("_meta":null))
    clear.apply_metadata_raw(previous).should be_nil

    remove_only = ACP::Protocol::V2::TerminalUpdate.from_json(%({"terminalId":"t","_meta":{"only":null}}))
    remove_only.apply_metadata_raw(ACP::Protocol::RawJson.from_json(%({"only":true}))).should be_nil

    update.meta.not_nil!["example.test/label"] = JSON::Any.new("edited")
    edited = update.apply_metadata_raw(previous).not_nil!
    edited.field("example.test/label").not_nil!.as_s?.should eq("edited")
    edited.field("example.test/added").not_nil!.json.should eq("-9223372036854775809")
  end

  it "delivers exact nested metadata and child announcements through the stdio client" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(5)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "root")

      meta = %({"example.test/sequence":18446744073709551615,"example.test/precision":0.1234567890123456789})
      updates = [
        %({"sessionUpdate":"terminal_update","terminalId":"t","output":{"data":"AP9B","_meta":#{meta}},"exitStatus":{"exitCode":-9,"_meta":#{meta}},"size":{"cols":80,"rows":24,"_meta":#{meta}},"capabilities":{"cancel":{"_meta":#{meta}},"_meta":#{meta}},"_meta":#{meta}}),
        %({"sessionUpdate":"terminal_output_chunk","terminalId":"t","data":"AAE=","_meta":#{meta}}),
        %({"sessionUpdate":"subagent_update","sessionId":"child","title":"Child","capabilities":{"cancel":{"_meta":#{meta}},"_meta":#{meta}},"_meta":#{meta}}),
        %({"sessionUpdate":"session_info_update","title":"Demo","_meta":#{meta}}),
        %({"sessionUpdate":"usage_update","used":9223372036854775808,"size":18446744073709551615,"cost":{"amount":0.5,"currency":"USD","_meta":#{meta}},"_meta":#{meta}}),
      ]
      updates.each do |update|
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":#{update}}})
      end

      terminal = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::TerminalUpdate)
      terminal.output.not_nil!.bytes.should eq(Bytes[0, 255, 65])
      terminal.exit_status.not_nil!.exit_code.should eq(-9_i64)
      terminal.size.not_nil!.cols.should eq(80_u16)
      terminal.output.not_nil!.meta_raw.not_nil!.json.should eq(meta)
      terminal.size.not_nil!.meta_raw.not_nil!.json.should eq(meta)
      terminal.exit_status.not_nil!.meta_raw.not_nil!.json.should eq(meta)
      terminal.capabilities.not_nil!.meta_raw.not_nil!.json.should eq(meta)
      terminal.capabilities.not_nil!.cancel.not_nil!.meta_raw.not_nil!.json.should eq(meta)
      terminal.meta_raw.not_nil!.json.should eq(meta)
      chunk = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::TerminalOutputChunk)
      chunk.bytes.should eq(Bytes[0, 1])
      chunk.meta_raw.not_nil!.json.should eq(meta)

      child = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::SubagentUpdate)
      child.session_id.should eq("child")
      child.meta_raw.not_nil!.json.should eq(meta)
      child.capabilities.not_nil!.meta_raw.not_nil!.json.should eq(meta)
      child.capabilities.not_nil!.cancel.not_nil!.meta_raw.not_nil!.json.should eq(meta)
      registered_child = client.subagent("child").not_nil!
      registered_child.title.should eq("Child")
      registered_child.cancel?.should be_true

      info = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::SessionInfoUpdate)
      info.title.should eq("Demo")
      info.meta_raw.not_nil!.json.should eq(meta)

      usage = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::UsageUpdate)
      usage.used.should eq(9223372036854775808_u64)
      usage.size.should eq(UInt64::MAX)
      usage.cost.not_nil!.currency.should eq("USD")
      usage.cost.not_nil!.meta_raw.not_nil!.json.should eq(meta)
      usage.meta_raw.not_nil!.json.should eq(meta)
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP v1 plan notifications" do
  it "delivers exact plan metadata and the remaining checklist after skipping invalid entries" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::Client.new(transport)
      client.request_timeout = 2.0
      answer_identity_request(feed, outgoing, %({"protocolVersion":1}))
      client.initialize_connection
      updates = Channel(ACP::Protocol::PlanUpdate).new(1)
      client.on_update = ->(note : ACP::Protocol::SessionUpdateParams) do
        updates.send(note.update.as(ACP::Protocol::PlanUpdate))
        nil
      end
      metadata = %({"example.test/count":18446744073709551615,"example.test/ratio":0.123456789012345678901})
      entries = %([{"content":"Draft","priority":"medium","status":"completed","_meta":#{metadata}},false,{"content":"Review","priority":"high","status":"pending"}])
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"plan","entries":#{entries},"_meta":#{metadata}}}})
      answer_identity_request(feed, outgoing, "{}")
      client.ext_method("barrier")
      select
      when plan = updates.receive
        plan.entries.map(&.content).should eq(["Draft", "Review"])
        plan.entries.first.meta_raw.not_nil!.json.should eq(metadata)
        plan.meta_raw.not_nil!.json.should eq(metadata)
        ACP::Protocol::RawJson.from_json(plan.to_json).field("_meta").not_nil!.json.should eq(metadata)
      else
        fail "the plan did not reach the typed callback"
      end
    ensure
      client.try(&.close)
    end
  end

  it "defaults an invalid entries collection on a v1 plan to an empty checklist" do
    plan = ACP::Protocol::PlanUpdate.from_json(%({"sessionUpdate":"plan","entries":false}))
    plan.entries.should be_empty
  end

  it "rejects ambiguous checklist fields and plan identities" do
    [
      %({"sessionUpdate":"plan","entries":[],"entries":[]}),
      %({"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p","entries":[],"entries":[]}}),
      %({"sessionUpdate":"plan_update","plan":{"type":"items","type":"items","planId":"p","entries":[]}}),
      %({"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p","planId":"q","entries":[]}}),
      %({"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p","entries":[]},"plan":{"type":"items","planId":"q","entries":[]}}),
      %({"sessionUpdate":"plan_removed","planId":"p","planId":"q"}),
    ].each do |wire|
      expect_raises(JSON::ParseException) { ACP::Protocol::SessionUpdate.from_json(wire) }
    end
  end

  it "decodes identified plans with metadata at the transport's nesting limit" do
    nested = "[" * 110 + "18446744073709551615" + "]" * 110
    metadata = %({"example.test/nested":#{nested}})
    wire = %({"sessionUpdate":"plan_update","plan":{"type":"markdown","planId":"p","content":"# Plan","_meta":#{metadata}}})
    update = ACP::Protocol::SessionUpdate.from_json(wire).as(ACP::Protocol::IdentifiedPlanUpdate)
    plan = update.plan.as(ACP::Protocol::PlanMarkdown)
    plan.content.should eq("# Plan")
    plan.meta_raw.not_nil!.json.should eq(metadata)
  end
end

describe "ACP v2 identified plan updates" do
  it "skips invalid checklist entries while retaining valid open statuses in order" do
    update = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p","entries":[{"content":"first","priority":"high","status":"cancelled"},false,{"content":"missing status","priority":"low"},{"content":"wrong type","priority":1,"status":"pending"},{"content":"null priority","priority":null,"status":"pending"},{"content":"null status","priority":"low","status":null},{"content":"last","priority":"future","status":"_queued"}]}}))
    plan = update.typed.as(ACP::Protocol::V2::PlanUpdate).plan.typed.as(ACP::Protocol::PlanItems)

    plan.entries.map(&.content).should eq(["first", "last"])
    plan.entries.map(&.priority).should eq(["high", "future"])
    plan.entries.map(&.status).should eq(["cancelled", "_queued"])
  end

  it "keeps open replacements with wide fields and rejects malformed known plans" do
    wire = %({"sessionUpdate":"plan_update","plan":{"type":"future","planId":"p","nodes":[18446744073709551615],"precision":0.1234567890123456789}})
    plan = ACP::Protocol::V2::SessionUpdate.from_json(wire).typed.as(ACP::Protocol::V2::PlanUpdate).plan
    plan.plan_id.should eq("p")
    plan.typed.should be_nil
    plan.raw.field("nodes").not_nil!.elements?.not_nil!.first.json.should eq(UInt64::MAX.to_s)
    plan.raw.field("precision").not_nil!.json.should eq("0.1234567890123456789")
    [
      %({"type":"items","planId":"p"}),
      %({"type":"items","planId":"p","entries":{}}),
      %({"type":"markdown","planId":"p","content":false}),
      %({"type":"items","type":"future","planId":"p"}),
      %({"type":"future","planId":"first","planId":"last"}),
    ].each do |plan|
      update = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"plan_update","plan":#{plan}}))
      update.typed.should be_nil
    end
  end

  it "preserves plan and entry metadata and exposes only absolute Markdown paths" do
    meta = %({"example.test/wide":18446744073709551615,"example.test/precision":0.1234567890123456789})
    plan = %({"type":"items","planId":"p","entries":[{"content":"step","priority":"medium","status":"pending","_meta":#{meta}}],"_meta":#{meta}})
    wire = %({"sessionUpdate":"plan_update","plan":#{plan},"_meta":#{meta}})
    update = ACP::Protocol::V2::SessionUpdate.from_json(wire).typed.as(ACP::Protocol::V2::PlanUpdate)
    update.meta_raw.not_nil!.json.should eq(meta)
    update.plan.meta_raw.not_nil!.json.should eq(meta)
    items = update.plan.typed.as(ACP::Protocol::PlanItems)
    items.meta_raw.not_nil!.json.should eq(meta)
    items.entries.first.meta_raw.not_nil!.json.should eq(meta)

    [
      {"/work/PLAN.md".to_json, "/work/PLAN.md"},
      {"C:/work/PLAN.md".to_json, "C:/work/PLAN.md"},
      {"PLAN.md".to_json, nil},
      {"false", nil},
    ].each do |path_json, expected|
      wire = %({"sessionUpdate":"plan_update","plan":{"type":"markdown","planId":"p","content":"# New plan","path":#{path_json}}})
      markdown = ACP::Protocol::V2::SessionUpdate.from_json(wire).typed.as(ACP::Protocol::V2::PlanUpdate).plan.typed.as(ACP::Protocol::PlanMarkdown)
      markdown.content.should eq("# New plan")
      markdown.path.should eq(expected)
    end

    removal = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"plan_removed","planId":"p","_meta":#{meta}})).typed.as(ACP::Protocol::PlanRemovedUpdate)
    removal.meta_raw.not_nil!.json.should eq(meta)
  end

  it "ignores unknown removals and tracks repeated replacements by session before callbacks" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(12)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "a")

      invalid = %({"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p","entries":null}})
      items = %({"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p","entries":[]}})
      open_plan = %({"sessionUpdate":"plan_update","plan":{"type":"_graph","planId":"p","nodes":[18446744073709551615]}})
      removal = %({"sessionUpdate":"plan_removed","planId":"p"})
      ambiguous = %({"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p","entries":[]},"plan":{"type":"future","planId":"p"}})
      [{"a", removal}, {"a", invalid}, {"a", ambiguous}, {"a", removal}, {"a", items},
       {"b", items}, {"b", removal}, {"a", open_plan}, {"a", removal}, {"a", removal},
       {"a", %({"sessionUpdate":"_barrier"})}].each do |sid, update|
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":#{sid.to_json},"update":#{update}}})
      end

      delivered = [] of ACP::Protocol::V2::SessionUpdateParams
      loop do
        note = next_exact_session_update(observed)
        break if note.update.session_update == "_barrier"
        delivered << note
      end
      delivered.map { |note| {note.session_id, note.update.session_update} }.should eq([
        {"a", "plan_update"}, {"a", "plan_update"}, {"a", "plan_removed"},
      ])
    ensure
      client.try(&.close)
    end
  end

  it "filters the raw callback and drops remembered plans when a session is closed" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s"})
    transport.replies["session/close"] = %("result":{})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")

    observed = [] of String
    client.on_notification = ->(method : String, params : JSON::Any?) do
      observed << params.not_nil!["update"]["sessionUpdate"].as_s if method == "session/update"
      nil
    end
    removal = %({"sessionUpdate":"plan_removed","planId":"p"})
    transport.update("s", removal)
    transport.update("s", %({"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p","entries":[]}}))
    client.session_close("s")
    transport.update("s", %({"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p","entries":[]}}))
    transport.update("s", removal)
    choice_state_barrier(client, transport)
    observed.should eq(["plan_update"])
  ensure
    client.try(&.close)
  end

  it "keeps replayed plans when an older close reply arrives before the new resume reply" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s"})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")
    next_answer(transport)
    next_answer(transport)

    observed = [] of String
    client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
      observed << note.update.session_update
      nil
    end

    closed = Channel(Nil).new(1)
    spawn do
      client.session_close("s")
      closed.send(nil)
    end
    close = next_answer(transport)
    close["method"].as_s.should eq("session/close")

    resumed = Channel(Nil).new(1)
    spawn do
      params = ACP::Protocol::V2::SessionResumeParams.new("s", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start)
      client.session_resume(params)
      resumed.send(nil)
    end
    resume_call = next_answer(transport)
    resume_call["method"].as_s.should eq("session/resume")

    transport.update("s", %({"sessionUpdate":"plan_update","plan":{"type":"items","planId":"replayed","entries":[]}}))
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{close["id"]},"result":{}}))
    transport.update("s", %({"sessionUpdate":"replay_complete"}))
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{resume_call["id"]},"result":{}}))
    transport.update("s", %({"sessionUpdate":"plan_removed","planId":"replayed"}))
    choice_state_barrier(client, transport)

    observed.should eq(["plan_update", "replay_complete", "plan_removed"])
    select
    when closed.receive
    when timeout(2.seconds)
      fail "close result was not delivered"
    end
    select
    when resumed.receive
    when timeout(2.seconds)
      fail "resume result was not delivered"
    end
  ensure
    client.try(&.close)
  end

  it "ignores raw-only removals for plans that cannot be delivered as JSON::Any" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      observed = Channel(String).new(6)
      client.on_notification = ->(method : String, params : JSON::Any?) do
        observed.send(params.not_nil!["update"]["sessionUpdate"].as_s) if method == "session/update"
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "s")

      [
        %({"sessionUpdate":"plan_update","plan":{"type":"future","planId":"wide","number":18446744073709551615}}),
        %({"sessionUpdate":"plan_removed","planId":"wide"}),
        %({"sessionUpdate":"plan_update","plan":{"type":"items","planId":"known","entries":[]}}),
        %({"sessionUpdate":"plan_removed","planId":"known"}),
        %({"sessionUpdate":"_barrier"}),
      ].each do |update|
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":#{update}}})
      end

      delivered = [] of String
      loop do
        select
        when kind = observed.receive
          break if kind == "_barrier"
          delivered << kind
        when timeout(2.seconds)
          fail "plan notifications did not reach the generic handler"
        end
      end
      delivered.should eq(["plan_update", "plan_removed"])
    ensure
      client.try(&.close)
    end
  end

  it "adopts early plans only for the session confirmed by the setup response" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/new"] = %("result":{"sessionId":"confirmed"})
    plan = %({"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p","entries":[]}})
    removal = %({"sessionUpdate":"plan_removed","planId":"p"})
    transport.before_reply = ->(method : String, _request : Hash(String, JSON::Any)) do
      if method == "session/new"
        transport.update("confirmed", plan)
        transport.update("unconfirmed", plan)
      end
      nil
    end
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection

    observed = [] of Tuple(String, String)
    client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
      observed << {note.session_id, note.update.session_update}
      nil
    end

    client.session_new("/work")
    transport.update("confirmed", removal)
    transport.update("unconfirmed", removal)
    choice_state_barrier(client, transport)
    observed.should eq([
      {"confirmed", "plan_update"}, {"unconfirmed", "plan_update"}, {"confirmed", "plan_removed"},
    ])
  ensure
    client.try(&.close)
  end

  it "bounds provisional plan IDs and keeps active sessions unrestricted" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s"})
    large_id = "p" * (64 * 1024)
    large_plan = %({"sessionUpdate":"plan_update","plan":{"type":"items","planId":#{large_id.to_json},"entries":[]}})
    transport.before_reply = ->(method : String, _request : Hash(String, JSON::Any)) do
      if method == "session/new"
        transport.update("s", large_plan)
        66.times do |index|
          plan = %({"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p#{index}","entries":[]}})
          transport.update("s", plan)
        end
      end
      nil
    end
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection

    seen = [] of String
    client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
      if plan = note.update.typed.as?(ACP::Protocol::V2::PlanUpdate)
        seen << plan.plan.plan_id
      end
      nil
    end

    client.session_new("/work")
    seen.should eq(Array.new(64) { |index| "p#{index}" })
    transport.update("s", large_plan)
    choice_state_barrier(client, transport)
    seen.last.should eq(large_id)
  ensure
    client.try(&.close)
  end
end

describe "ACP exact notices and replay completion" do
  it "keeps valid notices with wide metadata and tolerates a malformed optional description" do
    wire = %({"sessionUpdate":"notice","severity":"future_severity","title":"History gap","description":{"unexpected":true},"_meta":{"example.test/count":18446744073709551615}})
    notice = ACP::Protocol::V2::SessionUpdate.from_json(wire).typed.as(ACP::Protocol::NoticeUpdate)
    notice.severity.should eq("future_severity")
    notice.title.should eq("History gap")
    notice.description.should be_nil
    notice.to_json.should contain(%("example.test/count":18446744073709551615))
    notice.meta_raw.not_nil!.field("example.test/count").not_nil!.json.should eq(UInt64::MAX.to_s)
    malformed_meta = ACP::Protocol::NoticeUpdate.from_json(%({"sessionUpdate":"notice","severity":"info","title":"Hello","_meta":true}))
    malformed_meta.meta_raw.should be_nil

    shared = ACP::Protocol::NoticeUpdate.from_json(wire)
    shared.title.should eq("History gap")
    shared.description.should be_nil
    shared.to_json.should contain(%("example.test/count":18446744073709551615))
  end

  it "rejects malformed required notice fields while preserving the raw update" do
    [
      %("title":""),
      %("title":null),
      %("title":false),
      %("description":"optional"),
    ].each do |fields|
      update = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"notice","severity":"warning",#{fields}}))
      update.typed.should be_nil
      update.to_json.should contain(fields)
    end
  end

  it "retains exact replay metadata and ignores malformed optional metadata" do
    meta = %({"example.test/count":18446744073709551615,"example.test/precision":0.1234567890123456789})
    update = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"replay_complete","_meta":#{meta}}))
    marker = update.typed.as(ACP::Protocol::V2::ReplayCompleteUpdate)
    marker.meta_raw.not_nil!.json.should eq(meta)
    copy = ACP::Protocol::V2::ReplayCompleteUpdate.from_json(marker.to_json)
    copy.meta_raw.not_nil!.json.should eq(meta)

    ["null", "false", "[42]"].each do |invalid|
      update = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"replay_complete","_meta":#{invalid}}))
      update.typed.as(ACP::Protocol::V2::ReplayCompleteUpdate).meta_raw.should be_nil
    end
  end

  it "delivers exact notices and per-session replay markers in stdio order" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(8)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "root")
      resume = Channel(ACP::Protocol::V2::SessionResumeResult | Exception).new(1)
      spawn do
        params = ACP::Protocol::V2::SessionResumeParams.new("root", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start)
        resume.send(client.session_resume(params))
      rescue ex
        resume.send(ex)
      end
      request = JSON.parse(outgoing.gets.not_nil!)
      request["method"].as_s.should eq("session/resume")

      send_update = ->(sid : String, body : String) do
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":#{sid.to_json},"update":#{body}}})
        nil
      end
      meta = %({"example.test/count":18446744073709551615,"example.test/precision":0.1234567890123456789})
      send_update.call("root", %({"sessionUpdate":"notice","severity":"error","title":"In-flight live notice","_meta":#{meta}}))
      notice = next_exact_session_update(observed).update.typed.as(ACP::Protocol::NoticeUpdate)
      notice.title.should eq("In-flight live notice")
      notice.to_json.should contain(%("_meta":#{meta}))
      client.session_state("root").not_nil!.state.should eq("idle")

      send_update.call("root", %({"sessionUpdate":"subagent_update","sessionId":"child"}))
      next_exact_session_update(observed).update.session_update.should eq("subagent_update")
      send_update.call("root", %({"sessionUpdate":"cursor_update","cursorId":"r"}))
      next_exact_session_update(observed).update.session_update.should eq("cursor_update")
      send_update.call("child", %({"sessionUpdate":"cursor_update","cursorId":"c"}))
      next_exact_session_update(observed).update.session_update.should eq("cursor_update")

      client.session_cursor("root", "r").should be_nil
      client.session_cursor("child", "c").should be_nil
      marker = %({"sessionUpdate":"replay_complete","_meta":#{meta}})
      send_update.call("child", marker)
      child = next_exact_session_update(observed)
      child.session_id.should eq("child")
      child.update.typed.as(ACP::Protocol::V2::ReplayCompleteUpdate).to_json.should contain(%("_meta":#{meta}))
      client.session_cursor("child", "c").should_not be_nil
      client.session_cursor("root", "r").should be_nil

      send_update.call("root", marker)
      root = next_exact_session_update(observed)
      root.session_id.should eq("root")
      root.update.typed.as(ACP::Protocol::V2::ReplayCompleteUpdate).to_json.should contain(%("_meta":#{meta}))
      client.session_cursor("root", "r").should_not be_nil
      send_update.call("root", %({"sessionUpdate":"notice","severity":"info","title":"Live after replay"}))
      next_exact_session_update(observed).update.typed.as(ACP::Protocol::NoticeUpdate).title.should eq("Live after replay")

      feed.puts %({"jsonrpc":"2.0","id":#{request["id"]},"result":{}})
      select
      when result = resume.receive
        result.should be_a(ACP::Protocol::V2::SessionResumeResult)
      when timeout(2.seconds)
        fail "resume response did not arrive"
      end
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP replay write boundaries" do
  it "keeps live v2 cursors and session choices while a resume is queued and then rejected" do
    transport = QueuedChoiceStateTransport.new("session/resume")
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{}}})
    initial = choice_state_option("configId", "fast", ["fast", "large"])
    changed = choice_state_option("configId", "large", ["fast", "large"])
    transport.replies["session/new"] = %("result":{"sessionId":"s","configOptions":[#{initial}],"availableCommands":[]})
    transport.replies["session/resume"] = %("error":{"code":-32602,"message":"Replay unavailable"})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")

    result = Channel(ACP::Protocol::V2::SessionResumeResult | Exception).new(1)
    spawn do
      params = ACP::Protocol::V2::SessionResumeParams.new("s", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start)
      result.send(client.session_resume(params))
    rescue ex
      result.send(ex)
    end
    select
    when transport.queued.receive
    when timeout(2.seconds)
      fail "resume did not reach the transport queue"
    end

    transport.update("s", %({"sessionUpdate":"user_message","messageId":"m","content":[{"type":"text","text":"Live"}]}))
    transport.update("s", %({"sessionUpdate":"cursor_update","cursorId":"live","anchor":{"type":"user_message","messageId":"m","position":"after"}}))
    transport.update("s", %({"sessionUpdate":"config_option_update","configOptions":[#{changed}]}))
    transport.update("s", %({"sessionUpdate":"available_commands_update","availableCommands":[{"type":"command","name":"status","description":"Status"}]}))
    choice_state_barrier(client, transport)
    transport.sent_messages.none? { |message| message["method"]?.try(&.as_s?) == "session/resume" }.should be_true
    read_live = -> do
      {!client.session_cursor("s", "live").nil?, client.session_config_options_raw("s").try(&.json),
       client.session_available_commands("s").try(&.map(&.name))}
    end
    read_live.call.should eq({true, "[#{ACP::Protocol::RawJson.from_json(changed).json}]", ["status"]})

    transport.write.send(nil)
    select
    when outcome = result.receive
      outcome.as(ACP::JsonRpcError).code.should eq(-32602)
    when timeout(2.seconds)
      fail "resume rejection was not delivered"
    end
    read_live.call.should eq({true, "[#{ACP::Protocol::RawJson.from_json(changed).json}]", ["status"]})
  ensure
    transport.try(&.write.close)
    client.try(&.close)
  end

  it "keeps live v1 cursors, modes, and suggestions while a load is queued and then rejected" do
    transport = QueuedChoiceStateTransport.new("session/load")
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true}})
    modes = %({"currentModeId":"ask","availableModes":[{"id":"ask","name":"Ask"},{"id":"code","name":"Code"}]})
    transport.replies["session/new"] = %("result":{"sessionId":"s","modes":#{modes}})
    transport.replies["session/load"] = %("error":{"code":-32602,"message":"Load unavailable"})
    capabilities = ACP::Protocol::ClientSessionCapabilities.new(cursors: ACP::Protocol::SessionCursorsCapabilities.new,
      prompt_suggestions: ACP::Protocol::PromptSuggestionsCapabilities.new)
    client_caps = ACP::Protocol::ClientCapabilities.new(session: capabilities, subagents: ACP::Protocol::SubagentCapabilities.new)
    client = ACP::Client.new(transport, client_capabilities: client_caps)
    client.request_timeout = 2.0
    suggestions = [] of ACP::Protocol::PromptSuggestionsUpdate
    load_flags = [] of Bool
    client.on_update = ->(note : ACP::Protocol::SessionUpdateParams) do
      if update = note.update.as?(ACP::Protocol::PromptSuggestionsUpdate)
        suggestions << update
      end
      load_flags << note.before_load_response?
      nil
    end
    client.initialize_connection
    client.session_new("/work")
    transport.update("s", %({"sessionUpdate":"subagent_update","sessionId":"child","state":{"state":"running"}}))
    choice_state_barrier(client, transport)
    client.subagent("child").not_nil!.state.not_nil!.state.should eq("running")

    result = Channel(ACP::Protocol::SessionLoadResult | Exception).new(1)
    spawn do
      result.send(client.session_load("s", "/work"))
    rescue ex
      result.send(ex)
    end
    select
    when transport.queued.receive
    when timeout(2.seconds)
      fail "load did not reach the transport queue"
    end

    transport.update("s", %({"sessionUpdate":"user_message_chunk","messageId":"m","content":{"type":"text","text":"Live"}}))
    transport.update("s", %({"sessionUpdate":"cursor_update","cursorId":"live","anchor":{"type":"user_message","messageId":"m","position":"after"}}))
    transport.update("s", %({"sessionUpdate":"current_mode_update","currentModeId":"code"}))
    transport.update("s", %({"sessionUpdate":"prompt_suggestions_update","suggestions":[{"prompt":[{"type":"text","text":"Continue"}]}]}))
    transport.update("s", %({"sessionUpdate":"subagent_update","sessionId":"child","state":{"state":"idle"}}))
    choice_state_barrier(client, transport)
    transport.sent_messages.none? { |message| message["method"]?.try(&.as_s?) == "session/load" }.should be_true
    read_live = -> { {!client.session_cursor("s", "live").nil?, client.session_modes("s").try(&.current_mode_id)} }
    read_live.call.should eq({true, "code"})
    suggestions.size.should eq(1)
    load_flags.should eq(Array.new(6, false))
    client.subagent("child").not_nil!.state.not_nil!.state.should eq("idle")

    transport.write.send(nil)
    select
    when outcome = result.receive
      outcome.as(ACP::JsonRpcError).code.should eq(-32602)
    when timeout(2.seconds)
      fail "load rejection was not delivered"
    end
    read_live.call.should eq({true, "code"})
  ensure
    transport.try(&.write.close)
    client.try(&.close)
  end
end

describe "ACP v2 exact configuration options" do
  it "preserves full-width configuration options in every typed wrapper" do
    meta = %({"example.test/sequence":18446744073709551615,"example.test/precision":0.1234567890123456789})
    group = %({"groupId":"provider","name":"Provider","value":"unknown-field","_meta":#{meta},"options":[false,{"value":"small","name":"Small","_meta":#{meta}}]})
    select_option = %({"type":"select","configId":"model","name":"Model","currentValue":"small","options":[#{group}]})
    opaque = %({"type":"future","configId":"custom","name":"Custom","currentValue":{"wide":18446744073709551615}})
    config = "[false,#{select_option},#{opaque}]"
    fields = %("configOptions":#{config},"_meta":#{meta})

    created = ACP::Protocol::V2::SessionNewResult.from_json(%({"sessionId":"s",#{fields}}))
    resumed = ACP::Protocol::V2::SessionResumeResult.from_json(%({#{fields}}))
    preview = ACP::Protocol::V2::SessionOptionsResult.from_json(%({#{fields}}))
    changed = ACP::Protocol::V2::SessionSetConfigOptionResult.from_json(%({#{fields}}))
    updated = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"config_option_update",#{fields}})).typed.as(ACP::Protocol::V2::ConfigOptionUpdate)

    [created, resumed, preview, changed, updated].each do |wrapper|
      wrapper.typed_config_options.map(&.config_id).should eq(["model", "custom"])
      wrapper.config_options_raw.json.should eq(config)
      wrapper.config_options.size.should eq(2)
      wrapper.meta_raw.not_nil!.json.should eq(meta)
      wrapper.to_json.should contain(%("configOptions":#{config}))
      typed = wrapper.typed_config_options
      group = typed.first.select_options.as(Array(ACP::Protocol::V2::ConfigOptionGroup)).first
      group.meta_raw.not_nil!.json.should eq(meta)
      group.options.size.should eq(1)
      group.options_raw.elements?.not_nil!.first.json.should eq("false")
      group.values.first.meta_raw.not_nil!.json.should eq(meta)
      typed.last.raw.field("currentValue").not_nil!.field("wide").not_nil!.json.should eq(UInt64::MAX.to_s)
    end
  end

  it "omits unusable selectors and ambiguous configuration IDs" do
    wire = <<-JSON
      {"configOptions":[
        {"type":"select","configId":"missing-current","name":"Missing","currentValue":"absent","options":[{"value":"present","name":"Present"}]},
        {"type":"select","configId":"duplicate-value","name":"Duplicate","currentValue":"x","options":[{"value":"x","name":"First"},{"value":"x","name":"Second"}]},
        {"type":"select","configId":"duplicate-group","name":"Duplicate group","currentValue":"a","options":[{"groupId":"same","name":"First","options":[{"value":"a","name":"A"}]},{"groupId":"same","name":"Second","options":[{"value":"b","name":"B"}]}]},
        {"type":"select","configId":"mixed","name":"Mixed","currentValue":"a","options":[{"value":"a","name":"A"},{"groupId":"g","name":"Group","value":"shadow","options":[{"value":"b","name":"B"}]}]},
        {"type":"select","configId":"cross-group","name":"Cross group","currentValue":"a","options":[{"groupId":"g1","name":"First","options":[{"value":"a","name":"A"}]},{"groupId":"g2","name":"Second","options":[{"value":"a","name":"Again"}]}]},
        {"type":"boolean","configId":"repeated","name":"First","currentValue":true},
        {"type":"boolean","configId":"repeated","name":"Second","currentValue":false},
        {"type":"boolean","configId":"usable","name":"Usable","currentValue":false},
        {"type":"select","configId":"flat-with-extensions","name":"Flat","currentValue":"b","options":[{"value":"a","name":"A"},{"value":"b","name":"B","groupId":false,"options":false}]}]}
      JSON
    preview = ACP::Protocol::V2::SessionOptionsResult.from_json(wire)
    preview.typed_config_options.map(&.config_id).should eq(["usable", "flat-with-extensions"])
  end

  it "keeps exact option fields when editing or reordering the representable list" do
    wide = %({"configId":"wide","name":"Wide","type":"future","currentValue":18446744073709551615})
    precise = %({"configId":"precise","name":"Precise","type":"future","currentValue":0.1234567890123456789})
    result = ACP::Protocol::V2::SessionOptionsResult.from_json(%({"configOptions":[#{wide},false,#{precise}]}))
    result.config_options.map { |option| option["configId"].as_s }.should eq(["wide", "precise"])
    result.config_options.first.as_h["name"] = JSON::Any.new("Edited")
    result.config_options.reverse!
    values = result.typed_config_options
    values.map(&.name).should eq(["Precise", "Edited"])
    values.first.raw.field("currentValue").not_nil!.json.should eq("0.1234567890123456789")
    values.last.raw.field("currentValue").not_nil!.json.should eq(UInt64::MAX.to_s)

    result.config_options = [] of JSON::Any
    result.config_options_raw.json.should eq("[]")
    result.typed_config_options.should be_empty
  end

  it "uses the same exact configuration in stdio results, updates, and value validation" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(2)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end

      meta = %({"example.test/sequence":18446744073709551615,"example.test/ratio":0.1234567890123456789})
      custom = %({"configId":"future","name":"Future","type":"_range","currentValue":{"number":18446744073709551615}})
      values = %([{"value":"small","name":"Small"},{"value":"large","name":"Large","_meta":#{meta}}])
      selection = %({"configId":"model","name":"Model","type":"select","currentValue":"small","options":#{values}})
      valid = "[#{custom},#{selection}]"

      spawn do
        init = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{init["id"]},"result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{}}}})
        create = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{create["id"]},"result":{"sessionId":"s","configOptions":#{valid}}})
      end
      client.initialize_connection
      created = client.session_new("/work")
      created.config_options_raw.json.should eq(valid)
      client.session_config_options("s").not_nil!.map(&.config_id).should eq(["future", "model"])

      invalid = selection.sub(%("currentValue":"small"), %("currentValue":"missing"))
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"config_option_update","configOptions":[#{invalid}]}}})
      update = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::ConfigOptionUpdate)
      update.typed_config_options.should be_empty
      client.session_config_options("s").not_nil!.should be_empty
      params = ACP::Protocol::V2::SessionSetConfigOptionParams.new("s", "model", "large")
      expect_raises(ACP::InvalidStateError) { client.session_set_config_option(params) }

      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"config_option_update","configOptions":#{valid},"_meta":#{meta}}}})
      update = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::ConfigOptionUpdate)
      update.config_options_raw.json.should eq(client.session_config_options_raw("s").not_nil!.json)
      update.typed_config_options.map(&.config_id).should eq(client.session_config_options("s").not_nil!.map(&.config_id))

      sent = Channel(JSON::Any).new(1)
      spawn do
        change = JSON.parse(outgoing.gets.not_nil!)
        sent.send(change)
        chosen = selection.sub(%("currentValue":"small"), %("currentValue":"large"))
        feed.puts %({"jsonrpc":"2.0","id":#{change["id"]},"result":{"configOptions":[#{chosen}],"_meta":#{meta}}})
      end
      changed = client.session_set_config_option(params)
      sent.receive["params"]["value"].as_s.should eq("large")
      changed.meta_raw.not_nil!.json.should eq(meta)
      changed.typed_config_options.first.selected_value.should eq("large")
      changed.typed_config_options.first.selectable_values.not_nil!.last.meta_raw.not_nil!.json.should eq(meta)
      client.session_config_options_raw("s").not_nil!.json.should eq(changed.config_options_raw.json)
    ensure
      client.try(&.close)
    end
  end

  it "retains precise decimals even when the stdio response fits in JSON::Any" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      decimal = "0.1234567890123456789"
      original = %([{"configId":"review","name":"Review","type":"boolean","currentValue":false,"_meta":{"example.test/ratio":#{decimal}}}])
      changed = original.sub("false", "true")

      spawn do
        init = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{init["id"]},"result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"options":{}}}}})
        preview = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{preview["id"]},"result":{"configOptions":#{original}}})
        empty_preview = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{empty_preview["id"]},"result":{"_meta":{"example.test/ratio":#{decimal}}}})
        create = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{create["id"]},"result":{"sessionId":"s","configOptions":#{original}}})
        change = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{change["id"]},"result":{"configOptions":#{changed}}})
      end
      client.initialize_connection
      client.session_options("/work").config_options_raw.json.should eq(original)
      empty_preview = client.session_options("/work")
      empty_preview.typed_config_options.should be_empty
      empty_preview.meta_raw.not_nil!.field("example.test/ratio").not_nil!.json.should eq(decimal)
      client.session_new("/work").config_options_raw.json.should eq(original)
      params = ACP::Protocol::V2::SessionSetConfigOptionParams.new("s", "review", true)
      result = client.session_set_config_option(params)
      result.config_options_raw.json.should eq(changed)
      result.typed_config_options.first.meta_raw.not_nil!.field("example.test/ratio").not_nil!.json.should eq(decimal)
      client.session_config_options_raw("s").not_nil!.json.should eq(changed)
    ensure
      client.try(&.close)
    end
  end

  it "rejects duplicate configuration lists without replacing the cached choices" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(1)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end
      original = %([{"configId":"review","name":"Review","type":"boolean","currentValue":false}])
      duplicate = %("configOptions":false,"configOptions":[])

      expect_raises(JSON::ParseException) { ACP::Protocol::V2::SessionNewResult.from_json(%({"sessionId":"s",#{duplicate}})) }
      expect_raises(JSON::ParseException) { ACP::Protocol::V2::SessionSetConfigOptionResult.from_json(%({#{duplicate}})) }

      spawn do
        init = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{init["id"]},"result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{}}}})
        create = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{create["id"]},"result":{"sessionId":"s","configOptions":#{original}}})
        change = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{change["id"]},"result":{#{duplicate}}})
      end
      client.initialize_connection
      client.session_new("/work")

      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"config_option_update",#{duplicate}}}})
      next_exact_session_update(observed).update.typed.should be_nil
      client.session_config_options_raw("s").not_nil!.json.should eq(original)

      params = ACP::Protocol::V2::SessionSetConfigOptionParams.new("s", "review", true)
      expect_raises(ACP::ProtocolError) { client.session_set_config_option(params) }
      client.session_config_options_raw("s").not_nil!.json.should eq(original)
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP v2 exact command advertisements" do
  it "preserves exact slash inputs and skill metadata in typed setup and update lists" do
    meta = %({"example.test/count":18446744073709551615,"example.test/ratio":0.1234567890123456789})
    command = %({"type":"command","name":"status","description":"Inspect state","input":{"type":"text","hint":"Scope","_meta":#{meta}}})
    skill = %({"type":"skill","name":"notes","description":"Notes","path":"/work/skills/notes/SKILL.md","_meta":#{meta}})
    future = %({"type":"future","name":"next","description":"Future","payload":[0.1234567890123456789]})
    list = "[false,#{command},#{skill},#{future}]"
    setup = ACP::Protocol::V2::SessionNewResult.from_json(%({"sessionId":"s","availableCommands":#{list}}))
    update = ACP::Protocol::V2::SessionUpdate.from_json(%({"sessionUpdate":"available_commands_update","availableCommands":#{list}})).typed.as(ACP::Protocol::V2::AvailableCommandsUpdate)

    {setup, update}.each do |wrapper|
      slash, advertised_skill, extension = wrapper.typed_available_commands
      slash.name.should eq("status")
      slash.input.not_nil!.text_hint.should eq("Scope")
      slash.input.not_nil!.meta_raw.not_nil!.json.should eq(meta)
      advertised_skill.skill.not_nil!.meta_raw.not_nil!.json.should eq(meta)
      extension.raw.field("payload").not_nil!.json.should eq("[0.1234567890123456789]")
      wrapper.available_commands_raw.json.should eq(list)
      wrapper.to_json.should contain(%("availableCommands":#{list}))
    end
  end

  it "ignores ambiguous names and exposes malformed optional inputs as absent" do
    list = <<-JSON
      [
        {"type":"command","name":"collision","description":"First"},
        {"type":"skill","name":"collision","description":"Second"},
        {"type":"future","name":"old","name":"duplicate","description":"Ambiguous envelope"},
        {"type":"command","name":"missing-hint","description":"Usable","input":{"type":"text","hint":false}},
        {"type":"command","name":"ambiguous-input","description":"Usable","input":{"type":"text","type":"future","hint":"First"}},
        {"type":"command","name":"valid","description":"Usable","input":{"type":"future","arbitrary":null}}
      ]
      JSON
    update = ACP::Protocol::V2::AvailableCommandsUpdate.from_json(%({"availableCommands":#{list}}))
    update.typed_available_commands.map(&.name).should eq(["missing-hint", "ambiguous-input", "valid"])
    update.typed_available_commands.first(2).each { |command| command.input.should be_nil }
    update.typed_available_commands.last.input.not_nil!.type.should eq("future")
    update.typed_available_skills.should be_empty
  end

  it "preserves nested exact fields when editing the projected input hint" do
    meta = %({"example.test/count":18446744073709551615,"example.test/ratio":0.1234567890123456789})
    command = %({"type":"command","name":"status","description":"Inspect","input":{"type":"text","hint":"Before","_meta":#{meta}}})
    future = %({"type":"future","name":"next","description":"Next"})
    options = ACP::Protocol::V2::SessionOptionsResult.from_json(%({"availableCommands":[false,#{command},#{future}]}))
    options.available_commands.size.should eq(2)
    hint = options.available_commands.first["input"].as_h
    hint["hint"] = JSON::Any.new("After")
    options.available_commands.reverse!
    slash = options.typed_available_commands.last
    slash.input.not_nil!.text_hint.should eq("After")
    slash.input.not_nil!.meta_raw.not_nil!.field("example.test/count").not_nil!.json.should eq(UInt64::MAX.to_s)
    slash.input.not_nil!.meta_raw.not_nil!.field("example.test/ratio").not_nil!.json.should eq("0.1234567890123456789")

    options.available_commands = [] of JSON::Any
    options.available_commands_raw.json.should eq("[]")
  end

  it "applies input deletion and replacement without keeping the old metadata" do
    input = %({"type":"text","hint":"Before","_meta":{"example.test/count":18446744073709551615}})
    command = %({"type":"command","name":"status","description":"Inspect","input":#{input}})
    wire = %({"availableCommands":[#{command}]})
    removed = ACP::Protocol::V2::SessionOptionsResult.from_json(wire)
    removed.available_commands.first.as_h.delete("input")
    removed.typed_available_commands.first.input.should be_nil
    removed.available_commands_raw.elements?.not_nil!.first.field("input").should be_nil

    replaced = ACP::Protocol::V2::SessionOptionsResult.from_json(wire)
    # Even an identical JSON::Any view is a new input when its hash is replaced.
    replaced.available_commands.first.as_h["input"] = JSON.parse(%({"type":"text","hint":"Before"}))
    replaced.typed_available_commands.first.input.not_nil!.meta_raw.should be_nil
  end

  it "preserves rejected duplicate input members during unrelated edits" do
    command = %({"type":"command","name":"status","description":"Inspect","input":{"type":"text","type":"future","hint":"Before"}})
    options = ACP::Protocol::V2::SessionOptionsResult.from_json(%({"availableCommands":[#{command}]}))
    options.typed_available_commands.first.input.should be_nil
    options.available_commands.first.as_h["description"] = JSON::Any.new("Edited")
    options.typed_available_commands.first.input.should be_nil
    options.available_commands.first["input"].as_h["hint"] = JSON::Any.new("After")
    options.typed_available_commands.first.input.should be_nil
    options.available_commands_raw.json.should contain(%("type":"text","type":"future","hint":"After"))
  end

  it "keeps a rejected command ambiguous when editing its repeated input property" do
    wire = %({"availableCommands":[{"type":"command","name":"status","description":"Inspect","input":{"type":"text","hint":"First"},"input":{"type":"text","hint":"Second"}}]})
    options = ACP::Protocol::V2::SessionOptionsResult.from_json(wire)
    options.typed_available_commands.should be_empty
    options.available_commands.first["input"].as_h["hint"] = JSON::Any.new("Edited")
    options.typed_available_commands.should be_empty
    options.available_commands_raw.json.should contain(%("input":{"type":"text","hint":"First"},"input":{"type":"text","hint":"Edited"}))
  end

  it "keeps the typed stdio list and prompt skill grants in sync with the raw cache" do
    with_wide_stdio do |transport, feed, outgoing|
      command_capabilities = ACP::Protocol::V2::CommandsCapabilities.new(skill: ACP::Protocol::V2::CommandsSkillCapabilities.new)
      capabilities = ACP::Protocol::V2::ClientCapabilities.new(session: ACP::Protocol::V2::ClientSessionCapabilities.new(commands: command_capabilities))
      client = ACP::V2::Client.new(transport, capabilities: capabilities)
      client.request_timeout = 2.0
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(2)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end

      skill = %({"type":"skill","name":"notes","description":"Notes","_meta":{"example.test/rank":18446744073709551615}})
      command = %({"type":"command","name":"status","description":"Status","input":{"type":"text","hint":"Branch","_meta":{"example.test/rank":0.1234567890123456789}}})
      list = "[false,#{skill},#{command}]"
      spawn do
        init = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{init["id"]},"result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"options":{},"prompt":{"skill":{}}}}}})
        preview = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{preview["id"]},"result":{"availableCommands":[#{command}]}})
        setup = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{setup["id"]},"result":{"sessionId":"s","availableCommands":#{list}}})
      end
      client.initialize_connection
      preview = client.session_options("/work")
      preview.typed_available_commands.first.input.not_nil!.meta_raw.not_nil!.field("example.test/rank").not_nil!.json.should eq("0.1234567890123456789")
      setup = client.session_new("/work")
      setup.available_commands_raw.json.should eq(list)
      client.session_available_commands_raw("s").not_nil!.json.should eq(list)
      client.session_available_commands("s").not_nil!.map(&.name).should eq(["notes", "status"])

      duplicate = %("availableCommands":false,"availableCommands":[])
      expect_raises(JSON::ParseException) { ACP::Protocol::V2::SessionResumeResult.from_json(%({#{duplicate}})) }
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"available_commands_update",#{duplicate}}}})
      next_exact_session_update(observed).update.typed.should be_nil
      client.session_available_commands_raw("s").not_nil!.json.should eq(list)

      collision = %({"type":"future","name":"notes","description":"Ambiguous"})
      next_list = "[#{skill},#{collision},#{command}]"
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"available_commands_update","availableCommands":#{next_list},"_meta":{"example.test/rank":18446744073709551615}}}})
      update = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::AvailableCommandsUpdate)
      update.meta_raw.not_nil!.field("example.test/rank").not_nil!.json.should eq(UInt64::MAX.to_s)
      update.available_commands_raw.json.should eq(client.session_available_commands_raw("s").not_nil!.json)
      update.typed_available_commands.map(&.name).should eq(["status"])
      client.session_available_commands("s").not_nil!.map(&.name).should eq(["status"])

      blocks = [ACP::Protocol::V2::SkillReference.new("notes"), ACP::Protocol::TextContentBlock.new("Review")] of ACP::Protocol::V2::PromptContentBlock
      params = ACP::Protocol::V2::SessionPromptParams.new("s", blocks)
      expect_raises(ACP::InvalidStateError, /not currently advertised/) { client.session_prompt(params) }
    ensure
      client.try(&.close)
    end
  end
end
describe "ACP v2 structured tool diffs" do
  it "keeps usable changes in order when neighboring entries are malformed" do
    content = ACP::Protocol::V2::ToolCallContent.from_json <<-'JSON'
      {"type":"diff","changes":[
        false,
        {"operation":"add","path":"/work/source"},
        {"operation":"modify","path":"relative"},
        {"path":"/work/missing-operation"},
        {"operation":"move","path":"C:\\work\\destination","oldPath":"/work/source"},
        {"operation":"copy","path":"/work/missing-source"},
        {"operation":"modify","path":"/work/duplicate"},
        {"operation":"delete","path":"/work/duplicate"},
        {"operation":"modify","path":"/work/ambiguous","path":"/work/other"},
        {"operation":"future","path":"relative","fileType":42},
        {"operation":"delete","path":"/work/end"}
      ]}
      JSON

    changes = content.diff.not_nil!.changes
    changes.map(&.operation).should eq(["add", "move", "future", "delete"])
    changes.map(&.path).should eq(["/work/source", "C:\\work\\destination", nil, "/work/end"])
    changes[1].old_path.should eq("/work/source")
    changes[2].file_type.should be_nil
  end

  it "keeps structured changes when the optional patch is malformed" do
    changes = %([{"operation":"add","path":"/work/added"}])
    [
      %({"format":"git_patch","text":false}),
      %({"format":"git_patch","format":"future","text":"ambiguous"}),
      %({"format":"git_patch"}),
      "[]",
      "null",
    ].each do |patch|
      content = ACP::Protocol::V2::ToolCallContent.from_json(%({"type":"diff","changes":#{changes},"patch":#{patch}}))
      diff = content.diff.not_nil!
      diff.changes.first.path.should eq("/work/added")
      diff.patch.should be_nil
    end
  end

  it "requires a usable structured change before exposing a diff" do
    ["[]", %([{"operation":"move","path":"/work/incomplete"}]), "false"].each do |changes|
      content = ACP::Protocol::V2::ToolCallContent.from_json(%({"type":"diff","changes":#{changes},"patch":{"format":"git_patch","text":"example"}}))
      content.diff.should be_nil
    end
  end

  it "rejects ambiguous required fields and ignores ambiguous optional patches" do
    changes = %([{"operation":"add","path":"/work/added"}])
    duplicate_type = %("type":"content","type":"diff","changes":#{changes})
    duplicate_changes = %("type":"diff","changes":#{changes},"changes":#{changes})
    [duplicate_type, duplicate_changes].each do |fields|
      content = ACP::Protocol::V2::ToolCallContent.from_json("{#{fields}}")
      content.diff.should be_nil
      ACP::Protocol::V2::ToolCallContent.from_json(content.to_json).diff.should be_nil
    end
    expect_raises(JSON::ParseException, /Ambiguous ACP diff changes/) do
      ACP::Protocol::V2::DiffContent.from_json("{#{duplicate_changes}}")
    end
    expect_raises(JSON::ParseException, /Ambiguous ACP diff change fields/) do
      ACP::Protocol::V2::DiffChange.from_json(%({"operation":"add","path":"/work/added","path":"/work/ambiguous"}))
    end

    patch = %({"format":"git_patch","text":"example"})
    duplicate_patch = %({"type":"diff","changes":#{changes},"patch":#{patch},"patch":#{patch}})
    projected = ACP::Protocol::V2::ToolCallContent.from_json(duplicate_patch).diff.not_nil!
    direct = ACP::Protocol::V2::DiffContent.from_json(duplicate_patch)
    [projected, direct].each do |diff|
      diff.changes.first.path.should eq("/work/added")
      diff.patch.should be_nil
    end
  end

  it "preserves custom patch formats and the raw fields of future operations" do
    wire = %({"type":"diff","changes":[{"operation":"_future","path":"relative","vendor":{"number":18446744073709551615}}],"patch":{"format":"_future","text":"example"}})
    content = ACP::Protocol::V2::ToolCallContent.from_json(wire)
    diff = content.diff.not_nil!
    diff.patch.not_nil!.format.should eq("_future")
    diff.git_patch.should be_nil
    change = diff.changes.first
    change.path.should be_nil
    change.raw.field("path").not_nil!.as_s?.should eq("relative")
    change.raw.field("vendor").not_nil!.field("number").not_nil!.json.should eq(UInt64::MAX.to_s)
    content.raw.field("changes").not_nil!.elements?.not_nil!.size.should eq(1)
  end

  it "preserves exact metadata in full tool updates and streamed content over stdio" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(2)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "s")

      meta_key = "example.test/value"
      decimal = "0.1234567890123456789"
      wide = UInt64::MAX.to_s
      change = %({"operation":"modify","path":"/work/config","_meta":{"#{meta_key}":#{wide}}})
      patch = %({"format":"git_patch","text":"example","_meta":{"#{meta_key}":#{decimal}}})
      content = %({"type":"diff","changes":[false,#{change}],"patch":#{patch},"_meta":{"#{meta_key}":#{wide}}})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"tool","content":[#{content}]}}})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_content_chunk","toolCallId":"tool","content":#{content},"_meta":{"#{meta_key}":#{decimal}}}}})

      update = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::ToolCallUpdate)
      chunk = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::ToolCallContentChunk)
      chunk.meta_raw.not_nil!.field(meta_key).not_nil!.json.should eq(decimal)
      [update.content.not_nil!.first, chunk.content].each do |item|
        item.meta_raw.not_nil!.field(meta_key).not_nil!.json.should eq(wide)
        item.raw.field("changes").not_nil!.elements?.not_nil!.size.should eq(2)
        diff = item.diff.not_nil!
        diff.meta_raw.not_nil!.field(meta_key).not_nil!.json.should eq(wide)
        diff.changes.map(&.path).should eq(["/work/config"])
        diff.changes.first.meta_raw.not_nil!.field(meta_key).not_nil!.json.should eq(wide)
        diff.git_patch.not_nil!.meta_raw.not_nil!.field(meta_key).not_nil!.json.should eq(decimal)
        encoded = ACP::Protocol::WireFrame.encode(diff)
        decoded = ACP::Protocol::V2::DiffContent.from_json(encoded)
        decoded.meta_raw.not_nil!.field(meta_key).not_nil!.json.should eq(wide)
        decoded.git_patch.not_nil!.meta_raw.not_nil!.field(meta_key).not_nil!.json.should eq(decimal)
      end

      ambiguous = %({"type":"diff","changes":[#{change}],"changes":[#{change}]})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_content_chunk","toolCallId":"tool","content":#{ambiguous}}}})
      next_exact_session_update(observed).update.typed.should be_nil
    ensure
      client.try(&.close)
    end
  end
end
describe "ACP v2 tool-call patch decoding" do
  it "retains valid content and locations in a mixed replacement" do
    raw = <<-'JSON'
      {"sessionUpdate":"tool_call_update","toolCallId":"tool","title":"Kept",
       "name":false,"status":"paused","kind":"future_kind",
       "content":[false,{},{"type":"terminal"},{"type":"session","sessionId":"child"},
                  {"type":"content","content":{"type":"text","text":false}},
                  {"type":"diff","changes":[false]},
                  {"type":"diff","changes":[{"operation":"add","path":"/work/added"}],
                   "patch":{"format":"git_patch","text":"first"},"patch":{"format":"git_patch","text":"second"}},
                  {"type":"terminal","terminalId":"t1","terminalId":"t2"},
                  {"type":"_future","detail":{"value":18446744073709551615}},
                  {"type":"content","content":{"type":"text","text":"Done"}}],
       "locations":[0,{},{"path":"relative"},{"path":"/work/zero","line":0},
                    {"path":"/work/negative","line":-1},
                    {"path":"/work/out-of-range","line":4294967296},
                    {"path":"/work/wrong-type","line":"1"},
                    {"path":"/work/decimal","line":1.5},
                    {"path":"/work/ambiguous-line","line":1,"line":2},
                    {"path":"/first","path":"/second"},
                    {"path":"C:\\work\\full","line":4294967295}]}
      JSON
    update = ACP::Protocol::V2::SessionUpdate.from_json(raw).typed.as(ACP::Protocol::V2::ToolCallUpdate)
    update.title.should eq("Kept")
    update.status.should eq("paused")
    update.kind.should eq("future_kind")
    update.name_present?.should be_false
    update.content_present?.should be_true
    content = update.content.not_nil!
    content.map(&.content_type).should eq(["session", "diff", "_future", "content"])
    content.first.session_id.should eq("child")
    diff = content[1].diff.not_nil!
    diff.changes.first.path.should eq("/work/added")
    diff.patch.should be_nil
    content[2].raw.field("detail").not_nil!.field("value").not_nil!.json.should eq(UInt64::MAX.to_s)
    content.last.content_block.as(ACP::Protocol::TextContentBlock).text.should eq("Done")
    update.locations_present?.should be_true
    locations = update.locations.not_nil!
    locations.map(&.path).should eq(["/work/zero", "/work/negative", "/work/out-of-range", "/work/wrong-type", "/work/decimal", "/work/ambiguous-line", "C:\\work\\full"])
    locations.map(&.line).should eq([nil, nil, nil, nil, nil, nil, UInt32::MAX])
  end

  it "distinguishes malformed fields, explicit clears, and empty replacements on round trips" do
    base = %("sessionUpdate":"tool_call_update","toolCallId":"tool")
    bad = %({#{base},"name":1,"title":[],"kind":{},"status":true,"capabilities":"bad","content":{},"locations":false})
    update = ACP::Protocol::V2::ToolCallUpdate.from_json(bad)
    update.name_present?.should be_false
    update.title_present?.should be_false
    update.kind_present?.should be_false
    update.status_present?.should be_false
    update.capabilities_present?.should be_false
    update.content_present?.should be_false
    update.locations_present?.should be_false
    JSON.parse(update.to_json).should eq(JSON.parse("{#{base}}"))

    wire = %({#{base},"name":null,"title":null,"status":null,"kind":null,"content":null,"locations":null,"capabilities":null})
    clear = ACP::Protocol::V2::ToolCallUpdate.from_json(wire)
    clear.title_present?.should be_true
    clear.content_present?.should be_true
    clear.locations_present?.should be_true
    clear.capabilities_present?.should be_true
    JSON.parse(clear.to_json).should eq(JSON.parse(wire))

    empty = ACP::Protocol::V2::ToolCallUpdate.from_json(%({#{base},"content":[false],"locations":[]}))
    empty.content_present?.should be_true
    empty.locations_present?.should be_true
    empty.content.not_nil!.should be_empty
    empty.locations.not_nil!.should be_empty
    JSON.parse(empty.to_json).should eq(JSON.parse(%({#{base},"content":[],"locations":[]})))

    update.title = "Replaced"
    update.content = empty.content
    update.locations = nil
    JSON.parse(update.to_json).should eq(JSON.parse(%({#{base},"title":"Replaced","content":[],"locations":null})))
  end

  it "decodes permission and notification patches in receive order over stdio" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      events = Channel(String).new(3)
      updates = Channel(ACP::Protocol::V2::SessionUpdateParams).new(2)
      requests = Channel(ACP::Protocol::V2::RequestPermissionParams).new(1)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        updates.send(note)
        events.send("update")
        nil
      end
      client.on_request_permission = ->(request : ACP::Protocol::V2::RequestPermissionParams) do
        requests.send(request)
        events.send("permission")
        ACP::Protocol::V2::RequestPermissionResult.cancelled
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "s")

      content = %([false,{"type":"_future","data":0.1234567890123456789}])
      path = %({"path":"/work/file","line":false,"_meta":{"example.test/revision":18446744073709551615}})
      patch = %({"toolCallId":"tool","status":"paused","title":false,"locations":[null,#{path}],"content":#{content}})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"tool","title":"Before"}}})
      feed.puts %({"jsonrpc":"2.0","id":"permission","method":"session/request_permission","params":{"sessionId":"s","title":"Review tool call","subject":{"type":"tool_call","toolCall":#{patch}},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"}]}})

      next_permission_event(events).should eq("update")
      next_permission_event(events).should eq("update")
      next_permission_event(events).should eq("permission")
      first = next_exact_session_update(updates).update.typed.as(ACP::Protocol::V2::ToolCallUpdate)
      first.title.should eq("Before")
      notification = next_exact_session_update(updates)
      notification.raw.field("update").not_nil!.field("content").not_nil!.json.should eq(content)
      request = next_permission_event(requests)
      subject = request.typed_subject.not_nil!
      subject.tool_call_raw.not_nil!.json.should eq(patch)

      [notification.update.typed.as(ACP::Protocol::V2::ToolCallUpdate), subject.tool_call.not_nil!].each do |typed|
        typed.status.should eq("paused")
        typed.title_present?.should be_false
        typed.content.not_nil!.map(&.content_type).should eq(["_future"])
        typed.content.not_nil!.first.raw.field("data").not_nil!.json.should eq("0.1234567890123456789")
        location = typed.locations.not_nil!.first
        location.path.should eq("/work/file")
        location.line.should be_nil
        location.meta_raw.not_nil!.field("example.test/revision").not_nil!.json.should eq(UInt64::MAX.to_s)
        location.meta = {"example.test/tag" => JSON::Any.new("checked")}
        location.meta.not_nil!["example.test/tag"].as_s.should eq("checked")
      end
      reply = JSON.parse(outgoing.gets.not_nil!)
      reply["id"].as_s.should eq("permission")
      reply["result"]["outcome"]["outcome"].as_s.should eq("cancelled")
    ensure
      client.try(&.close)
    end
  end

  it "keeps tool cancellation in sync with the capability patch" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      updates = Channel(ACP::Protocol::V2::SessionUpdateParams).new(1)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        updates.send(note)
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "s")

      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"tool","capabilities":{"cancel":{}}}}})
      granted = next_exact_session_update(updates).update.typed.as(ACP::Protocol::V2::ToolCallUpdate)
      granted.capabilities.not_nil!.cancel.should_not be_nil

      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"tool","capabilities":false}}})
      malformed = next_exact_session_update(updates).update.typed.as(ACP::Protocol::V2::ToolCallUpdate)
      malformed.capabilities_present?.should be_false

      feed.puts %({"jsonrpc":"2.0","id":"permission","method":"session/request_permission","params":{"sessionId":"s","title":"Review tool call","subject":{"type":"tool_call","toolCall":{"toolCallId":"tool","capabilities":[]}},"options":[{"optionId":"deny","name":"Deny","kind":"reject_once"}]}})
      permission = next_exact_session_update(updates).update.typed.as(ACP::Protocol::V2::ToolCallUpdate)
      permission.capabilities_present?.should be_false
      JSON.parse(outgoing.gets.not_nil!)["result"]["outcome"]["outcome"].should eq("cancelled")

      sent = Channel(JSON::Any).new(1)
      spawn do
        request = JSON.parse(outgoing.gets.not_nil!)
        sent.send(request)
        feed.puts %({"jsonrpc":"2.0","id":#{request["id"]},"result":{}})
      end
      client.tool_call_cancel("s", "tool")
      sent.receive["method"].should eq("tool_call/cancel")

      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"tool","capabilities":null}}})
      cleared = next_exact_session_update(updates).update.typed.as(ACP::Protocol::V2::ToolCallUpdate)
      cleared.capabilities_present?.should be_true
      cleared.capabilities.should be_nil
      expect_raises(ACP::InvalidStateError, /current cancel capability/) { client.tool_call_cancel("s", "tool") }
    ensure
      client.try(&.close)
    end
  end
end
describe "ACP v2 terminal patch decoding" do
  it "keeps exit information when sibling fields and the optional exit code are malformed" do
    wire = <<-JSON
      {"sessionUpdate":"terminal_update","terminalId":"term","command":[],
       "cwd":"relative","output":{"data":"YQ"},"size":{"cols":0,"rows":24},"capabilities":false,
       "exitStatus":{"exitCode":9223372036854775808,"signal":"SIGTERM",
                     "_meta":{"example.test/sequence":18446744073709551615}}}
      JSON
    update = ACP::Protocol::V2::SessionUpdate.from_json(wire).typed.as(ACP::Protocol::V2::TerminalUpdate)
    update.command_present?.should be_false
    update.cwd_present?.should be_false
    update.output_present?.should be_false
    update.size_present?.should be_false
    update.capabilities_present?.should be_false
    update.exit_status_present?.should be_true
    status = update.exit_status.not_nil!
    status.exit_code.should be_nil
    status.signal.should eq("SIGTERM")
    status.meta_raw.not_nil!.field("example.test/sequence").not_nil!.json.should eq(UInt64::MAX.to_s)
    encoded = ACP::Protocol::RawJson.from_json(update.to_json)
    encoded.field("command").should be_nil
    encoded.field("cwd").should be_nil
    encoded.field("output").should be_nil
    encoded.field("size").should be_nil
    encoded.field("capabilities").should be_nil
  end

  it "distinguishes terminal replacements, explicit clears, and malformed optional fields" do
    base = %("sessionUpdate":"terminal_update","terminalId":"term")
    clear = %({#{base},"command":null,"cwd":null,"output":null,"exitStatus":null,"size":null,"capabilities":null})
    update = ACP::Protocol::V2::TerminalUpdate.from_json(clear)
    update.command_present?.should be_true
    update.cwd_present?.should be_true
    update.output_present?.should be_true
    update.exit_status_present?.should be_true
    update.size_present?.should be_true
    update.capabilities_present?.should be_true
    JSON.parse(update.to_json).should eq(JSON.parse(clear))

    valid = ACP::Protocol::V2::TerminalUpdate.from_json <<-'JSON'
      {"terminalId":"term","cwd":"C:\\work","output":{"data":""},
       "exitStatus":{"exitCode":-9223372036854775808,"signal":false},
       "size":{"cols":65535,"rows":1}}
      JSON
    valid.cwd.should eq("C:\\work")
    valid.output_present?.should be_true
    valid.output.not_nil!.bytes.should be_empty
    valid.exit_status.not_nil!.exit_code.should eq(Int64::MIN)
    valid.exit_status.not_nil!.signal.should be_nil
    valid.size.not_nil!.cols.should eq(UInt16::MAX)
    valid.size.not_nil!.rows.should eq(1_u16)

    bad = ACP::Protocol::V2::TerminalUpdate.from_json(%({#{base},"exitStatus":[],"size":{"cols":1,"rows":65536}}))
    bad.exit_status_present?.should be_false
    bad.size_present?.should be_false

    unknown = ACP::Protocol::V2::TerminalUpdate.from_json(%({#{base},"exitStatus":{"exitCode":[],"signal":{}}}))
    unknown.exit_status_present?.should be_true
    unknown.exit_status.not_nil!.exit_code.should be_nil
    unknown.exit_status.not_nil!.signal.should be_nil
    JSON.parse(unknown.to_json)["exitStatus"].should eq(JSON.parse("{}"))

    ambiguous = %({#{base},"output":{"data":"YQ=="},"output":{"data":"Yg=="},"command":"Kept"})
    update = ACP::Protocol::V2::SessionUpdate.from_json(ambiguous).typed.as(ACP::Protocol::V2::TerminalUpdate)
    update.output_present?.should be_false
    update.command.should eq("Kept")
  end

  it "accepts standard Base64 output and rejects invalid snapshots and chunks" do
    ["YQ", "YQ===", "Y Q=", "_w==", "YQ==\n", "A===", "a$b=", "é=="].each do |data|
      snapshot = %({"data":#{data.to_json}})
      chunk = %({"sessionUpdate":"terminal_output_chunk","terminalId":"term","data":#{data.to_json}})
      expect_raises(JSON::ParseException) { ACP::Protocol::V2::TerminalOutput.from_json(snapshot) }
      expect_raises(JSON::ParseException) { ACP::Protocol::V2::TerminalOutputChunk.from_json(chunk) }
      ACP::Protocol::V2::SessionUpdate.from_json(chunk).typed.should be_nil
    end

    ACP::Protocol::V2::TerminalOutput.from_json(%({"data":"AP9B"})).bytes.should eq(Bytes[0, 255, 65])
    ACP::Protocol::V2::TerminalOutput.from_json(%({"data":"+/8="})).bytes.should eq(Bytes[0xFB, 0xFF])
    first = ACP::Protocol::V2::TerminalOutputChunk.from_json(%({"terminalId":"term","data":"4g=="}))
    second = ACP::Protocol::V2::TerminalOutputChunk.from_json(%({"terminalId":"term","data":"gqw="}))
    first.bytes.should eq(Bytes[0xE2])
    second.bytes.should eq(Bytes[0x82, 0xAC])

    repeated = %({"data":"YQ==","data":"Yg=="})
    expect_raises(JSON::ParseException, /Ambiguous/) { ACP::Protocol::V2::TerminalOutput.from_json(repeated) }
    chunk = %({"sessionUpdate":"terminal_output_chunk","terminalId":"first","terminalId":"second","data":"YQ=="})
    expect_raises(JSON::ParseException, /Ambiguous/) { ACP::Protocol::V2::TerminalOutputChunk.from_json(chunk) }
    ACP::Protocol::V2::SessionUpdate.from_json(chunk).typed.should be_nil
  end

  it "delivers usable terminal changes and preserves explicit cancellation clears over stdio" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      updates = Channel(ACP::Protocol::V2::SessionUpdateParams).new(5)
      client.on_update = ->(update : ACP::Protocol::V2::SessionUpdateParams) do
        updates.send(update)
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "s")

      snapshot = %({"terminalId":"term","sessionUpdate":"terminal_update","command":"fixture","capabilities":{"cancel":{}},"output":{"data":"YQ=="}})
      patch = %({"terminalId":"term","sessionUpdate":"terminal_update","capabilities":false,"output":{"data":"YQ"},"size":{"cols":80,"rows":24}})
      bad_chunk = %({"terminalId":"term","sessionUpdate":"terminal_output_chunk","data":"YQ"})
      ambiguous_chunk = %({"terminalId":"term","sessionUpdate":"terminal_output_chunk","data":"YQ","data":"Yg=="})
      good_chunk = %({"terminalId":"term","sessionUpdate":"terminal_output_chunk","data":"Yg==","_meta":{"example.test/sequence":18446744073709551615}})
      [snapshot, patch, bad_chunk, ambiguous_chunk, good_chunk].each do |update|
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":#{update}}})
      end

      first = next_exact_session_update(updates).update.typed.as(ACP::Protocol::V2::TerminalUpdate)
      first.output.not_nil!.bytes.should eq("a".to_slice)
      middle = next_exact_session_update(updates).update.typed.as(ACP::Protocol::V2::TerminalUpdate)
      middle.capabilities_present?.should be_false
      middle.output_present?.should be_false
      middle.size.not_nil!.cols.should eq(80_u16)
      rejected = next_exact_session_update(updates)
      rejected.update.typed.should be_nil
      rejected.raw.field("update").not_nil!.field("data").not_nil!.as_s?.should eq("YQ")
      duplicate = next_exact_session_update(updates)
      duplicate.update.typed.should be_nil
      ACP::Protocol::WireFrame.repeated_members(duplicate.raw.field("update").not_nil!.json, "data").should contain("data")
      accepted = next_exact_session_update(updates).update.typed.as(ACP::Protocol::V2::TerminalOutputChunk)
      accepted.bytes.should eq("b".to_slice)
      accepted.meta_raw.not_nil!.field("example.test/sequence").not_nil!.json.should eq(UInt64::MAX.to_s)

      sent = Channel(JSON::Any).new(1)
      spawn do
        request = JSON.parse(outgoing.gets.not_nil!)
        sent.send(request)
        feed.puts %({"jsonrpc":"2.0","id":#{request["id"]},"result":{}})
      end
      client.terminal_cancel("s", "term")
      sent.receive["method"].should eq("terminal/cancel")

      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"terminal_update","terminalId":"term","capabilities":null,"capabilities":false}}})
      ambiguous_clear = next_exact_session_update(updates).update.typed.as(ACP::Protocol::V2::TerminalUpdate)
      ambiguous_clear.capabilities_present?.should be_true
      ambiguous_clear.capabilities.should be_nil
      expect_raises(ACP::InvalidStateError, /current cancel capability/) { client.terminal_cancel("s", "term") }

      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"terminal_update","terminalId":"wrong","terminalId":"other","capabilities":{"cancel":{}}}}})
      next_exact_session_update(updates).update.typed.should be_nil
      expect_raises(ACP::InvalidStateError, /current cancel capability/) { client.terminal_cancel("s", "other") }

      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":#{snapshot}}})
      next_exact_session_update(updates)
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"terminal_update","terminalId":"term","capabilities":null}}})
      cleared = next_exact_session_update(updates).update.typed.as(ACP::Protocol::V2::TerminalUpdate)
      cleared.capabilities_present?.should be_true
      cleared.capabilities.should be_nil
      expect_raises(ACP::InvalidStateError, /current cancel capability/) { client.terminal_cancel("s", "term") }
    ensure
      client.try(&.close)
    end
  end
end
describe "ACP v2 streamed tool content" do
  it "rejects invalid required content and ambiguous chunk fields on direct decoding" do
    base = %("sessionUpdate":"tool_call_content_chunk","toolCallId":"tool")
    [
      "null",
      "[]",
      %({"type":"terminal","terminalId":42}),
      %({"type":"session"}),
      %({"type":"content","content":{"type":"text","text":false}}),
      %({"type":"terminal","terminalId":"first","terminalId":"second"}),
      %({"type":"terminal","type":"session","sessionId":"child"}),
      %({"type":"diff","changes":[]}),
    ].each do |content|
      wire = %({#{base},"content":#{content}})
      expect_raises(JSON::ParseException) { ACP::Protocol::V2::ToolCallContentChunk.from_json(wire) }
      ACP::Protocol::V2::SessionUpdate.from_json(wire).typed.should be_nil
    end

    valid = %({"type":"session","sessionId":"child"})
    [
      %({#{base},"content":false,"content":#{valid}}),
      %({#{base},"toolCallId":"other","content":#{valid}}),
      %({#{base}}),
      %({"sessionUpdate":"tool_call_content_chunk","content":#{valid}}),
    ].each do |wire|
      expect_raises(JSON::ParseException) { ACP::Protocol::V2::ToolCallContentChunk.from_json(wire) }
      ACP::Protocol::V2::SessionUpdate.from_json(wire).typed.should be_nil
    end
  end

  it "shares diff fallback and open extension decoding with replacement content" do
    meta = %({"example.test/value":18446744073709551615})
    patch = %({"format":"git_patch","text":"example"})
    diff = %({"type":"diff","changes":[false,{"operation":"modify","path":"/work/a"}],"patch":null,"patch":#{patch},"_meta":#{meta}})
    future = %({"type":"_future","payload":{"value":0.1234567890123456789},"_meta":#{meta}})
    update = ACP::Protocol::V2::ToolCallUpdate.from_json(%({"toolCallId":"tool","content":[#{diff},#{future}]}))
    contents = update.content.not_nil!
    contents.size.should eq(2)

    [diff, future].each_with_index do |wire, idx|
      chunk = ACP::Protocol::V2::ToolCallContentChunk.from_json(%({"toolCallId":"tool","content":#{wire},"_meta":"malformed"}))
      chunk.content.raw.json.should eq(contents[idx].raw.json)
      chunk.content.meta_raw.not_nil!.json.should eq(meta)
      chunk.meta_raw.should be_nil
      chunk.content.diff.not_nil!.patch.should be_nil if idx == 0
    end
    contents.last.raw.field("payload").not_nil!.field("value").not_nil!.json.should eq("0.1234567890123456789")
  end

  it "retains receive order and raw malformed frames through stdio" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(6)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "s")

      append = %("sessionUpdate":"tool_call_content_chunk","toolCallId":"tool")
      replace = %("sessionUpdate":"tool_call_update","toolCallId":"tool")
      first = %({"type":"content","content":{"type":"text","text":"First"}})
      replacement = %({"type":"content","content":{"type":"text","text":"Replacement"}})
      future = %({"type":"future","details":{"sequence":18446744073709551615}})

      [
        %({#{append},"content":#{first}}),
        %({#{append},"content":{"type":"terminal"}}),
        %({#{append},"content":false,"content":#{first}}),
        %({#{replace},"content":[#{replacement}]}),
        %({#{append},"content":#{future},"_meta":{"example.test/time":0.1234567890123456789}}),
        %({#{replace},"content":null}),
      ].each do |wire|
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":#{wire}}})
      end

      chunk = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::ToolCallContentChunk)
      chunk.content.content_block.as(ACP::Protocol::TextContentBlock).text.should eq("First")
      next_exact_session_update(observed).update.typed.should be_nil
      ambiguous = next_exact_session_update(observed)
      ambiguous.update.typed.should be_nil
      raw = ambiguous.raw.field("update").not_nil!.json
      ACP::Protocol::WireFrame.repeated_members(raw, "content").should contain("content")
      ACP::Protocol::V2::SessionUpdate.from_json(raw).typed.should be_nil

      update = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::ToolCallUpdate)
      update.content.not_nil!.first.content_block.as(ACP::Protocol::TextContentBlock).text.should eq("Replacement")
      chunk = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::ToolCallContentChunk)
      chunk.content.content_type.should eq("future")
      chunk.content.raw.field("details").not_nil!.field("sequence").not_nil!.json.should eq(UInt64::MAX.to_s)
      chunk.meta_raw.not_nil!.field("example.test/time").not_nil!.json.should eq("0.1234567890123456789")
      chunk.content.meta_raw.should be_nil
      clear = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::ToolCallUpdate)
      clear.content_present?.should be_true
      clear.content.should be_nil
    ensure
      client.try(&.close)
    end
  end
end
describe "ACP v2 display media and resources" do
  it "requires standard Base64 for media and a valid URI and payload for resources" do
    invalid = [
      %({"type":"image","mimeType":"image/png","data":"YQ"}),
      %({"type":"audio","mimeType":"audio/wav","data":"_w=="}),
      %({"type":"resource","resource":{"uri":"file:///work/data","blob":"YQ="}}),
      %({"type":"resource","resource":{"uri":"file:///work/invalid%ZZ","text":"content"}}),
      %({"type":"resource","resource":{"uri":"relative","text":"content"}}),
      %({"type":"resource_link","name":"Notes","uri":"https://[draft]/notes"}),
      %({"type":"resource_link","name":"Notes","uri":"relative/path"}),
    ]
    invalid.each do |wire|
      expect_raises(JSON::ParseException) { ACP::Protocol::ContentBlock.from_v2_json(wire) }
    end

    legacy = ACP::Protocol::ContentBlock.from_json(invalid.first).as(ACP::Protocol::ImageContentBlock)
    legacy.data.should eq("YQ")
    resource = ACP::Protocol::ContentBlock.from_v2_json(%({"type":"resource","resource":{"uri":"file:///work/notes","text":"","_meta":{"example.test/value":18446744073709551615}}})).as(ACP::Protocol::ResourceContentBlock)
    resource.text.should eq("")
    resource.resource_raw.field("_meta").not_nil!.field("example.test/value").not_nil!.json.should eq(UInt64::MAX.to_s)

    mixed = %({"type":"resource","resource":{"uri":"file:///work/notes","text":"usable","blob":"!!!!"}})
    typed = ACP::Protocol::ContentBlock.from_v2_json(mixed).as(ACP::Protocol::ResourceContentBlock)
    typed.text.should eq("usable")
    typed.blob.should be_nil
    typed.resource_raw.field("blob").not_nil!.as_s?.should eq("!!!!")
  end

  it "keeps valid display content when optional media and link fields are malformed" do
    invalid_uri = %({"type":"image","mimeType":"image/png","data":"YQ==","uri":"https://example.test/with space","_meta":{"example.test/value":0.1234567890123456789}})
    image = ACP::Protocol::ContentBlock.from_v2_json(invalid_uri).as(ACP::Protocol::ImageContentBlock)
    image.data.should eq("YQ==")
    image.uri.should be_nil
    image.meta_raw.not_nil!.field("example.test/value").not_nil!.json.should eq("0.1234567890123456789")
    valid_image = ACP::Protocol::ContentBlock.from_v2_json(%({"type":"image","mimeType":"image/png","data":"+/8=","uri":"https://[2001:db8::1]/a%20b.png#preview"})).as(ACP::Protocol::ImageContentBlock)
    valid_image.uri.should eq("https://[2001:db8::1]/a%20b.png#preview")

    wire = <<-JSON
      {"type":"resource_link","name":"Notes","uri":"file:///work/a%20b","size":-1,
       "icons":[{"src":"relative.png"},{"src":"http://example.test/insecure.png"},
                {"src":"file:///work/icon.png"},{"src":"https://example.test/with space.png"},
                {"src":"https:icon.png"},{"src":"https:///icon.png"},
                {"src":"https://user@example.test/icon.png"},
                {"src":"https://example%20test/icon.png"},{"src":"https://example.test:65536/icon.png"},
                {"src":"https://example.test:2147483648/icon.png"},{"src":"https://[1%25scope]/icon.png"},
                {"src":"https://%5Bexample.test%5D/icon.png"},
                {"src":"data:icon.png"},{"src":"data:text/plain;base64,YQ=="},
                {"src":"data:text/plain;base64,YQ==","mimeType":"image/png"},
                {"src":"data:application/octet-stream;base64,YQ=="},
                {"src":"data:image/png;base64,YQ="},{"src":"data:image/png,YQ=="},
                {"src":"https://example.test/first","src":"https://example.test/second"},
                {"src":"data:image/png;base64,YQ%3D%3D"},{"src":"HTTPS://example.test/icon.png"},
                {"src":"https://[2001:db8::1]:65535/icon.png"},
                {"src":"data:application/octet-stream;base64,YQ==","mimeType":"image/png"},
                {"src":"data:;base64,YQ==","mimeType":"image/png"}]}
      JSON
    link = ACP::Protocol::ContentBlock.from_v2_json(wire).as(ACP::Protocol::ResourceLinkContentBlock)
    link.size.should be_nil
    link.size_bytes.should be_nil
    link.icons.not_nil!.map(&.src).should eq([
      "data:image/png;base64,YQ%3D%3D",
      "HTTPS://example.test/icon.png",
      "https://[2001:db8::1]:65535/icon.png",
      "data:application/octet-stream;base64,YQ==",
      "data:;base64,YQ==",
    ])
    ACP::Protocol::ContentBlock.from_json(wire).as(ACP::Protocol::ResourceLinkContentBlock).size.should eq(-1_i64)

    duplicate_icons = %({"type":"resource_link","name":"Notes","uri":"file:///work/a","icons":[],"icons":[{"src":"https://example.test/icon.png"}]})
    ACP::Protocol::ContentBlock.from_v2_json(duplicate_icons).as(ACP::Protocol::ResourceLinkContentBlock).icons.should be_nil
    duplicate_uri = %({"type":"resource_link","name":"Notes","uri":"relative","uri":"file:///work/a","icons":[]})
    expect_raises(JSON::ParseException) { ACP::Protocol::ContentBlock.from_v2_json(duplicate_uri) }
  end

  it "applies the same display validation across messages and tool updates over stdio" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(4)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "s")

      invalid_audio = %({"type":"audio","mimeType":"audio/wav","data":"!!!!"})
      image = %({"type":"image","mimeType":"image/png","data":"YQ==","uri":"relative.png"})
      blob = %({"type":"resource","resource":{"uri":"file:///work/blob","blob":"+/8=","_meta":{"example.test/value":18446744073709551615}}})
      invalid_link = %({"type":"resource_link","uri":"relative","name":"Notes"})
      wrap_link = %({"type":"content","content":#{invalid_link}})
      wrap_blob = %({"type":"content","content":#{blob}})
      [
        %({"sessionUpdate":"agent_message","messageId":"m","content":[#{invalid_audio},#{image},#{blob}]}),
        %({"sessionUpdate":"agent_message_chunk","messageId":"m","content":#{invalid_audio}}),
        %({"sessionUpdate":"tool_call_update","toolCallId":"t","content":[#{wrap_link},#{wrap_blob}]}),
        %({"sessionUpdate":"tool_call_content_chunk","toolCallId":"t","content":#{wrap_link}}),
      ].each do |wire|
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":#{wire}}})
      end

      message = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::MessageUpdate)
      message.content_raw.not_nil!.elements?.not_nil!.size.should eq(3)
      blocks = message.content_blocks.not_nil!
      blocks.map(&.type).should eq(["image", "resource"])
      blocks.first.as(ACP::Protocol::ImageContentBlock).uri.should be_nil
      message_blob = blocks.last.as(ACP::Protocol::ResourceContentBlock)
      message_blob.blob.should eq("+/8=")
      message_blob.resource_raw.field("_meta").not_nil!.field("example.test/value").not_nil!.json.should eq(UInt64::MAX.to_s)

      chunk = next_exact_session_update(observed)
      chunk.update.typed.should be_nil
      chunk.raw.field("update").not_nil!.field("content").not_nil!.json.should eq(invalid_audio)
      tool = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::ToolCallUpdate)
      tool.content.not_nil!.size.should eq(1)
      tool.content.not_nil!.first.content_block.as(ACP::Protocol::ResourceContentBlock).resource_raw.json.should eq(message_blob.resource_raw.json)
      rejected = next_exact_session_update(observed)
      rejected.update.typed.should be_nil
      rejected.raw.field("update").not_nil!.field("content").not_nil!.json.should eq(wrap_link)
    ensure
      client.try(&.close)
    end
  end
end
describe "ACP v2 exact session state" do
  it "preserves exact numbers in typed snapshots and background items" do
    usage = %({"totalTokens":3,"inputTokens":2,"outputTokens":1,"_meta":{"example.test/value":18446744073709551615}})
    error = %({"code":-32603,"message":"Failed","data":{"ratio":0.1234567890123456789}})
    background = %([{"type":"tool_call","toolCallId":"tool"},{"type":"_future","rate":0.9876543210987654321}])
    wire = %({"state":"idle","stopReason":"error","error":#{error},"background":#{background},"usage":#{usage},"extension":0.1111111111111111111})
    snapshot = ACP::Protocol::V2::StateSnapshot.from_json(wire)
    snapshot.to_json.should contain("0.1111111111111111111")
    snapshot.background.not_nil!.last.to_json.should contain("0.9876543210987654321")
    snapshot.usage.not_nil!.to_json.should contain(UInt64::MAX.to_s)
    snapshot.error.not_nil!.message.should eq("Failed")
  end

  it "exposes exact state, background, usage, and error fields in typed snapshots" do
    meta = %({"example.test/value":18446744073709551615,"example.test/precision":0.1234567890123456789})
    usage = %({"totalTokens":3,"inputTokens":2,"outputTokens":1,"_meta":#{meta}})
    error = %({"code":-32603,"message":"Failed","data":{"wide":18446744073709551615}})
    work = %({"type":"future","revision":0.9876543210987654321,"_meta":#{meta}})
    state = %({"state":"idle","stopReason":"error","error":#{error},"background":[#{work}],"usage":#{usage},"_meta":#{meta}})
    status = ACP::Protocol::V2::SessionStatusResult.from_json(%({"status":"active","state":#{state}}))
    snapshot = status.state.not_nil!
    snapshot.meta_raw.not_nil!.json.should eq(meta)
    snapshot.raw.field("error").not_nil!.json.should eq(error)
    snapshot.error_raw.not_nil!.json.should eq(error)
    snapshot.error.not_nil!.code.should eq(-32603)
    snapshot.error.not_nil!.data.should be_nil
    snapshot.usage_raw.not_nil!.json.should eq(usage)
    snapshot.usage.not_nil!.meta_raw.not_nil!.json.should eq(meta)
    snapshot.background_raw.not_nil!.elements?.not_nil!.first.json.should eq(work)
    background = snapshot.background.not_nil!.first
    background.entity_id.should be_nil
    background.raw.field("revision").not_nil!.json.should eq("0.9876543210987654321")
    background.meta_raw.not_nil!.json.should eq(meta)

    error = %({"code":-32603,"code":-32602,"message":"Ambiguous"})
    malformed = ACP::Protocol::V2::StateSnapshot.from_json(%({"state":"idle","stopReason":"error","error":#{error}}))
    malformed.error.should be_nil
    malformed.error_raw.not_nil!.json.should eq(error)
  end

  it "keeps absent or ambiguous background reports distinct from an empty list" do
    [
      %({"state":"running"}),
      %({"state":"running","background":null}),
      %({"state":"running","background":"invalid"}),
      %({"state":"running","background":[{"type":"tool_call"}]}),
      %({"state":"running","background":[{"type":"tool_call","toolCallId":"one","toolCallId":"two"}]}),
      %({"state":"running","background":[{"type":"tool_call","toolCallId":"one"},{"type":"tool_call","toolCallId":"one"}]}),
      %({"state":"running","background":null,"background":[]}),
    ].each do |wire|
      ACP::Protocol::V2::StateSnapshot.from_json(wire).background.should be_nil
    end
    ACP::Protocol::V2::StateSnapshot.from_json(%({"state":"running","background":[]})).background.not_nil!.should be_empty
    future = ACP::Protocol::V2::StateSnapshot.from_json(%({"state":"future","background":[{"type":"other_future"},{"type":"other_future"}]}))
    future.idle?.should be_false
    future.background.not_nil!.map(&.entity_type).should eq(["other_future", "other_future"])
  end

  it "rejects ambiguous foreground states on direct and notification decoding" do
    wire = %({"sessionUpdate":"state_update","state":"running","state":"idle"})
    expect_raises(JSON::ParseException) { ACP::Protocol::V2::StateUpdate.from_json(wire) }
    expect_raises(JSON::ParseException) { ACP::Protocol::V2::StateSnapshot.from_json(wire) }
    ACP::Protocol::V2::SessionUpdate.from_json(wire).typed.should be_nil
  end

  it "keeps the exact root cache and typed notifications in sync over stdio" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(1)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "s")

      state = %({"sessionUpdate":"state_update","state":"running","background":[{"type":"_future","progress":0.1234567890123456789}]})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":#{state}}})
      first = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::StateUpdate)
      cached = client.session_state("s").not_nil!
      first.background_raw.should eq(cached.background_raw)
      cached.background.not_nil!.first.raw.field("progress").not_nil!.json.should eq("0.1234567890123456789")

      state = %({"sessionUpdate":"state_update","state":"running","state":"idle","background":[]})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":#{state}}})
      ambiguous = next_exact_session_update(observed)
      ambiguous.update.typed.should be_nil
      raw = ambiguous.raw.field("update").not_nil!
      ACP::Protocol::WireFrame.repeated_members(raw.json, "state").should contain("state")
      client.session_state("s").not_nil!.state.should eq("running")

      state = %({"sessionUpdate":"state_update","state":"idle","background":null,"background":[]})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":#{state}}})
      idle = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::StateUpdate)
      idle.idle?.should be_true
      idle.background.should be_nil
      client.session_state("s").not_nil!.background.should be_nil
      ACP::Protocol::WireFrame.repeated_members(client.session_state_raw("s").not_nil!.json, "background").should contain("background")

      state = %({"sessionUpdate":"state_update","state":"idle","background":[]})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":#{state}}})
      quiet = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::StateUpdate)
      quiet.background.not_nil!.should be_empty
      client.session_state("s").not_nil!.background.not_nil!.should be_empty
    ensure
      client.try(&.close)
    end
  end

  it "retains exact child state from parent announcements and child updates over stdio" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(1)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "root")

      meta = %({"example.test/rate":0.1234567890123456789})
      state = %({"state":"running","_meta":#{meta}})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":{"sessionUpdate":"subagent_update","sessionId":"child","state":#{state}}}})
      announced = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::SubagentUpdate)
      announced.state.not_nil!.meta_raw.not_nil!.json.should eq(meta)
      client.subagent("child").not_nil!.state.not_nil!.meta_raw.not_nil!.json.should eq(meta)

      state = %({"sessionUpdate":"state_update","state":"running","state":"idle"})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"child","update":#{state}}})
      next_exact_session_update(observed).update.typed.should be_nil
      client.subagent("child").not_nil!.state.not_nil!.state.should eq("running")

      background = %([{"type":"future","revision":0.1111111111111111111}])
      state = %({"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn","background":#{background}})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"child","update":#{state}}})
      finished = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::StateUpdate)
      cached = client.subagent("child").not_nil!.state.not_nil!
      cached.stop_reason.should eq("end_turn")
      cached.raw.field("background").should eq(finished.background_raw)
      cached.raw.field("background").not_nil!.json.should eq(background)

      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"child","update":{"sessionUpdate":"state_update","state":"running","background":null,"background":[]}}})
      state = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::StateUpdate)
      state.background.should be_nil
      client.subagent("child").not_nil!.state.not_nil!.raw.field("background").should be_nil

      [
        %("state":null,"state":{"state":"idle"}),
        %("state":{"state":false}),
        %("state":{"state":"idle","state":"idle"}),
      ].each do |field|
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":{"sessionUpdate":"subagent_update","sessionId":"child","title":"Retained",#{field}}}})
        patch = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::SubagentUpdate)
        patch.title.should eq("Retained")
        patch.state_present?.should be_false
        child = client.subagent("child").not_nil!
        child.title.should eq("Retained")
        child.state.not_nil!.state.should eq("running")
      end

      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":{"sessionUpdate":"subagent_update","sessionId":"child","state":null}}})
      clear = next_exact_session_update(observed).update.typed.as(ACP::Protocol::V2::SubagentUpdate)
      clear.state_present?.should be_true
      client.subagent("child").not_nil!.state.should be_nil
    ensure
      client.try(&.close)
    end
  end

  it "keeps precise decimals and rejects ambiguous state in v2 status responses over stdio" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      describe_state = %({"state":"idle","stopReason":"error","error":{"code":-32603,"message":"Failed","data":{"ratio":0.1234567890123456789}},"background":[{"type":"future","progress":0.9876543210987654321}]})
      responses = [
        %({"status":"open","state":#{describe_state}}),
        %({"status":"open","state":{"state":"idle","state":"running"}}),
        %({"status":"open","state":null,"state":{"state":"running"}}),
        %({"status":"open","_meta":{"example.test/version":18446744073709551615}}),
      ]
      spawn do
        init = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{init["id"]},"result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"status":{}}}}})
        responses.each do |result|
          request = JSON.parse(outgoing.gets.not_nil!)
          request["method"].should eq("session/status")
          feed.puts %({"jsonrpc":"2.0","id":#{request["id"]},"result":#{result}})
        end
      end
      client.initialize_connection

      state = client.session_status("unattached").state.not_nil!
      state.error_raw.not_nil!.field("data").not_nil!.field("ratio").not_nil!.json.should eq("0.1234567890123456789")
      state.background.not_nil!.first.raw.field("progress").not_nil!.json.should eq("0.9876543210987654321")
      2.times do
        status = client.session_status("unattached")
        status.open?.should be_true
        status.state.should be_nil
      end
      status = client.session_status("unattached")
      status.meta_raw.not_nil!.field("example.test/version").not_nil!.json.should eq(UInt64::MAX.to_s)
      client.session_state("unattached").should be_nil
    ensure
      client.try(&.close)
    end
  end
end
describe "ACP v2 subagent patch decoding" do
  it "keeps valid fields when optional child fields are malformed" do
    wire = %({"sessionId":"child","title":"Retained","description":false,"capabilities":[],"state":{"state":false},"cwd":"/work/child","additionalDirectories":[]})
    patch = ACP::Protocol::V2::SubagentUpdate.from_json(wire)
    patch.title.should eq("Retained")
    patch.description_present?.should be_false
    patch.capabilities_present?.should be_false
    patch.state_present?.should be_false
    patch.cwd.should eq("/work/child")
    patch.additional_directories.not_nil!.should be_empty
    encoded = JSON.parse(patch.to_json)
    encoded["description"]?.should be_nil
    encoded["capabilities"]?.should be_nil
    encoded["state"]?.should be_nil
  end

  it "requires an unambiguous child ID and absolute workspace paths" do
    [
      %({"sessionId":"one","sessionId":"two"}),
      %({"sessionId":"child","cwd":"relative"}),
      %({"sessionId":"child","cwd":"/work/one","cwd":"/work/two"}),
      %({"sessionId":"child","additionalDirectories":["/valid","relative"]}),
      %({"sessionId":"child","additionalDirectories":[],"additionalDirectories":null}),
    ].each do |wire|
      expect_raises(JSON::ParseException) { ACP::Protocol::V2::SubagentUpdate.from_json(wire) }
    end
  end

  it "treats ambiguous optional capabilities as unavailable" do
    wire = %({"sessionId":"child","capabilities":{"cancel":{}},"capabilities":false})
    patch = ACP::Protocol::V2::SubagentUpdate.from_json(wire)
    patch.capabilities_present?.should be_true
    patch.capabilities.should be_nil

    wire = %({"sessionId":"child","capabilities":{"cancel":null,"cancel":{},"_meta":{"example.test/sequence":18446744073709551615}}})
    patch = ACP::Protocol::V2::SubagentUpdate.from_json(wire)
    patch.capabilities_present?.should be_true
    patch.capabilities.not_nil!.cancel.should be_nil
    patch.capabilities.not_nil!.meta_raw.not_nil!.field("example.test/sequence").not_nil!.json.should eq(UInt64::MAX.to_s)
  end

  it "applies the typed child patch to workspace, metadata, and cancellation over stdio" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(1)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end
      spawn do
        init = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{init["id"]},"result":{"protocolVersion":2,"info":{"name":"agent","version":"1"},"capabilities":{"session":{"additionalDirectories":{}}}}})
        request = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{request["id"]},"result":{"sessionId":"root"}})
      end
      client.initialize_connection
      client.session_new(ACP::Protocol::V2::SessionNewParams.new("/work", additional_directories: ["/parent/extra"]))

      send_patch = ->(fields : String) do
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":{"sessionUpdate":"subagent_update",#{fields}}}})
        next_exact_session_update(observed)
      end
      first = %("sessionId":"child","title":"First","description":"Original","capabilities":{"cancel":{}},"cwd":"/work/child","additionalDirectories":[],"_meta":{"example.test/remove":true,"example.test/retain":18446744073709551615})
      send_patch.call(first).update.typed.as(ACP::Protocol::V2::SubagentUpdate).capabilities.not_nil!.cancel.should_not be_nil
      client.session_workspace("child").not_nil!.cwd.should eq("/work/child")
      client.session_workspace("child").not_nil!.additional_directories.should be_empty

      second = %("sessionId":"child","title":"Updated","description":false,"capabilities":[],"_meta":{"example.test/remove":null,"example.test/ratio":0.1234567890123456789})
      patch = send_patch.call(second).update.typed.as(ACP::Protocol::V2::SubagentUpdate)
      patch.description_present?.should be_false
      patch.capabilities_present?.should be_false
      child = client.subagent("child").not_nil!
      child.title.should eq("Updated")
      child.description.should eq("Original")
      child.cancel?.should be_true
      child.meta_raw.not_nil!.field("example.test/remove").should be_nil
      child.meta_raw.not_nil!.field("example.test/retain").not_nil!.json.should eq(UInt64::MAX.to_s)
      child.meta_raw.not_nil!.field("example.test/ratio").not_nil!.json.should eq("0.1234567890123456789")

      invalid = send_patch.call(%("sessionId":"child","cwd":"relative","title":"Discarded","capabilities":null))
      invalid.update.typed.should be_nil
      invalid.raw.field("update").not_nil!.field("cwd").not_nil!.as_s?.should eq("relative")
      client.subagent("child").not_nil!.title.should eq("Updated")
      client.session_workspace("child").not_nil!.cwd.should eq("/work/child")
      client.session_cancel("child")
      JSON.parse(outgoing.gets.not_nil!)["method"].should eq("session/cancel")

      ambiguous = send_patch.call(%("sessionId":"child","sessionId":"other","capabilities":{"cancel":{}}))
      ambiguous.update.typed.should be_nil
      client.subagent("other").should be_nil

      clear = send_patch.call(%("sessionId":"child","capabilities":null,"capabilities":{"cancel":{}},"cwd":null,"additionalDirectories":null,"_meta":null))
      patch = clear.update.typed.as(ACP::Protocol::V2::SubagentUpdate)
      patch.capabilities_present?.should be_true
      patch.capabilities.should be_nil
      client.subagent("child").not_nil!.cancel?.should be_false
      client.subagent("child").not_nil!.meta_raw.should be_nil
      client.session_workspace("child").not_nil!.cwd.should eq("/work")
      client.session_workspace("child").not_nil!.additional_directories.should eq(["/parent/extra"])
      expect_raises(ACP::InvalidStateError) { client.session_cancel("child") }
    ensure
      client.try(&.close)
    end
  end

  it "keeps malformed child announcements out of associations and cursor replay" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(2)
      raw = Channel(Nil).new(2)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end
      client.on_notification = ->(method : String, _params : JSON::Any?) do
        raw.send(nil) if method == "session/update"
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "root")

      child = %({"sessionUpdate":"subagent_update","sessionId":"phantom","capabilities":{"cancel":{}}})
      [
        %({"sessionId":"other","sessionId":"root","update":#{child}}),
        %({"sessionId":"root","update":{},"update":#{child}}),
        %({"sessionId":"root","update":{"sessionUpdate":"notice","sessionUpdate":"subagent_update","sessionId":"phantom"}}),
      ].each do |params|
        expect_raises(JSON::ParseException) { ACP::Protocol::V2::SessionUpdateParams.from_json(params) }
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":#{params}})
        next_permission_event(raw)
        client.subagent("phantom").should be_nil
      end

      resume = Channel(ACP::Protocol::V2::SessionResumeResult | Exception).new(1)
      spawn do
        params = ACP::Protocol::V2::SessionResumeParams.new("root", "/work", replay_from: ACP::Protocol::V2::ReplayFrom.start)
        resume.send(client.session_resume(params))
      rescue ex
        resume.send(ex)
      end
      request = JSON.parse(outgoing.gets.not_nil!)
      request["method"].should eq("session/resume")
      send_update = ->(sid : String, update : String) do
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":#{sid.to_json},"update":#{update}}})
        next_exact_session_update(observed)
      end
      invalid = send_update.call("root", %({"sessionUpdate":"subagent_update","sessionId":"other","cwd":"relative"}))
      invalid.update.typed.should be_nil
      client.subagent("other").should be_nil
      send_update.call("other", %({"sessionUpdate":"cursor_update","cursorId":"live"}))
      client.session_cursor("other", "live").should_not be_nil

      send_update.call("root", %({"sessionUpdate":"replay_complete"}))
      send_update.call("root", %({"sessionUpdate":"state_update","state":"idle"}))
      feed.puts %({"jsonrpc":"2.0","id":#{request["id"]},"result":{}})
      next_permission_event(resume).should be_a(ACP::Protocol::V2::SessionResumeResult)
      client.session_cursor("other", "live").should_not be_nil
    ensure
      client.try(&.close)
    end
  end
end
describe "ACP v2 session-directed message patches" do
  it "keeps usable patches when individual participant fields are malformed" do
    wire = %({"sessionUpdate":"session_message","messageId":"local","senderSessionId":false,"recipientSessionId":"child","senderMessageId":null,"recipientMessageId":[],"content":[false,{"type":"text","text":"Hello"},{"type":"future","value":0.1234567890123456789}],"_meta":{"example.test/count":18446744073709551615}})
    update = ACP::Protocol::V2::SessionUpdate.from_json(wire).typed.as(ACP::Protocol::V2::SessionMessageUpdate)
    update.message_id.should eq("local")
    update.sender_session_id_present?.should be_false
    update.recipient_session_id.should eq("child")
    update.sender_message_id_present?.should be_true
    update.sender_message_id.should be_nil
    update.recipient_message_id_present?.should be_false
    update.content_raw.not_nil!.elements?.not_nil!.size.should eq(3)
    blocks = update.content_blocks.not_nil!
    blocks.map(&.type).should eq(["text", "future"])
    blocks.last.as(ACP::Protocol::UnknownContentBlock).raw.field("value").not_nil!.json.should eq("0.1234567890123456789")
    update.meta_raw.not_nil!.field("example.test/count").not_nil!.json.should eq(UInt64::MAX.to_s)
    encoded = ACP::Protocol::RawJson.from_json(update.to_json)
    encoded.field("senderSessionId").should be_nil
    encoded.field("recipientMessageId").should be_nil
    encoded.field("senderMessageId").not_nil!.null?.should be_true
  end

  it "rejects a repeated local ID and treats repeated optional patch fields as omitted" do
    wire = %({"sessionUpdate":"session_message","messageId":"old","messageId":"new","content":[]})
    expect_raises(JSON::ParseException) { ACP::Protocol::V2::SessionMessageUpdate.from_json(wire) }
    ACP::Protocol::V2::SessionUpdate.from_json(wire).typed.should be_nil

    wire = %({"sessionUpdate":"session_message","messageId":"local","senderSessionId":null,"senderSessionId":"another","recipientMessageId":"peer","content":null,"content":[],"_meta":null,"_meta":{"example.test/data":true}})
    [ACP::Protocol::V2::SessionMessageUpdate.from_json(wire), ACP::Protocol::V2::SessionUpdate.from_json(wire).typed.as(ACP::Protocol::V2::SessionMessageUpdate)].each do |update|
      update.sender_session_id_present?.should be_false
      update.recipient_message_id.should eq("peer")
      update.content_present?.should be_false
      update.meta_present?.should be_false
    end
  end

  it "requires one usable content block and an unambiguous local ID for a streamed message" do
    base = %("sessionUpdate":"session_message_chunk","messageId":"local")
    [
      %({#{base},"content":null}),
      %({#{base},"content":{"type":"image","data":"bad","mimeType":"image/png"}}),
      %({#{base},"content":{"type":"skill","name":"draft"}}),
      %({#{base},"content":false,"content":{"type":"text","text":"Ambiguous"}}),
      %({#{base},"messageId":"other","content":{"type":"text","text":"Ambiguous"}}),
    ].each do |wire|
      expect_raises(JSON::ParseException) { ACP::Protocol::V2::MessageChunkUpdate.from_json(wire) }
      ACP::Protocol::V2::SessionUpdate.from_json(wire).typed.should be_nil
    end

    valid = %({#{base},"content":{"type":"text","text":"Kept"},"_meta":null,"_meta":{"example.test/value":true}})
    chunk = ACP::Protocol::V2::SessionUpdate.from_json(valid).typed.as(ACP::Protocol::V2::MessageChunkUpdate)
    chunk.to_content_chunk.not_nil!.content.as(ACP::Protocol::TextContentBlock).text.should eq("Kept")
    chunk.meta_raw.should be_nil
  end

  it "delivers each transcript's chunks and explicit links in receive order over stdio" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(1)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "root")
      send_update = ->(sid : String, update : String) do
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":#{sid.to_json},"update":#{update}}})
        next_exact_session_update(observed)
      end
      send_update.call("root", %({"sessionUpdate":"subagent_update","sessionId":"child"}))

      first = send_update.call("child", %({"sessionUpdate":"session_message_chunk","messageId":"incoming","content":{"type":"future","detail":18446744073709551615},"_meta":{"example.test/chunk":0.1234567890123456789}}))
      first.session_id.should eq("child")
      chunk = first.update.typed.as(ACP::Protocol::V2::MessageChunkUpdate)
      chunk.message_id.should eq("incoming")
      block = chunk.to_content_chunk.not_nil!.content.as(ACP::Protocol::UnknownContentBlock)
      block.raw.field("detail").not_nil!.json.should eq(UInt64::MAX.to_s)
      chunk.meta_raw.not_nil!.field("example.test/chunk").not_nil!.json.should eq("0.1234567890123456789")

      equivalent = send_update.call("root", %({"sessionUpdate":"session_message","messageId":"incoming","recipientSessionId":"child"}))
      equivalent.session_id.should eq("root")
      coincident = equivalent.update.typed.as(ACP::Protocol::V2::SessionMessageUpdate)
      coincident.recipient_message_id_present?.should be_false

      malformed = send_update.call("child", %({"sessionUpdate":"session_message_chunk","messageId":"incoming","content":false,"content":{"type":"text","text":"Ignored"}}))
      malformed.update.typed.should be_nil
      raw = malformed.raw.field("update").not_nil!
      ACP::Protocol::WireFrame.repeated_members(raw.json, "content").should contain("content")

      parent = send_update.call("root", %({"sessionUpdate":"session_message","messageId":"outgoing","recipientSessionId":"child","recipientMessageId":"incoming","senderMessageId":false,"content":[]}))
      linked = parent.update.typed.as(ACP::Protocol::V2::SessionMessageUpdate)
      linked.recipient_message_id.should eq("incoming")
      linked.sender_message_id_present?.should be_false
      linked.content_present?.should be_true
      linked.content_blocks.not_nil!.should be_empty

      child = send_update.call("child", %({"sessionUpdate":"session_message","messageId":"incoming","senderSessionId":"root","senderMessageId":"outgoing","content":null}))
      child.session_id.should eq("child")
      delivered = child.update.typed.as(ACP::Protocol::V2::SessionMessageUpdate)
      delivered.sender_session_id.should eq("root")
      delivered.sender_message_id.should eq("outgoing")
      delivered.content_present?.should be_true
      delivered.content.should be_nil
    ensure
      client.try(&.close)
    end
  end
end
describe "ACP v2 session detail patch decoding" do
  it "keeps the usable session info fields and preserves valid timestamp strings" do
    wire = %({"sessionUpdate":"session_info_update","title":[],"updatedAt":"2026-11-22T00:00:00.123456789012345+09:00"})
    info = ACP::Protocol::V2::SessionUpdate.from_json(wire).typed.as(ACP::Protocol::V2::SessionInfoUpdate)
    info.title_present?.should be_false
    info.updated_at.should eq("2026-11-22T00:00:00.123456789012345+09:00")

    [
      "2026-02-29T00:00:00Z",
      "2026-11-22T00:00:00Zjunk",
      "2026-11-22T00:00:00+24:00",
      "2016-12-31T12:00:60Z",
      "2016-12-30T23:59:60Z",
      "yesterday",
    ].each do |time|
      update = ACP::Protocol::V2::SessionInfoUpdate.from_json(%({"title":"Kept","updatedAt":#{time.to_json}}))
      update.title.should eq("Kept")
      update.updated_at_present?.should be_false
    end
    ["2016-12-31T23:59:60Z", "2017-01-01T08:59:60+09:00", "1990-12-31T15:59:60-08:00", "0000-02-29T00:00:00Z"].each do |time|
      ACP::Protocol::V2::SessionInfoUpdate.from_json(%({"updatedAt":#{time.to_json}})).updated_at.should eq(time)
    end
    clear = ACP::Protocol::V2::SessionInfoUpdate.from_json(%({"updatedAt":null}))
    clear.updated_at_present?.should be_true
    clear.updated_at.should be_nil
  end

  it "omits invalid costs while preserving counts and distinguishing an explicit clear" do
    base = %("sessionUpdate":"usage_update","used":18446744073709551615,"size":200)
    [
      "[]",
      %({"currency":"USD"}),
      %({"amount":"1","currency":"USD"}),
      %({"amount":1e999,"currency":"USD"}),
      %({"amount":1.0,"amount":2.0,"currency":"USD"}),
    ].each do |cost|
      usage = ACP::Protocol::V2::SessionUpdate.from_json(%({#{base},"cost":#{cost}})).typed.as(ACP::Protocol::V2::UsageUpdate)
      usage.used.should eq(UInt64::MAX)
      usage.size.should eq(200_u64)
      usage.cost_present?.should be_false
      ACP::Protocol::RawJson.from_json(usage.to_json).field("cost").should be_nil
    end

    clear = ACP::Protocol::V2::UsageUpdate.from_json(%({#{base},"cost":null}))
    clear.cost_present?.should be_true
    clear.cost.should be_nil
    ["10000000000000000000", "1e19"].each do |amount|
      usage = ACP::Protocol::V2::UsageUpdate.from_json(%({#{base},"cost":{"amount":#{amount},"currency":"credits"}}))
      usage.cost.not_nil!.amount.should eq(1e19)
    end
    expect_raises(JSON::ParseException) { ACP::Protocol::V2::UsageUpdate.from_json(%({#{base},"used":1})) }
  end

  it "preserves the exact v2 cost amount across typed reads, metadata edits, and serialization" do
    amount = "10000000000000000001"
    number = "0.123456789012345678901"
    update = ACP::Protocol::V2::UsageUpdate.from_json(%({"used":1,"size":10,"cost":{"amount":#{amount},"currency":"credits","_meta":{"number":#{number},"edit":false}}}))
    update.cost.not_nil!.amount.should eq(1e19)
    update.cost_raw.not_nil!.field("amount").not_nil!.json.should eq(amount)
    update.cost.not_nil!.meta.not_nil!["edit"] = JSON::Any.new(true)
    serialized = ACP::Protocol::RawJson.from_json(update.to_json).field("cost").not_nil!
    serialized.field("amount").not_nil!.json.should eq(amount)
    serialized.field("_meta").not_nil!.field("number").not_nil!.json.should eq(number)
    serialized.field("_meta").not_nil!.field("edit").not_nil!.json.should eq("true")
    update.cost = ACP::Protocol::Cost.new(0.5, "USD")
    update.cost_raw.not_nil!.field("amount").not_nil!.json.should eq("0.5")
    round_trip = ACP::Protocol::V2::UsageUpdate.from_json(update.to_json)
    round_trip.should eq(update)
    round_trip.hash.should eq(update.hash)
    update.cost = nil
    update.cost_present?.should be_true
    update.cost_raw.should be_nil
    ACP::Protocol::RawJson.from_json(update.to_json).field("cost").not_nil!.null?.should be_true
  end

  it "keeps valid compaction fields and rejects unusable streamed summaries" do
    base = %("sessionUpdate":"compaction_update","compactionId":"c")
    update = ACP::Protocol::V2::SessionUpdate.from_json(%({#{base},"status":false,"error":"Kept","summary":[false,{"type":"text","text":"Summary"}]})).typed.as(ACP::Protocol::V2::CompactionUpdate)
    update.status_present?.should be_false
    update.error.should eq("Kept")
    update.summary_raw.not_nil!.elements?.not_nil!.size.should eq(2)
    update.typed_summary.not_nil!.map(&.type).should eq(["text"])

    bad = %({"sessionUpdate":"compaction_summary_chunk","compactionId":"c","content":false})
    expect_raises(JSON::ParseException) { ACP::Protocol::CompactionSummaryChunkUpdate.from_v2_json(bad) }
    ACP::Protocol::V2::SessionUpdate.from_json(bad).typed.should be_nil
  end

  it "preserves exact session details and clear semantics over stdio" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(1)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "s")
      send_update = ->(wire : String) do
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":#{wire}}})
        next_exact_session_update(observed)
      end

      info = send_update.call(%({"sessionUpdate":"session_info_update","title":null,"title":"Ambiguous","updatedAt":"2026-11-22T09:00:00+09:00"}))
      patch = info.update.typed.as(ACP::Protocol::V2::SessionInfoUpdate)
      patch.title_present?.should be_false
      patch.updated_at.should eq("2026-11-22T09:00:00+09:00")
      ACP::Protocol::WireFrame.repeated_members(info.raw.field("update").not_nil!.json, "title").should contain("title")

      cost = %({"amount":0.1234567890123456789,"currency":"credits","_meta":{"example.test/value":18446744073709551615}})
      usage = send_update.call(%({"sessionUpdate":"usage_update","used":3,"size":10,"cost":#{cost}}))
      usage.raw.field("update").not_nil!.field("cost").not_nil!.json.should eq(cost)
      usage.update.typed.as(ACP::Protocol::V2::UsageUpdate).cost.not_nil!.meta_raw.not_nil!.field("example.test/value").not_nil!.json.should eq(UInt64::MAX.to_s)
      invalid = send_update.call(%({"sessionUpdate":"usage_update","used":3,"used":4,"size":10,"cost":null}))
      invalid.update.typed.should be_nil

      chunk = send_update.call(%({"sessionUpdate":"compaction_summary_chunk","compactionId":"c","content":{"type":"_future","value":0.9876543210987654321}}))
      block = chunk.update.typed.as(ACP::Protocol::CompactionSummaryChunkUpdate).content_block.as(ACP::Protocol::UnknownContentBlock)
      block.raw.field("value").not_nil!.json.should eq("0.9876543210987654321")
      malformed = send_update.call(%({"sessionUpdate":"compaction_summary_chunk","compactionId":"c","content":false,"content":{"type":"text","text":"ambiguous"}}))
      malformed.update.typed.should be_nil
      ACP::Protocol::WireFrame.repeated_members(malformed.raw.field("update").not_nil!.json, "content").should contain("content")

      patch = send_update.call(%({"sessionUpdate":"compaction_update","compactionId":"c","status":"future","error":{},"summary":[],"summary":null})).update.typed.as(ACP::Protocol::V2::CompactionUpdate)
      patch.status.should eq("future")
      patch.error_present?.should be_false
      patch.summary_present?.should be_false
      clear = send_update.call(%({"sessionUpdate":"compaction_update","compactionId":"c","status":null,"error":null,"summary":null})).update.typed.as(ACP::Protocol::V2::CompactionUpdate)
      clear.status_present?.should be_true
      clear.error_present?.should be_true
      clear.summary_present?.should be_true
      clear.summary.should be_nil
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP session list response recovery" do
  it "keeps valid v1 sessions and workspace roots in order" do
    page = ACP::Protocol::SessionListResult.from_json(<<-JSON)
      {"sessions":[
        {"sessionId":"first","cwd":"/one","title":false,"updatedAt":12,"_meta":[],"archived":false,
         "additionalDirectories":["/extra",13,"relative","D:/shared"]},
        {"sessionId":"missing-directory"},
        {"sessionId":12,"cwd":"/bad"},
        {"sessionId":"relative","cwd":"relative"},
        {"sessionId":"ambiguous","sessionId":"other","cwd":"/bad"},
        42,
        {"sessionId":"last","cwd":"/last","title":"Last","updatedAt":"2026-11-22"},
        {"sessionId":"roots","cwd":"/roots","additionalDirectories":{}}
      ],"nextCursor":true,"_meta":false}
      JSON

    page.sessions.map(&.session_id).should eq(["first", "last", "roots"])
    first = page.sessions.first
    first.additional_directories.should eq(["/extra", "D:/shared"])
    first.title.should be_nil
    first.updated_at.should be_nil
    first.meta.should be_nil
    first.archived.should eq(false)
    JSON.parse(first.to_json)["archived"].should eq(false)
    page.sessions[1].updated_at.should eq("2026-11-22")
    page.sessions.last.additional_directories.should be_nil
    page.has_more?.should be_false
    page.meta.should be_nil
  end

  it "returns an empty page for an unusable session list while preserving its cursor" do
    ["null", "{}", "false"].each do |invalid|
      wire = %({"sessions":#{invalid},"nextCursor":""})
      [
        ACP::Protocol::SessionListResult.from_json(wire),
        ACP::Protocol::V2::SessionListResult.from_v2_json(wire),
      ].each do |page|
        page.sessions.should be_empty
        page.has_more?.should be_true
        page.next_cursor.should eq("")
      end
    end
  end

  it "preserves exact session and page metadata in v1 stdio responses" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::Client.new(transport)
      client.request_timeout = 2.0
      meta = %({"count":18446744073709551615,"ratio":0.1234567890123456789,"label":"visible"})
      spawn do
        initialize_request = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{initialize_request["id"]},"result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"list":{}}}}})
        request = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{request["id"]},"result":{"sessions":[null,{"sessionId":"session","cwd":"/work","_meta":#{meta}}],"_meta":#{meta}}})
      end
      client.initialize_connection

      page = client.session_list
      page.sessions.map(&.session_id).should eq(["session"])
      page.meta.not_nil!["label"].should eq("visible")
      page.sessions.first.meta.not_nil!["label"].should eq("visible")
      page.to_json.scan(%("_meta":#{meta})).size.should eq(2)
    ensure
      client.try(&.close)
    end
  end

  it "returns usable v2 sessions and sends the opaque empty cursor unchanged over stdio" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      initialize_wide_v2(client, feed, outgoing, session_id: "open")
      calls = Channel(JSON::Any).new(1)
      timestamp = "2026-11-22T13:20:00.1234567890123+09:00"
      meta = %({"ratio":0.1234567890123456789,"flag":true})
      first_page = <<-JSON
        {"sessions":[
          {"sessionId":"first","cwd":"/work","title":"Valid","updatedAt":#{timestamp.to_json},
           "additionalDirectories":["/data"],"_meta":#{meta}},
          {"sessionId":"bad-roots","cwd":"/work","additionalDirectories":["/data",1]},
          {"sessionId":"bad-path","cwd":"/work","additionalDirectories":["relative"]},
          {"sessionId":"duplicate-roots","cwd":"/work","additionalDirectories":["/one"],"additionalDirectories":["/two"]},
          {"sessionId":"one","sessionId":"two","cwd":"/work"},
          {"sessionId":"last","cwd":"/work","title":1,"updatedAt":"yesterday","additionalDirectories":null}
        ],"nextCursor":""}
        JSON
      spawn do
        request = JSON.parse(outgoing.gets.not_nil!)
        calls.send(request)
        feed.puts %({"jsonrpc":"2.0","id":#{request["id"]},"result":#{first_page.lines.join}})
      end

      page = client.session_list(ACP::Protocol::V2::SessionListParams.new(cwd: "/work"))
      page.sessions.map(&.session_id).should eq(["first", "last"])
      page.sessions.first.updated_at.should eq(timestamp)
      page.sessions.first.additional_directories.should eq(["/data"])
      page.sessions.last.updated_at.should be_nil
      page.sessions.last.title.should be_nil
      page.sessions.last.additional_directories.should be_nil
      page.meta_raw.should be_nil
      page.sessions.first.meta_raw.not_nil!.json.should eq(meta)
      page.has_more?.should be_true
      page.next_cursor.should eq("")

      next_permission_event(calls)["params"].as_h.should eq(JSON.parse(%({"cwd":"/work"})).as_h)
      spawn do
        request = JSON.parse(outgoing.gets.not_nil!)
        calls.send(request)
        feed.puts %({"jsonrpc":"2.0","id":#{request["id"]},"result":{"sessions":[],"nextCursor":null}})
      end
      last = client.session_list(ACP::Protocol::V2::SessionListParams.new(cwd: "/work", cursor: page.next_cursor))
      next_permission_event(calls)["params"].as_h.should eq(JSON.parse(%({"cwd":"/work","cursor":""})).as_h)
      last.has_more?.should be_false
    ensure
      client.try(&.close)
    end
  end

  it "rejects an invalid v2 pagination cursor without closing the connection" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      initialize_wide_v2(client, feed, outgoing, session_id: "open")
      [
        %({"sessions":[],"nextCursor":false}),
        %({"nextCursor":"one","nextCursor":"two"}),
      ].each do |invalid|
        spawn do
          request = JSON.parse(outgoing.gets.not_nil!)
          feed.puts %({"jsonrpc":"2.0","id":#{request["id"]},"result":#{invalid}})
        end
        expect_raises(ACP::ProtocolError, /malformed result for 'session\/list'/) { client.session_list }
      end

      spawn do
        request = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{request["id"]},"result":{"sessions":[]}})
      end
      client.session_list.has_more?.should be_false
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP v2 transcript message decoding" do
  it "rejects ambiguous upsert identities and leaves conflicting optional fields out of the patch" do
    {"user_message", "agent_message", "agent_thought"}.each do |kind|
      identity = %({"sessionUpdate":#{kind.to_json},"messageId":"original","messageId":"other"})
      expect_raises(JSON::ParseException) { ACP::Protocol::V2::MessageUpdate.from_json(identity) }
      ACP::Protocol::V2::SessionUpdate.from_json(identity).typed.should be_nil

      ambiguous_content = %({"sessionUpdate":#{kind.to_json},"messageId":"m",
        "content":null,"content":[],"_meta":{"example.test/sequence":18446744073709551615}})
      direct = ACP::Protocol::V2::MessageUpdate.from_json(ambiguous_content)
      open = ACP::Protocol::V2::SessionUpdate.from_json(ambiguous_content)
      [direct, open.typed.as(ACP::Protocol::V2::MessageUpdate)].each do |update|
        update.content_present?.should be_false
        update.meta_present?.should be_true
        update.meta_raw.not_nil!.field("example.test/sequence").not_nil!.json.should eq(UInt64::MAX.to_s)
      end

      ambiguous_meta = %({"sessionUpdate":#{kind.to_json},"messageId":"m",
        "_meta":null,"_meta":{"value":true},"content":null})
      update = ACP::Protocol::V2::SessionUpdate.from_json(ambiguous_meta).typed.as(ACP::Protocol::V2::MessageUpdate)
      update.meta_present?.should be_false
      update.content_present?.should be_true
      update.content.should be_nil
    end
  end

  it "requires one usable block in each streamed message and accepts a draft user skill" do
    custom = %({"type":"_example.test/chart","value":0.1234567890123456789})
    skill = %({"type":"skill","name":"plugin:notes"})
    {"user_message_chunk", "agent_message_chunk", "agent_thought_chunk"}.each do |kind|
      base = %("sessionUpdate":#{kind.to_json},"messageId":"m")
      [
        %({#{base}}),
        %({#{base},"content":null}),
        %({#{base},"content":{"type":"text","text":false}}),
        %({#{base},"content":{"type":"image","data":"!","mimeType":"image/png"}}),
        %({#{base},"content":#{custom},"content":#{custom}}),
        %({#{base},"messageId":"other","content":#{custom}}),
      ].each do |invalid|
        expect_raises(JSON::ParseException) { ACP::Protocol::V2::MessageChunkUpdate.from_json(invalid) }
        ACP::Protocol::V2::SessionUpdate.from_json(invalid).typed.should be_nil
      end

      wire = %({#{base},"content":#{custom},"_meta":{"label":"first"},"_meta":null})
      chunk = ACP::Protocol::V2::SessionUpdate.from_json(wire).typed.as(ACP::Protocol::V2::MessageChunkUpdate)
      chunk.meta_raw.should be_nil
      display = chunk.to_content_chunk.not_nil!
      display.message_id.should eq("m")
      display.content.as(ACP::Protocol::UnknownContentBlock).raw.json.should eq(custom)

      skill_update = ACP::Protocol::V2::SessionUpdate.from_json(%({#{base},"content":#{skill}})).typed
      if kind == "user_message_chunk"
        reference = skill_update.as(ACP::Protocol::V2::MessageChunkUpdate)
        reference.skill_reference.not_nil!.name.should eq("plugin:notes")
        reference.to_content_chunk.should be_nil
      else
        skill_update.should be_nil
      end
    end
  end

  it "checks the identity of serialized v2 content wrappers without requiring a compaction message ID" do
    content = %("content":{"type":"text","text":"Usable"})
    [
      %({#{content},"messageId":"first","messageId":"second"}),
      %({#{content},"messageId":false}),
      %({#{content},#{content}}),
    ].each do |wire|
      expect_raises(JSON::ParseException) { ACP::Protocol::ContentChunk.from_v2_json(wire) }
    end

    decoded = ACP::Protocol::ContentChunk.from_v2_json(%({#{content},"_meta":null,"_meta":{"scoped":true}}))
    decoded.message_id.should be_nil
    decoded.meta_raw.should be_nil
    decoded.text.should eq("Usable")
  end

  it "delivers chunk-first messages and their patches in order while keeping invalid wire content" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      observed = Channel(ACP::Protocol::V2::SessionUpdateParams).new(1)
      client.on_update = ->(note : ACP::Protocol::V2::SessionUpdateParams) do
        observed.send(note)
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "root")
      send_update = ->(wire : String) do
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":#{wire}}})
        next_exact_session_update(observed)
      end

      {"user_message", "agent_thought", "agent_message"}.each do |kind|
        wire = %({"sessionUpdate":#{"#{kind}_chunk".to_json},"messageId":"same","content":{"type":"text","text":#{kind.to_json}}})
        first = send_update.call(wire).update.typed.as(ACP::Protocol::V2::MessageChunkUpdate)
        first.session_update.should eq("#{kind}_chunk")
        first.message_id.should eq("same")
        first.to_content_chunk.not_nil!.content.as(ACP::Protocol::TextContentBlock).text.should eq(kind)
      end

      ambiguous = send_update.call(%({"sessionUpdate":"agent_thought","messageId":"same","messageId":"other"}))
      ambiguous.update.typed.should be_nil
      ambiguous.raw.field("update").not_nil!.json.scan(%("messageId")).size.should eq(2)

      invalid_media = %({"type":"audio","mimeType":"audio/wav","data":"!!!"})
      malformed = send_update.call(%({"sessionUpdate":"agent_message_chunk","messageId":"same","content":#{invalid_media}}))
      malformed.update.typed.should be_nil
      malformed.raw.field("update").not_nil!.field("content").not_nil!.json.should eq(invalid_media)

      content = %([{"type":"text","text":"replacement"},false,{"type":"future","value":18446744073709551615}])
      patch = send_update.call(%({"sessionUpdate":"agent_message","messageId":"same","content":#{content},"_meta":null}))
      message = patch.update.typed.as(ACP::Protocol::V2::MessageUpdate)
      message.message_id.should eq("same")
      message.content_present?.should be_true
      message.content_blocks.not_nil!.map(&.type).should eq(["text", "future"])
      message.content_raw.not_nil!.json.should eq(content)
      message.meta_present?.should be_true
      message.meta_raw.should be_nil

      next_chunk = send_update.call(%({"sessionUpdate":"agent_message_chunk","messageId":"same","content":{"type":"text","text":"append"}}))
      next_chunk.update.typed.as(ACP::Protocol::V2::MessageChunkUpdate).to_content_chunk.not_nil!.content.as(ACP::Protocol::TextContentBlock).text.should eq("append")
    ensure
      client.try(&.close)
    end
  end
end

private def answer_identity_request(feed : IO, outgoing : IO, result : String) : Nil
  spawn do
    request = JSON.parse(outgoing.gets.not_nil!)
    feed.puts %({"jsonrpc":"2.0","id":#{request["id"]},"result":#{result}})
  end
end

describe "ACP v1 exact session and turn replies" do
  {"load", "resume", "set_config_option", "prompt"}.each do |operation|
    {"wide integer" => "18446744073709551615", "precise decimal" => "1.23000000000000000001"}.each do |label, number|
      it "preserves a #{label} in a session/#{operation} reply" do
        with_wide_stdio do |transport, feed, outgoing|
          client = ACP::Client.new(transport)
          client.request_timeout = 2.0
          client.prompt_timeout = 2.0
          answer_identity_request(feed, outgoing, %({"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"resume":{}}}}))
          client.initialize_connection

          original = choice_state_option("id", "fast", ["fast", "large"])
          answer_identity_request(feed, outgoing, %({"sessionId":"root","configOptions":[#{original}]}))
          client.session_new("/work")

          updated = choice_state_option("id", "large", ["fast", "large"])
          fields = operation == "prompt" ? %("stopReason":"end_turn") : %("configOptions":[#{updated}])
          metadata = %({"example.test/source":"agent","example.test/number":#{number}})
          answer_identity_request(feed, outgoing, %({#{fields},"_meta":#{metadata}}))
          result = case operation
                   when "load"              then client.session_load("root", "/work")
                   when "resume"            then client.session_resume("root", "/work")
                   when "set_config_option" then client.session_set_config_option("model", "large")
                   else                          client.session_prompt_text("Hello")
                   end
          result.meta.try(&.["example.test/source"]?).should eq("agent")
          result.meta_raw.not_nil!.json.should eq(metadata)
          result.to_json.should contain(%("_meta":#{metadata}))
          if result.is_a?(ACP::Protocol::SessionPromptResult)
            result.stop_reason.should eq("end_turn")
          else
            result.config_options.not_nil!.first.current_value.should eq("large")
            client.session_config_options.not_nil!.first.current_value.should eq("large")
          end
        ensure
          client.try(&.close)
        end
      end
    end
  end

  it "preserves exact token usage metadata in a prompt reply with no outer metadata" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::Client.new(transport)
      client.request_timeout = 2.0
      client.prompt_timeout = 2.0
      answer_identity_request(feed, outgoing, %({"protocolVersion":1}))
      client.initialize_connection
      answer_identity_request(feed, outgoing, %({"sessionId":"root"}))
      client.session_new("/work")

      metadata = %({"example.test/ratio":1.23000000000000000001})
      usage = %({"totalTokens":3,"inputTokens":1,"outputTokens":2,"_meta":#{metadata}})
      answer_identity_request(feed, outgoing, %({"stopReason":"end_turn","usage":#{usage}}))
      result = client.session_prompt_text("Hello")
      result.usage.not_nil!.total_tokens.should eq(3)
      result.usage.not_nil!.meta_raw.not_nil!.json.should eq(metadata)
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP v1 usage notifications" do
  it "keeps required counts when optional cost and metadata are malformed" do
    fields = %("sessionUpdate":"usage_update","used":10,"size":100)
    [
      "null",
      "false",
      "[]",
      %({"currency":"credits"}),
      %({"amount":"1","currency":"credits"}),
      %({"amount":1e999,"currency":"credits"}),
      %({"amount":1,"amount":2,"currency":"credits"}),
    ].each do |cost|
      usage = ACP::Protocol::SessionUpdate.from_json(%({#{fields},"cost":#{cost},"_meta":false})).as(ACP::Protocol::UsageUpdate)
      usage.used.should eq(10_u64)
      usage.size.should eq(100_u64)
      usage.usage_ratio.should eq(0.1)
      usage.cost.should be_nil
      usage.cost_raw.should be_nil
      usage.meta.should be_nil
      ACP::Protocol::RawJson.from_json(usage.to_json).field("cost").should be_nil
    end

    expect_raises(JSON::ParseException) do
      ACP::Protocol::SessionUpdate.from_json(%({"sessionUpdate":"usage_update","used":-1,"size":100}))
    end
  end

  it "delivers exact cost and metadata through a typed stdio callback" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::Client.new(transport)
      client.request_timeout = 2.0
      answer_identity_request(feed, outgoing, %({"protocolVersion":1}))
      client.initialize_connection
      answer_identity_request(feed, outgoing, %({"sessionId":"root"}))
      client.session_new("/work")

      updates = Channel(ACP::Protocol::UsageUpdate).new(1)
      client.on_update = ->(note : ACP::Protocol::SessionUpdateParams) do
        if usage = note.update.as?(ACP::Protocol::UsageUpdate)
          updates.send(usage)
        end
        nil
      end
      amount = "10000000000000000001"
      metadata = %({"example.test/count":18446744073709551615,"example.test/ratio":1.23000000000000000001})
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":{"type":"usage_update","used":9223372036854775808,"size":18446744073709551615,"cost":{"amount":#{amount},"currency":"credits","_meta":#{metadata}},"_meta":#{metadata}}}})
      answer_identity_request(feed, outgoing, "{}")
      client.ext_method("barrier")
      select
      when usage = updates.receive
        usage.used.should eq(9223372036854775808_u64)
        usage.size.should eq(UInt64::MAX)
        usage.cost.not_nil!.amount.should eq(1e19)
        usage.cost.not_nil!.currency.should eq("credits")
        usage.meta_raw.not_nil!.json.should eq(metadata)
        usage.cost_raw.not_nil!.field("amount").not_nil!.json.should eq(amount)
        serialized = ACP::Protocol::RawJson.from_json(usage.to_json)
        serialized.field("_meta").not_nil!.json.should eq(metadata)
        serialized.field("cost").not_nil!.field("amount").not_nil!.json.should eq(amount)
        usage.cost.not_nil!.meta_raw.not_nil!.json.should eq(metadata)
      else
        fail "usage update did not reach the typed callback"
      end

      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":{"sessionUpdate":"usage_update","used":5,"size":20,"cost":{"amount":false,"currency":"credits"},"_meta":#{metadata}}}})
      select
      when usage = updates.receive
        usage.used.should eq(5_u64)
        usage.size.should eq(20_u64)
        usage.cost.should be_nil
        usage.meta_raw.not_nil!.json.should eq(metadata)
      when timeout(2.seconds)
        fail "usage counts did not reach the callback after a malformed cost"
      end
    ensure
      client.try(&.close)
    end
  end

  it "keeps the original decimal cost when editing its metadata" do
    amount = "0.123456789012345678901"
    usage = ACP::Protocol::UsageUpdate.from_json(%({"sessionUpdate":"usage_update","used":10,"size":100,"cost":{"amount":#{amount},"currency":"USD","_meta":{"edit":false}}}))
    usage.cost.not_nil!.meta.not_nil!["edit"] = JSON::Any.new(true)
    raw = ACP::Protocol::RawJson.from_json(usage.to_json).field("cost").not_nil!
    raw.field("amount").not_nil!.json.should eq(amount)
    raw.field("_meta").not_nil!.field("edit").not_nil!.json.should eq("true")
    usage.cost_raw.should eq(raw)

    usage.cost = ACP::Protocol::Cost.new(0.5, "USD")
    ACP::Protocol::RawJson.from_json(usage.to_json).field("cost").not_nil!.field("amount").not_nil!.json.should eq("0.5")
    decoded = ACP::Protocol::UsageUpdate.from_json(usage.to_json)
    decoded.should eq(usage)
    decoded.hash.should eq(usage.hash)
    usage.cost = nil
    ACP::Protocol::RawJson.from_json(usage.to_json).field("cost").should be_nil
  end

  it "compares wide counts, typed cost, and metadata independently" do
    fields = %("sessionUpdate":"usage_update","used":1,"size":18446744073709551615)
    left = ACP::Protocol::UsageUpdate.from_json(%({#{fields},"cost":{"amount":1,"currency":"USD"},"_meta":{"a":1,"b":2}}))
    right = ACP::Protocol::UsageUpdate.from_json(%({#{fields},"cost":{"amount":1.0,"currency":"USD"},"_meta":{"b":2,"a":1}}))
    left.should eq(right)
    left.hash.should eq(right.hash)
  end
end

describe "ACP v1 slash command advertisements" do
  it "keeps usable commands when other entries or optional inputs are malformed" do
    entries = %([false,{"name":false,"description":"Invalid"},{"name":"incomplete"},{"name":"help","description":"Help","input":{"hint":false}},{"name":"plan","description":"Plan","input":{"hint":"Topic","_meta":false},"_meta":true}])
    payload = %({"sessionUpdate":"available_commands_update","availableCommands":#{entries},"_meta":false})
    params = ACP::Protocol::SessionUpdateParams.from_json(%({"sessionId":"root","update":#{payload},"_meta":false}))
    params.meta.should be_nil
    update = params.update.as(ACP::Protocol::AvailableCommandsUpdate)
    update.available_commands.map(&.name).should eq(["help", "plan"])
    update.available_commands.first.input.should be_nil
    update.available_commands.last.input.not_nil!.hint.should eq("Topic")
    update.available_commands.last.input.not_nil!.meta.should be_nil
    update.available_commands.last.meta.should be_nil
    update.meta.should be_nil

    {"null", "false", "{}", "[]"}.each do |list|
      empty = ACP::Protocol::SessionUpdate.from_json(%({"sessionUpdate":"available_commands_update","availableCommands":#{list}})).as(ACP::Protocol::AvailableCommandsUpdate)
      empty.available_commands.should be_empty
    end
  end

  {"wide integer" => "18446744073709551615", "precise decimal" => "1.23000000000000000001"}.each do |label, number|
    it "delivers a #{label} in command metadata through a typed stdio callback" do
      with_wide_stdio do |transport, feed, outgoing|
        client = ACP::Client.new(transport)
        client.request_timeout = 2.0
        answer_identity_request(feed, outgoing, %({"protocolVersion":1}))
        client.initialize_connection
        answer_identity_request(feed, outgoing, %({"sessionId":"root"}))
        client.session_new("/work")

        updates = Channel(ACP::Protocol::SessionUpdateParams).new(1)
        client.on_update = ->(params : ACP::Protocol::SessionUpdateParams) do
          updates.send(params) if params.update.is_a?(ACP::Protocol::AvailableCommandsUpdate)
          nil
        end
        metadata = %({"example.test/samples":[{"number":#{number}}]})
        command = %({"name":"plan","description":"Plan","input":{"hint":"Topic","_meta":#{metadata}},"_meta":#{metadata}})
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":{"sessionUpdate":"available_commands_update","availableCommands":[#{command}],"_meta":#{metadata}},"_meta":#{metadata}}})
        answer_identity_request(feed, outgoing, "{}")
        client.ext_method("barrier")
        select
        when params = updates.receive
          params.session_id.should eq("root")
          update = params.update.as(ACP::Protocol::AvailableCommandsUpdate)
          option = update.available_commands.first
          option.name.should eq("plan")
          option.input.not_nil!.hint.should eq("Topic")
          {params, update, option, option.input.not_nil!}.each do |payload|
            payload.meta_raw.not_nil!.json.should eq(metadata)
          end
          decoded = ACP::Protocol::SessionUpdateParams.from_json(params.to_json)
          decoded.should eq(params)
          decoded.hash.should eq(params.hash)
          decoded.before_load_response = true
          decoded.should_not eq(params)
        else
          fail "available commands update did not reach the typed callback"
        end
      ensure
        client.try(&.close)
      end
    end
  end
end

describe "ACP v1 exact session modes" do
  {"wide integer" => "18446744073709551615", "precise decimal" => "1.23000000000000000001"}.each do |label, number|
    it "preserves a #{label} in mode snapshots and live updates" do
      with_wide_stdio do |transport, feed, outgoing|
        client = ACP::Client.new(transport)
        client.request_timeout = 2.0
        answer_identity_request(feed, outgoing, %({"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"options":{},"resume":{}}}}))
        client.initialize_connection

        metadata = %({"example.test/samples":[{"number":#{number}}]})
        list = %([{"id":"ask","name":"Ask","_meta":#{metadata}},{"id":false,"name":"Invalid"},{"id":"code","name":"Code"}])
        modes = %({"currentModeId":"ask","availableModes":#{list},"_meta":#{metadata}})
        answer_identity_request(feed, outgoing, %({"modes":#{modes}}))
        preview = client.session_options("/work").modes.not_nil!
        preview.available_modes.map(&.id).should eq(["ask", "code"])
        preview.meta_raw.not_nil!.json.should eq(metadata)
        preview.available_modes.first.meta_raw.not_nil!.json.should eq(metadata)
        check_snapshot = ->(snapshot : ACP::Protocol::SessionModeState?) do
          current = snapshot.not_nil!
          current.should eq(preview)
          current.hash.should eq(preview.hash)
          current.meta_raw.not_nil!.json.should eq(metadata)
          current.available_modes.first.meta_raw.not_nil!.json.should eq(metadata)
          nil
        end

        answer_identity_request(feed, outgoing, %({"sessionId":"root","modes":#{modes}}))
        check_snapshot.call(client.session_new("/work").modes)
        answer_identity_request(feed, outgoing, %({"modes":#{modes}}))
        check_snapshot.call(client.session_load("root", "/work").modes)
        answer_identity_request(feed, outgoing, %({"modes":#{modes}}))
        check_snapshot.call(client.session_resume("root", "/work").modes)
        check_snapshot.call(client.session_modes)

        acknowledgement = %({"_meta":#{metadata}})
        ACP::Protocol::SessionSetModeResult.from_json(acknowledgement).meta_raw.not_nil!.json.should eq(metadata)
        answer_identity_request(feed, outgoing, acknowledgement)
        client.session_set_mode("code")
        client.session_modes.not_nil!.current_mode_id.should eq("code")

        updates = Channel(ACP::Protocol::CurrentModeUpdate).new(1)
        client.on_update = ->(params : ACP::Protocol::SessionUpdateParams) do
          if update = params.update.as?(ACP::Protocol::CurrentModeUpdate)
            updates.send(update)
          end
          nil
        end
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":{"sessionUpdate":"current_mode_update","currentModeId":"ask","_meta":#{metadata}}}})
        select
        when update = updates.receive
          update.current_mode_id.should eq("ask")
          update.meta_raw.not_nil!.json.should eq(metadata)
        when timeout(2.seconds)
          fail "current mode update did not arrive"
        end
        check_snapshot.call(client.session_modes)
      ensure
        client.try(&.close)
      end
    end
  end

  it "skips invalid mode entries and optional fields without discarding usable modes" do
    entries = %(false,{"id":42,"name":"Invalid"},{"id":"ask","name":"Ask","description":false},{"id":"code","name":"Code","_meta":true})
    result = ACP::Protocol::SessionNewResult.from_json(%({"sessionId":"root","modes":{"currentModeId":"ask","availableModes":[#{entries}]}}))
    modes = result.modes.not_nil!
    modes.current_mode_id.should eq("ask")
    modes.available_modes.map(&.id).should eq(["ask", "code"])
    modes.available_modes.first.description.should be_nil
    modes.available_modes.last.meta.should be_nil

    {"null", "false", "{}"}.each do |list|
      empty = ACP::Protocol::SessionModeState.from_json(%({"currentModeId":"ask","availableModes":#{list}}))
      empty.available_modes.should be_empty
    end
    expect_raises(JSON::ParseException) do
      ACP::Protocol::SessionModeState.from_json(%({"currentModeId":42,"availableModes":[]}))
    end
  end
end

describe "ACP v1 recoverable configuration options" do
  it "keeps usable grouped choices through stdio and allows selecting them" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::Client.new(transport)
      client.request_timeout = 2.0
      answer_identity_request(feed, outgoing, %({"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"options":{}}}}))
      client.initialize_connection

      metadata = %({"example.test/count":18446744073709551615})
      values = %([false,{"value":"missing-name"},{"value":"fast","name":"Fast"},{"value":"large","name":"Large","_meta":#{metadata}}])
      option = %({"id":"model","name":"Model","type":"select","currentValue":"fast","options":[{"group":"local","name":"Local","options":#{values}}]})
      check_option = ->(options : Array(ACP::Protocol::ConfigOption)) do
        choose = options.first
        choose.groups.not_nil!.map(&.group).should eq(["local"])
        choose.all_values.map(&.value).should eq(["fast", "large"])
        choose.all_values.last.meta_raw.not_nil!.json.should eq(metadata)
        choose.options_raw.not_nil!.first["options"].as_a.first.should eq(false)
        nil
      end

      answer_identity_request(feed, outgoing, %({"configOptions":[#{option}]}))
      check_option.call(client.session_options("/work").config_options.not_nil!)
      answer_identity_request(feed, outgoing, %({"sessionId":"root","configOptions":[#{option}]}))
      check_option.call(client.session_new("/work").config_options.not_nil!)
      check_option.call(client.session_config_options.not_nil!)

      expect_raises(ArgumentError, /advertised value ID/) do
        client.session_set_config_option("model", "missing-name")
      end
      changed = option.sub(%("currentValue":"fast"), %("currentValue":"large"))
      answer_identity_request(feed, outgoing, %({"configOptions":[#{changed}]}))
      result = client.session_set_config_option("model", "large")
      check_option.call(result.config_options)
      client.session_config_options.not_nil!.first.current_value.should eq("large")
    ensure
      client.try(&.close)
    end
  end

  it "keeps selectors with malformed optional descriptions and categories" do
    selector = %({"id":"model","name":"Model","description":false,"category":[],"type":"select","currentValue":"fast","options":[{"value":"fast","name":"Fast","description":false}]})
    toggle = %({"id":"enabled","name":"Enabled","description":"Available","category":"_future","type":"boolean","currentValue":false})
    result = ACP::Protocol::SessionOptionsResult.from_json(%({"configOptions":[#{selector},#{toggle}]}))
    options = result.config_options.not_nil!
    options.map(&.id).should eq(["model", "enabled"])
    options[0].description.should be_nil
    options[0].category.should be_nil
    options[0].all_values.first.description.should be_nil
    options[1].description.should eq("Available")
    options[1].category.should eq("_future")
    options[1].boolean_value.should be_false
  end

  it "keeps flat choices when other entries resemble malformed groups" do
    entries = %([{"group":"bad","name":false,"options":[]},{"group":"bad-array","name":"Bad","options":false},{"value":"fast","name":"Fast","group":"extension"}])
    option = ACP::Protocol::ConfigOption.from_json(%({"id":"model","name":"Model","currentValue":"fast","options":#{entries}}))
    option.grouped?.should be_false
    option.all_values.map(&.value).should eq(["fast"])
  end

  it "defaults a malformed group value list to empty when decoding a group directly" do
    group = ACP::Protocol::ConfigOptionGroup.from_json(%({"group":"local","name":"Local","options":false}))
    group.options.should be_empty
  end
end

describe "ACP v1 exact configuration options" do
  {"wide integer" => "18446744073709551615", "precise decimal" => "1.23000000000000000001"}.each do |label, number|
    it "keeps flat and grouped choices with a #{label} in extension metadata" do
      with_wide_stdio do |transport, feed, outgoing|
        client = ACP::Client.new(transport)
        client.request_timeout = 2.0
        answer_identity_request(feed, outgoing, %({"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"options":{}}}}))
        client.initialize_connection

        metadata = %({"example.test/number":#{number}})
        values = %([{"value":"fast","name":"Fast","_meta":#{metadata}},{"value":"large","name":"Large"}])
        flat = %({"id":"model","name":"Model","type":"select","currentValue":"fast","options":#{values},"_meta":#{metadata}})
        group = %({"group":"models","name":"Models","options":#{values},"_meta":#{metadata}})
        grouped = %({"id":"grouped","name":"Grouped","type":"select","currentValue":"fast","options":[#{group}]})
        config = "[#{flat},#{grouped}]"
        check_options = ->(options : Array(ACP::Protocol::ConfigOption)) do
          options.map(&.id).should eq(["model", "grouped"])
          options[0].options.not_nil!.map(&.value).should eq(["fast", "large"])
          options[1].groups.not_nil!.map(&.group).should eq(["models"])
          options[0].meta_raw.not_nil!.json.should eq(metadata)
          options[1].groups.not_nil!.first.meta_raw.not_nil!.json.should eq(metadata)
          options.each { |option| option.all_values.first.meta_raw.not_nil!.json.should eq(metadata) }
          nil
        end

        answer_identity_request(feed, outgoing, %({"configOptions":#{config}}))
        check_options.call(client.session_options("/work").config_options.not_nil!)
        answer_identity_request(feed, outgoing, %({"sessionId":"root","configOptions":#{config}}))
        check_options.call(client.session_new("/work").config_options.not_nil!)
        check_options.call(client.session_config_options.not_nil!)

        updates = Channel(ACP::Protocol::ConfigOptionUpdate).new(1)
        client.on_update = ->(params : ACP::Protocol::SessionUpdateParams) do
          if update = params.update.as?(ACP::Protocol::ConfigOptionUpdate)
            updates.send(update)
          end
          nil
        end
        mixed = %([false,#{flat},#{grouped}])
        feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":{"sessionUpdate":"config_option_update","configOptions":#{mixed},"_meta":#{metadata}}}})
        select
        when update = updates.receive
          check_options.call(update.typed_config_options)
          update.meta_raw.not_nil!.json.should eq(metadata)
          update.config_options_raw.json.should eq(config)
          update.config_options.size.should eq(2)
          update.config_options.first.as_h["name"] = JSON::Any.new("Renamed")
          update.typed_config_options.first.name.should eq("Renamed")
          check_options.call(update.typed_config_options)
        when timeout(2.seconds)
          fail "configuration option update did not arrive"
        end
        check_options.call(client.session_config_options.not_nil!)

        changed = config.sub(%("currentValue":"fast"), %("currentValue":"large"))
        answer_identity_request(feed, outgoing, %({"configOptions":#{changed}}))
        result = client.session_set_config_option("model", "large")
        check_options.call(result.config_options)
        result.config_options.first.current_value.should eq("large")
        check_options.call(client.session_config_options.not_nil!)
        client.session_config_options.not_nil!.first.current_value.should eq("large")
      ensure
        client.try(&.close)
      end
    end
  end

  it "builds a configuration option from a typed value carrying exact metadata" do
    metadata = %({"example.test/count":18446744073709551615})
    value = ACP::Protocol::ConfigOptionValue.from_json(%({"value":"fast","name":"Fast","_meta":#{metadata}}))
    option = ACP::Protocol::ConfigOption.new("model", "Model", current_value: "fast", options: [value])
    option.options_raw.not_nil!.first["name"].should eq("Fast")
    option.options_raw.not_nil!.first.as_h["name"] = JSON::Any.new("Renamed")
    option.to_json.should contain(%("name":"Renamed"))
    option.to_json.should contain(%("_meta":#{metadata}))
  end

  it "keeps equality and hashing for configuration options that fit in JSON::Any" do
    left = ACP::Protocol::ConfigOption.from_json(%({"id":"model","name":"Model","options":[{"value":"fast","name":"Fast"}]}))
    right = ACP::Protocol::ConfigOption.from_json(%({"id":"model","name":"Model","options":[{"name":"Fast","value":"fast"}]}))
    left.should eq(right)
    left.hash.should eq(right.hash)

    options = [JSON.parse(left.to_json)]
    update = ACP::Protocol::ConfigOptionUpdate.new(options)
    decoded = ACP::Protocol::ConfigOptionUpdate.from_json(update.to_json)
    update.should eq(decoded)
    update.hash.should eq(decoded.hash)
  end

  it "compares retained configuration values independently of projection object IDs" do
    choice = %({"id":"model","name":"Model","options":[{"name":"Fast","value":"fast","_meta":{"samples":[{"number":1.25e0}]}}]})
    first = ACP::Protocol::ConfigOption.from_json(choice)
    second = ACP::Protocol::ConfigOption.from_json(choice.sub("1.25e0", "1.25"))
    first.should eq(second)
    first.hash.should eq(second.hash)

    wire = %({"sessionUpdate":"config_option_update","configOptions":[#{choice}]})
    first_update = ACP::Protocol::ConfigOptionUpdate.from_json(wire)
    second_update = ACP::Protocol::ConfigOptionUpdate.from_json(wire)
    first_update.should eq(second_update)
    first_update.hash.should eq(second_update.hash)

    wide = wire.sub("1.25e0", "18446744073709551615")
    ACP::Protocol::ConfigOptionUpdate.from_json(wide).should eq(ACP::Protocol::ConfigOptionUpdate.from_json(wide))
    ACP::Protocol::ConfigOptionUpdate.from_json(wide).should_not eq(ACP::Protocol::ConfigOptionUpdate.from_json(wide.sub("18446744073709551615", "18446744073709551614")))
  end

  it "includes the typed flat and grouped lists in configuration option comparison" do
    flat = ACP::Protocol::ConfigOption.new("model", "Model", options: [] of ACP::Protocol::ConfigOptionValue)
    grouped = ACP::Protocol::ConfigOption.new("model", "Model", groups: [] of ACP::Protocol::ConfigOptionGroup)
    flat.should_not eq(grouped)

    first = ACP::Protocol::ConfigOption.new("model", "Model", options: [ACP::Protocol::ConfigOptionValue.new("fast", "Fast")])
    second = ACP::Protocol::ConfigOption.from_json(first.to_json)
    second.options.not_nil![0] = ACP::Protocol::ConfigOptionValue.new("large", "Large")
    first.should_not eq(second)
  end
end

describe "ACP result identities" do
  it "requires unambiguous strings in the typed result decoders" do
    [ACP::Protocol::SessionNewResult, ACP::Protocol::V2::SessionNewResult].each do |type|
      [%("sessionId":null), %("sessionId":false), %("sessionId":"one","sessionId":"two")].each do |field|
        expect_raises(JSON::ParseException) { type.from_json("{#{field}}") }
      end
      expect_raises(JSON::ParseException) { type.from_json("{}") }
      type.from_json(%({"sessionId":""})).session_id.should eq("")
    end

    type = ACP::Protocol::V2::SessionPromptResult
    [%("messageId":null), %("messageId":false), %("messageId":"one","messageId":"two")].each do |field|
      expect_raises(JSON::ParseException) { type.from_json("{#{field}}") }
    end
    expect_raises(JSON::ParseException) { type.from_json("{}") }
    type.from_json(%({"messageId":""})).message_id.should eq("")
  end

  it "preserves prompt acknowledgement metadata and rejects ambiguous IDs over stdio" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      client.prompt_timeout = 2.0
      initialize_wide_v2(client, feed, outgoing, session_id: "root")

      answer_identity_request(feed, outgoing, %({"messageId":"first","messageId":"second"}))
      expect_raises(ACP::ProtocolError, /Ambiguous.*messageId/) { client.session_prompt_text("root", "One") }

      answer_identity_request(feed, outgoing, %({"messageId":"first"},"result":{"messageId":"second"}))
      expect_raises(ACP::ProtocolError, /Ambiguous.*result/) { client.session_prompt_text("root", "Two") }

      spawn do
        request = JSON.parse(outgoing.gets.not_nil!)
        id = request["id"].as_i64
        feed.puts %({"jsonrpc":"2.0","id":#{id + 1000},"id":#{id},"result":{"messageId":"uncorrelated"}})
        feed.puts %({"jsonrpc":"2.0","id":#{id + 1000},"id":#{id},"error":{"code":-32603,"message":"Uncorrelated error"}})
        feed.puts %({"jsonrpc":"2.0","id":#{id},"result":{"messageId":"correlated"}})
      end
      client.session_prompt_text("root", "Three").message_id.should eq("correlated")

      meta = %({"count":18446744073709551615,"precise":0.1234567890123456789,"label":"visible"})
      answer_identity_request(feed, outgoing, %({"messageId":"inserted","_meta":#{meta}}))
      ack = client.session_prompt_text("root", "Four")
      ack.message_id.should eq("inserted")
      ack.meta.not_nil!["label"].should eq("visible")
      ack.meta_raw.not_nil!.json.should eq(meta)
      ack.to_json.should contain(%("_meta":#{meta}))
      client.session_state("root").not_nil!.idle?.should be_true

      decimal_meta = %({"precise":0.1234567890123456789})
      answer_identity_request(feed, outgoing, %({"messageId":"precise","_meta":#{decimal_meta}}))
      client.session_prompt_text("root", "Five").meta_raw.not_nil!.json.should eq(decimal_meta)

      answer_identity_request(feed, outgoing, %({"messageId":"valid","_meta":null,"_meta":{"conflicting":true}}))
      client.session_prompt_text("root", "Six").meta.should be_nil

      spawn do
        request = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{request["id"]},"error":{"code":-32603,"message":"One"},"error":{"code":-32602,"message":"Two"}})
      end
      expect_raises(ACP::ProtocolError, /Ambiguous.*error/) { client.session_prompt_text("root", "Seven") }

      spawn do
        request = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"jsonrpc":"2.0","id":#{request["id"]},"error":{"code":-32602,"message":"Valid error"}})
      end
      expect_raises(ACP::JsonRpcError, /Valid error/) { client.session_prompt_text("root", "Eight") }
    ensure
      client.try(&.close)
    end
  end

  it "rejects ambiguous new and fork results before attaching either session ID" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      answer_identity_request(feed, outgoing, %({"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"fork":{}}}}))
      client.initialize_connection

      answer_identity_request(feed, outgoing, %({"sessionId":"root"}))
      client.session_new("/work").session_id.should eq("root")

      {"session/new", "session/fork"}.each_with_index do |method, index|
        candidate = "candidate-#{index}"
        create = -> do
          if method == "session/new"
            client.session_new("/other")
          else
            client.session_fork("root", "/other")
          end
        end

        answer_identity_request(feed, outgoing, %({"sessionId":"first","sessionId":#{candidate.to_json}}))
        expect_raises(ACP::ProtocolError, /Ambiguous.*sessionId/) { create.call }

        answer_identity_request(feed, outgoing, %({"sessionId":"first"},"result":{"sessionId":#{candidate.to_json}}))
        expect_raises(ACP::ProtocolError, /Ambiguous.*result/) { create.call }
        ["first", candidate].each do |id|
          client.session_state(id).should be_nil
          client.session_workspace(id).should be_nil
          client.session_available_commands_raw(id).should be_nil
          client.session_config_options_raw(id).should be_nil
        end

        answer_identity_request(feed, outgoing, %({"sessionId":#{candidate.to_json},"sessionId":"root"}))
        expect_raises(ACP::ProtocolError, /Ambiguous.*sessionId/) { create.call }
        client.session_state("root").not_nil!.idle?.should be_true
        client.session_workspace("root").not_nil!.cwd.should eq("/work")

        meta = %({"precise":0.1234567890123456789})
        answer_identity_request(feed, outgoing, %({"sessionId":#{candidate.to_json},"_meta":#{meta}}))
        created = create.call
        created.session_id.should eq(candidate)
        created.to_json.should contain(%("_meta":#{meta}))
        client.session_state(candidate).not_nil!.idle?.should be_true
        client.session_workspace(candidate).not_nil!.cwd.should eq("/other")
      end
    ensure
      client.try(&.close)
    end
  end

  it "keeps the v1 session unchanged after ambiguous creation and fork results" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::Client.new(transport)
      client.request_timeout = 2.0
      answer_identity_request(feed, outgoing, %({"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"fork":{}}}}))
      client.initialize_connection

      answer_identity_request(feed, outgoing, %({"sessionId":"root"}))
      client.session_new("/work").session_id.should eq("root")
      answer_identity_request(feed, outgoing, %({"sessionId":"first","sessionId":"second"}))
      expect_raises(ACP::ProtocolError, /Ambiguous.*sessionId/) { client.session_new("/other") }
      client.session_id.should eq("root")

      answer_identity_request(feed, outgoing, %({"sessionId":"root"}))
      expect_raises(ACP::ProtocolError, /existing session ID/) { client.session_new("/reused") }
      client.session_id.should eq("root")

      meta = %({"precise":0.1234567890123456789})
      answer_identity_request(feed, outgoing, %({"sessionId":"second","_meta":#{meta}}))
      created = client.session_new("/other")
      created.session_id.should eq("second")
      client.session_id.should eq("second")
      created.meta_raw.not_nil!.json.should eq(meta)
      created.to_json.should contain(%("_meta":#{meta}))

      answer_identity_request(feed, outgoing, %({"sessionId":"new","sessionId":"second"}))
      expect_raises(ACP::ProtocolError, /Ambiguous.*sessionId/) { client.session_fork("second", "/fork") }
      client.session_id.should eq("second")

      answer_identity_request(feed, outgoing, %({"sessionId":"new","_meta":#{meta}}))
      forked = client.session_fork("second", "/fork")
      forked.session_id.should eq("new")
      forked.meta_raw.not_nil!.json.should eq(meta)
      client.session_id.should eq("new")
    ensure
      client.try(&.close)
    end
  end
end

private def answer_rpc_outcome(feed : IO, outgoing : IO, fields : String) : Nil
  spawn do
    request = JSON.parse(outgoing.gets.not_nil!)
    feed.puts %({"jsonrpc":"2.0","id":#{request["id"]}#{fields}})
  end
end

describe "ACP JSON-RPC response outcomes" do
  {1, 2}.each do |version|
    it "requires one outcome on v#{version} requests and preserves a null success" do
      with_wide_stdio do |transport, feed, outgoing|
        client = version == 1 ? ACP::Client.new(transport) : ACP::V2::Client.new(transport)
        client.request_timeout = 2.0
        if client.is_a?(ACP::V2::Client)
          initialize_wide_v2(client, feed, outgoing)
        else
          answer_identity_request(feed, outgoing, %({"protocolVersion":1}))
          client.initialize_connection
        end

        answer_rpc_outcome(feed, outgoing, %(,"result":null,"error":{"code":-32602,"message":"Invalid"}))
        expect_raises(ACP::ProtocolError, /exactly one.*result.*error/) { client.ext_method("fixture/outcome") }
        answer_rpc_outcome(feed, outgoing, "")
        expect_raises(ACP::ProtocolError, /exactly one.*result.*error/) { client.ext_method("fixture/outcome") }
        answer_rpc_outcome(feed, outgoing, %(,"result":null))
        client.ext_method("fixture/outcome").raw.should be_nil
      ensure
        client.try(&.close)
      end
    end

    it "keeps the v#{version} agent error type when data has wide JSON numbers" do
      with_wide_stdio do |transport, feed, outgoing|
        client = version == 1 ? ACP::Client.new(transport) : ACP::V2::Client.new(transport)
        client.request_timeout = 2.0
        if client.is_a?(ACP::V2::Client)
          initialize_wide_v2(client, feed, outgoing)
        else
          answer_identity_request(feed, outgoing, %({"protocolVersion":1}))
          client.initialize_connection
        end

        data = %({"count":18446744073709551615,"precise":0.1234567890123456789,"label":"visible"})
        answer_rpc_outcome(feed, outgoing, %(,"error":{"code":-32602,"message":"Invalid","data":#{data}}))
        error = expect_raises(ACP::JsonRpcError, "Invalid") { client.ext_method("fixture/wide") }
        error.invalid_params?.should be_true
        error.received?.should be_true
        error.data.not_nil!["label"].should eq("visible")
        error.data_raw.not_nil!.json.should eq(data)

        decimal = "0.9876543210987654321"
        answer_rpc_outcome(feed, outgoing, %(,"error":{"code":-32602,"message":"Custom","data":#{decimal}}))
        exact = expect_raises(ACP::JsonRpcError, "Custom") { client.ext_method("fixture/decimal") }
        exact.data_raw.not_nil!.json.should eq(decimal)
      ensure
        client.try(&.close)
      end
    end
  end

  it "keeps exact error data during v2 initialization and accepts a later offer" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      data = %({"providers":["fixture"],"large":18446744073709551615})
      answer_rpc_outcome(feed, outgoing, %(,"error":{"code":-32000,"message":"Login required","data":#{data}}))
      failure = expect_raises(ACP::JsonRpcError, "Login required") { client.initialize_connection }
      failure.auth_required?.should be_true
      failure.received?.should be_true
      failure.data.not_nil!["providers"].as_a.first.should eq("fixture")
      failure.data_raw.not_nil!.json.should eq(data)
      initialize_wide_v2(client, feed, outgoing)
      client.negotiated_protocol_version.should eq(2)
    ensure
      client.try(&.close)
    end
  end

  it "keeps retirement-dependent choices unavailable after a late out-of-range error" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/new"] = %("result":{"sessionId":"s","availableCommands":[{"type":"command","name":"old","description":"Old"}]})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")
    client.session_available_commands("s").not_nil!.map(&.name).should eq(["old"])
    next_answer(transport)
    next_answer(transport)

    client.request_timeout = 0.01
    expect_raises(ACP::RequestTimeoutError) { client.session_close("s") }
    request = next_answer(transport)
    request["method"].should eq("session/close")

    client.request_timeout = 2.0
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{request["id"]},"error":{"code":2147483648,"message":"Out of range"}}))
    choice_state_barrier(client, transport)
    client.session_available_commands("s").should be_nil
    client.session_workspace("s").not_nil!.cwd.should eq("/work")
  ensure
    client.try(&.close)
  end

  it "keeps a fork cursor available after an ambiguous or incomplete error reply" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.request_timeout = 2.0
      updates = Channel(Nil).new(1)
      client.on_update = ->(_note : ACP::Protocol::V2::SessionUpdateParams) do
        updates.send(nil)
        nil
      end
      answer_identity_request(feed, outgoing, %({"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"fork":{}}}}))
      client.initialize_connection
      answer_identity_request(feed, outgoing, %({"sessionId":"source"}))
      client.session_new("/work")
      feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"source","update":{"sessionUpdate":"cursor_update","cursorId":"c","capabilities":{"fork":{}}}}})
      next_permission_event(updates)

      [
        %(,"result":{"sessionId":"impossible"},"error":{"code":-32602,"message":"Expired"}),
        %(,"error":{"code":-32603,"code":-32602,"message":"Ambiguous"}),
      ].each do |fields|
        answer_rpc_outcome(feed, outgoing, fields)
        expect_raises(ACP::ProtocolError) { client.session_fork("source", "/fork", cursor_id: "c") }
        client.session_cursor("source", "c").not_nil!.fork?.should be_true
        client.session_workspace("impossible").should be_nil
      end

      answer_rpc_outcome(feed, outgoing, %(,"error":{"code":-32602}))
      expect_raises(ACP::JsonRpcError) { client.session_fork("source", "/fork", cursor_id: "c") }
      client.session_cursor("source", "c").not_nil!.fork?.should be_true

      answer_rpc_outcome(feed, outgoing, %(,"error":{"code":-32602,"message":"Expired"}))
      expect_raises(ACP::JsonRpcError, "Expired") { client.session_fork("source", "/fork", cursor_id: "c") }
      client.session_cursor("source", "c").not_nil!.fork?.should be_false
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP JSON-RPC response ID types" do
  {1, 2}.each do |version|
    it "correlates v#{version} stdio replies by the same numeric ID" do
      with_wide_stdio do |transport, feed, outgoing|
        client = version == 1 ? ACP::Client.new(transport) : ACP::V2::Client.new(transport)
        client.request_timeout = 2.0
        if client.is_a?(ACP::V2::Client)
          initialize_wide_v2(client, feed, outgoing)
        else
          answer_identity_request(feed, outgoing, %({"protocolVersion":1}))
          client.initialize_connection
        end

        spawn do
          request = JSON.parse(outgoing.gets.not_nil!)
          id = request["id"].as_i64
          feed.puts %({"jsonrpc":"2.0","id":"#{id}","error":{"code":-32602,"message":"Wrong ID type"}})
          feed.puts %({"jsonrpc":"2.0","id":"#{id}","result":"string ID"})
          feed.puts %({"jsonrpc":"2.0","id":#{id}.5,"result":"fractional ID"})
          feed.puts %({"jsonrpc":"2.0","id":#{id}.00000000000000001,"result":"rounded ID"})
          feed.puts %({"jsonrpc":"2.0","id":#{id}e0,"result":"exponent ID"})
          feed.puts %({"jsonrpc":"2.0","id":#{id},"result":"integer ID"})
        end
        client.ext_method("fixture/response").should eq("integer ID")
      ensure
        client.try(&.close)
      end
    end
  end

  it "keeps a timed-out close pending for the matching numeric ID" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{}}})
    transport.replies["session/new"] = %("result":{"sessionId":"root","availableCommands":[{"type":"command","name":"status","description":"Status"}]})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")
    next_answer(transport)
    next_answer(transport)
    client.request_timeout = 0.01
    expect_raises(ACP::RequestTimeoutError) { client.session_close("root") }
    close = next_answer(transport)
    close["method"].should eq("session/close")

    client.request_timeout = 2.0
    transport.inject_raw(%({"jsonrpc":"2.0","id":"#{close["id"]}","result":{}}))
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{close["id"]}.0,"result":{}}))
    choice_state_barrier(client, transport)
    client.session_workspace("root").not_nil!.cwd.should eq("/work")
    client.session_available_commands("root").should be_nil

    transport.inject_raw(%({"jsonrpc":"2.0","id":#{close["id"]},"result":{}}))
    choice_state_barrier(client, transport)
    client.session_workspace("root").should be_nil
    client.session_state("root").should be_nil
  ensure
    client.try(&.close)
  end

  it "keeps a timed-out resume provisional until the matching numeric ID" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{}}})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    next_answer(transport)

    client.request_timeout = 0.01
    params = ACP::Protocol::V2::SessionResumeParams.new("saved", "/work")
    expect_raises(ACP::RequestTimeoutError) { client.session_resume(params) }
    resume = next_answer(transport)
    resume["method"].should eq("session/resume")
    transport.update("saved", %({"sessionUpdate":"state_update","state":"running"}))
    commands = %([{"type":"command","name":"status","description":"Status"}])

    client.request_timeout = 2.0
    transport.inject_raw(%({"jsonrpc":"2.0","id":"#{resume["id"]}","result":{"availableCommands":#{commands}}}))
    choice_state_barrier(client, transport)
    client.session_workspace("saved").should be_nil
    client.session_available_commands("saved").should be_nil

    transport.inject_raw(%({"jsonrpc":"2.0","id":#{resume["id"]},"result":{"availableCommands":#{commands}}}))
    choice_state_barrier(client, transport)
    client.session_workspace("saved").not_nil!.cwd.should eq("/work")
    client.session_available_commands("saved").not_nil!.map(&.name).should eq(["status"])
    client.session_state("saved").not_nil!.state.should eq("running")
  ensure
    client.try(&.close)
  end
end

private class PausedReplyTransport < ChoiceStateTransport
  getter finishing = Channel(Nil).new(1)
  getter release = Channel(Nil).new(1)

  def initialize(@paused_id : String = "finishing")
    super()
  end

  def send(message : Hash(String, JSON::Any)) : Nil
    if message["id"]?.try(&.as_s?) == @paused_id
      @finishing.send(nil)
      @release.receive?
    end
    super
  end
end

private class PausedStdioError < ACP::StdioTransport
  property paused_code = ACP::JsonRpcError::INVALID_REQUEST
  getter replying = Channel(Nil).new(1)
  getter release = Channel(Nil).new(1)

  def send(message : Hash(String, JSON::Any)) : Nil
    if message["error"]?.try(&.["code"]?) == JSON::Any.new(@paused_code.to_i64)
      @replying.send(nil)
      @release.receive?
    end
    super
  end
end

describe "ACP cancellation request identities" do
  it "requires one cancellation ID while tolerating optional metadata" do
    type = ACP::Protocol::CancelRequestParams
    expect_raises(JSON::ParseException) { type.from_json(%({})) }
    expect_raises(JSON::ParseException) { type.from_json(%({"requestId":"one","requestId":"two"})) }
    expect_raises(JSON::ParseException) { type.from_json(%({"requestId":17.0})) }
    type.from_json(%({"requestId":null})).request_id.should be_nil
    typed = type.from_json(%({"requestId":"17","_meta":false}))
    typed.request_id.should eq("17")
    typed.meta.should be_nil
    precise = %({"wide":18446744073709551615,"fraction":0.1234567890123456789})
    type.from_json(%({"requestId":17,"_meta":#{precise}})).meta_raw.not_nil!.json.should eq(precise)
  end

  it "cancels a v1 request despite malformed optional metadata over stdio" do
    with_wide_stdio do |transport, feed, outgoing|
      client = initialized_v1_terminal_client(transport, feed, outgoing)
      client.on_create_terminal = ->(_params : ACP::Protocol::CreateTerminalParams) do
        ACP::Protocol::CreateTerminalResult.new("terminal")
      end
      feed.puts %({"jsonrpc":"2.0","id":16,"method":"terminal/create","params":{"sessionId":"root","command":"fixture"}})
      JSON.parse(outgoing.gets.not_nil!)["result"]["terminalId"].should eq("terminal")
      started = Channel(Nil).new(1)
      release = Channel(Nil).new(1)
      client.on_wait_for_terminal_exit = ->(_params : ACP::Protocol::WaitForTerminalExitParams) do
        started.send(nil)
        release.receive
        ACP::Protocol::WaitForTerminalExitResult.new(exit_code: 0)
      end
      feed.puts %({"jsonrpc":"2.0","id":17,"method":"terminal/wait_for_exit","params":{"sessionId":"root","terminalId":"terminal"}})
      next_permission_event(started)
      feed.puts %({"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":17,"_meta":false}})
      reply = JSON.parse(outgoing.gets.not_nil!)
      reply["id"].should eq(17)
      reply["error"]["code"].should eq(ACP::JsonRpcError::REQUEST_CANCELLED)
      release.send(nil)
    ensure
      release.try(&.close)
      client.try(&.close)
    end
  end

  it "cancels only the matching live v2 request with an exact stdio ID" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      started = Channel(Nil).new(2)
      release = Channel(Nil).new(2)
      barriers = Channel(Nil).new(1)
      seen = [] of JSON::Any
      client.on_request_permission = ->(_params : ACP::Protocol::V2::RequestPermissionParams) do
        started.send(nil)
        release.receive
        ACP::Protocol::V2::RequestPermissionResult.selected("allow")
      end
      client.on_notification = ->(method : String, params : JSON::Any?) do
        if method == "$/cancel_request"
          seen << params.not_nil!
        elsif method == "_barrier"
          barriers.send(nil)
        end
        nil
      end
      initialize_wide_v2(client, feed, outgoing, session_id: "root")
      permissions = %({"sessionId":"root","title":"Read","options":[{"optionId":"allow","name":"Allow","kind":"allow_once"}]})
      {"17", %("17")}.each do |id|
        feed.puts %({"jsonrpc":"2.0","id":#{id},"method":"session/request_permission","params":#{permissions}})
        next_permission_event(started)
      end

      [
        %("params":{"requestId":17,"requestId":"17"}),
        %("params":{"requestId":17},"params":{"requestId":"17"}),
        %("params":{"requestId":17.0000000000000001}),
        %("params":{"requestId":"unknown"}),
        %("params":{"requestId":"17"},"result":null),
        %("params":{"requestId":"17"},"error":{"code":-32603,"message":"Mixed"}),
      ].each do |fields|
        feed.puts %({"jsonrpc":"2.0","method":"$/cancel_request",#{fields}})
      end
      feed.puts %({"jsonrpc":"2.0","method":"_barrier"})
      next_permission_event(barriers)
      seen.should be_empty

      feed.puts %({"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":"17","_meta":{"wide":18446744073709551615,"label":"visible"}}})
      cancelled = JSON.parse(outgoing.gets.not_nil!)
      cancelled["id"].as_s.should eq("17")
      cancelled["result"]["outcome"]["outcome"].should eq("cancelled")

      feed.puts %({"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":"17"}})
      feed.puts %({"jsonrpc":"2.0","method":"_barrier"})
      next_permission_event(barriers)
      seen.size.should eq(1)
      seen.first["requestId"].as_s.should eq("17")
      seen.first["_meta"]["label"].should eq("visible")
      seen.first["_meta"]["wide"]?.should be_nil

      2.times { release.send(nil) }
      kept = JSON.parse(outgoing.gets.not_nil!)
      kept["id"].as_i64.should eq(17)
      kept["result"]["outcome"]["optionId"].should eq("allow")
    ensure
      release.try(&.close)
      client.try(&.close)
    end
  end

  it "rejects noninteger or ambiguous Agent IDs before they can become cancellation targets" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      calls = 0
      client.on_request_permission = ->(_params : ACP::Protocol::V2::RequestPermissionParams) do
        calls += 1
        ACP::Protocol::V2::RequestPermissionResult.selected("allow")
      end
      server = client.register_mcp_server("fixture") do |_context|
        calls += 1
        ACP::Protocol::MessageMcpResponse.success(JSON::Any.new(nil))
      end
      answer_identity_request(feed, outgoing, %({"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"mcp":{"acp":{}}}}}))
      client.initialize_connection
      answer_identity_request(feed, outgoing, %({"sessionId":"root"}))
      client.session_new(ACP::Protocol::V2::SessionNewParams.new("/work", mcp_servers: [ACP::Protocol::V2::McpServer.acp(server)]))
      requests = {
        %("method":"session/request_permission","params":{"sessionId":"root","title":"Read","options":[{"optionId":"allow","name":"Allow","kind":"allow_once"}]}),
        %("method":"mcp/message","params":{"serverId":#{server.server_id.to_json},"requestId":"m","method":"tools/call","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":#{ACP::MCP_PROTOCOL_VERSION.to_json},"io.modelcontextprotocol/clientCapabilities":{}}}}),
      }
      requests.each do |request|
        { %("id":17.0000000000000001), %("id":17,"id":"17") }.each do |id_fields|
          feed.puts %({"jsonrpc":"2.0",#{id_fields},#{request}})
          reply = JSON.parse(outgoing.gets.not_nil!)
          reply["id"].raw.should be_nil
          reply["error"]["code"].should eq(ACP::JsonRpcError::INVALID_REQUEST)
        end
      end
      calls.should eq(0)
    ensure
      client.try(&.close)
    end
  end

  it "keeps dispatch running while an ambiguous MCP request error waits for output" do
    reader, feed = IO.pipe
    outgoing, writer = IO.pipe
    outgoing.read_timeout = 2.seconds
    transport = PausedStdioError.new(reader, writer)
    client = ACP::V2::Client.new(transport)
    checkpoint = Channel(Nil).new(1)
    client.on_notification = ->(method : String, _params : JSON::Any?) do
      checkpoint.send(nil) if method == "_checkpoint"
      nil
    end
    initialize_wide_v2(client, feed, outgoing)
    feed.puts %({"jsonrpc":"2.0","id":17,"id":18,"method":"mcp/message","params":{}})
    next_permission_event(transport.replying)

    feed.puts %({"jsonrpc":"2.0","method":"_checkpoint"})
    next_permission_event(checkpoint)

    transport.release.send(nil)
    error = JSON.parse(outgoing.gets.not_nil!)
    error["id"].raw.should be_nil
    error["error"]["code"].should eq(ACP::JsonRpcError::INVALID_REQUEST)
  ensure
    transport.try { |fixture| fixture.release.close }
    client.try(&.close)
    feed.try(&.close)
    outgoing.try(&.close)
  end

  it "ignores a cancellation after the native MCP terminal reply is selected" do
    transport = PausedReplyTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"fixture","version":"1"},"capabilities":{"session":{"mcp":{"acp":{}}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"root"})
    client = ACP::V2::Client.new(transport)
    client.request_timeout = 2.0
    contexts = Channel(ACP::McpRequestContext).new(1)
    cancellations = 0
    client.on_notification = ->(method : String, _params : JSON::Any?) do
      cancellations += 1 if method == "$/cancel_request"
      nil
    end
    server = client.register_mcp_server("fixture") do |context|
      contexts.send(context)
      ACP::Protocol::MessageMcpResponse.success(JSON::Any.new("selected"))
    end
    client.initialize_connection
    next_answer(transport)["method"].should eq("initialize")
    client.session_new(ACP::Protocol::V2::SessionNewParams.new("/work", mcp_servers: [ACP::Protocol::V2::McpServer.acp(server)]))
    next_answer(transport)["method"].should eq("session/new")
    transport.inject_raw(%({"jsonrpc":"2.0","id":"finishing","method":"mcp/message","params":{"serverId":#{server.server_id.to_json},"requestId":"m","method":"tools/call","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":#{ACP::MCP_PROTOCOL_VERSION.to_json},"io.modelcontextprotocol/clientCapabilities":{}}}}}))
    context = next_permission_event(contexts)
    next_permission_event(transport.finishing)
    transport.inject_raw(%({"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":"finishing"}}))
    choice_state_barrier(client, transport)
    next_answer(transport)["method"].should eq("_barrier")
    cancellations.should eq(0)
    context.cancelled?.should be_false

    transport.release.send(nil)
    reply = next_answer(transport)
    reply["id"].should eq("finishing")
    reply["result"]["result"].should eq("selected")
  ensure
    transport.try { |fixture| fixture.release.close }
    client.try(&.close)
  end

  it "ignores ambiguous plain and wrapped cancellations before translating their IDs" do
    with_wide_stdio(exact_frames: true) do |client, client_send, client_read|
      with_wide_stdio(exact_frames: true) do |proxy, proxy_send, proxy_read|
        with_wide_stdio(exact_frames: true) do |agent, agent_send, agent_read|
          relay = ACP::Conductor.new(client, agent, proxies: [proxy])
          spawn relay.run
          client_send.puts %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2}})
          proxy_init = JSON.parse(proxy_read.gets.not_nil!)
          proxy_send.puts %({"jsonrpc":"2.0","id":"init","method":"proxy/successor","params":{"method":"initialize","params":{"protocolVersion":2}}})
          agent_init = JSON.parse(agent_read.gets.not_nil!)
          agent_send.puts %({"jsonrpc":"2.0","id":#{agent_init["id"]},"result":{"protocolVersion":2}})
          JSON.parse(proxy_read.gets.not_nil!)["id"].should eq("init")
          proxy_send.puts %({"jsonrpc":"2.0","id":#{proxy_init["id"]},"result":{"protocolVersion":2}})
          JSON.parse(client_read.gets.not_nil!)["id"].should eq(1)

          client_send.puts %({"jsonrpc":"2.0","id":4,"id":17,"method":"_inbound"})
          ambiguous = JSON.parse(client_read.gets.not_nil!)
          ambiguous["id"].raw.should be_nil
          ambiguous["error"]["code"].should eq(ACP::JsonRpcError::INVALID_REQUEST)

          client_send.puts %({"jsonrpc":"2.0","id":17,"method":"_inbound"})
          inbound = JSON.parse(proxy_read.gets.not_nil!)
          client_send.puts %({"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":4,"requestId":17}})
          client_send.puts %({"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":4},"params":{"requestId":17}})
          client_send.puts %({"jsonrpc":"2.0","method":"_checkpoint"})
          JSON.parse(proxy_read.gets.not_nil!)["method"].should eq("_checkpoint")
          client_send.puts %({"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":17}})
          JSON.parse(proxy_read.gets.not_nil!)["params"]["requestId"].should eq(inbound["id"])

          proxy_send.puts %({"jsonrpc":"2.0","id":"17","method":"proxy/successor","params":{"method":"_outbound"}})
          outbound = JSON.parse(agent_read.gets.not_nil!)
          proxy_send.puts %({"jsonrpc":"2.0","method":"proxy/successor","params":{"method":"$/cancel_request","params":{"requestId":"wrong","requestId":"17"}}})
          proxy_send.puts %({"jsonrpc":"2.0","method":"proxy/successor","params":{"method":"$/cancel_request","params":{"requestId":"wrong"},"params":{"requestId":"17"}}})
          proxy_send.puts %({"jsonrpc":"2.0","method":"proxy/successor","params":{"method":"_checkpoint"}})
          JSON.parse(agent_read.gets.not_nil!)["method"].should eq("_checkpoint")
          proxy_send.puts %({"jsonrpc":"2.0","method":"proxy/successor","params":{"method":"$/cancel_request","params":{"requestId":"17"}}})
          JSON.parse(agent_read.gets.not_nil!)["params"]["requestId"].should eq(outbound["id"])
          agent_send.puts %({"jsonrpc":"2.0","id":#{outbound["id"]},"result":null})
          JSON.parse(proxy_read.gets.not_nil!)["id"].should eq("17")
        ensure
          relay.try(&.close)
        end
      end
    end
  end
end

describe "Permission result validation" do
  it "round-trips exact metadata on the result and selected outcome" do
    metadata = %({"example.test/count":18446744073709551615,"example.test/ratio":0.123456789012345678901})
    outcome = %({"outcome":"selected","optionId":"deny","_meta":#{metadata}})
    result = ACP::Protocol::RequestPermissionResult.from_json(%({"outcome":#{outcome},"_meta":#{metadata}}))
    result.selected_option_id.should eq("deny")
    wire = ACP::Protocol::RawJson.from_json(result.to_json)
    wire.field("outcome").not_nil!.json.should eq(outcome)
    wire.field("_meta").not_nil!.json.should eq(metadata)
  end

  {1, 2}.each do |version|
    it "sends exact v#{version} outcomes while checking the original offer" do
      with_wide_stdio do |transport, feed, outgoing|
        number = "18446744073709551615"
        decimal = "0.123456789012345678901"
        metadata = %({"example.test/count":#{number},"example.test/ratio":#{decimal}})
        result = ACP::Protocol::RequestPermissionResult.cancelled
        if version == 1
          v1 = ACP::Client.new(transport)
          v1.request_timeout = 2.0
          answer_identity_request(feed, outgoing, %({"protocolVersion":1}))
          v1.initialize_connection
          v1.on_request_permission = ->(_params : ACP::Protocol::RequestPermissionParams) { result }
        else
          v2 = ACP::V2::Client.new(transport)
          v2.request_timeout = 2.0
          initialize_wide_v2(v2, feed, outgoing)
          v2.on_request_permission = ->(_params : ACP::Protocol::V2::RequestPermissionParams) { result }
        end

        option = %([{"optionId":"deny","name":"Deny","kind":"reject_once"}])
        details = version == 1 ? %({"sessionId":"s","toolCall":{"toolCallId":"tool"},"options":#{option}}) : %({"sessionId":"s","title":"Review","options":#{option}})
        result.meta_raw = ACP::Protocol::RawJson.from_json(metadata)
        {
          %({"outcome":"selected","optionId":"deny","_meta":#{metadata}})        => true,
          %({"outcome":"selected","optionId":"unavailable","_meta":#{metadata}}) => false,
          %({"outcome":"cancelled","_meta":#{metadata}})                         => true,
          %({"outcome":"_deferred","extension":{"count":#{number}}})             => (version == 2),
        }.each_with_index do |(decision, valid), id|
          result.outcome_raw = ACP::Protocol::RawJson.from_json(decision)
          feed.puts %({"jsonrpc":"2.0","id":#{id},"method":"session/request_permission","params":#{details}})
          reply = ACP::Protocol::RawJson.from_json(outgoing.gets.not_nil!)
          reply.field("id").not_nil!.as_i64?.should eq(id)
          if valid
            wire = reply.field("result").not_nil!
            wire.field("outcome").not_nil!.json.should eq(decision)
            wire.field("_meta").not_nil!.json.should eq(metadata)
          else
            reply.field("error").not_nil!.field("code").not_nil!.as_i64?.should eq(ACP::JsonRpcError::INTERNAL_ERROR)
          end
        end
      ensure
        v1.try(&.close)
        v2.try(&.close)
      end
    end
  end

  it "checks v1 selections against the original options before a raw handler can change them" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::Client.new(transport)
      client.on_agent_request = ->(_method : String, params : JSON::Any) do
        selected = params["toolCall"]["title"].as_s
        params["options"][0].as_h["optionId"] = JSON::Any.new(selected)
        JSON.parse(ACP::Protocol::RequestPermissionResult.selected(selected).to_json)
      end
      options = %([{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}])
      {"forged", "deny"}.each_with_index do |selected, id|
        feed.puts %({"jsonrpc":"2.0","id":#{id},"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"t","title":#{selected.to_json}},"options":#{options}}})
        reply = JSON.parse(outgoing.gets.not_nil!)
        if selected == "deny"
          reply["result"]["outcome"]["optionId"].as_s.should eq("deny")
        else
          reply["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INTERNAL_ERROR)
        end
      end
    ensure
      client.try(&.close)
    end
  end

  it "checks v2 selections against the original options and forwards future outcomes" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::V2::Client.new(transport)
      client.on_request_permission = ->(params : ACP::Protocol::V2::RequestPermissionParams) do
        if params.title == "forged"
          params.options << ACP::Protocol::PermissionOption.new("forged", "Forged")
          ACP::Protocol::V2::RequestPermissionResult.selected("forged")
        else
          ACP::Protocol::V2::RequestPermissionResult.new(JSON.parse(params.title))
        end
      end
      initialize_wide_v2(client, feed, outgoing)
      options = %([{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}])
      {
        "forged"                                                               => false,
        %({"outcome":"selected"})                                              => false,
        %({"outcome":"selected","optionId":3})                                 => false,
        %("cancelled")                                                         => false,
        %({"outcome":"selected","optionId":"allow","_meta":{"source":"user"}}) => true,
        %({"outcome":"selected","optionId":"deny"})                            => true,
        %({"outcome":"cancelled","_meta":{"reason":"dismissed"}})              => true,
        %({"outcome":"_deferred","extension":{"value":42}})                    => true,
        %({"outcome":"future","extension":true})                               => true,
      }.each_with_index do |(title, valid), id|
        feed.puts %({"jsonrpc":"2.0","id":#{id},"method":"session/request_permission","params":{"sessionId":"s","title":#{title.to_json},"options":#{options}}})
        reply = JSON.parse(outgoing.gets.not_nil!)
        reply["id"].as_i.should eq(id)
        if valid
          reply["result"]["outcome"].should eq(JSON.parse(title))
        else
          reply["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INTERNAL_ERROR)
        end
      end
    ensure
      client.try(&.close)
    end
  end

  it "keeps custom and future v2 outcomes opaque to the selection helper" do
    {"_deferred", "future"}.each do |kind|
      result = ACP::Protocol::V2::RequestPermissionResult.from_json(%({"outcome":{"outcome":#{kind.to_json},"optionId":"allow"}}))
      result.selected_option_id.should be_nil
      result.cancelled?.should be_false
    end
  end

  it "rejects conflicting v1 legacy selection IDs and normalizes legacy cancellation" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::Client.new(transport)
      client.on_agent_request = ->(_method : String, params : JSON::Any) do
        params["toolCall"]["reply"]
      end
      options = %([{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}])
      {
        %({"outcome":{"selected":"allow","optionId":"deny"}})                            => nil,
        %({"outcome":{"selected":"allow","optionId":42}})                                => nil,
        %({"outcome":{"selected":"deny","optionId":"deny","_meta":{"source":"legacy"}}}) => %({"outcome":{"outcome":"selected","optionId":"deny","_meta":{"source":"legacy"}}}),
        %({"outcome":"cancelled","_meta":{"reason":"dismissed"}})                        => %({"outcome":{"outcome":"cancelled"},"_meta":{"reason":"dismissed"}}),
      }.each_with_index do |(result, expected), id|
        feed.puts %({"jsonrpc":"2.0","id":#{id},"method":"session/request_permission","params":{"sessionId":"s","toolCall":{"toolCallId":"t","reply":#{result}},"options":#{options}}})
        reply = JSON.parse(outgoing.gets.not_nil!)
        if expected
          reply["result"].should eq(JSON.parse(expected))
        else
          reply["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INTERNAL_ERROR)
        end
      end
    ensure
      client.try(&.close)
    end
  end

  {1, 2}.each do |version|
    it "rejects ambiguous v#{version} offers before invoking the handler" do
      with_wide_stdio do |transport, feed, outgoing|
        calls = 0
        if version == 2
          v2 = ACP::V2::Client.new(transport)
          v2.on_request_permission = ->(_params : ACP::Protocol::V2::RequestPermissionParams) do
            calls += 1
            ACP::Protocol::V2::RequestPermissionResult.selected("allow")
          end
          initialize_wide_v2(v2, feed, outgoing)
          client = v2
        else
          v1 = ACP::Client.new(transport)
          v1.on_agent_request = ->(_method : String, _params : JSON::Any) do
            calls += 1
            JSON.parse(ACP::Protocol::RequestPermissionResult.selected("allow").to_json)
          end
          client = v1
        end

        fields = version == 2 ? %("sessionId":"s","title":"Review") : %("sessionId":"s","toolCall":{"toolCallId":"t"})
        allow = %({"optionId":"allow","name":"Allow","kind":"allow_once"})
        ambiguous = %({"optionId":"deny","optionId":"allow","name":"Review","kind":"reject_once"})
        {
          %("params":{#{fields},"options":[]},"params":{#{fields},"options":[#{allow}]}),
          %("params":{#{fields},"options":[],"options":[#{allow}]}),
          %("params":{#{fields},"options":[#{ambiguous}]}),
          %("params":{#{fields},"options":[{"optionId":"allow","name":"Allow","kind":"reject_once","kind":"allow_once"}]}),
          %("params":{#{fields},"options":[{"optionId":"allow","name":"Deny","name":"Allow","kind":"allow_once"}]}),
        }.each_with_index do |params, id|
          feed.puts %({"jsonrpc":"2.0","id":#{id},"method":"session/request_permission",#{params}})
          reply = JSON.parse(outgoing.gets.not_nil!)
          reply["id"].as_i.should eq(id)
          reply["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INVALID_PARAMS)
        end
        if version == 2
          feed.puts %({"jsonrpc":"2.0","id":"malformed","method":"session/request_permission","params":[]})
          reply = JSON.parse(outgoing.gets.not_nil!)
          reply["id"].as_s.should eq("malformed")
          reply["error"]["code"].as_i.should eq(ACP::JsonRpcError::INVALID_PARAMS)
        end
        calls.should eq(0)

        feed.puts %({"jsonrpc":"2.0","id":"valid","method":"session/request_permission","params":{#{fields},"options":[#{allow}]}})
        reply = JSON.parse(outgoing.gets.not_nil!)
        reply["result"]["outcome"]["optionId"].as_s.should eq("allow")
        calls.should eq(1)
      ensure
        client.try(&.close)
      end
    end
  end

  it "keeps dispatch running while an ambiguous permission reply waits for output" do
    reader, feed = IO.pipe
    outgoing, writer = IO.pipe
    outgoing.read_timeout = 2.seconds
    transport = PausedStdioError.new(reader, writer)
    transport.paused_code = ACP::JsonRpcError::INVALID_PARAMS
    client = ACP::Client.new(transport)
    checkpoint = Channel(Nil).new(1)
    client.on_notification = ->(method : String, _params : JSON::Any?) do
      checkpoint.send(nil) if method == "_checkpoint"
      nil
    end
    feed.puts %({"jsonrpc":"2.0","id":"ambiguous","method":"session/request_permission","params":{"options":[],"options":[]}})
    next_permission_event(transport.replying)

    feed.puts %({"jsonrpc":"2.0","method":"_checkpoint"})
    next_permission_event(checkpoint)

    transport.release.send(nil)
    reply = JSON.parse(outgoing.gets.not_nil!)
    reply["id"].as_s.should eq("ambiguous")
    reply["error"]["code"].as_i.should eq(ACP::JsonRpcError::INVALID_PARAMS)
  ensure
    transport.try { |fixture| fixture.release.close }
    client.try(&.close)
    feed.try(&.close)
    outgoing.try(&.close)
  end
end

private class PausedElicitationReplyStdio < ACP::StdioTransport
  getter replying = Channel(Nil).new(1)
  getter release = Channel(Nil).new(1)
  property? fail_write : Bool = false
  property paused_action = "accept"

  def send(message : Hash(String, JSON::Any)) : Nil
    if message["result"]?.try(&.["action"]?).try(&.as_s?) == @paused_action
      @replying.send(nil)
      @release.receive?
      raise ACP::TransportError.new("Fixture write failure") if @fail_write
    end
    super
  end
end

describe "URL elicitation completion correlation" do
  {1, 2}.each do |version|
    it "delivers each accepted v#{version} URL completion once and ignores malformed or unknown IDs" do
      with_wide_stdio do |transport, feed, outgoing|
        caps = ACP::Protocol::ElicitationCapabilities.new(url: ACP::Protocol::ElicitationUrlCapabilities.new)
        if version == 2
          v2 = ACP::V2::Client.new(transport, capabilities: ACP::Protocol::V2::ClientCapabilities.new(elicitation: caps))
          client = v2
          initialize_wide_v2(v2, feed, outgoing)
        else
          client = ACP::Client.new(transport, client_capabilities: ACP::Protocol::ClientCapabilities.new(elicitation: caps))
        end
        received = [] of String
        checkpoints = Channel(Nil).new(1)
        client.on_create_elicitation = ->(params : ACP::Protocol::CreateElicitationParams) do
          params.message == "Accept" ? ACP::Protocol::CreateElicitationResult.accept : ACP::Protocol::CreateElicitationResult.decline
        end
        client.on_elicitation_complete = ->(note : ACP::Protocol::CompleteElicitationParams) { received << note.elicitation_id; nil }
        client.on_notification = ->(method : String, params : JSON::Any?) do
          case method
          when "_checkpoint"          then checkpoints.send(nil)
          when "elicitation/complete" then received << "raw:#{params.not_nil!["elicitationId"].as_s}"
          end
          nil
        end
        completion = ->(fields : String) { feed.puts %({"jsonrpc":"2.0","method":"elicitation/complete",#{fields}}) }
        create = ->(id : Int32, fields : String, message : String) do
          feed.puts %({"jsonrpc":"2.0","id":#{id},"method":"elicitation/create","params":{"mode":"url","sessionId":"s","message":#{message.to_json},"url":"https://example.test/interaction",#{fields}}})
          JSON.parse(outgoing.gets.not_nil!)
        end
        barrier = -> do
          feed.puts %({"jsonrpc":"2.0","method":"_checkpoint"})
          next_permission_event(checkpoints)
        end

        completion.call(%("params":{"elicitationId":"first"}))
        barrier.call
        received.should be_empty
        create.call(1, %("elicitationId":"first"), "Accept")["result"]["action"].as_s.should eq("accept")
        create.call(2, %("elicitationId":"first"), "Accept")["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INVALID_PARAMS)
        create.call(3, %("elicitationId":"other","elicitationId":"forged"), "Accept")["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INVALID_PARAMS)
        completion.call(%("params":{"elicitationId":"other","elicitationId":"first"}))
        completion.call(%("params":{"elicitationId":"first"},"params":{"elicitationId":"first"}))
        barrier.call
        received.should be_empty
        2.times { completion.call(%("params":{"elicitationId":"first","_meta":false})) }
        barrier.call
        received.should eq(["first"])

        create.call(4, %("elicitationId":"first"), "Decline")["result"]["action"].as_s.should eq("decline")
        completion.call(%("params":{"elicitationId":"first"}))
        barrier.call
        received.should eq(["first"])

        client.on_elicitation_complete = nil
        create.call(5, %("elicitationId":"first"), "Accept")["result"]["action"].as_s.should eq("accept")
        2.times { completion.call(%("params":{"elicitationId":"first"})) }
        barrier.call
        received.should eq(["first", "raw:first"])
        create.call(6, %("elicitationId":"wide"), "Accept")["result"]["action"].as_s.should eq("accept")
        completion.call(%("params":{"elicitationId":"wide","_meta":{"wide":18446744073709551615}}))
        barrier.call
        received.should eq(["first", "raw:first"])
      ensure
        client.try(&.close)
      end
    end
  end

  it "holds an early completion until the callback accepts and drops it when the Agent cancels" do
    with_wide_stdio do |transport, feed, outgoing|
      caps = ACP::Protocol::ElicitationCapabilities.new(url: ACP::Protocol::ElicitationUrlCapabilities.new)
      client = ACP::V2::Client.new(transport, capabilities: ACP::Protocol::V2::ClientCapabilities.new(elicitation: caps))
      initialize_wide_v2(client, feed, outgoing)
      entered = Channel(Nil).new(1)
      release = Channel(Nil).new(1)
      checkpoints = Channel(Nil).new(1)
      delivered = Channel(String).new(4)
      client.on_create_elicitation = ->(_params : ACP::Protocol::CreateElicitationParams) do
        entered.send(nil)
        release.receive?
        ACP::Protocol::CreateElicitationResult.accept
      end
      client.on_elicitation_complete = ->(note : ACP::Protocol::CompleteElicitationParams) do
        delivered.send(note.meta_raw.not_nil!.json)
        nil
      end
      client.on_notification = ->(method : String, _params : JSON::Any?) do
        checkpoints.send(nil) if method == "_checkpoint"
        nil
      end
      barrier = -> do
        feed.puts %({"jsonrpc":"2.0","method":"_checkpoint"})
        next_permission_event(checkpoints)
      end

      {"cancelled", "accepted"}.each do |id|
        feed.puts %({"jsonrpc":"2.0","id":#{id.to_json},"method":"elicitation/create","params":{"mode":"url","sessionId":"s","message":"Open","url":"https://example.test/interaction","elicitationId":"same"}})
        next_permission_event(entered)
        feed.puts %({"jsonrpc":"2.0","method":"elicitation/complete","params":{"elicitationId":"same","_meta":{"wide":18446744073709551615}}})
        barrier.call
        select
        when delivered.receive
          fail "completion was delivered before a decision"
        else
        end

        if id == "cancelled"
          feed.puts %({"jsonrpc":"2.0","id":"cancelled","method":"elicitation/create","params":{"mode":"url","sessionId":"s","message":"Second","url":"https://example.test/interaction","elicitationId":"same"}})
          collision = JSON.parse(outgoing.gets.not_nil!)
          collision["id"].raw.should be_nil
          collision["error"]["code"].as_i.should eq(ACP::JsonRpcError::INVALID_REQUEST)
          feed.puts %({"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":"cancelled"}})
          JSON.parse(outgoing.gets.not_nil!)["result"]["action"].as_s.should eq("cancel")
          release.send(nil)
          barrier.call
        else
          release.send(nil)
          JSON.parse(outgoing.gets.not_nil!)["result"]["action"].as_s.should eq("accept")
          next_permission_event(delivered).should eq(%({"wide":18446744073709551615}))
        end
      end
    ensure
      release.try(&.close)
      client.try(&.close)
    end
  end

  it "waits for an acceptance write and dispatches the completion alongside wire notifications" do
    reader, feed = IO.pipe
    outgoing, writer = IO.pipe
    outgoing.read_timeout = 2.seconds
    transport = PausedElicitationReplyStdio.new(reader, writer)
    caps = ACP::Protocol::ElicitationCapabilities.new(url: ACP::Protocol::ElicitationUrlCapabilities.new)
    client = ACP::Client.new(transport, client_capabilities: ACP::Protocol::ClientCapabilities.new(elicitation: caps))
    held = Channel(Nil).new(1)
    release = Channel(Nil).new(1)
    delivered = Channel(Nil).new(1)
    events = [] of String
    client.on_create_elicitation = ->(_params : ACP::Protocol::CreateElicitationParams) { ACP::Protocol::CreateElicitationResult.accept }
    client.on_notification = ->(method : String, _params : JSON::Any?) do
      case method
      when "_hold"
        events << "hold"
        held.send(nil)
        release.receive?
        events << "released"
      when "elicitation/complete"
        events << "completion"
        delivered.send(nil)
      end
      nil
    end
    create = ->(id : Int32) { feed.puts %({"jsonrpc":"2.0","id":#{id},"method":"elicitation/create","params":{"mode":"url","sessionId":"s","message":"Open","url":"https://example.test/interaction","elicitationId":"held"}}) }
    complete = -> { feed.puts %({"jsonrpc":"2.0","method":"elicitation/complete","params":{"elicitationId":"held"}}) }

    transport.fail_write = true
    create.call(1)
    next_permission_event(transport.replying)
    complete.call
    feed.puts %({"jsonrpc":"2.0","method":"_hold"})
    next_permission_event(held)
    events.should eq(["hold"])
    transport.release.send(nil)
    Fiber.yield
    release.send(nil)
    transport.fail_write = false

    create.call(2)
    next_permission_event(transport.replying)
    {
      %("params":{"mode":"url","sessionId":"s","message":"Open","url":"https://example.test/interaction","elicitationId":"other"}),
      %("params":{},"params":{}),
    }.each do |params|
      feed.puts %({"jsonrpc":"2.0","id":2,"method":"elicitation/create",#{params}})
      collision = JSON.parse(outgoing.gets.not_nil!)
      collision["id"].raw.should be_nil
      collision["error"]["code"].as_i.should eq(ACP::JsonRpcError::INVALID_REQUEST)
    end
    events.should eq(["hold", "released"])
    events.clear
    complete.call
    feed.puts %({"jsonrpc":"2.0","method":"_hold"})
    next_permission_event(held)
    events.should eq(["hold"])

    transport.release.send(nil)
    JSON.parse(outgoing.gets.not_nil!)["result"]["action"].as_s.should eq("accept")
    Fiber.yield
    events.should eq(["hold"])
    release.send(nil)

    next_permission_event(delivered)
    events.should eq(["hold", "released", "completion"])
  ensure
    release.try(&.close)
    transport.try { |fixture| fixture.release.close }
    client.try(&.close)
    feed.try(&.close)
    outgoing.try(&.close)
  end

  it "keeps a v1 elicitation request ID reserved during its session cancel reply" do
    reader, feed = IO.pipe
    outgoing, writer = IO.pipe
    outgoing.read_timeout = 2.seconds
    transport = PausedElicitationReplyStdio.new(reader, writer)
    transport.paused_action = "cancel"
    elicitation = ACP::Protocol::ElicitationCapabilities.new(url: ACP::Protocol::ElicitationUrlCapabilities.new)
    caps = ACP::Protocol::ClientCapabilities.new(elicitation: elicitation, subagents: ACP::Protocol::SubagentCapabilities.new)
    client = ACP::Client.new(transport, client_capabilities: caps)
    entered = Channel(Nil).new(1)
    release = Channel(Nil).new(1)
    finished = Channel(Nil).new(1)
    client.on_create_elicitation = ->(_params : ACP::Protocol::CreateElicitationParams) do
      entered.send(nil)
      release.receive?
      ACP::Protocol::CreateElicitationResult.decline
    end
    create = ->(elicitation_id : String) do
      feed.puts %({"jsonrpc":"2.0","id":1,"method":"elicitation/create","params":{"mode":"url","sessionId":"s","message":"Open","url":"https://example.test/interaction","elicitationId":#{elicitation_id.to_json}}})
    end
    create.call("first")
    next_permission_event(entered)
    spawn do
      client.session_cancel("s")
      finished.send(nil)
    end
    JSON.parse(outgoing.gets.not_nil!)["method"].as_s.should eq("session/cancel")
    next_permission_event(transport.replying)
    create.call("second")
    collision = JSON.parse(outgoing.gets.not_nil!)
    collision["id"].raw.should be_nil
    collision["error"]["code"].as_i.should eq(ACP::JsonRpcError::INVALID_REQUEST)
    transport.release.send(nil)
    JSON.parse(outgoing.gets.not_nil!)["result"]["action"].as_s.should eq("cancel")
    next_permission_event(finished)
  ensure
    release.try(&.close)
    transport.try { |fixture| fixture.release.close }
    client.try(&.close)
    feed.try(&.close)
    outgoing.try(&.close)
  end
end

private class PausedRequestElicitationStdio < ACP::StdioTransport
  getter queued = Channel(JSON::Any).new(1)
  getter release = Channel(Nil).new(1)
  property pause_method : String?
  property? pause_accept : Bool = false

  def send(message : Hash(String, JSON::Any)) : Nil
    # Catch an outbound parent even before all v2 requests use send_checked.
    pause_parent(message)
    super
  end

  def send_checked(message : Hash(String, JSON::Any), &preflight : -> Nil) : Nil
    pause_parent(message)
    if @pause_accept && message["result"]?.try(&.["action"]?.try(&.as_s?)) == "accept"
      @queued.send(message["id"])
      @release.receive?
    end
    super(message, &preflight)
  end

  def send_wire(frame : ACP::Protocol::WireFrame, &preflight : -> Nil) : Nil
    if @pause_accept
      source = ACP::Protocol::RawJson.from_json(frame.json)
      if source.field("result").try(&.field("action")).try(&.as_s?) == "accept"
        @queued.send(source.field("id").not_nil!.to_json_any)
        @release.receive?
      end
    end
    super(frame, &preflight)
  end

  private def pause_parent(message : Hash(String, JSON::Any)) : Nil
    if (method = @pause_method) && message["method"]?.try(&.as_s?) == method
      @queued.send(message["id"])
      @release.receive?
    end
  end
end

private def request_elicitation_frame(id : String, scope : String) : String
  %({"jsonrpc":"2.0","id":#{id.to_json},"method":"elicitation/create","params":{#{scope},"mode":"form","message":"Answer","requestedSchema":{"type":"object","properties":{}}}})
end

private def request_elicitation_client(transport : ACP::Transport) : ACP::V2::Client
  elicitation = ACP::Protocol::ElicitationCapabilities.new(
    form: ACP::Protocol::ElicitationFormCapabilities.new, url: ACP::Protocol::ElicitationUrlCapabilities.new)
  caps = ACP::Protocol::V2::ClientCapabilities.new(elicitation: elicitation)
  ACP::V2::Client.new(transport, capabilities: caps)
end

describe "ACP v2 request-scoped elicitations" do
  it "validates the exact written parent ID and disallows tool-call scope" do
    reader, feed = IO.pipe
    outgoing, writer = IO.pipe
    outgoing.read_timeout = 2.seconds
    transport = PausedRequestElicitationStdio.new(reader, writer)
    client = request_elicitation_client(transport)
    calls = [] of ACP::Protocol::RequestId?
    client.on_create_elicitation = ->(params : ACP::Protocol::CreateElicitationParams) do
      calls << params.request_id
      ACP::Protocol::CreateElicitationResult.decline
    end
    initialize_wide_v2(client, feed, outgoing)

    transport.pause_method = "initialize"
    initialized = Channel(ACP::Protocol::V2::InitializeResult).new(1)
    spawn { initialized.send(client.initialize_connection); nil }
    repeated_init = next_permission_event(transport.queued)
    feed.puts request_elicitation_frame("unwritten-initialize", %("requestId":#{repeated_init}))
    JSON.parse(outgoing.gets.not_nil!)["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INVALID_PARAMS)
    transport.release.send(nil)
    JSON.parse(outgoing.gets.not_nil!)["id"].should eq(repeated_init)
    feed.puts %({"jsonrpc":"2.0","id":#{repeated_init},"result":{"protocolVersion":2,"info":{"name":"agent","version":"1"}}})
    next_permission_event(initialized).protocol_version.should eq(2)

    transport.pause_method = "_parent"
    result = Channel(JSON::Any).new(1)
    spawn { result.send(client.ext_method("parent", JSON.parse("{}"))); nil }
    parent_id = next_permission_event(transport.queued)

    feed.puts request_elicitation_frame("unwritten", %("requestId":#{parent_id}))
    JSON.parse(outgoing.gets.not_nil!)["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INVALID_PARAMS)
    transport.release.send(nil)
    JSON.parse(outgoing.gets.not_nil!)["id"].should eq(parent_id)

    {
      %("requestId":#{parent_id.to_s.to_json}),
      %("requestId":#{parent_id}.0),
      %("requestId":#{parent_id},"toolCallId":"tool"),
      %("requestId":#{parent_id},"toolCallId":null),
      %("requestId":#{parent_id},"sessionId":null),
      %("requestId":#{parent_id},"requestId":#{parent_id}),
      %("requestId":99999),
    }.each_with_index do |scope, index|
      feed.puts request_elicitation_frame(index.to_s, scope)
      reply = JSON.parse(outgoing.gets.not_nil!)
      reply["id"].as_s.should eq(index.to_s)
      reply["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INVALID_PARAMS)
    end
    calls.should be_empty
    feed.puts request_elicitation_frame("valid", %("requestId":#{parent_id}))
    JSON.parse(outgoing.gets.not_nil!)["result"]["action"].as_s.should eq("decline")
    calls.should eq([parent_id.as_i64])

    feed.puts %({"jsonrpc":"2.0","id":#{parent_id},"result":{}})
    next_permission_event(result).should eq(JSON.parse("{}"))
    feed.puts request_elicitation_frame("retired", %("requestId":#{parent_id}))
    JSON.parse(outgoing.gets.not_nil!)["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INVALID_PARAMS)
    calls.size.should eq(1)
  ensure
    transport.try { |fixture| fixture.release.close }
    client.try(&.close)
    feed.try(&.close)
    outgoing.try(&.close)
  end

  it "cancels only the elicitations of the parent that finished" do
    with_wide_stdio do |transport, feed, outgoing|
      client = request_elicitation_client(transport)
      entered = Channel(ACP::Protocol::CreateElicitationParams).new(2)
      release = Channel(Nil).new(2)
      replies = Channel(JSON::Any).new(2)
      client.on_create_elicitation = ->(params : ACP::Protocol::CreateElicitationParams) do
        entered.send(params)
        release.receive?
        ACP::Protocol::CreateElicitationResult.decline
      end
      initialize_wide_v2(client, feed, outgoing)

      spawn { replies.send(client.ext_method("first", JSON.parse("{}"))); nil }
      first = JSON.parse(outgoing.gets.not_nil!)["id"]
      spawn { replies.send(client.ext_method("second", JSON.parse("{}"))); nil }
      second = JSON.parse(outgoing.gets.not_nil!)["id"]
      feed.puts request_elicitation_frame("first", %("requestId":#{first}))
      first_input = next_permission_event(entered)
      feed.puts request_elicitation_frame("second", %("requestId":#{second}))
      second_input = next_permission_event(entered)
      first_input.request_id.should eq(first.as_i64)
      second_input.request_id.should eq(second.as_i64)
      first_signal = first_input.cancellation.not_nil!
      second_signal = second_input.cancellation.not_nil!
      first_signal.closed?.should be_false
      second_signal.closed?.should be_false
      JSON.parse(first_input.to_json).as_h.has_key?("cancellation").should be_false

      feed.puts %({"jsonrpc":"2.0","id":#{first},"result":"done"})
      next_permission_event(replies).as_s.should eq("done")
      cancelled = JSON.parse(outgoing.gets.not_nil!)
      cancelled["id"].as_s.should eq("first")
      cancelled["result"]["action"].as_s.should eq("cancel")
      first_signal.closed?.should be_true
      second_signal.closed?.should be_false

      feed.puts %({"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":"second"}})
      cancelled = JSON.parse(outgoing.gets.not_nil!)
      cancelled["id"].as_s.should eq("second")
      cancelled["result"]["action"].as_s.should eq("cancel")
      second_signal.closed?.should be_true
      release.close
      feed.puts %({"jsonrpc":"2.0","id":#{second},"result":"kept"})
      next_permission_event(replies).as_s.should eq("kept")

      spawn { replies.send(client.ext_method("barrier", JSON.parse("{}"))); nil }
      barrier = JSON.parse(outgoing.gets.not_nil!)
      barrier["method"].as_s.should eq("_barrier")
      feed.puts %({"jsonrpc":"2.0","id":#{barrier["id"]},"result":true})
      next_permission_event(replies).as_bool.should be_true
    ensure
      release.try(&.close)
      client.try(&.close)
    end
  end

  {false, true}.each do |exact|
    it "drops a queued #{exact ? "exact" : "typed"} approval when the parent receives its answer" do
      reader, feed = IO.pipe
      outgoing, writer = IO.pipe
      outgoing.read_timeout = 2.seconds
      transport = PausedRequestElicitationStdio.new(reader, writer)
      transport.pause_accept = true
      client = request_elicitation_client(transport)
      client.on_create_elicitation = ->(_params : ACP::Protocol::CreateElicitationParams) do
        if exact
          ACP::Protocol::CreateElicitationResult.accept_raw(ACP::Protocol::RawJson.from_json("{}"))
        else
          ACP::Protocol::CreateElicitationResult.accept
        end
      end
      initialize_wide_v2(client, feed, outgoing)
      result = Channel(JSON::Any).new(1)
      spawn { result.send(client.ext_method("parent", JSON.parse("{}"))); nil }
      parent = JSON.parse(outgoing.gets.not_nil!)["id"]
      feed.puts request_elicitation_frame("child", %("requestId":#{parent}))
      next_permission_event(transport.queued).as_s.should eq("child")
      feed.puts %({"jsonrpc":"2.0","id":#{parent},"result":{}})
      next_permission_event(result).should eq(JSON.parse("{}"))
      cancelled = JSON.parse(outgoing.gets.not_nil!)
      cancelled["id"].as_s.should eq("child")
      cancelled["result"]["action"].as_s.should eq("cancel")
      transport.release.send(nil)

      spawn { result.send(client.ext_method("barrier", JSON.parse("{}"))); nil }
      barrier = JSON.parse(outgoing.gets.not_nil!)
      barrier["method"].as_s.should eq("_barrier")
      feed.puts %({"jsonrpc":"2.0","id":#{barrier["id"]},"result":true})
      next_permission_event(result).as_bool.should be_true
    ensure
      transport.try { |fixture| fixture.release.close }
      client.try(&.close)
      feed.try(&.close)
      outgoing.try(&.close)
    end
  end

  it "retires a timed-out parent's URL input and allows its elicitation ID to be reused" do
    with_wide_stdio do |transport, feed, outgoing|
      client = request_elicitation_client(transport)
      entered = Channel(ACP::Protocol::CreateElicitationParams).new(2)
      timed_out = Channel(ACP::RequestTimeoutError).new(1)
      result = Channel(JSON::Any).new(1)
      completions = Channel(String).new(2)
      client.on_create_elicitation = ->(params : ACP::Protocol::CreateElicitationParams) do
        entered.send(params)
        if params.message == "Wait"
          params.cancellation.not_nil!.receive?
        end
        ACP::Protocol::CreateElicitationResult.accept
      end
      client.on_elicitation_complete = ->(params : ACP::Protocol::CompleteElicitationParams) do
        completions.send(params.elicitation_id)
        nil
      end
      initialize_wide_v2(client, feed, outgoing)
      spawn do
        client.ext_method("timeout", JSON.parse("{}"), timeout: 0.5)
      rescue ex : ACP::RequestTimeoutError
        timed_out.send(ex)
      end
      parent = JSON.parse(outgoing.gets.not_nil!)["id"]
      url = ->(id : String, message : String, parent_id : JSON::Any) do
        %({"jsonrpc":"2.0","id":#{id.to_json},"method":"elicitation/create","params":{"requestId":#{parent_id},"mode":"url","message":#{message.to_json},"url":"https://example.test/interaction","elicitationId":"opaque"}})
      end
      complete = %({"jsonrpc":"2.0","method":"elicitation/complete","params":{"elicitationId":"opaque"}})
      feed.puts url.call("old", "Wait", parent)
      old_input = next_permission_event(entered)
      feed.puts complete
      cancelled_parent = JSON.parse(outgoing.gets.not_nil!)
      cancelled_parent["method"].as_s.should eq("$/cancel_request")
      cancelled_parent["params"]["requestId"].should eq(parent)
      next_permission_event(timed_out)
      cancelled = JSON.parse(outgoing.gets.not_nil!)
      cancelled["id"].as_s.should eq("old")
      cancelled["result"]["action"].as_s.should eq("cancel")
      old_input.cancellation.not_nil!.closed?.should be_true

      spawn { result.send(client.ext_method("next", JSON.parse("{}"))); nil }
      next_parent = JSON.parse(outgoing.gets.not_nil!)["id"]
      feed.puts url.call("new", "Accept", next_parent)
      next_permission_event(entered)
      accepted = JSON.parse(outgoing.gets.not_nil!)
      accepted["id"].as_s.should eq("new")
      accepted["result"]["action"].as_s.should eq("accept")
      feed.puts %({"jsonrpc":"2.0","id":#{next_parent},"result":true})
      next_permission_event(result).as_bool.should be_true
      feed.puts complete
      next_permission_event(completions).should eq("opaque")
      select
      when completions.receive
        fail "the retired interaction delivered its URL completion"
      else
      end
    ensure
      client.try(&.close)
    end
  end
end

private def form_elicitation_frame(id : Int32, schema : String, *, scope : String = %q("sessionId":"s")) : String
  wire = ACP::Protocol::RawJson.from_json(schema)
  %({"jsonrpc":"2.0","id":#{id},"method":"elicitation/create","params":{#{scope},"mode":"form","message":"Choose","requestedSchema":#{wire.json}}})
end

describe "ACP v2 form elicitation schemas" do
  it "rejects forms with missing, malformed, or unrenderable fields before the handler" do
    with_wide_stdio do |transport, feed, outgoing|
      client = request_elicitation_client(transport)
      calls = 0
      client.on_create_elicitation = ->(_params : ACP::Protocol::CreateElicitationParams) do
        calls += 1
        ACP::Protocol::CreateElicitationResult.decline
      end
      initialize_wide_v2(client, feed, outgoing)
      choice = %({"const":"a","title":"Alpha"})
      {
        %({"properties":{}}),
        %({"type":"object"}),
        %({"type":"array","properties":{}}),
        %({"type":"object","properties":{},"required":["absent"]}),
        %({"type":"object","properties":{"value":{"type":"_future"}},"required":["value"]}),
        %({"type":"object","properties":{"value":{"type":"array","items":{"type":"_future"}}},"required":["value"]}),
        %({"type":"object","properties":{"value":{"type":"string","enum":["a"],"oneOf":[#{choice}]}}}),
        %({"type":"object","properties":{"value":{"type":"string","enum":[]}}}),
        %({"type":"object","properties":{"value":{"type":"string","oneOf":[{"const":"a"}]}}}),
        %({"type":"object","properties":{"value":{"type":"array"}}}),
        %({"type":"object","properties":{"value":{"type":"array","items":{"type":"string","anyOf":[#{choice}]}}}}),
        %({"type":"object","properties":{"value":{"type":"array","items":{"anyOf":[]}}}}),
        %({"type":"object","properties":{"value":{"type":"array","items":{"type":null,"anyOf":[#{choice}]}}}}),
        %({"type":"object","properties":{"value":{"type":"integer","maximum":1.5}}}),
        %({"type":"object","properties":{"value":{"type":"string","minLength":-1}}}),
        %({"type":"object","properties":{"value":{"type":"string","minLength":2,"maxLength":1}}}),
        %({"type":"object","properties":{"value":{"type":"number","minimum":2,"maximum":1.5}}}),
        %({"type":"object","properties":{"value":{"type":"number","minimum":0.10000000000000000001,"maximum":0.1}}}),
        %({"type":"object","properties":{"value":{"type":"integer","minimum":9223372036854775807,"maximum":9223372036854775806}}}),
        %({"type":"object","properties":{"value":{"type":"array","items":{"type":"string","enum":["a"]},"minItems":2,"maxItems":1}}}),
        %({"type":"object","properties":{"value":{"type":"string","type":"boolean"}}}),
        %({"type":"object","properties":{"value":{"type":"boolean"},"value":{"type":"string"}}}),
      }.each_with_index do |schema, index|
        feed.puts form_elicitation_frame(index, schema)
        reply = JSON.parse(outgoing.gets.not_nil!)
        reply["id"].as_i.should eq(index)
        reply["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INVALID_PARAMS)
      end
      calls.should eq(0)

      feed.puts form_elicitation_frame(100, %({"type":"object","properties":{}}))
      JSON.parse(outgoing.gets.not_nil!)["result"]["action"].as_s.should eq("decline")
      calls.should eq(1)

      client.on_create_elicitation = nil
      feed.puts form_elicitation_frame(101, %({"type":"object","properties":{}}))
      JSON.parse(outgoing.gets.not_nil!)["error"]["code"].as_i.should eq(ACP::JsonRpcError::INVALID_PARAMS)
    ensure
      client.try(&.close)
    end
  end

  it "decodes standard controls and omits unsupported optional controls" do
    with_wide_stdio do |transport, feed, outgoing|
      client = request_elicitation_client(transport)
      received = Channel(ACP::Protocol::CreateElicitationParams).new(1)
      client.on_create_elicitation = ->(params : ACP::Protocol::CreateElicitationParams) do
        received.send(params)
        ACP::Protocol::CreateElicitationResult.decline
      end
      initialize_wide_v2(client, feed, outgoing)
      schema = %({"type":"object","title":false,"_meta":{"width":18446744073709551615,"label":"form"},"properties":{
        "text":{"type":"string","format":"_custom","minLength":2,"default":"ab","description":false},
        "plain":{"type":"string","enum":["a"],"oneOf":null,"minLength":-0,"default":42},
        "titled":{"type":"string","oneOf":[{"const":"a","title":"Alpha","description":42}]},
        "amount":{"type":"number","maximum":1.25e50,"default":2.5},
        "count":{"type":"integer","minimum":-9223372036854775808,"default":1.5},
        "visible":{"type":"boolean","default":true},
        "plainArray":{"type":"array","items":{"type":"string","enum":["a"],"anyOf":false},"maxItems":18446744073709551615,"default":["a",9]},
        "titledArray":{"type":"array","minItems":-0,"items":{"anyOf":[{"const":"a","title":"Alpha"}]}},
        "future":{"type":"_future","enum":18446744073709551615},
        "futureArray":{"type":"array","items":{"type":"future","enum":18446744073709551615}}
      },"required":["text"]})
      feed.puts form_elicitation_frame(1, schema)
      reply = JSON.parse(outgoing.gets.not_nil!)
      fail reply.to_json unless reply["result"]?
      reply["result"]["action"].as_s.should eq("decline")
      request = next_permission_event(received)
      raw = request.requested_schema_raw.not_nil!
      raw.field("_meta").not_nil!.field("width").not_nil!.json.should eq("18446744073709551615")
      raw.field("properties").not_nil!.field("future").not_nil!.field("enum").not_nil!.json.should eq("18446744073709551615")
      ACP::Protocol::RawJson.from_json(request.to_json).field("requested_schema_raw").should be_nil
      present = request.requested_schema.not_nil!
      present.required.should eq(["text"])
      present.title.should be_nil
      present.meta.not_nil!["label"].as_s.should eq("form")
      props = present.properties
      props.keys.should eq(["text", "plain", "titled", "amount", "count", "visible", "plainArray", "titledArray"])
      props["text"].format.should eq("_custom")
      props["text"].description.should be_nil
      props["text"].min_length.should eq(2_u32)
      props["text"].default.should eq(JSON::Any.new("ab"))
      props["plain"].enum_values.should eq(["a"])
      props["plain"].min_length.should eq(0_u32)
      props["plain"].default.should be_nil
      props["titled"].one_of.not_nil!.first.title.should eq("Alpha")
      props["titled"].one_of.not_nil!.first.description.should be_nil
      props["amount"].maximum.should eq(1.25e50)
      props["amount"].default.should eq(JSON::Any.new(2.5))
      props["count"].minimum.should eq(Int64::MIN)
      props["count"].default.should be_nil
      props["visible"].default.should eq(JSON::Any.new(true))
      props["plainArray"].items.not_nil!.enum_values.should eq(["a"])
      props["plainArray"].max_items.should eq(UInt64::MAX)
      props["plainArray"].default.should eq(JSON.parse(%(["a"])))
      props["titledArray"].items.not_nil!.any_of.not_nil!.first.const_value.should eq("a")
      props["titledArray"].min_items.should eq(0_u64)
      raw.field("properties").not_nil!.field("titledArray").not_nil!.field("minItems").not_nil!.json.should eq("-0")
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP v2 form elicitation replies" do
  it "validates submitted fields against the original schema" do
    with_wide_stdio do |transport, feed, outgoing|
      client = request_elicitation_client(transport)
      value = ACP::Protocol::CreateElicitationResult.accept
      client.on_create_elicitation = ->(input : ACP::Protocol::CreateElicitationParams) do
        # A renderer can edit its presentation without changing the wire contract.
        input.requested_schema.not_nil!.properties.clear
        input.requested_schema_raw = nil
        value
      end
      initialize_wide_v2(client, feed, outgoing)
      schema = %({"type":"object","required":["choice"],"properties":{"choice":{"type":"string","enum":["one","two"]},"text":{"type":"string","minLength":1,"maxLength":1},"integer":{"type":"integer","minimum":0,"maximum":9223372036854775806},"number":{"type":"number","minimum":0.5,"maximum":1.5},"check":{"type":"boolean"},"items":{"type":"array","items":{"anyOf":[{"const":"a","title":"Alpha"},{"const":"b","title":"Beta"}]},"minItems":1,"maxItems":2}}})
      good = {"choice" => "one", "text" => "한", "integer" => 9223372036854775806_i64, "number" => 1.25, "check" => false, "items" => ["a", "b"]} of String => ACP::Protocol::ElicitationContentValue
      bad = {
        good.reject("choice"),
        good.merge({"choice" => "three"}),
        good.merge({"text" => "두자"}),
        good.merge({"integer" => 1.5}),
        good.merge({"integer" => 9223372036854775807_i64}),
        good.merge({"number" => 2_i64}),
        good.merge({"check" => "false"}),
        good.merge({"items" => [] of String}),
        good.merge({"items" => ["unoffered"]}),
        good.merge({"unrequested" => "answer"}),
      }
      bad.each_with_index do |content, index|
        value = ACP::Protocol::CreateElicitationResult.accept(content)
        feed.puts form_elicitation_frame(index, schema)
        reply = JSON.parse(outgoing.gets.not_nil!)
        reply["id"].as_i.should eq(index)
        reply["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INTERNAL_ERROR)
      end
      value = ACP::Protocol::CreateElicitationResult.accept(good)
      feed.puts form_elicitation_frame(100, schema)
      JSON.parse(outgoing.gets.not_nil!)["result"]["content"].should eq(JSON.parse(good.to_json))

      value = ACP::Protocol::CreateElicitationResult.accept
      feed.puts form_elicitation_frame(101, schema)
      JSON.parse(outgoing.gets.not_nil!)["result"].should eq(JSON.parse(%({"action":"accept"})))

      value = ACP::Protocol::CreateElicitationResult.new("decline", good)
      feed.puts form_elicitation_frame(102, schema)
      JSON.parse(outgoing.gets.not_nil!)["result"].should eq(JSON.parse(%({"action":"decline"})))
    ensure
      client.try(&.close)
    end
  end

  it "sends exact custom content and validates standard fields in the same reply" do
    with_wide_stdio do |transport, feed, outgoing|
      client = request_elicitation_client(transport)
      result = ACP::Protocol::CreateElicitationResult.accept
      client.on_create_elicitation = ->(_params : ACP::Protocol::CreateElicitationParams) { result }
      initialize_wide_v2(client, feed, outgoing)
      schema = %({"type":"object","required":["choice"],"properties":{"choice":{"type":"string","oneOf":[{"const":"one","title":"One"}]},"number":{"type":"number","minimum":0.1,"maximum":0.2},"negative":{"type":"number","minimum":-0.2,"maximum":-0.1},"extension":{"type":"_custom"}}})
      opaque = %({"count":18446744073709551615,"precise":0.12345678901234567890,"values":[true,null,{"extra":[]} ]})
      content = ACP::Protocol::RawJson.from_json(%({"choice":"one","number":10e-2,"negative":-0.200,"extension":#{opaque}}))
      result = ACP::Protocol::CreateElicitationResult.accept_raw(content)
      result.content_raw.should eq(content)
      feed.puts form_elicitation_frame(1, schema)
      reply = ACP::Protocol::RawJson.from_json(outgoing.gets.not_nil!)
      reply.field("id").not_nil!.as_i64?.should eq(1)
      reply.field("result").not_nil!.field("content").not_nil!.json.should eq(content.json)

      {
        %({"choice":"two","extension":#{opaque}}),
        %({"choice":"one","choice":"one","extension":#{opaque}}),
        %({"choice":null}),
        %({"choice":"one","number":0.09999999999999999999}),
        %({"choice":"one","number":0.20000000000000000001}),
        %({"choice":"one","negative":-0.20000000000000000001}),
        %({"choice":"one","negative":-0.09999999999999999999}),
      }.each_with_index do |invalid, index|
        result = ACP::Protocol::CreateElicitationResult.accept_raw(ACP::Protocol::RawJson.from_json(invalid))
        feed.puts form_elicitation_frame(index + 2, schema)
        JSON.parse(outgoing.gets.not_nil!)["error"]["code"].as_i.should eq(ACP::JsonRpcError::INTERNAL_ERROR)
      end

      result = ACP::Protocol::CreateElicitationResult.accept_raw(ACP::Protocol::RawJson.from_json("null"))
      feed.puts form_elicitation_frame(100, schema)
      JSON.parse(outgoing.gets.not_nil!)["result"].should eq(JSON.parse(%({"action":"accept","content":null})))
    ensure
      client.try(&.close)
    end
  end

  it "rejects lossy projection by a transport using the default send_wire" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":2,"info":{"name":"agent","version":"1"}})
    client = request_elicitation_client(transport)
    content = ACP::Protocol::RawJson.from_json("{}")
    client.on_create_elicitation = ->(_params : ACP::Protocol::CreateElicitationParams) do
      ACP::Protocol::CreateElicitationResult.accept_raw(content)
    end
    client.initialize_connection
    next_answer(transport)["method"].as_s.should eq("initialize")
    schema = %({"type":"object","properties":{"extra":{"type":"_future"}}})
    {
      %({"extra":18446744073709551615}),
      %({"extra":0.12345678901234567890}),
      %({"extra":{"same":1,"same":2}}),
      %({"extra":10e-1}),
    }.each_with_index do |inexact, index|
      content = ACP::Protocol::RawJson.from_json(inexact)
      transport.inject_raw(form_elicitation_frame(index, schema))
      reply = next_answer(transport)
      reply["id"].as_i.should eq(index)
      reply["error"]["code"].as_i.should eq(ACP::JsonRpcError::INTERNAL_ERROR)
    end
    content = ACP::Protocol::RawJson.from_json(%({"extra":[1,0.5,true]}))
    transport.inject_raw(form_elicitation_frame(100, schema))
    next_answer(transport)["result"]["content"].should eq(content.to_json_any)
    client.closed?.should be_false
  ensure
    client.try(&.close)
  end

  it "answers when the exact result exceeds the nesting limit only after framing" do
    with_wide_stdio do |transport, feed, outgoing|
      client = request_elicitation_client(transport)
      nested = "[" * 510 + "0" + "]" * 510
      content = ACP::Protocol::RawJson.from_json(%({"extra":#{nested}}))
      client.on_create_elicitation = ->(_params : ACP::Protocol::CreateElicitationParams) do
        ACP::Protocol::CreateElicitationResult.accept_raw(content)
      end
      initialize_wide_v2(client, feed, outgoing)
      feed.puts form_elicitation_frame(12, %({"type":"object","properties":{"extra":{"type":"_future"}}}))
      reply = JSON.parse(outgoing.gets.not_nil!)
      reply["id"].as_i.should eq(12)
      reply["error"]["code"].as_i.should eq(ACP::JsonRpcError::INTERNAL_ERROR)
      reply["error"]["message"].as_s.should eq("Cannot send exact elicitation content")
      client.closed?.should be_false
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP v2 elicitation string formats" do
  it "checks the four standard formats for typed and exact submissions" do
    with_wide_stdio do |transport, feed, outgoing|
      client = request_elicitation_client(transport)
      result = ACP::Protocol::CreateElicitationResult.accept
      client.on_create_elicitation = ->(_params : ACP::Protocol::CreateElicitationParams) { result }
      initialize_wide_v2(client, feed, outgoing)

      {
        {"email", "name+tag@example.test", true},
        {"email", %("a @ b"@[IPv6:2001:db8::1]), true},
        {"email", "name@[192.0.2.1]", true},
        {"email", "name@[IPv6:2001:db8::192.000.2.1]", true},
        {"email", "name..tag@example.test", false},
        {"email", "Name <name@example.test>", false},
        {"email", "name@-example.test", false},
        {"email", "name@[256.0.2.1]", false},
        {"email", "name@[IPv6:fe80::1%eth0]", false},
        {"email", "name@[IPv6:1:2:3:4:5:6:7::]", false},
        {"email", "name@example.test.", false},
        {"email", "name@example.test.\n", false},
        {"uri", "urn:isbn:9780141036144", true},
        {"uri", "https://[2001:db8::1]/resource%20name", true},
        {"uri", "catalog://user:pass@host:2147483648/entry", true},
        {"uri", "catalog://[2001:db8::1]:2147483648/entry", true},
        {"uri", "https://[1%25scope]/", false},
        {"uri", "https://example.test:invalid/path", false},
        {"uri", "relative/resource", false},
        {"uri", "https://example.test/%zz", false},
        {"uri", "https://example.test/two words", false},
        {"date", "2000-02-29", true},
        {"date", "1900-02-29", false},
        {"date", "2026-2-01", false},
        {"date", "2026-00-01", false},
        {"date", "2026-02-00", false},
        {"date-time", "2024-02-29t23:59:59.123456789123z", true},
        {"date-time", "1990-12-31T15:59:60-08:00", true},
        {"date-time", "2015-07-01T05:29:60+05:30", true},
        {"date-time", "2026-01-01T12:00:00-00:00", true},
        {"date-time", "2026-01-01T12:00:00", false},
        {"date-time", "2026-01-01 12:00:00Z", false},
        {"date-time", "2026-01-01T24:00:00Z", false},
        {"date-time", "2026-01-01T12:00:00+24:00", false},
        {"date-time", "2026-01-01T12:00:00+00:60", false},
        {"date-time", "2026-01-01T23:59:60Z", false},
        {"date-time", "2026-01-31T23:59:61Z", false},
        {"_future_format", "plain text", true},
      }.each_with_index do |(format, value, valid), id|
        fields = {"value" => value} of String => ACP::Protocol::ElicitationContentValue
        result = if id.even?
                   ACP::Protocol::CreateElicitationResult.accept(fields)
                 else
                   ACP::Protocol::CreateElicitationResult.accept_raw(ACP::Protocol::RawJson.from_json(fields.to_json))
                 end
        schema = %({"type":"object","properties":{"value":{"type":"string","format":#{format.to_json}}}})
        feed.puts form_elicitation_frame(id, schema)
        reply = JSON.parse(outgoing.gets.not_nil!)
        reply["id"].as_i.should eq(id)
        if valid
          reply["result"]?.try(&.["content"]["value"].as_s).should eq(value)
        else
          reply["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INTERNAL_ERROR)
        end
      end
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP v1 form submission validation" do
  it "validates typed replies against the original v1 schema" do
    with_wide_stdio do |transport, feed, outgoing|
      caps = ACP::Protocol::ClientCapabilities.new(
        elicitation: ACP::Protocol::ElicitationCapabilities.new(form: ACP::Protocol::ElicitationFormCapabilities.new))
      client = ACP::Client.new(transport, client_capabilities: caps)
      result = ACP::Protocol::CreateElicitationResult.accept
      calls = 0
      client.on_create_elicitation = ->(input : ACP::Protocol::CreateElicitationParams) do
        schema = input.requested_schema.not_nil!
        schema.schema_type.should eq("object")
        input.requested_schema_raw.not_nil!.object?.should be_true
        calls += 1
        schema.properties.clear
        result
      end
      schema = %({"required":["choice"],"properties":{"choice":{"type":"string","enum":["one","two"]},"label":{"type":"string","pattern":"[a-z]{2}-[0-9]+"},"instant":{"type":"string","format":"date-time"},"choices":{"type":"array","items":{"type":"string","enum":["yes"]},"maxItems":18446744073709551615}}})
      valid = {"choice" => "one", "label" => "prefix ab-12 suffix", "instant" => "20260101T123456Z", "choices" => ["yes"]} of String => ACP::Protocol::ElicitationContentValue
      {
        valid.reject("choice"),
        valid.merge({"choice" => "unoffered"}),
        valid.merge({"label" => "wrong"}),
        valid.merge({"instant" => "no date"}),
        valid.merge({"instant" => "20260101T123456Zgarbage"}),
        valid.merge({"instant" => "2026-01-01T12:34:56+01:00garbage"}),
        valid.merge({"instant" => "2026-01-01T12:34:56+12:60"}),
        valid.merge({"instant" => "2026-01-01T12:34:56+24:00"}),
        valid.merge({"instant" => "2026-01-01T24:00:01Z"}),
        valid.merge({"instant" => "2025-W53-1T12:00Z"}),
        valid.merge({"instant" => "2026-366T12:00Z"}),
        valid.merge({"choices" => ["no"]}),
      }.each_with_index do |content, id|
        result = ACP::Protocol::CreateElicitationResult.accept(content)
        feed.puts form_elicitation_frame(id, schema)
        reply = JSON.parse(outgoing.gets.not_nil!)
        reply["id"].as_i.should eq(id)
        reply["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INTERNAL_ERROR)
      end
      result = ACP::Protocol::CreateElicitationResult.accept(valid)
      feed.puts form_elicitation_frame(100, schema)
      JSON.parse(outgoing.gets.not_nil!)["result"]["content"].should eq(JSON.parse(valid.to_json))
      {
        "2026-01-01T12:34:56", "2026-01-01T12:34:56+01", "2026-01-01T24:00:00Z",
        "2026-W53-7T12:00Z", "2024-366T12:00Z", "2026-01-01T12.123456789012345Z",
      }.each_with_index do |timestamp, id|
        content = valid.merge({"instant" => timestamp})
        result = ACP::Protocol::CreateElicitationResult.accept(content)
        feed.puts form_elicitation_frame(id + 102, schema)
        JSON.parse(outgoing.gets.not_nil!)["result"]["content"].should eq(JSON.parse(content.to_json))
      end

      {
        { %q(^[\d]+$), "42", true },
        { %q(^[\d]+$), "٤٢", false },
        { %q(^\u0061$), "a", true },
        { %q(^\u0061$), "b", false },
        { %q(^\uD83D\uDE00$), "😀", true },
        { %q(^a$), "a\n", false },
        { %q(^[[]\d$), "[4", true },
        { %q(^[[]\d$), "[0-9", false },
        { %q(^\v$), "\v", true },
        { %q(^\v$), "\n", false },
      }.each_with_index do |(pattern, label, matches), id|
        schema = %({"properties":{"label":{"type":"string","pattern":#{pattern.to_json}}}})
        result = ACP::Protocol::CreateElicitationResult.accept({"label" => label} of String => ACP::Protocol::ElicitationContentValue)
        feed.puts form_elicitation_frame(id + 300, schema)
        reply = JSON.parse(outgoing.gets.not_nil!)
        if matches
          reply["result"]["content"]["label"].as_s.should eq(label)
        else
          reply["error"]["code"].as_i.should eq(ACP::JsonRpcError::INTERNAL_ERROR)
        end
      end

      result = ACP::Protocol::CreateElicitationResult.accept
      feed.puts form_elicitation_frame(101, %({"type":null}))
      JSON.parse(outgoing.gets.not_nil!)["result"].should eq(JSON.parse(%({"action":"accept"})))

      before_malformed = calls
      {
        "null",
        %({"required":["missing"]}),
        %({"properties":{"field":{"type":"array"}}}),
        %({"properties":{"field":{"type":"array","items":{}}}}),
        %({"properties":{"field":{"type":"array","items":{"type":"string"}}}}),
        %q{{"properties":{"field":{"type":"string","pattern":"("}}}},
        %q{{"properties":{"field":{"type":"string","pattern":")|("}}}},
        %({"properties":{"field":{"type":"string","pattern":"a","pattern":"b"}}}),
      }.each_with_index do |malformed, id|
        feed.puts form_elicitation_frame(id + 200, malformed)
        JSON.parse(outgoing.gets.not_nil!)["error"]["code"].as_i.should eq(ACP::JsonRpcError::INVALID_PARAMS)
      end
      calls.should eq(before_malformed)
    ensure
      client.try(&.close)
    end
  end

  it "checks the v1 raw callback result without removing the callback" do
    with_wide_stdio do |transport, feed, outgoing|
      caps = ACP::Protocol::ClientCapabilities.new(
        elicitation: ACP::Protocol::ElicitationCapabilities.new(form: ACP::Protocol::ElicitationFormCapabilities.new))
      client = ACP::Client.new(transport, client_capabilities: caps)
      result = JSON.parse(%({"action":"accept","content":{"choice":"chosen"}}))
      called = 0
      client.on_agent_request = ->(method : String, params : JSON::Any) do
        method.should eq("elicitation/create")
        params["toolCallId"].as_i.should eq(42)
        params["requestedSchema"]["properties"].as_h.clear
        called += 1
        result
      end
      schema = %({"type":"object","properties":{"choice":{"type":"string","enum":["chosen"],"description":42,"default":false},"custom":{"type":"_custom","items":["a","b"]}},"_meta":false})
      {
        { %({"action":"accept","content":{"choice":"chosen","custom":["value"]}}), true },
        { %({"action":"accept","content":{"choice":"other"}}), false },
        { %({"action":"accept","content":{"custom":{"nested":true}}}), false },
        { %({"action":"accept","content":[]}), false },
        { %({"content":{}}), false },
        { %({"action":"decline","content":{"choice":"other"}}), true },
        { %({"action":"_future","extra":[1,2]}), true },
      }.each_with_index do |(wire, valid), id|
        result = JSON.parse(wire)
        feed.puts form_elicitation_frame(id, schema, scope: %q("sessionId":"s","toolCallId":42))
        reply = JSON.parse(outgoing.gets.not_nil!)
        reply["id"].as_i.should eq(id)
        if valid
          expected = JSON.parse(wire)
          expected.as_h.delete("content") if expected["action"].as_s == "decline"
          reply["result"].should eq(expected)
        else
          reply["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INTERNAL_ERROR)
        end
      end
      called.should eq(7)
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP elicitation request parameters" do
  it "requires a v1 scope and still accepts explicit null, integer, and string request IDs" do
    with_wide_stdio do |transport, feed, outgoing|
      caps = ACP::Protocol::ElicitationCapabilities.new(form: ACP::Protocol::ElicitationFormCapabilities.new)
      client = ACP::Client.new(transport, client_capabilities: ACP::Protocol::ClientCapabilities.new(elicitation: caps))
      calls = 0
      client.on_create_elicitation = ->(params : ACP::Protocol::CreateElicitationParams) do
        calls += 1
        ACP::Protocol::CreateElicitationResult.accept({"scope" => params.request_id.to_json} of String => ACP::Protocol::ElicitationContentValue)
      end
      client.on_agent_request = ->(_method : String, _params : JSON::Any) do
        calls += 1
        JSON.parse(%({"action":"decline"}))
      end
      schema = %({"properties":{"scope":{"type":"string"}}})
      {true, false}.each do |typed|
        client.on_create_elicitation = nil unless typed
        { %("extra":true), %("sessionId":null), %("requestId":false), %("toolCallId":"tool") }.each_with_index do |scope, id|
          feed.puts form_elicitation_frame(id, schema, scope: scope)
          reply = JSON.parse(outgoing.gets.not_nil!)
          reply["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INVALID_PARAMS)
        end
        calls.should eq(0)
      end
      client.on_create_elicitation = ->(params : ACP::Protocol::CreateElicitationParams) do
        params.tool_call_id.should be_nil
        ACP::Protocol::CreateElicitationResult.accept({"scope" => params.request_id.to_json} of String => ACP::Protocol::ElicitationContentValue)
      end
      {"null", "23", %("parent")}.each_with_index do |parent, id|
        feed.puts form_elicitation_frame(id + 100, schema, scope: %("requestId":#{parent}))
        JSON.parse(outgoing.gets.not_nil!)["result"]["content"]["scope"].as_s.should eq(parent)
      end
    ensure
      client.try(&.close)
    end
  end

  {1, 2}.each do |version|
    it "checks the v#{version} URL before invoking either callback or reserving the elicitation ID" do
      with_wide_stdio do |transport, feed, outgoing|
        caps = ACP::Protocol::ElicitationCapabilities.new(url: ACP::Protocol::ElicitationUrlCapabilities.new)
        if version == 2
          v2 = ACP::V2::Client.new(transport, capabilities: ACP::Protocol::V2::ClientCapabilities.new(elicitation: caps))
          client = v2
          initialize_wide_v2(v2, feed, outgoing)
        else
          client = ACP::Client.new(transport, client_capabilities: ACP::Protocol::ClientCapabilities.new(elicitation: caps))
        end
        calls = 0
        if client.is_a?(ACP::Client)
          client.on_agent_request = ->(_method : String, _params : JSON::Any) do
            calls += 1
            JSON.parse(%({"action":"accept"}))
          end
        end
        handler = ->(params : ACP::Protocol::CreateElicitationParams) do
          calls += 1
          params.url.should eq("https://example.test/a%20b")
          params.meta.should be_nil
          params.tool_call_id.should be_nil
          params.requested_schema.should be_nil
          ACP::Protocol::CreateElicitationResult.accept
        end
        send_url = ->(id : Int32, url : String, extra : String) do
          feed.puts %({"jsonrpc":"2.0","id":#{id},"method":"elicitation/create","params":{"mode":"url","message":"Open","sessionId":"s","elicitationId":"one","url":#{url.to_json}#{extra}}})
          JSON.parse(outgoing.gets.not_nil!)
        end
        client.on_create_elicitation = handler
        {true, false}.each do |typed|
          client.on_create_elicitation = nil unless typed
          {"/relative", "https://example.test/%GG", "https://example.test/a b"}.each_with_index do |url, id|
            reply = send_url.call(id, url, "")
            reply["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INVALID_PARAMS)
          end
        end
        calls.should eq(0)
        client.on_create_elicitation = handler
        reply = send_url.call(100, "https://example.test/a%20b", %q(,"_meta":false,"toolCallId":42,"requestedSchema":"irrelevant"))
        reply["result"]["action"].as_s.should eq("accept")
        calls.should eq(1)
      ensure
        client.try(&.close)
      end
    end
  end
end

describe "ACP elicitation extension metadata" do
  {1, 2}.each do |version|
    it "preserves v#{version} metadata across typed form and URL elicitations" do
      with_wide_stdio do |transport, feed, outgoing|
        caps = ACP::Protocol::ElicitationCapabilities.new(
          form: ACP::Protocol::ElicitationFormCapabilities.new, url: ACP::Protocol::ElicitationUrlCapabilities.new)
        if version == 2
          v2 = ACP::V2::Client.new(transport, capabilities: ACP::Protocol::V2::ClientCapabilities.new(elicitation: caps))
          client = v2
          initialize_wide_v2(v2, feed, outgoing)
        else
          client = ACP::Client.new(transport, client_capabilities: ACP::Protocol::ClientCapabilities.new(elicitation: caps))
        end
        metadata = %({"example.test/display":true,"example.test/details":{"sections":[{"visible":"original","wide":18446744073709551615,"decimal":0.123456789012345678901}]}})
        updated = metadata.sub("original", "updated")
        completions = Channel(String).new(1)
        received = Channel({Bool?, String?}).new(1)
        client.on_create_elicitation = ->(params : ACP::Protocol::CreateElicitationParams) do
          visible = params.meta.try(&.["example.test/display"]?).try(&.as_bool?)
          source = ACP::Protocol::RawJson.from_json(params.to_json).field("_meta")
          received.send({visible, source.try(&.json)})
          if section = params.meta.try(&.["example.test/details"]?).try(&.["sections"]?).try(&.as_a?).try(&.first?).try(&.as_h?)
            section["visible"] = JSON::Any.new("updated")
          end
          result = ACP::Protocol::CreateElicitationResult.accept
          result.meta_raw = params.meta_raw
          result
        end
        client.on_elicitation_complete = ->(note : ACP::Protocol::CompleteElicitationParams) do
          completions.send(note.elicitation_id)
          nil
        end

        {
          %("mode":"form","requestedSchema":{"type":"object","properties":{}}),
          %("mode":"url","elicitationId":"metadata","url":"https://example.test/"),
        }.each_with_index do |fields, id|
          feed.puts %({"jsonrpc":"2.0","id":#{id},"method":"elicitation/create","params":{"sessionId":"s","message":"Continue",#{fields},"_meta":#{metadata}}})
          reply = ACP::Protocol::RawJson.from_json(outgoing.gets.not_nil!)
          next_permission_event(received).should eq({true, metadata})
          result = reply.field("result")
          result.try(&.field("action")).try(&.as_s?).should eq("accept")
          result.try(&.field("_meta")).try(&.json).should eq(updated)
        end

        feed.puts %({"jsonrpc":"2.0","method":"elicitation/complete","params":{"elicitationId":"metadata"}})
        next_permission_event(completions).should eq("metadata")
      ensure
        client.try(&.close)
      end
    end
  end

  it "projects the same metadata through public JSON constructors" do
    metadata = %({"example.test/details":{"label":"visible","wide":18446744073709551615}})
    request = ACP::Protocol::CreateElicitationParams.from_json(%({"mode":"form","message":"Choose","sessionId":"s","requestedSchema":{"type":"object","properties":{}},"_meta":#{metadata}}))
    result = ACP::Protocol::CreateElicitationResult.from_json(%({"action":"accept","_meta":#{metadata}}))
    {request, result}.each do |value|
      value.meta.try(&.["example.test/details"]["label"].as_s?).should eq("visible")
      value.meta_raw.try(&.json).should eq(metadata)
    end

    simple = {"example.test/visible" => JSON::Any.new(true)}
    ordinary = ACP::Protocol::CreateElicitationResult.new("accept", meta: simple)
    ACP::Protocol::CreateElicitationResult.from_json(ordinary.to_json).should eq(ordinary)
    ordinary.meta_raw = ACP::Protocol::RawJson.from_json("null")
    ordinary.meta.should be_nil
  end

  it "retains exact values when editing and moving metadata array elements" do
    first = %({"label":"first","values":[{"decimal":0.123456789012345678901,"label":"old"}]})
    second = %({"label":"second","decimal":0.987654321098765432109})
    equivalent = { %({"decimal":0.123456789012345678901}), %({"decimal":0.123456789012345678902}) }
    result = ACP::Protocol::CreateElicitationResult.from_json(%({"action":"accept","_meta":{"items":[#{first},#{second}],"numbers":[0.123456789012345678901,0.987654321098765432109],"equivalent":[#{equivalent[0]},#{equivalent[1]}]}}))
    metadata = result.meta.not_nil!
    items = metadata["items"].as_a
    items[0]["values"][0].as_h["label"] = JSON::Any.new("updated")
    items.reverse!
    metadata["numbers"].as_a.unshift(JSON::Any.new("inserted"))
    metadata["equivalent"].as_a.reverse!

    edited = first.sub("old", "updated")
    result.meta_raw.try(&.json).should eq(%({"items":[#{second},#{edited}],"numbers":["inserted",0.123456789012345678901,0.987654321098765432109],"equivalent":[#{equivalent[1]},#{equivalent[0]}]}))
  end

  it "exposes editable objects in arrays with wide fields and retains opaque numeric arrays" do
    result = ACP::Protocol::CreateElicitationResult.from_json(%({"action":"accept","_meta":{"items":[{"label":"old","wide":18446744073709551615}],"opaque":[18446744073709551615]}}))
    metadata = result.meta.not_nil!
    entries = metadata["items"]?.try(&.as_a?)
    entries.should_not be_nil
    metadata.has_key?("opaque").should be_false
    entries.not_nil![0].as_h["label"] = JSON::Any.new("updated")
    result.meta_raw.try(&.json).should eq(%({"items":[{"label":"updated","wide":18446744073709551615}],"opaque":[18446744073709551615]}))
    entries.not_nil![0] = JSON.parse(%({"label":"updated"}))
    result.meta_raw.try(&.json).should eq(%({"items":[{"label":"updated"}],"opaque":[18446744073709551615]}))
  end

  it "reports an unsupported exact URL reply and releases its completion ID" do
    transport = SignalingTransport.new
    caps = ACP::Protocol::ElicitationCapabilities.new(url: ACP::Protocol::ElicitationUrlCapabilities.new)
    client = ACP::Client.new(transport, client_capabilities: ACP::Protocol::ClientCapabilities.new(elicitation: caps))
    client.on_create_elicitation = ->(_params : ACP::Protocol::CreateElicitationParams) do
      ACP::Protocol::CreateElicitationResult.from_json(%({"action":"accept","_meta":{"example.test/decimal":0.123456789012345678901}}))
    end
    request = ->(id : Int32) do
      %({"jsonrpc":"2.0","id":#{id},"method":"elicitation/create","params":{"sessionId":"s","mode":"url","message":"Open","url":"https://example.test","elicitationId":"same"}})
    end
    transport.inject_raw(request.call(1))
    reply = next_answer(transport)
    reply["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INTERNAL_ERROR)

    client.on_create_elicitation = ->(_params : ACP::Protocol::CreateElicitationParams) { ACP::Protocol::CreateElicitationResult.accept }
    transport.inject_raw(request.call(2))
    next_answer(transport)["result"]["action"].as_s.should eq("accept")
  ensure
    client.try(&.close)
  end
end

describe "ACP v1 resource callback capabilities" do
  it "uses advertised file and terminal capabilities before either callback" do
    transport = SignalingTransport.new
    read_only = ACP::Protocol::ClientCapabilities.new(fs: ACP::Protocol::FsCapabilities.new(read_text_file: true))
    client = ACP::Client.new(transport, client_capabilities: read_only)
    calls = [] of String
    client.on_read_text_file = ->(_params : ACP::Protocol::ReadTextFileParams) do
      calls << "read"
      ACP::Protocol::ReadTextFileResult.new("fixture")
    end
    client.on_write_text_file = ->(_params : ACP::Protocol::WriteTextFileParams) do
      calls << "write"
      ACP::Protocol::WriteTextFileResult.new
    end
    client.on_agent_request = ->(method : String, _params : JSON::Any) do
      calls << method
      JSON.parse("{}")
    end
    send_request = ->(id : String, method : String, fields : String) do
      transport.inject_raw(%({"jsonrpc":"2.0","id":#{id.to_json},"method":#{method.to_json},"params":{"sessionId":"s",#{fields}}}))
      next_answer(transport)
    end

    read_fields = %("path":"/file")
    send_request.call("early", "fs/read_text_file", read_fields)["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::METHOD_NOT_FOUND)
    spawn do
      request = next_answer(transport)
      transport.inject_raw(build_init_response(request["id"].as_i64))
    end
    client.initialize_connection
    client.client_capabilities = ACP::Protocol::ClientCapabilities.new(
      fs: ACP::Protocol::FsCapabilities.new(write_text_file: true), terminal: true)

    send_request.call("read", "fs/read_text_file", read_fields)["result"]["content"].as_s.should eq("fixture")
    {
      {"fs/write_text_file", %("path":"/file","content":"fixture")},
      {"terminal/create", %("command":"fixture")},
      {"terminal/output", %("terminalId":"t")},
      {"terminal/release", %("terminalId":"t")},
      {"terminal/wait_for_exit", %("terminalId":"t")},
      {"terminal/kill", %("terminalId":"t")},
    }.each do |method, fields|
      reply = send_request.call(method, method, fields)
      reply["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::METHOD_NOT_FOUND)
    end
    calls.should eq(["read"])
  ensure
    client.try(&.close)
  end

  it "uses the raw initialize offer for generic callbacks" do
    transport = SignalingTransport.new
    client = ACP::Client.new(transport)
    entered = Channel(String).new(2)
    client.on_agent_request = ->(method : String, _params : JSON::Any) do
      entered.send(method)
      JSON.parse(%({"terminalId":"fixture"}))
    end
    offer = JSON.parse(%({"protocolVersion":1,"clientCapabilities":{"terminal":true}}))
    terminal_request = %({"jsonrpc":"2.0","id":"terminal","method":"terminal/create","params":{"sessionId":"s","command":"fixture"}})
    spawn do
      request = next_answer(transport)
      transport.inject_raw(%({"jsonrpc":"2.0","id":#{request["id"].as_i64},"error":{"code":-32603,"message":"Initialization failed"}}))
    end
    expect_raises(ACP::JsonRpcError) { client.send_request_raw("initialize", offer) }
    transport.inject_raw(terminal_request)
    next_answer(transport)["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::METHOD_NOT_FOUND)

    finished = Channel(JSON::Any).new(1)
    spawn do
      finished.send(client.send_request_raw("initialize", offer))
    end
    request = next_answer(transport)
    transport.inject_raw(build_init_response(request["id"].as_i64))
    transport.inject_raw(terminal_request)
    transport.inject_raw(%({"jsonrpc":"2.0","id":"extension","method":"_test","params":{}}))
    replies = {next_answer(transport), next_answer(transport)}
    replies.each { |reply| reply["result"]?.try(&.["terminalId"].as_s?).should eq("fixture") }
    methods = {next_permission_event(entered), next_permission_event(entered)}
    methods.to_a.sort.should eq(["_test", "terminal/create"])
    next_permission_event(finished)["protocolVersion"].as_i.should eq(1)
  ensure
    client.try(&.close)
  end

  it "keeps a queued raw initialize offer consistent with the request written to stdio" do
    reader, feed = IO.pipe
    outgoing, writer = IO.pipe
    outgoing.read_timeout = 2.seconds
    transport = PausedRequestElicitationStdio.new(reader, writer)
    transport.pause_method = "initialize"
    client = ACP::Client.new(transport)
    client.request_timeout = 2.0
    client.on_agent_request = ->(_method : String, _params : JSON::Any) do
      JSON.parse(%({"terminalId":"fixture"}))
    end

    offer = JSON.parse(%({"protocolVersion":1,"clientCapabilities":{"terminal":true}}))
    finished = Channel(JSON::Any).new(1)
    spawn { finished.send(client.send_request_raw("initialize", offer)) }
    id = next_permission_event(transport.queued).as_i64
    offer["clientCapabilities"].as_h["terminal"] = JSON::Any.new(false)

    request = %({"jsonrpc":"2.0","id":"term","method":"terminal/create","params":{"sessionId":"s","command":"fixture"}})
    feed.puts request
    JSON.parse(outgoing.gets.not_nil!)["error"]["code"].as_i.should eq(ACP::JsonRpcError::METHOD_NOT_FOUND)

    transport.release.send(nil)
    initialize = JSON.parse(outgoing.gets.not_nil!)
    initialize["params"]["clientCapabilities"]["terminal"].as_bool.should be_true
    feed.puts build_init_response(id).delete('\n')
    feed.puts request
    JSON.parse(outgoing.gets.not_nil!)["result"]["terminalId"].as_s.should eq("fixture")
    next_permission_event(finished)["protocolVersion"].as_i.should eq(1)
  ensure
    transport.try(&.release.close)
    client.try(&.close)
    feed.try(&.close)
    outgoing.try(&.close)
  end

  it "keeps the latest successful offer when overlapping initialize replies are reordered" do
    { {true, true}, {false, true}, {false, false} }.each do |(first_reply_first, second_fails)|
      transport = SignalingTransport.new
      client = ACP::Client.new(transport)
      client.request_timeout = 2.0
      client.on_agent_request = ->(_method : String, _params : JSON::Any) do
        JSON.parse(%({"terminalId":"fixture"}))
      end
      finished = Channel(Bool).new(2)
      send_offer = ->(terminal : Bool) do
        spawn do
          offer = JSON.parse(%({"protocolVersion":1,"clientCapabilities":{"terminal":#{terminal}}}))
          client.send_request_raw("initialize", offer)
          finished.send(true)
        rescue ACP::JsonRpcError
          finished.send(false)
        end
        nil
      end

      send_offer.call(true)
      first_id = next_answer(transport)["id"].as_i64
      send_offer.call(false)
      second_id = next_answer(transport)["id"].as_i64
      first = build_init_response(first_id)
      second = if second_fails
                 %({"jsonrpc":"2.0","id":#{second_id},"error":{"code":-32603,"message":"Initialization failed"}})
               else
                 build_init_response(second_id)
               end
      replies = first_reply_first ? {first, second} : {second, first}
      replies.each { |reply| transport.inject_raw(reply) }
      outcomes = {next_permission_event(finished), next_permission_event(finished)}
      outcomes.count(true).should eq(second_fails ? 1 : 2)

      transport.inject_raw(%({"jsonrpc":"2.0","id":"term","method":"terminal/create","params":{"sessionId":"s","command":"fixture"}}))
      reply = next_answer(transport)
      if second_fails
        reply["result"]["terminalId"].as_s.should eq("fixture")
      else
        reply["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::METHOD_NOT_FOUND)
      end
    ensure
      client.try(&.close)
    end
  end

  it "rejects malformed initialize replies before activating the advertised methods" do
    with_wide_stdio do |transport, feed, outgoing|
      client = ACP::Client.new(transport, client_capabilities: ACP::Protocol::ClientCapabilities.new(terminal: true))
      client.request_timeout = 2.0
      client.on_agent_request = ->(_method : String, _params : JSON::Any) do
        JSON.parse(%({"output":"fixture","truncated":false}))
      end
      request = %({"jsonrpc":"2.0","id":"term","method":"terminal/output","params":{"sessionId":"s","terminalId":"t"}})
      {
        { %q("jsonrpc":"1.0"), %q("protocolVersion":1) },
        { %q("jsonrpc":"1.0","jsonrpc":"2.0"), %q("protocolVersion":1) },
        { %q("jsonrpc":"2.0"), %q("protocolVersion":2,"protocolVersion":1) },
      }.each do |(header, versions)|
        finished = Channel(Bool).new(1)
        spawn do
          client.initialize_connection
          finished.send(false)
        rescue ACP::ProtocolError
          finished.send(true)
        end
        id = JSON.parse(outgoing.gets.not_nil!)["id"].as_i64
        feed.puts %({#{header},"id":#{id},"result":{#{versions}}})
        next_permission_event(finished).should be_true
        feed.puts request
        JSON.parse(outgoing.gets.not_nil!)["error"]["code"].as_i.should eq(ACP::JsonRpcError::METHOD_NOT_FOUND)
      end
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP v1 resource request parameters" do
  it "validates resource requests before either typed or generic callbacks" do
    with_wide_stdio do |transport, feed, outgoing|
      caps = ACP::Protocol::ClientCapabilities.new(
        fs: ACP::Protocol::FsCapabilities.new(read_text_file: true, write_text_file: true), terminal: true)
      client = ACP::Client.new(transport, client_capabilities: caps)
      spawn do
        init = JSON.parse(outgoing.gets.not_nil!)
        feed.puts build_init_response(init["id"].as_i64).delete('\n')
      end
      client.initialize_connection
      calls = [] of String
      client.on_read_text_file = ->(params : ACP::Protocol::ReadTextFileParams) do
        calls << params.path
        ACP::Protocol::ReadTextFileResult.new(params.path)
      end
      client.on_create_terminal = ->(params : ACP::Protocol::CreateTerminalParams) do
        calls << params.command
        environment = ACP::Protocol::RawJson.from_json(params.to_json).field("env")
        ACP::Protocol::CreateTerminalResult.new(environment.try(&.json) || "t")
      end
      client.on_agent_request = ->(method : String, params : JSON::Any) do
        calls << method
        result = {"example.test/request" => params}
        result["terminalId"] = JSON::Any.new("t") if method == "terminal/create"
        JSON::Any.new(result)
      end
      request = ->(id : Int32, method : String, params : String) do
        feed.puts %({"jsonrpc":"2.0","id":#{id},"method":#{method.to_json},"params":#{params}})
        JSON.parse(outgoing.gets.not_nil!)
      end
      invalid = {
        {"fs/read_text_file", %({"sessionId":"s","path":"relative.txt"})},
        {"fs/read_text_file", %q({"sessionId":"s","path":"/file\u0000suffix"})},
        {"fs/read_text_file", %({"sessionId":"s","path":"/a","path":"/b"})},
        {"fs/read_text_file", %({"sessionId":"s","path":"/a","line":-1})},
        {"fs/read_text_file", %({"sessionId":"s","path":"/a","line":0})},
        {"fs/write_text_file", %({"sessionId":"s","path":"relative.txt","content":"example"})},
        {"fs/write_text_file", %({"sessionId":"s","path":"/a","content":false})},
        {"terminal/create", %({"sessionId":"s","command":"fixture","cwd":"relative"})},
        {"terminal/create", %({"sessionId":"s","command":"fixture","env":[false]})},
        {"terminal/create", %({"sessionId":"s","command":"fixture","env":[{"name":"FIXTURE"}]})},
        {"terminal/create", %({"sessionId":"s","command":"fixture","env":[{"name":"FIXTURE","name":"OTHER","value":"sample"}]})},
        {"terminal/create", %({"sessionId":"s","command":"fixture","env":[{"name":"FIXTURE=OTHER","value":"sample"}]})},
        {"terminal/create", %q({"sessionId":"s","command":"fixture","env":[{"name":"FIXTURE","value":"a\u0000b"}]})},
        {"terminal/create", %q({"sessionId":"s","command":"fixture\u0000suffix"})},
        {"terminal/create", %q({"sessionId":"s","command":"fixture","args":["a\u0000b"]})},
        {"terminal/output", %({"sessionId":"s","terminalId":false})},
        {"terminal/wait_for_exit", %({"terminalId":"t"})},
        {"terminal/release", %({"sessionId":"s","terminalId":"t","terminalId":"other"})},
        {"terminal/kill", %({"sessionId":"s"})},
      }
      {true, false}.each do |typed|
        unless typed
          client.on_read_text_file = nil
          client.on_create_terminal = nil
        end
        invalid.each_with_index do |(method, params), id|
          reply = request.call(id, method, params)
          reply["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INVALID_PARAMS)
        end
      end
      feed.puts %({"jsonrpc":"2.0","id":19,"method":"fs/read_text_file","params":{},"params":{"sessionId":"s","path":"/fixture"}})
      JSON.parse(outgoing.gets.not_nil!)["error"]["code"].as_i.should eq(ACP::JsonRpcError::INVALID_PARAMS)
      {
        %q("jsonrpc":"1.0"),
        %q("jsonrpc":"2.0","jsonrpc":"2.0"),
        %q("jsonrpc":"2.0","result":{}),
        %q("jsonrpc":"2.0","error":null),
      }.each_with_index do |envelope, id|
        feed.puts %({#{envelope},"id":#{id + 30},"method":"terminal/output","params":{"sessionId":"s","terminalId":"t"}})
        JSON.parse(outgoing.gets.not_nil!)["error"]["code"].as_i.should eq(ACP::JsonRpcError::INVALID_REQUEST)
      end
      calls.should be_empty

      write_params = %({"sessionId":"s","path":"/fixture","content":"example","_meta":false})
      request.call(20, "fs/write_text_file", write_params)["result"]["example.test/request"].should eq(JSON.parse(write_params))
      create_params = %({"sessionId":"s","command":"fixture","outputByteLimit":-0})
      request.call(21, "terminal/create", create_params)["result"]["example.test/request"]["outputByteLimit"].as_i.should eq(0)
      calls.should eq(["fs/write_text_file", "terminal/create"])
    ensure
      client.try(&.close)
    end
  end

  it "accepts absolute paths and preserves exact terminal environment metadata for typed handlers" do
    with_wide_stdio do |transport, feed, outgoing|
      client = initialized_v1_terminal_client(transport, feed, outgoing)
      environment = %([{"name":"FIXTURE","value":"example","_meta":{"example.test/wide":18446744073709551615}}])
      received = Channel({String?, String?, UInt64?}).new(2)
      client.on_create_terminal = ->(params : ACP::Protocol::CreateTerminalParams) do
        source = ACP::Protocol::RawJson.from_json(params.to_json)
        env = source.field("env").try(&.json)
        name = params.env.try(&.first?).try(&.["name"]?).try(&.as_s?)
        received.send({name, params.env_raw.try(&.json), params.output_byte_limit})
        ACP::Protocol::CreateTerminalResult.new(env || params.cwd || "t")
      end
      feed.puts %({"jsonrpc":"2.0","id":1,"method":"terminal/create","params":{"sessionId":"s","command":"fixture","cwd":"C:/project","args":null,"env":#{environment},"_meta":false}})
      reply = JSON.parse(outgoing.gets.not_nil!)
      reply["result"]?.try(&.["terminalId"].as_s?).should eq(environment)
      next_permission_event(received).should eq({"FIXTURE", environment, nil})
      feed.puts %({"jsonrpc":"2.0","id":2,"method":"terminal/create","params":{"sessionId":"s","command":"fixture","cwd":"/project","env":null,"outputByteLimit":-0}})
      JSON.parse(outgoing.gets.not_nil!)["result"]["terminalId"].as_s.should eq("/project")
      next_permission_event(received).should eq({nil, nil, 0_u64})
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP v1 resource reply metadata" do
  it "preserves exact metadata from typed file and terminal replies over stdio" do
    with_wide_stdio do |transport, feed, outgoing|
      caps = ACP::Protocol::ClientCapabilities.new(
        fs: ACP::Protocol::FsCapabilities.new(read_text_file: true, write_text_file: true), terminal: true)
      client = ACP::Client.new(transport, client_capabilities: caps)
      spawn do
        init = JSON.parse(outgoing.gets.not_nil!)
        feed.puts build_init_response(init["id"].as_i64).delete('\n')
      end
      client.initialize_connection
      metadata = %({"example.test/wide":18446744073709551615,"example.test/decimal":0.123456789012345678901})
      exit_status = %({"exitCode":4294967295,"_meta":#{metadata}})
      client.on_read_text_file = ->(params : ACP::Protocol::ReadTextFileParams) do
        result = ACP::Protocol::ReadTextFileResult.new("fixture")
        result.meta_raw = params.meta_raw
        result
      end
      client.on_write_text_file = ->(_params : ACP::Protocol::WriteTextFileParams) do
        ACP::Protocol::WriteTextFileResult.from_json(%({"_meta":#{metadata}}))
      end
      client.on_create_terminal = ->(_params : ACP::Protocol::CreateTerminalParams) do
        ACP::Protocol::CreateTerminalResult.from_json(%({"terminalId":"t","_meta":#{metadata}}))
      end
      client.on_terminal_output = ->(_params : ACP::Protocol::TerminalOutputParams) do
        ACP::Protocol::TerminalOutputResult.from_json(%({"output":"fixture","truncated":false,"exitStatus":#{exit_status},"_meta":#{metadata}}))
      end
      client.on_release_terminal = ->(_params : ACP::Protocol::ReleaseTerminalParams) do
        ACP::Protocol::ReleaseTerminalResult.from_json(%({"_meta":#{metadata}}))
      end
      client.on_wait_for_terminal_exit = ->(_params : ACP::Protocol::WaitForTerminalExitParams) do
        ACP::Protocol::WaitForTerminalExitResult.from_json(exit_status)
      end
      client.on_kill_terminal = ->(_params : ACP::Protocol::KillTerminalParams) do
        ACP::Protocol::KillTerminalResult.from_json(%({"_meta":#{metadata}}))
      end

      {
        {"fs/read_text_file", %("path":"/fixture","_meta":#{metadata})},
        {"fs/write_text_file", %("path":"/fixture","content":"fixture")},
        {"terminal/create", %("command":"fixture")},
        {"terminal/output", %("terminalId":"t")},
        {"terminal/wait_for_exit", %("terminalId":"t")},
        {"terminal/kill", %("terminalId":"t")},
        {"terminal/release", %("terminalId":"t")},
      }.each_with_index do |(method, params), id|
        feed.puts %({"jsonrpc":"2.0","id":#{id},"method":#{method.to_json},"params":{"sessionId":"s",#{params}}})
        reply = ACP::Protocol::RawJson.from_json(outgoing.gets.not_nil!)
        reply.field("id").try(&.as_i64?).should eq(id)
        result = reply.field("result")
        result.try(&.field("_meta")).try(&.json).should eq(metadata)
        if method == "terminal/output"
          status = result.try(&.field("exitStatus"))
          status.try(&.field("exitCode")).try(&.as_i64?).should eq(UInt32::MAX)
          status.try(&.field("_meta")).try(&.json).should eq(metadata)
        end
      end
    ensure
      client.try(&.close)
    end
  end

  it "reports an exact reply the transport cannot preserve and handles the next request" do
    transport = SignalingTransport.new
    client = initialized_read_client(transport)
    request = ->(id : Int32) { %({"jsonrpc":"2.0","id":#{id},"method":"fs/read_text_file","params":{"sessionId":"s","path":"/fixture"}}) }
    client.on_read_text_file = ->(_params : ACP::Protocol::ReadTextFileParams) do
      ACP::Protocol::ReadTextFileResult.from_json(%({"content":"fixture","_meta":{"example.test/decimal":0.123456789012345678901}}))
    end
    transport.inject_raw(request.call(1))
    reply = next_answer(transport)
    reply["id"].as_i.should eq(1)
    reply["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INTERNAL_ERROR)
    reply["error"]["message"].as_s.should contain("fs/read_text_file")

    client.on_read_text_file = ->(_params : ACP::Protocol::ReadTextFileParams) do
      ACP::Protocol::ReadTextFileResult.new("fixture", {"example.test/flag" => JSON::Any.new(true)})
    end
    transport.inject_raw(request.call(2))
    next_answer(transport)["result"].should eq(JSON.parse(%({"content":"fixture","_meta":{"example.test/flag":true}})))
  ensure
    client.try(&.close)
  end

  it "honors the wire nesting limit for representable metadata in stdio replies" do
    with_wide_stdio do |transport, feed, outgoing|
      client = initialized_v1_terminal_client(transport, feed, outgoing)
      {120, 509, 510}.each_with_index do |depth, id|
        nested = "[" * depth + "1" + "]" * depth
        metadata = %({"example.test/nested":#{nested}})
        client.on_create_terminal = ->(_params : ACP::Protocol::CreateTerminalParams) do
          ACP::Protocol::CreateTerminalResult.from_json(%({"terminalId":"t-#{id}","_meta":#{metadata}}))
        end
        feed.puts %({"jsonrpc":"2.0","id":#{id},"method":"terminal/create","params":{"sessionId":"s","command":"fixture"}})
        reply = ACP::Protocol::RawJson.from_json(outgoing.gets.not_nil!)
        reply.field("id").try(&.as_i64?).should eq(id)
        if depth == 510
          reply.field("error").try(&.field("code")).try(&.as_i64?).should eq(ACP::JsonRpcError::INTERNAL_ERROR)
        else
          reply.field("result").try(&.field("_meta")).try(&.json).should eq(metadata)
        end
      end
    ensure
      client.try(&.close)
    end
  end

  it "answers an exact reply refused by the relay line limit" do
    reader, feed = IO.pipe
    outgoing, writer = IO.pipe
    outgoing.read_timeout = 2.seconds
    transport = ACP::StdioTransport.new(reader, writer, max_line_bytes: 512, exact_frames: true)
    client = ACP::Client.new(transport, client_capabilities: ACP::Protocol::ClientCapabilities.new(terminal: true))
    spawn do
      init = JSON.parse(outgoing.gets.not_nil!)
      feed.puts %({"jsonrpc":"2.0","id":#{init["id"].as_i64},"result":{"protocolVersion":1}})
    end
    client.initialize_connection
    metadata = %({"example.test/wide":18446744073709551615,"example.test/text":#{("a" * 600).to_json}})
    client.on_create_terminal = ->(_params : ACP::Protocol::CreateTerminalParams) do
      ACP::Protocol::CreateTerminalResult.from_json(%({"terminalId":"t","_meta":#{metadata}}))
    end
    request = %({"jsonrpc":"2.0","id":1,"method":"terminal/create","params":{"sessionId":"s","command":"fixture"}})
    feed.puts request
    reply = JSON.parse(outgoing.gets.not_nil!)
    reply["id"].as_i.should eq(1)
    reply["error"]["code"].as_i.should eq(ACP::JsonRpcError::INTERNAL_ERROR)

    client.on_create_terminal = ->(_params : ACP::Protocol::CreateTerminalParams) { ACP::Protocol::CreateTerminalResult.new("t") }
    feed.puts request
    JSON.parse(outgoing.gets.not_nil!)["result"]["terminalId"].as_s.should eq("t")
  ensure
    client.try(&.close)
    feed.try(&.close)
    outgoing.try(&.close)
  end
end

describe "ACP v1 generic resource replies" do
  it "validates known success fields while preserving extensions and handler errors" do
    with_wide_stdio do |transport, feed, outgoing|
      caps = ACP::Protocol::ClientCapabilities.new(
        fs: ACP::Protocol::FsCapabilities.new(read_text_file: true, write_text_file: true), terminal: true)
      client = ACP::Client.new(transport, client_capabilities: caps)
      spawn do
        init = JSON.parse(outgoing.gets.not_nil!)
        feed.puts build_init_response(init["id"].as_i64).delete('\n')
      end
      client.initialize_connection
      reply = JSON.parse("{}")
      client.on_agent_request = ->(_method : String, _params : JSON::Any) { reply }
      request = ->(id : Int32, method : String, params : String) do
        feed.puts %({"jsonrpc":"2.0","id":#{id},"method":#{method.to_json},"params":{"sessionId":"s",#{params}}})
        answer = JSON.parse(outgoing.gets.not_nil!)
        answer["id"].as_i.should eq(id)
        answer
      end

      terminal = %("terminalId":"t")
      create = %("command":"fixture")
      file = %("path":"/fixture")
      invalid_output = {
        %({"output":""}),
        %({"output":"","truncated":null}),
        %({"truncated":false}),
        %({"output":"","truncated":false,"exitStatus":[]}),
        %({"output":"","truncated":false,"exitStatus":{"exitCode":4294967296}}),
        %({"output":"","truncated":false,"exitStatus":{"_meta":false}}),
      }
      valid_output = %({"output":"","truncated":false,"exitStatus":{"exitCode":4294967295,"signal":null,"_meta":{"example.test/flag":true}}})
      cases = {
        {"fs/read_text_file", file, {"{}", %({"content":false})}, %({"content":"","example.test/extra":[1]})},
        {"fs/write_text_file", %(#{file},"content":"fixture"), {"null", "[]"}, %({"_meta":{"example.test/flag":true}})},
        {"terminal/create", create, {"{}", %({"terminalId":null})}, %({"terminalId":"t","note":true})},
        {"terminal/output", terminal, invalid_output, valid_output},
        {"terminal/wait_for_exit", terminal, { %({"exitCode":-1}), %({"signal":false}), "null" }, %({"exitCode":null,"signal":"fixture","detail":"accepted"})},
        {"terminal/kill", terminal, { %({"_meta":[]}) }, %({"_meta":null})},
        {"terminal/release", terminal, {"false"}, "{}"},
      }
      cases.each_with_index do |(method, params, invalid, valid), id|
        invalid.each do |result|
          reply = JSON.parse(result)
          answer = request.call(id, method, params)
          answer["error"]?.try(&.["code"].as_i?).should eq(ACP::JsonRpcError::INTERNAL_ERROR)
        end
        reply = JSON.parse(valid)
        request.call(id, method, params)["result"].should eq(reply)
      end

      reply = JSON::Any.new({"content" => JSON::Any.new("fixture"), "example.test/value" => JSON::Any.new(Float64::NAN)})
      request.call(90, "fs/read_text_file", file)["error"]["code"].as_i.should eq(ACP::JsonRpcError::INTERNAL_ERROR)
      nested = "[" * 511 + "0" + "]" * 511
      reply = JSON.parse(%({"content":"fixture","example.test/nested":#{nested}}))
      request.call(91, "fs/read_text_file", file)["error"]["code"].as_i.should eq(ACP::JsonRpcError::INTERNAL_ERROR)

      reply = JSON.parse("42")
      request.call(100, "_fixture", %("example":true))["result"].as_i.should eq(42)
      client.on_agent_request = ->(_method : String, _params : JSON::Any) : JSON::Any do
        raise ACP::JsonRpcError.new(ACP::JsonRpcError::RESOURCE_NOT_FOUND, "Fixture missing", JSON.parse(%({"detail":"fixture"})))
      end
      error = request.call(101, "fs/read_text_file", file)["error"]
      error["code"].as_i.should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)
      error["data"]["detail"].as_s.should eq("fixture")
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP v1 session workspaces" do
  it "makes the attached roots available to file callbacks and retires each scope independently" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"additionalDirectories":{},"close":{},"delete":{}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"first"})
    caps = ACP::Protocol::ClientCapabilities.new(fs: ACP::Protocol::FsCapabilities.new(read_text_file: true))
    client = ACP::Client.new(transport, client_capabilities: caps)
    client.request_timeout = 2.0
    client.initialize_connection
    next_answer(transport)
    client.on_read_text_file = ->(params : ACP::Protocol::ReadTextFileParams) do
      workspace = client.session_workspace(params.session_id)
      ACP::Protocol::ReadTextFileResult.new(workspace.try { |roots| ([roots.cwd] + roots.additional_directories).join(",") } || "unknown")
    end

    transport.after_reply = ->(method : String, _request : Hash(String, JSON::Any)) do
      if method == "session/new"
        transport.inject_raw(%({"jsonrpc":"2.0","id":"read","method":"fs/read_text_file","params":{"sessionId":"first","path":"/work/file"}}))
      end
    end
    client.session_new("/work", additional_directories: ["/docs"])
    next_answer(transport)["method"].should eq("session/new")
    next_answer(transport)["result"]["content"].should eq("/work,/docs")
    transport.after_reply = nil

    transport.replies["session/new"] = %("result":{"sessionId":"second"})
    client.session_new("C:/other")
    first = client.session_workspace("first").not_nil!
    first.additional_directories.clear
    client.session_workspace("first").should eq(ACP::SessionWorkspace.new("/work", ["/docs"]))
    client.session_workspace("second").should eq(ACP::SessionWorkspace.new("C:/other", [] of String))
    client.session_workspace("unattached").should be_nil

    transport.replies["session/delete"] = %("result":{})
    client.session_delete("first")
    client.session_workspace("first").should_not be_nil
    transport.replies["session/close"] = %("error":{"code":-32002,"message":"Already closed"})
    client.session_close("first")
    client.session_workspace("first").should be_nil
    client.session_workspace("second").should_not be_nil
    client.forget_session("second").should be_true
    client.session_workspace("second").should be_nil
  ensure
    client.try(&.close)
  end

  it "keeps the confirmed roots during raw setup and replaces the full set only on success" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"additionalDirectories":{},"resume":{}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"root"})
    client = ACP::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.send_request_raw("session/new", JSON.parse(%({"cwd":"/work","additionalDirectories":["/extra"],"mcpServers":[]})))
    client.session_workspace("root").should eq(ACP::SessionWorkspace.new("/work", ["/extra"]))

    seen = nil
    transport.before_reply = ->(method : String, _request : Hash(String, JSON::Any)) do
      seen = client.session_workspace("root") if method == "session/load"
      nil
    end
    transport.replies["session/load"] = %("error":{"code":-32602,"message":"Rejected"})
    params = JSON.parse(%({"sessionId":"root","cwd":"/work","mcpServers":[]}))
    expect_raises(ACP::JsonRpcError, "Rejected") { client.send_request_raw("session/load", params) }
    seen.should eq(ACP::SessionWorkspace.new("/work", ["/extra"]))
    client.session_workspace("root").should eq(ACP::SessionWorkspace.new("/work", ["/extra"]))

    transport.replies["session/load"] = %("result":{})
    client.send_request_raw("session/load", params)
    seen.should eq(ACP::SessionWorkspace.new("/work", ["/extra"]))
    client.session_workspace("root").should eq(ACP::SessionWorkspace.new("/work", [] of String))

    transport.replies["session/resume"] = %("result":{})
    client.send_request_raw("session/resume", JSON.parse(%({"sessionId":"root","cwd":"/work","additionalDirectories":["/valid",123],"mcpServers":[]})))
    client.session_workspace("root").should be_nil
    client.send_request_raw("session/resume", JSON.parse(%({"sessionId":"root","cwd":"/work","additionalDirectories":null,"mcpServers":[]})))
    client.session_workspace("root").should eq(ACP::SessionWorkspace.new("/work", [] of String))

    transport.replies.delete("session/resume")
    client.request_timeout = 0.01
    expect_raises(ACP::RequestTimeoutError) { client.send_request_raw("session/resume", params) }
    client.session_workspace("root").should be_nil

    client.request_timeout = 2.0
    transport.replies["session/resume"] = %("result":{})
    client.send_request_raw("session/resume", params)
    client.session_workspace("root").should_not be_nil
    client.close
    client.session_workspace("root").should be_nil
  ensure
    client.try(&.close)
  end
  it "records the sent workspace only when a queued request can receive a reply" do
    transport = QueuedChoiceStateTransport.new("session/new")
    transport.replies["initialize"] = %("result":{"protocolVersion":1})
    transport.replies["session/new"] = %("result":{"sessionId":"root"})
    client = ACP::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    params = JSON.parse(%({"cwd":"/original","additionalDirectories":["/extra"],"mcpServers":[]}))
    completed = Channel(JSON::Any | Exception).new(1)
    spawn do
      completed.send(client.send_request_raw("session/new", params))
    rescue ex
      completed.send(ex)
    end

    queued_id = select
    when id = transport.queued.receive
      id
    when timeout(2.seconds)
      fail "session setup did not reach the send queue"
    end
    params.as_h["cwd"] = JSON::Any.new("/edited")
    params["additionalDirectories"].as_a.clear
    transport.inject_raw(%({"jsonrpc":"2.0","id":#{queued_id},"result":{"sessionId":"premature"}}))
    choice_state_barrier(client, transport)
    client.session_workspace("premature").should be_nil
    transport.write.send(nil)

    select
    when result = completed.receive
      result.should eq(JSON.parse(%({"sessionId":"root"})))
    when timeout(2.seconds)
      fail "session setup did not finish"
    end
    request = transport.sent_messages.find! { |message| message["method"]?.try(&.as_s?) == "session/new" }
    request["params"]["cwd"].should eq("/original")
    client.session_workspace("root").should eq(ACP::SessionWorkspace.new("/original", ["/extra"]))
  ensure
    transport.try(&.write.close)
    client.try(&.close)
  end
  it "keeps confirmed roots when stdio setup replies have an invalid JSON-RPC header" do
    with_wide_stdio do |transport, feed, outgoing|
      cursors = ACP::Protocol::ClientSessionCapabilities.new(cursors: ACP::Protocol::SessionCursorsCapabilities.new)
      caps = ACP::Protocol::ClientCapabilities.new(session: cursors)
      client = ACP::Client.new(transport, client_capabilities: caps)
      client.request_timeout = 2.0
      answer_identity_request(feed, outgoing, %({"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"additionalDirectories":{}}}}))
      client.initialize_connection

      spawn do
        new_request = JSON.parse(outgoing.gets.not_nil!)
        feed.puts %({"id":#{new_request["id"]},"result":{"sessionId":"unconfirmed"}})
      end
      expect_raises(ACP::ProtocolError, /Invalid JSON-RPC header/) { client.session_new("/work") }
      client.session_workspace("unconfirmed").should be_nil

      answer_identity_request(feed, outgoing, %({"sessionId":"root"}))
      client.session_new("/work", additional_directories: ["/extra"])
      bad_headers = [%("jsonrpc":"1.0"), %("jsonrpc":"1.0","jsonrpc":"2.0")]
      bad_headers.each do |header|
        spawn do
          load_request = JSON.parse(outgoing.gets.not_nil!)
          feed.puts %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"root","update":{"sessionUpdate":"cursor_update","cursorId":"replayed"}}})
          feed.puts %({#{header},"id":#{load_request["id"]},"result":{}})
        end
        expect_raises(ACP::ProtocolError, /JSON-RPC/) { client.session_load("root", "/work") }
        client.session_workspace("root").should eq(ACP::SessionWorkspace.new("/work", ["/extra"]))
        client.session_cursor("root", "replayed").should be_nil
      end
    ensure
      client.try(&.close)
    end
  end

  it "does not give a malformed raw fork authority over an existing workspace" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"sessionCapabilities":{"fork":{}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"root"})
    transport.replies["session/fork"] = %("result":{"sessionId":"root"})
    client = ACP::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")
    client.send_request_raw("session/fork", JSON.parse(%({"cwd":"/other","mcpServers":[]})))
    client.session_workspace("root").should eq(ACP::SessionWorkspace.new("/work", [] of String))

    transport.replies["session/fork"] = %("result":{"sessionId":"forked"})
    client.session_fork("root", "/forked")
    client.session_workspace("forked").should eq(ACP::SessionWorkspace.new("/forked", [] of String))
  ensure
    client.try(&.close)
  end

  {"close", "forget"}.each do |retirement|
    it "does not restore a retired workspace when an older load replies after #{retirement}" do
      transport = ChoiceStateTransport.new
      transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"close":{}}}})
      transport.replies["session/new"] = %("result":{"sessionId":"root"})
      transport.replies["session/close"] = %("result":{})
      client = ACP::Client.new(transport)
      client.request_timeout = 2.0
      client.initialize_connection
      client.session_new("/work")
      next_answer(transport)
      next_answer(transport)

      completed = Channel(Exception?).new(1)
      spawn do
        client.session_load("root", "/work")
        completed.send(nil)
      rescue ex
        completed.send(ex)
      end
      load = next_answer(transport)
      load["method"].should eq("session/load")
      if retirement == "close"
        client.session_close("root")
      else
        client.forget_session("root").should be_true
      end
      transport.inject_raw(%({"jsonrpc":"2.0","id":#{load["id"]},"result":{}}))

      select
      when error = completed.receive
        error.should be_nil
      when timeout(2.seconds)
        fail "session load did not finish"
      end
      client.session_workspace("root").should be_nil
      client.session_id.should be_nil
    ensure
      client.try(&.close)
    end
  end

  it "retires on a late close reply and preserves a workspace from a newer attachment" do
    transport = PausedReplyTransport.new("permission")
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"close":{},"additionalDirectories":{}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"root"})
    transport.replies["session/load"] = %("result":{})
    client = ACP::Client.new(transport)
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")
    next_answer(transport)
    next_answer(transport)

    permission_started = Channel(Nil).new(1)
    permission_release = Channel(Nil).new(1)
    client.on_agent_request = ->(_method : String, _params : JSON::Any) do
      permission_started.send(nil)
      permission_release.receive?
      JSON.parse(ACP::Protocol::RequestPermissionResult.selected("allow").to_json)
    end
    transport.inject_raw(%({"jsonrpc":"2.0","id":"permission","method":"session/request_permission","params":{"sessionId":"root","toolCall":{"toolCallId":"tool"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"}]}}))
    next_permission_event(permission_started)

    {false, true}.each do |reattach|
      client.request_timeout = 0.01
      expect_raises(ACP::RequestTimeoutError) { client.session_close("root") }
      close = next_answer(transport)
      close["method"].should eq("session/close")
      next_answer(transport)["method"].should eq("$/cancel_request")
      client.session_workspace("root").should_not be_nil

      client.request_timeout = 2.0
      if reattach
        client.session_load("root", "/work", additional_directories: ["/extra"])
        next_answer(transport)
      end
      transport.inject_raw(%({"jsonrpc":"2.0","id":#{close["id"]},"result":{}}))
      next_permission_event(transport.finishing) unless reattach
      choice_state_barrier(client, transport)
      next_answer(transport)
      if reattach
        client.session_workspace("root").should eq(ACP::SessionWorkspace.new("/work", ["/extra"]))
      else
        client.session_workspace("root").should be_nil
        transport.release.send(nil)
        next_answer(transport)["result"]["outcome"]["outcome"].should eq("cancelled")
        client.session_load("root", "/work")
        next_answer(transport)
      end
    end
  ensure
    permission_release.try(&.close)
    transport.try(&.release.close)
    client.try(&.close)
  end
end

private class QueuedTerminalReplyTransport < ChoiceStateTransport
  getter queued = Channel(Nil).new(1)
  getter release = Channel(Nil).new(1)

  def send_checked(message : Hash(String, JSON::Any), &preflight : -> Nil) : Nil
    if message["id"]?.try(&.as_s?) == "queued-create"
      @queued.send(nil)
      @release.receive?
    end
    super(message, &preflight)
  end
end

describe "ACP v1 terminal ownership" do
  it "routes a terminal only to its owning session until release succeeds" do
    with_wide_stdio do |transport, feed, outgoing|
      client = initialized_v1_terminal_client(transport, feed, outgoing)
      called = [] of String
      release_fails = true
      client.on_agent_request = ->(method : String, _params : JSON::Any) do
        called << method
        case method
        when "terminal/create"
          JSON.parse(%({"terminalId":"fixture"}))
        when "terminal/output"
          JSON.parse(%({"output":"captured","truncated":false}))
        when "terminal/wait_for_exit"
          JSON.parse(%({"exitCode":0}))
        when "terminal/release"
          raise ACP::JsonRpcError.new(ACP::JsonRpcError::INTERNAL_ERROR, "Release failed") if release_fails
          JSON.parse("{}")
        else
          JSON.parse("{}")
        end
      end
      call = ->(id : Int32, method : String, session : String) do
        field = method == "terminal/create" ? %("command":"fixture") : %("terminalId":"fixture")
        feed.puts %({"jsonrpc":"2.0","id":#{id},"method":#{method.to_json},"params":{"sessionId":#{session.to_json},#{field}}})
        answer = JSON.parse(outgoing.gets.not_nil!)
        answer["id"].should eq(id)
        answer
      end

      call.call(1, "terminal/output", "owner")["error"]?.try(&.["code"]).should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)
      call.call(2, "terminal/create", "owner")["result"]["terminalId"].should eq("fixture")
      {"terminal/output", "terminal/wait_for_exit", "terminal/kill", "terminal/release"}.each_with_index do |method, i|
        call.call(4 + i, method, "other")["error"]?.try(&.["code"]).should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)
      end
      called.should eq(["terminal/create"])

      call.call(8, "terminal/kill", "owner")["result"].should eq(JSON.parse("{}"))
      call.call(9, "terminal/output", "owner")["result"]["output"].should eq("captured")
      call.call(10, "terminal/wait_for_exit", "owner")["result"]["exitCode"].should eq(0)
      call.call(11, "terminal/release", "owner")["error"]["message"].should eq("Release failed")
      call.call(12, "terminal/output", "owner")["result"]["output"].should eq("captured")
      release_fails = false
      call.call(13, "terminal/release", "owner")["result"].should eq(JSON.parse("{}"))

      total = called.size
      {"terminal/output", "terminal/wait_for_exit", "terminal/kill", "terminal/release"}.each_with_index do |method, i|
        call.call(14 + i, method, "owner")["error"]?.try(&.["code"]).should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)
      end
      called.size.should eq(total)
      call.call(18, "terminal/create", "other")["error"]?.try(&.["code"]).should eq(ACP::JsonRpcError::INTERNAL_ERROR)
      client.forget_session("owner").should be_false
      total = called.size
      call.call(19, "terminal/create", "owner")["error"]?.try(&.["code"]).should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)
      called.size.should eq(total)
    ensure
      client.try(&.close)
    end
  end
  it "publishes only sent creations and detaches generic replies before writing" do
    transport = QueuedTerminalReplyTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1})
    client = ACP::Client.new(transport, client_capabilities: ACP::Protocol::ClientCapabilities.new(terminal: true))
    client.initialize_connection
    next_answer(transport)
    client.on_create_terminal = ->(_params : ACP::Protocol::CreateTerminalParams) do
      ACP::Protocol::CreateTerminalResult.from_json(%({"terminalId":"t","_meta":{"example.test/decimal":0.123456789012345678901}}))
    end
    client.on_terminal_output = ->(_params : ACP::Protocol::TerminalOutputParams) do
      ACP::Protocol::TerminalOutputResult.new("fixture")
    end
    send_create = ->(id : String, session : String) do
      transport.inject_raw(%({"jsonrpc":"2.0","id":#{id.to_json},"method":"terminal/create","params":{"sessionId":#{session.to_json},"command":"fixture"}}))
    end
    send_output = ->(id : Int32) do
      transport.inject_raw(%({"jsonrpc":"2.0","id":#{id},"method":"terminal/output","params":{"sessionId":"s","terminalId":"t"}}))
      next_answer(transport)
    end

    send_create.call("exact", "s")
    next_answer(transport)["error"]["code"].should eq(ACP::JsonRpcError::INTERNAL_ERROR)
    send_output.call(1)["error"]["code"].should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)

    client.on_create_terminal = nil
    generic_reply = JSON.parse(%({"terminalId":"t"}))
    client.on_agent_request = ->(_method : String, _params : JSON::Any) { generic_reply }
    send_create.call("queued-create", "s")
    next_permission_event(transport.queued)
    generic_reply.as_h["terminalId"] = JSON::Any.new("edited")
    send_output.call(2)["error"]["code"].should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)
    transport.release.send(nil)
    next_answer(transport)["result"]["terminalId"].should eq("t")
    send_output.call(3)["result"]["output"].should eq("fixture")
    generic_reply.as_h["terminalId"] = JSON::Any.new("t")
    generic_reply.as_h["_meta"] = JSON::Any.new({"example.test/value" => JSON::Any.new(Float64::NAN)})
    send_create.call("duplicate", "other")
    next_answer(transport)["error"]["code"].should eq(ACP::JsonRpcError::INTERNAL_ERROR)
    send_output.call(4)["error"]["code"].should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)

    generic_reply.as_h.delete("_meta")
    generic_reply.as_h["terminalId"] = JSON::Any.new("queued-collision")
    send_create.call("queued-create", "s")
    next_permission_event(transport.queued)
    send_create.call("second-create", "other")
    next_answer(transport)["error"]["code"].should eq(ACP::JsonRpcError::INTERNAL_ERROR)
    transport.release.send(nil)
    obsolete = next_answer(transport)
    obsolete["id"].should eq("queued-create")
    obsolete["error"]["code"].should eq(ACP::JsonRpcError::INTERNAL_ERROR)
  ensure
    transport.try(&.release.close)
    client.try(&.close)
  end

  {"typed", "generic"}.each do |kind|
    it "keeps a completed #{kind} release retired when its reply cannot be encoded" do
      with_wide_stdio do |transport, feed, outgoing|
        client = initialized_v1_terminal_client(transport, feed, outgoing)
        client.on_create_terminal = ->(_params : ACP::Protocol::CreateTerminalParams) do
          ACP::Protocol::CreateTerminalResult.new("t")
        end
        client.on_terminal_output = ->(_params : ACP::Protocol::TerminalOutputParams) do
          ACP::Protocol::TerminalOutputResult.new("fixture")
        end
        entered = Channel(Nil).new(1)
        finish = Channel(Nil).new(1)
        if kind == "typed"
          client.on_release_terminal = ->(_params : ACP::Protocol::ReleaseTerminalParams) do
            entered.send(nil)
            finish.receive?
            result = ACP::Protocol::ReleaseTerminalResult.from_json(%({"_meta":{"example.test/value":0}}))
            result.meta.not_nil!["example.test/value"] = JSON::Any.new(Float64::NAN)
            result
          end
        else
          client.on_agent_request = ->(_method : String, _params : JSON::Any) do
            entered.send(nil)
            finish.receive?
            JSON::Any.new({"_meta" => JSON::Any.new({"example.test/value" => JSON::Any.new(Float64::NAN)})})
          end
        end
        call = ->(id : Int32, method : String, field : String) do
          feed.puts %({"jsonrpc":"2.0","id":#{id},"method":#{method.to_json},"params":{"sessionId":"s",#{field}}})
        end
        terminal = %("terminalId":"t")

        call.call(1, "terminal/create", %("command":"fixture"))
        JSON.parse(outgoing.gets.not_nil!)["result"]["terminalId"].should eq("t")
        call.call(2, "terminal/release", terminal)
        next_permission_event(entered)
        call.call(3, "terminal/release", terminal)
        JSON.parse(outgoing.gets.not_nil!)["error"]["code"].should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)
        call.call(4, "terminal/output", terminal)
        JSON.parse(outgoing.gets.not_nil!)["error"]["code"].should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)
        finish.send(nil)
        JSON.parse(outgoing.gets.not_nil!)["error"]["code"].should eq(ACP::JsonRpcError::INTERNAL_ERROR)
        call.call(5, "terminal/output", terminal)
        JSON.parse(outgoing.gets.not_nil!)["error"]["code"].should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)
      ensure
        finish.try(&.close)
        client.try(&.close)
      end
    end
  end

  it "retires existing and pending terminals when a session closes" do
    transport = ChoiceStateTransport.new
    transport.replies["initialize"] = %("result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"close":{}}}})
    transport.replies["session/new"] = %("result":{"sessionId":"root"})
    transport.replies["session/close"] = %("result":{})
    transport.replies["session/load"] = %("result":{})
    client = ACP::Client.new(transport, client_capabilities: ACP::Protocol::ClientCapabilities.new(terminal: true))
    client.request_timeout = 2.0
    client.initialize_connection
    client.session_new("/work")
    next_answer(transport)
    next_answer(transport)

    entered = Channel(Nil).new(1)
    finish = Channel(Nil).new(1)
    callbacks = [] of String
    client.on_create_terminal = ->(params : ACP::Protocol::CreateTerminalParams) do
      callbacks << params.command
      if params.command == "pending"
        entered.send(nil)
        finish.receive?
      end
      ACP::Protocol::CreateTerminalResult.new(params.command)
    end
    client.on_terminal_output = ->(_params : ACP::Protocol::TerminalOutputParams) do
      ACP::Protocol::TerminalOutputResult.new("fixture")
    end
    create = ->(id : Int32, command : String) do
      transport.inject_raw(%({"jsonrpc":"2.0","id":#{id},"method":"terminal/create","params":{"sessionId":"root","command":#{command.to_json}}}))
    end
    output = ->(id : Int32, terminal : String) do
      transport.inject_raw(%({"jsonrpc":"2.0","id":#{id},"method":"terminal/output","params":{"sessionId":"root","terminalId":#{terminal.to_json}}}))
      next_answer(transport)
    end

    create.call(21, "initial")
    next_answer(transport)["result"]["terminalId"].should eq("initial")
    create.call(22, "pending")
    next_permission_event(entered)

    client.session_close("root")
    next_answer(transport)["method"].should eq("session/close")
    output.call(23, "initial")["error"]["code"].should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)
    create.call(24, "closed")
    next_answer(transport)["error"]["code"].should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)
    callbacks.should eq(["initial", "pending"])

    client.session_load("root", "/work")
    next_answer(transport)["method"].should eq("session/load")
    create.call(25, "new")
    next_answer(transport)["result"]["terminalId"].should eq("new")
    finish.send(nil)
    pending = next_answer(transport)
    pending["id"].should eq(22)
    pending["error"]["code"].should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)
    output.call(26, "pending")["error"]["code"].should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)
    output.call(27, "new")["result"]["output"].should eq("fixture")

    transport.replies.delete("session/close")
    client.request_timeout = 0.01
    expect_raises(ACP::RequestTimeoutError) { client.session_close("root") }
    close = next_answer(transport)
    close["method"].should eq("session/close")
    next_answer(transport)["method"].should eq("$/cancel_request")
    client.request_timeout = 2.0
    client.session_load("root", "/work")
    next_answer(transport)["method"].should eq("session/load")
    create.call(28, "newest")
    next_answer(transport)["result"]["terminalId"].should eq("newest")

    transport.inject_raw(%({"jsonrpc":"2.0","id":#{close["id"]},"result":{}}))
    choice_state_barrier(client, transport)
    next_answer(transport)
    output.call(29, "new")["error"]["code"].should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)
    output.call(30, "newest")["result"]["output"].should eq("fixture")
    client.forget_session("root").should be_true
    output.call(31, "newest")["error"]["code"].should eq(ACP::JsonRpcError::RESOURCE_NOT_FOUND)
  ensure
    finish.try(&.close)
    client.try(&.close)
  end
end

describe "ACP v1 terminal output byte limits" do
  it "keeps a valid UTF-8 suffix and preserves exact typed reply metadata" do
    with_wide_stdio do |transport, feed, outgoing|
      client = initialized_v1_terminal_client(transport, feed, outgoing)
      client.on_create_terminal = ->(params : ACP::Protocol::CreateTerminalParams) do
        ACP::Protocol::CreateTerminalResult.new(params.command)
      end
      text = "a한🙂\n"
      current_output = text
      handler_truncated = false
      metadata = %({"example.test/wide":18446744073709551615,"example.test/fraction":0.123456789012345678901})
      client.on_terminal_output = ->(_params : ACP::Protocol::TerminalOutputParams) do
        result = ACP::Protocol::TerminalOutputResult.from_json(%({"output":"","truncated":false,"exitStatus":{"exitCode":1,"_meta":#{metadata}},"_meta":#{metadata}}))
        result.output = current_output
        result.truncated = handler_truncated
        result
      end

      cases = {
        {nil, text, false, text, false},
        {9_u64, text, false, text, false},
        {8_u64, text, false, "한🙂\n", true},
        {7_u64, text, false, "🙂\n", true},
        {4_u64, text, false, "\n", true},
        {3_u64, "🙂", false, "", true},
        {0_u64, text, false, "", true},
        {0_u64, "", false, "", false},
        {UInt64::MAX, text, true, text, true},
        {3_u64, String.new(Bytes[0xff, 0x61]), false, "a", true},
      }
      cases.each_with_index do |(limit, captured, already_truncated, expected, truncated), index|
        terminal = "term-#{index}"
        current_output = captured
        handler_truncated = already_truncated
        limit_field = limit ? %(,"outputByteLimit":#{limit}) : ""
        feed.puts %({"jsonrpc":"2.0","id":"create","method":"terminal/create","params":{"sessionId":"s","command":#{terminal.to_json}#{limit_field}}})
        JSON.parse(outgoing.gets.not_nil!)["result"]["terminalId"].should eq(terminal)
        feed.puts %({"jsonrpc":"2.0","id":"output","method":"terminal/output","params":{"sessionId":"s","terminalId":#{terminal.to_json}}})
        result = ACP::Protocol::RawJson.from_json(outgoing.gets.not_nil!).field("result").not_nil!
        result.field("output").not_nil!.as_s?.should eq(expected)
        result.field("truncated").not_nil!.json.should eq(truncated.to_json)
        result.field("_meta").not_nil!.json.should eq(metadata)
        status = result.field("exitStatus").not_nil!
        status.field("exitCode").not_nil!.as_i64?.should eq(1)
        status.field("_meta").not_nil!.json.should eq(metadata)
      end
    ensure
      client.try(&.close)
    end
  end

  it "uses the negotiated limit for the generic callback without editing its result" do
    with_wide_stdio do |transport, feed, outgoing|
      client = initialized_v1_terminal_client(transport, feed, outgoing)
      original = JSON.parse(%({"output":"a한🙂","truncated":false,"example.test/extra":[1,true]}))
      reply = original
      client.on_agent_request = ->(method : String, params : JSON::Any) do
        if method == "terminal/create"
          params.as_h["outputByteLimit"] = JSON::Any.new(99_i64)
          JSON.parse(%({"terminalId":"fixture"}))
        else
          reply
        end
      end
      feed.puts %({"jsonrpc":"2.0","id":1,"method":"terminal/create","params":{"sessionId":"s","command":"fixture","outputByteLimit":6}})
      JSON.parse(outgoing.gets.not_nil!)["result"]["terminalId"].should eq("fixture")

      request = %({"jsonrpc":"2.0","id":2,"method":"terminal/output","params":{"sessionId":"s","terminalId":"fixture"}})
      feed.puts request
      result = JSON.parse(outgoing.gets.not_nil!)["result"]
      result.should eq(JSON.parse(%({"output":"🙂","truncated":true,"example.test/extra":[1,true]})))
      original.should eq(JSON.parse(%({"output":"a한🙂","truncated":false,"example.test/extra":[1,true]})))

      reply = JSON.parse(%({"output":"a한🙂","truncated":"invalid"}))
      feed.puts request
      JSON.parse(outgoing.gets.not_nil!)["error"]["code"].should eq(ACP::JsonRpcError::INTERNAL_ERROR)
    ensure
      client.try(&.close)
    end
  end
end

describe "ACP v1 terminal output truncation history" do
  {"typed", "generic"}.each do |kind|
    it "preserves confirmed truncation on later #{kind} output for the same terminal" do
      with_wide_stdio do |transport, feed, outgoing|
        client = initialized_v1_terminal_client(transport, feed, outgoing)
        client.on_create_terminal = ->(params : ACP::Protocol::CreateTerminalParams) do
          ACP::Protocol::CreateTerminalResult.new(params.command)
        end
        captured = ""
        reported = false
        invalid_metadata = ""
        nested_metadata = %({"example.test/nested":#{"[" * 510}1#{"]" * 510}})
        if kind == "typed"
          client.on_terminal_output = ->(_params : ACP::Protocol::TerminalOutputParams) do
            result = ACP::Protocol::TerminalOutputResult.new(captured, truncated: reported)
            case invalid_metadata
            when "nan"
              result.meta = {"example.test/value" => JSON::Any.new(0)}
              result.meta.not_nil!["example.test/value"] = JSON::Any.new(Float64::NAN)
            when "nesting"
              result.meta_raw = ACP::Protocol::RawJson.from_json(nested_metadata)
            end
            result
          end
        else
          client.on_agent_request = ->(_method : String, _params : JSON::Any) do
            fields = {"output" => JSON::Any.new(captured), "truncated" => JSON::Any.new(reported)}
            case invalid_metadata
            when "nan"
              fields["_meta"] = JSON::Any.new({"example.test/value" => JSON::Any.new(Float64::NAN)})
            when "nesting"
              fields["_meta"] = JSON.parse(nested_metadata)
            end
            JSON::Any.new(fields)
          end
        end
        create = ->(name : String, limit : UInt64?) do
          limit_field = limit ? %(,"outputByteLimit":#{limit}) : ""
          feed.puts %({"jsonrpc":"2.0","id":"create","method":"terminal/create","params":{"sessionId":"s","command":#{name.to_json}#{limit_field}}})
          JSON.parse(outgoing.gets.not_nil!)["result"]["terminalId"].should eq(name)
        end
        output = ->(name : String) do
          feed.puts %({"jsonrpc":"2.0","id":"output","method":"terminal/output","params":{"sessionId":"s","terminalId":#{name.to_json}}})
          JSON.parse(outgoing.gets.not_nil!)
        end
        create.call("limited", 4_u64)
        create.call("reported", nil)
        create.call("independent", 4_u64)

        {"nan", "nesting"}.each do |failure|
          captured = "한🙂"
          invalid_metadata = failure
          output.call("limited")["error"]?.try(&.["code"]).should eq(ACP::JsonRpcError::INTERNAL_ERROR)
          invalid_metadata = ""
          captured = "a"
          output.call("limited")["result"]["truncated"].should eq(false)
        end

        captured = "한🙂"
        output.call("limited")["result"].should eq(JSON.parse(%({"output":"🙂","truncated":true})))
        captured = "z"
        output.call("limited")["result"].should eq(JSON.parse(%({"output":"z","truncated":true})))
        output.call("independent")["result"]["truncated"].should eq(false)

        reported = true
        output.call("reported")["result"]["truncated"].should eq(true)
        reported = false
        output.call("reported")["result"]["truncated"].should eq(true)
      ensure
        client.try(&.close)
      end
    end
  end
end

describe "ACP example terminal display" do
  it "escapes C0, DEL, and C1 controls while preserving Unicode and intentional layout" do
    input = "한👩‍💻\n\t\u0007\u000d\u001b\u007f\u0085\u009b"
    ExampleTerminal.text(input, multiline: true).should eq("한👩‍💻\n\t\\u{7}\\u{d}\\u{1b}\\u{7f}\\u{85}\\u{9b}")
    ExampleTerminal.text(input).should eq("한👩‍💻\\u{a}\\u{9}\\u{7}\\u{d}\\u{1b}\\u{7f}\\u{85}\\u{9b}")
  end

  it "filters stderr controls and preserves UTF-8 across arbitrary write boundaries" do
    output = IO::Memory.new
    stream = ExampleTerminal::Stream.new(output)
    payload = "한\u009b🙂\u0007\n"
    payload.to_slice.each { |byte| stream.write(Bytes[byte]) }
    output.to_s.should eq("한\\u{9b}🙂\\u{7}\n")

    incomplete = Bytes[0xf0, 0x9f]
    stream.write(incomplete)
    output.to_s.should eq("한\\u{9b}🙂\\u{7}\n")
    stream.finish
    output.to_s.should eq("한\\u{9b}🙂\\u{7}\n#{String.new(incomplete).scrub}")
  end

  it "filters control characters in the formatted log message and exception" do
    output = IO::Memory.new
    backend = ExampleTerminal.log_backend(output)
    entry = Log::Entry.new("fixture", Log::Severity::Warn, "warning\u007f", Log::Metadata.empty, Exception.new("detail\u0007"))
    backend.write(entry)

    output.to_s.should contain("warning\\u{7f}")
    output.to_s.should contain("detail\\u{7}")
    output.to_s.should_not contain('\u007f')
    output.to_s.should_not contain('\u0007')
  end

  it "keeps permission display escapes distinct from literal backslashes" do
    literal = %q(allow\u{7})
    control = "allow\u0007"
    ExampleTerminal.text(literal, escape_backslashes: true).should eq(%q(allow\\u{7}))
    ExampleTerminal.text(control, escape_backslashes: true).should eq(%q(allow\u{7}))
    ExampleTerminal.text("a\u061cb\u202ec\u2066d\u2028e").should eq(%q(a\u{61c}b\u{202e}c\u{2066}d\u{2028}e))
  end

  it "serializes styled lines with diagnostics that use the same display" do
    output = YieldingIO.new
    styled = "fixture".colorize(:cyan).toggle(true)
    expected_line = "#{styled}\n"
    stream = ExampleTerminal::Stream.new(output)
    done = Channel(Nil).new(2)

    spawn do
      ExampleTerminal.puts(output, styled)
      done.send(nil)
    end
    spawn do
      stream.write("diagnostic\u0007\n".to_slice)
      done.send(nil)
    end
    2.times { next_permission_event(done) }

    diagnostic = "diagnostic\\u{7}\n"
    output.sink.to_s.in?(expected_line + diagnostic, diagnostic + expected_line).should be_true
  end

  it "drains final diagnostics when a short-lived child has exited" do
    output = IO::Memory.new
    agent = ExampleTerminal::Agent.new("/bin/sh", ["-c", "printf '%s' \"$1\" >&2; printf '\\360\\237' >&2", "fixture", "final 한\u0007"], stderr: output)
    agent.transport.close
    agent.wait.not_nil!.success?.should be_true
    output.to_s.should eq("final 한\\u{7}#{String.new(Bytes[0xf0, 0x9f]).scrub}")
  ensure
    agent.try(&.transport.close)
  end
end
