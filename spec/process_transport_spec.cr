require "./spec_helper"

describe ACP::ProcessTransport do
  # Use `cat` as a simple echo server for JSON-RPC messages.
  # Since `cat` echoes input to output, whatever JSON line we send
  # will be echoed back, allowing us to test the transport loop.
  it "spawns a process and communicates via stdio" do
    transport = ACP::ProcessTransport.new("cat")

    msg = Hash(String, JSON::Any).new
    msg["test"] = JSON::Any.new("hello")
    transport.send(msg)

    response = transport.receive
    response.should_not be_nil
    response.as(JSON::Any)["test"].as_s.should eq("hello")

    transport.close

    # Wait for process to terminate
    # We poll briefly
    terminated = false
    10.times do
      if transport.terminated?
        terminated = true
        break
      end
      sleep 50.milliseconds
    end
    terminated.should be_true
  end

  it "terminates the process on close" do
    transport = ACP::ProcessTransport.new("cat")
    transport.closed?.should be_false
    transport.terminated?.should be_false

    transport.close
    transport.closed?.should be_true

    # Give it a moment to terminate gracefully
    sleep 100.milliseconds
    transport.terminated?.should be_true
  end

  it "handles environment variables" do
    # Use sh to echo a JSON object containing the environment variable.
    # Command passed to sh -c: echo "{\"env\": \"$TEST_VAR\"}"
    # This allows shell expansion of $TEST_VAR inside double quotes.
    cmd = "echo \"{\\\"env\\\": \\\"$TEST_VAR\\\"}\""

    env = {"TEST_VAR" => "success"}
    transport = ACP::ProcessTransport.new("sh", ["-c", cmd], env: env)

    response = transport.receive
    response.should_not be_nil
    response.as(JSON::Any)["env"].as_s.should eq("success")

    transport.close
  end

  it "sets working directory" do
    # Create a temporary directory for the test
    test_dir = File.join(Dir.tempdir, "acp_test_#{Random.new.hex(4)}")
    Dir.mkdir(test_dir)

    begin
      # Command passed to sh -c: echo "{\"cwd\": \"$(pwd)\"}"
      # This allows shell expansion of $(pwd).
      cmd = "echo \"{\\\"cwd\\\": \\\"$(pwd)\\\"}\""

      transport = ACP::ProcessTransport.new("sh", ["-c", cmd], chdir: test_dir)

      response = transport.receive
      response.should_not be_nil

      cwd = response.as(JSON::Any)["cwd"].as_s

      # Resolve symlinks for comparison (e.g. /tmp -> /private/tmp on macOS)
      # Note: File.realpath might raise if path doesn't exist, but we just created it.
      real_cwd = File.realpath(cwd)
      real_test_dir = File.realpath(test_dir)

      real_cwd.should eq(real_test_dir)

      transport.close
    ensure
      Dir.delete(test_dir) if Dir.exists?(test_dir)
    end
  end
end

# R31: a command that can't be started raised File::NotFoundError, which is
# not an ACP::Error; the error guide rescues `ACP::TransportError` here.
describe "ACP::ProcessTransport spawn failures" do
  it "raises TransportError for a missing command" do
    ex = expect_raises(ACP::TransportError, /Failed to start agent: .*acp-no-such-agent-r31/) do
      ACP::ProcessTransport.new("acp-no-such-agent-r31")
    end
    ex.cause.should be_a(File::NotFoundError)
  end

  it "raises TransportError for a missing working directory" do
    expect_raises(ACP::TransportError) do
      ACP::ProcessTransport.new("cat", chdir: "/nonexistent-acp-r31-dir")
    end
  end

  it "raises TransportError for an argument with a NUL byte" do
    expect_raises(ACP::TransportError) { ACP::ProcessTransport.new("cat", ["a\0b"]) }
  end

  it "raises TransportError from ACP.connect" do
    expect_raises(ACP::TransportError) { ACP.connect("acp-no-such-agent-r31") }
  end
end

describe "ACP terminal authentication" do
  it "uses the configured invocation and reconnects after an approved login" do
    directory = File.join(Dir.tempdir, "acp-terminal-auth-#{Random::Secure.hex(8)}")
    Dir.mkdir(directory)
    script = File.join(directory, "agent.sh")
    marker = File.join(directory, "authorized")
    File.write(script, <<-'SH')
      #!/bin/sh
      [ "$1" = "base argument" ] || exit 4
      case "$2" in
        --login)
          [ "$3" = "two words" ] && [ "$ACP_SPEC_LOGIN" = "interactive" ] || exit 5
          printf approved > authorized
          exit 0
          ;;
        --fail)
          exit 6
          ;;
      esac
      [ "$ACP_SPEC_LOGIN" = "base" ] || exit 7
      while IFS= read -r wire; do
        case "$wire" in
          *'"method":"initialize"'*)
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"authMethods":[{"type":"terminal","id":"login","name":"Terminal login","args":["--login","two words"],"env":{"ACP_SPEC_LOGIN":"interactive"}},{"type":"terminal","id":"fail","name":"Fail","args":["--fail"]}]}}'
            ;;
          *'"method":"session/new"'*)
            [ -f authorized ] || exit 8
            printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"logged-in"}}'
            ;;
        esac
      done
      SH

    caps = ACP::Protocol::ClientCapabilities.new(auth: ACP::Protocol::ClientAuthCapabilities.new(terminal: true))
    client = ACP.connect("/bin/sh", [script, "base argument"], env: {"ACP_SPEC_LOGIN" => "base"}, chdir: directory, capabilities: caps)
    client.request_timeout = 2.0
    notification_handler = ->(_method : String, _params : JSON::Any?) { nil }
    client.on_notification = notification_handler

    expect_raises(ACP::AuthenticationError, /declined/) { client.authenticate_terminal("login") { false } }
    File.exists?(marker).should be_false
    expect_raises(ACP::AuthenticationError, /unsuccessfully/) { client.authenticate_terminal("fail") { true } }
    File.exists?(marker).should be_false
    client.closed?.should be_false

    replacement = client.authenticate_terminal("login") do |method|
      method.args.should eq(["--login", "two words"])
      method.env.should eq({"ACP_SPEC_LOGIN" => "interactive"})
      true
    end
    File.read(marker).should eq("approved")
    client.closed?.should be_true
    replacement.request_timeout.should eq(2.0)
    replacement.on_notification.should eq(notification_handler)
    replacement.session_new(directory).session_id.should eq("logged-in")
  ensure
    replacement.try(&.close)
    client.try(&.close)
    File.delete(marker) if marker && File.exists?(marker)
    File.delete(script) if script && File.exists?(script)
    Dir.delete(directory) if directory && Dir.exists?(directory)
  end
end
