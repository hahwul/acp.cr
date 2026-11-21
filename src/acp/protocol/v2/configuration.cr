require "../types"

module ACP
  module Protocol
    module V2
      # A named group of selectable values in an ACP v2 configuration option.
      struct ConfigOptionGroup
        include JSON::Serializable

        # Identifier for the group within the selector.
        @[JSON::Field(key: "groupId")]
        getter group_id : String

        # User-visible group label.
        getter name : String

        # Wire objects in the group's option list.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalOptionList)]
        getter options : Array(JSON::Any)

        # Extension metadata scoped to the group.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        property meta : Hash(String, JSON::Any)?

        # Creates a group with its selectable values.
        def initialize(@group_id : String, @name : String, @options : Array(JSON::Any), @meta : Hash(String, JSON::Any)? = nil)
        end

        # Returns valid selectable values in this group.
        def values : Array(Protocol::ConfigOptionValue)
          @options.compact_map { |option| Protocol::ConfigOptionValue.from_json(option.to_json) rescue nil }
        end
      end

      # An open ACP v2 configuration option with typed access to known selectors.
      struct ConfigOption
        include JSON::Serializable
        include JSON::Serializable::Unmapped

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

        # Extension metadata scoped to the option.
        def meta : Hash(String, JSON::Any)?
          @json_unmapped["_meta"]?.try(&.as_h?)
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
          return unless @type == "select" && (options = @json_unmapped["options"]?.try(&.as_a?))
          return unless first = options.first?.try(&.as_h?)

          if first.has_key?("groupId")
            options.map { |option| ConfigOptionGroup.from_json(option.to_json) }
          else
            options.map { |option| Protocol::ConfigOptionValue.from_json(option.to_json) }
          end
        rescue JSON::ParseException
          nil
        end
      end

      # An open input specification for an advertised command.
      struct CommandInput
        include JSON::Serializable
        include JSON::Serializable::Unmapped

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

        # Extension metadata scoped to the input specification.
        def meta : Hash(String, JSON::Any)?
          @json_unmapped["_meta"]?.try(&.as_h?)
        end
      end

      # An advertised command, including open variants that are not slash commands.
      struct AvailableCommand
        include JSON::Serializable
        include JSON::Serializable::Unmapped

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

        # Input specification for a recognized slash command, when available.
        def input : CommandInput?
          return unless slash_command? && (input = @json_unmapped["input"]?)

          CommandInput.from_json(input.to_json) if input.as_h?
        rescue JSON::ParseException
          nil
        end

        # Extension metadata scoped to the command.
        def meta : Hash(String, JSON::Any)?
          @json_unmapped["_meta"]?.try(&.as_h?)
        end
      end

      # Typed access to configuration options while retaining their raw values.
      module ConfigOptionList
        # Parses usable configuration entries, preserving future option types.
        def typed_config_options : Array(ConfigOption)
          config_options.compact_map do |raw|
            option = ConfigOption.from_json(WireFrame.encode(raw))
            case option.type
            when "select"  then option if option.selected_value && option.select_options
            when "boolean" then option unless option.boolean_value.nil?
            else                option
            end
          rescue JSON::Error
            nil
          end
        end
      end

      # Typed access to advertised commands while retaining their raw values.
      module AvailableCommandList
        # Parses entries that carry a v2 command discriminator, name, and description.
        def typed_available_commands : Array(AvailableCommand)
          available_commands.compact_map { |command| AvailableCommand.from_json(command.to_json) rescue nil }
        end
      end

      # Replaces the available commands advertised for a session.
      struct AvailableCommandsUpdate
        include JSON::Serializable
        include AvailableCommandList

        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "available_commands_update"

        # Complete list of currently advertised commands.
        @[JSON::Field(key: "availableCommands")]
        property available_commands : Array(JSON::Any)

        # Extension metadata scoped to the update.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates an update with replacement command advertisements.
        def initialize(@available_commands : Array(JSON::Any), @meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # Replaces the configuration options advertised for a session.
      struct ConfigOptionUpdate
        include JSON::Serializable
        include ConfigOptionList

        # Session update discriminator.
        @[JSON::Field(key: "sessionUpdate")]
        getter session_update : String = "config_option_update"

        # Complete list of the session's configuration options.
        @[JSON::Field(key: "configOptions")]
        property config_options : Array(JSON::Any)

        # Extension metadata scoped to the update.
        @[JSON::Field(key: "_meta")]
        property meta : Hash(String, JSON::Any)?

        # Creates an update with replacement configuration options.
        def initialize(@config_options : Array(JSON::Any), @meta : Hash(String, JSON::Any)? = nil)
        end
      end
    end
  end
end
