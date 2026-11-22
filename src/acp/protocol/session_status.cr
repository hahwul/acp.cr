require "./optional_metadata"
require "./raw_json"

module ACP
  module Protocol
    # Agent capability marker for draft session status queries.
    struct SessionStatusCapabilities
      include JSON::Serializable
      include LosslessMetadata

      # Creates an optional status capability.
      def initialize(meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end

      # :nodoc:
      def self.from_json(pull : JSON::PullParser) : SessionStatusCapabilities?
        if pull.kind.begin_object?
          from_json(WireFrame.read_raw(pull))
        else
          pull.skip
          nil
        end
      end

      # :nodoc:
      def self.to_json(value : SessionStatusCapabilities, builder : JSON::Builder) : Nil
        value.to_json(builder)
      end

      def_equals_and_hash metadata_comparison
    end

    # Parameters of the draft read-only session/status query.
    struct SessionStatusParams
      include JSON::Serializable

      # Agent-owned ID of the session to inspect.
      @[JSON::Field(key: "sessionId")]
      property session_id : String

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      # Creates a status query.
      def initialize(@session_id : String, @meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Session status fields shared by the v1 and v2 responses.
    abstract struct SessionStatusSnapshot
      include JSON::Serializable
      include LosslessMetadata

      # Reported status, including future wire values.
      @[JSON::Field(key: "status")]
      getter raw_status : String

      # Returns open or saved. Future statuses behave like saved.
      def status : String
        open? ? "open" : "saved"
      end

      # Whether the Agent currently has this session in memory.
      def open? : Bool
        @raw_status == "open"
      end
    end

    # A read-only v1 snapshot of the Agent's session status.
    struct SessionStatusResult < SessionStatusSnapshot
      # Creates a status result.
      def initialize(@raw_status : String, meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end
    end
  end
end
