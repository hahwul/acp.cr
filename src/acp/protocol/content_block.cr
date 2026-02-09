# ACP Protocol — Content Block Types
#
# Content blocks are the fundamental units of content in the ACP protocol.
# They appear in:
#   - User prompts sent via `session/prompt`
#   - Language model output streamed through `session/update` notifications
#   - Progress updates and results from tool calls
#
# The ACP protocol uses the same ContentBlock structure as the Model Context
# Protocol (MCP), enabling seamless forwarding of content.
#
# Supported types (per ACP spec):
#   - "text"          — plain text content (baseline, all agents MUST support)
#   - "image"         — image with base64 data and MIME type
#   - "audio"         — audio with base64 data and MIME type
#   - "resource"      — embedded resource contents (requires embeddedContext capability)
#   - "resource_link" — reference to a resource (baseline, all agents MUST support)
#
# Reference: https://agentclientprotocol.com/protocol/content
#
# Uses Crystal's `use_json_discriminator` to automatically deserialize
# the correct subtype based on the "type" field.

require "json"

module ACP
  module Protocol
    # ─── Annotations ──────────────────────────────────────────────────

    # Optional annotations for content blocks. The client can use
    # annotations to inform how objects are used or displayed.
    struct Annotations
      include JSON::Serializable

      # Describes who the intended audience of this content is.
      property audience : Array(String)?

      # An ISO 8601 datetime string indicating when the content was last modified.
      @[JSON::Field(key: "lastModified")]
      property last_modified : String?

      # A priority hint for the content (0.0 to 1.0).
      property priority : Float64?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @audience : Array(String)? = nil,
        @last_modified : String? = nil,
        @priority : Float64? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # ─── Abstract Content Block Base ──────────────────────────────────

    # Abstract base for all content block types. Deserialization is
    # dispatched via the "type" JSON field using Crystal's built-in
    # discriminator support.
    abstract struct ContentBlock
      include JSON::Serializable

      use_json_discriminator "type", {
        "text"          => TextContentBlock,
        "image"         => ImageContentBlock,
        "audio"         => AudioContentBlock,
        "resource"      => ResourceContentBlock,
        "resource_link" => ResourceLinkContentBlock,
      }

      # The discriminator field present on every content block.
      getter type : String
    end

    # ─── Text Content Block ───────────────────────────────────────────

    # A plain-text content block. This is the most common block type,
    # used for user messages and code snippets.
    # All Agents MUST support text content blocks in prompts.
    # Clients SHOULD render this text as Markdown.
    #
    # See: https://agentclientprotocol.com/protocol/content#text-content
    struct TextContentBlock < ContentBlock
      include JSON::Serializable

      # Always "text" for this block type.
      getter type : String = "text"

      # The text content of the block.
      property text : String

      # Optional metadata about how the content should be used or displayed.
      property annotations : Annotations?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(@text : String, @annotations : Annotations? = nil, @meta : Hash(String, JSON::Any)? = nil)
        @type = "text"
      end

      # Alias for backward compatibility (previously named `content`).
      def content : String
        @text
      end
    end

    # ─── Image Content Block ──────────────────────────────────────────

    # An image content block. Requires the `image` prompt capability.
    #
    # See: https://agentclientprotocol.com/protocol/content#image-content
    struct ImageContentBlock < ContentBlock
      include JSON::Serializable

      # Always "image" for this block type.
      getter type : String = "image"

      # Base64-encoded image data (required).
      property data : String

      # MIME type of the image (e.g., "image/png", "image/jpeg") (required).
      @[JSON::Field(key: "mimeType")]
      property mime_type : String

      # Optional URI reference for the image source.
      property uri : String?

      # Optional metadata about how the content should be used or displayed.
      property annotations : Annotations?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @data : String,
        @mime_type : String = "image/png",
        @uri : String? = nil,
        @annotations : Annotations? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @type = "image"
      end

      # @deprecated Use `uri` instead. Kept for backward compatibility.
      def url : String?
        @uri
      end
    end

    # ─── Audio Content Block ──────────────────────────────────────────

    # An audio content block. Requires the `audio` prompt capability.
    #
    # See: https://agentclientprotocol.com/protocol/content#audio-content
    struct AudioContentBlock < ContentBlock
      include JSON::Serializable

      # Always "audio" for this block type.
      getter type : String = "audio"

      # Base64-encoded audio data (required).
      property data : String

      # MIME type of the audio (e.g., "audio/wav", "audio/mp3") (required).
      @[JSON::Field(key: "mimeType")]
      property mime_type : String

      # Optional metadata about how the content should be used or displayed.
      property annotations : Annotations?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @data : String,
        @mime_type : String = "audio/wav",
        @annotations : Annotations? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @type = "audio"
      end
    end

    # ─── Embedded Resource Types ──────────────────────────────────────

    # Text-based resource contents embedded in a resource content block.
    struct TextResourceContents
      include JSON::Serializable

      # The URI identifying the resource.
      property uri : String

      # The text content of the resource.
      property text : String

      # Optional MIME type of the text content.
      @[JSON::Field(key: "mimeType")]
      property mime_type : String?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @uri : String,
        @text : String,
        @mime_type : String? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # Binary resource contents embedded in a resource content block.
    struct BlobResourceContents
      include JSON::Serializable

      # The URI identifying the resource.
      property uri : String

      # Base64-encoded binary data.
      property blob : String

      # Optional MIME type of the blob.
      @[JSON::Field(key: "mimeType")]
      property mime_type : String?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @uri : String,
        @blob : String,
        @mime_type : String? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
      end
    end

    # ─── Resource Content Block (Embedded Resource) ───────────────────

    # Complete resource contents embedded directly in the message.
    # This is the preferred way to include context in prompts, such as
    # when using @-mentions to reference files or other resources.
    # Requires the `embeddedContext` prompt capability.
    #
    # See: https://agentclientprotocol.com/protocol/content#embedded-resource
    struct ResourceContentBlock < ContentBlock
      include JSON::Serializable

      # Always "resource" for this block type.
      getter type : String = "resource"

      # The embedded resource contents. Can be either a TextResourceContents
      # or BlobResourceContents. Stored as JSON::Any for flexible parsing.
      property resource : JSON::Any

      # Optional metadata about how the content should be used or displayed.
      property annotations : Annotations?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @resource : JSON::Any,
        @annotations : Annotations? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @type = "resource"
      end

      # Creates a ResourceContentBlock with text resource contents.
      def self.text(uri : String, text : String, mime_type : String? = nil) : ResourceContentBlock
        resource_hash = Hash(String, JSON::Any).new
        resource_hash["uri"] = JSON::Any.new(uri)
        resource_hash["text"] = JSON::Any.new(text)
        resource_hash["mimeType"] = JSON::Any.new(mime_type) if mime_type
        new(resource: JSON::Any.new(resource_hash))
      end

      # Creates a ResourceContentBlock with blob resource contents.
      def self.blob(uri : String, blob : String, mime_type : String? = nil) : ResourceContentBlock
        resource_hash = Hash(String, JSON::Any).new
        resource_hash["uri"] = JSON::Any.new(uri)
        resource_hash["blob"] = JSON::Any.new(blob)
        resource_hash["mimeType"] = JSON::Any.new(mime_type) if mime_type
        new(resource: JSON::Any.new(resource_hash))
      end

      # Helper: get the URI from the embedded resource.
      def uri : String?
        @resource.as_h?.try { |h| h["uri"]?.try(&.as_s?) }
      end

      # Helper: get the text from the embedded resource (nil if blob).
      def text : String?
        @resource.as_h?.try { |h| h["text"]?.try(&.as_s?) }
      end

      # Helper: get the blob from the embedded resource (nil if text).
      def blob : String?
        @resource.as_h?.try { |h| h["blob"]?.try(&.as_s?) }
      end

      # Helper: get the MIME type from the embedded resource.
      def resource_mime_type : String?
        @resource.as_h?.try { |h| h["mimeType"]?.try(&.as_s?) }
      end

      # @deprecated Use ResourceContentBlock.text or .blob factory methods instead.
      # Backward-compatible constructor from a file path.
      def self.from_path(path : String, mime_type : String? = nil) : ResourceContentBlock
        uri = path.starts_with?("/") ? "file://#{path}" : path
        text(uri: uri, text: "", mime_type: mime_type)
      end
    end

    # ─── Resource Link Content Block ──────────────────────────────────

    # References to resources that the Agent can access.
    # All Agents MUST support resource links in prompts.
    #
    # See: https://agentclientprotocol.com/protocol/content#resource-link
    struct ResourceLinkContentBlock < ContentBlock
      include JSON::Serializable

      # Always "resource_link" for this block type.
      getter type : String = "resource_link"

      # The URI of the resource (required).
      property uri : String

      # A human-readable name for the resource (required).
      property name : String

      # The MIME type of the resource.
      @[JSON::Field(key: "mimeType")]
      property mime_type : String?

      # Optional display title for the resource.
      property title : String?

      # Optional description of the resource contents.
      property description : String?

      # Optional size of the resource in bytes.
      property size : Int64?

      # Optional metadata about how the content should be used or displayed.
      property annotations : Annotations?

      # Extension metadata.
      @[JSON::Field(key: "_meta")]
      property meta : Hash(String, JSON::Any)?

      def initialize(
        @uri : String,
        @name : String,
        @mime_type : String? = nil,
        @title : String? = nil,
        @description : String? = nil,
        @size : Int64? = nil,
        @annotations : Annotations? = nil,
        @meta : Hash(String, JSON::Any)? = nil,
      )
        @type = "resource_link"
      end

      # Creates a resource link from an absolute file path.
      def self.from_path(path : String, mime_type : String? = nil) : ResourceLinkContentBlock
        uri = path.starts_with?("/") ? "file://#{path}" : path
        name = File.basename(path)
        new(uri: uri, name: name, mime_type: mime_type)
      end

      # Helper to extract the file path from a file:// URI.
      def path : String?
        if @uri.starts_with?("file://")
          @uri.sub("file://", "")
        else
          nil
        end
      end
    end

    # Backward-compatible alias: FileContentBlock → ResourceLinkContentBlock
    alias FileContentBlock = ResourceLinkContentBlock

    # ─── Convenience Constructors ─────────────────────────────────────

    # Helper module for building content blocks ergonomically.
    module ContentBlocks
      # Creates a text content block.
      def self.text(content : String) : TextContentBlock
        TextContentBlock.new(content)
      end

      # Creates an image content block from base64 data.
      def self.image(data : String, mime_type : String = "image/png") : ImageContentBlock
        ImageContentBlock.new(data: data, mime_type: mime_type)
      end

      # Creates an image content block with an optional URI reference.
      def self.image(data : String, mime_type : String, uri : String) : ImageContentBlock
        ImageContentBlock.new(data: data, mime_type: mime_type, uri: uri)
      end

      # @deprecated Use `image(data, mime_type)` instead.
      def self.image_url(url : String, mime_type : String? = nil) : ImageContentBlock
        ImageContentBlock.new(data: "", mime_type: mime_type || "image/png", uri: url)
      end

      # @deprecated Use `image(data, mime_type)` instead.
      def self.image_data(data : String, mime_type : String = "image/png") : ImageContentBlock
        ImageContentBlock.new(data: data, mime_type: mime_type)
      end

      # Creates an audio content block from base64 data.
      def self.audio(data : String, mime_type : String = "audio/wav") : AudioContentBlock
        AudioContentBlock.new(data: data, mime_type: mime_type)
      end

      # @deprecated Use `audio(data, mime_type)` instead.
      def self.audio_url(url : String, mime_type : String? = nil) : AudioContentBlock
        AudioContentBlock.new(data: "", mime_type: mime_type || "audio/wav")
      end

      # @deprecated Use `audio(data, mime_type)` instead.
      def self.audio_data(data : String, mime_type : String = "audio/wav") : AudioContentBlock
        AudioContentBlock.new(data: data, mime_type: mime_type)
      end

      # Creates an embedded resource content block with text content.
      def self.resource(uri : String, text : String, mime_type : String? = nil) : ResourceContentBlock
        ResourceContentBlock.text(uri: uri, text: text, mime_type: mime_type)
      end

      # Creates a resource link content block.
      def self.resource_link(uri : String, name : String, mime_type : String? = nil) : ResourceLinkContentBlock
        ResourceLinkContentBlock.new(uri: uri, name: name, mime_type: mime_type)
      end

      # Creates a resource link from a file path.
      # @deprecated Use `resource_link` instead.
      def self.file(path : String, mime_type : String? = nil) : ResourceLinkContentBlock
        ResourceLinkContentBlock.from_path(path, mime_type)
      end
    end
  end
end
