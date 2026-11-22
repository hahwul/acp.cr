require "../client_methods"

module ACP
  module Protocol
    module V2
      # :nodoc:
      # Decodes the v2 subset of JSON Schema without narrowing extension data.
      module FormElicitationRequest
        def self.from_json(json : String) : CreateElicitationParams
          fields = RawJson.new(JSON::PullParser.new(json)).members? || invalid("Form elicitation params must be an object")
          form = fields["requestedSchema"]? || invalid("Missing form schema")
          message = fields["message"]?.try(&.as_s?) || invalid("Invalid elicitation message")
          request = fields["requestId"]?
          input = CreateElicitationParams.new("form", message,
            session_id: fields["sessionId"]?.try(&.as_s?),
            tool_call_id: fields["toolCallId"]?.try(&.as_s?),
            request_id: request.try(&.as_i64?) || request.try(&.as_s?),
            requested_schema: schema(form), meta: metadata(fields["_meta"]?))
          input.requested_schema_raw = form
          input
        end

        private def self.schema(form : RawJson) : ElicitationSchema
          fields = form.unambiguous_patch(required: {"type", "properties", "required"},
            optional: {"title", "description", "_meta"}).members?
          unless fields && fields["type"]?.try(&.as_s?) == "object" && (raw_properties = fields["properties"]?) && raw_properties.object?
            invalid("Form schema requires type object and properties")
          end
          unless WireFrame.unique_members?(raw_properties.json, recursive: false)
            invalid("Ambiguous form property names")
          end

          properties = {} of String => ElicitationPropertySchema
          raw_properties.members?.not_nil!.each do |name, raw|
            if decoded = property_schema(raw)
              properties[name] = decoded
            end
          end
          required = strings(fields["required"]?, "required")
          if required && !required.all? { |name| properties.has_key?(name) }
            invalid("Form requires a missing or unsupported property")
          end
          ElicitationSchema.new(properties, required, fields["title"]?.try(&.as_s?),
            fields["description"]?.try(&.as_s?), metadata(fields["_meta"]?))
        end

        private def self.property_schema(raw : RawJson) : ElicitationPropertySchema?
          unless WireFrame.repeated_members(raw.json, "type").empty?
            invalid("Ambiguous form property type")
          end
          type = raw.field("type").try(&.as_s?) || invalid("Form property requires a type")
          fields = case type
                   when "string"
                     property_fields(raw, {"minLength", "maxLength", "format", "enum", "oneOf"})
                   when "number", "integer"
                     property_fields(raw, {"minimum", "maximum"})
                   when "array"
                     property_fields(raw, {"minItems", "maxItems", "items"})
                   when "boolean"
                     property_fields(raw, Tuple.new)
                   else
                     return nil
                   end
          property = ElicitationPropertySchema.new(type, title: fields["title"]?.try(&.as_s?),
            description: fields["description"]?.try(&.as_s?), meta: metadata(fields["_meta"]?))
          default = fields["default"]?
          case type
          when "string"
            property.min_length = constraint(fields["minLength"]?, "minLength") { |value| unsigned_digits(value).to_u32? }
            property.max_length = constraint(fields["maxLength"]?, "maxLength") { |value| unsigned_digits(value).to_u32? }
            check_range(property.min_length, property.max_length, "string length")
            property.format = constraint(fields["format"]?, "format", &.as_s?)
            property.enum_values = strings(fields["enum"]?, "enum", nonempty: true)
            property.one_of = titled_choices(fields["oneOf"]?, "oneOf")
            if property.enum_values && property.one_of
              invalid("Form property cannot specify both enum and oneOf")
            end
            property.default = default.try(&.as_s?).try { |value| JSON::Any.new(value) }
          when "number", "integer"
            property.minimum = constraint(fields["minimum"]?, "minimum") { |value| number(value, type) }
            property.maximum = constraint(fields["maximum"]?, "maximum") { |value| number(value, type) }
            check_range(property.minimum, property.maximum, "numeric value")
            property.default = default.try { |value| number(value, type) }.try { |value| JSON::Any.new(value) }
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
            property.items = select_items(items) || return nil
            property.default = default.try(&.elements?).try do |values|
              JSON::Any.new(values.compact_map { |value| value.as_s?.try { |item| JSON::Any.new(item) } })
            end
          end
          property
        end

        private def self.property_fields(raw : RawJson, keys : Tuple) : Hash(String, RawJson)
          raw.unambiguous_patch(required: keys, optional: {"title", "description", "default", "_meta"}).members?.not_nil!
        end

        private def self.select_items(raw : RawJson) : MultiSelectItems?
          source = raw.unambiguous_patch(required: {"type"}, optional: {"_meta"})
          fields = source.members? || invalid("Array form items must be an object")
          meta = metadata(fields["_meta"]?)
          if discriminator = fields["type"]?
            type = discriminator.as_s? || invalid("Invalid array form item type")
            return unless type == "string"

            reject_repeated(source, "enum")
            options = strings(fields["enum"]?, "enum", nonempty: true) || invalid("String array items require enum")
            MultiSelectItems.new(items_type: type, enum_values: options, meta: meta)
          else
            reject_repeated(source, "anyOf")
            choices = titled_choices(fields["anyOf"]?, "anyOf") || invalid("Titled array items require anyOf")
            MultiSelectItems.new(any_of: choices, meta: meta)
          end
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

        private def self.titled_choices(value : RawJson?, name : String) : Array(EnumOption)?
          return if value.nil? || value.null?

          elements = value.elements? || invalid("Form #{name} must be an array")
          invalid("Form #{name} must contain a choice") if elements.empty?
          elements.map do |element|
            fields = element.unambiguous_patch(required: {"const", "title"}, optional: {"description", "_meta"}).members?
            choice = fields.try(&.["const"]?).try(&.as_s?)
            title = fields.try(&.["title"]?).try(&.as_s?)
            invalid("Form #{name} requires a string const and title") unless fields && choice && title

            EnumOption.new(choice, title, fields["description"]?.try(&.as_s?), metadata(fields["_meta"]?))
          end
        end

        private def self.check_range(minimum, maximum, name : String) : Nil
          invalid("Form #{name} has a minimum above its maximum") if minimum && maximum && minimum > maximum
        end

        private def self.constraint(value : RawJson?, name : String, &)
          return if value.nil? || value.null?

          (yield value) || invalid("Invalid form #{name}")
        end

        private def self.unsigned_digits(value : RawJson) : String
          value.json == "-0" ? "0" : value.json
        end

        private def self.number(value : RawJson, type : String) : Int64 | Float64 | Nil
          if integer = value.as_i64?
            return integer
          end
          value.json.to_f64?.try { |number| number if number.finite? } if type == "number"
        end

        private def self.metadata(value : RawJson?) : Hash(String, JSON::Any)?
          if value && value.object?
            PreservedJson.new(value, project_object_members: true, project_nested_objects: true).value.try(&.as_h?)
          end
        end

        private def self.invalid(message : String) : NoReturn
          raise JSON::ParseException.new(message, 1, 1)
        end
      end
    end
  end
end
