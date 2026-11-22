require "./optional_capability"

module ACP
  module Protocol
    # :nodoc:
    module OptionalRfc3339Timestamp
      def self.from_json(pull : JSON::PullParser) : String?
        return unless value = OptionalCapabilityString.from_json(pull)
        return unless value.ascii_only?

        date = /\A([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([01][0-9]|2[0-3]):([0-5][0-9]):([0-5][0-9]|60)(?:\.[0-9]++)?([Zz]|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])\z/.match(value)
        return unless date

        # Crystal starts at year one. Year 400 has the same calendar as year zero.
        year = date[1].to_i
        year = 400 if year.zero?
        local_minute = Time.utc(year, date[2].to_i, date[3].to_i, date[4].to_i, date[5].to_i)
        return if date[6] == "60" && !leap_second_position?(local_minute, date[7])

        value
      rescue ArgumentError
        nil
      end

      private def self.leap_second_position?(local_minute : Time, zone : String) : Bool
        offset = 0
        if zone.bytesize > 1
          offset = zone[1, 2].to_i * 60 + zone[4, 2].to_i
          offset = -offset if zone.starts_with?('-')
        end
        utc_minute = local_minute - offset.minutes
        utc_minute.hour == 23 && utc_minute.minute == 59 && (utc_minute + 1.minute).day == 1
      end
    end
  end
end
