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

    transport.last_sent.not_nil!["method"].as_s.should eq("_vendor/ping")

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
        begin
          results.send(transport.wait)
        rescue ex
          results.send(ex)
        end
      end
    end

    statuses = Array(Process::Status | Exception).new(4) { results.receive }
    statuses.each(&.should be_a(Process::Status))
    statuses.uniq.size.should eq(1)
  end
end
