require "json"
require "../capabilities"
require "../types"
require "../raw_json"
require "./skills"

module ACP
  module Protocol
    # Wire types for the ACP v2 Preview schema.
    module V2
      # Protocol version carried in ACP v2 initialize requests.
      VERSION = 2_u16

      # Name, version, display title and metadata for either peer.
      alias Implementation = Protocol::ClientInfo

      # Parameters of the draft auth/status query.
      alias AuthStatusParams = Protocol::AuthStatusParams

      # Authentication status returned by the draft query.
      alias AuthStatusResult = Protocol::AuthStatusResult

      # Authentication status delivered by a draft update notification.
      alias AuthStatusUpdateParams = Protocol::AuthStatusUpdateParams

      # Draft provider configuration uses the same payloads in v1 and v2.
      alias ProvidersCapabilities = Protocol::ProvidersCapabilities
      alias ProviderId = Protocol::ProviderId
      alias LlmProtocol = Protocol::LlmProtocol
      alias ProviderCurrentConfig = Protocol::ProviderCurrentConfig
      alias ProviderInfo = Protocol::ProviderInfo
      alias ListProvidersParams = Protocol::ListProvidersParams
      alias ListProvidersResult = Protocol::ListProvidersResult
      alias SetProviderParams = Protocol::SetProviderParams
      alias SetProviderResult = Protocol::SetProviderResult
      alias DisableProviderParams = Protocol::DisableProviderParams
      alias DisableProviderResult = Protocol::DisableProviderResult

      # Draft MCP-over-ACP declarations and message envelopes.
      alias McpServerAcp = Protocol::McpServerAcp
      alias McpServerAcpId = Protocol::McpServerAcpId
      alias McpRequestId = Protocol::McpRequestId
      alias McpJson = Protocol::McpJson
      alias McpError = Protocol::McpError
      alias MessageMcpRequest = Protocol::MessageMcpRequest
      alias MessageMcpNotification = Protocol::MessageMcpNotification
      alias MessageMcpResponse = Protocol::MessageMcpResponse

      # Presence advertises support for a feature with no named fields.
      struct Capability
        include JSON::Serializable
        include LosslessUnmapped

        # Extension metadata.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        property meta : Hash(String, JSON::Any)?

        # Creates a support marker.
        def initialize(@meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # Authentication features advertised by a v2 client.
      struct ClientAuthCapabilities
        include JSON::Serializable

        # Presence advertises interactive terminal authentication.
        property terminal : Capability?

        # Extension metadata.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates the authentication capability group.
        def initialize(@terminal : Capability? = nil, @meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # Advertises which prompt suggestions the client can present.
      alias PromptSuggestionsCapabilities = Protocol::PromptSuggestionsCapabilities

      # Presence advertises support for suggestions containing images.
      alias PromptSuggestionsImageCapabilities = Protocol::PromptSuggestionsImageCapabilities

      # Presence advertises support for suggestions containing audio.
      alias PromptSuggestionsAudioCapabilities = Protocol::PromptSuggestionsAudioCapabilities

      # Presence advertises support for suggestions containing embedded resources.
      alias PromptSuggestionsEmbeddedContextCapabilities = Protocol::PromptSuggestionsEmbeddedContextCapabilities

      # Session features that the v2 client can present.
      struct ClientSessionCapabilities
        include JSON::Serializable
        include LosslessUnmapped

        # Presence advertises support for draft prompt suggestions.
        @[JSON::Field(key: "promptSuggestions", converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::PromptSuggestionsCapabilities))]
        property prompt_suggestions : PromptSuggestionsCapabilities?

        # Additional command types understood by this client.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::V2::CommandsCapabilities))]
        property commands : CommandsCapabilities?

        # Extension metadata scoped to the session capabilities.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        property meta : Hash(String, JSON::Any)?

        # Creates the session capability group.
        def initialize(
          @prompt_suggestions : PromptSuggestionsCapabilities? = nil,
          @meta : Hash(String, JSON::Any)? = nil,
          @commands : CommandsCapabilities? = nil,
        )
        end
      end

      # Optional capabilities sent by the v2 client during initialize.
      struct ClientCapabilities
        include JSON::Serializable

        # Authentication capabilities.
        property auth : ClientAuthCapabilities?

        # Supported elicitation modes.
        property elicitation : Protocol::ElicitationCapabilities?

        # Session features supported by the client.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::V2::ClientSessionCapabilities))]
        property session : ClientSessionCapabilities?

        # Extension metadata.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates client capabilities.
        def initialize(
          @auth : ClientAuthCapabilities? = nil,
          @elicitation : Protocol::ElicitationCapabilities? = nil,
          @meta : Hash(String, JSON::Any)? = nil,
          @session : ClientSessionCapabilities? = nil,
        )
        end
      end

      # Interprets an Agent's exact initialize capabilities for a custom prompt type.
      alias PromptContentTypeResolver = (String, RawJson -> Bool)

      # Additional content types accepted in prompts.
      struct PromptCapabilities
        include JSON::Serializable

        # Presence advertises image content.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::V2::Capability))]
        property image : Capability?

        # Presence advertises audio content.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::V2::Capability))]
        property audio : Capability?

        # Presence advertises embedded resource content.
        @[JSON::Field(key: "embeddedContext", converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::V2::Capability))]
        property embedded_context : Capability?

        # Presence allows a skill reference at the start of a prompt.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::V2::PromptSkillCapabilities))]
        property skill : PromptSkillCapabilities?

        # Extension metadata.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        property meta : Hash(String, JSON::Any)?

        # Creates prompt capabilities.
        def initialize(
          @image : Capability? = nil,
          @audio : Capability? = nil,
          @embedded_context : Capability? = nil,
          @meta : Hash(String, JSON::Any)? = nil,
          @skill : PromptSkillCapabilities? = nil,
        )
        end
      end

      # MCP server transports the v2 agent accepts.
      struct McpCapabilities
        include JSON::Serializable

        # Presence advertises stdio MCP servers.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::V2::Capability))]
        property stdio : Capability?

        # Presence advertises HTTP MCP servers.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::V2::Capability))]
        property http : Capability?

        # Presence advertises support for servers hosted over ACP.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::V2::Capability))]
        property acp : Capability?

        # Extension metadata.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        property meta : Hash(String, JSON::Any)?

        # Creates the transport capability group.
        def initialize(
          @stdio : Capability? = nil,
          @http : Capability? = nil,
          @meta : Hash(String, JSON::Any)? = nil,
          @acp : Capability? = nil,
        )
        end
      end

      # Optional features available for v2 sessions.
      struct SessionCapabilities
        include JSON::Serializable

        # Additional prompt content that the Agent accepts.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::V2::PromptCapabilities))]
        property prompt : PromptCapabilities?

        # MCP transports supported by the Agent.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::V2::McpCapabilities))]
        property mcp : McpCapabilities?

        # Presence advertises session deletion.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::SessionDeleteCapabilities))]
        property delete : Protocol::SessionDeleteCapabilities?

        # Presence advertises support for additional workspace directories.
        @[JSON::Field(key: "additionalDirectories", converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::SessionAdditionalDirectoriesCapabilities))]
        property additional_directories : Protocol::SessionAdditionalDirectoriesCapabilities?

        # Client-supplied system prompt support.
        @[JSON::Field(key: "systemPrompt", converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::SessionSystemPromptCapabilities))]
        property system_prompt : Protocol::SessionSystemPromptCapabilities?

        # When present, the Agent supports the draft session/status query.
        @[JSON::Field(converter: ::ACP::Protocol::SessionStatusCapabilities)]
        property status : Protocol::SessionStatusCapabilities?

        # When present, the Agent supports setting session titles.
        @[JSON::Field(converter: ::ACP::Protocol::SessionTitleCapabilities)]
        property title : Protocol::SessionTitleCapabilities?

        # When present, the Agent supports archiving, restoration, and archive filters.
        @[JSON::Field(converter: ::ACP::Protocol::SessionArchiveCapabilities)]
        property archive : Protocol::SessionArchiveCapabilities?

        # Presence advertises session/options and initial configuration values.
        @[JSON::Field(converter: ::ACP::Protocol::SessionOptionsCapabilities)]
        property options : Protocol::SessionOptionsCapabilities?

        # Presence advertises support for forking an existing session.
        @[JSON::Field(converter: ::ACP::Protocol::SessionForkCapabilities)]
        property fork : Protocol::SessionForkCapabilities?

        # Extension metadata.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        property meta : Hash(String, JSON::Any)?

        # Creates the session capability group.
        def initialize(
          @prompt : PromptCapabilities? = nil,
          @mcp : McpCapabilities? = nil,
          @delete : Protocol::SessionDeleteCapabilities? = nil,
          @additional_directories : Protocol::SessionAdditionalDirectoriesCapabilities? = nil,
          @system_prompt : Protocol::SessionSystemPromptCapabilities? = nil,
          @meta : Hash(String, JSON::Any)? = nil,
          @status : Protocol::SessionStatusCapabilities? = nil,
          @title : Protocol::SessionTitleCapabilities? = nil,
          @archive : Protocol::SessionArchiveCapabilities? = nil,
          @options : Protocol::SessionOptionsCapabilities? = nil,
          @fork : Protocol::SessionForkCapabilities? = nil,
        )
        end
      end

      # Optional capabilities returned by the Agent during v2 initialize.
      struct AgentCapabilities
        include JSON::Serializable

        # Capabilities scoped to sessions.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::V2::SessionCapabilities))]
        property session : SessionCapabilities?

        # Optional authentication extensions.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::V2::Capability))]
        property auth : Capability?

        # Presence advertises draft provider configuration methods.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::ProvidersCapabilities))]
        property providers : ProvidersCapabilities?

        # Extension metadata.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        property meta : Hash(String, JSON::Any)?

        # Creates the agent capability group.
        def initialize(
          @session : SessionCapabilities? = nil,
          @auth : Capability? = nil,
          @meta : Hash(String, JSON::Any)? = nil,
          @providers : ProvidersCapabilities? = nil,
        )
        end

        # Whether the Agent advertised the draft auth/status capability.
        def auth_status? : Bool
          !@auth.try(&.json_unmapped["status"]?).try(&.as_h?).nil?
        end
      end

      # The additional launch configuration of a terminal authentication method.
      struct TerminalAuthSettings
        include JSON::Serializable

        # Arguments appended to the configured Agent invocation.
        property args : Array(String) = [] of String

        # Variables overlaid on the configured Agent environment.
        property env : Array(Protocol::EnvVariable) = [] of Protocol::EnvVariable

        # Creates terminal launch settings.
        def initialize(@args : Array(String) = [] of String, @env : Array(Protocol::EnvVariable) = [] of Protocol::EnvVariable)
        end

        # Environment overlay for process launch. Later entries override earlier ones.
        def environment : Hash(String, String)
          @env.to_h { |entry| {entry.name, entry.value} }
        end
      end

      # An advertised v2 authentication method. Variant-specific and extension
      # fields are retained in `json_unmapped` for forwarding or inspection.
      struct AuthMethod
        include JSON::Serializable
        include LosslessUnmapped

        # Wire discriminator. Known values are `agent` and `terminal`.
        @[JSON::Field(key: "type")]
        getter method_type : String

        # Method identifier used by the selected authentication flow.
        @[JSON::Field(key: "methodId")]
        getter method_id : String

        # Human-readable name of the method.
        getter name : String

        # Creates an authentication method with its variant-specific fields.
        def initialize(
          @method_type : String,
          @method_id : String,
          @name : String,
          @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any,
        )
        end

        # Description intended for the user.
        def description : String?
          @json_unmapped["description"]?.try(&.as_s?)
        end

        # Extension metadata.
        def meta : Hash(String, JSON::Any)?
          @json_unmapped["_meta"]?.try(&.as_h?)
        end

        # Whether the Agent performs this flow via auth/login.
        def agent? : Bool
          @method_type == "agent"
        end

        # Whether the flow uses a separate interactive Agent invocation.
        def terminal? : Bool
          @method_type == "terminal"
        end

        # Parsed launch settings for a terminal method.
        def terminal_settings : TerminalAuthSettings?
          return unless terminal?

          TerminalAuthSettings.from_json(@json_unmapped.to_json)
        rescue JSON::ParseException
          nil
        end
      end

      # :nodoc:
      module OptionalAuthMethods
        def self.from_json(pull : JSON::PullParser) : Array(AuthMethod)
          methods = [] of AuthMethod
          unless pull.kind.begin_array?
            pull.skip
            return methods
          end

          pull.read_array do
            raw = WireFrame.read_raw(pull)
            begin
              methods << AuthMethod.from_json(raw)
            rescue JSON::ParseException
              # Keep usable methods next to malformed entries.
            end
          end
          methods
        end

        def self.to_json(methods : Array(AuthMethod), builder : JSON::Builder) : Nil
          methods.to_json(builder)
        end
      end

      # Parameters of an ACP v2 initialize request.
      struct InitializeParams
        include JSON::Serializable

        # Highest supported protocol version offered in the handshake.
        @[JSON::Field(key: "protocolVersion")]
        property protocol_version : UInt16

        # Required client implementation information.
        property info : Implementation

        # Client features.
        property capabilities : ClientCapabilities = ClientCapabilities.new

        # Extension metadata.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates an initialization offer in the ACP v2 format.
        def initialize(
          @info : Implementation,
          @protocol_version : UInt16 = VERSION,
          @capabilities : ClientCapabilities = ClientCapabilities.new,
          @meta : Hash(String, JSON::Any)? = nil,
        )
        end
      end

      # Successful initialize result encoded in the ACP v2 format.
      struct InitializeResult
        include JSON::Serializable

        # Chosen protocol version.
        @[JSON::Field(key: "protocolVersion")]
        property protocol_version : UInt16

        # Required agent implementation information.
        property info : Implementation

        # Agent features.
        @[JSON::Field(converter: ::ACP::Protocol::DefaultCapabilityObject(::ACP::Protocol::V2::AgentCapabilities))]
        property capabilities : AgentCapabilities = AgentCapabilities.new

        # Advertised authentication methods.
        @[JSON::Field(key: "authMethods", converter: ::ACP::Protocol::V2::OptionalAuthMethods)]
        property auth_methods : Array(AuthMethod) = [] of AuthMethod

        # Extension metadata.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        property meta : Hash(String, JSON::Any)?

        # Creates a successful ACP v2 initialize result.
        def initialize(
          @info : Implementation,
          @protocol_version : UInt16 = VERSION,
          @capabilities : AgentCapabilities = AgentCapabilities.new,
          @auth_methods : Array(AuthMethod) = [] of AuthMethod,
          @meta : Hash(String, JSON::Any)? = nil,
        )
        end
      end

      # Structured data for an Unsupported protocol version error (-32022).
      struct UnsupportedProtocolVersionData
        include JSON::Serializable

        # Protocol version requested by the client.
        property requested : UInt16

        # Protocol versions supported by the Agent.
        property supported : Array(UInt16)

        # Extension metadata.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates version negotiation error data.
        def initialize(@requested : UInt16, @supported : Array(UInt16), @meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # Parameters of an Agent-managed auth/login request.
      struct AuthLoginParams
        include JSON::Serializable

        # Advertised method identifier.
        @[JSON::Field(key: "methodId")]
        property method_id : String

        # Extension metadata.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates a login request for the specified method.
        def initialize(@method_id : String, @meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # Empty successful auth/login result with optional metadata.
      alias AuthLoginResult = Protocol::AuthenticateResult

      # Empty auth/logout parameters with optional metadata.
      alias AuthLogoutParams = Protocol::LogoutParams

      # Empty successful auth/logout result with optional metadata.
      alias AuthLogoutResult = Protocol::LogoutResult
    end
  end
end
