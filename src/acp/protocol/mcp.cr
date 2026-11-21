require "./raw_json"
require "./optional_metadata"

module ACP
  module Protocol
    # An opaque MCP server ID issued by the provider.
    alias McpServerAcpId = String

    # An opaque MCP request ID issued by the consumer.
    alias McpRequestId = String

    # :nodoc:
    module McpAcpFlag
      def self.from_json(pull : JSON::PullParser) : Bool
        return pull.read_bool if pull.kind.bool?

        pull.skip
        false
      end

      def self.to_json(value : Bool, json : JSON::Builder) : Nil
        json.bool(value)
      end
    end

    # ACP declaration of a server hosted on the existing connection.
    struct McpServerAcp
      include JSON::Serializable

      # MCP transport discriminator.
      getter type : String = "acp"

      # Session-local name for the server.
      getter name : String

      # Connection-local ID of the provider's registration.
      @[JSON::Field(key: "serverId")]
      getter server_id : McpServerAcpId

      # ACP extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      getter meta : Hash(String, JSON::Any)?

      # Builds a declaration from a registered server ID.
      def initialize(@name : String, @server_id : McpServerAcpId, @meta : Hash(String, JSON::Any)? = nil)
      end

      # Returns the declaration in the v1 session setup format.
      def to_json_any : JSON::Any
        JSON.parse(WireFrame.encode(self))
      end
    end

    # Exact JSON used by MCP-over-ACP.
    alias McpJson = RawJson

    # :nodoc:
    alias OptionalMcpMetadata = OptionalRawMetadata

    # The routing envelope shared by MCP requests and notifications.
    struct McpMessage
      include JSON::Serializable

      # Declared server handling the request.
      @[JSON::Field(key: "serverId")]
      getter server_id : McpServerAcpId

      # Logical request ID, distinct from the outer JSON-RPC ID.
      @[JSON::Field(key: "requestId")]
      getter request_id : McpRequestId

      # Inner MCP method.
      getter method : String

      # Optional inner MCP parameters.
      getter params : McpJson?

      # Outer ACP metadata, separate from the inner params' metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMcpMetadata)]
      getter meta : McpJson?

      # Builds an MCP routing envelope.
      def initialize(@server_id : McpServerAcpId, @request_id : McpRequestId, @method : String,
                     @params : McpJson? = nil, @meta : McpJson? = nil)
        if (params = @params) && !params.object?
          raise ArgumentError.new("MCP message params must be a JSON object")
        end
        if (metadata = @meta) && !metadata.object?
          raise ArgumentError.new("MCP envelope metadata must be a JSON object")
        end
      end

      private def after_initialize : Nil
        if (params = @params) && !params.object?
          raise JSON::ParseException.new("MCP message params must be a JSON object", 1, 1)
        end
      end
    end

    # Agent-to-provider request for one MCP operation.
    alias MessageMcpRequest = McpMessage

    # Provider-to-agent notification scoped to the active operation.
    alias MessageMcpNotification = McpMessage

    # An inner MCP error whose code is independent of outer ACP errors.
    struct McpError
      include JSON::Serializable

      @[JSON::Field(ignore: true)]
      @fields = {} of String => McpJson

      # Inner MCP error code.
      getter code : Int32

      # MCP error description.
      getter message : String

      # Builds an error. Pass an explicit JSON null to send a null data field.
      def initialize(@code : Int32, @message : String, data : McpJson? = nil)
        @fields["data"] = data if data
      end

      # Optional error data. A JSON null value is distinct from nil.
      def data : McpJson?
        @fields["data"]?
      end

      # Exact value of an inner error extension or data field.
      def raw_field(name : String) : String?
        @fields[name]?.try(&.json)
      end

      protected def on_unknown_json_attribute(pull, key, key_location)
        @fields[key] = McpJson.new(pull)
      end

      protected def on_to_json(json)
        @fields.each do |name, value|
          json.field(name, value)
        end
      end
    end

    # The inner result or error carried by a successful ACP response.
    struct MessageMcpResponse
      # MCP result, which can contain an explicit JSON null.
      getter result : McpJson?

      # Inner MCP error.
      getter error : McpError?

      # ACP response metadata.
      getter meta : McpJson?

      private def initialize(@result : McpJson?, @error : McpError?, @meta : McpJson?)
        if (metadata = @meta) && !metadata.object?
          raise ArgumentError.new("MCP result metadata must be a JSON object")
        end
      end

      # Carries an MCP result, including JSON null.
      def self.success(result : McpJson | JSON::Any, meta : McpJson? = nil) : self
        new(result.is_a?(McpJson) ? result : McpJson.new(result), nil, meta)
      end

      # Carries an MCP error as a successful outer ACP response.
      def self.failure(error : McpError, meta : McpJson? = nil) : self
        new(nil, error, meta)
      end

      # Reads the outcome, preferring the result when both branches arrive.
      def self.from_json(value : String) : self
        wire = McpJson.from_json(value)
        meta = wire.field("_meta")
        meta = nil unless meta.try(&.object?)
        if result = wire.field("result")
          success(result, meta)
        elsif error = wire.field("error")
          failure(McpError.from_json(error.json), meta)
        else
          raise JSON::ParseException.new("MCP response requires an outcome", 1, 1)
        end
      end

      # Encodes exactly one MCP outcome.
      def to_json(builder : JSON::Builder) : Nil
        builder.object do
          if result = @result
            builder.field("result", result)
          else
            builder.field("error", @error.not_nil!)
          end
          builder.field("_meta", @meta) if @meta
        end
      end

      # Returns the encoded outcome carrier.
      def to_json : String
        WireFrame.encode(self)
      end
    end
  end
end
