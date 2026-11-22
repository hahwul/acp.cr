require "json"
require "./raw_json"

module ACP
  module Protocol
    # Draft capability marker for authentication status queries.
    struct AuthStatusCapabilities
      include JSON::Serializable
      include LosslessMetadata

      # Creates an authentication status capability marker.
      def initialize(meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end

      # :nodoc:
      def self.from_json(pull : JSON::PullParser) : AuthStatusCapabilities?
        return new(pull) if pull.kind.begin_object?

        pull.skip
        nil
      end

      # :nodoc:
      def self.to_json(value : AuthStatusCapabilities, builder : JSON::Builder) : Nil
        value.to_json(builder)
      end

      def_equals_and_hash metadata_comparison
    end

    # Parameters of the draft auth/status method.
    struct AuthStatusParams
      include JSON::Serializable
      include LosslessMetadata

      # Creates a read-only authentication status query.
      def initialize(meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end

      def_equals_and_hash metadata_comparison
    end

    # Agent-provided account information for display.
    struct AuthAccount
      include JSON::Serializable
      include LosslessOpenObject

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

      def_equals_and_hash @label, @json_unmapped, @raw_fields
    end

    # Authentication status snapshot shared by both ACP versions.
    struct AuthStatusResult
      include JSON::Serializable
      include LosslessOpenObject

      @[JSON::Field(ignore: true)]
      @accounts_wire : PreservedJson?

      # Authentication state as received, including future values.
      @[JSON::Field(key: "state")]
      getter raw_state : String

      # Creates a status snapshot with additional wire fields.
      def initialize(@raw_state : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
      end

      # Reads a snapshot with an unambiguous state.
      def self.new(pull : JSON::PullParser) : self
        previous_def(WireFrame.read_with_unique_members(pull, "state"))
      end

      protected def on_unknown_json_attribute(pull, key, key_location)
        return super unless key == "accounts"

        source = RawJson.new(pull)
        projection = source.to_json_any?
        # A fully representable list remains editable through json_unmapped.
        # Keep the entire wire array when an element cannot be projected.
        @accounts_wire = if projection.try(&.as_a?) && WireFrame.encode(projection) != source.json
                           PreservedJson.new(source, project_array_objects: true, project_nested_objects: true)
                         end
        retain_unmapped_json(key, source.json, projection: @accounts_wire.try(&.value) || projection)
      end

      protected def retained_unmapped_json(key : String, value : JSON::Any) : String?
        if key == "accounts" && (accounts = @accounts_wire) && (view = value.as_a?)
          return accounts.raw_with_array(view).json
        end

        super
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
        return [] of AuthAccount unless wire = exact_unmapped_json("accounts")
        return [] of AuthAccount unless entries = RawJson.new(JSON::PullParser.new(wire)).elements?

        entries.compact_map do |entry|
          AuthAccount.from_json(entry.json) if entry.object?
        rescue JSON::ParseException
          nil
        end
      end

      def_equals_and_hash @raw_state, @json_unmapped, @raw_fields
    end

    # The auth/status_update notification carries the same status snapshot.
    alias AuthStatusUpdateParams = AuthStatusResult
  end
end
