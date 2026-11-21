require "json"

module ACP
  module Protocol
    # Draft capability marker for authentication status queries.
    struct AuthStatusCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      # Creates an authentication status capability marker.
      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end

      # :nodoc:
      def self.from_json(pull : JSON::PullParser) : AuthStatusCapabilities?
        if fields = JSON::Any.new(pull).as_h?
          new(fields["_meta"]?.try(&.as_h?))
        end
      end

      # :nodoc:
      def self.to_json(value : AuthStatusCapabilities, builder : JSON::Builder) : Nil
        value.to_json(builder)
      end
    end

    # Parameters of the draft auth/status method.
    struct AuthStatusParams
      include JSON::Serializable

      # Extension metadata scoped to the query.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      # Creates a read-only authentication status query.
      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Agent-provided account information for display.
    struct AuthAccount
      include JSON::Serializable
      include JSON::Serializable::Unmapped

      # Human-readable account label.
      getter label : String

      # Creates an account with additional display fields.
      def initialize(@label : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
      end

      # Account or credential source description.
      def description : String?
        @json_unmapped["description"]?.try(&.as_s?)
      end

      # Whether the Agent uses this account by default, if reported.
      def active : Bool?
        @json_unmapped["active"]?.try(&.as_bool?)
      end

      # Display name of the account user.
      def name : String?
        @json_unmapped["name"]?.try(&.as_s?)
      end

      # Display email of the account user.
      def email : String?
        @json_unmapped["email"]?.try(&.as_s?)
      end

      # Display name of the organization, team or workspace.
      def organization : String?
        @json_unmapped["organization"]?.try(&.as_s?)
      end

      # Extension metadata scoped to this account.
      def meta : Hash(String, JSON::Any)?
        @json_unmapped["_meta"]?.try(&.as_h?)
      end
    end

    # Authentication status snapshot shared by both ACP versions.
    struct AuthStatusResult
      include JSON::Serializable
      include JSON::Serializable::Unmapped

      # Authentication state as received, including future values.
      @[JSON::Field(key: "state")]
      getter raw_state : String

      # Creates a status snapshot with additional wire fields.
      def initialize(@raw_state : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
      end

      # The known state, treating future values as unknown.
      def state : String
        case @raw_state
        when "authenticated", "unauthenticated", "not_required" then @raw_state
        else                                                         "unknown"
        end
      end

      # Reported accounts for display. Invalid entries are skipped.
      def accounts : Array(AuthAccount)
        return [] of AuthAccount unless entries = @json_unmapped["accounts"]?.try(&.as_a?)

        entries.compact_map { |entry| AuthAccount.from_json(entry.to_json) rescue nil }
      end

      # Extension metadata scoped to the snapshot.
      def meta : Hash(String, JSON::Any)?
        @json_unmapped["_meta"]?.try(&.as_h?)
      end
    end

    # The auth/status_update notification carries the same status snapshot.
    alias AuthStatusUpdateParams = AuthStatusResult
  end
end
