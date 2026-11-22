# ACP Protocol — Session Update Types
#
# Typed accessor support:
#   `ToolCallUpdate` and `ToolCallStatusUpdate` store `content` and
#   `locations` as `Array(JSON::Any)?` for wire compatibility. The
#   helper methods `typed_content` and `typed_locations` attempt to
#   parse these into `Array(ToolCallContent)` and
#   `Array(ToolCallLocation)` respectively, silently skipping entries
#   that fail to deserialize.
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
require "./prompt_suggestions"
require "./session_options"
require "./tool_call_content"
require "./tool_call_content_helper"
require "./chunk_content_helper"

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
      include LosslessMetadata

      # A single item of display content.
      property content : ContentBlock

      # Optional ID linking this chunk to other chunks of the same message.
      @[JSON::Field(key: "messageId")]
      property message_id : String?

      # Creates a chunk with optional extension metadata.
      def initialize(@content : ContentBlock, meta : Hash(String, JSON::Any)? = nil, @message_id : String? = nil)
        self.meta = meta
      end

      # Creates a chunk from exact extension metadata.
      def initialize(@content : ContentBlock, *, meta_raw : RawJson?, @message_id : String? = nil)
        if meta_raw && meta_raw.object?
          @metadata_wire = PreservedJson.new(meta_raw, project_object_members: true)
        end
      end

      # Reads a serialized v2 chunk wrapper with open display content.
      def self.from_v2_json(json : String) : self
        wire = RawJson.from_json(json)
        unless block = wire.field("content")
          raise JSON::SerializableError.new("Missing required content", to_s, "content", 1, 1, nil)
        end
        new(ContentBlock.from_v2_json(block), meta_raw: wire.field("_meta"), message_id: wire.field("messageId").try(&.as_s?))
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

      # Whether this update arrived during a pending `session/load`.
      # Child state, capabilities, and config options from this interval
      # describe history. Set by a client tracking subagent sessions.
      @[JSON::Field(ignore: true)]
      property? before_load_response : Bool = false

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

      # Keep the wire nesting limit when copying a discriminated update.
      # Candidates inside a suggestion list are validated individually.
      private macro use_session_update_discriminator(mapping)
        def self.new(pull : JSON::PullParser)
          location = pull.location_i64
          kind = nil
          wire = JSON.build do |json|
            json.max_nesting = pull.max_nesting
            json.object do
              pull.read_object do |key|
                kind = pull.kind.string? ? pull.string_value : nil if key == "sessionUpdate"
                json.field(key) { pull.read_raw(json) }
              end
            end
          end

          case kind
          {% for name, type in mapping %}
            when {{name}} then {{type}}.from_json(wire)
          {% end %}
          else
            raise JSON::SerializableError.new("Unknown or missing 'sessionUpdate' discriminator: #{kind.inspect}", to_s, nil, *location, nil)
          end
        end
      end

      use_session_update_discriminator({
        # ── ACP Spec Standard Types ──
        "user_message_chunk"        => UserMessageChunkUpdate,
        "agent_message_chunk"       => AgentMessageChunkUpdate,
        "agent_thought_chunk"       => AgentThoughtChunkUpdate,
        "tool_call"                 => ToolCallUpdate,
        "tool_call_update"          => ToolCallStatusUpdate,
        "plan"                      => PlanUpdate,
        "plan_update"               => IdentifiedPlanUpdate,
        "plan_removed"              => PlanRemovedUpdate,
        "subagent_update"           => SubagentUpdate,
        "session_message"           => SessionMessageUpdate,
        "session_message_chunk"     => SessionMessageChunkUpdate,
        "available_commands_update" => AvailableCommandsUpdate,
        "current_mode_update"       => CurrentModeUpdate,
        "config_option_update"      => ConfigOptionUpdate,
        "config_options_update"     => ConfigOptionUpdate,
        "session_info_update"       => SessionInfoUpdate,
        "usage_update"              => UsageUpdate,
        "notice"                    => NoticeUpdate,
        "compaction_update"         => CompactionUpdate,
        "compaction_summary_chunk"  => CompactionSummaryChunkUpdate,
        "cursor_update"             => CursorUpdate,
        "prompt_suggestions_update" => PromptSuggestionsUpdate,
        # ── Non-Standard / Backward Compatibility ──
        "agent_message_start" => AgentMessageStartUpdate,
        "agent_message_end"   => AgentMessageEndUpdate,
        "thought"             => AgentThoughtChunkUpdate,
        "tool_call_start"     => ToolCallUpdate,
        "tool_call_chunk"     => ToolCallChunkUpdate,
        "tool_call_end"       => ToolCallEndUpdate,
        "status"              => StatusUpdate,
        "error"               => ErrorUpdate,
      })

      # The discriminator field. In the ACP spec this is "sessionUpdate".
      @[JSON::Field(key: "sessionUpdate")]
      property session_update : String

      # Backward-compatible alias: returns the session update type string.
      def type : String
        @session_update
      end
    end

    # Replaces the suggestions for the next user prompt.
    struct PromptSuggestionsUpdate < SessionUpdate
      # Suggestions in Agent priority order. An empty list withdraws them.
      @[JSON::Field(converter: ::ACP::Protocol::PromptSuggestionList(::ACP::Protocol::PromptSuggestion))]
      getter suggestions : Array(PromptSuggestion)

      # Extension metadata scoped to the replacement.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      getter meta : Hash(String, JSON::Any)?

      # Creates a replacement list for the session.
      def initialize(@suggestions : Array(PromptSuggestion), @meta : Hash(String, JSON::Any)? = nil)
        @session_update = "prompt_suggestions_update"
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

      # Optional ID correlating every chunk of the same logical message.
      @[JSON::Field(key: "messageId")]
      property message_id : String?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @content : JSON::Any,
        @message_id : String? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @session_update = "user_message_chunk"
      end

      include ChunkContentHelper
    end

    # ─── Agent Message Chunk ───────────────────────────────────────────

    # A chunk of the agent's response being streamed.
    # See: https://agentclientprotocol.com/protocol/prompt-turn#3-agent-reports-output
    struct AgentMessageChunkUpdate < SessionUpdate
      include JSON::Serializable

      # The content chunk. Kept as JSON::Any for backward compatibility
      # with agents that may send varying formats.
      property content : JSON::Any

      # Optional ID correlating every chunk of the same logical message.
      @[JSON::Field(key: "messageId")]
      property message_id : String?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @content : JSON::Any,
        @message_id : String? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @session_update = "agent_message_chunk"
      end

      include ChunkContentHelper
    end

    # ─── Agent Thought Chunk ───────────────────────────────────────────

    # A chunk of the agent's internal reasoning/chain-of-thought being streamed.
    # See: https://agentclientprotocol.com/protocol/prompt-turn
    struct AgentThoughtChunkUpdate < SessionUpdate
      include JSON::Serializable

      # The content chunk. Kept as JSON::Any for backward compatibility
      # with agents that may send varying formats.
      property content : JSON::Any

      # Optional ID correlating every chunk of the same logical message.
      @[JSON::Field(key: "messageId")]
      property message_id : String?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @content : JSON::Any,
        @message_id : String? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @session_update = "agent_thought_chunk"
      end

      include ChunkContentHelper

      # Backward-compatible alias for `text`. Some agents send a `title` field.
      def title : String
        text
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

      # The name of the tool being invoked.
      property name : String?

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
        @name : String? = nil,
      )
        @session_update = "tool_call"
      end

      include ToolCallContentHelper
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

      # Update the tool name.
      property name : String?

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
        @name : String? = nil,
      )
        @session_update = "tool_call_update"
      end

      include ToolCallContentHelper
    end

    # ─── Plan Update ───────────────────────────────────────────────────

    # An execution plan for accomplishing complex tasks.
    # See: https://agentclientprotocol.com/protocol/agent-plan
    struct PlanUpdate < SessionUpdate
      include JSON::Serializable

      # The list of tasks to be accomplished (required).
      # When updating, the agent MUST send a complete list; the client
      # replaces the entire plan with each update.
      @[JSON::Field(converter: ::ACP::Protocol::PlanEntries)]
      property entries : Array(PlanEntry) = [] of PlanEntry

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
      include LosslessMetadata

      # Human-readable description of what this task aims to accomplish (required).
      property content : String

      # The relative importance of this task: "high", "medium", or "low" (required).
      property priority : String = "medium"

      # Current execution status: "pending", "in_progress", "completed", "cancelled", or an extension.
      property status : String = "pending"

      # Creates an entry with defaults for priority and status.
      def initialize(
        @content : String,
        @priority : String = "medium",
        @status : String = "pending",
        meta : Hash(String, JSON::Any)? = nil,
      )
        self.meta = meta
      end
    end

    # Backward-compatible alias.
    alias PlanStep = PlanEntry

    # :nodoc:
    module PlanEntries
      def self.from_json(pull : JSON::PullParser) : Array(PlanEntry)
        read(pull, require_fields: false)
      end

      def self.read(pull : JSON::PullParser, *, require_fields : Bool) : Array(PlanEntry)
        entries = [] of PlanEntry
        pull.read_array do
          wire = WireFrame.read_raw(pull)
          if entry = decode_entry(wire, require_fields: require_fields)
            entries << entry
          end
        end
        entries
      end

      private def self.decode_entry(wire : String, *, require_fields : Bool) : PlanEntry?
        return unless WireFrame.unique_members?(wire)

        if require_fields
          fields = RawJson.new(JSON::PullParser.new(wire)).members?
          return unless fields && fields["priority"]?.try(&.as_s?) && fields["status"]?.try(&.as_s?)
        end
        PlanEntry.from_json(wire)
      rescue JSON::ParseException
        nil
      end

      def self.to_json(entries : Array(PlanEntry), json : JSON::Builder) : Nil
        entries.to_json(json)
      end
    end

    # A complete identified plan carried by `plan_update`.
    abstract struct PlanUpdateContent
      include JSON::Serializable
      include LosslessMetadata

      use_json_discriminator "type", {
        "items"    => PlanItems,
        "markdown" => PlanMarkdown,
      }

      # Representation of the plan on the wire.
      getter type : String

      # Opaque plan ID, unique within its session.
      @[JSON::Field(key: "planId")]
      getter plan_id : String
    end

    # An identified plan represented as a complete checklist.
    struct PlanItems < PlanUpdateContent
      # Current entries. Each update supplies the full list.
      @[JSON::Field(converter: ::ACP::Protocol::PlanEntries)]
      property entries : Array(PlanEntry)

      # Creates a checklist plan.
      def initialize(@plan_id : String, @entries : Array(PlanEntry), meta : Hash(String, JSON::Any)? = nil)
        @type = "items"
        self.meta = meta
      end

      # Creates a checklist with exact extension metadata.
      def initialize(@plan_id : String, @entries : Array(PlanEntry), *, meta_raw : RawJson?)
        @type = "items"
        if meta_raw && meta_raw.object?
          @metadata_wire = PreservedJson.new(meta_raw, project_object_members: true)
        end
      end
    end

    # An identified plan represented as a Markdown document.
    struct PlanMarkdown < PlanUpdateContent
      # The entire Markdown document.
      property content : String

      # Optional absolute path to the file containing the plan.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalAbsolutePath)]
      property path : String?

      # Creates a Markdown plan.
      def initialize(@plan_id : String, @content : String, @path : String? = nil, meta : Hash(String, JSON::Any)? = nil)
        @type = "markdown"
        self.meta = meta
      end
    end

    # Replaces the complete plan with this ID, including its representation.
    struct IdentifiedPlanUpdate < SessionUpdate
      include LosslessMetadata

      # The replacement checklist or Markdown document.
      property plan : PlanUpdateContent

      # Creates a `plan_update` notification payload.
      def initialize(@plan : PlanUpdateContent, meta : Hash(String, JSON::Any)? = nil)
        @session_update = "plan_update"
        self.meta = meta
      end
    end

    # Removes a plan previously announced in the same session.
    struct PlanRemovedUpdate < SessionUpdate
      include LosslessMetadata

      # The plan ID to remove.
      @[JSON::Field(key: "planId")]
      property plan_id : String

      # Creates a `plan_removed` notification payload.
      def initialize(@plan_id : String, meta : Hash(String, JSON::Any)? = nil)
        @session_update = "plan_removed"
        self.meta = meta
      end
    end

    # ─── Available Commands Update ─────────────────────────────────────

    # Notification that available slash commands have changed.
    # See: https://agentclientprotocol.com/protocol/slash-commands
    struct AvailableCommandsUpdate < SessionUpdate
      include JSON::Serializable

      # The commands the agent can execute.
      @[JSON::Field(key: "availableCommands")]
      property available_commands : Array(AvailableCommand) = [] of AvailableCommand

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
      # Stored as `Array(JSON::Any)` for wire compatibility; use
      # `typed_config_options` for parsed `ConfigOption` structs.
      @[JSON::Field(key: "configOptions", converter: ::ACP::Protocol::RequiredOptionList)]
      property config_options : Array(JSON::Any) = [] of JSON::Any

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @config_options : Array(JSON::Any) = [] of JSON::Any,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @session_update = "config_option_update"
      end

      # Attempts to parse `config_options` items as typed `ConfigOption` values.
      # Entries that fail to deserialize or have an unrecognized `type` are
      # skipped (see `Protocol.parse_config_options`).
      def typed_config_options : Array(ConfigOption)
        Protocol.parse_config_options(@config_options)
      end
    end

    # ─── Session Info Update ─────────────────────────────────────────

    # Notification that session metadata has changed (e.g., title or timestamp).
    # Agents send this to inform the client of changes to the session's
    # human-readable metadata.
    # See: https://agentclientprotocol.com/protocol/session-setup
    struct SessionInfoUpdate < SessionUpdate
      include JSON::Serializable

      # Human-readable title for the session. May be set by the agent
      # based on conversation content (e.g., a summary of the first prompt).
      # Omitted means unchanged, `null` means cleared: both read as nil
      # here, so check `title_present?` to tell them apart.
      @[JSON::Field(presence: true)]
      getter title : String?

      # ISO 8601 timestamp of last activity. Like `title`, `null` clears
      # it; see `updated_at_present?`.
      @[JSON::Field(key: "updatedAt", presence: true)]
      getter updated_at : String?

      # Whether `title` was sent (possibly as `null`, i.e. cleared).
      @[JSON::Field(ignore: true)]
      getter? title_present : Bool

      # Whether `updatedAt` was sent (possibly as `null`, i.e. cleared).
      @[JSON::Field(ignore: true)]
      getter? updated_at_present : Bool

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @title : String? = nil,
        @updated_at : String? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @session_update = "session_info_update"
        @title_present = !@title.nil?
        @updated_at_present = !@updated_at.nil?
      end

      # Assigning a field marks it present (assigning nil means "clear").
      def title=(@title : String?) : String?
        @title_present = true
        @title
      end

      # :ditto:
      def updated_at=(@updated_at : String?) : String?
        @updated_at_present = true
        @updated_at
      end
    end

    # ─── Usage Update ────────────────────────────────────────────────

    # The monetary cost accrued by a session so far.
    # See: https://agentclientprotocol.com/protocol/schema
    struct Cost
      include JSON::Serializable
      include LosslessMetadata

      # The amount spent, in `currency` units (required).
      property amount : Float64

      # The currency the amount is denominated in (required).
      property currency : String

      def initialize(
        @amount : Float64,
        @currency : String,
        meta : Hash(String, JSON::Any)? = nil,
      )
        self.meta = meta
      end
    end

    # Notification that the session's context-window usage has changed.
    # Agents send this so clients can show how much of the window is
    # consumed, and optionally what the turn has cost.
    # See: https://agentclientprotocol.com/protocol/schema
    struct UsageUpdate < SessionUpdate
      include JSON::Serializable

      # How much of the context window is currently in use (required). Schema `uint64`.
      property used : UInt64

      # The total size of the context window (required). Schema `uint64`.
      property size : UInt64

      # The cost accrued so far, if the agent reports one.
      property cost : Cost?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @used : UInt64,
        @size : UInt64,
        @cost : Cost? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @session_update = "usage_update"
      end

      # The fraction of the context window in use, in `0.0..1.0`.
      # Returns 0.0 when `size` is zero so callers never divide by zero.
      def usage_ratio : Float64
        return 0.0 if @size == 0
        @used.to_f / @size.to_f
      end
    end

    # ─── Notice ──────────────────────────────────────────────────────

    # A live, user-facing notice scoped to one event. ACP v1 delivery requires
    # the Client's `clientCapabilities.session.notices` capability.
    # Severity is a presentation hint and leaves request and session state alone.
    # See: https://agentclientprotocol.com/protocol/v2/prompt-lifecycle#session-notices
    struct NoticeUpdate < SessionUpdate
      include JSON::Serializable
      include LosslessMetadata

      # "info", "warning", "error", or a future/`_`-prefixed value (required).
      property severity : String

      # Short, non-empty plain-text summary (required).
      property title : String

      # Optional supporting detail.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalContentValue(String))]
      property description : String?

      # Creates a notice with an open severity value.
      def initialize(
        @severity : String,
        @title : String,
        @description : String? = nil,
        meta : Hash(String, JSON::Any)? = nil,
      )
        @session_update = "notice"
        self.meta = meta
      end

      private def after_initialize : Nil
        if @title.empty?
          raise JSON::ParseException.new("Notice title must not be empty", 0, 0)
        end
      end
    end

    # ─── Compaction ──────────────────────────────────────────────────

    # Creates or patches an ID-addressed context compaction entity. Only
    # sent to clients that advertise `clientCapabilities.session.compaction`.
    #
    # `summary`, `error` and `_meta` are patches: omitted leaves the stored
    # value unchanged, `null` clears it, a value replaces it (`summary: []`
    # also clears). Both omitted and `null` read as nil here, so check
    # `summary_present?` / `error_present?` / `meta_present?`.
    # See: https://agentclientprotocol.com/protocol/v1/prompt-turn#session-compaction
    struct CompactionUpdate < SessionUpdate
      include JSON::Serializable

      # Opaque, agent-owned ID, unique within the session (required).
      @[JSON::Field(key: "compactionId")]
      property compaction_id : String

      # "in_progress", "completed", "failed", "cancelled", or a
      # future/`_`-prefixed value (required).
      property status : String

      # Replacement summary content blocks. Kept as raw JSON like message
      # chunks; see `typed_summary`.
      @[JSON::Field(presence: true)]
      getter summary : Array(JSON::Any)?

      # Human-readable error description.
      @[JSON::Field(presence: true)]
      getter error : String?

      # Extension metadata for the compaction entity.
      @[JSON::Field(key: "_meta", presence: true)]
      getter meta : Hash(String, JSON::Any)?

      # Whether `summary` was sent (possibly as `null`, i.e. cleared).
      @[JSON::Field(ignore: true)]
      getter? summary_present : Bool

      # Whether `error` was sent (possibly as `null`, i.e. cleared).
      @[JSON::Field(ignore: true)]
      getter? error_present : Bool

      # Whether `_meta` was sent (possibly as `null`, i.e. cleared).
      @[JSON::Field(ignore: true)]
      getter? meta_present : Bool

      def initialize(
        @compaction_id : String,
        @status : String,
        @summary : Array(JSON::Any)? = nil,
        @error : String? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @session_update = "compaction_update"
        @summary_present = !@summary.nil?
        @error_present = !@error.nil?
        @meta_present = !@meta.nil?
      end

      # Assigning a field marks it present (assigning nil means "clear").
      def summary=(@summary : Array(JSON::Any)?) : Array(JSON::Any)?
        @summary_present = true
        @summary
      end

      # :ditto:
      def error=(@error : String?) : String?
        @error_present = true
        @error
      end

      # :ditto:
      def meta=(@meta : Hash(String, JSON::Any)?) : Hash(String, JSON::Any)?
        @meta_present = true
        @meta
      end

      # Writes an explicit `null` for a field that is present but nil, so a
      # clear survives re-serialization instead of turning into "unchanged".
      protected def on_to_json(json : ::JSON::Builder)
        json.field("summary", nil) if @summary_present && @summary.nil?
        json.field("error", nil) if @error_present && @error.nil?
        json.field("_meta", nil) if @meta_present && @meta.nil?
      end

      # `summary` parsed into content blocks, skipping entries that don't
      # parse. Nil when no summary was sent or it was cleared.
      def typed_summary : Array(ContentBlock)?
        @summary.try &.compact_map { |item| ContentBlock.from_json(item.to_json) rescue nil }
      end
    end

    # Appends one content block to a compaction's summary.
    # See: https://agentclientprotocol.com/protocol/v1/prompt-turn#session-compaction
    struct CompactionSummaryChunkUpdate < SessionUpdate
      include JSON::Serializable
      include LosslessMetadata
      include LosslessContentField
      include ChunkContentHelper

      # :nodoc:
      V2_REQUIRED_FIELDS = {"sessionUpdate", "compactionId", "content"}
      V2_OPTIONAL_FIELDS = {"_meta"}
      V2_WIRE_FIELDS     = V2_REQUIRED_FIELDS + V2_OPTIONAL_FIELDS

      # The compaction this chunk belongs to (required).
      @[JSON::Field(key: "compactionId")]
      property compaction_id : String

      @[JSON::Field(ignore: true)]
      @open_content = false

      # Creates a summary chunk.
      def initialize(@compaction_id : String, content : JSON::Any, meta : Hash(String, JSON::Any)? = nil)
        @session_update = "compaction_summary_chunk"
        @content_wire = PreservedJson.new(content)
        self.meta = meta
      end

      # Reads a v2 summary chunk with unambiguous fields and usable open content.
      def self.from_v2_json(json : String) : self
        parser = RawJson.patch_parser(JSON::PullParser.new(json), required: V2_REQUIRED_FIELDS, optional: V2_OPTIONAL_FIELDS)
        chunk = new(parser)
        ContentBlock.from_v2_json(chunk.content_raw)
        chunk.enable_open_content
        chunk
      end

      protected def enable_open_content : Nil
        @open_content = true
      end

      # Converts the appended block using the compaction's wire version.
      def content_block : ContentBlock?
        if @open_content
          ContentBlock.from_v2_json(content_raw)
        else
          ContentBlock.from_json(content_raw.json)
        end
      rescue JSON::Error
        nil
      end

      # Wraps the appended block with metadata scoped to this chunk.
      def to_content_chunk : ContentChunk?
        if block = content_block
          ContentChunk.new(block, meta_raw: meta_raw)
        end
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

require "./subagent_updates"
require "./cursor_update"
