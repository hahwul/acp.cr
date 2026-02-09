# ACP Protocol — Tool Call Content Types
#
# Defines the typed content structures that can appear in tool call
# updates. These replace raw JSON::Any representations with proper
# Crystal structs for type-safe handling of tool call output.
#
# Tool calls can produce three types of content:
#   - `content`  — Standard ContentBlock wrapper (text, images, resources)
#   - `diff`     — File modifications shown as diffs
#   - `terminal` — Live terminal output from command execution
#
# Additionally defines `ToolCallLocation` for file location tracking
# that enables "follow-along" features in clients.
#
# Reference: https://agentclientprotocol.com/protocol/tool-calls#content

require "json"
require "./content_block"

module ACP
  module Protocol
    # ─── Tool Call Content ────────────────────────────────────────────
    # Content produced by a tool call. Uses the "type" discriminator
    # to determine which variant is present.
    #
    # See: https://agentclientprotocol.com/protocol/tool-calls#content

    abstract struct ToolCallContent
      include JSON::Serializable

      use_json_discriminator "type", {
        "content"  => ToolCallContentBlock,
        "diff"     => ToolCallDiff,
        "terminal" => ToolCallTerminal,
      }

      # The discriminator field present on every tool call content item.
      getter type : String
    end

    # ─── Standard Content ─────────────────────────────────────────────
    # Wraps a standard ContentBlock (text, images, resources) inside
    # a tool call content item.
    #
    # Example JSON:
    #   {
    #     "type": "content",
    #     "content": { "type": "text", "text": "Analysis complete." }
    #   }

    struct ToolCallContentBlock < ToolCallContent
      include JSON::Serializable

      # Always "content" for this variant.
      getter type : String = "content"

      # The actual content block (text, image, audio, resource, resource_link).
      property content : ContentBlock

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@content : ContentBlock, @meta : Hash(String, JSON::Any)? = nil)
        @type = "content"
      end

      # Convenience: returns the text if the inner content is a TextContentBlock.
      def text : String?
        if c = @content.as?(TextContentBlock)
          c.text
        end
      end
    end

    # ─── Diff Content ─────────────────────────────────────────────────
    # File modifications shown as diffs. Shows changes to files in a
    # format suitable for display in the client UI.
    #
    # Example JSON:
    #   {
    #     "type": "diff",
    #     "path": "/home/user/project/src/config.json",
    #     "oldText": "{ \"debug\": false }",
    #     "newText": "{ \"debug\": true }"
    #   }
    #
    # See: https://agentclientprotocol.com/protocol/tool-calls#diffs

    struct ToolCallDiff < ToolCallContent
      include JSON::Serializable

      # Always "diff" for this variant.
      getter type : String = "diff"

      # The absolute file path being modified (required).
      property path : String

      # The original content (nil for new files).
      @[JSON::Field(key: "oldText")]
      property old_text : String?

      # The new content after modification (required).
      @[JSON::Field(key: "newText")]
      property new_text : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @path : String,
        @new_text : String,
        @old_text : String? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @type = "diff"
      end

      # Returns true if this diff represents a new file creation.
      def new_file? : Bool
        @old_text.nil?
      end

      # Returns true if this diff represents a file deletion (new_text is empty).
      def deletion? : Bool
        @new_text.empty? && !@old_text.nil?
      end
    end

    # ─── Terminal Content ─────────────────────────────────────────────
    # Embeds a terminal created with `terminal/create` by its ID.
    # When embedded in a tool call, the client displays live output
    # as it's generated and continues to display it even after the
    # terminal is released.
    #
    # Example JSON:
    #   {
    #     "type": "terminal",
    #     "terminalId": "term_xyz789"
    #   }
    #
    # See: https://agentclientprotocol.com/protocol/tool-calls#terminals

    struct ToolCallTerminal < ToolCallContent
      include JSON::Serializable

      # Always "terminal" for this variant.
      getter type : String = "terminal"

      # The ID of a terminal created with `terminal/create` (required).
      @[JSON::Field(key: "terminalId")]
      property terminal_id : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@terminal_id : String, @meta : Hash(String, JSON::Any)? = nil)
        @type = "terminal"
      end
    end

    # ─── Tool Call Location ───────────────────────────────────────────
    # A file location being accessed or modified by a tool. Enables
    # clients to implement "follow-along" features that track which
    # files the agent is working with in real-time.
    #
    # Example JSON:
    #   {
    #     "path": "/home/user/project/src/main.py",
    #     "line": 42
    #   }
    #
    # See: https://agentclientprotocol.com/protocol/tool-calls#following-the-agent

    struct ToolCallLocation
      include JSON::Serializable

      # The absolute file path being accessed or modified (required).
      property path : String

      # Optional line number within the file (1-based).
      property line : Int32?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @path : String,
        @line : Int32? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end

      # Returns a human-readable representation of this location.
      def to_s(io : IO) : Nil
        io << @path
        if l = @line
          io << ':'
          io << l
        end
      end
    end

    # ─── Terminal Exit Status ─────────────────────────────────────────
    # Exit status of a terminal command. Used in terminal/output and
    # terminal/wait_for_exit responses.
    #
    # See: https://agentclientprotocol.com/protocol/terminals

    struct TerminalExitStatus
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
  end
end
