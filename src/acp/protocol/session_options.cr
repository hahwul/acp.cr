require "path"
require "./optional_metadata"

module ACP
  module Protocol
    # Checks absolute paths in the Agent's POSIX or Windows filesystem syntax.
    def self.absolute_path?(path : String) : Bool
      !path.includes?('\0') && (Path.posix(path).absolute? || Path.windows(path).absolute?)
    end

    # :nodoc:
    def self.absolute_workspace?(cwd : String, directories : Array(String)?) : Bool
      absolute_path?(cwd) && (directories.nil? || directories.all? { |path| absolute_path?(path) })
    end

    # Agent support for the options query and initial configuration values.
    struct SessionOptionsCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      getter meta : Hash(String, JSON::Any)?

      # Creates an options capability marker.
      def initialize(@meta : Hash(String, JSON::Any)? = nil)
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
    end

    # Agent support for forking an existing session.
    struct SessionForkCapabilities
      include JSON::Serializable

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      getter meta : Hash(String, JSON::Any)?

      # Creates a fork capability marker.
      def initialize(@meta : Hash(String, JSON::Any)? = nil)
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

      # ID of the configuration option to set.
      @[JSON::Field(key: "configId")]
      getter config_id : String

      # Value discriminator. Omission defaults to an ID in v1.
      @[JSON::Field(key: "type")]
      getter value_type : String?

      # Value ID or boolean to propose to the Agent.
      getter value : String | Bool

      # Extension metadata.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      getter meta : Hash(String, JSON::Any)?

      # Creates an initial value, explicitly tagging boolean choices.
      def initialize(@config_id : String, @value : String | Bool, @meta : Hash(String, JSON::Any)? = nil)
        @value_type = "boolean" if @value.is_a?(Bool)
      end

      private def after_initialize : Nil
        valid = @value_type == "boolean" ? @value.is_a?(Bool) : @value.is_a?(String)
        unless valid
          raise JSON::ParseException.new("Initial v1 config value does not match its type", 0, 0)
        end
      end
    end

    # :nodoc:
    def self.validate_initial_config_options(values : Array(T)) : Nil forall T
      ids = values.map(&.config_id)
      raise ArgumentError.new("Initial config option IDs must be unique") if ids.uniq.size != ids.size
    end

    # :nodoc:
    module OptionalOptionList
      def self.from_json(pull : JSON::PullParser) : Array(JSON::Any)
        values = [] of JSON::Any
        if pull.kind.begin_array?
          pull.read_array do
            json = WireFrame.read_raw(pull)
            begin
              value = JSON.parse(json)
              values << value if value.as_h?
            rescue JSON::Error
              # Keep other options when an entry cannot be represented.
            end
          end
        else
          pull.skip
        end
        values
      end

      def self.to_json(values : Array(JSON::Any), json : JSON::Builder) : Nil
        values.to_json(json)
      end
    end

    # :nodoc:
    module RequiredOptionList
      def self.from_json(pull : JSON::PullParser) : Array(JSON::Any)
        unless pull.kind.begin_array?
          raise JSON::ParseException.new("Configuration options must be an array", *pull.location)
        end
        OptionalOptionList.from_json(pull)
      end

      def self.to_json(value : Array(JSON::Any), json : JSON::Builder) : Nil
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
