require "./optional_metadata"
require "./raw_json"

module ACP
  module Protocol
    # Agent support for archiving, restoring, and listing archived sessions.
    struct SessionArchiveCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      property meta : Hash(String, JSON::Any)?

      # Creates the archive capability marker.
      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end

      # :nodoc:
      def self.from_json(pull : JSON::PullParser) : SessionArchiveCapabilities?
        if pull.kind.begin_object?
          from_json(WireFrame.read_raw(pull))
        else
          pull.skip
          nil
        end
      end

      # :nodoc:
      def self.to_json(value : SessionArchiveCapabilities, builder : JSON::Builder) : Nil
        value.to_json(builder)
      end
    end

    # :nodoc:
    abstract struct ArchiveParams
      include JSON::Serializable

      # ID of the target session.
      @[JSON::Field(key: "sessionId")]
      getter session_id : String

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      getter meta : Hash(String, JSON::Any)?

      # Creates parameters for a session archive operation.
      def initialize(@session_id : String, @meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Parameters for closing and archiving a session.
    struct SessionArchiveParams < ArchiveParams
    end

    # Parameters for restoring a session to the default list.
    struct SessionUnarchiveParams < ArchiveParams
    end

    # :nodoc:
    abstract struct ArchiveResult
      include JSON::Serializable
      include LosslessMetadata

      # Creates a successful result with optional metadata.
      def initialize(meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end
    end

    # The Agent closed and archived the session.
    struct SessionArchiveResult < ArchiveResult
    end

    # The Agent restored the session to the default list.
    struct SessionUnarchiveResult < ArchiveResult
    end

    # :nodoc:
    module ArchivedFlag
      def self.from_json(pull : JSON::PullParser) : Bool?
        return pull.read_bool if pull.kind.bool?

        pull.skip
        nil
      end
    end
  end
end
