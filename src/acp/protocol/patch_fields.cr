module ACP
  module Protocol
    # :nodoc:
    module PatchFields
      # Keeps a malformed non-null value distinguishable from an explicit clear.
      struct Decoded(T, Decoder)
        getter value : T?

        def initialize(@value : T?)
        end

        def self.new(pull : JSON::PullParser) : self
          new(Decoder.from_json(pull))
        end

        def to_json(json : JSON::Builder) : Nil
          @value.to_json(json)
        end
      end

      # Adds nullable fields with default-on-error decoding and explicit clears.
      macro tolerant(fields)
        {% for name, declaration in fields %}
          @[JSON::Field(key: {{declaration[1]}}, presence: true, emit_null: true, ignore_serialize: !{{name.id}}_present?)]
          @{{name.id}}_patch : ::ACP::Protocol::PatchFields::Decoded({{declaration[0]}}, {{declaration[2]}})?

          @[JSON::Field(ignore: true)]
          @{{name.id}}_patch_present = false

          # Decoded replacement value when supplied.
          def {{name.id}} : {{declaration[0]}}?
            @{{name.id}}_patch.try(&.value)
          end

          # True when the patch supplies a valid replacement or an explicit clear.
          def {{name.id}}_present? : Bool
            @{{name.id}}_patch_present && (!@{{name.id}}_patch || !{{name.id}}.nil?)
          end

          # Marks the field present. Assign nil to send a clear.
          def {{name.id}}=(value : {{declaration[0]}}?) : {{declaration[0]}}?
            @{{name.id}}_patch_present = true
            @{{name.id}}_patch = value.try do |replacement|
              ::ACP::Protocol::PatchFields::Decoded({{declaration[0]}}, {{declaration[2]}}).new(replacement)
            end
            value
          end
        {% end %}
      end

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
