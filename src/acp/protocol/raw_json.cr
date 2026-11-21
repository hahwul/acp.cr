require "./wire_frame"

module ACP
  module Protocol
    # JSON retained without rounding numbers or dropping explicit nulls.
    struct RawJson
      # JSON text, compacted for newline-delimited transport.
      getter json : String

      private def initialize(@json : String)
      end

      # Wraps a representable JSON value.
      def self.new(value : JSON::Any) : self
        new(WireFrame.encode(value))
      end

      # Parses exact JSON, including numeric values beyond JSON::Any.
      def self.from_json(value : String) : self
        WireFrame.new(value)
        new(JSON::PullParser.new(value))
      end

      # Reads one JSON value without narrowing its numbers.
      def self.new(pull : JSON::PullParser) : self
        new(WireFrame.read_raw(pull))
      end

      # Whether the value is a JSON object.
      def object? : Bool
        @json.starts_with?('{')
      end

      # Whether the value is a JSON array.
      def array? : Bool
        @json.starts_with?('[')
      end

      # Reads the elements of an array without narrowing numbers.
      def elements? : Array(RawJson)?
        return unless array?

        elements = [] of RawJson
        pull = JSON::PullParser.new(@json)
        pull.read_array { elements << RawJson.new(pull) }
        elements
      end

      # Whether the value is JSON null.
      def null? : Bool
        @json == "null"
      end

      # Reads a signed JSON integer in the Int64 range.
      def as_i64? : Int64?
        @json.to_i64?
      end

      # Reads a string or returns nil for other JSON values.
      def as_s? : String?
        JSON.parse(@json).as_s if @json.starts_with?('"')
      end

      # Reads an object's members without narrowing their values.
      def members? : Hash(String, RawJson)?
        return unless object?

        members = {} of String => RawJson
        pull = JSON::PullParser.new(@json)
        pull.read_object { |key| members[key] = RawJson.new(pull) }
        members
      end

      # Reads a member without projecting the rest of the object.
      def field(name : String) : RawJson?
        if object? && (value = WireFrame.field(@json, name))
          RawJson.new(JSON::PullParser.new(value))
        end
      end

      # Decodes values that fit within JSON::Any.
      def to_json_any : JSON::Any
        JSON.parse(@json)
      end

      # Projects representable values into JSON::Any.
      def to_json_any? : JSON::Any?
        to_json_any
      rescue JSON::ParseException
        nil
      end

      # Writes the JSON value directly.
      def to_json(builder : JSON::Builder) : Nil
        builder.raw(@json)
      end

      # Replaces an object member, preserving the other fields as exact JSON.
      def with_field(name : String, value : RawJson) : RawJson
        replace_field(name, value)
      end

      # Removes an object member, preserving the other fields as exact JSON.
      def without_field(name : String) : RawJson
        replace_field(name, nil)
      end

      private def replace_field(name : String, value : RawJson?) : RawJson
        raise ArgumentError.new("JSON value must be an object") unless object?

        pull = JSON::PullParser.new(@json)
        wire = JSON.build do |builder|
          builder.max_nesting = pull.max_nesting
          builder.object do
            pull.read_object do |key|
              if key == name
                pull.skip
              else
                builder.field(key) { pull.read_raw(builder) }
              end
            end
            builder.field(name, value) if value
          end
        end
        RawJson.new(JSON::PullParser.new(wire))
      end
    end

    # :nodoc:
    # Keeps exact JSON behind an existing mutable JSON::Any accessor.
    struct PreservedJson
      getter value : JSON::Any?
      getter? partial = false
      @source : RawJson?
      @projected : String?

      def initialize(@value : JSON::Any)
      end

      def initialize(pull : JSON::PullParser, *, project_object_members : Bool = false)
        source = RawJson.new(pull)
        @source = source
        @value = source.to_json_any?
        if @value.nil? && project_object_members && (members = source.members?)
          projection = {} of String => JSON::Any
          members.each do |key, member|
            if value = member.to_json_any?
              projection[key] = value
            end
          end
          @value = JSON::Any.new(projection)
          @partial = true
        end
        @projected = @value.try { |value| WireFrame.encode(value) }
      end

      def raw : RawJson
        if value = @value
          rendered = RawJson.new(value)
          if source = @source
            return source if rendered.json == @projected

            merged = WireFrame.merge_projection(source.json, value, partial_object: partial?)
            return RawJson.new(JSON::PullParser.new(merged))
          end

          rendered
        else
          @source.not_nil!
        end
      end

      def to_json(builder : JSON::Builder) : Nil
        raw.to_json(builder)
      end
    end

    # :nodoc:
    module PreservedMetadata
      def self.from_json(pull : JSON::PullParser) : PreservedJson
        PreservedJson.new(pull, project_object_members: true)
      end

      def self.to_json(value : PreservedJson, builder : JSON::Builder) : Nil
        value.to_json(builder)
      end
    end

    # :nodoc:
    module OptionalPreservedMetadata
      def self.from_json(pull : JSON::PullParser) : PreservedJson?
        return PreservedMetadata.from_json(pull) if pull.kind.begin_object?

        pull.skip
        nil
      end

      def self.to_json(value : PreservedJson, json : JSON::Builder) : Nil
        PreservedMetadata.to_json(value, json)
      end
    end

    # :nodoc:
    module OptionalRawMetadata
      def self.from_json(pull : JSON::PullParser) : RawJson?
        return RawJson.new(pull) if pull.kind.begin_object?

        pull.skip
        nil
      end

      def self.to_json(value : RawJson, json : JSON::Builder) : Nil
        value.to_json(json)
      end
    end
  end
end
