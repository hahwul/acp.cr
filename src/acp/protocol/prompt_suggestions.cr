require "./raw_json"
require "set"
require "./content_block"
require "./optional_capability"

module ACP
  module Protocol
    # Presence advertises support for an additional suggestion content type.
    struct PromptSuggestionContentCapabilities
      include JSON::Serializable
      include LosslessMetadata

      # Creates a content type support marker.
      def initialize(meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end

      def_equals_and_hash metadata_comparison
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
      include LosslessMetadata

      # Presence allows suggestions with image content.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::PromptSuggestionsImageCapabilities))]
      getter image : PromptSuggestionsImageCapabilities?

      # Presence allows suggestions with audio content.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::PromptSuggestionsAudioCapabilities))]
      getter audio : PromptSuggestionsAudioCapabilities?

      # Presence allows suggestions with embedded resources.
      @[JSON::Field(key: "embeddedContext", converter: ::ACP::Protocol::OptionalCapabilityObject(::ACP::Protocol::PromptSuggestionsEmbeddedContextCapabilities))]
      getter embedded_context : PromptSuggestionsEmbeddedContextCapabilities?

      # Advertises baseline text and resource links plus any supplied options.
      def initialize(
        @image : PromptSuggestionsImageCapabilities? = nil,
        @audio : PromptSuggestionsAudioCapabilities? = nil,
        @embedded_context : PromptSuggestionsEmbeddedContextCapabilities? = nil,
        meta : Hash(String, JSON::Any)? = nil,
      )
        self.meta = meta
      end

      # :nodoc:
      def content_types(*, image : Bool, audio : Bool, embedded_context : Bool) : Set(String)
        allowed = Set{"text", "resource_link"}
        allowed.add("image") if @image && image
        allowed.add("audio") if @audio && audio
        allowed.add("resource") if @embedded_context && embedded_context
        allowed
      end

      def_equals_and_hash @image, @audio, @embedded_context, metadata_comparison
    end

    private struct SuggestionPrompt(Block)
      getter blocks : Array(Block)
      @wire : PreservedJson?

      def initialize(@blocks : Array(Block), @wire : PreservedJson? = nil)
      end

      def self.new(pull : JSON::PullParser) : self
        {% if Block == JSON::Any %}
          wire = ContentBlockArray.from_json(pull)
          new(wire.value.not_nil!.as_a, wire)
        {% else %}
          new(Array(Block).new(pull))
        {% end %}
      end

      def raw : RawJson
        @wire.try(&.raw) || RawJson.new(JSON::PullParser.new(WireFrame.encode(@blocks)))
      end

      def to_json(json : JSON::Builder) : Nil
        if wire = @wire
          wire.to_json(json)
        else
          @blocks.to_json(json)
        end
      end
    end

    # :nodoc:
    struct PromptSuggestionOf(Block)
      include JSON::Serializable
      include LosslessMetadata

      @[JSON::Field(key: "prompt")]
      @prompt_wire : SuggestionPrompt(Block)

      # Creates a suggestion from its complete prompt.
      def initialize(prompt : Array(Block), meta : Hash(String, JSON::Any)? = nil)
        @prompt_wire = SuggestionPrompt(Block).new(prompt)
        self.meta = meta
      end

      # Ordered content blocks for display.
      def prompt : Array(Block)
        @prompt_wire.blocks
      end

      # Serializes the typed v1 blocks or returns the exact v2 block JSON.
      def prompt_raw : RawJson
        @prompt_wire.raw
      end

      def_equals_and_hash comparable_prompt, metadata_comparison

      protected def comparable_prompt
        {% if Block == JSON::Any %}
          wire = prompt_raw
          wire.to_json_any? || wire
        {% else %}
          prompt
        {% end %}
      end

      # :nodoc:
      def usable? : Bool
        has_content = false
        each_block do |block|
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
      rescue JSON::Error | ArgumentError
        false
      end

      # :nodoc:
      def allowed?(types : Set(String)) : Bool
        prompt.all? { |block| types.includes?(block_type(block)) }
      end

      private def each_block(&)
        {% if Block == JSON::Any %}
          prompt_raw.elements?.not_nil!.each { |block| yield ContentBlock.from_v2_prompt(block) }
        {% else %}
          prompt.each { |block| yield block }
        {% end %}
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

      def self.decode_usable(raw : String) : T?
        # A candidate must have the same meaning when it is sent back.
        return unless WireFrame.unique_members?(raw)

        suggestion = T.from_json(raw)
        suggestion if suggestion.usable?
      rescue JSON::Error
        # Keep the remaining suggestions when one cannot be used.
        nil
      end

      # Projects a full replacement for generic callbacks, which can only
      # offer candidates whose complete prompt fits in JSON::Any.
      def self.notification_projection(suggestions : Array(T)) : JSON::Any
        values = suggestions.compact_map do |suggestion|
          next unless prompt = suggestion.prompt_raw.to_json_any?

          fields = {"prompt" => prompt}
          if meta = suggestion.meta_raw.try(&.to_json_any?)
            fields["_meta"] = meta
          end
          JSON::Any.new(fields)
        end
        JSON::Any.new(values)
      end

      def self.to_json(values : Array(T), json : JSON::Builder) : Nil
        values.to_json(json)
      end
    end
  end
end
