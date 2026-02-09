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
        "text"  => TextContentBlock,
        "image" => ImageContentBlock,
        "audio" => AudioContentBlock,
        "file"  => FileContentBlock,
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

    # ─── File Content Block ───────────────────────────────────────────

    # A file-reference content block. Points to a file on the local
    # file system by its absolute path. The agent may read the file
    # contents if it has the appropriate capabilities.
    struct FileContentBlock < ContentBlock
      include JSON::Serializable

      # Always "file" for this block type.
      getter type : String = "file"

      # Absolute path to the file on the local file system.
      property path : String

      # Optional MIME type hint for the file content.
      @[JSON::Field(key: "mimeType")]
      property mime_type : String?

      def initialize(@path : String, @mime_type : String? = nil)
        @type = "file"
      end
    end

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

      # Creates a file content block from an absolute path.
      def self.file(path : String, mime_type : String? = nil) : FileContentBlock
        FileContentBlock.new(path, mime_type)
      end
    end
  end
end
