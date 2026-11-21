require "./wire_frame"

module ACP
  module Protocol
    # :nodoc:
    module OptionalMetadata
      def self.from_json(pull : JSON::PullParser) : Hash(String, JSON::Any)?
        JSON.parse(WireFrame.read_raw(pull)).as_h?
      rescue JSON::ParseException
        nil
      end

      def self.to_json(value : Hash(String, JSON::Any), builder : JSON::Builder) : Nil
        value.to_json(builder)
      end
    end
  end
end
