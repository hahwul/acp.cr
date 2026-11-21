require "../types"
require "./skills"

module ACP
  module Protocol
    module V2
      # :nodoc:
      module AdvertisementArray
        # Validates list fields before JSON::Serializable can collapse repeated members.
        macro guard_envelope(*members)
          def self.new(pull : JSON::PullParser) : self
            wire = ::ACP::Protocol::WireFrame.read_raw(pull)
            {% for member in members %}
              ::ACP::Protocol::WireFrame.field(wire, {{member}}, unique: true)
            {% end %}
            previous_def(JSON::PullParser.new(wire))
          end
        end

        def self.from_json(pull : JSON::PullParser, *, project_nested_objects : Bool = false) : PreservedJson
          if pull.kind.begin_array?
            wire = RawJson.new(pull)
            PreservedJson.new(wire, project_array_objects: true, object_entries_only: true, project_nested_objects: project_nested_objects)
          else
            WireFrame.read_raw(pull)
            PreservedJson.new(JSON::Any.new([] of JSON::Any))
          end
        end

        def self.to_json(value : PreservedJson, json : JSON::Builder) : Nil
          value.to_json(json)
        end
      end

      # :nodoc:
      module RequiredConfigOptionArray
        def self.from_json(pull : JSON::PullParser) : PreservedJson
          unless pull.kind.begin_array?
            raise JSON::ParseException.new("Configuration options must be an array", *pull.location)
          end
          AdvertisementArray.from_json(pull)
        end

        def self.to_json(value : PreservedJson, json : JSON::Builder) : Nil
          value.to_json(json)
        end
      end

      # A named group of selectable values in an ACP v2 configuration option.
      struct ConfigOptionGroup
        include JSON::Serializable
        include LosslessMetadata

        # Identifier for the group within the selector.
        @[JSON::Field(key: "groupId")]
        getter group_id : String

        # User-visible group label.
        getter name : String

        @[JSON::Field(key: "options", converter: ::ACP::Protocol::V2::AdvertisementArray)]
        @options_wire : PreservedJson

        # Creates a group with its selectable values.
        def initialize(@group_id : String, @name : String, options : Array(JSON::Any), meta : Hash(String, JSON::Any)? = nil)
          @options_wire = PreservedJson.new(JSON::Any.new(options))
          self.meta = meta
        end

        # Representable fields in this group's option list.
        def options : Array(JSON::Any)
          @options_wire.value.not_nil!.as_a
        end

        # Exact option values as advertised by the Agent.
        def options_raw : RawJson
          @options_wire.raw
        end

        # Returns valid selectable values in this group.
        def values : Array(Protocol::ConfigOptionValue)
          options_raw.elements?.not_nil!.compact_map do |value|
            Protocol::ConfigOptionValue.from_json(value.json) if WireFrame.unique_members?(value.json, recursive: false)
          rescue JSON::Error
            nil
          end
        end
      end

      # An open ACP v2 configuration option with typed access to known selectors.
      struct ConfigOption
        include JSON::Serializable
        include LosslessOpenObject

        # Option discriminator, such as select or boolean.
        @[JSON::Field(key: "type")]
        getter type : String

        # Identifier used when changing the option.
        @[JSON::Field(key: "configId")]
        getter config_id : String

        # User-visible option label.
        getter name : String

        # Creates an option with its variant-specific wire fields.
        def initialize(@type : String, @config_id : String, @name : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
        end

        # User-visible description when supplied.
        def description : String?
          @json_unmapped["description"]?.try(&.as_s?)
        end

        # Optional semantic category, including future categories.
        def category : String?
          @json_unmapped["category"]?.try(&.as_s?)
        end

        # Selected value for a select option.
        def selected_value : String?
          @json_unmapped["currentValue"]?.try(&.as_s?) if @type == "select"
        end

        # Current value for a boolean option, including false.
        def boolean_value : Bool?
          @json_unmapped["currentValue"]?.try(&.as_bool?) if @type == "boolean"
        end

        # Returns the selectable values as a flat list or a list of named groups.
        def select_options : Array(Protocol::ConfigOptionValue) | Array(ConfigOptionGroup) | Nil
          return unless @type == "select" && (wire = exact_unmapped_json("options"))

          options = RawJson.new(JSON::PullParser.new(wire)).elements?
          return unless options && !options.empty?

          if options.any? { |entry| entry.field("groupId").try(&.as_s?) && entry.field("options").try(&.array?) }
            grouped_select_options(options)
          else
            flat_select_options(options)
          end
        end

        # Flattens selectable values across groups.
        def selectable_values : Array(Protocol::ConfigOptionValue)?
          case choices = select_options
          when Array(Protocol::ConfigOptionValue) then choices
          when Array(ConfigOptionGroup)           then choices.flat_map(&.values)
          end
        end

        # Decodes a usable configuration snapshot in the Agent's order.
        # :nodoc:
        def self.decode_list(raw : RawJson?) : Array(ConfigOption)
          entries = raw.try(&.elements?) || return [] of ConfigOption
          ids = entries.compact_map { |entry| entry.field("configId").try(&.as_s?) }.tally
          entries.compact_map do |entry|
            option = decode_usable(entry)
            option if option && ids[option.config_id] == 1
          end
        end

        # Reads a known valid option or an unrecognized option envelope.
        # :nodoc:
        def self.decode_usable(raw : RawJson) : self?
          return unless WireFrame.unique_members?(raw.json, recursive: false)

          option = from_json(raw.json)
          case option.type
          when "select"
            if (selected = option.selected_value) && option.selectable_values.try(&.any? { |value| value.value == selected })
              option
            end
          when "boolean" then option unless option.boolean_value.nil?
          else                option
          end
        rescue JSON::Error
          nil
        end

        private def flat_select_options(options : Array(RawJson)) : Array(Protocol::ConfigOptionValue)?
          values = options.map do |option|
            return unless WireFrame.unique_members?(option.json, recursive: false)
            Protocol::ConfigOptionValue.from_json(option.json)
          end
          values if unique_values?(values)
        rescue JSON::Error
          nil
        end

        private def grouped_select_options(options : Array(RawJson)) : Array(ConfigOptionGroup)?
          values = [] of Protocol::ConfigOptionValue
          groups = options.map do |option|
            return unless WireFrame.unique_members?(option.json, recursive: false)

            group = ConfigOptionGroup.from_json(option.json)
            group_values = group.values
            return if group_values.empty?
            values.concat(group_values)
            group
          end
          groups if groups.map(&.group_id).uniq.size == groups.size && unique_values?(values)
        rescue JSON::Error
          nil
        end

        private def unique_values?(values : Array(Protocol::ConfigOptionValue)) : Bool
          values.map(&.value).uniq.size == values.size
        end
      end

      # An open input specification for an advertised command.
      struct CommandInput
        include JSON::Serializable
        include LosslessOpenObject

        # Input discriminator, including the standard text kind.
        @[JSON::Field(key: "type")]
        getter type : String

        # Creates an input specification with variant-specific fields.
        def initialize(@type : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
        end

        # Text hint for the standard free-text input specification.
        def text_hint : String?
          @json_unmapped["hint"]?.try(&.as_s?) if @type == "text"
        end
      end

      # An advertised command, including open variants that are not slash commands.
      struct AvailableCommand
        include JSON::Serializable
        include LosslessOpenObject

        # Command discriminator, such as command for slash commands.
        @[JSON::Field(key: "type")]
        getter type : String

        # Command name without its slash prefix.
        getter name : String

        # Human-readable description of the command.
        getter description : String

        # Creates a command with variant-specific fields.
        def initialize(@type : String, @name : String, @description : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
        end

        # Whether the client may display this variant as a slash command.
        def slash_command? : Bool
          @type == "command"
        end

        # Projects a valid skill advertisement without interpreting its path.
        def skill : Skill?
          return unless @type == "skill" && Skill.valid_name?(@name)

          Skill.from_json(WireFrame.encode(self))
        end

        # Input specification for a recognized slash command, when available.
        def input : CommandInput?
          return unless slash_command?

          raw = exact_unmapped_json("input")
          return unless raw && WireFrame.unique_members?(raw, recursive: false)

          input = CommandInput.from_json(raw)
          input if input.type != "text" || input.text_hint
        rescue JSON::Error
          nil
        end
      end

      # Typed access to configuration options.
      module ConfigOptionList
        # Parses usable configuration entries, preserving future option types.
        def typed_config_options : Array(ConfigOption)
          ConfigOption.decode_list(config_options_raw)
        end

        # The configuration option objects as JSON.
        def config_options_raw : RawJson
          RawJson.new(JSON::PullParser.new(WireFrame.encode(config_options)))
        end
      end

      # :nodoc:
      module LosslessConfigOptionList
        include ConfigOptionList

        # Representable fields on the advertised configuration options.
        def config_options : Array(JSON::Any)
          @config_options_wire.value.not_nil!.as_a
        end

        # Replaces the full advertised list.
        def config_options=(options : Array(JSON::Any)) : Array(JSON::Any)
          @config_options_wire = PreservedJson.new(JSON::Any.new(options))
          options
        end

        # The configuration option objects with their exact JSON values.
        def config_options_raw : RawJson
          @config_options_wire.raw
        end
      end

      # Typed access to advertised commands.
      module AvailableCommandList
        # Parses unambiguous commands in the Agent's order.
        def typed_available_commands : Array(AvailableCommand)
          AvailableCommandsJson.decode_list(available_commands_raw)
        end

        # Parses unambiguous skill entries.
        def typed_available_skills : Array(Skill)
          typed_available_commands.compact_map(&.skill)
        end

        # The advertised command array as JSON.
        def available_commands_raw : RawJson
          RawJson.new(JSON::PullParser.new(WireFrame.encode(available_commands)))
        end
      end

      # :nodoc:
      module LosslessAvailableCommandList
        include AvailableCommandList

        # Representable command fields, including available input hints.
        def available_commands : Array(JSON::Any)
          @available_commands_wire.value.not_nil!.as_a
        end

        # Replaces the advertised list.
        def available_commands=(commands : Array(JSON::Any)) : Array(JSON::Any)
          @available_commands_wire = PreservedJson.new(JSON::Any.new(commands))
          commands
        end

        # The exact advertised list, including extension values.
        def available_commands_raw : RawJson
          @available_commands_wire.raw
        end
      end

      # :nodoc:
      module AvailableCommandsJson
        def self.from_json(pull : JSON::PullParser) : PreservedJson
          AdvertisementArray.from_json(pull, project_nested_objects: true)
        end

        def self.to_json(value : PreservedJson, json : JSON::Builder) : Nil
          value.to_json(json)
        end

        def self.decode_list(raw : RawJson) : Array(AvailableCommand)
          entries = raw.elements? || return [] of AvailableCommand
          names = entries.compact_map { |entry| entry.field("name").try(&.as_s?) }.tally
          entries.compact_map do |entry|
            command = typed_command(entry.json)
            command if command && names[command.name] == 1
          end
        end

        private def self.typed_command(raw : String) : AvailableCommand?
          return unless WireFrame.unique_members?(raw, recursive: false)

          command = AvailableCommand.from_json(raw)
          return unless Skill.valid_name?(command.name)
          return if command.slash_command? && command.name.starts_with?('/')

          command
        rescue JSON::Error
          nil
        end
      end

      # :nodoc:
      module RequiredAvailableCommands
        def self.from_json(pull : JSON::PullParser) : PreservedJson
          unless pull.kind.begin_array?
            raise JSON::ParseException.new("Available commands must be an array", *pull.location)
          end
          AvailableCommandsJson.from_json(pull)
        end

        def self.to_json(value : PreservedJson, json : JSON::Builder) : Nil
          AvailableCommandsJson.to_json(value, json)
        end
      end

      # Replaces the available commands advertised for a session.
      struct AvailableCommandsUpdate
        include JSON::Serializable
        include LosslessAvailableCommandList
        include LosslessMetadata

        AdvertisementArray.guard_envelope "availableCommands"

        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "available_commands_update"

        @[JSON::Field(key: "availableCommands", converter: ::ACP::Protocol::V2::RequiredAvailableCommands)]
        @available_commands_wire : PreservedJson

        # Creates an update with replacement command advertisements.
        def initialize(available_commands : Array(JSON::Any), meta : Hash(String, JSON::Any)? = nil)
          @available_commands_wire = PreservedJson.new(JSON::Any.new(available_commands))
          self.meta = meta
        end
      end

      # Replaces the configuration options advertised for a session.
      struct ConfigOptionUpdate
        include JSON::Serializable
        include LosslessConfigOptionList
        include LosslessMetadata

        AdvertisementArray.guard_envelope "configOptions"

        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "config_option_update"

        @[JSON::Field(key: "configOptions", converter: ::ACP::Protocol::V2::RequiredConfigOptionArray)]
        @config_options_wire : PreservedJson

        # Creates an update with replacement configuration options.
        def initialize(config_options : Array(JSON::Any), meta : Hash(String, JSON::Any)? = nil)
          @config_options_wire = PreservedJson.new(JSON::Any.new(config_options))
          self.meta = meta
        end
      end
    end
  end
end
