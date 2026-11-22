require "path"
require "./optional_metadata"
require "./raw_json"

module ACP
  module Protocol
    # Checks absolute paths in the Agent's POSIX or Windows filesystem syntax.
    def self.absolute_path?(path : String) : Bool
      !path.includes?('\0') && (Path.posix(path).absolute? || Path.windows(path).absolute?)
    end

    # :nodoc:
    module OptionalAbsolutePath
      def self.from_json(pull : JSON::PullParser) : String?
        if pull.kind.string?
          value = pull.read_string
          return value if Protocol.absolute_path?(value)
        else
          pull.skip
        end
        nil
      end

      def self.to_json(value : String, json : JSON::Builder) : Nil
        json.string(value)
      end
    end

    # :nodoc:
    def self.absolute_workspace?(cwd : String, directories : Array(String)?) : Bool
      absolute_path?(cwd) && (directories.nil? || directories.all? { |path| absolute_path?(path) })
    end

    # Agent support for the options query and initial configuration values.
    struct SessionOptionsCapabilities
      include JSON::Serializable
      include LosslessMetadata

      # Creates an options capability marker.
      def initialize(meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end

      # :nodoc:
      def self.from_json(pull : JSON::PullParser) : SessionOptionsCapabilities?
        return new(pull) if pull.kind.begin_object?

        pull.skip
        nil
      end

      # :nodoc:
      def self.to_json(value : SessionOptionsCapabilities, json : JSON::Builder) : Nil
        value.to_json(json)
      end

      def_equals_and_hash metadata_comparison
    end

    # Agent support for forking an existing session.
    struct SessionForkCapabilities
      include JSON::Serializable
      include LosslessMetadata

      # Creates a fork capability marker.
      def initialize(meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end

      # :nodoc:
      def self.from_json(pull : JSON::PullParser) : SessionForkCapabilities?
        return new(pull) if pull.kind.begin_object?

        pull.skip
        nil
      end

      # :nodoc:
      def self.to_json(value : SessionForkCapabilities, json : JSON::Builder) : Nil
        value.to_json(json)
      end

      def_equals_and_hash metadata_comparison
    end

    # Workspace and optional saved session for an options preview.
    struct SessionOptionsParams
      include JSON::Serializable

      # Absolute working directory the Agent resolves settings against.
      getter cwd : String

      # Session whose restored options should be previewed.
      @[JSON::Field(key: "sessionId")]
      getter session_id : String?

      # Extra absolute workspace roots.
      @[JSON::Field(key: "additionalDirectories")]
      getter additional_directories : Array(String)?

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      getter meta : Hash(String, JSON::Any)?

      # Builds a read-only options query.
      def initialize(
        @cwd : String,
        *,
        @session_id : String? = nil,
        @additional_directories : Array(String)? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # A configuration choice to apply when setting up a v1 session.
    struct InitialSessionConfigOption
      include JSON::Serializable
      include LosslessMetadata

      # ID of the configuration option to set.
      @[JSON::Field(key: "configId")]
      getter config_id : String

      # Value discriminator. Omission defaults to an ID in v1.
      @[JSON::Field(key: "type")]
      getter value_type : String?

      # Value ID or boolean to propose to the Agent.
      getter value : String | Bool

      # Creates an initial value, explicitly tagging boolean choices.
      def initialize(@config_id : String, @value : String | Bool, meta : Hash(String, JSON::Any)? = nil)
        @value_type = "boolean" if @value.is_a?(Bool)
        self.meta = meta
      end

      private def after_initialize : Nil
        valid = @value_type == "boolean" ? @value.is_a?(Bool) : @value.is_a?(String)
        unless valid
          raise JSON::ParseException.new("Initial v1 config value does not match its type", 0, 0)
        end
      end

      def_equals_and_hash @config_id, @value_type, @value, metadata_comparison
    end

    # :nodoc:
    def self.validate_initial_config_options(values : Array(T)) : Nil forall T
      ids = values.map(&.config_id)
      raise ArgumentError.new("Initial config option IDs must be unique") if ids.uniq.size != ids.size
    end

    # :nodoc:
    module SelectableOptionArray
      def self.from_json(pull : JSON::PullParser, *, object_entries_only : Bool = false) : PreservedJson
        unless pull.kind.begin_array?
          raise JSON::ParseException.new("Configuration options must be an array", *pull.location)
        end
        wire = RawJson.new(pull)
        if object_entries_only
          items = wire.elements?.not_nil!
          objects = items.select(&.object?)
          if objects.size != items.size
            wire = RawJson.new(JSON::PullParser.new(WireFrame.encode(objects)))
          end
        end
        if (value = wire.to_json_any?) && WireFrame.encode(value) == wire.json
          return PreservedJson.new(value)
        end

        PreservedJson.new(wire, project_array_objects: true, project_nested_objects: true)
      end

      def self.to_json(value : PreservedJson, json : JSON::Builder) : Nil
        value.to_json(json)
      end
    end

    # :nodoc:
    module RequiredOptionList
      def self.from_json(pull : JSON::PullParser) : PreservedJson
        SelectableOptionArray.from_json(pull, object_entries_only: true)
      end

      def self.to_json(value : PreservedJson, json : JSON::Builder) : Nil
        value.to_json(json)
      end
    end

    # :nodoc:
    module OptionalOptionDescription
      def self.from_json(pull : JSON::PullParser) : String?
        return pull.read_string if pull.kind.string?

        pull.skip
        nil
      end

      def self.to_json(value : String, json : JSON::Builder) : Nil
        value.to_json(json)
      end
    end
  end
end
