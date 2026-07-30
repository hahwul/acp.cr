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
