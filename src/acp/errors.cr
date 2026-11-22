# ACP Error Types
#
# Custom exceptions for ACP protocol errors, transport failures,
# and JSON-RPC 2.0 standard error codes.

require "./protocol/raw_json"

module ACP
  # Base error for all ACP-related exceptions.
  class Error < Exception
  end

  # ─── Transport Errors ───────────────────────────────────────────────

  # Raised when the underlying transport (stdio, websocket, etc.) fails.
  class TransportError < Error
  end

  # Raised when the transport connection is closed unexpectedly.
  class ConnectionClosedError < TransportError
    def initialize(message : String = "Connection closed")
      super(message)
    end
  end

  # Raised when reading from or writing to the transport times out.
  class TransportTimeoutError < TransportError
    def initialize(message : String = "Transport operation timed out")
      super(message)
    end
  end

  # Raised before writing an outgoing frame that exceeds the transport's limit.
  class FrameTooLargeError < TransportError
  end

  # ─── Protocol Errors ───────────────────────────────────────────────

  # Raised on protocol-level issues (version mismatch, bad handshake, etc.)
  class ProtocolError < Error
  end

  # Raised when the agent reports an incompatible protocol version.
  class VersionMismatchError < ProtocolError
    getter client_version : UInt16
    getter agent_version : UInt16?

    def initialize(@client_version : UInt16, @agent_version : UInt16? = nil)
      agent_str = @agent_version.try(&.to_s) || "unknown"
      super("Protocol version mismatch: client=#{@client_version}, agent=#{agent_str}")
    end
  end

  # Raised when the client is not in the expected state for an operation
  # (e.g., sending a prompt before initialization).
  class InvalidStateError < ProtocolError
    def initialize(message : String = "Invalid client state for this operation")
      super(message)
    end
  end

  # ─── JSON-RPC 2.0 Errors ───────────────────────────────────────────

  # Represents a JSON-RPC 2.0 error returned by the agent.
  # See: https://www.jsonrpc.org/specification#error_object
  class JsonRpcError < Error
    # Standard JSON-RPC 2.0 error codes
    PARSE_ERROR      = -32700
    INVALID_REQUEST  = -32600
    METHOD_NOT_FOUND = -32601
    INVALID_PARAMS   = -32602
    INTERNAL_ERROR   = -32603

    # Errors in the outer MCP-over-ACP binding.
    MCP_RESOURCE_LIMIT     = -33000
    MCP_SERVER_UNAVAILABLE = -33001
    MCP_BACKEND_FAILURE    = -33002

    # JSON-RPC 2.0 reserved range for server errors: -32000 to -32099
    SERVER_ERROR_START = -32099
    SERVER_ERROR_END   = -32000

    # The peer stopped processing a request because it was cancelled.
    # Part of the JSON-RPC implementation-defined range reserved by ACP.
    REQUEST_CANCELLED = -32800

    # ACP-specific error codes (reserved range -32000 to -32099).
    # See: https://agentclientprotocol.com/protocol/schema#errorcode

    # Authentication is required before this operation can be performed.
    AUTH_REQUIRED = -32000

    # A given resource, such as a file, was not found.
    RESOURCE_NOT_FOUND = -32002

    # The agent could not select a compatible ACP protocol version.
    UNSUPPORTED_PROTOCOL_VERSION = -32022

    # The integer error code.
    getter code : Int32

    @data_wire : Protocol::PreservedJson?

    # Optional error data representable as JSON::Any.
    def data : JSON::Any?
      @data_wire.try(&.value)
    end

    # Exact JSON data attached to the error, including wide numbers.
    def data_raw : Protocol::RawJson?
      @data_wire.try(&.raw)
    end

    # True when this error was decoded from a peer's structured error response.
    getter? received : Bool

    # Creates a JSON-RPC error with optional data.
    def initialize(@code : Int32, message : String, data : JSON::Any? = nil, @received : Bool = false)
      @data_wire = data.try { |value| Protocol::PreservedJson.new(value) }
      super(message)
    end

    private def initialize(@code : Int32, message : String, *, @data_wire : Protocol::PreservedJson?, @received : Bool)
      super(message)
    end

    # Returns true if this is a standard JSON-RPC parse error.
    def parse_error? : Bool
      @code == PARSE_ERROR
    end

    # Returns true if this is a standard JSON-RPC invalid request error.
    def invalid_request? : Bool
      @code == INVALID_REQUEST
    end

    # Returns true if this is a standard JSON-RPC method-not-found error.
    def method_not_found? : Bool
      @code == METHOD_NOT_FOUND
    end

    # Returns true if this is a standard JSON-RPC invalid params error.
    def invalid_params? : Bool
      @code == INVALID_PARAMS
    end

    # Returns true if this is a standard JSON-RPC internal error.
    def internal_error? : Bool
      @code == INTERNAL_ERROR
    end

    # Returns true if the error code falls in the server-defined range.
    def server_error? : Bool
      @code >= SERVER_ERROR_START && @code <= SERVER_ERROR_END
    end

    # Returns true if the peer reported the request as cancelled.
    def request_cancelled? : Bool
      @code == REQUEST_CANCELLED
    end

    # Returns true if this is an ACP authentication-required error.
    def auth_required? : Bool
      @code == AUTH_REQUIRED
    end

    # Returns true if this is an ACP resource-not-found error.
    def resource_not_found? : Bool
      @code == RESOURCE_NOT_FOUND
    end

    # Returns true if negotiation failed to select a compatible ACP version.
    def unsupported_protocol_version? : Bool
      @code == UNSUPPORTED_PROTOCOL_VERSION
    end

    # Builds a human-readable representation including the code.
    def to_s(io : IO) : Nil
      io << "JsonRpcError(#{@code}): #{message}"
      if d = data
        io << " data=#{d.to_json}"
      end
    end

    # Constructs a `JsonRpcError` from a raw `JSON::Any` error object.
    # Expects the object to have "code" (int) and "message" (string) keys,
    # with an optional "data" key.
    def self.from_json_any(obj : JSON::Any) : JsonRpcError
      code = int32_code(obj["code"]?.try(&.as_i64?)) || INTERNAL_ERROR
      message = obj["message"]?.try(&.as_s?) || "Unknown error"
      new(code, message, obj["data"]?, received: true)
    end

    # Reads a structured error while retaining the exact data payload.
    # :nodoc:
    def self.from_wire(error : Protocol::RawJson) : self
      code = int32_code(error.field("code").try(&.as_i64?)) || INTERNAL_ERROR
      message = error.field("message").try(&.as_s?) || "Unknown error"
      data = error.field("data").try { |wire| Protocol::PreservedJson.new(wire, project_object_members: true) }
      new(code, message, data_wire: data, received: true)
    end

    # Returns the error code if it fits the ACP schema's signed 32-bit range.
    # :nodoc:
    def self.int32_code(code : Int64?) : Int32?
      code.to_i32 if code && (Int32::MIN..Int32::MAX).includes?(code)
    end
  end

  # ─── Session Errors ─────────────────────────────────────────────────

  # Raised when an operation references a session that doesn't exist
  # or has already been closed.
  class SessionNotFoundError < Error
    getter session_id : String

    def initialize(@session_id : String)
      super("Session not found: #{@session_id}")
    end
  end

  # Raised when a session/prompt or other session method is called
  # but no active session has been established.
  class NoActiveSessionError < Error
    def initialize(message : String = "No active session. Call session/new or session/load first.")
      super(message)
    end
  end

  # ─── Authentication Errors ─────────────────────────────────────────

  # Raised when authentication is required but fails or is not provided.
  class AuthenticationError < Error
    def initialize(message : String = "Authentication failed")
      super(message)
    end
  end

  # ─── Request Errors ────────────────────────────────────────────────

  # Raised when a request times out waiting for a response.
  class RequestTimeoutError < Error
    getter request_id : Int64 | String

    def initialize(@request_id : Int64 | String, timeout_seconds : Float64)
      super("Request #{@request_id} timed out after #{timeout_seconds}s")
    end
  end

  # Raised when a request is cancelled before receiving a response.
  class RequestCancelledError < Error
    getter request_id : Int64 | String

    def initialize(@request_id : Int64 | String)
      super("Request #{@request_id} was cancelled")
    end
  end
end
