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

      # Writes the JSON value directly.
      def to_json(builder : JSON::Builder) : Nil
        builder.raw(@json)
      end

      # Replaces an object member, preserving the other fields as exact JSON.
      def with_field(name : String, value : RawJson) : RawJson
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
            builder.field(name, value)
          end
        end
        RawJson.new(JSON::PullParser.new(wire))
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
