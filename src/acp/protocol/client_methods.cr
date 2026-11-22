# ACP Protocol — Client Method Types
#
# Defines the typed request and response structures for all client-side
# methods that the agent can invoke. These methods allow the agent to
# interact with the client's environment (file system, terminals).
#
# Client methods are agent-initiated JSON-RPC requests that the client
# must handle. The client advertises support for these methods via
# capabilities during initialization.
#
# Methods defined here:
#   - `fs/read_text_file`    — Read file contents (requires fs.readTextFile)
#   - `fs/write_text_file`   — Write file contents (requires fs.writeTextFile)
#   - `terminal/create`      — Create a new terminal (requires terminal)
#   - `terminal/output`      — Get terminal output and exit status
#   - `terminal/release`     — Release a terminal
#   - `terminal/wait_for_exit` — Wait for terminal command to exit
#   - `terminal/kill`        — Kill terminal command without releasing
#   - `elicitation/create`   — Ask the user for input (requires elicitation)
#   - `elicitation/complete` — URL elicitation finished (notification)
#
# Reference: https://agentclientprotocol.com/protocol/file-system
# Reference: https://agentclientprotocol.com/protocol/terminals
# Reference: https://agentclientprotocol.com/protocol/v1/elicitation

require "json"
require "./types"
require "./tool_call_content"

