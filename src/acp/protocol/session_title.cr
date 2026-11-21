require "./optional_metadata"

module ACP
  module Protocol
    # Agent capability marker for setting a session title.
    struct SessionTitleCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      # Creates an optional title capability.
      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end

      # :nodoc:
      def self.from_json(pull : JSON::PullParser) : SessionTitleCapabilities?
        if pull.kind.begin_object?
          from_json(WireFrame.read_raw(pull))
        else
          pull.skip
          nil
        end
      end

      # :nodoc:
      def self.to_json(value : SessionTitleCapabilities, builder : JSON::Builder) : Nil
        value.to_json(builder)
      end
    end

    # Parameters of the draft session/set_title request in v1 and v2.
    struct SetSessionTitleParams
      include JSON::Serializable

      # Agent-owned ID of the session to retitle.
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # The proposed session title.
      property title : String

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      # Creates a request to set a session title.
      def initialize(@session_id : String, @title : String, @meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # The title stored by the Agent after any normalization.
    struct SetSessionTitleResult
      include JSON::Serializable

      # The stored title to display.
      property title : String

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      # Creates a result with the title stored by the Agent.
      def initialize(@title : String, @meta : Hash(String, JSON::Any)? = nil)
      end
    end
  end
end
