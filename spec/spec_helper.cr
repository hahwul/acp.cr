require "spec"
require "../src/acp"

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

  # Handler fibers send concurrently; under -Dpreview_mt an unguarded
  # Array#<< can lose a frame.
  @send_mutex = Mutex.new

  def send(message : Hash(String, JSON::Any)) : Nil
    raise ACP::ConnectionClosedError.new if @closed
    frame = JSON.parse(message.to_json)
    @send_mutex.synchronize { @sent_messages << frame }
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
def build_init_response(id : Int64, protocol_version : UInt16 = 1_u16, *, session_capabilities : String? = nil) : String
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
          }#{session_capabilities ? %(,"sessionCapabilities":#{session_capabilities}) : ""}
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
