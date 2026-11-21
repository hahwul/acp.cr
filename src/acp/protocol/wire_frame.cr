require "json"

module ACP
  module Protocol
    # :nodoc:
    module LosslessUnmapped
      include JSON::Serializable::Unmapped

      @[JSON::Field(ignore: true)]
      @raw_fields : Hash(String, String)?

      @[JSON::Field(ignore: true)]
      @exact_fields : Hash(String, Tuple(String, String))?

      protected def on_unknown_json_attribute(pull, key, key_location)
        json = WireFrame.read_raw(pull)
        @json_unmapped.delete(key)
        @raw_fields.try(&.delete(key))
        @exact_fields.try(&.delete(key))
        begin
          value = JSON.parse(json)
          @json_unmapped[key] = value
          if keep_exact_unmapped?(key)
            projected = WireFrame.encode(value)
            if json != projected
              fields = @exact_fields ||= {} of String => Tuple(String, String)
              fields[key] = {json, projected}
            end
          end
        rescue JSON::ParseException
          fields = @raw_fields ||= {} of String => String
          fields[key] = json
        end
      end

      protected def on_to_json(json)
        @json_unmapped.each do |key, value|
          if raw = retained_unmapped_json(key, value)
            json.field(key) { json.raw(raw) }
          else
            json.field(key, value)
          end
        end
        @raw_fields.try &.each do |key, value|
          json.field(key) { json.raw(value) } unless @json_unmapped.has_key?(key)
        end
      end

      protected def keep_exact_unmapped?(key : String) : Bool
        false
      end

      protected def exact_unmapped_json(key : String) : String?
        if value = @json_unmapped[key]?
          retained_unmapped_json(key, value) || WireFrame.encode(value)
        else
          raw_field(key)
        end
      end

      private def retained_unmapped_json(key : String, value : JSON::Any) : String?
        return unless entry = @exact_fields.try(&.[key]?)
        return entry[0] if WireFrame.encode(value) == entry[1]

        WireFrame.merge_projection(entry[0], value)
      end

      # A field's exact JSON when it cannot be represented as JSON::Any.
      def raw_field(key : String) : String?
        @raw_fields.try(&.[key]?) unless @json_unmapped.has_key?(key)
      end
    end

    # A syntactically valid frame retained for lossless typed decoding.
    struct WireFrame
      # Serializes an already parsed payload at the wire parser's nesting limit.
      # :nodoc:
      def self.encode(value) : String
        JSON.build do |json|
          json.max_nesting = 512
          value.to_json(json)
        end
      end

      # Writes edits to a JSON::Any view while keeping unchanged wire values.
      # :nodoc:
      def self.merge_projection(source : String, value : JSON::Any, *, partial_object : Bool = false) : String
        JSON.build do |builder|
          builder.max_nesting = 512
          write_merged_projection(source, value, builder, partial_object: partial_object)
        end
      end

      private def self.write_merged_projection(source : String?, value : JSON::Any, builder : JSON::Builder, *, partial_object : Bool = false) : Nil
        if source && source.starts_with?('{') && (fields = value.as_h?)
          prior = {} of String => String
          pull = JSON::PullParser.new(source)
          pull.read_object { |key| prior[key] = read_raw(pull) }
          builder.object do
            if partial_object
              prior.each do |key, member|
                if !fields.has_key?(key) && !parse_projection(member)
                  builder.field(key) { builder.raw(member) }
                end
              end
            end
            fields.each do |key, member|
              builder.field(key) { write_merged_projection(prior[key]?, member, builder) }
            end
          end
        elsif source && (original = parse_projection(source)) && encode(original) == encode(value)
          builder.raw(source)
        else
          value.to_json(builder)
        end
      end

      private def self.parse_projection(source : String) : JSON::Any?
        JSON.parse(source)
      rescue JSON::ParseException
        nil
      end

      # Returns the exact payload of a successful JSON-RPC response.
      # :nodoc:
      def self.result_json(response : JSON::Any?, frame : WireFrame? = nil) : String?
        return unless response && !response["error"]? && (result = response["result"]?)

        frame ? field(frame.json, "result") : encode(result)
      rescue JSON::Error
        nil
      end

      # Original JSON text, including exact numeric tokens.
      getter json : String

      # Exact parameters when requested or outside the range of JSON::Any.
      getter params_json : String?

      # Whether the result or error is outside the range of JSON::Any.
      getter? wide_response = false

      # Checks the complete JSON syntax and extracts the raw params.
      def initialize(@json : String, *, @exact_params : Bool = false)
        pull = JSON::PullParser.new(@json)
        if pull.kind.begin_object?
          pull.read_object do |key|
            case key
            when "params"
              params = self.class.read_raw(pull)
              @params_json = @exact_params || !fits_json_any?(params) ? params : nil
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

      # The ordinary decoder's view of a deliberately retained exact frame.
      def representable : JSON::Any?
        JSON.parse(@json) if @exact_params
      rescue JSON::ParseException
        nil
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
        representable || project(JSON::PullParser.new(@json))
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
