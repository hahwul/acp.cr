require "./updates"
require "./wire_frame"

module ACP
  module Protocol
    # Capability marker permitting a fork at a particular cursor.
    struct CursorForkCapabilities
      include JSON::Serializable
      include LosslessUnmapped

      # Extension metadata.
      def meta : Hash(String, JSON::Any)?
        @json_unmapped["_meta"]?.try(&.as_h?)
      end

      # Creates a cursor fork capability marker.
      def initialize(meta : Hash(String, JSON::Any)? = nil)
        @json_unmapped["_meta"] = JSON::Any.new(meta) if meta
      end

      # :nodoc:
      def self.from_json(pull : JSON::PullParser) : CursorForkCapabilities?
        return new(pull) if pull.kind.begin_object?

        pull.skip
        nil
      end

      # :nodoc:
      def self.to_json(value : CursorForkCapabilities, json : JSON::Builder) : Nil
        value.to_json(json)
      end
    end

    # The methods currently available at a session cursor.
    struct CursorCapabilities
      include JSON::Serializable
      include LosslessUnmapped

      # When present, the Agent accepts this cursor in session/fork.
      @[JSON::Field(converter: ::ACP::Protocol::CursorForkCapabilities)]
      getter fork : CursorForkCapabilities?

      # Extension metadata.
      def meta : Hash(String, JSON::Any)?
        @json_unmapped["_meta"]?.try(&.as_h?)
      end

      # Creates the advertised capabilities for a cursor.
      def initialize(@fork : CursorForkCapabilities? = nil, meta : Hash(String, JSON::Any)? = nil)
        @json_unmapped["_meta"] = JSON::Any.new(meta) if meta
      end
    end

    # :nodoc:
    struct CursorMetadata
      protected def initialize(@fields : Hash(String, String))
      end

      def initialize(fields : Hash(String, JSON::Any))
        @fields = fields.transform_values(&.to_json)
      end

      def self.from_json(pull : JSON::PullParser) : CursorMetadata
        fields = {} of String => String
        pull.read_object { |key| fields[key] = WireFrame.read_raw(pull) }
        new(fields)
      end

      def raw_field(key : String) : String?
        @fields[key]?
      end

      def to_h : Hash(String, JSON::Any)
        fields = {} of String => JSON::Any
        @fields.each do |key, json|
          fields[key] = JSON.parse(json)
        rescue JSON::Error
          # The original JSON remains accessible through raw_field.
        end
        fields
      end

      def apply_to(previous : CursorMetadata?) : CursorMetadata
        fields = previous.try(&.fields.dup) || {} of String => String
        @fields.each do |key, json|
          if json == "null"
            fields.delete(key)
          else
            fields[key] = json
          end
        end
        CursorMetadata.new(fields)
      end

      def to_json(builder : JSON::Builder) : Nil
        builder.object do
          @fields.each do |key, json|
            builder.field(key) { builder.raw(json) }
          end
        end
      end

      protected getter fields : Hash(String, String)
    end

    # A position relative to a known or future transcript entity.
    struct CursorAnchor
      include JSON::Serializable
      include LosslessUnmapped

      # Discriminator identifying the anchored entity type.
      @[JSON::Field(key: "type")]
      getter anchor_type : String

      # Creates an anchor from its type and fields, preserving future variants.
      def initialize(@anchor_type : String, @json_unmapped : Hash(String, JSON::Any) = {} of String => JSON::Any)
        raise ArgumentError.new("Missing cursor anchor entity ID or position") if malformed?
      end

      # ID of the anchored entity for a recognized type.
      def entity_id : String?
        entity_key.try { |key| @json_unmapped[key]?.try(&.as_s?) }
      end

      # Side of the anchored entity, including future position strings.
      def position : String?
        @json_unmapped["position"]?.try(&.as_s?)
      end

      # Extension metadata.
      def meta : Hash(String, JSON::Any)?
        @json_unmapped["_meta"]?.try(&.as_h?)
      end

      # Whether the library recognizes both the entity type and the side.
      def known_position? : Bool
        !entity_id.nil? && position.in?("before", "after")
      end

      private def entity_key : String?
        case @anchor_type
        when "user_message", "agent_message", "agent_thought", "session_message"
          "messageId"
        when "tool_call"
          "toolCallId"
        when "compaction"
          "compactionId"
        end
      end

      private def malformed? : Bool
        !entity_key.nil? && (entity_id.nil? || position.nil?)
      end

      private def after_initialize : Nil
        if malformed?
          raise JSON::ParseException.new("Missing cursor anchor entity ID or position", 0, 0)
        end
      end
    end

    # Announces a new session cursor or changes its capabilities or metadata.
    struct CursorUpdate < SessionUpdate
      # Opaque Agent-owned ID scoped to this update's enclosing session.
      @[JSON::Field(key: "cursorId")]
      getter cursor_id : String

      # The cursor's position when supplied. Null and omission are equivalent.
      property anchor : CursorAnchor?

      # New capabilities for this cursor when present.
      @[JSON::Field(ignore: true)]
      getter capabilities : CursorCapabilities? = nil

      # :nodoc:
      @[JSON::Field(ignore: true)]
      getter metadata : CursorMetadata? = nil

      # New metadata values representable as JSON::Any.
      def meta : Hash(String, JSON::Any)?
        @metadata.try(&.to_h)
      end

      # Exact JSON for a metadata entry when the update supplies it.
      def raw_meta_field(key : String) : String?
        @metadata.try(&.raw_field(key))
      end

      # Whether the update replaces the capabilities or explicitly clears them.
      @[JSON::Field(ignore: true)]
      getter? capabilities_present : Bool = false

      # Whether the update replaces the metadata or explicitly clears it.
      @[JSON::Field(ignore: true)]
      getter? meta_present : Bool = false

      # Creates a cursor announcement or patch.
      def initialize(@cursor_id : String, @anchor : CursorAnchor? = nil)
        @session_update = "cursor_update"
      end

      # Replaces the capabilities. Assign nil to explicitly clear them.
      def capabilities=(@capabilities : CursorCapabilities?) : CursorCapabilities?
        @capabilities_present = true
        @capabilities
      end

      # Replaces metadata. Assign nil to explicitly clear it.
      def meta=(value : Hash(String, JSON::Any)?) : Hash(String, JSON::Any)?
        @meta_present = true
        @metadata = value.try { |fields| CursorMetadata.new(fields) }
        value
      end

      protected def on_unknown_json_attribute(pull, key, key_location)
        case key
        when "capabilities"
          if pull.kind.null?
            pull.read_null
            @capabilities = nil
            @capabilities_present = true
          elsif pull.kind.begin_object?
            @capabilities = CursorCapabilities.new(pull)
            @capabilities_present = true
          else
            pull.skip
          end
        when "_meta"
          if pull.kind.null?
            pull.read_null
            @metadata = nil
            @meta_present = true
          elsif pull.kind.begin_object?
            @metadata = CursorMetadata.from_json(pull)
            @meta_present = true
          else
            pull.skip
          end
        else
          super
        end
      end

      protected def on_to_json(json)
        super
        json.field("capabilities", @capabilities) if @capabilities_present
        json.field("_meta", @metadata) if @meta_present
      end
    end
  end
end
