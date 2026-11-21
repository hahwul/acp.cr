require "json"

module ACP
  module Protocol
    # :nodoc:
    module LosslessUnmapped
      include JSON::Serializable::Unmapped

      @[JSON::Field(ignore: true)]
      @raw_fields : Hash(String, String)?

      protected def on_unknown_json_attribute(pull, key, key_location)
        json = WireFrame.read_raw(pull)
        @json_unmapped.delete(key)
        @raw_fields.try(&.delete(key))
        begin
          @json_unmapped[key] = JSON.parse(json)
        rescue JSON::ParseException
          fields = @raw_fields ||= {} of String => String
          fields[key] = json
        end
      end

      protected def on_to_json(json)
        super
        @raw_fields.try &.each do |key, value|
          json.field(key) { json.raw(value) } unless @json_unmapped.has_key?(key)
        end
      end

      # A field's exact JSON when it cannot be represented as JSON::Any.
      def raw_field(key : String) : String?
        @raw_fields.try(&.[key]?) unless @json_unmapped.has_key?(key)
      end
    end

    # A syntactically valid JSON frame that Crystal's JSON::Any cannot hold.
    # The original text remains available for lossless typed decoding.
    struct WireFrame
      # Original JSON text, including exact numeric tokens.
      getter json : String

      # Exact parameters when they cannot be represented as JSON::Any.
      getter params_json : String?

      # Whether the result or error is outside the range of JSON::Any.
      getter? wide_response = false

      # Checks the complete JSON syntax and extracts the raw params.
      def initialize(@json : String)
        pull = JSON::PullParser.new(@json)
        if pull.kind.begin_object?
          pull.read_object do |key|
            case key
            when "params"
              params = self.class.read_raw(pull)
              @params_json = fits_json_any?(params) ? nil : params
            when "result", "error"
              value = self.class.read_raw(pull)
              @wide_response ||= !fits_json_any?(value)
            else
              pull.skip
            end
          end
        elsif pull.kind.begin_array?
          pull.skip
        else
          # PullParser treats the first scalar as EOF even with trailing tokens.
          lexer = JSON::Lexer.new(@json)
          lexer.next_token
          unless lexer.next_token.kind.eof?
            raise JSON::ParseException.new("Unexpected content after JSON frame", *pull.location)
          end
          pull.skip
        end
        unless pull.kind.eof?
          raise JSON::ParseException.new("Unexpected content after JSON frame", *pull.location)
        end
      end

      # :nodoc:
      def self.read_raw(pull : JSON::PullParser) : String
        return pull.read_raw unless pull.kind.begin_array? || pull.kind.begin_object?

        JSON.build do |json|
          json.max_nesting = pull.max_nesting
          pull.read_raw(json)
        end
      end

      # :nodoc:
      def self.field(json : String, name : String) : String?
        pull = JSON::PullParser.new(json)
        value = nil
        pull.read_object do |key|
          if key == name
            value = read_raw(pull)
          else
            pull.skip
          end
        end
        value
      end

      private def fits_json_any?(json : String) : Bool
        JSON.parse(json)
        true
      rescue JSON::ParseException
        false
      end

      # Internal routing view. Unrepresentable numbers are unusable as IDs
      # or discriminators. Typed handlers must decode the original text.
      # :nodoc:
      def project_for_routing : JSON::Any
        project(JSON::PullParser.new(@json))
      end

      private def project(pull : JSON::PullParser) : JSON::Any
        case pull.kind
        when .int?
          raw = pull.read_raw
          value = raw.to_i64?
          value ? JSON::Any.new(value) : JSON::Any.new(false)
        when .float?
          raw = pull.read_raw
          value = raw.to_f64?
          value && value.finite? ? JSON::Any.new(value) : JSON::Any.new(false)
        when .begin_object?
          fields = {} of String => JSON::Any
          pull.read_object { |key| fields[key] = project(pull) }
          JSON::Any.new(fields)
        when .begin_array?
          items = [] of JSON::Any
          pull.read_array { items << project(pull) }
          JSON::Any.new(items)
        else
          JSON::Any.new(pull)
        end
      end
    end
  end
end
