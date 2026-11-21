require "./sessions"
require "./tool_updates"
require "../raw_json"

module ACP
  module Protocol
    module V2
      # Tool-call fields embedded in a permission request.
      struct PermissionToolCall < ToolCallPatch
      end

      # Command details for a permission request. The Agent runs the command
      # if the user approves it.
      struct PermissionCommand
        include JSON::Serializable

        # Complete command to present to the user.
        property command : String

        # Absolute working directory in the Agent's filesystem syntax.
        property cwd : String

        # Associated tool call when known.
        @[JSON::Field(key: "toolCallId", converter: ::ACP::Protocol::OptionalOptionDescription)]
        property tool_call_id : String?

        # Associated display terminal when known.
        @[JSON::Field(key: "terminalId", converter: ::ACP::Protocol::OptionalOptionDescription)]
        property terminal_id : String?

        # Extension metadata scoped to the command subject.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        property meta : Hash(String, JSON::Any)?

        # Creates a command subject.
        def initialize(@command : String, @cwd : String, @tool_call_id : String? = nil,
                       @terminal_id : String? = nil, @meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # An open permission subject with accessors for the standard variants.
      struct PermissionSubject
        include JSON::Serializable
        include LosslessUnmapped

        # Subject discriminator such as tool_call or command.
        getter type : String

        # Creates a subject with its variant-specific fields.
        def initialize(@type : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
        end

        # Decodes a tool-call patch. Raises JSON::ParseException if the required ID is malformed.
        def tool_call : PermissionToolCall?
          PermissionToolCall.from_json(exact_unmapped_json("toolCall") || "null") if @type == "tool_call"
        end

        # Exact tool-call patch, including extension data outside JSON::Any.
        def tool_call_raw : RawJson?
          if @type == "tool_call" && (json = exact_unmapped_json("toolCall"))
            RawJson.new(JSON::PullParser.new(json))
          end
        end

        protected def keep_exact_unmapped?(key : String) : Bool
          true
        end

        # Decodes a command. Raises JSON::ParseException for malformed fields.
        def command : PermissionCommand?
          PermissionCommand.from_json(WireFrame.encode(self)) if @type == "command"
        end
      end

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

        # JSON-RPC request ID available in the client callback. Match it to
        # a subsequent cancel_request notification to dismiss the prompt.
        @[JSON::Field(ignore: true)]
        property request_id : Protocol::RequestId?

        # Optional detail about the request.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalOptionDescription)]
        property description : String?

        @[JSON::Field(key: "subject")]
        @subject_wire : PreservedJson?

        # Extension metadata.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        property meta : Hash(String, JSON::Any)?

        # Creates permission request parameters.
        def initialize(
          @session_id : String,
          @title : String,
          @options : Array(Protocol::PermissionOption),
          @description : String? = nil,
          subject : JSON::Any? = nil,
          @meta : Hash(String, JSON::Any)? = nil,
        )
          @subject_wire = subject.try { |value| PreservedJson.new(value) }
        end

        # JSON::Any view of the tagged subject when it is representable.
        def subject : JSON::Any?
          @subject_wire.try(&.value)
        end

        # Replaces the tagged subject.
        def subject=(value : JSON::Any?) : JSON::Any?
          @subject_wire = value.try { |present| PreservedJson.new(present) }
          value
        end

        # Exact JSON for a standard or extension subject.
        def subject_raw : RawJson?
          @subject_wire.try(&.raw)
        end

        # Decodes a subject while retaining the payload of future variants.
        def typed_subject : PermissionSubject?
          if raw = subject_raw
            PermissionSubject.from_json(raw.json) unless raw.null?
          end
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
