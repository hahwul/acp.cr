require "./wire_frame"

module ACP
  module Protocol
    # :nodoc:
    module CapabilityFlag
      def self.from_json(pull : JSON::PullParser) : Bool
        return pull.read_bool if pull.kind.bool?

        pull.skip
        false
      end

      def self.to_json(value : Bool, json : JSON::Builder) : Nil
        json.bool(value)
      end
    end

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

    # :nodoc:
    module DefaultCapabilityObject(T)
      def self.from_json(pull : JSON::PullParser) : T
        OptionalCapabilityObject(T).from_json(pull) || T.new
      end

      def self.to_json(value : T, json : JSON::Builder) : Nil
        value.to_json(json)
      end
    end

    # :nodoc:
    module OptionalCapabilityString
      def self.from_json(pull : JSON::PullParser) : String?
        return pull.read_string if pull.kind.string?

        pull.skip
        nil
      end

      def self.to_json(value : String, json : JSON::Builder) : Nil
        json.string(value)
      end
    end
  end
end
