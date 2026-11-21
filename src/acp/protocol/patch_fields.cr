module ACP
  module Protocol
    # :nodoc:
    module PatchFields
      # Adds nullable fields that distinguish an omitted patch from a clear.
      macro define(fields)
        {% for name, declaration in fields %}
          @[JSON::Field(key: {{declaration[1]}}, presence: true)]
          getter {{name.id}} : {{declaration[0]}}?

          # True when the update includes this field, even if its value is null.
          @[JSON::Field(ignore: true)]
          getter? {{name.id}}_present : Bool = false

          # Marks the field present. Assign nil to send a clear.
          def {{name.id}}=(@{{name.id}} : {{declaration[0]}}?) : {{declaration[0]}}?
            @{{name.id}}_present = true
            @{{name.id}}
          end
        {% end %}

        protected def on_to_json(json : ::JSON::Builder)
          super
          {% for name, declaration in fields %}
            json.field({{declaration[1]}}, nil) if @{{name.id}}_present && @{{name.id}}.nil?
          {% end %}
        end
      end
    end
  end
end
