# ACP Protocol — Session Update Types
#
# Defines all the session update notification types that an agent can
# send to the client during a prompt turn. These are delivered as
# `session/update` notifications (JSON-RPC 2.0 notifications with
# method = "session/update").
#
# The ACP spec uses "sessionUpdate" as the discriminator field name
# in the update object. For example:
#
#   {
#     "jsonrpc": "2.0",
#     "method": "session/update",
#     "params": {
#       "sessionId": "sess_abc123",
#       "update": {
#         "sessionUpdate": "agent_message_chunk",
#         "content": { "type": "text", "text": "Hello!" }
#       }
#     }
#   }
#
# The client dispatcher normalizes incoming updates so that both
# "sessionUpdate" (spec-standard) and "type" (legacy/backward-compat)
# are accepted.
#
# Reference: https://agentclientprotocol.com/protocol/prompt-turn
# Reference: https://agentclientprotocol.com/protocol/schema

require "json"
require "./content_block"

module ACP
  module Protocol
    # ─── Content Chunk ─────────────────────────────────────────────────
    # A streamed item of content, wrapping a ContentBlock. Used in
    # message chunk session updates (user_message_chunk,
    # agent_message_chunk, agent_thought_chunk).
    #
    # Matches the Rust SDK's `ContentChunk` struct.
    # See: https://agentclientprotocol.com/protocol/prompt-turn
    struct ContentChunk
      include JSON::Serializable

      # A single item of content (text, image, audio, resource, resource_link).
      property content : ContentBlock

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@content : ContentBlock, @meta : Hash(String, JSON::Any)? = nil)
      end

      # Convenience: returns the text if the content is a TextContentBlock.
      def text : String?
        if c = @content.as?(TextContentBlock)
          c.text
        end
      end
    end

    # ─── Session Update Wrapper ────────────────────────────────────────
    #
    # The params of a `session/update` notification. Contains the session
    # ID and the polymorphic update payload.

    struct SessionUpdateParams
      include JSON::Serializable

      # The session this update belongs to.
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The update payload. Deserialized using the "sessionUpdate" discriminator.
      property update : SessionUpdate

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@session_id : String, @update : SessionUpdate, @meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # ─── Abstract Update Base ──────────────────────────────────────────

    # Abstract base for all session update types. Deserialization is
    # dispatched via the "sessionUpdate" JSON field, which is the
    # ACP spec-standard discriminator.
    #
    # The client dispatcher ensures backward compatibility by normalizing
    # the legacy "type" field to "sessionUpdate" before parsing.
    abstract struct SessionUpdate
      include JSON::Serializable

      use_json_discriminator "sessionUpdate", {
        # ── ACP Spec Standard Types ──
        "user_message_chunk"        => UserMessageChunkUpdate,
        "agent_message_chunk"       => AgentMessageChunkUpdate,
        "agent_thought_chunk"       => AgentThoughtChunkUpdate,
        "tool_call"                 => ToolCallUpdate,
        "tool_call_update"          => ToolCallStatusUpdate,
        "plan"                      => PlanUpdate,
        "available_commands_update" => AvailableCommandsUpdate,
        "current_mode_update"       => CurrentModeUpdate,
        "config_option_update"      => ConfigOptionUpdate,
        "config_options_update"     => ConfigOptionUpdate,
        # ── Non-Standard / Backward Compatibility ──
        "agent_message_start" => AgentMessageStartUpdate,
        "agent_message_end"   => AgentMessageEndUpdate,
        "thought"             => AgentThoughtChunkUpdate,
        "tool_call_start"     => ToolCallUpdate,
        "tool_call_chunk"     => ToolCallChunkUpdate,
        "tool_call_end"       => ToolCallEndUpdate,
        "status"              => StatusUpdate,
        "error"               => ErrorUpdate,
      }

      # The discriminator field. In the ACP spec this is "sessionUpdate".
      @[JSON::Field(key: "sessionUpdate")]
      property session_update : String

      # Backward-compatible alias: returns the session update type string.
      def type : String
        @session_update
      end
    end

    # ═══════════════════════════════════════════════════════════════════
    # ACP Spec Standard Update Types
    # ═══════════════════════════════════════════════════════════════════

    # ─── User Message Chunk ────────────────────────────────────────────

    # A chunk of the user's message being streamed (e.g., during session/load replay).
    # See: https://agentclientprotocol.com/protocol/session-setup#loading-a-session
    struct UserMessageChunkUpdate < SessionUpdate
      include JSON::Serializable

      # The content chunk. Kept as JSON::Any for backward compatibility
      # with agents that may send varying formats.
      property content : JSON::Any

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@content : JSON::Any, @meta : Hash(String, JSON::Any)? = nil)
        @session_update = "user_message_chunk"
      end

      # Helper to get the actual text content regardless of wrapping.
      def text : String
        if (h = @content.as_h?) && h["text"]?
          h["text"].as_s
        elsif s = @content.as_s?
          s
        else
          @content.to_json
        end
      end

      # Attempts to parse the content as a typed ContentBlock.
      # Returns nil if parsing fails.
      def content_block : ContentBlock?
        if h = @content.as_h?
          ContentBlock.from_json(@content.to_json) rescue nil
        end
      end

      # Returns a ContentChunk wrapping the parsed content block, if possible.
      def to_content_chunk : ContentChunk?
        if block = content_block
          ContentChunk.new(block, @meta)
        end
      end
    end

    # ─── Agent Message Chunk ───────────────────────────────────────────

    # A chunk of the agent's response being streamed.
    # See: https://agentclientprotocol.com/protocol/prompt-turn#3-agent-reports-output
    struct AgentMessageChunkUpdate < SessionUpdate
      include JSON::Serializable

      # The content chunk. Kept as JSON::Any for backward compatibility
      # with agents that may send varying formats.
      property content : JSON::Any

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@content : JSON::Any, @meta : Hash(String, JSON::Any)? = nil)
        @session_update = "agent_message_chunk"
      end

      # Helper to get the actual text content regardless of wrapping.
      def text : String
        if (h = @content.as_h?) && h["text"]?
          h["text"].as_s
        elsif s = @content.as_s?
          s
        else
          @content.to_json
        end
      end

      # Attempts to parse the content as a typed ContentBlock.
      # Returns nil if parsing fails.
      def content_block : ContentBlock?
        if h = @content.as_h?
          ContentBlock.from_json(@content.to_json) rescue nil
        end
      end

      # Returns a ContentChunk wrapping the parsed content block, if possible.
      def to_content_chunk : ContentChunk?
        if block = content_block
          ContentChunk.new(block, @meta)
        end
      end
    end

    # ─── Agent Thought Chunk ───────────────────────────────────────────

    # A chunk of the agent's internal reasoning/chain-of-thought being streamed.
    # See: https://agentclientprotocol.com/protocol/prompt-turn
    struct AgentThoughtChunkUpdate < SessionUpdate
      include JSON::Serializable

      # The content chunk. Kept as JSON::Any for backward compatibility
      # with agents that may send varying formats.
      property content : JSON::Any

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@content : JSON::Any, @meta : Hash(String, JSON::Any)? = nil)
        @session_update = "agent_thought_chunk"
      end

      # Helper to get the actual text content regardless of wrapping.
      def text : String
        if (h = @content.as_h?) && h["text"]?
          h["text"].as_s
        elsif s = @content.as_s?
          s
        else
          @content.to_json
        end
      end

      # Backward-compatible alias for `text`. Some agents send a `title` field.
      def title : String
        text
      end

      # Attempts to parse the content as a typed ContentBlock.
      # Returns nil if parsing fails.
      def content_block : ContentBlock?
        if h = @content.as_h?
          ContentBlock.from_json(@content.to_json) rescue nil
        end
      end

      # Returns a ContentChunk wrapping the parsed content block, if possible.
      def to_content_chunk : ContentChunk?
        if block = content_block
          ContentChunk.new(block, @meta)
        end
      end
    end

    # Backward-compatible alias for ThoughtUpdate.
    alias ThoughtUpdate = AgentThoughtChunkUpdate

    # ─── Tool Call ─────────────────────────────────────────────────────

    # Notification that a new tool call has been initiated by the language model.
    # See: https://agentclientprotocol.com/protocol/tool-calls#creating
    struct ToolCallUpdate < SessionUpdate
      include JSON::Serializable

      # Unique identifier for this tool call within the session (required).
      @[JSON::Field(key: "toolCallId")]
      property tool_call_id : String

      # Human-readable title describing what the tool is doing (required).
      property title : String

      # The category of tool being invoked. Helps clients choose icons.
      # Values: read, edit, delete, move, search, execute, think, fetch,
      #         switch_mode, other
      property kind : String?

      # Current execution status: pending, in_progress, completed, failed.
      property status : String?

      # Content produced by the tool call.
      property content : Array(JSON::Any)?

      # File locations affected by this tool call.
      property locations : Array(JSON::Any)?

      # Raw input parameters sent to the tool.
      @[JSON::Field(key: "rawInput")]
      property raw_input : JSON::Any?

      # Raw output returned by the tool.
      @[JSON::Field(key: "rawOutput")]
      property raw_output : JSON::Any?

      # The name of the tool being invoked (non-standard, backward compat).
      @[JSON::Field(key: "toolName")]
      property tool_name : String?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @tool_call_id : String,
        @title : String,
        @kind : String? = nil,
        @status : String? = "pending",
        @content : Array(JSON::Any)? = nil,
        @locations : Array(JSON::Any)? = nil,
        @raw_input : JSON::Any? = nil,
        @raw_output : JSON::Any? = nil,
        @tool_name : String? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @session_update = "tool_call"
      end
    end

    # Backward-compatible alias.
    alias ToolCallStartUpdate = ToolCallUpdate

    # ─── Tool Call Update ──────────────────────────────────────────────

    # Update on the status or results of an existing tool call.
    # All fields except toolCallId are optional — only changed fields
    # need to be included.
    # See: https://agentclientprotocol.com/protocol/tool-calls#updating
    struct ToolCallStatusUpdate < SessionUpdate
      include JSON::Serializable

      # The ID of the tool call being updated (required).
      @[JSON::Field(key: "toolCallId")]
      property tool_call_id : String

      # Update the execution status.
      property status : String?

      # Update the human-readable title.
      property title : String?

      # Update the tool kind.
      property kind : String?

      # Replace the content collection.
      property content : Array(JSON::Any)?

      # Replace the locations collection.
      property locations : Array(JSON::Any)?

      # Update the raw input.
      @[JSON::Field(key: "rawInput")]
      property raw_input : JSON::Any?

      # Update the raw output.
      @[JSON::Field(key: "rawOutput")]
      property raw_output : JSON::Any?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @tool_call_id : String,
        @status : String? = nil,
        @title : String? = nil,
        @kind : String? = nil,
        @content : Array(JSON::Any)? = nil,
        @locations : Array(JSON::Any)? = nil,
        @raw_input : JSON::Any? = nil,
        @raw_output : JSON::Any? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @session_update = "tool_call_update"
      end
    end

    # ─── Plan Update ───────────────────────────────────────────────────

    # An execution plan for accomplishing complex tasks.
    # See: https://agentclientprotocol.com/protocol/agent-plan
    struct PlanUpdate < SessionUpdate
      include JSON::Serializable

      # The list of tasks to be accomplished (required).
      # When updating, the agent MUST send a complete list; the client
      # replaces the entire plan with each update.
      property entries : Array(PlanEntry)

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @entries : Array(PlanEntry) = [] of PlanEntry,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @session_update = "plan"
      end
    end

    # A single entry in an execution plan.
    # See: https://agentclientprotocol.com/protocol/agent-plan#plan-entries
    struct PlanEntry
      include JSON::Serializable

      # Human-readable description of what this task aims to accomplish (required).
      property content : String

      # The relative importance of this task: "high", "medium", or "low" (required).
      property priority : String

      # Current execution status: "pending", "in_progress", or "completed" (required).
      property status : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @content : String,
        @priority : String = "medium",
        @status : String = "pending",
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Backward-compatible alias.
    alias PlanStep = PlanEntry

    # ─── Available Commands Update ─────────────────────────────────────

    # Notification that available slash commands have changed.
    # See: https://agentclientprotocol.com/protocol/slash-commands
    struct AvailableCommandsUpdate < SessionUpdate
      include JSON::Serializable

      # The commands the agent can execute.
      @[JSON::Field(key: "availableCommands")]
      property available_commands : Array(AvailableCommand)

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @available_commands : Array(AvailableCommand) = [] of AvailableCommand,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @session_update = "available_commands_update"
      end
    end

    # Information about an available slash command.
    struct AvailableCommand
      include JSON::Serializable

      # Command name (e.g., "web", "test", "plan").
      property name : String

      # Human-readable description of what the command does.
      property description : String

      # Optional input specification for the command.
      property input : AvailableCommandInput?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @name : String,
        @description : String,
        @input : AvailableCommandInput? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Input specification for a slash command.
    # In the ACP spec this is a union type (currently only "unstructured").
    struct AvailableCommandInput
      include JSON::Serializable

      # A hint to display when the input hasn't been provided yet.
      property hint : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@hint : String, @meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # ─── Current Mode Update ───────────────────────────────────────────

    # Notification that the current session mode has changed.
    # See: https://agentclientprotocol.com/protocol/session-modes#from-the-agent
    struct CurrentModeUpdate < SessionUpdate
      include JSON::Serializable

      # The ID of the current mode.
      @[JSON::Field(key: "currentModeId")]
      property current_mode_id : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@current_mode_id : String, @meta : Hash(String, JSON::Any)? = nil)
        @session_update = "current_mode_update"
      end

      # Backward-compatible alias.
      def mode_id : String
        @current_mode_id
      end
    end

    # ─── Config Option Update ──────────────────────────────────────────

    # Notification that session configuration options have been updated.
    # See: https://agentclientprotocol.com/protocol/session-config-options#from-the-agent
    struct ConfigOptionUpdate < SessionUpdate
      include JSON::Serializable

      # The full set of configuration options and their current values.
      @[JSON::Field(key: "configOptions")]
      property config_options : Array(JSON::Any)

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @config_options : Array(JSON::Any) = [] of JSON::Any,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @session_update = "config_option_update"
      end
    end

    # ═══════════════════════════════════════════════════════════════════
    # Non-Standard Update Types (Backward Compatibility)
    # ═══════════════════════════════════════════════════════════════════
    #
    # The following types are NOT part of the official ACP spec but are
    # kept for backward compatibility with some agent implementations
    # (e.g., Gemini CLI, custom agents).

    # ─── Agent Message Start (Non-Standard) ────────────────────────────

    # Signals the beginning of a new agent message. The client should
    # prepare to receive streamed chunks.
    # NOTE: Not part of the ACP spec.
    struct AgentMessageStartUpdate < SessionUpdate
      include JSON::Serializable

      # Optional message ID for correlating start/chunk/end events.
      @[JSON::Field(key: "messageId")]
      property message_id : String?

      # Optional role indicator (usually "assistant").
      property role : String?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@message_id : String? = nil, @role : String? = nil, @meta : Hash(String, JSON::Any)? = nil)
        @session_update = "agent_message_start"
      end
    end

    # ─── Agent Message End (Non-Standard) ──────────────────────────────

    # Signals the end of an agent message.
    # NOTE: Not part of the ACP spec.
    struct AgentMessageEndUpdate < SessionUpdate
      include JSON::Serializable

      # Optional message ID for correlation.
      @[JSON::Field(key: "messageId")]
      property message_id : String?

      # Optional stop reason for this particular message.
      @[JSON::Field(key: "stopReason")]
      property stop_reason : String?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@message_id : String? = nil, @stop_reason : String? = nil, @meta : Hash(String, JSON::Any)? = nil)
        @session_update = "agent_message_end"
      end
    end

    # ─── Tool Call Chunk (Non-Standard) ────────────────────────────────

    # A streamed chunk of tool call input or output.
    # NOTE: Not part of the ACP spec. Use tool_call_update instead.
    struct ToolCallChunkUpdate < SessionUpdate
      include JSON::Serializable

      # The tool call ID this chunk belongs to.
      @[JSON::Field(key: "toolCallId")]
      property tool_call_id : String

      # The content of this tool call chunk.
      property content : String?

      # Optional field indicating whether this is "input" or "output".
      property kind : String?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @tool_call_id : String,
        @content : String? = nil,
        @kind : String? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @session_update = "tool_call_chunk"
      end
    end

    # ─── Tool Call End (Non-Standard) ──────────────────────────────────

    # Signals that a tool invocation has completed.
    # NOTE: Not part of the ACP spec. Use tool_call_update with
    # status "completed" or "failed" instead.
    struct ToolCallEndUpdate < SessionUpdate
      include JSON::Serializable

      # The tool call ID this end event corresponds to.
      @[JSON::Field(key: "toolCallId")]
      property tool_call_id : String

      # Final status of the tool call (e.g., "completed", "failed", "cancelled").
      property status : String = "completed"

      # Optional result content from the tool invocation.
      property result : String?

      # Optional error message if the tool call failed.
      property error : String?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @tool_call_id : String,
        @status : String = "completed",
        @result : String? = nil,
        @error : String? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @session_update = "tool_call_end"
      end
    end

    # ─── Status Update (Non-Standard) ──────────────────────────────────

    # Indicates a change in the agent's high-level status.
    # NOTE: Not part of the ACP spec.
    struct StatusUpdate < SessionUpdate
      include JSON::Serializable

      # The new status label (e.g., "thinking", "working", "idle").
      property status : String

      # Optional human-readable message providing more context.
      property message : String?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@status : String, @message : String? = nil, @meta : Hash(String, JSON::Any)? = nil)
        @session_update = "status"
      end
    end

    # ─── Error Update (Non-Standard) ───────────────────────────────────

    # Reports a non-fatal error to the client.
    # NOTE: Not part of the ACP spec.
    struct ErrorUpdate < SessionUpdate
      include JSON::Serializable

      # Error message text.
      property message : String

      # Optional error code for programmatic handling.
      property code : Int32?

      # Optional additional detail or stack trace.
      property detail : String?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@message : String, @code : Int32? = nil, @detail : String? = nil, @meta : Hash(String, JSON::Any)? = nil)
        @session_update = "error"
      end
    end
  end
end
