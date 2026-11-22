require "json"
require "./raw_json"

module ACP
  module Protocol
    # Opaque ID of a configurable model provider.
    alias ProviderId = String

    # API protocol name, including future ACP and custom identifiers.
    alias LlmProtocol = String

    # Presence advertises support for draft provider configuration.
    struct ProvidersCapabilities
      include JSON::Serializable
      include LosslessMetadata

      # Creates the provider configuration support marker.
      def initialize(meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end

      def_equals_and_hash metadata_comparison
    end

    # Non-secret routing information for an enabled provider.
    struct ProviderCurrentConfig
      include JSON::Serializable
      include LosslessMetadata

      # API protocol currently used for this provider.
      @[JSON::Field(key: "apiType")]
      getter api_type : LlmProtocol

      # Effective base URL reported by the Agent.
      @[JSON::Field(key: "baseUrl")]
      getter base_url : String

      # Creates a routing summary.
      def initialize(@api_type : LlmProtocol, @base_url : String, meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end

      def_equals_and_hash api_type, base_url, metadata_comparison
    end

    # Describes one configurable model provider.
    struct ProviderInfo
      include JSON::Serializable
      include LosslessMetadata

      # :nodoc:
      module SupportedProtocols
        def self.from_json(pull : JSON::PullParser) : Array(LlmProtocol)
          supported = [] of LlmProtocol
          if pull.kind.begin_array?
            pull.read_array do
              if pull.kind.string?
                supported << pull.read_string
              else
                pull.skip
              end
            end
          else
            pull.skip
          end
          supported
        end

        def self.to_json(value : Array(LlmProtocol), json : JSON::Builder) : Nil
          value.to_json(json)
        end
      end

      # Opaque ID used to configure this provider.
      @[JSON::Field(key: "providerId")]
      getter provider_id : ProviderId

      # API protocols the provider accepts, in the Agent's order.
      @[JSON::Field(converter: ::ACP::Protocol::ProviderInfo::SupportedProtocols)]
      getter supported : Array(LlmProtocol) = [] of LlmProtocol

      # A mandatory provider cannot be disabled.
      getter? required : Bool

      # Effective routing. Nil indicates a disabled provider.
      getter current : ProviderCurrentConfig?

      # Creates an entry for a configurable provider.
      def initialize(
        @provider_id : ProviderId,
        @supported : Array(LlmProtocol),
        @required : Bool,
        @current : ProviderCurrentConfig? = nil,
        meta : Hash(String, JSON::Any)? = nil,
      )
        self.meta = meta
      end

      def_equals_and_hash provider_id, supported, required?, current, metadata_comparison
    end

    # Parameters for querying configurable model providers.
    struct ListProvidersParams
      include JSON::Serializable
      include LosslessMetadata

      # Creates a provider list query.
      def initialize(meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end

      def_equals_and_hash metadata_comparison
    end

    # The Agent's list of configurable providers and current routing.
    struct ListProvidersResult
      include JSON::Serializable
      include LosslessMetadata

      # Configurable providers, including providers that are disabled.
      getter providers : Array(ProviderInfo)

      # Creates a provider list response.
      def initialize(@providers : Array(ProviderInfo), meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end

      def_equals_and_hash providers, metadata_comparison

      # Whether the current list describes this provider as mandatory.
      def required?(provider_id : ProviderId) : Bool
        @providers.any? { |provider| provider.required? && provider.provider_id == provider_id }
      end
    end

    # Full replacement of a provider's process-scoped routing configuration.
    struct SetProviderParams
      include JSON::Serializable
      include LosslessMetadata

      # Opaque ID of the target provider.
      @[JSON::Field(key: "providerId")]
      getter provider_id : ProviderId

      # API protocol the provider should use.
      @[JSON::Field(key: "apiType")]
      getter api_type : LlmProtocol

      # Base URL for requests through this provider.
      @[JSON::Field(key: "baseUrl")]
      getter base_url : String

      # Full header map sent to the Agent. It can contain credentials.
      getter headers : Hash(String, String)?

      # Creates a full replacement request.
      def initialize(
        @provider_id : ProviderId,
        @api_type : LlmProtocol,
        @base_url : String,
        @headers : Hash(String, String)? = nil,
        meta : Hash(String, JSON::Any)? = nil,
      )
        self.meta = meta
      end

      def_equals_and_hash provider_id, api_type, base_url, headers, metadata_comparison

      # Avoids printing request credentials during normal inspection.
      def inspect(io : IO) : Nil
        io << self.class << "([REDACTED])"
      end
    end

    # A successful configuration replacement.
    struct SetProviderResult
      include JSON::Serializable
      include LosslessMetadata

      # Creates a configuration replacement acknowledgement.
      def initialize(meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end

      def_equals_and_hash metadata_comparison
    end

    # Parameters for disabling a non-mandatory provider.
    struct DisableProviderParams
      include JSON::Serializable
      include LosslessMetadata

      # Opaque ID of the target provider.
      @[JSON::Field(key: "providerId")]
      getter provider_id : ProviderId

      # Creates a disable request.
      def initialize(@provider_id : ProviderId, meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end

      def_equals_and_hash provider_id, metadata_comparison
    end

    # A successful provider disable operation.
    struct DisableProviderResult
      include JSON::Serializable
      include LosslessMetadata

      # Creates a disable acknowledgement.
      def initialize(meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end

      def_equals_and_hash metadata_comparison
    end
  end
end
