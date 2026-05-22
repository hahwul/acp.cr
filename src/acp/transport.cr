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
    # Hard cap on the size of a single incoming JSON-RPC line. ACP messages
    # are typically a few KiB; 16 MiB is generous enough for an unusually
    # large ContentBlock (e.g. embedded image data) while preventing a
    # runaway / malicious agent from OOM-ing the client by streaming an
    # unbounded line.
    DEFAULT_MAX_LINE_BYTES = 16 * 1024 * 1024

    # JSON-RPC method names whose `params` are treated as sensitive. The
    # transport redacts these from DEBUG-level frame logs so a session
    # with debug logging enabled does not write credentials/tokens to log
    # files. Add to this set if new methods carry secrets.
    SENSITIVE_METHODS = Set{"authenticate"}

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
    # - `max_line_bytes` — abort and log a warning if a single incoming
    #   line exceeds this many bytes. Default 16 MiB.
    def initialize(
      @reader : IO,
      @writer : IO,
      buffer_size : Int32 = 256,
      @max_line_bytes : Int32 = DEFAULT_MAX_LINE_BYTES,
    )
      @incoming = Channel(JSON::Any?).new(buffer_size)
      start_reader
    end

    # Sends a JSON-RPC message over the transport. The message is
    # serialized as a single line of JSON followed by a newline.
    def send(message : Hash(String, JSON::Any)) : Nil
      raise ConnectionClosedError.new if @closed

      json_line = message.to_json
      Log.debug { ">>> #{redact_frame(message)}" }

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

    # Returns the JSON string to print at DEBUG level for an outgoing
    # message. If the method is in `SENSITIVE_METHODS`, the `params`
    # field is replaced with "[REDACTED]" so credentials don't end up
    # in log files. Errors fall back to a constant string.
    private def redact_frame(message : Hash(String, JSON::Any)) : String
      method = message["method"]?.try(&.as_s?)
      return message.to_json unless method && SENSITIVE_METHODS.includes?(method)

      sanitized = message.dup
      sanitized["params"] = JSON::Any.new("[REDACTED]") if sanitized.has_key?("params")
      sanitized.to_json
    rescue
      %({"method":"#{method}","params":"[REDACTED]"})
    end

    # Same as `redact_frame` but operates on a raw incoming JSON string
    # whose method is the request being responded to or notified. We
    # only redact when the line is parseable AND its method is
    # sensitive; otherwise pass through the original line.
    private def redact_raw_frame(line : String) : String
      parsed = JSON.parse(line).as_h?
      return line unless parsed
      method = parsed["method"]?.try(&.as_s?)
      return line unless method && SENSITIVE_METHODS.includes?(method)

      parsed["params"] = JSON::Any.new("[REDACTED]") if parsed.has_key?("params")
      parsed["result"] = JSON::Any.new("[REDACTED]") if parsed.has_key?("result")
      parsed.to_json
    rescue
      "[REDACTED frame]"
    end

    # Read bytes up to (and including) the next '\n' from `@reader` to
    # re-sync after an oversized line. Returns the number of bytes
    # discarded. A nil return from `gets` (EOF) ends the drain.
    private def drain_oversize_line : Int64
      drained = 0_i64
      while chunk = @reader.gets(@max_line_bytes, chomp: false)
        drained += chunk.bytesize
        break if chunk.ends_with?('\n')
      end
      drained
    end

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
          # gets(limit, chomp: true) reads up to `limit` bytes or until
          # newline, whichever comes first. If the line exceeded the
          # limit, the returned string will not end on a real newline —
          # we detect this by checking the post-truncation byte at the
          # current position and drain the rest of the offending line so
          # we re-sync with the next message boundary.
          line = @reader.gets(@max_line_bytes, chomp: true)
        rescue ex : IO::Error
          Log.error { "Read error: #{ex.message}" }
          break
        end

        # nil from gets means EOF — the agent process closed its stdout.
        if line.nil?
          Log.debug { "Reader reached EOF" }
          break
        end

        # If the line filled the buffer without hitting a newline, the
        # next byte in the stream is non-newline data belonging to the
        # same logical line. Drain to the next '\n' and skip the message.
        if line.bytesize >= @max_line_bytes
          drained = drain_oversize_line
          Log.warn { "Dropped oversized incoming line (>= #{@max_line_bytes} bytes; drained #{drained} more bytes to re-sync)" }
          next
        end

        line = line.strip
        next if line.empty?

        Log.debug { "<<< #{redact_raw_frame(line)}" }

        begin
          parsed = JSON.parse(line)
          @incoming.send(parsed)
        rescue ex : JSON::ParseException
          Log.warn { "Failed to parse incoming JSON: #{ex.message}" }
          # Don't log the raw line at any level — it may be a partially
          # received frame that contains sensitive data.
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

    # Flag to prevent duplicate close/terminate sequences.
    @process_closing : Bool = false

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
      return if @process_closing
      @process_closing = true
      super

      if @process.terminated?
        # Reap the already-terminated process to avoid zombies.
        begin
          @process.wait
        rescue
          # Already reaped.
        end
      else
        # Give the process a moment to exit gracefully, then signal it.
        @process.terminate(graceful: true)

        # Wait briefly for graceful shutdown, then force-kill if needed.
        spawn do
          sleep 2.seconds
          begin
            unless @process.terminated?
              @process.terminate(graceful: false)
            end
          rescue
            # Process may have already exited.
          end
          # Reap the process to avoid zombies.
          begin
            @process.wait unless @process.terminated?
          rescue
            # Process may have already been reaped.
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