module ACP
  module Protocol
    # ═══════════════════════════════════════════════════════════════════
    # File System Methods
    # ═══════════════════════════════════════════════════════════════════

    # ─── fs/read_text_file ────────────────────────────────────────────
    # Reads content from a text file in the client's file system,
    # including unsaved changes in the editor.
    #
    # Only available if the client advertises the `fs.readTextFile`
    # capability during initialization.
    #
    # See: https://agentclientprotocol.com/protocol/file-system#reading-files

    # Request parameters for `fs/read_text_file`.
    struct ReadTextFileParams
      include JSON::Serializable
      include LosslessMetadata

      # The session ID for this request (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # Absolute path to the file to read (required).
      property path : String

      # Optional line number to start reading from (1-based). Schema `uint32`.
      property line : UInt32?

      # Optional maximum number of lines to read. Schema `uint32`.
      property limit : UInt32?

      def initialize(
        @session_id : String,
        @path : String,
        @line : UInt32? = nil,
        @limit : UInt32? = nil,
        meta : Hash(String, JSON::Any)? = nil,
      )
        self.meta = meta
      end
    end

    # Response for `fs/read_text_file`.
    struct ReadTextFileResult
      include JSON::Serializable

      # The file contents (required).
      property content : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@content : String, @meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # ─── fs/write_text_file ───────────────────────────────────────────
    # Writes content to a text file in the client's file system.
    # The client MUST create the file if it doesn't exist.
    #
    # Only available if the client advertises the `fs.writeTextFile`
    # capability during initialization.
    #
    # See: https://agentclientprotocol.com/protocol/file-system#writing-files

    # Request parameters for `fs/write_text_file`.
    struct WriteTextFileParams
      include JSON::Serializable
      include LosslessMetadata

      # The session ID for this request (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # Absolute path to the file to write (required).
      property path : String

      # The text content to write to the file (required).
      property content : String

      def initialize(
        @session_id : String,
        @path : String,
        @content : String,
        meta : Hash(String, JSON::Any)? = nil,
      )
        self.meta = meta
      end
    end

    # Response for `fs/write_text_file`.
    # An empty result on success.
    struct WriteTextFileResult
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # ═══════════════════════════════════════════════════════════════════
    # Terminal Methods
    # ═══════════════════════════════════════════════════════════════════

    # ─── terminal/create ──────────────────────────────────────────────
    # Executes a command in a new terminal. Returns a TerminalId that
    # can be used with other terminal methods.
    #
    # The Agent is responsible for releasing the terminal by using
    # the `terminal/release` method.
    #
    # Only available if the client advertises the `terminal` capability.
    #
    # See: https://agentclientprotocol.com/protocol/terminals#executing-commands

    # :nodoc:
    module TerminalEnvironment
      def self.from_json(pull : JSON::PullParser) : PreservedJson?
        location = pull.location
        source = RawJson.new(pull)
        return if source.null?

        entries = source.elements?
        unless entries
          raise JSON::ParseException.new("Terminal environment must be an array", *location)
        end
        entries.each do |entry|
          fields = entry.members?
          name = fields.try(&.["name"]?).try(&.as_s?)
          value = fields.try(&.["value"]?).try(&.as_s?)
          unless name && value &&
                 WireFrame.repeated_members(entry.json, "name", "value").empty?
            raise JSON::ParseException.new("Each terminal environment entry requires a unique string name and value", *location)
          end
          if name.empty? || name.includes?('=') || name.includes?('\0') || value.includes?('\0')
            raise JSON::ParseException.new("Invalid terminal environment name or value", *location)
          end
        end

        if (projection = source.to_json_any?) && WireFrame.encode(projection) == source.json
          PreservedJson.new(projection)
        else
          PreservedJson.new(source, project_array_objects: true, project_nested_objects: true)
        end
      end

      def self.to_json(value : PreservedJson, builder : JSON::Builder) : Nil
        value.to_json(builder)
      end
    end

    # :nodoc:
    module TerminalOutputByteLimit
      def self.from_json(pull : JSON::PullParser) : UInt64?
        return pull.read_null if pull.kind.null?
        if pull.kind.int? && pull.raw_value == "-0"
          pull.read_raw
          return 0_u64
        end
        UInt64.new(pull)
      end

      def self.to_json(value : UInt64, builder : JSON::Builder) : Nil
        builder.number(value)
      end
    end

    # Request parameters for `terminal/create`.
    struct CreateTerminalParams
      include JSON::Serializable
      include LosslessMetadata

      # The session ID for this request (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The command to execute (required).
      property command : String

      # Array of command arguments.
      property args : Array(String)?

      @[JSON::Field(key: "env", converter: ::ACP::Protocol::TerminalEnvironment)]
      @environment_wire : PreservedJson?

      # Working directory for the command (absolute path).
      property cwd : String?

      # Maximum number of output bytes to retain. Once exceeded,
      # earlier output is truncated to stay within this limit.
      # The Client MUST ensure truncation happens at a character boundary.
      # Schema `uint64`.
      @[JSON::Field(key: "outputByteLimit", converter: ::ACP::Protocol::TerminalOutputByteLimit)]
      property output_byte_limit : UInt64?

      def initialize(
        @session_id : String,
        @command : String,
        @args : Array(String)? = nil,
        env : Array(JSON::Any)? = nil,
        @cwd : String? = nil,
        @output_byte_limit : UInt64? = nil,
        meta : Hash(String, JSON::Any)? = nil,
      )
        self.env = env
        self.meta = meta
      end

      # Environment variables with their name, value, and editable extension fields.
      def env : Array(JSON::Any)?
        @environment_wire.try(&.value).try(&.as_a?)
      end

      # Replaces the terminal environment.
      def env=(value : Array(JSON::Any)?) : Array(JSON::Any)?
        @environment_wire = value.try { |entries| PreservedJson.new(JSON::Any.new(entries)) }
        value
      end

      # Exact original environment values, including extension metadata.
      def env_raw : RawJson?
        @environment_wire.try(&.raw)
      end
    end

    # Response for `terminal/create`.
    struct CreateTerminalResult
      include JSON::Serializable

      # The unique identifier for the created terminal (required).
      @[JSON::Field(key: "terminalId")]
      property terminal_id : String

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@terminal_id : String, @meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # ─── terminal/output ──────────────────────────────────────────────
    # Gets the terminal output and exit status without waiting for
    # the command to complete.
    #
    # See: https://agentclientprotocol.com/protocol/terminals#getting-output

    # Request parameters for `terminal/output`.
    struct TerminalOutputParams
      include JSON::Serializable
      include LosslessMetadata

      # The session ID for this request (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The ID of the terminal to get output from (required).
      @[JSON::Field(key: "terminalId")]
      property terminal_id : String

      def initialize(
        @session_id : String,
        @terminal_id : String,
        meta : Hash(String, JSON::Any)? = nil,
      )
        self.meta = meta
      end
    end

    # Response for `terminal/output`.
    struct TerminalOutputResult
      include JSON::Serializable

      # The terminal output captured so far (required).
      property output : String

      # Whether the output was truncated due to byte limits (required).
      property? truncated : Bool = false

      # Exit status if the command has completed. Nil if still running.
      @[JSON::Field(key: "exitStatus")]
      property exit_status : TerminalExitStatus?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @output : String,
        @truncated : Bool = false,
        @exit_status : TerminalExitStatus? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end

      # Returns true if the command has exited.
      def exited? : Bool
        !@exit_status.nil?
      end
    end

    # ─── terminal/release ─────────────────────────────────────────────
    # Releases a terminal. The command is killed if it hasn't exited yet.
    # After release, the TerminalId can no longer be used with other
    # terminal/* methods.
    #
    # See: https://agentclientprotocol.com/protocol/terminals#releasing-terminals

    # Request parameters for `terminal/release`.
    struct ReleaseTerminalParams
      include JSON::Serializable
      include LosslessMetadata

      # The session ID for this request (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The ID of the terminal to release (required).
      @[JSON::Field(key: "terminalId")]
      property terminal_id : String

      def initialize(
        @session_id : String,
        @terminal_id : String,
        meta : Hash(String, JSON::Any)? = nil,
      )
        self.meta = meta
      end
    end

    # Response for `terminal/release`.
    struct ReleaseTerminalResult
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # ─── terminal/wait_for_exit ───────────────────────────────────────
    # Waits for the terminal command to exit and returns its exit status.
    #
    # See: https://agentclientprotocol.com/protocol/terminals#waiting-for-exit

    # Request parameters for `terminal/wait_for_exit`.
    struct WaitForTerminalExitParams
      include JSON::Serializable
      include LosslessMetadata

      # The session ID for this request (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The ID of the terminal to wait for (required).
      @[JSON::Field(key: "terminalId")]
      property terminal_id : String

      def initialize(
        @session_id : String,
        @terminal_id : String,
        meta : Hash(String, JSON::Any)? = nil,
      )
        self.meta = meta
      end
    end

    # Response for `terminal/wait_for_exit`.
    struct WaitForTerminalExitResult
      include JSON::Serializable

      # The process exit code (may be nil if terminated by signal). Schema `uint32`.
      @[JSON::Field(key: "exitCode")]
      property exit_code : UInt32?

      # The signal that terminated the process (may be nil if exited normally).
      property signal : String?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @exit_code : UInt32? = nil,
        @signal : String? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end

      # Returns true if the command exited successfully (exit code 0).
      def success? : Bool
        @exit_code == 0
      end

      # Returns true if the command was terminated by a signal.
      def signaled? : Bool
        !@signal.nil?
      end
    end

    # ─── terminal/kill ────────────────────────────────────────────────
    # Kills the terminal command without releasing the terminal.
    # The TerminalId remains valid and can be used with other methods.
    # The Agent MUST still call `terminal/release` when done.
    #
    # See: https://agentclientprotocol.com/protocol/terminals#killing-commands

    # Request parameters for `terminal/kill`.
    struct KillTerminalParams
      include JSON::Serializable
      include LosslessMetadata

      # The session ID for this request (required).
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The ID of the terminal to kill (required).
      @[JSON::Field(key: "terminalId")]
      property terminal_id : String

      def initialize(
        @session_id : String,
        @terminal_id : String,
        meta : Hash(String, JSON::Any)? = nil,
      )
        self.meta = meta
      end
    end

    # Response for `terminal/kill`.
    struct KillTerminalResult
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # ═══════════════════════════════════════════════════════════════════
    # Elicitation Methods
    # ═══════════════════════════════════════════════════════════════════
    # See: https://agentclientprotocol.com/protocol/v1/elicitation

    # One choice of an enum-valued elicitation property (`EnumOption`).
    struct EnumOption
      include JSON::Serializable

      # The value submitted when this option is chosen (required).
      @[JSON::Field(key: "const")]
      property const_value : String

      # Display label (required).
      property title : String

      # Optional longer description.
      property description : String?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @const_value : String,
        @title : String,
        @description : String? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # The `items` of an `array` (multi-select) elicitation property: either
    # untitled (`type: "string"` + `enum`) or titled (`anyOf` options).
    struct MultiSelectItems
      include JSON::Serializable

      # "string" for untitled items; absent for titled ones.
      @[JSON::Field(key: "type")]
      property items_type : String?

      # Allowed values of untitled items.
      @[JSON::Field(key: "enum")]
      property enum_values : Array(String)?

      # Allowed values of titled items.
      @[JSON::Field(key: "anyOf")]
      property any_of : Array(EnumOption)?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @items_type : String? = nil,
        @enum_values : Array(String)? = nil,
        @any_of : Array(EnumOption)? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # One property of a form elicitation's `requestedSchema`
    # (`ElicitationPropertySchema`). The schema's variants
    # (`StringPropertySchema`, `NumberPropertySchema`,
    # `IntegerPropertySchema`, `BooleanPropertySchema`,
    # `MultiSelectPropertySchema`) are flattened into one struct keyed by
    # `property_type`; fields that don't apply to a variant are nil.
    struct ElicitationPropertySchema
      include JSON::Serializable

      # "string", "number", "integer", "boolean", "array", or a future type
      # (required).
      @[JSON::Field(key: "type")]
      property property_type : String

      # Display label.
      property title : String?

      # Longer description.
      property description : String?

      # Default value (a string, number, boolean or string array, matching
      # the type).
      property default : JSON::Any?

      # `string`: length bounds. Schema `uint32`.
      @[JSON::Field(key: "minLength")]
      property min_length : UInt32?

      # :ditto:
      @[JSON::Field(key: "maxLength")]
      property max_length : UInt32?

      # `string`: regular expression the value must match.
      property pattern : String?

      # `string`: "email", "uri", "date" or "date-time".
      property format : String?

      # `string`: allowed values (untitled enum).
      @[JSON::Field(key: "enum")]
      property enum_values : Array(String)?

      # `string`: allowed values with display titles (titled enum).
      @[JSON::Field(key: "oneOf")]
      property one_of : Array(EnumOption)?

      # `number` / `integer`: inclusive bounds. Integers stay `Int64`.
      property minimum : Int64 | Float64?

      # :ditto:
      property maximum : Int64 | Float64?

      # `array`: selection count bounds. Schema `uint64`.
      @[JSON::Field(key: "minItems")]
      property min_items : UInt64?

      # :ditto:
      @[JSON::Field(key: "maxItems")]
      property max_items : UInt64?

      # `array`: the selectable values (required for `array`).
      property items : MultiSelectItems?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @property_type : String,
        @title : String? = nil,
        @description : String? = nil,
        @default : JSON::Any? = nil,
        @min_length : UInt32? = nil,
        @max_length : UInt32? = nil,
        @pattern : String? = nil,
        @format : String? = nil,
        @enum_values : Array(String)? = nil,
        @one_of : Array(EnumOption)? = nil,
        @minimum : Int64 | Float64? = nil,
        @maximum : Int64 | Float64? = nil,
        @min_items : UInt64? = nil,
        @max_items : UInt64? = nil,
        @items : MultiSelectItems? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # The restricted JSON Schema of a form elicitation: a flat object of
    # primitive and enum properties.
    struct ElicitationSchema
      include JSON::Serializable

      # Always "object".
      @[JSON::Field(key: "type")]
      property schema_type : String = "object"

      # Optional form title.
      property title : String?

      # Optional form description.
      property description : String?

      # The form fields, keyed by property name.
      property properties : Hash(String, ElicitationPropertySchema) = {} of String => ElicitationPropertySchema

      # Names of the properties the user must fill in.
      property required : Array(String)?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @properties : Hash(String, ElicitationPropertySchema) = {} of String => ElicitationPropertySchema,
        @required : Array(String)? = nil,
        @title : String? = nil,
        @description : String? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @schema_type = "object"
      end
    end

    # ─── elicitation/create ───────────────────────────────────────────
    # Asks the user for structured input (form mode) or for consent to open
    # an out-of-band URL (URL mode). Only sent for a mode the client
    # advertised in `clientCapabilities.elicitation`; the client answers any
    # other mode with -32602.

    # Request parameters for `elicitation/create` (`CreateElicitationRequest`).
    # Mode- and scope-specific fields are flattened: `requested_schema` is
    # set for form mode, `elicitation_id` / `url` for URL mode; `session_id`
    # (plus optional `tool_call_id`) for a session-scoped request,
    # `request_id` for a request-scoped one.
    struct CreateElicitationParams
      include JSON::Serializable
      include LosslessMetadata

      # "form", "url", or a future mode (required).
      property mode : String

      # What is being asked and why (required).
      property message : String

      # Session scope: the session this elicitation belongs to.
      @[JSON::Field(key: "sessionId")]
      property session_id : String?

      # Session scope: the tool call this elicitation belongs to.
      @[JSON::Field(key: "toolCallId")]
      property tool_call_id : String?

      # Request scope: the JSON-RPC request this elicitation belongs to.
      @[JSON::Field(key: "requestId")]
      property request_id : RequestId?

      # Local signal supplied to ACP v2 callbacks. It closes if the input
      # is cancelled, its originating request ends, or the connection closes.
      @[JSON::Field(ignore: true)]
      property cancellation : Channel(Nil)?

      # Form mode: the fields to collect (required for form mode).
      @[JSON::Field(key: "requestedSchema")]
      property requested_schema : ElicitationSchema?

      # Exact source schema supplied to the callback for a form request.
      # Includes optional custom controls omitted from the v2 typed view.
      @[JSON::Field(ignore: true)]
      property requested_schema_raw : RawJson?

      # URL mode: opaque ID echoed by `elicitation/complete` (required for URL mode).
      @[JSON::Field(key: "elicitationId")]
      property elicitation_id : String?

      # URL mode: the URL to open after user consent (required for URL mode).
      property url : String?

      def initialize(
        @mode : String,
        @message : String,
        @session_id : String? = nil,
        @tool_call_id : String? = nil,
        @request_id : RequestId? = nil,
        @requested_schema : ElicitationSchema? = nil,
        @elicitation_id : String? = nil,
        @url : String? = nil,
        meta : Hash(String, JSON::Any)? = nil,
      )
        self.meta = meta
      end

      # Both scopes missing can only mean `"requestId": null` (a request
      # scope with a null ID), so write that back instead of no scope at all.
      protected def on_to_json(json : ::JSON::Builder)
        json.field("requestId", nil) if @session_id.nil? && @request_id.nil?
      end

      # Returns true for a form-mode request.
      def form? : Bool
        @mode == "form"
      end

      # Returns true for a URL-mode request.
      def url? : Bool
        @mode == "url"
      end
    end

    # :nodoc:
    # Projects the wire envelope independently of mode-specific schema fields.
    module ElicitationRequest
      def self.from_json(json : String) : CreateElicitationParams
        fields = RawJson.new(JSON::PullParser.new(json)).members?
        raise JSON::ParseException.new("Elicitation params must be an object", 1, 1) unless fields

        from_fields(fields)
      end

      def self.from_fields(fields : Hash(String, RawJson)) : CreateElicitationParams
        mode = fields["mode"]?.try(&.as_s?)
        message = fields["message"]?.try(&.as_s?)
        raise JSON::ParseException.new("Elicitation requires a mode and message", 1, 1) unless mode && message

        session = fields["sessionId"]?.try(&.as_s?)
        request = fields["requestId"]?
        input = CreateElicitationParams.new(mode, message,
          session_id: session,
          tool_call_id: (fields["toolCallId"]?.try(&.as_s?) if session),
          request_id: request.try(&.as_i64?) || request.try(&.as_s?),
          elicitation_id: (fields["elicitationId"]?.try(&.as_s?) if mode == "url"),
          url: (fields["url"]?.try(&.as_s?) if mode == "url"))
        if (meta = fields["_meta"]?) && meta.object?
          input.meta_raw = meta
        end
        input
      end
    end

    # A submitted form value (`ElicitationContentValue`).
    alias ElicitationContentValue = String | Int64 | Float64 | Bool | Array(String)

    # Response for `elicitation/create` (`CreateElicitationResponse`).
    struct CreateElicitationResult
      include JSON::Serializable
      include LosslessMetadata

      # "accept", "decline" or "cancel" (required).
      property action : String

      # The submitted values; only meaningful for an accepted form
      # elicitation, normally omitted for URL mode.
      getter content : Hash(String, ElicitationContentValue)?

      # Exact content set by `accept_raw`.
      @[JSON::Field(ignore: true)]
      getter content_raw : RawJson?

      # Replaces submitted content with standard typed values.
      def content=(value : Hash(String, ElicitationContentValue)?) : Hash(String, ElicitationContentValue)?
        @content_raw = nil
        @content = value
      end

      def initialize(
        @action : String,
        @content : Hash(String, ElicitationContentValue)? = nil,
        meta : Hash(String, JSON::Any)? = nil,
      )
        self.meta = meta
      end

      # The user submitted the form or consented to open the URL.
      def self.accept(content : Hash(String, ElicitationContentValue)? = nil) : CreateElicitationResult
        new("accept", content)
      end

      # Accepts an ACP v2 form with exact JSON content, including custom values.
      # Content must be an object or null.
      def self.accept_raw(content : RawJson) : CreateElicitationResult
        raise ArgumentError.new("Elicitation content must be an object or null") unless content.object? || content.null?

        result = new("accept")
        result.content_raw = content
        result
      end

      protected def content_raw=(@content_raw : RawJson)
      end

      protected def on_to_json(json : JSON::Builder) : Nil
        if raw = @content_raw
          json.field("content", raw)
        end
      end

      # The user explicitly declined.
      def self.decline : CreateElicitationResult
        new("decline")
      end

      # The user dismissed the request without choosing.
      def self.cancel : CreateElicitationResult
        new("cancel")
      end
    end

    # ─── elicitation/complete ─────────────────────────────────────────
    # Notification that the out-of-band interaction of a URL elicitation
    # finished. Clients MUST ignore unknown or already-completed IDs.

    # Params for the `elicitation/complete` notification
    # (`CompleteElicitationNotification`).
    struct CompleteElicitationParams
      include JSON::Serializable
      include LosslessMetadata

      # The `elicitationId` of the original URL-mode request (required).
      @[JSON::Field(key: "elicitationId")]
      property elicitation_id : String

      # Creates a completion for a URL elicitation.
      def initialize(@elicitation_id : String, meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end

      # Reads a completion with one unambiguous elicitation ID.
      def self.new(pull : JSON::PullParser) : self
        previous_def(WireFrame.read_with_unique_members(pull, "elicitationId"))
      end
    end

    # ─── Agent Method Names ───────────────────────────────────────────
    # Constants for all agent method names (client → agent requests),
    # matching the Rust SDK's `AGENT_METHOD_NAMES`.
    # See: https://agentclientprotocol.com/protocol/overview

    module AgentMethod
      # Connection lifecycle.
      INITIALIZE   = "initialize"
      AUTHENTICATE = "authenticate"
      LOGOUT       = "logout"
      AUTH_STATUS  = "auth/status"

      # Draft process-scoped provider configuration.
      PROVIDERS_LIST    = "providers/list"
      PROVIDERS_SET     = "providers/set"
      PROVIDERS_DISABLE = "providers/disable"
      PROVIDER_METHODS  = {PROVIDERS_LIST, PROVIDERS_SET, PROVIDERS_DISABLE}

      # Request-scoped MCP notification sent to the Agent.
      MCP_MESSAGE = "mcp/message"

      # Session management.
      SESSION_NEW               = "session/new"
      SESSION_LOAD              = "session/load"
      SESSION_LIST              = "session/list"
      SESSION_STATUS            = "session/status"
      SESSION_OPTIONS           = "session/options"
      SESSION_FORK              = "session/fork"
      SESSION_SET_TITLE         = "session/set_title"
      SESSION_ARCHIVE           = "session/archive"
      SESSION_UNARCHIVE         = "session/unarchive"
      SESSION_RESUME            = "session/resume"
      SESSION_CLOSE             = "session/close"
      SESSION_DELETE            = "session/delete"
      SESSION_PROMPT            = "session/prompt"
      SESSION_CANCEL            = "session/cancel"
      SESSION_SET_MODE          = "session/set_mode"
      SESSION_SET_CONFIG_OPTION = "session/set_config_option"

      # Session update notification (agent → client).
      SESSION_UPDATE = "session/update"

      # Every session-scoped method name, in one place so `known?` and
      # `session_method?` cannot drift apart as methods are added.
      SESSION_METHODS = {
        SESSION_NEW, SESSION_LOAD, SESSION_LIST, SESSION_STATUS, SESSION_OPTIONS, SESSION_FORK, SESSION_SET_TITLE, SESSION_RESUME,
        SESSION_CLOSE, SESSION_DELETE, SESSION_ARCHIVE, SESSION_UNARCHIVE, SESSION_PROMPT, SESSION_CANCEL,
        SESSION_SET_MODE, SESSION_SET_CONFIG_OPTION, SESSION_UPDATE,
      }

      # Returns true if the given method name is a known agent method.
      def self.known?(method : String) : Bool
        method == INITIALIZE || method == AUTHENTICATE || method == LOGOUT || method == AUTH_STATUS ||
          method == MCP_MESSAGE || PROVIDER_METHODS.includes?(method) || session_method?(method)
      end

      # Returns true if the given method name is a session method.
      def self.session_method?(method : String) : Bool
        SESSION_METHODS.includes?(method)
      end
    end

    # ─── Extension Method Helpers ─────────────────────────────────────
    # Extension methods in ACP are prefixed with `_`. These helpers
    # detect and strip the prefix for dispatch.
    # See: https://agentclientprotocol.com/protocol/extensibility

    module ExtensionMethod
      # Extension method prefix as defined by the ACP spec.
      PREFIX = "_"

      # Returns true if the given method name is an extension method.
      def self.extension?(method : String) : Bool
        method.starts_with?(PREFIX)
      end

      # Strips the extension prefix from a method name.
      # Returns nil if the method is not an extension method.
      def self.strip_prefix(method : String) : String?
        if extension?(method)
          method[PREFIX.size..]
        end
      end

      # Adds the extension prefix to a method name.
      #
      # Idempotent: a name that is already prefixed is returned unchanged.
      # Agent-initiated extension requests are handed to `on_agent_request`
      # under their full wire name, so echoing that name straight back into
      # `Client#ext_method` is the natural thing to write — and used to put
      # `__foo` on the wire, which no agent recognizes.
      def self.add_prefix(method : String) : String
        return method if extension?(method)
        "#{PREFIX}#{method}"
      end
    end

    # ─── Client Method Names ──────────────────────────────────────────
    # Constants for all client method names, for use in dispatching
    # and handler registration.

    module ClientMethod
      # File system methods.
      FS_READ_TEXT_FILE  = "fs/read_text_file"
      FS_WRITE_TEXT_FILE = "fs/write_text_file"

      # Terminal methods.
      TERMINAL_CREATE        = "terminal/create"
      TERMINAL_OUTPUT        = "terminal/output"
      TERMINAL_RELEASE       = "terminal/release"
      TERMINAL_WAIT_FOR_EXIT = "terminal/wait_for_exit"
      TERMINAL_KILL          = "terminal/kill"

      # Permission request method.
      SESSION_REQUEST_PERMISSION = "session/request_permission"
      AUTH_STATUS_UPDATE         = "auth/status_update"
      MCP_MESSAGE                = AgentMethod::MCP_MESSAGE

      # Elicitation request and its completion notification.
      ELICITATION_CREATE   = "elicitation/create"
      ELICITATION_COMPLETE = "elicitation/complete"

      # Returns true if the given method name is a known client method.
      def self.known?(method : String) : Bool
        case method
        when FS_READ_TEXT_FILE, FS_WRITE_TEXT_FILE,
             TERMINAL_CREATE, TERMINAL_OUTPUT, TERMINAL_RELEASE,
             TERMINAL_WAIT_FOR_EXIT, TERMINAL_KILL,
             SESSION_REQUEST_PERMISSION, AUTH_STATUS_UPDATE, MCP_MESSAGE,
             ELICITATION_CREATE, ELICITATION_COMPLETE
          true
        else
          false
        end
      end

      # Returns true if the given method name is a file system method.
      def self.fs_method?(method : String) : Bool
        method == FS_READ_TEXT_FILE || method == FS_WRITE_TEXT_FILE
      end

      # Returns true if the given method name is a terminal method.
      def self.terminal_method?(method : String) : Bool
        case method
        when TERMINAL_CREATE, TERMINAL_OUTPUT, TERMINAL_RELEASE,
             TERMINAL_WAIT_FOR_EXIT, TERMINAL_KILL
          true
        else
          false
        end
      end
    end

    # ─── Proxy Method Names ───────────────────────────────────────────

    # Methods exchanged between an ACP conductor and a proxy component.
    module ProxyMethod
      # Initializes a component in proxy mode.
      INITIALIZE = "proxy/initialize"

      # Carries a request or notification across the successor boundary.
      SUCCESSOR = "proxy/successor"
    end

    # ─── Protocol Method Names ────────────────────────────────────────

    # Protocol-level methods either side may send (`$/`-prefixed).
    module ProtocolMethod
      # Asks the peer to cancel one of our requests.
      # See: https://agentclientprotocol.com/protocol/v1/cancellation
      CANCEL_REQUEST = "$/cancel_request"
    end
  end
end
