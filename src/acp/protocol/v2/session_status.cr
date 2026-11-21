require "../session_status"
require "./updates"

module ACP
  module Protocol
    module V2
      # Parameters of the read-only v2 session status query.
      alias SessionStatusParams = Protocol::SessionStatusParams

      # A read-only snapshot of the v2 session and its foreground activity.
      struct SessionStatusResult < Protocol::SessionStatusSnapshot
        # :nodoc:
        module StateConverter
          def self.from_json(pull : JSON::PullParser) : StateSnapshot?
            json = WireFrame.read_raw(pull)
            StateSnapshot.from_json(json) unless json == "null"
          rescue JSON::ParseException
            nil
          end

          def self.to_json(value : StateSnapshot, builder : JSON::Builder) : Nil
            value.to_json(builder)
          end
        end

        # Foreground snapshot when the Agent reports one in a usable form.
        @[JSON::Field(converter: ::ACP::Protocol::V2::SessionStatusResult::StateConverter)]
        property state : StateSnapshot?

        # Creates a status result with an optional foreground snapshot.
        def initialize(@raw_status : String, @state : StateSnapshot? = nil, meta : Hash(String, JSON::Any)? = nil)
          self.meta = meta
        end

        # Reads a status result, treating unusable state as unreported.
        def self.new(pull : JSON::PullParser) : self
          wire = StateFields.normalize_patch(RawJson.new(pull))
          previous_def(JSON::PullParser.new(wire.json))
        end
      end
    end
  end
end
