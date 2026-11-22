require "log"
require "../src/acp"

# Display helpers for example clients that write agent data to a terminal.
module ExampleTerminal
  private OUTPUT_MUTEX = Mutex.new

  # Renders terminal control characters as visible escapes.
  def self.text(value : String?, *, multiline : Bool = false, escape_backslashes : Bool = false) : String
    return "" unless value

    String.build do |output|
      value.each_char do |char|
        code = char.ord
        if multiline && (char == '\n' || char == '\t')
          output << char
        elsif escape_backslashes && char == '\\'
          output << "\\\\"
        elsif char.ascii_control? || (0x80 <= code <= 0x9f) || directional_control?(code) ||
              (!multiline && (code == 0x2028 || code == 0x2029))
          output << "\\u{" << code.to_s(16) << '}'
        else
          output << char
        end
      end
    end
  end

  private def self.directional_control?(code : Int32) : Bool
    code.in?(0x061c, 0x200e, 0x200f) || (0x202a <= code <= 0x202e) || (0x2066 <= code <= 0x206f)
  end

  # Serializes complete terminal writes, including locally generated styling.
  def self.print(io : IO, value) : Nil
    OUTPUT_MUTEX.synchronize do
      io.print(value.to_s)
      io.flush
    end
  end

  # Writes a line through the same display lock as streamed text and diagnostics.
  def self.puts(io : IO, value = "") : Nil
    OUTPUT_MUTEX.synchronize do
      io.puts(value.to_s)
      io.flush
    end
  end

  # Formats log entries as visible text before writing to the display.
  def self.log_backend(output : IO = STDOUT) : ::Log::IOBackend
    DisplayLogBackend.new(io: output)
  end

  private class DisplayLogBackend < ::Log::IOBackend
    def write(entry : ::Log::Entry) : Nil
      line = String.build { |buffer| formatter.format(entry, buffer) }
      ExampleTerminal.puts(io, ExampleTerminal.text(line, multiline: true))
    end
  end

  # Owns the process and drains its filtered diagnostics at exit.
  class Agent
    getter transport : ACP::ProcessTransport

    # A descendant can keep the stderr pipe open after the agent exits.
    private DRAIN_GRACE = 1.second

    @waiting = Atomic(Bool).new(false)
    @finished = Channel(Nil).new
    @exit_status : Process::Status?

    def initialize(command : String, args : Array(String), *, chdir : String? = nil, stderr : IO = STDERR)
      @diagnostics = Stream.new(stderr)
      @transport = ACP::ProcessTransport.new(command, args: args, chdir: chdir, stderr: @diagnostics)
      at_exit do
        @transport.close
        wait unless @waiting.get
      end
    end

    # Waits for remaining diagnostics after the client closes its transport.
    def wait : Process::Status?
      if @waiting.compare_and_set(false, true)[1]
        spawn(name: "acp-example-agent-stderr") do
          @exit_status = @transport.wait
          @diagnostics.finish
        rescue ACP::TransportError | IO::Error
          # The display may already be closed during shutdown.
        ensure
          @finished.close
        end
      end

      select
      when @finished.receive?
        @exit_status
      when timeout(DRAIN_GRACE)
        nil
      end
    end
  end

  # Filters byte streams while preserving characters split across writes.
  class Stream < IO
    @pending = Bytes.empty

    def initialize(@output : IO)
    end

    def read(slice : Bytes) : Int32
      raise IO::Error.new("Terminal display stream is write-only")
    end

    def write(slice : Bytes) : Nil
      bytes = slice
      unless @pending.empty?
        bytes = Bytes.new(@pending.size + slice.size)
        @pending.copy_to(bytes)
        slice.copy_to(bytes + @pending.size)
      end

      tail_size = incomplete_utf8_tail(bytes)
      full_size = bytes.size - tail_size
      @pending = tail_size == 0 ? Bytes.empty : bytes[full_size, tail_size].dup
      display(bytes[0, full_size])
    end

    # Displays any incomplete UTF-8 at EOF as replacement characters.
    def finish : Nil
      display(@pending)
      @pending = Bytes.empty
    end

    private def display(bytes : Bytes) : Nil
      return if bytes.empty?

      ExampleTerminal.print(@output, ExampleTerminal.text(String.new(bytes), multiline: true))
    end

    # A partial character can leave at most three bytes at the end.
    private def incomplete_utf8_tail(bytes : Bytes) : Int32
      start = bytes.size - 1
      while start >= 0 && bytes.size - start < 4 && (bytes[start] & 0xc0_u8) == 0x80_u8
        start -= 1
      end
      return 0 if start < 0

      width = case bytes[start]
              when 0xc2..0xdf then 2
              when 0xe0..0xef then 3
              when 0xf0..0xf4 then 4
              else                 0
              end
      available = bytes.size - start
      available < width ? available : 0
    end
  end
end
