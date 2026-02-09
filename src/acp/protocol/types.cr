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
      return nil unless raw
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
      @[JSON::Field(key: "clientInfo")]
      property client_info : ClientInfo

      def initialize(
        @protocol_version : UInt16,
        @client_capabilities : ClientCapabilities,
        @client_info : ClientInfo,
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
      property auth_methods : Array(String)?

      # Metadata about the agent.
      @[JSON::Field(key: "agentInfo")]
      property agent_info : AgentInfo?

      def initialize(
        @protocol_version : UInt16,
        @agent_capabilities : AgentCapabilities = AgentCapabilities.new,
        @auth_methods : Array(String)? = nil,
        @agent_info : AgentInfo? = nil,
      )
      end
    end

    # ─── Authenticate Method ──────────────────────────────────────────

    # Params for the `authenticate` method (Client → Agent).
    struct AuthenticateParams
      include JSON::Serializable

      # The authentication method ID to use (from the agent's authMethods list).
      @[JSON::Field(key: "methodId")]
      property method_id : String

      # Optional credentials or token data, depending on the auth method.
      property credentials : JSON::Any?

      def initialize(@method_id : String, @credentials : JSON::Any? = nil)
      end
    end

    # Result of the `authenticate` method. Empty object on success.
    struct AuthenticateResult
      include JSON::Serializable

      def initialize
      end
    end

    # ─── Session/New Method ───────────────────────────────────────────

    # Params for the `session/new` method (Client → Agent).
    struct SessionNewParams
      include JSON::Serializable

      # The current working directory (absolute path).
      property cwd : String

      # Optional list of MCP servers the agent should connect to.
      @[JSON::Field(key: "mcpServers")]
      property mcp_servers : Array(McpServer)?

      def initialize(
        @cwd : String,
        @mcp_servers : Array(McpServer)? = nil,
      )
      end
    end

    # A single mode option that the agent supports.
    struct ModeOption
      include JSON::Serializable

      # Unique identifier for this mode.
      property id : String

      # Human-readable label for this mode.
      property label : String

      # Human-readable description of what this mode does.
      property description : String?

      def initialize(@id : String, @label : String, @description : String? = nil)
      end
    end

    # A single config option that the agent supports.
    struct ConfigOption
      include JSON::Serializable

      # Unique identifier for this config option.
      property id : String

      # Human-readable label.
      property label : String

      # The type of this config option (e.g., "boolean", "string", "enum").
      @[JSON::Field(key: "type")]
      property config_type : String?

      # The current/default value.
      property value : JSON::Any?

      # For enum-type options, the allowed values.
      property options : Array(JSON::Any)?

      # Human-readable description.
      property description : String?

      def initialize(
        @id : String,
        @label : String,
        @config_type : String? = nil,
        @value : JSON::Any? = nil,
        @options : Array(JSON::Any)? = nil,
        @description : String? = nil,
      )
      end
    end

    # Result of the `session/new` method (Agent → Client).
    struct SessionNewResult
      include JSON::Serializable

      # The unique session identifier assigned by the agent.
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # Optional modes the agent supports for this session.
      property modes : Array(ModeOption)?

      # Optional config options the agent exposes for this session.
      @[JSON::Field(key: "configOptions")]
      property config_options : Array(ConfigOption)?

      def initialize(
        @session_id : String,
        @modes : Array(ModeOption)? = nil,
        @config_options : Array(ConfigOption)? = nil,
      )
      end
    end

    # ─── Session/Load Method ──────────────────────────────────────────

    # Params for the `session/load` method (Client → Agent).
    struct SessionLoadParams
      include JSON::Serializable

      # The session ID to load/resume.
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The current working directory (absolute path).
      property cwd : String?

      def initialize(@session_id : String, @cwd : String? = nil)
      end
    end

    # Result of the `session/load` method. Same shape as session/new result.
    alias SessionLoadResult = SessionNewResult

    # ─── Session/Prompt Method ────────────────────────────────────────

    # Params for the `session/prompt` method (Client → Agent).
    struct SessionPromptParams
      include JSON::Serializable

      # The session to send the prompt to.
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The prompt content as an array of content blocks.
      property prompt : Array(ContentBlock)

      def initialize(@session_id : String, @prompt : Array(ContentBlock))
      end
    end

    # Result of the `session/prompt` method (Agent → Client).
    struct SessionPromptResult
      include JSON::Serializable

      # Reason the agent stopped generating.
      # Possible values: "end_turn", "max_tokens", "refusal", "cancelled", etc.
      @[JSON::Field(key: "stopReason")]
      property stop_reason : String

      def initialize(@stop_reason : String)
      end
    end

    # ─── Session/Cancel Notification ──────────────────────────────────

    # Params for the `session/cancel` notification (Client → Agent).
    struct SessionCancelParams
      include JSON::Serializable

      # The session to cancel the current operation for.
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      def initialize(@session_id : String)
      end
    end

    # ─── Session/SetMode Method ───────────────────────────────────────

    # Params for the `session/set_mode` method (Client → Agent).
    struct SessionSetModeParams
      include JSON::Serializable

      # The session to change the mode for.
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The mode ID to switch to.
      @[JSON::Field(key: "modeId")]
      property mode_id : String

      def initialize(@session_id : String, @mode_id : String)
      end
    end

    # Result of the `session/set_mode` method. Empty on success.
    struct SessionSetModeResult
      include JSON::Serializable

      def initialize
      end
    end

    # ─── Session/RequestPermission (Agent → Client) ───────────────────

    # A single permission option the client can choose from.
    struct PermissionOption
      include JSON::Serializable

      # Unique identifier for this option (e.g., "allow_once", "allow_always", "deny").
      property id : String

      # Human-readable label for this option.
      property label : String

      def initialize(@id : String, @label : String)
      end
    end

    # Describes the tool call that triggered the permission request.
    struct ToolCallInfo
      include JSON::Serializable

      # The unique ID of the tool call.
      @[JSON::Field(key: "toolCallId")]
      property tool_call_id : String?

      # Human-readable title or summary of the tool call.
      property title : String?

      # The name of the tool being invoked.
      @[JSON::Field(key: "toolName")]
      property tool_name : String?

      # The input/arguments to the tool call.
      property input : JSON::Any?

      def initialize(
        @tool_call_id : String? = nil,
        @title : String? = nil,
        @tool_name : String? = nil,
        @input : JSON::Any? = nil,
      )
      end
    end

    # Params for `session/request_permission` (Agent → Client).
    # The agent asks the client (user) for permission to perform an action.
    struct RequestPermissionParams
      include JSON::Serializable

      # The session this permission request belongs to.
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # Information about the tool call requesting permission.
      @[JSON::Field(key: "toolCall")]
      property tool_call : ToolCallInfo

      # The options the user can choose from.
      property options : Array(PermissionOption)

      def initialize(
        @session_id : String,
        @tool_call : ToolCallInfo,
        @options : Array(PermissionOption),
      )
      end
    end

    # The outcome chosen by the user for a permission request.
    struct PermissionOutcome
      include JSON::Serializable

      # The ID of the selected option (e.g., "allow_once").
      property selected : String

      def initialize(@selected : String)
      end
    end

    # Result of `session/request_permission` (Client → Agent).
    struct RequestPermissionResult
      include JSON::Serializable

      # The user's chosen outcome. Nil or a special value indicates cancellation.
      property outcome : PermissionOutcome | String

      def initialize(@outcome : PermissionOutcome | String)
      end
    end

    # ─── Utility: Build JSON-RPC Messages ─────────────────────────────

    # Builds a JSON-RPC 2.0 request object as a Hash for serialization.
    def self.build_request(id : RequestId, method : String, params : JSON::Serializable) : Hash(String, JSON::Any)
      msg = Hash(String, JSON::Any).new
      msg["jsonrpc"] = JSON::Any.new("2.0")
      case id
      when Int64
        msg["id"] = JSON::Any.new(id)
      when String
        msg["id"] = JSON::Any.new(id)
      end
      msg["method"] = JSON::Any.new(method)
      msg["params"] = JSON.parse(params.to_json)
      msg
    end

    # Builds a JSON-RPC 2.0 request with raw JSON::Any params.
    def self.build_request_raw(id : RequestId, method : String, params : JSON::Any) : Hash(String, JSON::Any)
      msg = Hash(String, JSON::Any).new
      msg["jsonrpc"] = JSON::Any.new("2.0")
      case id
      when Int64
        msg["id"] = JSON::Any.new(id)
      when String
        msg["id"] = JSON::Any.new(id)
      end
      msg["method"] = JSON::Any.new(method)
      msg["params"] = params
      msg
    end

    # Builds a JSON-RPC 2.0 notification (no "id" field).
    def self.build_notification(method : String, params : JSON::Serializable) : Hash(String, JSON::Any)
      msg = Hash(String, JSON::Any).new
      msg["jsonrpc"] = JSON::Any.new("2.0")
      msg["method"] = JSON::Any.new(method)
      msg["params"] = JSON.parse(params.to_json)
      msg
    end

    # Builds a JSON-RPC 2.0 success response.
    def self.build_response(id : RequestId, result : JSON::Serializable) : Hash(String, JSON::Any)
      msg = Hash(String, JSON::Any).new
      msg["jsonrpc"] = JSON::Any.new("2.0")
      case id
      when Int64
        msg["id"] = JSON::Any.new(id)
      when String
        msg["id"] = JSON::Any.new(id)
      end
      msg["result"] = JSON.parse(result.to_json)
      msg
    end

    # Builds a JSON-RPC 2.0 success response with raw JSON::Any result.
    def self.build_response_raw(id : RequestId, result : JSON::Any) : Hash(String, JSON::Any)
      msg = Hash(String, JSON::Any).new
      msg["jsonrpc"] = JSON::Any.new("2.0")
      case id
      when Int64
        msg["id"] = JSON::Any.new(id)
      when String
        msg["id"] = JSON::Any.new(id)
      end
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

      msg = Hash(String, JSON::Any).new
      msg["jsonrpc"] = JSON::Any.new("2.0")
      case id
      when Int64
        msg["id"] = JSON::Any.new(id)
      when String
        msg["id"] = JSON::Any.new(id)
      end
      msg["error"] = JSON::Any.new(error_obj)
      msg
    end
  end
end
