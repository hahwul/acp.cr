require "./protocol/v2/updates"

module ACP
  module V2
    # The latest title, activity time, and metadata reported by session info updates.
    record SessionInfoSnapshot,
      session_id : String,
      title : String?,
      updated_at : String?,
      meta_raw : Protocol::RawJson?

    # The latest context-window counts and cumulative cost reported for a session.
    record SessionUsageSnapshot,
      session_id : String,
      used : UInt64,
      size : UInt64,
      cost_raw : Protocol::RawJson?,
      meta_raw : Protocol::RawJson? do
      # Decodes a detached Float64 projection of the cumulative cost.
      def cost : Protocol::Cost?
        if raw = cost_raw
          Protocol::V2::UsageUpdate::OptionalCost.from_json(JSON::PullParser.new(raw.json)).try(&.cost)
        end
      end

      # Returns the fraction of available context in use, or zero when capacity is zero.
      def usage_ratio : Float64
        size.zero? ? 0.0 : used.to_f64 / size.to_f64
      end
    end

    # Retains the latest reported session info and usage from ACP v2 updates.
    class SessionDetailsStore
      private alias Wire = Protocol::V2

      # Default number of sessions retained in a store.
      DEFAULT_SESSION_LIMIT = 128

      # Default byte budget for each session's ID and reported details.
      DEFAULT_SESSION_BYTE_LIMIT = 64 * 1024

      private class Entry
        getter info : SessionInfoSnapshot?
        getter usage : SessionUsageSnapshot?
        @info_bytes = 0_i64
        @usage_bytes = 0_i64

        def initialize(@session_id : String, @byte_limit : Int32?)
        end

        def apply(patch : Wire::SessionInfoUpdate) : Bool
          title = patch.title_present? ? patch.title : @info.try(&.title)
          updated_at = patch.updated_at_present? ? patch.updated_at : @info.try(&.updated_at)
          metadata = patch.apply_metadata_raw(@info.try(&.meta_raw))
          bytes = (title.try(&.bytesize) || 0).to_i64 + (updated_at.try(&.bytesize) || 0) + (metadata.try(&.json.bytesize) || 0)
          return false unless fits?(@usage_bytes + bytes)

          @info = SessionInfoSnapshot.new(@session_id, title, updated_at, metadata)
          @info_bytes = bytes
          true
        end

        def apply(patch : Wire::UsageUpdate) : Bool
          return false unless fits?(@info_bytes + @usage_bytes)

          previous_cost = @usage.try(&.cost_raw)
          previous_meta = @usage.try(&.meta_raw)
          cost = patch.cost_present? ? patch.cost_raw : previous_cost
          metadata = patch.apply_metadata_raw(previous_meta)
          unless fits_usage?(cost, metadata)
            # Preserve clears and accept an optional field if it fits on its own.
            previous_cost = nil unless cost
            previous_meta = nil unless metadata
            if fits_usage?(cost, previous_meta)
              metadata = previous_meta
            elsif fits_usage?(previous_cost, metadata)
              cost = previous_cost
            else
              cost = previous_cost
              metadata = previous_meta
            end
          end
          @usage_bytes = raw_bytes(cost) + raw_bytes(metadata)
          @usage = SessionUsageSnapshot.new(@session_id, patch.used, patch.size, cost, metadata)
          true
        end

        private def fits_usage?(cost : Protocol::RawJson?, metadata : Protocol::RawJson?) : Bool
          fits?(@info_bytes + raw_bytes(cost) + raw_bytes(metadata))
        end

        private def raw_bytes(raw : Protocol::RawJson?) : Int64
          raw.try(&.json.bytesize.to_i64) || 0_i64
        end

        private def fits?(details_bytes : Int64) : Bool
          (limit = @byte_limit) ? @session_id.bytesize.to_i64 + details_bytes <= limit : true
        end
      end

      @sessions = {} of String => Entry
      @mutex = Mutex.new

      # Creates a store with configurable count and byte limits. Nil removes that limit.
      def initialize(*, @session_limit : Int32? = DEFAULT_SESSION_LIMIT, @session_byte_limit : Int32? = DEFAULT_SESSION_BYTE_LIMIT)
        if (limit = @session_limit) && limit <= 0
          raise ArgumentError.new("Session limit must be positive")
        end
        if (limit = @session_byte_limit) && limit <= 0
          raise ArgumentError.new("Session detail byte limit must be positive")
        end
      end

      # Applies a session info or usage update in receive order.
      def observe(params : Wire::SessionUpdateParams) : Bool
        return false unless params.update.session_update.in?("session_info_update", "usage_update")

        case patch = params.update.typed
        when Wire::SessionInfoUpdate, Wire::UsageUpdate
          @mutex.synchronize do
            session_id = params.session_id
            if entry = @sessions[session_id]?
              entry.apply(patch)
            elsif (limit = @session_limit) && @sessions.size >= limit
              false
            else
              entry = Entry.new(session_id, @session_byte_limit)
              return false unless entry.apply(patch)

              @sessions[session_id] = entry
              true
            end
          end
        else
          false
        end
      end

      # Returns the latest reported session info, if seen.
      def session_info(session_id : String) : SessionInfoSnapshot?
        @mutex.synchronize { @sessions[session_id]?.try(&.info) }
      end

      # Returns the latest reported context-window usage, if seen.
      def session_usage(session_id : String) : SessionUsageSnapshot?
        @mutex.synchronize { @sessions[session_id]?.try(&.usage) }
      end

      # Drops the info and usage for one session.
      def forget_session(session_id : String) : Bool
        @mutex.synchronize { !@sessions.delete(session_id).nil? }
      end
    end
  end
end
