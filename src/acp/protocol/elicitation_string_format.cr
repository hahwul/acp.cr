require "socket"
require "./content_block"

module ACP
  module Protocol
    # :nodoc:
    module ElicitationStringFormat
      def self.valid?(format : String?, value : String, *, v2 : Bool) : Bool
        case format
        when "email"     then mailbox?(value)
        when "uri"       then Protocol.absolute_uri_syntax?(value)
        when "date"      then !calendar_date(value).nil?
        when "date-time" then date_time?(value) || (!v2 && iso8601?(value))
        else                  true
        end
      end

      # JSON Schema's email format uses the RFC 5321 Mailbox production.
      private def self.mailbox?(value : String) : Bool
        match = /\A(?:"(?:[\x20-\x21\x23-\x5b\x5d-\x7e]|\\[\x20-\x7e])*"|([^@"]+))@([^\r\n]+)\z/.match(value)
        return false unless match

        if local = match[1]?
          return false unless local.split('.').all? { |atom| atom.matches?(/\A[A-Za-z0-9!#$%&'*+\/=?^_`{|}~\-]+\z/) }
        end

        domain = match[2]
        return address_literal?(domain.byte_slice(1, domain.bytesize - 2)) if domain.starts_with?('[') && domain.ends_with?(']')

        domain.split('.').all? { |label| label.matches?(/\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\z/) }
      end

      private def self.address_literal?(literal : String) : Bool
        tag, colon, address = literal.partition(':')
        return !ipv4_octets(literal).nil? if colon.empty?

        if tag.compare("IPv6", case_insensitive: true) == 0
          return smtp_ipv6?(address)
        end

        # Validate the syntax of extension tags without consulting a registry.
        tag.matches?(/\A[A-Za-z0-9-]*[A-Za-z0-9]\z/) && address.matches?(/\A[\x21-\x5a\x5e-\x7e]+\z/)
      end

      private def self.smtp_ipv6?(address : String) : Bool
        groups = address.split(':', remove_empty: true).size
        if address.includes?('.')
          prefix, separator, tail = address.rpartition(':')
          return false if separator.empty? || !(octets = ipv4_octets(tail))

          address = prefix + separator + octets.join('.')
          groups += 1 # A dotted IPv4 suffix occupies two IPv6 groups.
        end
        return false if address.includes?("::") && groups > 6
        return false if address.includes?('%')

        Socket::IPAddress.valid_v6?(address)
      end

      private def self.ipv4_octets(address : String) : Array(Int32)?
        octets = address.split('.')
        return unless octets.size == 4 && octets.all? { |octet| octet.matches?(/\A[0-9]{1,3}\z/) }

        values = octets.map(&.to_i)
        values if values.all? { |octet| octet <= 255 }
      end

      private def self.calendar_date(value : String) : {Int32, Int32, Int32}?
        match = /\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z/.match(value)
        return unless match

        year, month, day = match[1].to_i, match[2].to_i, match[3].to_i
        {year, month, day} if 1 <= month <= 12 && 1 <= day <= Time.days_in_month(year, month)
      end

      private def self.iso8601?(value : String) : Bool
        date, separator, time = value.partition('T')
        return false if separator.empty?
        return false unless date.matches?(/\A[0-9]{4}(?:-[0-9]{2}-[0-9]{2}|[0-9]{4}|-?[0-9]{3}|-W[0-9]{2}-[1-7]|W[0-9]{2}[1-7])\z/)

        match = /\A((?:[01][0-9]|2[0-4])(?:(?::[0-5][0-9]){1,2}|(?:[0-5][0-9]){1,2})?(?:[.,][0-9]+)?)(?:[Zz]|[+-](?:[01][0-9]|2[0-3])(?::?[0-5][0-9])?)?\z/.match(time)
        return false unless match
        clock = match[1]
        if clock.starts_with?("24")
          remainder = clock.byte_slice(2)
          return false unless remainder.matches?(/\A[0:.,]*\z/)
          clock = "00" + remainder
        end

        # Validate the calendar and clock with a placeholder zone. The match
        # above already checks the optional ISO offset, including hour-only offsets.
        Time.parse_iso8601("#{date}T#{clock}Z")
        true
      rescue Time::Format::Error | ArgumentError
        false
      end

      private def self.date_time?(value : String) : Bool
        # RFC 3339 permits lowercase separators, arbitrary fraction digits,
        # a numeric offset, and second 60 at the end of a UTC month.
        match = /\A([0-9]{4}-[0-9]{2}-[0-9]{2})[Tt]([01][0-9]|2[0-3]):([0-5][0-9]):([0-5][0-9]|60)(?:\.[0-9]+)?(?:[Zz]|([+-])([01][0-9]|2[0-3]):([0-5][0-9]))\z/.match(value)
        return false unless match && (date = calendar_date(match[1]))
        return true unless match[4] == "60"

        year, month, day = date
        utc_minute = match[2].to_i * 60 + match[3].to_i
        if sign = match[5]?
          offset = match[6].to_i * 60 + match[7].to_i
          utc_minute += sign == "-" ? offset : -offset
        end
        (utc_minute == 23 * 60 + 59 && day == Time.days_in_month(year, month)) ||
          (utc_minute == -1 && day == 1)
      end
    end
  end
end
