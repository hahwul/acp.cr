require "./wire_frame"

module ACP
  module Protocol
    # :nodoc:
    module OptionalCapabilityObject(T)
      def self.from_json(pull : JSON::PullParser) : T?
        return T.from_json(WireFrame.read_raw(pull)) if pull.kind.begin_object?

        pull.skip
        nil
      rescue JSON::ParseException
        nil
      end

      def self.to_json(value : T, json : JSON::Builder) : Nil
        value.to_json(json)
      end
    end
  end
end
