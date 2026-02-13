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
