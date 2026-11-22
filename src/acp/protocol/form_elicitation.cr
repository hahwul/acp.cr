require "./client_methods"
require "./elicitation_pattern"
require "./elicitation_string_format"

module ACP
  module Protocol
    # :nodoc:
    # Decodes form requests and checks submissions against the original schema.
    module FormElicitation
      def self.from_json(json : String, *, v2 : Bool) : CreateElicitationParams
        fields = RawJson.new(JSON::PullParser.new(json)).members? || invalid("Form elicitation params must be an object")
        form = fields["requestedSchema"]? || invalid("Missing form schema")
        input = ElicitationRequest.from_fields(fields)
        input.requested_schema = schema(form, v2: v2)
        input.requested_schema_raw = form
        input
      end

      def self.validate_submission(form : RawJson, content : RawJson?, *, v2 : Bool) : Nil
        return if content.nil? || content.null?

        values = content.members? || invalid("Form submission content must be an object")
        invalid("Ambiguous submitted field names") unless WireFrame.unique_members?(content.json, recursive: false)
        decoded = schema(form, v2: v2)
        if (required = decoded.required) && !required.all? { |name| values.has_key?(name) }
          invalid("Form submission is missing a required field")
        end

        declared = form.field("properties").try(&.members?) || {} of String => RawJson
        values.each do |name, value|
          invalid("Form submission includes an undeclared field") unless declared.has_key?(name)
          if field = decoded.properties[name]?
            invalid("Submitted value does not match its form field") unless valid_submission?(field, value, v2: v2)
          end
        end
      end

      private def self.valid_submission?(field : ElicitationPropertySchema, value : RawJson, *, v2 : Bool) : Bool
        case field.property_type
        when "string"
          text = value.as_s?
          return false unless text && within_bounds?(text.size, field.min_length, field.max_length)
          return false if (options = field.enum_values) && !options.includes?(text)
          return false if (options = field.one_of) && !options.any? { |option| option.const_value == text }

          return false unless ElicitationStringFormat.valid?(field.format, text, v2: v2)

          pattern = field.pattern
          v2 || pattern.nil? || compile_pattern(pattern).matches?(text)
        when "integer"
          input = value.as_i64?
          !input.nil? && within_bounds?(input, field.minimum, field.maximum)
        when "number"
          return false unless ElicitationNumber.project(value)

          minimum = field.minimum_raw
          maximum = field.maximum_raw
          (minimum.nil? || compare_numbers(value, minimum) >= 0) &&
            (maximum.nil? || compare_numbers(value, maximum) <= 0)
        when "boolean"
          value.json.in?("true", "false")
        when "array"
          selections = value.elements?
          return false unless selections && within_bounds?(selections.size, field.min_items, field.max_items)

          items = field.items.not_nil!
          options = items.enum_values || items.any_of.try(&.map(&.const_value))
          selections.all? { |selection| (choice = selection.as_s?) && (!options || options.includes?(choice)) }
        else
          !v2 && v1_content_value?(value)
        end
      rescue Regex::Error
        false
      end

      private def self.v1_content_value?(value : RawJson) : Bool
        return true if value.as_s? || value.json.in?("true", "false") || ElicitationNumber.project(value)

        value.elements?.try(&.all? { |entry| !entry.as_s?.nil? }) == true
      end

      private def self.compile_pattern(pattern : String, *, search : Bool = true) : Regex
        # JSON Schema patterns search anywhere in the subject. Use one
        # anchored attempt so the engine's budget covers all candidate offsets.
        expression = ElicitationPattern.normalize(pattern)
        source = search ? "(?s:.*?)(?:#{expression})" : expression
        options = Regex::CompileOptions::DOLLAR_ENDONLY | Regex::CompileOptions::ANCHORED
        Regex.new("(*NO_JIT)(*LIMIT_MATCH=10000)(*LIMIT_RECURSION=1000)#{source}", options)
      rescue ArgumentError | Regex::Error
        invalid("Invalid or unsupported form pattern")
      end

      private def self.within_bounds?(value, minimum, maximum) : Bool
        (minimum.nil? || value >= minimum) && (maximum.nil? || value <= maximum)
      end

      private def self.schema(form : RawJson, *, v2 : Bool) : ElicitationSchema
        fields = form.unambiguous_patch(required: {"type", "properties", "required"},
          optional: {"title", "description", "_meta"}).members? || invalid("Form schema must be an object")
        raw_properties = fields["properties"]?
        if v2 && (fields["type"]?.try(&.as_s?) != "object" || raw_properties.nil?)
          invalid("Form schema requires type object and properties")
        end

        # V1 defaults the schema type to object and the properties to an empty map.
        properties = {} of String => ElicitationPropertySchema
        if raw_properties
          entries = raw_properties.members? || invalid("Form properties must be an object")
          unless WireFrame.unique_members?(raw_properties.json, recursive: false)
            invalid("Ambiguous form property names")
          end
          entries.each do |name, raw|
            if decoded = property_schema(raw, v2: v2)
              properties[name] = decoded
            end
          end
        end
        required = strings(fields["required"]?, "required")
        if required && !required.all? { |name| properties.has_key?(name) }
          invalid("Form requires a missing or unsupported property")
        end
        schema = ElicitationSchema.new(properties, required, fields["title"]?.try(&.as_s?),
          fields["description"]?.try(&.as_s?))
        with_metadata(schema, fields["_meta"]?)
      end

      private def self.property_schema(raw : RawJson, *, v2 : Bool) : ElicitationPropertySchema?
        unless WireFrame.repeated_members(raw.json, "type").empty?
          invalid("Ambiguous form property type")
        end
        type = raw.field("type").try(&.as_s?) || invalid("Form property requires a type")
        fields = case type
                 when "string"
                   if v2
                     property_fields(raw, {"minLength", "maxLength", "format", "enum", "oneOf"})
                   else
                     property_fields(raw, {"minLength", "maxLength", "format", "enum", "oneOf", "pattern"})
                   end
                 when "number", "integer"
                   property_fields(raw, {"minimum", "maximum"})
                 when "array"
                   property_fields(raw, {"minItems", "maxItems", "items"})
                 when "boolean"
                   property_fields(raw, Tuple.new)
                 else
                   return nil if v2
                   property_fields(raw, Tuple.new)
                 end
        property = ElicitationPropertySchema.new(type, title: fields["title"]?.try(&.as_s?),
          description: fields["description"]?.try(&.as_s?))
        default = fields["default"]?
        case type
        when "string"
          property.min_length = constraint(fields["minLength"]?, "minLength") { |value| unsigned_digits(value).to_u32? }
          property.max_length = constraint(fields["maxLength"]?, "maxLength") { |value| unsigned_digits(value).to_u32? }
          check_range(property.min_length, property.max_length, "string length")
          property.format = constraint(fields["format"]?, "format", &.as_s?)
          property.enum_values = strings(fields["enum"]?, "enum", nonempty: v2)
          property.one_of = titled_choices(fields["oneOf"]?, "oneOf", nonempty: v2)
          if v2 && property.enum_values && property.one_of
            invalid("Form property cannot specify both enum and oneOf")
          end
          unless v2
            property.pattern = constraint(fields["pattern"]?, "pattern", &.as_s?)
            if pattern = property.pattern
              compile_pattern(pattern, search: false)
              compile_pattern(pattern)
            end
          end
          property.default = default.try(&.as_s?).try { |value| JSON::Any.new(value) }
        when "number", "integer"
          integer = type == "integer"
          minimum = numeric_bound(fields["minimum"]?, "minimum", integer: integer)
          maximum = numeric_bound(fields["maximum"]?, "maximum", integer: integer)
          if minimum && maximum && compare_numbers(minimum, maximum) > 0
            invalid("Form numeric value has a minimum above its maximum")
          end
          property.minimum_raw = minimum
          property.maximum_raw = maximum
          property.default_raw = default if default && ElicitationNumber.project(default, integer: integer)
        when "boolean"
          case default.try(&.json)
          when "true"  then property.default = JSON::Any.new(true)
          when "false" then property.default = JSON::Any.new(false)
          end
        when "array"
          items = fields["items"]? || invalid("Array form property requires items")
          property.min_items = constraint(fields["minItems"]?, "minItems") { |value| unsigned_digits(value).to_u64? }
          property.max_items = constraint(fields["maxItems"]?, "maxItems") { |value| unsigned_digits(value).to_u64? }
          check_range(property.min_items, property.max_items, "selection count")
          property.items = select_items(items, v2: v2) || return nil
          property.default = default.try(&.elements?).try do |values|
            JSON::Any.new(values.compact_map { |value| value.as_s?.try { |item| JSON::Any.new(item) } })
          end
        else
          property.default = default.try(&.to_json_any?)
        end
        with_metadata(property, fields["_meta"]?)
      end

      private def self.property_fields(raw : RawJson, keys : Tuple) : Hash(String, RawJson)
        raw.unambiguous_patch(required: keys, optional: {"title", "description", "default", "_meta"}).members?.not_nil!
      end

      private def self.select_items(raw : RawJson, *, v2 : Bool) : MultiSelectItems?
        source = raw.unambiguous_patch(required: {"type"}, optional: {"_meta"})
        fields = source.members? || invalid("Array form items must be an object")
        meta = fields["_meta"]?
        discriminator = fields["type"]?
        type = discriminator.try(&.as_s?)
        if v2 && discriminator && !type
          invalid("Invalid array form item type")
        end
        if type == "string"
          reject_repeated(source, "enum")
          options = strings(fields["enum"]?, "enum", nonempty: v2)
          if options
            return with_metadata(MultiSelectItems.new(items_type: type, enum_values: options), meta)
          end
          invalid("String array items require enum") if v2
        elsif type
          return v2 ? nil : with_metadata(MultiSelectItems.new(items_type: type), meta)
        end
        reject_repeated(source, "anyOf")
        choices = titled_choices(fields["anyOf"]?, "anyOf", nonempty: v2) || invalid("Titled array items require anyOf")
        with_metadata(MultiSelectItems.new(items_type: type, any_of: choices), meta)
      end

      private def self.reject_repeated(source : RawJson, field : String) : Nil
        invalid("Ambiguous form item choices") unless WireFrame.repeated_members(source.json, field).empty?
      end

      private def self.strings(value : RawJson?, name : String, *, nonempty : Bool = false) : Array(String)?
        return if value.nil? || value.null?

        elements = value.elements? || invalid("Form #{name} must be an array")
        invalid("Form #{name} must contain a choice") if nonempty && elements.empty?
        elements.map { |element| element.as_s? || invalid("Form #{name} expects strings") }
      end

      private def self.titled_choices(value : RawJson?, name : String, *, nonempty : Bool) : Array(EnumOption)?
        return if value.nil? || value.null?

        elements = value.elements? || invalid("Form #{name} must be an array")
        invalid("Form #{name} must contain a choice") if nonempty && elements.empty?
        elements.map do |element|
          fields = element.unambiguous_patch(required: {"const", "title"}, optional: {"description", "_meta"}).members?
          choice = fields.try(&.["const"]?).try(&.as_s?)
          title = fields.try(&.["title"]?).try(&.as_s?)
          invalid("Form #{name} requires a string const and title") unless fields && choice && title

          option = EnumOption.new(choice, title, fields["description"]?.try(&.as_s?))
          with_metadata(option, fields["_meta"]?)
        end
      end

      private def self.check_range(minimum, maximum, name : String) : Nil
        invalid("Form #{name} has a minimum above its maximum") if minimum && maximum && minimum > maximum
      end

      private def self.constraint(value : RawJson?, name : String, &)
        return if value.nil? || value.null?

        (yield value) || invalid("Invalid form #{name}")
      end

      private def self.numeric_bound(value : RawJson?, name : String, *, integer : Bool) : RawJson?
        constraint(value, name) { |wire| wire if ElicitationNumber.project(wire, integer: integer) }
      end

      # Compare the decimal tokens without rounding them or expanding exponents.
      private def self.compare_numbers(left : RawJson, right : RawJson) : Int32
        left_sign, left_order, left_digits = decimal_parts(left)
        right_sign, right_order, right_digits = decimal_parts(right)
        return left_sign <=> right_sign unless left_sign == right_sign

        magnitude = left_order <=> right_order
        magnitude = left_digits <=> right_digits if magnitude.zero?
        left_sign * magnitude
      end

      private def self.decimal_parts(value : RawJson) : {Int32, Int128, String}
        parts = /\A(-?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?\z/.match(value.json)
        invalid("Invalid form number") unless parts

        fraction = parts[3]? || ""
        digits = (parts[2] + fraction).lstrip('0')
        return {0, 0_i128, ""} if digits.empty?

        exponent = (parts[4]? || "0").to_i64? || invalid("Form number exponent is outside the supported range")
        order = exponent.to_i128 + digits.bytesize - fraction.bytesize
        {parts[1].empty? ? 1 : -1, order, digits.rstrip('0')}
      end

      private def self.unsigned_digits(value : RawJson) : String
        value.json == "-0" ? "0" : value.json
      end

      private def self.with_metadata(value, metadata : RawJson?)
        value.meta_raw = metadata if metadata.try(&.object?)
        value
      end

      private def self.invalid(message : String) : NoReturn
        raise JSON::ParseException.new(message, 1, 1)
      end
    end
  end
end
