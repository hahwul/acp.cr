# ACP Protocol — Enumeration Constants
#
# Defines strongly-typed enumerations for all protocol-level string
# constants in the Agent Client Protocol. Using enums instead of raw
# strings provides compile-time safety, IDE auto-completion, and
# self-documenting code.
#
# Each enum serializes to/from its lowercase snake_case JSON string
# representation, matching the ACP wire format exactly.
#
# Reference: https://agentclientprotocol.com/protocol/schema

require "json"

module ACP
  module Protocol
    # ─── Stop Reason ──────────────────────────────────────────────────
    # Reasons why an agent stops processing a prompt turn.
    # See: https://agentclientprotocol.com/protocol/prompt-turn#stop-reasons

    enum StopReason
      # The language model finishes responding without requesting more tools.
      EndTurn

      # The maximum token limit is reached.
      MaxTokens

      # The maximum number of model requests in a single turn is exceeded.
      MaxTurnRequests

      # The Agent refuses to continue. The user prompt and everything
      # that comes after it won't be included in the next prompt.
      Refusal

      # The Client cancels the turn via `session/cancel`.
      Cancelled

      # Returns the wire-format string for this stop reason.
      def to_s : String
        case self
        in EndTurn         then "end_turn"
        in MaxTokens       then "max_tokens"
        in MaxTurnRequests then "max_turn_requests"
        in Refusal         then "refusal"
        in Cancelled       then "cancelled"
        end
      end

      # Parses a wire-format string into a StopReason.
      # Returns nil if the string is not a recognized stop reason.
      def self.parse?(value : String) : StopReason?
        case value
        when "end_turn"          then EndTurn
        when "max_tokens"        then MaxTokens
        when "max_turn_requests" then MaxTurnRequests
        when "refusal"           then Refusal
        when "cancelled"         then Cancelled
        else                          nil
        end
      end

      # Parses a wire-format string into a StopReason.
      # Raises ArgumentError if the string is not recognized.
      def self.parse(value : String) : StopReason
        parse?(value) || raise ArgumentError.new("Unknown StopReason: #{value}")
      end

      def to_json(json : JSON::Builder) : Nil
        json.string(to_s)
      end

      def self.new(pull : JSON::PullParser) : self
        parse(pull.read_string)
      end
    end

    # ─── Tool Kind ────────────────────────────────────────────────────
    # Categories of tools that can be invoked. Tool kinds help clients
    # choose appropriate icons and optimize display of tool execution.
    # See: https://agentclientprotocol.com/protocol/tool-calls#creating

    enum ToolKind
      # Reading files or data.
      Read

      # Modifying files or content.
      Edit

      # Removing files or data.
      Delete

      # Moving or renaming files.
      Move

      # Searching for information.
      Search

      # Running commands or code.
      Execute

      # Internal reasoning or planning.
      Think

      # Retrieving external data.
      Fetch

      # Switching the current session mode.
      SwitchMode

      # Other tool types (default).
      Other

      # Returns the wire-format string for this tool kind.
      def to_s : String
        case self
        in Read       then "read"
        in Edit       then "edit"
        in Delete     then "delete"
        in Move       then "move"
        in Search     then "search"
        in Execute    then "execute"
        in Think      then "think"
        in Fetch      then "fetch"
        in SwitchMode then "switch_mode"
        in Other      then "other"
        end
      end

      # Parses a wire-format string into a ToolKind.
      # Returns nil if the string is not a recognized tool kind.
      def self.parse?(value : String) : ToolKind?
        case value
        when "read"        then Read
        when "edit"        then Edit
        when "delete"      then Delete
        when "move"        then Move
        when "search"      then Search
        when "execute"     then Execute
        when "think"       then Think
        when "fetch"       then Fetch
        when "switch_mode" then SwitchMode
        when "other"       then Other
        else                    nil
        end
      end

      # Parses a wire-format string into a ToolKind.
      # Raises ArgumentError if the string is not recognized.
      def self.parse(value : String) : ToolKind
        parse?(value) || raise ArgumentError.new("Unknown ToolKind: #{value}")
      end

      def to_json(json : JSON::Builder) : Nil
        json.string(to_s)
      end

      def self.new(pull : JSON::PullParser) : self
        parse(pull.read_string)
      end
    end

    # ─── Tool Call Status ─────────────────────────────────────────────
    # Execution status of a tool call through its lifecycle.
    # See: https://agentclientprotocol.com/protocol/tool-calls#status

    enum ToolCallStatus
      # The tool call hasn't started running yet because the input is
      # either streaming or awaiting approval.
      Pending

      # The tool call is currently running.
      InProgress

      # The tool call completed successfully.
      Completed

      # The tool call failed with an error.
      Failed

      # Returns the wire-format string for this tool call status.
      def to_s : String
        case self
        in Pending    then "pending"
        in InProgress then "in_progress"
        in Completed  then "completed"
        in Failed     then "failed"
        end
      end

      # Parses a wire-format string into a ToolCallStatus.
      # Returns nil if the string is not recognized.
      def self.parse?(value : String) : ToolCallStatus?
        case value
        when "pending"     then Pending
        when "in_progress" then InProgress
        when "completed"   then Completed
        when "failed"      then Failed
        else                    nil
        end
      end

      # Parses a wire-format string into a ToolCallStatus.
      # Raises ArgumentError if the string is not recognized.
      def self.parse(value : String) : ToolCallStatus
        parse?(value) || raise ArgumentError.new("Unknown ToolCallStatus: #{value}")
      end

      def to_json(json : JSON::Builder) : Nil
        json.string(to_s)
      end

      def self.new(pull : JSON::PullParser) : self
        parse(pull.read_string)
      end
    end

    # ─── Permission Option Kind ───────────────────────────────────────
    # The type of permission option presented to the user. Helps clients
    # choose appropriate icons and UI treatment.
    # See: https://agentclientprotocol.com/protocol/tool-calls#permission-options

    enum PermissionOptionKind
      # Allow this operation only this time.
      AllowOnce

      # Allow this operation and remember the choice.
      AllowAlways

      # Reject this operation only this time.
      RejectOnce

      # Reject this operation and remember the choice.
      RejectAlways

      # Returns the wire-format string for this permission option kind.
      def to_s : String
        case self
        in AllowOnce    then "allow_once"
        in AllowAlways  then "allow_always"
        in RejectOnce   then "reject_once"
        in RejectAlways then "reject_always"
        end
      end

      # Parses a wire-format string into a PermissionOptionKind.
      # Returns nil if the string is not recognized.
      def self.parse?(value : String) : PermissionOptionKind?
        case value
        when "allow_once"    then AllowOnce
        when "allow_always"  then AllowAlways
        when "reject_once"   then RejectOnce
        when "reject_always" then RejectAlways
        else                      nil
        end
      end

      # Parses a wire-format string into a PermissionOptionKind.
      # Raises ArgumentError if the string is not recognized.
      def self.parse(value : String) : PermissionOptionKind
        parse?(value) || raise ArgumentError.new("Unknown PermissionOptionKind: #{value}")
      end

      def to_json(json : JSON::Builder) : Nil
        json.string(to_s)
      end

      def self.new(pull : JSON::PullParser) : self
        parse(pull.read_string)
      end
    end

    # ─── Plan Entry Priority ─────────────────────────────────────────
    # Priority levels for plan entries. Used to indicate the relative
    # importance or urgency of different tasks in the execution plan.
    # See: https://agentclientprotocol.com/protocol/agent-plan#plan-entries

    enum PlanEntryPriority
      # High priority task — critical to the overall goal.
      High

      # Medium priority task — important but not critical.
      Medium

      # Low priority task — nice to have but not essential.
      Low

      # Returns the wire-format string for this priority.
      def to_s : String
        case self
        in High   then "high"
        in Medium then "medium"
        in Low    then "low"
        end
      end

      # Parses a wire-format string into a PlanEntryPriority.
      # Returns nil if the string is not recognized.
      def self.parse?(value : String) : PlanEntryPriority?
        case value
        when "high"   then High
        when "medium" then Medium
        when "low"    then Low
        else               nil
        end
      end

      # Parses a wire-format string into a PlanEntryPriority.
      # Raises ArgumentError if the string is not recognized.
      def self.parse(value : String) : PlanEntryPriority
        parse?(value) || raise ArgumentError.new("Unknown PlanEntryPriority: #{value}")
      end

      def to_json(json : JSON::Builder) : Nil
        json.string(to_s)
      end

      def self.new(pull : JSON::PullParser) : self
        parse(pull.read_string)
      end
    end

    # ─── Plan Entry Status ────────────────────────────────────────────
    # Status of a plan entry in the execution flow. Tracks the lifecycle
    # of each task from planning through completion.
    # See: https://agentclientprotocol.com/protocol/agent-plan#plan-entries

    enum PlanEntryStatus
      # The task has not started yet.
      Pending

      # The task is currently being worked on.
      InProgress

      # The task has been successfully completed.
      Completed

      # Returns the wire-format string for this status.
      def to_s : String
        case self
        in Pending    then "pending"
        in InProgress then "in_progress"
        in Completed  then "completed"
        end
      end

      # Parses a wire-format string into a PlanEntryStatus.
      # Returns nil if the string is not recognized.
      def self.parse?(value : String) : PlanEntryStatus?
        case value
        when "pending"     then Pending
        when "in_progress" then InProgress
        when "completed"   then Completed
        else                    nil
        end
      end

      # Parses a wire-format string into a PlanEntryStatus.
      # Raises ArgumentError if the string is not recognized.
      def self.parse(value : String) : PlanEntryStatus
        parse?(value) || raise ArgumentError.new("Unknown PlanEntryStatus: #{value}")
      end

      def to_json(json : JSON::Builder) : Nil
        json.string(to_s)
      end

      def self.new(pull : JSON::PullParser) : self
        parse(pull.read_string)
      end
    end

    # ─── Session Config Option Category ───────────────────────────────
    # Semantic category for session configuration options. Helps clients
    # provide consistent UX such as keyboard shortcuts, icons, and placement.
    #
    # Category names beginning with `_` are free for custom use.
    # Category names that do not begin with `_` are reserved for the ACP spec.
    #
    # See: https://agentclientprotocol.com/protocol/session-config-options#option-categories

    enum SessionConfigOptionCategory
      # Session mode selector.
      Mode

      # Model selector.
      Model

      # Thought/reasoning level selector.
      ThoughtLevel

      # Unknown / uncategorized selector.
      Other

      # Returns the wire-format string for this category.
      def to_s : String
        case self
        in Mode         then "mode"
        in Model        then "model"
        in ThoughtLevel then "thought_level"
        in Other        then "other"
        end
      end

      # Parses a wire-format string into a SessionConfigOptionCategory.
      # Returns nil if the string is not recognized.
      def self.parse?(value : String) : SessionConfigOptionCategory?
        case value
        when "mode"          then Mode
        when "model"         then Model
        when "thought_level" then ThoughtLevel
        when "other"         then Other
        else                      nil
        end
      end

      # Parses a wire-format string into a SessionConfigOptionCategory.
      # Raises ArgumentError if the string is not recognized.
      def self.parse(value : String) : SessionConfigOptionCategory
        parse?(value) || raise ArgumentError.new("Unknown SessionConfigOptionCategory: #{value}")
      end

      def to_json(json : JSON::Builder) : Nil
        json.string(to_s)
      end

      def self.new(pull : JSON::PullParser) : self
        parse(pull.read_string)
      end
    end

    # ─── Role ─────────────────────────────────────────────────────────
    # The sender or recipient of messages and data in a conversation.
    # See: https://agentclientprotocol.com/protocol/schema#role

    enum Role
      # The AI assistant / agent.
      Assistant

      # The human user.
      User

      # Returns the wire-format string for this role.
      def to_s : String
        case self
        in Assistant then "assistant"
        in User      then "user"
        end
      end

      # Parses a wire-format string into a Role.
      # Returns nil if the string is not recognized.
      def self.parse?(value : String) : Role?
        case value
        when "assistant" then Assistant
        when "user"      then User
        else                  nil
        end
      end

      # Parses a wire-format string into a Role.
      # Raises ArgumentError if the string is not recognized.
      def self.parse(value : String) : Role
        parse?(value) || raise ArgumentError.new("Unknown Role: #{value}")
      end

      def to_json(json : JSON::Builder) : Nil
        json.string(to_s)
      end

      def self.new(pull : JSON::PullParser) : self
        parse(pull.read_string)
      end
    end

    # ─── ACP Error Codes ──────────────────────────────────────────────
    # Protocol-specific error codes beyond the standard JSON-RPC 2.0 set.
    # These use the reserved range (-32000 to -32099).
    # See: https://agentclientprotocol.com/protocol/schema#errorcode

    module ErrorCode
      # Standard JSON-RPC 2.0 error codes.
      PARSE_ERROR      = -32700
      INVALID_REQUEST  = -32600
      METHOD_NOT_FOUND = -32601
      INVALID_PARAMS   = -32602
      INTERNAL_ERROR   = -32603

      # ACP-specific error codes (reserved range -32000 to -32099).

      # Authentication is required before this operation can be performed.
      AUTH_REQUIRED = -32000

      # A given resource, such as a file, was not found.
      RESOURCE_NOT_FOUND = -32002
    end
  end
end
