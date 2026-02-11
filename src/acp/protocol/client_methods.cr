# ACP Protocol — Client Method Types
#
# Defines the typed request and response structures for all client-side
# methods that the agent can invoke. These methods allow the agent to
# interact with the client's environment (file system, terminals).
#
# Client methods are agent-initiated JSON-RPC requests that the client
# must handle. The client advertises support for these methods via
# capabilities during initialization.
#
# Methods defined here:
#   - `fs/read_text_file`    — Read file contents (requires fs.readTextFile)
#   - `fs/write_text_file`   — Write file contents (requires fs.writeTextFile)
#   - `terminal/create`      — Create a new terminal (requires terminal)
#   - `terminal/output`      — Get terminal output and exit status
#   - `terminal/release`     — Release a terminal
#   - `terminal/wait_for_exit` — Wait for terminal command to exit
#   - `terminal/kill`        — Kill terminal command without releasing
#
# Reference: https://agentclientprotocol.com/protocol/file-system
# Reference: https://agentclientprotocol.com/protocol/terminals

require "json"
require "./tool_call_content"

module ACP
  module Protocol
    # ═══════════════════════════════════════════════════════════════════
    # File System Methods
    # ═══════════════════════════════════════════════════════════════════

    # ─── fs/read_text_file ────────────────────────────────────────────
    # Reads content from a text file in the client's file system,
    # including unsaved changes in the editor.
    #
    # Only available if the client advertises the `fs.readTextFile`
    # capability during initialization.
    #
    # See: https://agentclientprotocol.com/protocol/file-system#reading-files

    # Request parameters for `fs/read_text_file`.
    struct ReadTextFileParams
      include JSON::Serializable

      # The session ID for this request (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # Absolute path to the file to read (required).
      property path : String

      # Optional line number to start reading from (1-based).
      property line : Int32?

      # Optional maximum number of lines to read.
      property limit : Int32?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @session_id : String,
        @path : String,
        @line : Int32? = nil,
        @limit : Int32? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Response for `fs/read_text_file`.
    struct ReadTextFileResult
      include JSON::Serializable

      # The file contents (required).
      property content : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@content : String, @meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # ─── fs/write_text_file ───────────────────────────────────────────
    # Writes content to a text file in the client's file system.
    # The client MUST create the file if it doesn't exist.
    #
    # Only available if the client advertises the `fs.writeTextFile`
    # capability during initialization.
    #
    # See: https://agentclientprotocol.com/protocol/file-system#writing-files

    # Request parameters for `fs/write_text_file`.
    struct WriteTextFileParams
      include JSON::Serializable

      # The session ID for this request (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # Absolute path to the file to write (required).
      property path : String

      # The text content to write to the file (required).
      property content : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @session_id : String,
        @path : String,
        @content : String,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Response for `fs/write_text_file`.
    # An empty result on success.
    struct WriteTextFileResult
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # ═══════════════════════════════════════════════════════════════════
    # Terminal Methods
    # ═══════════════════════════════════════════════════════════════════

    # ─── terminal/create ──────────────────────────────────────────────
    # Executes a command in a new terminal. Returns a TerminalId that
    # can be used with other terminal methods.
    #
    # The Agent is responsible for releasing the terminal by using
    # the `terminal/release` method.
    #
    # Only available if the client advertises the `terminal` capability.
    #
    # See: https://agentclientprotocol.com/protocol/terminals#executing-commands

    # Request parameters for `terminal/create`.
    struct CreateTerminalParams
      include JSON::Serializable

      # The session ID for this request (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The command to execute (required).
      property command : String

      # Array of command arguments.
      property args : Array(String)?

      # Environment variables for the command.
      # Each variable has `name` and `value` fields.
      property env : Array(JSON::Any)?

      # Working directory for the command (absolute path).
      property cwd : String?

      # Maximum number of output bytes to retain. Once exceeded,
      # earlier output is truncated to stay within this limit.
      # The Client MUST ensure truncation happens at a character boundary.
      @[JSON::Field(key: "outputByteLimit")]
      property output_byte_limit : Int64?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @session_id : String,
        @command : String,
        @args : Array(String)? = nil,
        @env : Array(JSON::Any)? = nil,
        @cwd : String? = nil,
        @output_byte_limit : Int64? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Response for `terminal/create`.
    struct CreateTerminalResult
      include JSON::Serializable

      # The unique identifier for the created terminal (required).
      @[JSON::Field(key: "terminalId")]
      property terminal_id : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@terminal_id : String, @meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # ─── terminal/output ──────────────────────────────────────────────
    # Gets the terminal output and exit status without waiting for
    # the command to complete.
    #
    # See: https://agentclientprotocol.com/protocol/terminals#getting-output

    # Request parameters for `terminal/output`.
    struct TerminalOutputParams
      include JSON::Serializable

      # The session ID for this request (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The ID of the terminal to get output from (required).
      @[JSON::Field(key: "terminalId")]
      property terminal_id : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @session_id : String,
        @terminal_id : String,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Response for `terminal/output`.
    struct TerminalOutputResult
      include JSON::Serializable

      # The terminal output captured so far (required).
      property output : String

      # Whether the output was truncated due to byte limits (required).
      property? truncated : Bool

      # Exit status if the command has completed. Nil if still running.
      @[JSON::Field(key: "exitStatus")]
      property exit_status : TerminalExitStatus?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @output : String,
        @truncated : Bool = false,
        @exit_status : TerminalExitStatus? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end

      # Returns true if the command has exited.
      def exited? : Bool
        !@exit_status.nil?
      end
    end

    # ─── terminal/release ─────────────────────────────────────────────
    # Releases a terminal. The command is killed if it hasn't exited yet.
    # After release, the TerminalId can no longer be used with other
    # terminal/* methods.
    #
    # See: https://agentclientprotocol.com/protocol/terminals#releasing-terminals

    # Request parameters for `terminal/release`.
    struct ReleaseTerminalParams
      include JSON::Serializable

      # The session ID for this request (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The ID of the terminal to release (required).
      @[JSON::Field(key: "terminalId")]
      property terminal_id : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @session_id : String,
        @terminal_id : String,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Response for `terminal/release`.
    struct ReleaseTerminalResult
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # ─── terminal/wait_for_exit ───────────────────────────────────────
    # Waits for the terminal command to exit and returns its exit status.
    #
    # See: https://agentclientprotocol.com/protocol/terminals#waiting-for-exit

    # Request parameters for `terminal/wait_for_exit`.
    struct WaitForTerminalExitParams
      include JSON::Serializable

      # The session ID for this request (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The ID of the terminal to wait for (required).
      @[JSON::Field(key: "terminalId")]
      property terminal_id : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @session_id : String,
        @terminal_id : String,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Response for `terminal/wait_for_exit`.
    struct WaitForTerminalExitResult
      include JSON::Serializable

      # The process exit code (may be nil if terminated by signal).
      @[JSON::Field(key: "exitCode")]
      property exit_code : Int32?

      # The signal that terminated the process (may be nil if exited normally).
      property signal : String?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @exit_code : Int32? = nil,
        @signal : String? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end

      # Returns true if the command exited successfully (exit code 0).
      def success? : Bool
        @exit_code == 0
      end

      # Returns true if the command was terminated by a signal.
      def signaled? : Bool
        !@signal.nil?
      end
    end

    # ─── terminal/kill ────────────────────────────────────────────────
    # Kills the terminal command without releasing the terminal.
    # The TerminalId remains valid and can be used with other methods.
    # The Agent MUST still call `terminal/release` when done.
    #
    # See: https://agentclientprotocol.com/protocol/terminals#killing-commands

    # Request parameters for `terminal/kill`.
    struct KillTerminalParams
      include JSON::Serializable

      # The session ID for this request (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The ID of the terminal to kill (required).
      @[JSON::Field(key: "terminalId")]
      property terminal_id : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @session_id : String,
        @terminal_id : String,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Response for `terminal/kill`.
    struct KillTerminalResult
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # ─── Agent Method Names ───────────────────────────────────────────
    # Constants for all agent method names (client → agent requests),
    # matching the Rust SDK's `AGENT_METHOD_NAMES`.
    # See: https://agentclientprotocol.com/protocol/overview

    module AgentMethod
      # Connection lifecycle.
      INITIALIZE   = "initialize"
      AUTHENTICATE = "authenticate"

      # Session management.
      SESSION_NEW               = "session/new"
      SESSION_LOAD              = "session/load"
      SESSION_PROMPT            = "session/prompt"
      SESSION_CANCEL            = "session/cancel"
      SESSION_SET_MODE          = "session/set_mode"
      SESSION_SET_CONFIG_OPTION = "session/set_config_option"

      # Session update notification (agent → client).
      SESSION_UPDATE = "session/update"

      # Returns true if the given method name is a known agent method.
      def self.known?(method : String) : Bool
        case method
        when INITIALIZE, AUTHENTICATE,
             SESSION_NEW, SESSION_LOAD, SESSION_PROMPT, SESSION_CANCEL,
             SESSION_SET_MODE, SESSION_SET_CONFIG_OPTION, SESSION_UPDATE
          true
        else
          false
        end
      end

      # Returns true if the given method name is a session method.
      def self.session_method?(method : String) : Bool
        case method
        when SESSION_NEW, SESSION_LOAD, SESSION_PROMPT, SESSION_CANCEL,
             SESSION_SET_MODE, SESSION_SET_CONFIG_OPTION, SESSION_UPDATE
          true
        else
          false
        end
      end
    end

    # ─── Extension Method Helpers ─────────────────────────────────────
    # Extension methods in ACP are prefixed with `_`. These helpers
    # detect and strip the prefix for dispatch.
    # See: https://agentclientprotocol.com/protocol/extensibility

    module ExtensionMethod
      # Extension method prefix as defined by the ACP spec.
      PREFIX = "_"

      # Returns true if the given method name is an extension method.
      def self.extension?(method : String) : Bool
        method.starts_with?(PREFIX)
      end

      # Strips the extension prefix from a method name.
      # Returns nil if the method is not an extension method.
      def self.strip_prefix(method : String) : String?
        if extension?(method)
          method[PREFIX.size..]
        end
      end

      # Adds the extension prefix to a method name.
      def self.add_prefix(method : String) : String
        "#{PREFIX}#{method}"
      end
    end

    # ─── Client Method Names ──────────────────────────────────────────
    # Constants for all client method names, for use in dispatching
    # and handler registration.

    module ClientMethod
      # File system methods.
      FS_READ_TEXT_FILE  = "fs/read_text_file"
      FS_WRITE_TEXT_FILE = "fs/write_text_file"

      # Terminal methods.
      TERMINAL_CREATE        = "terminal/create"
      TERMINAL_OUTPUT        = "terminal/output"
      TERMINAL_RELEASE       = "terminal/release"
      TERMINAL_WAIT_FOR_EXIT = "terminal/wait_for_exit"
      TERMINAL_KILL          = "terminal/kill"

      # Permission request method.
      SESSION_REQUEST_PERMISSION = "session/request_permission"

      # Returns true if the given method name is a known client method.
      def self.known?(method : String) : Bool
        case method
        when FS_READ_TEXT_FILE, FS_WRITE_TEXT_FILE,
             TERMINAL_CREATE, TERMINAL_OUTPUT, TERMINAL_RELEASE,
             TERMINAL_WAIT_FOR_EXIT, TERMINAL_KILL,
             SESSION_REQUEST_PERMISSION
          true
        else
          false
        end
      end

      # Returns true if the given method name is a file system method.
      def self.fs_method?(method : String) : Bool
        method == FS_READ_TEXT_FILE || method == FS_WRITE_TEXT_FILE
      end

      # Returns true if the given method name is a terminal method.
      def self.terminal_method?(method : String) : Bool
        case method
        when TERMINAL_CREATE, TERMINAL_OUTPUT, TERMINAL_RELEASE,
             TERMINAL_WAIT_FOR_EXIT, TERMINAL_KILL
          true
        else
          false
        end
      end
    end
  end
end
