# ACP Protocol — Core Types
#
# Defines the JSON-RPC 2.0 message structures and all ACP method
# parameter / result types used by the client and agent.
#
# JSON-RPC 2.0 message kinds:
#   - Request:      {"jsonrpc":"2.0", "id": ..., "method": "...", "params": {...}}
#   - Response:     {"jsonrpc":"2.0", "id": ..., "result": {...}}
#   - Error Resp:   {"jsonrpc":"2.0", "id": ..., "error": {"code":..., "message":..., "data":...}}
#   - Notification: {"jsonrpc":"2.0", "method": "...", "params": {...}}
#
# IDs can be Int64 or String per JSON-RPC 2.0 spec.
#
# Reference: https://agentclientprotocol.com/protocol/schema

require "json"
require "./capabilities"
require "./content_block"
require "./updates"

module ACP
  module Protocol
    # Type alias for JSON-RPC message IDs (integer or string).
    alias RequestId = Int64 | String

    # ─── JSON-RPC 2.0 Core Structures ─────────────────────────────────

    # A JSON-RPC 2.0 error object, returned inside error responses.
    struct JsonRpcErrorObject
      include JSON::Serializable

      # Integer error code.
      property code : Int32

      # Human-readable error message.
      property message : String

      # Optional structured error data.
      property data : JSON::Any?

      def initialize(@code : Int32, @message : String, @data : JSON::Any? = nil)
      end
    end

    # Represents a raw incoming JSON-RPC message before it is classified.
    # We parse to JSON::Any first and then inspect the fields to determine
    # if it is a response, request (agent→client method), or notification.
    enum MessageKind
      # A response to a request we sent (has "id" and "result" or "error").
      Response

      # A method call from the agent that expects a response (has "id" and "method").
      Request

      # A one-way notification (has "method" but no "id").
      Notification
    end

    # Utility to classify a raw JSON::Any message into its kind.
    def self.classify_message(msg : JSON::Any) : MessageKind
      has_id = msg["id"]? && !msg["id"]?.try(&.raw).nil?
      has_method = msg["method"]?.try(&.as_s?)

      if has_id && has_method
        # Agent is calling a method on the client (e.g., session/request_permission).
        MessageKind::Request
      elsif has_id
        # Response to one of our outgoing requests.
        MessageKind::Response
      elsif has_method
        # Notification from the agent (e.g., session/update).
        MessageKind::Notification
      else
        # Malformed — treat as notification and let the handler deal with it.
        MessageKind::Notification
      end
    end

    # Extract the request ID from a raw JSON message. Returns nil if not present.
    # Handles both integer and string IDs.
    def self.extract_id(msg : JSON::Any) : RequestId?
      raw = msg["id"]?
      return unless raw
      case v = raw.raw
      when Int64  then v
      when String then v
      when Int32  then v.to_i64
      when Float64
        # JSON numbers without decimals may parse as float; coerce to Int64.
        v.to_i64
      else
        raw.to_s
      end
    end

    # ─── Initialize Method ────────────────────────────────────────────
    # See: https://agentclientprotocol.com/protocol/initialization

    # Params for the `initialize` method (Client → Agent).
    struct InitializeParams
      include JSON::Serializable

      # The ACP protocol version the client supports.
      @[JSON::Field(key: "protocolVersion")]
      property protocol_version : UInt16

      # Capabilities the client advertises to the agent.
      @[JSON::Field(key: "clientCapabilities")]
      property client_capabilities : ClientCapabilities

      # Metadata about the client application.
      # Note: in future versions of the protocol, this will be required.
      @[JSON::Field(key: "clientInfo")]
      property client_info : ClientInfo?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @protocol_version : UInt16,
        @client_capabilities : ClientCapabilities,
        @client_info : ClientInfo? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Result of the `initialize` method (Agent → Client).
    struct InitializeResult
      include JSON::Serializable

      # The ACP protocol version the agent supports.
      @[JSON::Field(key: "protocolVersion")]
      property protocol_version : UInt16

      # Capabilities the agent advertises to the client.
      @[JSON::Field(key: "agentCapabilities")]
      property agent_capabilities : AgentCapabilities

      # Authentication methods the agent supports.
      # If empty or nil, no authentication is required.
      @[JSON::Field(key: "authMethods")]
      property auth_methods : Array(JSON::Any)?

      # Metadata about the agent.
      # Note: in future versions of the protocol, this will be required.
      @[JSON::Field(key: "agentInfo")]
      property agent_info : AgentInfo?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @protocol_version : UInt16,
        @agent_capabilities : AgentCapabilities = AgentCapabilities.new,
        @auth_methods : Array(JSON::Any)? = nil,
        @agent_info : AgentInfo? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # ─── Authenticate Method ──────────────────────────────────────────
    # See: https://agentclientprotocol.com/protocol/initialization

    # Params for the `authenticate` method (Client → Agent).
    struct AuthenticateParams
      include JSON::Serializable

      # The authentication method ID to use (from the agent's authMethods list).
      @[JSON::Field(key: "methodId")]
      property method_id : String

      # Optional credentials or token data, depending on the auth method.
      property credentials : JSON::Any?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@method_id : String, @credentials : JSON::Any? = nil, @meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Result of the `authenticate` method. Empty object on success.
    struct AuthenticateResult
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # ─── Session/New Method ───────────────────────────────────────────
    # See: https://agentclientprotocol.com/protocol/session-setup#creating-a-session

    # Params for the `session/new` method (Client → Agent).
    struct SessionNewParams
      include JSON::Serializable

      # The current working directory (absolute path).
      property cwd : String

      # List of MCP servers the agent should connect to.
      # See: https://agentclientprotocol.com/protocol/session-setup#mcp-servers
      @[JSON::Field(key: "mcpServers")]
      property mcp_servers : Array(JSON::Any) = [] of JSON::Any

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @cwd : String,
        @mcp_servers : Array(JSON::Any) = [] of JSON::Any,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end

      # Convenience constructor that accepts typed McpServer values.
      def self.new(cwd : String, mcp_servers : Array(McpServer), meta : Hash(String, JSON::Any)? = nil)
        json_servers = mcp_servers.map do |server|
          case server
          when McpServerStdio
            JSON.parse(server.to_json)
          when McpServerHttp
            JSON.parse(server.to_json)
          when McpServerSse
            JSON.parse(server.to_json)
          else
            JSON::Any.new(nil)
          end
        end
        inst = allocate
        inst.initialize(cwd: cwd, mcp_servers: json_servers, meta: meta)
        inst
      end
    end

    # ─── Session Mode Types ───────────────────────────────────────────
    # See: https://agentclientprotocol.com/protocol/session-modes

    # A mode the agent can operate in.
    struct SessionMode
      include JSON::Serializable

      # Unique identifier for this mode (required).
      property id : String

      # Human-readable name of the mode (required).
      property name : String

      # Optional description providing more details about what this mode does.
      property description : String?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@id : String, @name : String, @description : String? = nil, @meta : Hash(String, JSON::Any)? = nil)
      end

      # Backward-compatible alias for `name`.
      def label : String
        @name
      end
    end

    # Backward-compatible alias.
    alias ModeOption = SessionMode

    # The set of modes and the one currently active.
    struct SessionModeState
      include JSON::Serializable

      # The current mode the Agent is in.
      @[JSON::Field(key: "currentModeId")]
      property current_mode_id : String

      # The set of modes that the Agent can operate in.
      @[JSON::Field(key: "availableModes")]
      property available_modes : Array(SessionMode)

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @current_mode_id : String,
        @available_modes : Array(SessionMode) = [] of SessionMode,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # ─── Session Config Option Types ──────────────────────────────────
    # See: https://agentclientprotocol.com/protocol/session-config-options

    # A possible value for a session configuration option.
    # Matches the Rust SDK's `SessionConfigSelectOption`.
    struct ConfigOptionValue
      include JSON::Serializable

      # Unique identifier for this option value (required).
      # Maps to the Rust SDK's `SessionConfigValueId`.
      property value : String

      # Human-readable label for this option value (required).
      property name : String

      # Optional description for this option value.
      property description : String?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @value : String,
        @name : String,
        @description : String? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Backward-compatible alias.
    alias SessionConfigSelectOption = ConfigOptionValue

    # A group of possible values for a session configuration option.
    # Matches the Rust SDK's `SessionConfigSelectGroup`.
    # Groups allow organizing option values into logical sections
    # (e.g., grouping models by provider).
    # See: https://agentclientprotocol.com/protocol/session-config-options
    struct ConfigOptionGroup
      include JSON::Serializable

      # Unique identifier for this group (required).
      # Maps to the Rust SDK's `SessionConfigGroupId`.
      property id : String

      # Human-readable label for this group (required).
      property name : String

      # The values in this group (required).
      property options : Array(ConfigOptionValue)

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @id : String,
        @name : String,
        @options : Array(ConfigOptionValue) = [] of ConfigOptionValue,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Backward-compatible alias.
    alias SessionConfigSelectGroup = ConfigOptionGroup

    # A single session configuration option and its current state.
    # Matches the Rust SDK's `SessionConfigOption` + `SessionConfigSelect`.
    # See: https://agentclientprotocol.com/protocol/session-config-options#configoption
    struct ConfigOption
      include JSON::Serializable

      # Unique identifier for this config option (required).
      # Maps to the Rust SDK's `SessionConfigId`.
      property id : String

      # Human-readable label (required).
      property name : String

      # Optional description providing more details.
      property description : String?

      # Optional semantic category to help Clients provide consistent UX.
      # Reserved categories: "mode", "model", "thought_level".
      # Names beginning with `_` are free for custom use.
      # See: https://agentclientprotocol.com/protocol/session-config-options#option-categories
      property category : String?

      # The type of input control (required). Currently only "select" is supported.
      # Maps to the Rust SDK's `SessionConfigKind`.
      @[JSON::Field(key: "type")]
      property config_type : String = "select"

      # The currently selected value (required).
      # Maps to the Rust SDK's `SessionConfigSelect.current_value`.
      @[JSON::Field(key: "currentValue")]
      property current_value : String?

      # Flat list of available values for this option.
      # Used when options are not grouped. Maps to the Rust SDK's
      # `SessionConfigSelectOptions::Flat`.
      property options : Array(ConfigOptionValue)?

      # Grouped list of available values for this option.
      # Used when options are organized into logical sections (e.g., by provider).
      # Maps to the Rust SDK's `SessionConfigSelectOptions::Grouped`.
      property groups : Array(ConfigOptionGroup)?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @id : String,
        @name : String,
        @config_type : String = "select",
        @current_value : String? = nil,
        @options : Array(ConfigOptionValue)? = nil,
        @groups : Array(ConfigOptionGroup)? = nil,
        @description : String? = nil,
        @category : String? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end

      # Backward-compatible alias for `name`.
      def label : String
        @name
      end

      # Backward-compatible alias for `current_value`.
      def value : String?
        @current_value
      end

      # Returns true if this option uses grouped values.
      def grouped? : Bool
        !@groups.nil? && !@groups.try(&.empty?)
      end

      # Returns all option values across all groups (flattened).
      # If the option has flat `options`, returns those.
      # If the option has `groups`, returns all values from all groups.
      def all_values : Array(ConfigOptionValue)
        if opts = @options
          opts
        elsif grps = @groups
          grps.flat_map(&.options)
        else
          [] of ConfigOptionValue
        end
      end
    end

    # Backward-compatible alias.
    alias SessionConfigOption = ConfigOption

    # ─── Session/New Result ───────────────────────────────────────────

    # Result of the `session/new` method (Agent → Client).
    struct SessionNewResult
      include JSON::Serializable

      # The unique session identifier assigned by the agent (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # Initial mode state if supported by the Agent.
      # See: https://agentclientprotocol.com/protocol/session-modes
      property modes : SessionModeState?

      # Initial session configuration options if supported by the Agent.
      # See: https://agentclientprotocol.com/protocol/session-config-options
      @[JSON::Field(key: "configOptions")]
      property config_options : Array(ConfigOption)?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @session_id : String,
        @modes : SessionModeState? = nil,
        @config_options : Array(ConfigOption)? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # ─── Session/Load Method ──────────────────────────────────────────
    # See: https://agentclientprotocol.com/protocol/session-setup#loading-sessions

    # Params for the `session/load` method (Client → Agent).
    struct SessionLoadParams
      include JSON::Serializable

      # The session ID to load/resume (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The current working directory (absolute path) (required).
      property cwd : String

      # List of MCP servers the agent should connect to (required).
      @[JSON::Field(key: "mcpServers")]
      property mcp_servers : Array(JSON::Any) = [] of JSON::Any

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @session_id : String,
        @cwd : String,
        @mcp_servers : Array(JSON::Any) = [] of JSON::Any,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Result of the `session/load` method. Contains mode/config state
    # but NOT a sessionId (unlike session/new).
    struct SessionLoadResult
      include JSON::Serializable

      # Mode state if supported by the Agent.
      property modes : SessionModeState?

      # Session configuration options if supported by the Agent.
      @[JSON::Field(key: "configOptions")]
      property config_options : Array(ConfigOption)?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @modes : SessionModeState? = nil,
        @config_options : Array(ConfigOption)? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end

      # Backward-compatible: return a provided session_id or empty string.
      # (session/load doesn't return a sessionId in the ACP spec,
      # so this is for code that expects it.)
      def session_id : String
        ""
      end
    end

    # ─── Session/Prompt Method ────────────────────────────────────────
    # See: https://agentclientprotocol.com/protocol/prompt-turn

    # Params for the `session/prompt` method (Client → Agent).
    struct SessionPromptParams
      include JSON::Serializable

      # The session to send the prompt to (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The prompt content as an array of content blocks (required).
      # As a baseline, the Agent MUST support ContentBlock::Text and
      # ContentBlock::ResourceLink. Other types require capabilities.
      property prompt : Array(ContentBlock)

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@session_id : String, @prompt : Array(ContentBlock), @meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Result of the `session/prompt` method (Agent → Client).
    # See: https://agentclientprotocol.com/protocol/prompt-turn#stop-reasons
    struct SessionPromptResult
      include JSON::Serializable

      # Reason the agent stopped generating (required).
      # Values: "end_turn", "max_tokens", "max_turn_requests",
      #         "refusal", "cancelled"
      @[JSON::Field(key: "stopReason")]
      property stop_reason : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@stop_reason : String, @meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # ─── Session/Cancel Notification ──────────────────────────────────
    # See: https://agentclientprotocol.com/protocol/prompt-turn#cancellation

    # Params for the `session/cancel` notification (Client → Agent).
    struct SessionCancelParams
      include JSON::Serializable

      # The session to cancel the current operation for (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@session_id : String, @meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # ─── Session/SetMode Method ───────────────────────────────────────
    # See: https://agentclientprotocol.com/protocol/session-modes#from-the-client

    # Params for the `session/set_mode` method (Client → Agent).
    struct SessionSetModeParams
      include JSON::Serializable

      # The session to change the mode for (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The mode ID to switch to (required). Must be one of the modes
      # listed in availableModes.
      @[JSON::Field(key: "modeId")]
      property mode_id : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@session_id : String, @mode_id : String, @meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Result of the `session/set_mode` method. Empty on success.
    struct SessionSetModeResult
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # ─── Session/SetConfigOption Method ───────────────────────────────
    # See: https://agentclientprotocol.com/protocol/session-config-options#from-the-client

    # Params for the `session/set_config_option` method (Client → Agent).
    struct SessionSetConfigOptionParams
      include JSON::Serializable

      # The session to set the config option for (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The ID of the configuration option to change (required).
      @[JSON::Field(key: "configId")]
      property config_id : String

      # The new value to set (required). Must be one of the values
      # listed in the option's options array.
      property value : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @session_id : String,
        @config_id : String,
        @value : String,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Result of the `session/set_config_option` method (Agent → Client).
    # The response always contains the complete configuration state.
    struct SessionSetConfigOptionResult
      include JSON::Serializable

      # The full set of configuration options and their current values (required).
      @[JSON::Field(key: "configOptions")]
      property config_options : Array(ConfigOption)

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @config_options : Array(ConfigOption) = [] of ConfigOption,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # ─── Session/RequestPermission (Agent → Client) ───────────────────
    # See: https://agentclientprotocol.com/protocol/tool-calls#requesting-permission

    # A single permission option the client can choose from.
    # See: https://agentclientprotocol.com/protocol/tool-calls#permission-options
    struct PermissionOption
      include JSON::Serializable

      # Unique identifier for this option (required).
      @[JSON::Field(key: "optionId")]
      property option_id : String

      # Human-readable label to display to the user (required).
      property name : String

      # Hint about the nature of this permission option (required).
      # Values: "allow_once", "allow_always", "reject_once", "reject_always"
      property kind : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @option_id : String,
        @name : String,
        @kind : String = "allow_once",
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end

      # Backward-compatible alias: `id` maps to `option_id`.
      def id : String
        @option_id
      end

      # Backward-compatible alias: `label` maps to `name`.
      def label : String
        @name
      end
    end

    # Describes the tool call that triggered the permission request.
    # This is a ToolCallUpdate-like object.
    # See: https://agentclientprotocol.com/protocol/tool-calls#requesting-permission
    struct ToolCallInfo
      include JSON::Serializable

      # The unique ID of the tool call.
      @[JSON::Field(key: "toolCallId")]
      property tool_call_id : String?

      # Human-readable title or summary of the tool call.
      property title : String?

      # The category of tool being invoked.
      property kind : String?

      # Current execution status.
      property status : String?

      # Content produced by the tool call.
      property content : Array(JSON::Any)?

      # The name of the tool being invoked (backward compat).
      @[JSON::Field(key: "toolName")]
      property tool_name : String?

      # The input/arguments to the tool call.
      property input : JSON::Any?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @tool_call_id : String? = nil,
        @title : String? = nil,
        @kind : String? = nil,
        @status : String? = nil,
        @content : Array(JSON::Any)? = nil,
        @tool_name : String? = nil,
        @input : JSON::Any? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Params for `session/request_permission` (Agent → Client).
    # The agent asks the client (user) for permission to perform an action.
    struct RequestPermissionParams
      include JSON::Serializable

      # The session this permission request belongs to (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # Information about the tool call requesting permission (required).
      @[JSON::Field(key: "toolCall")]
      property tool_call : ToolCallInfo

      # The options the user can choose from (required).
      property options : Array(PermissionOption)

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @session_id : String,
        @tool_call : ToolCallInfo,
        @options : Array(PermissionOption),
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # The outcome when the user selected one of the provided options.
    struct SelectedPermissionOutcome
      include JSON::Serializable

      # Must be "selected".
      property outcome : String = "selected"

      # The ID of the option the user selected (required).
      @[JSON::Field(key: "optionId")]
      property option_id : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @option_id : String,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @outcome = "selected"
      end
    end

    # The outcome when the prompt turn was cancelled.
    struct CancelledPermissionOutcome
      include JSON::Serializable

      # Must be "cancelled".
      property outcome : String = "cancelled"

      def initialize
        @outcome = "cancelled"
      end
    end

    # Result of `session/request_permission` (Client → Agent).
    # See: https://agentclientprotocol.com/protocol/tool-calls#requesting-permission
    struct RequestPermissionResult
      include JSON::Serializable

      # The user's decision on the permission request (required).
      # Either a SelectedPermissionOutcome or CancelledPermissionOutcome,
      # serialized as a JSON object.
      property outcome : JSON::Any

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@outcome : JSON::Any, @meta : Hash(String, JSON::Any)? = nil)
      end

      # Creates a "selected" outcome result.
      def self.selected(option_id : String) : RequestPermissionResult
        outcome_hash = Hash(String, JSON::Any).new
        outcome_hash["outcome"] = JSON::Any.new("selected")
        outcome_hash["optionId"] = JSON::Any.new(option_id)
        new(outcome: JSON::Any.new(outcome_hash))
      end

      # Creates a "cancelled" outcome result.
      def self.cancelled : RequestPermissionResult
        outcome_hash = Hash(String, JSON::Any).new
        outcome_hash["outcome"] = JSON::Any.new("cancelled")
        new(outcome: JSON::Any.new(outcome_hash))
      end

      # Returns true if the outcome was "cancelled".
      def cancelled? : Bool
        if h = @outcome.as_h?
          h["outcome"]?.try(&.as_s?) == "cancelled"
        elsif s = @outcome.as_s?
          s == "cancelled"
        else
          false
        end
      end

      # Returns the selected option ID, or nil if cancelled.
      def selected_option_id : String?
        if h = @outcome.as_h?
          return if h["outcome"]?.try(&.as_s?) == "cancelled"
          h["optionId"]?.try(&.as_s?)
        end
      end

      # Backward-compatible: returns the selected option ID as a string.
      def selected : String?
        selected_option_id
      end
    end

    # ─── Extension Types ──────────────────────────────────────────────
    # Extension methods provide a way to add custom functionality while
    # maintaining protocol compatibility. Extension method names are
    # prefixed with `_` on the wire.
    # See: https://agentclientprotocol.com/protocol/extensibility

    # Allows for sending an arbitrary request that is not part of the
    # ACP spec. The `method` field is the custom method name WITHOUT
    # the `_` prefix (the prefix is added automatically on the wire).
    struct ExtRequest
      include JSON::Serializable

      # The custom method name (without the `_` prefix).
      @[JSON::Field(ignore: true)]
      property method : String = ""

      # The request parameters as raw JSON.
      property params : JSON::Any

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @method : String,
        @params : JSON::Any = JSON::Any.new(nil),
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Response to an `ExtRequest`.
    struct ExtResponse
      include JSON::Serializable

      # The response data as raw JSON.
      property result : JSON::Any

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @result : JSON::Any = JSON::Any.new(nil),
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Allows for sending an arbitrary one-way notification that is not
    # part of the ACP spec. The `method` field is the custom method name
    # WITHOUT the `_` prefix.
    struct ExtNotification
      include JSON::Serializable

      # The custom method name (without the `_` prefix).
      @[JSON::Field(ignore: true)]
      property method : String = ""

      # The notification parameters as raw JSON.
      property params : JSON::Any

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @method : String,
        @params : JSON::Any = JSON::Any.new(nil),
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # ─── Utility: Build JSON-RPC Messages ─────────────────────────────

    # Creates a new JSON-RPC 2.0 message hash with the "jsonrpc" field set.
    private def self.new_message : Hash(String, JSON::Any)
      msg = Hash(String, JSON::Any).new
      msg["jsonrpc"] = JSON::Any.new("2.0")
      msg
    end

    # Sets the "id" field on a JSON-RPC message hash from a RequestId
    # (which may be Int64 or String).
    private def self.set_id(msg : Hash(String, JSON::Any), id : RequestId) : Nil
      case id
      when Int64
        msg["id"] = JSON::Any.new(id)
      when String
        msg["id"] = JSON::Any.new(id)
      end
    end

    # Builds a JSON-RPC 2.0 request object as a Hash for serialization.
    def self.build_request(id : RequestId, method : String, params : JSON::Serializable) : Hash(String, JSON::Any)
      msg = new_message
      set_id(msg, id)
      msg["method"] = JSON::Any.new(method)
      msg["params"] = JSON.parse(params.to_json)
      msg
    end

    # Builds a JSON-RPC 2.0 request with raw JSON::Any params.
    def self.build_request_raw(id : RequestId, method : String, params : JSON::Any) : Hash(String, JSON::Any)
      msg = new_message
      set_id(msg, id)
      msg["method"] = JSON::Any.new(method)
      msg["params"] = params
      msg
    end

    # Builds a JSON-RPC 2.0 notification (no "id" field).
    def self.build_notification(method : String, params : JSON::Serializable) : Hash(String, JSON::Any)
      msg = new_message
      msg["method"] = JSON::Any.new(method)
      msg["params"] = JSON.parse(params.to_json)
      msg
    end

    # Builds a JSON-RPC 2.0 notification with raw JSON::Any params.
    def self.build_notification_raw(method : String, params : JSON::Any) : Hash(String, JSON::Any)
      msg = new_message
      msg["method"] = JSON::Any.new(method)
      msg["params"] = params
      msg
    end

    # Builds a JSON-RPC 2.0 success response.
    def self.build_response(id : RequestId, result : JSON::Serializable) : Hash(String, JSON::Any)
      msg = new_message
      set_id(msg, id)
      msg["result"] = JSON.parse(result.to_json)
      msg
    end

    # Builds a JSON-RPC 2.0 success response with raw JSON::Any result.
    def self.build_response_raw(id : RequestId, result : JSON::Any) : Hash(String, JSON::Any)
      msg = new_message
      set_id(msg, id)
      msg["result"] = result
      msg
    end

    # Builds a JSON-RPC 2.0 error response.
    def self.build_error_response(id : RequestId, code : Int32, message : String, data : JSON::Any? = nil) : Hash(String, JSON::Any)
      error_obj = Hash(String, JSON::Any).new
      error_obj["code"] = JSON::Any.new(code.to_i64)
      error_obj["message"] = JSON::Any.new(message)
      if d = data
        error_obj["data"] = d
      end

      msg = new_message
      set_id(msg, id)
      msg["error"] = JSON::Any.new(error_obj)
      msg
    end
  end
end
