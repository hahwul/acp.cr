module ACP
  module Protocol
    # :nodoc:
    module ElicitationPattern
      private ASCII_DIGITS = "0-9"
      private ASCII_WORDS  = "A-Za-z0-9_"
      private JS_SPACES    = %q(\x{9}-\x{d}\x{20}\x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}\x{feff})

      # Translate common ECMAScript character classes and Unicode escapes before
      # using Crystal's regex engine.
      def self.normalize(pattern : String) : String
        in_class = false
        pattern.gsub(/\\(?:u[Dd][89AaBb][0-9A-Fa-f]{2}\\u[Dd][CcDdEeFf][0-9A-Fa-f]{2}|u[0-9A-Fa-f]{4}|.)|\[\^?\]|[\[\].]/m) do |token|
          case token
          when "["
            in_class = true
            token
          when "]"
            in_class = false
            token
          when "[]", "[^]"
            if in_class
              in_class = false
              token
            else
              token == "[]" ? "(?!)" : "(?s:.)"
            end
          when "."
            in_class ? token : %q([^\r\n\x{2028}\x{2029}])
          when %q(\d)
            in_class ? ASCII_DIGITS : "[#{ASCII_DIGITS}]"
          when %q(\D)
            in_class ? %q(\x{0}-\x{2f}\x{3a}-\x{10ffff}) : "[^#{ASCII_DIGITS}]"
          when %q(\w)
            in_class ? ASCII_WORDS : "[#{ASCII_WORDS}]"
          when %q(\W)
            in_class ? %q(\x{0}-\x{2f}\x{3a}-\x{40}\x{5b}-\x{5e}\x{60}\x{7b}-\x{10ffff}) : "[^#{ASCII_WORDS}]"
          when %q(\s)
            in_class ? JS_SPACES : "[#{JS_SPACES}]"
          when %q(\S)
            in_class ? %q(\x{0}-\x{8}\x{e}-\x{1f}\x{21}-\x{9f}\x{a1}-\x{167f}\x{1681}-\x{1fff}\x{200b}-\x{2027}\x{202a}-\x{202e}\x{2030}-\x{205e}\x{2060}-\x{2fff}\x{3001}-\x{fefe}\x{ff00}-\x{10ffff}) : "[^#{JS_SPACES}]"
          when %q(\v)
            %q(\x{b})
          when %q(\b), %q(\B)
            in_class ? token : word_boundary(token)
          else
            token.starts_with?(%q(\u)) ? unicode_escape(token) : token
          end
        end
      end

      private def self.word_boundary(token : String) : String
        boundary = "(?:(?<![#{ASCII_WORDS}])(?=[#{ASCII_WORDS}])|(?<=[#{ASCII_WORDS}])(?![#{ASCII_WORDS}]))"
        token == %q(\b) ? boundary : "(?!#{boundary})"
      end

      private def self.unicode_escape(token : String) : String
        return token if token.bytesize < 6

        codepoint = token.byte_slice(2, 4).to_i(16)
        if token.bytesize == 12
          trail = token.byte_slice(8, 4).to_i(16)
          codepoint = ((codepoint - 0xd800) << 10) + (trail - 0xdc00) + 0x10000
        end
        "\\x{#{codepoint.to_s(16)}}"
      end
    end
  end
end
