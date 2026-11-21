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
# Selects the concrete subtype from the "type" field.

require "json"
require "uri"
require "./raw_json"

module ACP
  module Protocol
    # :nodoc:
    module OptionalContentValue(T)
      def self.from_json(pull : JSON::PullParser) : T?
        T.from_json(WireFrame.read_raw(pull))
      rescue JSON::ParseException
        nil
      end

      def self.to_json(value : T, builder : JSON::Builder) : Nil
        value.to_json(builder)
      end
    end

    # :nodoc:
    module OptionalContentList(T)
      def self.from_json(pull : JSON::PullParser) : Array(T)?
        unless pull.kind.begin_array?
          pull.skip
          return nil
        end

        values = [] of T
        pull.read_array do
          if value = OptionalContentValue(T).from_json(pull)
            values << value
          end
        end
        values
      end

      def self.to_json(values : Array(T), builder : JSON::Builder) : Nil
        values.to_json(builder)
      end
    end

    # :nodoc:
    module ProjectedContent
      def self.from_json(pull : JSON::PullParser) : PreservedJson
        location = pull.location
        content = PreservedJson.new(pull, project_object_members: true)
        unless content.value
          raise JSON::ParseException.new("Content must be representable or a JSON object", *location)
        end
        content
      end

      def self.to_json(content : PreservedJson, builder : JSON::Builder) : Nil
        content.to_json(builder)
      end
    end

    # :nodoc:
    module LosslessContentField
      @[JSON::Field(key: "content", converter: ::ACP::Protocol::ProjectedContent)]
      @content_wire : PreservedJson

      # Content fields representable in JSON::Any.
      def content : JSON::Any
        @content_wire.value.not_nil!
      end

      # Replaces the content of this chunk.
      def content=(value : JSON::Any) : JSON::Any
        @content_wire = PreservedJson.new(value)
        value
      end

      # Exact content JSON, including extension values.
      def content_raw : RawJson
        @content_wire.raw
      end
    end

    # :nodoc:
    module ContentBlockArray
      def self.from_json(pull : JSON::PullParser) : PreservedJson
        unless pull.kind.begin_array?
          raise JSON::ParseException.new("Content blocks must be a JSON array", *pull.location)
        end
        PreservedJson.new(pull, project_array_objects: true)
      end

      def self.to_json(value : PreservedJson, builder : JSON::Builder) : Nil
        value.to_json(builder)
      end
    end

    # :nodoc:
    module ResourceLinkSize
      def self.from_json(pull : JSON::PullParser) : Int64 | UInt64 | Nil
        if pull.kind.int?
          value = pull.read_raw
          value.to_i64? || value.to_u64?
        else
          pull.skip
          nil
        end
      end

      def self.to_json(value : Int64 | UInt64, builder : JSON::Builder) : Nil
        value.to_json(builder)
      end
    end

    # An open icon theme, such as light or dark.
    alias IconTheme = String

    # Display metadata for a resource-link icon.
    struct Icon
      include JSON::Serializable
      include LosslessUnmapped
      include LosslessMetadata

      # URI supplied by the peer.
      property src : String

      # Optional media type override for the icon.
      @[JSON::Field(key: "mimeType", converter: ::ACP::Protocol::OptionalContentValue(String))]
      property mime_type : String?

      # Supported display sizes, such as "48x48" or "any".
      @[JSON::Field(converter: ::ACP::Protocol::OptionalContentList(String))]
      property sizes : Array(String)?

      # Optional background theme. Unknown themes retain their wire strings.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalContentValue(String))]
      property theme : IconTheme?

      # Creates an icon without resolving its URI.
      def initialize(@src : String, @mime_type : String? = nil, @sizes : Array(String)? = nil,
                     @theme : IconTheme? = nil, meta : Hash(String, JSON::Any)? = nil)
        self.meta = meta
      end

      protected def keep_exact_unmapped?(_key : String) : Bool
        true
      end
    end

    # ─── Annotations ──────────────────────────────────────────────────

    # Optional annotations for content blocks. The client can use
    # annotations to inform how objects are used or displayed.
    struct Annotations
      include JSON::Serializable
      include LosslessMetadata

      # Describes who the intended audience of this content is.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalContentList(String))]
      property audience : Array(String)?

      # An ISO 8601 datetime string indicating when the content was last modified.
      @[JSON::Field(key: "lastModified", converter: ::ACP::Protocol::OptionalContentValue(String))]
      property last_modified : String?

      # A priority hint for the content (0.0 to 1.0).
      @[JSON::Field(converter: ::ACP::Protocol::OptionalContentValue(Float64))]
      property priority : Float64?

      def initialize(
        @audience : Array(String)? = nil,
        @last_modified : String? = nil,
        @priority : Float64? = nil,
        meta : Hash(String, JSON::Any)? = nil,
      )
        self.meta = meta
      end
    end

    # ─── Abstract Content Block Base ──────────────────────────────────

    # Abstract base for all standard content block types.
    abstract struct ContentBlock
      include JSON::Serializable

      # Reads a standard block at the transport's JSON nesting limit.
      def self.new(pull : JSON::PullParser) : ContentBlock
        line, column = pull.location
        decode(RawJson.new(pull), line, column, allow_unknown: false)
      end

      # Reads ACP v2 display content, including custom and future block types.
      def self.from_v2_json(json : String) : ContentBlock
        from_v2_json(RawJson.from_json(json))
      end

      # Reads ACP v2 display content from exact JSON.
      def self.from_v2_json(block : RawJson) : ContentBlock
        decode(block, 1, 1, allow_unknown: true)
      end

      # Reads usable v2 display blocks from an array in wire order.
      # :nodoc:
      def self.decode_v2_array(array : RawJson) : Array(ContentBlock)?
        array.elements?.try &.compact_map do |block|
          from_v2_json(block)
        rescue JSON::Error
          nil
        end
      end

      private def self.decode(block : RawJson, line : Int32, column : Int32, *, allow_unknown : Bool) : ContentBlock
        type = block.field("type").try(&.as_s?)
        if allow_unknown && !WireFrame.unique_members?(block.json)
          raise JSON::SerializableError.new("Ambiguous ACP v2 content fields", to_s, "type", line, column, nil)
        end

        case type
        when "text"          then TextContentBlock.from_json(block.json)
        when "image"         then ImageContentBlock.from_json(block.json)
        when "audio"         then AudioContentBlock.from_json(block.json)
        when "resource_link" then ResourceLinkContentBlock.from_json(block.json)
        when "resource"
          resource = ResourceContentBlock.from_json(block.json)
          if allow_unknown && !(resource.uri && (resource.text || resource.blob))
            raise JSON::SerializableError.new("Malformed embedded resource", to_s, "resource", line, column, nil)
          end
          resource
        else
          # Skill references have a separate user-message API.
          if allow_unknown && type && type != "skill"
            return UnknownContentBlock.from_wire(block, type)
          end
          raise JSON::SerializableError.new("Unknown or missing content type #{type.inspect}", to_s, "type", line, column, nil)
        end
      end

      # The discriminator field present on every content block.
      getter type : String
    end

    # An ACP v2 display block with an unrecognized discriminator.
    struct UnknownContentBlock < ContentBlock
      # The complete block as exact JSON.
      getter raw : RawJson

      private def initialize(@raw : RawJson, @type : String)
      end

      # Creates the fallback after checking the wire discriminator.
      # :nodoc:
      protected def self.from_wire(raw : RawJson, type : String) : self
        new(raw, type)
      end

      # Reads an unrecognized v2 block.
      def self.new(pull : JSON::PullParser) : self
        line, column = pull.location
        block = ContentBlock.from_v2_json(RawJson.new(pull))
        return block if block.is_a?(UnknownContentBlock)

        raise JSON::SerializableError.new("Expected an unrecognized ACP v2 content type", to_s, "type", line, column, nil)
      end

      # Whether the type uses the namespace reserved for extensions.
      def custom? : Bool
        @type.starts_with?('_')
      end

      # Writes the original opaque content.
      def to_json(builder : JSON::Builder) : Nil
        @raw.to_json(builder)
      end
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
      include LosslessMetadata

      # Always "text" for this block type.
      getter type : String = "text"

      # The text content of the block.
      property text : String

      # Optional metadata about how the content should be used or displayed.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalContentValue(::ACP::Protocol::Annotations))]
      property annotations : Annotations?

      def initialize(@text : String, @annotations : Annotations? = nil, meta : Hash(String, JSON::Any)? = nil)
        @type = "text"
        self.meta = meta
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
      include LosslessMetadata

      # Always "image" for this block type.
      getter type : String = "image"

      # Base64-encoded image data (required).
      property data : String

      # MIME type of the image (e.g., "image/png", "image/jpeg") (required).
      @[JSON::Field(key: "mimeType")]
      property mime_type : String

      # Optional URI reference for the image source.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalContentValue(String))]
      property uri : String?

      # Optional metadata about how the content should be used or displayed.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalContentValue(::ACP::Protocol::Annotations))]
      property annotations : Annotations?

      def initialize(
        @data : String,
        @mime_type : String = "image/png",
        @uri : String? = nil,
        @annotations : Annotations? = nil,
        meta : Hash(String, JSON::Any)? = nil,
      )
        @type = "image"
        self.meta = meta
      end
    end

    # ─── Audio Content Block ──────────────────────────────────────────

    # An audio content block. Requires the `audio` prompt capability.
    #
    # See: https://agentclientprotocol.com/protocol/content#audio-content
    struct AudioContentBlock < ContentBlock
      include JSON::Serializable
      include LosslessMetadata

      # Always "audio" for this block type.
      getter type : String = "audio"

      # Base64-encoded audio data (required).
      property data : String

      # MIME type of the audio (e.g., "audio/wav", "audio/mp3") (required).
      @[JSON::Field(key: "mimeType")]
      property mime_type : String

      # Optional metadata about how the content should be used or displayed.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalContentValue(::ACP::Protocol::Annotations))]
      property annotations : Annotations?

      def initialize(
        @data : String,
        @mime_type : String = "audio/wav",
        @annotations : Annotations? = nil,
        meta : Hash(String, JSON::Any)? = nil,
      )
        @type = "audio"
        self.meta = meta
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
      include LosslessMetadata

      # Always "resource" for this block type.
      getter type : String = "resource"

      @[JSON::Field(key: "resource", converter: ::ACP::Protocol::ProjectedContent)]
      @resource_wire : PreservedJson

      # Optional metadata about how the content should be used or displayed.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalContentValue(::ACP::Protocol::Annotations))]
      property annotations : Annotations?

      def initialize(
        resource : JSON::Any,
        @annotations : Annotations? = nil,
        meta : Hash(String, JSON::Any)? = nil,
      )
        @type = "resource"
        @resource_wire = PreservedJson.new(resource)
        self.meta = meta
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

      # Embedded text or blob resource fields representable in JSON::Any.
      def resource : JSON::Any
        @resource_wire.value.not_nil!
      end

      # Replaces the embedded resource.
      def resource=(value : JSON::Any) : JSON::Any
        @resource_wire = PreservedJson.new(value)
        value
      end

      # Exact embedded resource JSON.
      def resource_raw : RawJson
        @resource_wire.raw
      end

      # Helper: get the URI from the embedded resource.
      def uri : String?
        resource.as_h?.try { |hash| hash["uri"]?.try(&.as_s?) }
      end

      # Helper: get the text from the embedded resource (nil if blob).
      def text : String?
        resource.as_h?.try { |hash| hash["text"]?.try(&.as_s?) }
      end

      # Helper: get the blob from the embedded resource (nil if text).
      def blob : String?
        resource.as_h?.try { |hash| hash["blob"]?.try(&.as_s?) }
      end

      # Helper: get the MIME type from the embedded resource.
      def resource_mime_type : String?
        resource.as_h?.try { |hash| hash["mimeType"]?.try(&.as_s?) }
      end
    end

    # ─── Resource Link Content Block ──────────────────────────────────

    # References to resources that the Agent can access.
    # All Agents MUST support resource links in prompts.
    #
    # See: https://agentclientprotocol.com/protocol/content#resource-link
    struct ResourceLinkContentBlock < ContentBlock
      include JSON::Serializable
      include LosslessUnmapped
      include LosslessMetadata

      # Always "resource_link" for this block type.
      getter type : String = "resource_link"

      # The URI of the resource (required).
      property uri : String

      # A human-readable name for the resource (required).
      property name : String

      # The MIME type of the resource.
      @[JSON::Field(key: "mimeType", converter: ::ACP::Protocol::OptionalContentValue(String))]
      property mime_type : String?

      # Optional display title for the resource.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalContentValue(String))]
      property title : String?

      # Optional description of the resource contents.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalContentValue(String))]
      property description : String?

      @[JSON::Field(key: "size", converter: ::ACP::Protocol::ResourceLinkSize)]
      @wire_size : Int64 | UInt64 | Nil

      # Optional metadata about how the content should be used or displayed.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalContentValue(::ACP::Protocol::Annotations))]
      property annotations : Annotations?

      # Optional icons provided for this link in ACP v2.
      @[JSON::Field(converter: ::ACP::Protocol::OptionalContentList(::ACP::Protocol::Icon))]
      property icons : Array(Icon)?

      def initialize(
        @uri : String,
        @name : String,
        @mime_type : String? = nil,
        @title : String? = nil,
        @description : String? = nil,
        size : Int64? = nil,
        @annotations : Annotations? = nil,
        meta : Hash(String, JSON::Any)? = nil,
        *,
        @icons : Array(Icon)? = nil,
        size_bytes : UInt64? = nil,
      )
        @type = "resource_link"
        @wire_size = size_bytes || size
        self.meta = meta
      end

      # Size in the signed range for existing callers and ACP v1.
      def size : Int64?
        if (value = @wire_size) && value <= Int64::MAX
          value.to_i64
        end
      end

      # Replaces the size using the ACP v1 signed field.
      def size=(value : Int64?) : Int64?
        @wire_size = value
      end

      # Non-negative size across the full ACP v2 range.
      def size_bytes : UInt64?
        if (value = @wire_size) && value >= 0
          value.to_u64
        end
      end

      # Replaces the size using the ACP v2 unsigned field.
      def size_bytes=(value : UInt64?) : UInt64?
        @wire_size = value
      end

      protected def keep_exact_unmapped?(_key : String) : Bool
        true
      end

      # Creates a resource link from an absolute file path.
      #
      # The path is percent-encoded, so paths containing spaces, `#`, `?`, or
      # `%` produce a valid URI rather than one a strict parser rejects or
      # truncates at the first `#`. `path` reverses the encoding.
      def self.from_path(path : String, mime_type : String? = nil, *, icons : Array(Icon)? = nil) : ResourceLinkContentBlock
        uri = path.starts_with?("/") ? "file://#{URI.encode_path(path)}" : path
        name = File.basename(path)
        new(uri: uri, name: name, mime_type: mime_type, icons: icons)
      end

      # Helper to extract the file path from a `file://` URI.
      #
      # Percent escapes are decoded, so a URI like `file:///My%20Docs/a.cr`
      # yields a path that can actually be opened. Returns nil for any other
      # scheme.
      def path : String?
        return unless @uri.starts_with?(FILE_URI_PREFIX)
        URI.decode(@uri[FILE_URI_PREFIX.size..])
      end

      # The scheme prefix recognized by `path` / produced by `from_path`.
      private FILE_URI_PREFIX = "file://"
    end

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

      # Creates an audio content block from base64 data.
      def self.audio(data : String, mime_type : String = "audio/wav") : AudioContentBlock
        AudioContentBlock.new(data: data, mime_type: mime_type)
      end

      # Creates an embedded resource content block with text content.
      def self.resource(uri : String, text : String, mime_type : String? = nil) : ResourceContentBlock
        ResourceContentBlock.text(uri: uri, text: text, mime_type: mime_type)
      end

      # Creates a resource link content block.
      def self.resource_link(uri : String, name : String, mime_type : String? = nil, *, icons : Array(Icon)? = nil) : ResourceLinkContentBlock
        ResourceLinkContentBlock.new(uri: uri, name: name, mime_type: mime_type, icons: icons)
      end
    end
  end
end
