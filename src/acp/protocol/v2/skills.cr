require "../raw_json"
require "../content_block"
require "../optional_capability"
require "../optional_metadata"
require "../session_options"

module ACP
  module Protocol
    module V2
      # Presence advertises a skill capability with no named fields.
      struct SkillCapability
        include JSON::Serializable
        include LosslessUnmapped

        # Extension metadata scoped to this capability.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        getter meta : Hash(String, JSON::Any)?

        # Creates a support marker.
        def initialize(@meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # The client can present skill entries in the session's command list.
      alias CommandsSkillCapabilities = SkillCapability

      # The Agent accepts skill references at any position in a prompt.
      alias PromptSkillInlineCapabilities = SkillCapability

      # Command variants a client can present in addition to slash commands.
      struct CommandsCapabilities
        include JSON::Serializable
        include LosslessUnmapped

        # Presence allows the Agent to advertise skill commands.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::V2::CommandsSkillCapabilities))]
        getter skill : CommandsSkillCapabilities?

        # Extension metadata scoped to the command capabilities.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        getter meta : Hash(String, JSON::Any)?

        # Creates the optional command capability group.
        def initialize(@skill : CommandsSkillCapabilities? = nil, @meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # Skill references accepted by the Agent in a prompt.
      struct PromptSkillCapabilities
        include JSON::Serializable
        include LosslessUnmapped

        # Presence allows multiple skill references at any position.
        @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::V2::PromptSkillInlineCapabilities))]
        getter inline : PromptSkillInlineCapabilities?

        # Extension metadata scoped to the skill prompt capability.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        getter meta : Hash(String, JSON::Any)?

        # Creates a leading-skill capability with optional inline support.
        def initialize(@inline : PromptSkillInlineCapabilities? = nil, @meta : Hash(String, JSON::Any)? = nil)
        end
      end

      # A selectable Agent skill advertised as a session command.
      struct Skill
        include JSON::Serializable

        # :nodoc:
        alias OptionalPath = Protocol::OptionalAbsolutePath

        # Wire discriminator for skill entries.
        getter type : String = "skill"

        # Name used to refer to the skill in a prompt.
        getter name : String

        # Description intended for display.
        getter description : String

        # Optional absolute path on the Agent's filesystem.
        @[JSON::Field(converter: ::ACP::Protocol::V2::Skill::OptionalPath)]
        getter path : String?

        # Extension metadata scoped to the entry.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        getter meta : Hash(String, JSON::Any)?

        # Creates an advertised skill.
        def initialize(@name : String, @description : String, path : String? = nil, @meta : Hash(String, JSON::Any)? = nil)
          @path = path if path && Protocol.absolute_path?(path)
        end

        # Whether a name can identify a skill in a v2 command list.
        def self.valid_name?(name : String) : Bool
          !name.empty? && !name.each_char.any?(&.whitespace?)
        end
      end

      # A user-selected reference to an advertised Agent skill.
      struct SkillReference
        include JSON::Serializable

        # Wire discriminator for skill references.
        getter type : String = "skill"

        # Name of a skill in the session's current command list.
        getter name : String

        # Extension metadata scoped to the reference.
        @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
        getter meta : Hash(String, JSON::Any)?

        # Builds a reference without opening the skill's file.
        def initialize(@name : String, @meta : Hash(String, JSON::Any)? = nil)
          raise ArgumentError.new("Invalid ACP skill name") unless Skill.valid_name?(@name)
        end

        # Parses a well-formed skill reference from an open content block.
        def self.from_content_block(block : JSON::Any) : self?
          return unless block.as_h?.try(&.["type"]?).try(&.as_s?) == "skill"

          decode_reference(WireFrame.encode(block))
        rescue JSON::Error
          nil
        end

        # Parses a skill reference from exact JSON.
        def self.from_content_block(block : RawJson) : self?
          return unless block.field("type").try(&.as_s?) == "skill" && WireFrame.unique_members?(block.json)

          decode_reference(block.json)
        rescue JSON::Error
          nil
        end

        private def self.decode_reference(json : String) : self?
          reference = from_json(json)
          reference if Skill.valid_name?(reference.name)
        end
      end

      # Standard typed prompt blocks and v2 skill references.
      alias PromptContentBlock = Protocol::ContentBlock | SkillReference
    end
  end
end
