require "./spec_helper"

# ═══════════════════════════════════════════════════════════════════════
# Stability Hardening Regression Specs
#
# These guard against TypeCastError / raw crashes on malformed input.
# Each example fails before the corresponding hardening fix and passes
# after it.
# ═══════════════════════════════════════════════════════════════════════

# ─── F1: ChunkContentHelper#text with a non-string "text" value ─────────
describe "ChunkContentHelper#text (malformed text value)" do
  it "does not raise TypeCastError when 'text' is a number" do
    update = ACP::Protocol::AgentMessageChunkUpdate.new(JSON.parse(%({"text": 123})))
    # Falls back to the JSON serialization of the content instead of crashing.
    update.text.should eq(%({"text":123}))
  end

  it "does not raise TypeCastError when 'text' is an array" do
    update = ACP::Protocol::AgentMessageChunkUpdate.new(JSON.parse(%({"text": [1, 2]})))
    update.text.should eq(%({"text":[1,2]}))
  end

  it "still returns the string when 'text' is a string" do
    update = ACP::Protocol::AgentMessageChunkUpdate.new(JSON.parse(%({"text": "hello"})))
    update.text.should eq("hello")
  end
end

# ─── F2: McpServerParser.from_json_any with non-object input ────────────
describe "ACP::Protocol::McpServerParser.from_json_any (non-object input)" do
  it "does not raise TypeCastError for an array JSON value" do
    value = JSON.parse("[1, 2, 3]")
    expect_raises(JSON::ParseException) do
      ACP::Protocol::McpServerParser.from_json_any(value)
    end
  end

  it "does not raise TypeCastError for a scalar JSON value" do
    value = JSON.parse("42")
    expect_raises(JSON::ParseException) do
      ACP::Protocol::McpServerParser.from_json_any(value)
    end
  end

  it "still parses a valid stdio server object" do
    value = JSON.parse(%({"name": "test", "command": "/bin/test"}))
    server = ACP::Protocol::McpServerParser.from_json_any(value)
    server.should be_a(ACP::Protocol::McpServerStdio)
    server.as(ACP::Protocol::McpServerStdio).name.should eq("test")
  end
end

# ─── F3: McpServerParser.array_from_json with non-array input ───────────
describe "ACP::Protocol::McpServerParser.array_from_json (non-array input)" do
  it "returns an empty array for a scalar JSON value instead of raising" do
    result = ACP::Protocol::McpServerParser.array_from_json(JSON.parse("42"))
    result.should be_a(Array(ACP::Protocol::McpServer))
    result.should be_empty
  end

  it "returns an empty array for an object JSON value instead of raising" do
    result = ACP::Protocol::McpServerParser.array_from_json(JSON.parse(%({"name": "x"})))
    result.should be_empty
  end

  it "still parses a valid array of servers" do
    value = JSON.parse(%([{"name": "a", "command": "/bin/a"}, {"name": "b", "command": "/bin/b"}]))
    result = ACP::Protocol::McpServerParser.array_from_json(value)
    result.size.should eq(2)
    result.map(&.as(ACP::Protocol::McpServerStdio).name).should eq(["a", "b"])
  end
end
