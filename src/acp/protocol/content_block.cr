# ACP Protocol — Content Block Types
#
# Content blocks are the fundamental units of prompt content sent from
# the client to the agent in `session/prompt` requests. Each block has
# a "type" discriminator field that determines its shape.
#
# Supported types:
#   - "text"  — plain text content
#   - "image" — image referenced by URL or base64 data
#   - "audio" — audio referenced by URL or base64 data
#   - "file"  — file reference by absolute path
#
# Uses Crystal's `use_json_discriminator` to automatically deserialize
# the correct subtype based on the "type" field.

require "json"

module ACP
  module Protocol
    # Abstract base for all content block types. Deserialization is
    # dispatched via the "type" JSON field using Crystal's built-in
    # discriminator support.
    abstract struct ContentBlock
      include JSON::Serializable

      use_json_discriminator "type", {
        "text"          => TextContentBlock,
        "image"         => ImageContentBlock,
        "audio"         => AudioContentBlock,
        "file"          => ResourceContentBlock,
        "resource"      => ResourceContentBlock,
        "resource_link" => ResourceContentBlock,
      }

      # The discriminator field present on every content block.
      getter type : String
    end

    # ─── Text Content Block ───────────────────────────────────────────

    # A plain-text content block. This is the most common block type,
    # used for user messages and code snippets.
    struct TextContentBlock < ContentBlock
      include JSON::Serializable

      # Always "text" for this block type.
      getter type : String = "text"

      # The text content of the block.
      @[JSON::Field(key: "text")]
      property content : String

      def initialize(@content : String)
        @type = "text"
      end
    end

    # ─── Image Content Block ──────────────────────────────────────────

    # An image content block. The image can be referenced by URL or
    # provided inline as base64-encoded data.
    struct ImageContentBlock < ContentBlock
      include JSON::Serializable

      # Always "image" for this block type.
      getter type : String = "image"

      # URL pointing to the image resource (e.g., file://, https://).
      property url : String?

      # Base64-encoded image data, used when the image is provided inline.
      property data : String?

      # MIME type of the image (e.g., "image/png", "image/jpeg").
      @[JSON::Field(key: "mimeType")]
      property mime_type : String?

      def initialize(
        @url : String? = nil,
        @data : String? = nil,
        @mime_type : String? = nil,
      )
        @type = "image"
      end
    end

    # ─── Audio Content Block ──────────────────────────────────────────

    # An audio content block. Similar to image blocks, audio can be
    # referenced by URL or provided inline as base64-encoded data.
    struct AudioContentBlock < ContentBlock
      include JSON::Serializable

      # Always "audio" for this block type.
      getter type : String = "audio"

      # URL pointing to the audio resource.
      property url : String?

      # Base64-encoded audio data, used when the audio is provided inline.
      property data : String?

      # MIME type of the audio (e.g., "audio/wav", "audio/mp3").
      @[JSON::Field(key: "mimeType")]
      property mime_type : String?

      def initialize(
        @url : String? = nil,
        @data : String? = nil,
        @mime_type : String? = nil,
      )
        @type = "audio"
      end
    end

    # ─── Resource Content Block ───────────────────────────────────────

    # A resource content block (or file reference). Points to a resource
    # or file by its URI.
    struct ResourceContentBlock < ContentBlock
      include JSON::Serializable

      # Always "resource" for this block type in modern ACP/Gemini.
      getter type : String = "resource"

      # The URI of the resource (e.g., file:///path/to/file).
      @[JSON::Field(key: "uri")]
      property uri : String

      # Optional human-readable name for the resource.
      property name : String?

      # Optional MIME type hint for the content.
      @[JSON::Field(key: "mimeType")]
      property mime_type : String?

      def initialize(uri : String, @name : String? = nil, @mime_type : String? = nil)
        @uri = uri.starts_with?("/") ? "file://#{uri}" : uri
        @name ||= File.basename(@uri)
        @type = "resource"
      end

      # Alias for standard ACP compatibility
      def path
        @uri.sub("file://", "")
      end
    end

    # Alias for backward compatibility
    alias FileContentBlock = ResourceContentBlock

    # ─── Convenience Constructors ─────────────────────────────────────

    # Helper module for building content blocks ergonomically.
    module ContentBlocks
      # Creates a text content block.
      def self.text(content : String) : TextContentBlock
        TextContentBlock.new(content)
      end

      # Creates an image content block from a URL.
      def self.image_url(url : String, mime_type : String? = nil) : ImageContentBlock
        ImageContentBlock.new(url: url, mime_type: mime_type)
      end

      # Creates an image content block from base64 data.
      def self.image_data(data : String, mime_type : String = "image/png") : ImageContentBlock
        ImageContentBlock.new(data: data, mime_type: mime_type)
      end

      # Creates an audio content block from a URL.
      def self.audio_url(url : String, mime_type : String? = nil) : AudioContentBlock
        AudioContentBlock.new(url: url, mime_type: mime_type)
      end

      # Creates an audio content block from base64 data.
      def self.audio_data(data : String, mime_type : String = "audio/wav") : AudioContentBlock
        AudioContentBlock.new(data: data, mime_type: mime_type)
      end

      # Creates a resource (file) content block from an absolute path or URI.
      def self.file(path : String, mime_type : String? = nil) : ResourceContentBlock
        ResourceContentBlock.new(uri: path, mime_type: mime_type)
      end

      # Creates a resource content block.
      def self.resource(uri : String, name : String? = nil, mime_type : String? = nil) : ResourceContentBlock
        ResourceContentBlock.new(uri: uri, name: name, mime_type: mime_type)
      end
    end
  end
end
