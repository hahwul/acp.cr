# ACP Protocol — Capability Types
#
# Defines the capability structures exchanged during the `initialize`
# handshake. The client advertises what it supports (file system access,
# terminal, etc.) and the agent advertises what it can do (load sessions,
# accept images/audio in prompts, MCP transports, etc.).
#
# Reference: https://agentclientprotocol.com/protocol/initialization

require "json"
require "./auth_status"
require "./session_status"
require "./session_title"
require "./session_archive"
require "./session_options"
require "./prompt_suggestions"
require "./providers"
require "./mcp"
require "./optional_capability"
require "./raw_json"

module ACP
  module Protocol
    # ─── Client Capabilities ──────────────────────────────────────────

    # File-system capabilities the client can provide to the agent.
    # See: https://agentclientprotocol.com/protocol/file-system
    struct FsCapabilities
      include JSON::Serializable

      # Whether the client can read text files on behalf of the agent.
      # Enables the `fs/read_text_file` method.
      @[JSON::Field(key: "readTextFile")]
      property? read_text_file : Bool = false

      # Whether the client can write text files on behalf of the agent.
      # Enables the `fs/write_text_file` method.
      @[JSON::Field(key: "writeTextFile")]
      property? write_text_file : Bool = false

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @read_text_file : Bool = false,
        @write_text_file : Bool = false,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Presence (`{}`) advertises that the client handles `compaction_update`
    # and `compaction_summary_chunk` session updates (`CompactionUpdate`,
    # `CompactionSummaryChunkUpdate`).
    # See: https://agentclientprotocol.com/protocol/v1/prompt-turn#session-compaction
    struct CompactionCapabilities
      include JSON::Serializable

      def initialize
      end
    end

    # Presence (`{}`) advertises that the client handles `notice` session
    # updates (`NoticeUpdate`).
    # See: https://agentclientprotocol.com/protocol/v1/prompt-turn#session-notices
    struct NoticeCapabilities
      include JSON::Serializable

      def initialize
      end
    end

    # Presence (`{}`) advertises that the client understands `type: "boolean"`
    # config options.
    # See: https://agentclientprotocol.com/protocol/v1/session-config-options#boolean-config-options
    struct BooleanConfigOptionCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Config option types the client supports beyond the baseline `select`.
    struct SessionConfigOptionsCapabilities
      include JSON::Serializable

      # When present, the agent may send `type: "boolean"` config options.
      property boolean : BooleanConfigOptionCapabilities?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @boolean : BooleanConfigOptionCapabilities? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Presence advertises support for v1 cursor_update notifications.
    struct SessionCursorsCapabilities
      include JSON::Serializable

      # Creates the cursor support marker.
      def initialize
      end

      # :nodoc:
      def self.from_json(pull : JSON::PullParser) : SessionCursorsCapabilities?
        return new(pull) if pull.kind.begin_object?

        pull.skip
        nil
      end

      # :nodoc:
      def self.to_json(value : SessionCursorsCapabilities, json : JSON::Builder) : Nil
        value.to_json(json)
      end
    end

    # Session-related client capabilities (`clientCapabilities.session`).
    # Each field is opt-in: omitted or null means unsupported, and the agent
    # MUST NOT send the corresponding updates or option types.
    struct ClientSessionCapabilities
      include JSON::Serializable

      # Context compaction updates.
      property compaction : CompactionCapabilities?

      # Config option types beyond `select`.
      @[JSON::Field(key: "configOptions")]
      property config_options : SessionConfigOptionsCapabilities?

      # Live user-facing notices.
      property notices : NoticeCapabilities?

      # Session cursor announcements.
      @[JSON::Field(converter: ::ACP::Protocol::SessionCursorsCapabilities)]
      property cursors : SessionCursorsCapabilities?

      # Draft prompt suggestions presented to the user.
      @[JSON::Field(key: "promptSuggestions", converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::PromptSuggestionsCapabilities))]
      property prompt_suggestions : PromptSuggestionsCapabilities?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @compaction : CompactionCapabilities? = nil,
        @config_options : SessionConfigOptionsCapabilities? = nil,
        @notices : NoticeCapabilities? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
        @cursors : SessionCursorsCapabilities? = nil,
        @prompt_suggestions : PromptSuggestionsCapabilities? = nil,
      )
      end
    end

    # Presence (`{}`) of `form` / `url` in `ElicitationCapabilities`
    # advertises that elicitation mode.
    struct ElicitationModeCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Schema names for the two mode capability objects.
    alias ElicitationFormCapabilities = ElicitationModeCapabilities
    alias ElicitationUrlCapabilities = ElicitationModeCapabilities

    # The `elicitation/create` modes the client supports. Unlike MCP, an
    # empty object advertises no mode: each mode must be present and non-null.
    # See: https://agentclientprotocol.com/protocol/v1/elicitation#checking-support
    struct ElicitationCapabilities
      include JSON::Serializable

      # Form mode support.
      property form : ElicitationFormCapabilities?

      # URL mode support.
      property url : ElicitationUrlCapabilities?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @form : ElicitationFormCapabilities? = nil,
        @url : ElicitationUrlCapabilities? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end

      # Returns true if the given `mode` ("form" or "url") is advertised.
      def supports?(mode : String?) : Bool
        case mode
        when "form" then !@form.nil?
        when "url"  then !@url.nil?
        else             false
        end
      end
    end

    # Presence advertises support for identified plan updates and removals.
    # See: https://agentclientprotocol.com/protocol/v1/agent-plan#plan-operations
    struct PlanCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      # Creates the capability, optionally with extension metadata.
      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Presence advertises support for exposed child sessions.
    struct SubagentCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      # Creates the subagent capability.
      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Presence authorizes cancellation for an announced child session.
    struct SessionCancelCapabilities
      include JSON::Serializable
      include LosslessMetadata

      # Creates the cancellation capability, optionally with metadata.
      def initialize(meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end
    end

    # Methods the client can send to an announced child session.
    struct SubagentSessionCapabilities
      include JSON::Serializable
      include LosslessMetadata

      # A value authorizes `session/cancel` for the child.
      property cancel : SessionCancelCapabilities?

      # Creates the child's method allowlist.
      def initialize(@cancel : SessionCancelCapabilities? = nil, meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end
    end

    # Authentication flows the client can perform.
    struct ClientAuthCapabilities
      include JSON::Serializable

      # Whether the client can run the configured agent in a terminal for login.
      property? terminal : Bool = false

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      # Creates the client's advertised authentication capabilities.
      def initialize(@terminal : Bool = false, @meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # The full set of capabilities the client advertises to the agent
    # during the `initialize` handshake.
    #
    # Everything defaults to unsupported. Only advertise a capability once
    # the client actually handles it, e.g. set `elicitation` together with
    # `Client#on_create_elicitation`.
    # See: https://agentclientprotocol.com/protocol/initialization#client-capabilities
    struct ClientCapabilities
      include JSON::Serializable

      # File-system access capabilities. Nil means no FS support.
      property fs : FsCapabilities?

      # Whether the client supports all `terminal/*` methods.
      # Serialized as a plain bool in the protocol.
      @[JSON::Field(key: "terminal")]
      property? terminal : Bool = false

      # Session-related capabilities (compaction, notices, boolean config
      # options). Nil means none.
      property session : ClientSessionCapabilities?

      # Supported `elicitation/create` modes. Nil means elicitation is
      # unsupported.
      property elicitation : ElicitationCapabilities?

      # Support for identified checklist and Markdown plans.
      property plan : PlanCapabilities?

      # Support for Agent-owned child sessions.
      property subagents : SubagentCapabilities?

      # Authentication flows supported by this client.
      property auth : ClientAuthCapabilities?

      # Extension metadata for custom capabilities.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @fs : FsCapabilities? = nil,
        @terminal : Bool = false,
        @meta : Hash(String, JSON::Any)? = nil,
        @session : ClientSessionCapabilities? = nil,
        @elicitation : ElicitationCapabilities? = nil,
        @plan : PlanCapabilities? = nil,
        @subagents : SubagentCapabilities? = nil,
        @auth : ClientAuthCapabilities? = nil,
      )
      end
    end

    # ─── Agent Capabilities ───────────────────────────────────────────

    # Describes which prompt content types the agent can accept.
    # As a baseline, all Agents MUST support ContentBlock::Text and
    # ContentBlock::ResourceLink in session/prompt requests.
    # See: https://agentclientprotocol.com/protocol/initialization#prompt-capabilities
    struct PromptCapabilities
      include JSON::Serializable

      # Whether the agent accepts image content blocks.
      @[JSON::Field(converter: ::ACP::Protocol::CapabilityFlag)]
      property? image : Bool = false

      # Whether the agent accepts audio content blocks.
      @[JSON::Field(converter: ::ACP::Protocol::CapabilityFlag)]
      property? audio : Bool = false

      # Whether the agent accepts embedded resource content blocks
      # (ContentBlock::Resource) in session/prompt requests.
      @[JSON::Field(key: "embeddedContext", converter: ::ACP::Protocol::CapabilityFlag)]
      property? embedded_context : Bool = false

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @image : Bool = false,
        @audio : Bool = false,
        @embedded_context : Bool = false,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # MCP transport capabilities supported by the agent.
    # See: https://agentclientprotocol.com/protocol/session-setup#checking-transport-support
    struct McpCapabilities
      include JSON::Serializable

      # Whether the agent supports connecting to MCP servers over HTTP.
      @[JSON::Field(converter: ::ACP::Protocol::CapabilityFlag)]
      property? http : Bool = false

      # Whether the agent supports connecting to MCP servers over SSE.
      # Note: SSE transport has been deprecated by the MCP spec.
      @[JSON::Field(converter: ::ACP::Protocol::CapabilityFlag)]
      property? sse : Bool = false

      # Whether the Agent consumes MCP servers over ACP.
      @[JSON::Field(converter: ::ACP::Protocol::CapabilityFlag)]
      property? acp : Bool = false

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @http : Bool = false,
        @sse : Bool = false,
        @meta : Hash(String, JSON::Any)? = nil,
        @acp : Bool = false,
      )
      end
    end

    # Capabilities for the session/list method.
    # Presence of this object (even empty) indicates the agent supports
    # listing sessions via `session/list`.
    # See: https://agentclientprotocol.com/protocol/session-setup#listing-sessions
    struct SessionListCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Capabilities for the session/resume method.
    # Presence of this object (even empty) indicates the agent supports
    # reconnecting to an existing session via `session/resume` without
    # replaying conversation history.
    # See: https://agentclientprotocol.com/protocol/session-setup#resuming-sessions
    struct SessionResumeCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Capabilities for the session/close method.
    # Presence of this object (even empty) indicates the agent supports
    # cancelling ongoing work and freeing resources for a session via
    # `session/close`.
    # See: https://agentclientprotocol.com/protocol/session-setup#closing-active-sessions
    struct SessionCloseCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Capabilities for the session/delete method.
    # Presence of this object (even empty) indicates the agent supports
    # removing sessions from `session/list` via `session/delete`.
    # See: https://agentclientprotocol.com/protocol/v1/session-delete
    struct SessionDeleteCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Presence of this object (even empty) indicates the agent accepts
    # `additionalDirectories` on `session/new`, `session/load` and
    # `session/resume`.
    # See: https://agentclientprotocol.com/protocol/v1/session-setup#additional-workspace-roots
    struct SessionAdditionalDirectoriesCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Presence advertises the `override` system prompt mode.
    struct SessionSystemPromptOverrideCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # System prompt modes the agent supports beyond the baseline `append`.
    struct SessionSystemPromptModeCapabilities
      include JSON::Serializable
      include LosslessUnmapped

      # When present, the agent accepts `mode: "override"`.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::SessionSystemPromptOverrideCapabilities))]
      property override : SessionSystemPromptOverrideCapabilities?

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @override : SessionSystemPromptOverrideCapabilities? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Interprets an extension-defined advertisement for a system prompt mode.
    alias SystemPromptModeResolver = (String, SessionSystemPromptCapabilities -> Bool)

    # Presence of this object (even empty) indicates the agent accepts a
    # `systemPrompt` (mode `append`) on `session/new`, `session/load` and
    # `session/resume`.
    # See: https://agentclientprotocol.com/protocol/v1/session-setup#system-prompt
    struct SessionSystemPromptCapabilities
      include JSON::Serializable

      # Additional modes the agent supports.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::SessionSystemPromptModeCapabilities))]
      property mode : SessionSystemPromptModeCapabilities?

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @mode : SessionSystemPromptModeCapabilities? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end

      # Returns true if the agent accepts `mode: "override"`.
      def override? : Bool
        !@mode.try(&.override).nil?
      end

      # Whether the Agent accepts this baseline or advertised prompt mode.
      # A resolver can recognize custom modes advertised through extension metadata.
      def supports_mode?(name : String, resolve : SystemPromptModeResolver? = nil) : Bool
        case name
        when "append"   then true
        when "override" then override?
        else
          declared = @mode.try do |modes|
            modes.json_unmapped[name]?.try(&.as_h?) || modes.raw_field(name).try(&.starts_with?('{'))
          end
          !!(declared || resolve.try(&.call(name, self)))
        end
      end
    end

    # Session capabilities supported by the agent.
    # As a baseline, all Agents MUST support session/new, session/prompt,
    # session/cancel, and session/update.
    # See: https://agentclientprotocol.com/protocol/initialization#session-capabilities
    struct SessionCapabilities
      include JSON::Serializable

      # When present (non-null), indicates the agent supports `session/list`.
      # The value is a `SessionListCapabilities` object.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::SessionListCapabilities))]
      property list : SessionListCapabilities?

      # When present (non-null), indicates the agent supports `session/resume`.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::SessionResumeCapabilities))]
      property resume : SessionResumeCapabilities?

      # When present (non-null), indicates the agent supports `session/close`.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::SessionCloseCapabilities))]
      property close : SessionCloseCapabilities?

      # When present (non-null), indicates the agent supports `session/delete`.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::SessionDeleteCapabilities))]
      property delete : SessionDeleteCapabilities?

      # When present (non-null), the agent accepts `additionalDirectories`.
      @[JSON::Field(key: "additionalDirectories", converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::SessionAdditionalDirectoriesCapabilities))]
      property additional_directories : SessionAdditionalDirectoriesCapabilities?

      # When present (non-null), the agent accepts a `systemPrompt`.
      @[JSON::Field(key: "systemPrompt", converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::SessionSystemPromptCapabilities))]
      property system_prompt : SessionSystemPromptCapabilities?

      # When present, the Agent supports the draft session/status query.
      @[JSON::Field(converter: ::ACP::Protocol::SessionStatusCapabilities)]
      property status : SessionStatusCapabilities?

      # When present, the Agent supports setting session titles.
      @[JSON::Field(converter: ::ACP::Protocol::SessionTitleCapabilities)]
      property title : SessionTitleCapabilities?

      # When present, the Agent supports archiving, restoration, and archive filters.
      @[JSON::Field(converter: ::ACP::Protocol::SessionArchiveCapabilities)]
      property archive : SessionArchiveCapabilities?

      # Presence advertises session/options and initial configuration values.
      @[JSON::Field(converter: ::ACP::Protocol::SessionOptionsCapabilities)]
      property options : SessionOptionsCapabilities?

      # Presence advertises session/fork and permits previewing its source options.
      @[JSON::Field(converter: ::ACP::Protocol::SessionForkCapabilities)]
      property fork : SessionForkCapabilities?

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @list : SessionListCapabilities? = nil,
        @resume : SessionResumeCapabilities? = nil,
        @close : SessionCloseCapabilities? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
        @delete : SessionDeleteCapabilities? = nil,
        @additional_directories : SessionAdditionalDirectoriesCapabilities? = nil,
        @system_prompt : SessionSystemPromptCapabilities? = nil,
        @status : SessionStatusCapabilities? = nil,
        @title : SessionTitleCapabilities? = nil,
        @archive : SessionArchiveCapabilities? = nil,
        @options : SessionOptionsCapabilities? = nil,
        @fork : SessionForkCapabilities? = nil,
      )
      end

      # Returns true if the agent supports deleting sessions.
      def delete? : Bool
        !@delete.nil?
      end

      # Returns true if the agent accepts `additionalDirectories`.
      def additional_directories? : Bool
        !@additional_directories.nil?
      end

      # Returns true if the agent accepts a `systemPrompt`.
      def system_prompt? : Bool
        !@system_prompt.nil?
      end

      # Returns true if the agent supports session listing.
      def list? : Bool
        !@list.nil?
      end

      # Returns true if the agent supports resuming sessions.
      def resume? : Bool
        !@resume.nil?
      end

      # Returns true if the agent supports closing sessions.
      def close? : Bool
        !@close.nil?
      end
    end

    # Presence of this object (even empty) indicates the agent supports
    # the `logout` method.
    # See: https://agentclientprotocol.com/protocol/v1/authentication#logging-out
    struct LogoutCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Authentication-related agent capabilities (`agentCapabilities.auth`).
    struct AgentAuthCapabilities
      include JSON::Serializable

      # When present (non-null), the agent supports `logout`.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::LogoutCapabilities))]
      property logout : LogoutCapabilities?

      # When present, the Agent supports the draft auth/status method.
      @[JSON::Field(converter: ::ACP::Protocol::AuthStatusCapabilities)]
      property status : AuthStatusCapabilities?

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @logout : LogoutCapabilities? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
        @status : AuthStatusCapabilities? = nil,
      )
      end

      # Returns true if the agent supports `logout`.
      def logout? : Bool
        !@logout.nil?
      end
    end

    # The full set of capabilities the agent advertises to the client
    # in its `initialize` response.
    # See: https://agentclientprotocol.com/protocol/initialization#agent-capabilities
    struct AgentCapabilities
      include JSON::Serializable

      # Whether the agent supports loading previous sessions via `session/load`.
      @[JSON::Field(key: "loadSession", converter: ::ACP::Protocol::CapabilityFlag)]
      property? load_session : Bool = false

      # Describes which prompt content types the agent can accept.
      @[JSON::Field(key: "promptCapabilities", converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::PromptCapabilities))]
      property prompt_capabilities : PromptCapabilities?

      # MCP transport capabilities.
      @[JSON::Field(key: "mcpCapabilities", converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::McpCapabilities))]
      property mcp_capabilities : McpCapabilities?

      # Session capabilities beyond the baseline.
      @[JSON::Field(key: "sessionCapabilities", converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::SessionCapabilities))]
      property session_capabilities : SessionCapabilities?

      # Authentication capabilities (e.g. `logout`).
      @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::AgentAuthCapabilities))]
      property auth : AgentAuthCapabilities?

      # Presence advertises draft provider configuration methods.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::ProvidersCapabilities))]
      property providers : ProvidersCapabilities?

      # Extension metadata for custom capabilities.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @load_session : Bool = false,
        @prompt_capabilities : PromptCapabilities? = nil,
        @mcp_capabilities : McpCapabilities? = nil,
        @session_capabilities : SessionCapabilities? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
        @auth : AgentAuthCapabilities? = nil,
        @providers : ProvidersCapabilities? = nil,
      )
      end
    end

    # ─── Info Structs ─────────────────────────────────────────────────

    # Metadata about the client, sent during `initialize`.
    # See: https://agentclientprotocol.com/protocol/initialization#implementation-information
    struct ClientInfo
      include JSON::Serializable

      # Intended for programmatic or logical use, but can be used as a
      # display name fallback if title isn't present.
      property name : String

      # Intended for UI and end-user contexts — optimized to be human-readable.
      # If not provided, the name should be used for display.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityString)]
      property title : String?

      # Version of the implementation.
      property version : String

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      def initialize(@name : String, @version : String, @title : String? = nil, @meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Metadata about the agent, returned in the `initialize` response.
    # See: https://agentclientprotocol.com/protocol/initialization#implementation-information
    struct AgentInfo
      include JSON::Serializable
      include LosslessMetadata
      include WireValueEquality

      # Intended for programmatic or logical use, but can be used as a
      # display name fallback if title isn't present.
      property name : String

      # Intended for UI and end-user contexts — optimized to be human-readable.
      # If not provided, the name should be used for display.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityString)]
      property title : String?

      # Version of the implementation.
      property version : String

      def initialize(@name : String, @version : String, @title : String? = nil, meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end

      # Returns the display-friendly name (title if available, otherwise name).
      def display_name : String
        @title || @name
      end
    end

    # ─── MCP Server References ───────────────────────────────────────

    # Environment variable to set when launching an MCP server.
    struct EnvVariable
      include JSON::Serializable

      # The name of the environment variable.
      property name : String

      # The value of the environment variable.
      property value : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@name : String, @value : String, @meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # HTTP header to set when making requests to an MCP server.
    struct HttpHeader
      include JSON::Serializable

      # The name of the HTTP header.
      property name : String

      # The value to set for the HTTP header.
      property value : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@name : String, @value : String, @meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Configuration for connecting to an MCP server via stdio transport.
    # All Agents MUST support this transport.
    # See: https://agentclientprotocol.com/protocol/session-setup#stdio-transport
    struct McpServerStdio
      include JSON::Serializable

      # Human-readable name identifying this MCP server.
      property name : String

      # Path to the MCP server executable.
      property command : String

      # Command-line arguments to pass to the MCP server.
      property args : Array(String) = [] of String

      # Environment variables to set when launching the MCP server.
      property env : Array(EnvVariable) = [] of EnvVariable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @name : String,
        @command : String,
        @args : Array(String) = [] of String,
        @env : Array(EnvVariable) = [] of EnvVariable,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Configuration for connecting to an MCP server via HTTP transport.
    # Only available when Agent capabilities indicate mcpCapabilities.http is true.
    # See: https://agentclientprotocol.com/protocol/session-setup#http-transport
    struct McpServerHttp
      include JSON::Serializable

      # Must be "http".
      @[JSON::Field(key: "type")]
      property transport_type : String = "http"

      # Human-readable name identifying this MCP server.
      property name : String

      # URL to the MCP server.
      property url : String

      # HTTP headers to set when making requests to the MCP server.
      property headers : Array(HttpHeader) = [] of HttpHeader

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @name : String,
        @url : String,
        @headers : Array(HttpHeader) = [] of HttpHeader,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @transport_type = "http"
      end
    end

    # Configuration for connecting to an MCP server via SSE transport.
    # Only available when Agent capabilities indicate mcpCapabilities.sse is true.
    # Note: SSE transport has been deprecated by the MCP spec.
    # See: https://agentclientprotocol.com/protocol/session-setup#sse-transport
    struct McpServerSse
      include JSON::Serializable

      # Must be "sse".
      @[JSON::Field(key: "type")]
      property transport_type : String = "sse"

      # Human-readable name identifying this MCP server.
      property name : String

      # URL of the SSE endpoint.
      property url : String

      # HTTP headers to set when establishing the SSE connection.
      property headers : Array(HttpHeader) = [] of HttpHeader

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @name : String,
        @url : String,
        @headers : Array(HttpHeader) = [] of HttpHeader,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @transport_type = "sse"
      end
    end

    # Union type representing all MCP server transport configurations.
    # Uses the "type" discriminator to determine transport kind; stdio
    # servers omit the type field (they are the default).
    #
    # For JSON deserialization, use `McpServer.from_json` which handles
    # the discriminator logic. For simplicity in Crystal, the type is
    # kept as a tagged union.
    #
    # See: https://agentclientprotocol.com/protocol/session-setup#transport-types
    alias McpServer = McpServerStdio | McpServerHttp | McpServerSse | McpServerAcp

    # Helper module for MCP server JSON parsing.
    module McpServerParser
      # Parses a JSON::Any value into the appropriate McpServer subtype.
      def self.from_json_any(value : JSON::Any) : McpServer
        transport_type = value.as_h?.try(&.["type"]?).try(&.as_s?)

        case transport_type
        when "http"
          McpServerHttp.from_json(value.to_json)
        when "sse"
          McpServerSse.from_json(value.to_json)
        when "acp"
          McpServerAcp.from_json(value.to_json)
        else
          # Default: stdio transport (no "type" field)
          McpServerStdio.from_json(value.to_json)
        end
      end

      # Parses a JSON array of MCP servers.
      def self.array_from_json(value : JSON::Any) : Array(McpServer)
        (value.as_a? || [] of JSON::Any).map { |item| from_json_any(item) }
      end
    end

    # ─── Auth Method ──────────────────────────────────────────────────

    # Describes an Agent-managed authentication method for `authenticate`.
    # See: https://agentclientprotocol.com/protocol/v1/authentication
    struct AuthMethod
      include JSON::Serializable
      include LosslessMetadata
      include WireValueEquality

      # Unique identifier for this authentication method.
      property id : String

      # Human-readable name of the authentication method.
      property name : String

      # Optional description providing more details.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityString)]
      property description : String?

      # Explicit wire type. Omission also selects Agent-managed authentication.
      @[JSON::Field(key: "type")]
      property method_type : String?

      def initialize(
        @id : String,
        @name : String,
        @description : String? = nil,
        meta : Hash(String, JSON::Any)? = nil,
        @method_type : String? = nil,
      )
        self.meta = meta
      end
    end

    # Describes login arguments and environment for the configured Agent program.
    struct TerminalAuthMethod
      include JSON::Serializable
      include LosslessMetadata
      include WireValueEquality

      # Always `terminal` for this flow.
      @[JSON::Field(key: "type", ignore_deserialize: true)]
      getter method_type : String = "terminal"

      # Unique identifier for this authentication method.
      property id : String

      # Human-readable name of the login flow.
      property name : String

      # Optional description providing more details.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityString)]
      property description : String?

      # Additional arguments for the configured Agent executable.
      property args : Array(String) = [] of String

      # Values to override in the configured Agent's environment.
      property env : Hash(String, String) = {} of String => String

      # Creates a terminal login descriptor.
      def initialize(
        @id : String,
        @name : String,
        @description : String? = nil,
        @args : Array(String) = [] of String,
        @env : Hash(String, String) = {} of String => String,
        meta : Hash(String, JSON::Any)? = nil,
      )
        self.meta = meta
      end
    end

    # The authentication methods supported by ACP v1.
    alias AuthenticationMethod = AuthMethod | TerminalAuthMethod

    # Parses the implemented authentication methods, skipping unknown wire types.
    def self.typed_auth_methods(methods : Array(JSON::Any)?) : Array(AuthenticationMethod)
      methods.try(&.compact_map { |value| typed_auth_method(RawJson.new(value)) }) || [] of AuthenticationMethod
    end

    # Parses the implemented authentication methods from exact JSON.
    def self.typed_auth_methods(methods : RawJson) : Array(AuthenticationMethod)
      methods.elements?.try(&.compact_map { |value| typed_auth_method(value) }) || [] of AuthenticationMethod
    end

    # Parses an implemented method with unambiguous identity and launch fields.
    def self.typed_auth_method(value : RawJson) : AuthenticationMethod?
      return unless value.field("id", unique: true).try(&.as_s?) && value.field("name", unique: true).try(&.as_s?)

      case value.field("type", unique: true).try(&.json)
      when nil, "null", %("agent")
        AuthMethod.from_json(value.json)
      when %("terminal")
        if WireFrame.repeated_members(value.json, "args", "env").empty?
          TerminalAuthMethod.from_json(value.json)
        end
      end
    rescue JSON::ParseException
      nil
    end
  end
end
