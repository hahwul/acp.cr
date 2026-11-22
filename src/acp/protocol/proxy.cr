require "./client_methods"
require "./raw_json"
require "./v2/initialization"

module ACP
  module Protocol
    # ACP v1 initialization parameters when starting a proxy.
    alias InitializeProxyRequest = InitializeParams

    # ACP v1 initialization result for a proxy and its successors.
    alias InitializeProxyResponse = InitializeResult

    # The parameters shared by requests and notifications on a successor link.
    struct ProxySuccessorMessage
      include JSON::Serializable

      # The inner JSON-RPC method.
      getter method : String

      # The optional inner object or array of parameters.
      getter params : RawJson?

      # Hop-local metadata on the envelope.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalRawMetadata)]
      getter meta : RawJson?

      # Wraps one request or notification.
      def initialize(@method : String, @params : RawJson? = nil, @meta : RawJson? = nil)
        normalize_params
        raise ArgumentError.new("Successor params must be an object or array") unless valid_params?
        if (metadata = @meta) && !metadata.object?
          raise ArgumentError.new("Successor metadata must be an object")
        end
      end

      # Reads a wrapper with one inner method and at most one parameter value.
      def self.new(pull : JSON::PullParser) : self
        previous_def(WireFrame.read_with_unique_members(pull, "method", "params"))
      end

      private def after_initialize : Nil
        normalize_params
        raise JSON::ParseException.new("Successor params must be an object or array", 1, 1) unless valid_params?
      end

      private def normalize_params : Nil
        @params = nil if @params.try(&.null?)
      end

      private def valid_params? : Bool
        params = @params
        params.nil? || params.object? || params.array?
      end
    end

    # The wire parameters of a wrapped successor request.
    alias ProxySuccessorRequest = ProxySuccessorMessage

    # The JSON result of a wrapped successor request.
    alias ProxySuccessorResponse = RawJson

    # The wire parameters of a wrapped successor notification.
    alias ProxySuccessorNotification = ProxySuccessorMessage

    # A result or error produced locally by a proxy handler.
    struct ProxyReply
      # The exact result, including a possible JSON null.
      getter result : RawJson?

      # The exact JSON-RPC error object.
      getter error : RawJson?

      private def initialize(@result : RawJson?, @error : RawJson?)
      end

      # Returns a successful reply.
      def self.success(result : RawJson = RawJson.from_json("null")) : self
        new(result, nil)
      end

      # Returns a JSON-RPC error with optional exact data.
      def self.failure(code : Int32, message : String, data : RawJson? = nil) : self
        body = JSON.build do |json|
          json.max_nesting = 512
          json.object do
            json.field("code", code)
            json.field("message", message)
            json.field("data", data) if data
          end
        end
        new(nil, RawJson.from_json(body))
      end
    end

    module V2
      # Method names shared with the v1 proxy protocol.
      alias ProxyMethod = Protocol::ProxyMethod

      # Draft ACP v2 initialization parameters when starting a proxy.
      alias InitializeProxyRequest = InitializeParams

      # Draft ACP v2 initialization result for a proxy and its successors.
      alias InitializeProxyResponse = InitializeResult

      # The wire parameters of a wrapped successor request.
      alias ProxySuccessorRequest = Protocol::ProxySuccessorRequest

      # The JSON result of a wrapped successor request.
      alias ProxySuccessorResponse = Protocol::ProxySuccessorResponse

      # The wire parameters of a wrapped successor notification.
      alias ProxySuccessorNotification = Protocol::ProxySuccessorNotification
    end
  end
end
