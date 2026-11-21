require "set"
require "./content_block"
require "./optional_metadata"
require "./optional_capability"

module ACP
  module Protocol
    # Presence advertises support for an additional suggestion content type.
    struct PromptSuggestionContentCapabilities
      include JSON::Serializable

      # Extension metadata for this content type.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      getter meta : Hash(String, JSON::Any)?

      # Creates a content type support marker.
      def initialize(@meta : Hash(String, JSON::Any)? = nil)
      end
    end

    # Presence advertises support for suggestions containing images.
    alias PromptSuggestionsImageCapabilities = PromptSuggestionContentCapabilities

    # Presence advertises support for suggestions containing audio.
    alias PromptSuggestionsAudioCapabilities = PromptSuggestionContentCapabilities

    # Presence advertises support for suggestions containing embedded resources.
    alias PromptSuggestionsEmbeddedContextCapabilities = PromptSuggestionContentCapabilities

    # Advertises which prompt suggestions the client can present.
    struct PromptSuggestionsCapabilities
      include JSON::Serializable

      # Presence allows suggestions with image content.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::PromptSuggestionsImageCapabilities))]
      getter image : PromptSuggestionsImageCapabilities?

      # Presence allows suggestions with audio content.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::PromptSuggestionsAudioCapabilities))]
      getter audio : PromptSuggestionsAudioCapabilities?

      # Presence allows suggestions with embedded resources.
      @[JSON::Field(key: "embeddedContext", converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::PromptSuggestionsEmbeddedContextCapabilities))]
      getter embedded_context : PromptSuggestionsEmbeddedContextCapabilities?

      # Extension metadata for the suggestion capability.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      getter meta : Hash(String, JSON::Any)?

      # Advertises baseline text and resource links plus any supplied options.
      def initialize(
        @image : PromptSuggestionsImageCapabilities? = nil,
        @audio : PromptSuggestionsAudioCapabilities? = nil,
        @embedded_context : PromptSuggestionsEmbeddedContextCapabilities? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end

      # :nodoc:
      def content_types(*, image : Bool, audio : Bool, embedded_context : Bool) : Set(String)
        allowed = Set{"text", "resource_link"}
        allowed.add("image") if @image && image
        allowed.add("audio") if @audio && audio
        allowed.add("resource") if @embedded_context && embedded_context
        allowed
      end
    end

    # :nodoc:
    struct PromptSuggestionOf(Block)
      include JSON::Serializable

      # Ordered content blocks ready to use in a prompt after user acceptance.
      getter prompt : Array(Block)

      # Extension metadata specific to this suggestion.
      @[JSON::Field(key: "_meta", converter: ::ACP::Protocol::OptionalMetadata)]
      getter meta : Hash(String, JSON::Any)?

      # Creates a suggestion from its complete prompt.
      def initialize(@prompt : Array(Block), @meta : Hash(String, JSON::Any)? = nil)
      end

      # :nodoc:
      def usable? : Bool
        has_content = false
        @prompt.each do |value|
          block = parse_block(value)
          case block
          when TextContentBlock
            has_content ||= !block.text.blank?
          when ResourceContentBlock
            return false unless block.uri && (block.text || block.blob)
            has_content = true
          else
            has_content = true
          end
        end
        has_content
      rescue JSON::Error
        false
      end

      # :nodoc:
      def allowed?(types : Set(String)) : Bool
        @prompt.all? { |block| types.includes?(block_type(block)) }
      end

      private def parse_block(block : ContentBlock) : ContentBlock
        block
      end

      private def parse_block(block : JSON::Any) : ContentBlock
        ContentBlock.from_json(WireFrame.encode(block))
      end

      private def block_type(block : ContentBlock) : String
        block.type
      end

      private def block_type(block : JSON::Any) : String
        block["type"].as_s
      end
    end

    # A v1 candidate for the next user prompt.
    alias PromptSuggestion = PromptSuggestionOf(ContentBlock)

    # :nodoc:
    module PromptSuggestionList(T)
      def self.from_json(pull : JSON::PullParser) : Array(T)
        candidates = [] of T
        pull.read_array do
          if suggestion = decode_usable(WireFrame.read_raw(pull))
            candidates << suggestion
          end
        end
        candidates
      end

      def self.decode_usable(raw : String, *, unique_members : Bool = false) : T?
        return if unique_members && !unique_members?(JSON::PullParser.new(raw))

        suggestion = T.from_json(raw)
        suggestion if suggestion.usable?
      rescue JSON::Error
        # Keep the remaining suggestions when one cannot be used.
        nil
      end

      private def self.unique_members?(pull : JSON::PullParser) : Bool
        case pull.kind
        when .begin_object?
          keys = Set(String).new
          pull.read_object do |key|
            return false unless keys.add?(key) && unique_members?(pull)
          end
        when .begin_array?
          pull.read_array { return false unless unique_members?(pull) }
        else
          pull.skip
        end
        true
      end

      def self.to_json(values : Array(T), json : JSON::Builder) : Nil
        values.to_json(json)
      end
    end
  end
end
