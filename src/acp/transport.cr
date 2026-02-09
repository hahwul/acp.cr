# ACP Transport Layer
#
# Provides the abstraction for sending and receiving JSON-RPC 2.0
# messages over different transport mechanisms. The primary transport
# is newline-delimited JSON over stdio (stdin/stdout of a child process).
#
# Architecture:
#   - `Transport` is the abstract base that defines the interface.
#   - `StdioTransport` implements communication over IO pairs (typically
#     the stdin/stdout of a spawned agent process).
#   - Messages are read/written as single-line JSON terminated by '\n'.
#   - A dedicated reader fiber pushes incoming messages into a Channel,
#     decoupling the read loop from message processing.

require "json"
require "log"

module ACP
  # Logger for transport-level diagnostics.
  Log = ::Log.for("acp.transport")

  # ─── Abstract Transport ───────────────────────────────────────────

  # Abstract base class for all ACP transports. Subclasses must implement
  # the raw read/write operations; the base class provides the JSON
  # parsing/serialization layer on top.
  abstract class Transport
    # Sends a JSON-RPC message (Hash serialized to JSON + newline).
    abstract def send(message : Hash(String, JSON::Any)) : Nil

    # Receives the next incoming JSON message, blocking until one arrives.
    # Returns nil if the transport is closed.
    abstract def receive : JSON::Any?

    # Closes the transport, releasing any underlying resources.
    abstract def close : Nil

    # Returns true if the transport is open and operational.
    abstract def closed? : Bool

    # Convenience: send a JSON::Serializable object that has already
    # been wrapped in the JSON-RPC envelope.
    def send_json(obj : Hash(String, JSON::Any)) : Nil
      send(obj)
    end
  end

  # ─── Stdio Transport ─────────────────────────────────────────────

  # Implements the ACP transport over a pair of IO objects. In the
  # typical case these are the stdin (for writing) and stdout (for
  # reading) of a spawned agent child process.
  #
  # Incoming messages are read in a background fiber and placed into
  # a buffered channel so that `#receive` never blocks the writer.
  #
  # Thread safety: Crystal fibers are cooperatively scheduled on a
  # single thread, so we don't need mutexes — just channels.
  class StdioTransport < Transport
    # The channel that the reader fiber pushes parsed messages into.
    # A nil value signals that the reader has stopped (EOF or error).
    getter incoming : Channel(JSON::Any?)

    # Whether the transport has been closed.
    @closed : Bool = false

    # Mutex-like flag to prevent double-close.
    @close_sent : Bool = false

    # The IO we write outgoing messages to (agent's stdin).
    @writer : IO

    # The IO we read incoming messages from (agent's stdout).
    @reader : IO

    # The background reader fiber.
    @reader_fiber : Fiber? = nil

    # Creates a new stdio transport.
    #
    # - `reader` — the IO to read incoming JSON-RPC messages from
    #   (typically the agent process's stdout).
    # - `writer` — the IO to write outgoing JSON-RPC messages to
    #   (typically the agent process's stdin).
    # - `buffer_size` — how many messages to buffer in the channel
    #   before back-pressuring the reader fiber. Default 256.
    def initialize(@reader : IO, @writer : IO, buffer_size : Int32 = 256)
      @incoming = Channel(JSON::Any?).new(buffer_size)
      start_reader
    end

    # Sends a JSON-RPC message over the transport. The message is
    # serialized as a single line of JSON followed by a newline.
    def send(message : Hash(String, JSON::Any)) : Nil
      raise ConnectionClosedError.new if @closed

      json_line = message.to_json
      Log.debug { ">>> #{json_line}" }

      begin
        @writer.print(json_line)
        @writer.print('\n')
        @writer.flush
      rescue ex : IO::Error
        Log.error { "Write failed: #{ex.message}" }
        @closed = true
        raise ConnectionClosedError.new("Failed to write: #{ex.message}")
      end
    end

    # Receives the next incoming JSON-RPC message. Blocks until a
    # message is available. Returns nil if the transport is closed
    # or the reader encountered EOF.
    def receive : JSON::Any?
      return if @closed

      begin
        msg = @incoming.receive
        if msg.nil?
          # nil sentinel means the reader stopped.
          @closed = true
        end
        msg
      rescue Channel::ClosedError
        @closed = true
        nil
      end
    end

    # Receives with a timeout. Returns nil if no message arrives
    # within the given duration.
    def receive(timeout : Time::Span) : JSON::Any?
      return if @closed

      select
      when msg = @incoming.receive
        if msg.nil?
          @closed = true
        end
        msg
      when timeout(timeout)
        nil
      end
    end

    # Closes the transport, signaling the reader to stop and
    # closing the underlying IO objects.
    def close : Nil
      return if @closed
      @closed = true

      # Send nil sentinel so any blocked receive call unblocks.
      unless @close_sent
        @close_sent = true
        begin
          @incoming.send(nil)
        rescue Channel::ClosedError
          # Already closed, that's fine.
        end
      end

      # Close the incoming channel to unblock any further receives.
      @incoming.close

      # Close the underlying IOs if they support it.
      @writer.close rescue nil
      @reader.close rescue nil
    end

    # Returns true if the transport has been closed.
    def closed? : Bool
      @closed
    end

    # ─── Private ────────────────────────────────────────────────────

    private def start_reader
      @reader_fiber = spawn(name: "acp-transport-reader") do
        read_loop
      end
    end

    # The main read loop running in a background fiber. Reads lines
    # from the reader IO, parses them as JSON, and pushes them into
    # the incoming channel. Sends a nil sentinel on EOF or error.
    private def read_loop
      loop do
        break if @closed

        begin
          line = @reader.gets
        rescue ex : IO::Error
          Log.error { "Read error: #{ex.message}" }
          break
        end

        # nil from gets means EOF — the agent process closed its stdout.
        if line.nil?
          Log.debug { "Reader reached EOF" }
          break
        end

        # Skip blank lines (shouldn't happen, but be defensive).
        line = line.strip
        next if line.empty?

        Log.debug { "<<< #{line}" }

        begin
          parsed = JSON.parse(line)
          @incoming.send(parsed)
        rescue ex : JSON::ParseException
          Log.warn { "Failed to parse incoming JSON: #{ex.message}" }
          Log.debug { "Raw line: #{line}" }
          # Skip malformed messages rather than crashing.
          next
        rescue Channel::ClosedError
          # Channel was closed (transport shutting down).
          break
        end
      end

      # Signal that the reader has stopped.
      unless @close_sent
        @close_sent = true
        begin
          @incoming.send(nil)
        rescue Channel::ClosedError
          # Already closed, fine.
        end
      end
    end
  end

  # ─── Process Transport ──────────────────────────────────────────

  # A convenience wrapper that spawns an agent process and creates
  # a `StdioTransport` connected to its stdin/stdout. The agent's
  # stderr is forwarded to a configurable IO (default: STDERR).
  class ProcessTransport < StdioTransport
    # The underlying child process.
    getter process : Process

    # Spawns an agent process with the given command and arguments,
    # and sets up the stdio transport.
    #
    # - `command` — the agent executable (e.g., "claude-agent").
    # - `args` — command-line arguments for the agent.
    # - `env` — optional environment variables.
    # - `chdir` — optional working directory for the process.
    # - `stderr` — where to send the agent's stderr (default: STDERR).
    # - `buffer_size` — channel buffer size (default: 256).
    def initialize(
      command : String,
      args : Array(String) = [] of String,
      env : Process::Env = nil,
      chdir : String? = nil,
      stderr : IO = STDERR,
      buffer_size : Int32 = 256,
    )
      @process = Process.new(
        command,
        args: args,
        env: env,
        chdir: chdir,
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Pipe,
        error: stderr
      )

      super(@process.output, @process.input, buffer_size)
    end

    # Closes the transport and terminates the agent process if it's
    # still running.
    def close : Nil
      super

      # Give the process a moment to exit gracefully, then signal it.
      unless @process.terminated?
        @process.terminate(graceful: true)

        # Wait briefly for graceful shutdown.
        spawn do
          sleep 2.seconds
          unless @process.terminated?
            @process.terminate(graceful: false)
          end
        end
      end
    end

    # Waits for the agent process to exit and returns its status.
    def wait : Process::Status
      @process.wait
    end

    # Returns true if the agent process has terminated.
    def terminated? : Bool
      @process.terminated?
    end
  end
end
