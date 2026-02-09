# ACP Protocol — Session Update Types
#
# Session updates are sent from the agent to the client as
# `session/update` notifications. Each update has a "type"
# discriminator field that determines its shape.
#
# Supported update types:
#   - "agent_message_start"   — signals the beginning of a new agent message
#   - "agent_message_chunk"   — a streamed chunk of the agent's response text
#   - "agent_message_end"     — signals the end of an agent message
#   - "thought"               — agent's internal reasoning / chain-of-thought
#   - "tool_call_start"       — a tool invocation has begun
#   - "tool_call_chunk"       — streamed chunk of tool call input/output
#   - "tool_call_end"         — a tool invocation has completed
#   - "plan"                  — agent's high-level plan or step list
#   - "status"                — agent status change (e.g., thinking, working)
#   - "error"                 — an error that doesn't terminate the session
#
# Uses Crystal's `use_json_discriminator` to automatically deserialize
# the correct subtype based on the "type" field.

require "json"

module ACP
  module Protocol
    # ─── Session Update Wrapper ────────────────────────────────────────
    #
    # The params of a `session/update` notification. Contains the session
    # ID and the polymorphic update payload.

    struct SessionUpdateParams
      include JSON::Serializable

      # The session this update belongs to.
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The update payload. Deserialized using the "type" discriminator.
      property update : SessionUpdate

      def initialize(@session_id : String, @update : SessionUpdate)
      end
    end

    # ─── Abstract Update Base ──────────────────────────────────────────

    # Abstract base for all session update types. Deserialization is
    # dispatched via the "type" JSON field.
    abstract struct SessionUpdate
      include JSON::Serializable

      use_json_discriminator "type", {
        "agent_message_start" => AgentMessageStartUpdate,
        "agent_message_chunk" => AgentMessageChunkUpdate,
        "agent_message_end"   => AgentMessageEndUpdate,
        "thought"             => ThoughtUpdate,
        "tool_call_start"     => ToolCallStartUpdate,
        "tool_call_chunk"     => ToolCallChunkUpdate,
        "tool_call_end"       => ToolCallEndUpdate,
        "plan"                => PlanUpdate,
        "status"              => StatusUpdate,
        "error"               => ErrorUpdate,
      }

      # The discriminator field present on every update.
      getter type : String
    end

    # ─── Agent Message Updates ─────────────────────────────────────────

    # Signals the beginning of a new agent message. The client should
    # prepare to receive streamed chunks that form a complete message.
    struct AgentMessageStartUpdate < SessionUpdate
      include JSON::Serializable

      getter type : String = "agent_message_start"

      # Optional message ID for correlating start/chunk/end events.
      @[JSON::Field(key: "messageId")]
      property message_id : String?

      # Optional role indicator (usually "assistant").
      property role : String?

      def initialize(@message_id : String? = nil, @role : String? = nil)
        @type = "agent_message_start"
      end
    end

    # A streamed chunk of the agent's response text. Multiple chunks
    # arrive between a `agent_message_start` and `agent_message_end`,
    # and should be concatenated by the client to form the full message.
    struct AgentMessageChunkUpdate < SessionUpdate
      include JSON::Serializable

      getter type : String = "agent_message_chunk"

      # The text content of this chunk. Append to the current message buffer.
      property content : String

      # Optional message ID for correlating with start/end events.
      @[JSON::Field(key: "messageId")]
      property message_id : String?

      def initialize(@content : String, @message_id : String? = nil)
        @type = "agent_message_chunk"
      end
    end

    # Signals the end of an agent message. After receiving this, the
    # client can consider the current message complete.
    struct AgentMessageEndUpdate < SessionUpdate
      include JSON::Serializable

      getter type : String = "agent_message_end"

      # Optional message ID for correlation.
      @[JSON::Field(key: "messageId")]
      property message_id : String?

      # Optional stop reason for this particular message.
      @[JSON::Field(key: "stopReason")]
      property stop_reason : String?

      def initialize(@message_id : String? = nil, @stop_reason : String? = nil)
        @type = "agent_message_end"
      end
    end

    # ─── Thought Update ────────────────────────────────────────────────

    # Represents the agent's internal reasoning or chain-of-thought.
    # Clients may display this in a collapsible "thinking" pane or
    # log it for debugging purposes.
    struct ThoughtUpdate < SessionUpdate
      include JSON::Serializable

      getter type : String = "thought"

      # The thought text content.
      property content : String

      # Optional title or label for the thought block.
      property title : String?

      def initialize(@content : String, @title : String? = nil)
        @type = "thought"
      end
    end

    # ─── Tool Call Updates ─────────────────────────────────────────────

    # Signals that the agent is starting a tool invocation. The client
    # should display a pending tool call indicator.
    struct ToolCallStartUpdate < SessionUpdate
      include JSON::Serializable

      getter type : String = "tool_call_start"

      # Unique identifier for this tool call, used to correlate
      # start/chunk/end events and permission requests.
      @[JSON::Field(key: "toolCallId")]
      property tool_call_id : String

      # Human-readable title or description of the tool call.
      property title : String?

      # The name of the tool being invoked.
      @[JSON::Field(key: "toolName")]
      property tool_name : String?

      # The status of the tool call. Typically "pending" at start.
      property status : String = "pending"

      def initialize(
        @tool_call_id : String,
        @title : String? = nil,
        @tool_name : String? = nil,
        @status : String = "pending",
      )
        @type = "tool_call_start"
      end
    end

    # A streamed chunk of tool call input or output. These chunks arrive
    # between a `tool_call_start` and `tool_call_end` for a given tool
    # call ID.
    struct ToolCallChunkUpdate < SessionUpdate
      include JSON::Serializable

      getter type : String = "tool_call_chunk"

      # The tool call ID this chunk belongs to.
      @[JSON::Field(key: "toolCallId")]
      property tool_call_id : String

      # The content of this tool call chunk (could be input being
      # constructed or output being streamed).
      property content : String?

      # Optional field indicating whether this is "input" or "output".
      property kind : String?

      def initialize(
        @tool_call_id : String,
        @content : String? = nil,
        @kind : String? = nil,
      )
        @type = "tool_call_chunk"
      end
    end

    # Signals that a tool invocation has completed. Contains the final
    # status and optionally the tool's result.
    struct ToolCallEndUpdate < SessionUpdate
      include JSON::Serializable

      getter type : String = "tool_call_end"

      # The tool call ID this end event corresponds to.
      @[JSON::Field(key: "toolCallId")]
      property tool_call_id : String

      # Final status of the tool call (e.g., "completed", "failed", "cancelled").
      property status : String = "completed"

      # Optional result content from the tool invocation.
      property result : String?

      # Optional error message if the tool call failed.
      property error : String?

      def initialize(
        @tool_call_id : String,
        @status : String = "completed",
        @result : String? = nil,
        @error : String? = nil,
      )
        @type = "tool_call_end"
      end
    end

    # ─── Plan Update ───────────────────────────────────────────────────

    # Represents the agent's high-level plan or step list. The client
    # can display this as a progress indicator or task list.
    struct PlanUpdate < SessionUpdate
      include JSON::Serializable

      getter type : String = "plan"

      # Human-readable title for the plan.
      property title : String?

      # Ordered list of plan steps. Each step is a simple description.
      property steps : Array(PlanStep)?

      # Free-form text description of the plan.
      property content : String?

      def initialize(
        @title : String? = nil,
        @steps : Array(PlanStep)? = nil,
        @content : String? = nil,
      )
        @type = "plan"
      end
    end

    # A single step within a `PlanUpdate`.
    struct PlanStep
      include JSON::Serializable

      # Unique identifier for this step.
      property id : String?

      # Human-readable description of the step.
      property title : String

      # Current status of the step (e.g., "pending", "in_progress", "completed", "failed").
      property status : String = "pending"

      def initialize(@title : String, @id : String? = nil, @status : String = "pending")
      end
    end

    # ─── Status Update ─────────────────────────────────────────────────

    # Indicates a change in the agent's high-level status. Useful for
    # displaying a spinner or status text in the client UI.
    struct StatusUpdate < SessionUpdate
      include JSON::Serializable

      getter type : String = "status"

      # The new status label (e.g., "thinking", "working", "idle").
      property status : String

      # Optional human-readable message providing more context.
      property message : String?

      def initialize(@status : String, @message : String? = nil)
        @type = "status"
      end
    end

    # ─── Error Update ──────────────────────────────────────────────────

    # Reports a non-fatal error to the client. The session remains active
    # but the client should display the error to the user.
    struct ErrorUpdate < SessionUpdate
      include JSON::Serializable

      getter type : String = "error"

      # Error message text.
      property message : String

      # Optional error code for programmatic handling.
      property code : Int32?

      # Optional additional detail or stack trace.
      property detail : String?

      def initialize(@message : String, @code : Int32? = nil, @detail : String? = nil)
        @type = "error"
      end
    end
  end
end
