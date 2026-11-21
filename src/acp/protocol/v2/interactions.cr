require "./sessions"

module ACP
  module Protocol
    module V2
      # A permission decision requested by the Agent. The optional subject
      # retains variant-specific fields for rendering or forwarding.
      struct RequestPermissionParams
        include JSON::Serializable

        # Session requesting the decision.
        @[JSON::Field(key: "sessionId")]
        property session_id : String

        # Short title to present to the user.
        property title : String

        # Options supplied by the Agent.
        property options : Array(Protocol::PermissionOption)

        # Optional detail about the request.
        property description : String?

        # Tagged subject, such as a tool call or command.
        property subject : JSON::Any?

        # Extension metadata.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates permission request parameters.
        def initialize(
          @session_id : String,
          @title : String,
          @options : Array(Protocol::PermissionOption),
          @description : String? = nil,
          @subject : JSON::Any? = nil,
          @meta : Hash(String, JSON::Any)? = nil,
        )
        end
      end

      # Permission response with the chosen option or cancelled outcome.
      alias RequestPermissionResult = Protocol::RequestPermissionResult

      # Cancels one Agent-owned tool call that advertises cancellation.
      struct ToolCallCancelParams
        include JSON::Serializable

        # Session that owns the tool call.
        @[JSON::Field(key: "sessionId")]
        property session_id : String

        # Tool call to cancel.
        @[JSON::Field(key: "toolCallId")]
        property tool_call_id : String

        # Extension metadata.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates cancellation parameters for a tool call.
        def initialize(@session_id : String, @tool_call_id : String, @meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # Successful tool_call/cancel response with optional metadata.
      alias ToolCallCancelResult = Protocol::SessionCloseResult

      # Cancels one Agent-owned terminal that advertises cancellation.
      struct TerminalCancelParams
        include JSON::Serializable

        # Session that owns the terminal.
        @[JSON::Field(key: "sessionId")]
        property session_id : String

        # Terminal to cancel.
        @[JSON::Field(key: "terminalId")]
        property terminal_id : String

        # Extension metadata.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates cancellation parameters for a terminal.
        def initialize(@session_id : String, @terminal_id : String, @meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # Successful terminal/cancel response with optional metadata.
      alias TerminalCancelResult = Protocol::SessionCloseResult
    end
  end
end
