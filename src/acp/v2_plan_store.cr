require "./protocol/v2/updates"

module ACP
  module V2
    # The latest complete representation of one ACP v2 plan.
    record PlanSnapshot,
      session_id : String,
      plan_id : String,
      plan_raw : Protocol::RawJson,
      meta_raw : Protocol::RawJson? do
      # Decodes a detached plan, including custom and future representations.
      def plan : Protocol::V2::PlanContent
        Protocol::V2::PlanContent.from_json(plan_raw.json)
      end
    end

    # Retains ACP v2 plan replacements and removals from session updates.
    class PlanStore
      private alias Wire = Protocol::V2

      # Default number of plans retained across sessions in a store.
      DEFAULT_PLAN_LIMIT = 128

      # Default serialized byte budget for a retained plan.
      DEFAULT_PLAN_BYTE_LIMIT = 256 * 1024

      @plans = {} of {String, String} => PlanSnapshot
      @mutex = Mutex.new

      # Creates a store with configurable count and byte limits. Nil removes that limit.
      def initialize(*, @plan_limit : Int32? = DEFAULT_PLAN_LIMIT, @plan_byte_limit : Int32? = DEFAULT_PLAN_BYTE_LIMIT)
        if (limit = @plan_limit) && limit <= 0
          raise ArgumentError.new("Plan limit must be positive")
        end
        if (limit = @plan_byte_limit) && limit <= 0
          raise ArgumentError.new("Plan byte limit must be positive")
        end
      end

      # Applies an update in receive order. Returns true when a snapshot is stored or discarded.
      # A valid over-budget replacement discards the previous snapshot for its ID, if any.
      def observe(params : Wire::SessionUpdateParams) : Bool
        payload = params.update
        return false unless payload.session_update.in?("plan_update", "plan_removed")
        return false if Wire::SessionUpdate::PLAN_WIRE_FIELDS.any? { |key| payload.repeated_field?(key) }

        case update = payload.typed
        when Wire::PlanUpdate
          retain(params.session_id, update)
        when Protocol::PlanRemovedUpdate
          @mutex.synchronize { !@plans.delete({params.session_id, update.plan_id}).nil? }
        else
          false
        end
      end

      # Returns the latest retained plan for the selected session and plan ID.
      def plan(session_id : String, plan_id : String) : PlanSnapshot?
        @mutex.synchronize { @plans[{session_id, plan_id}]? }
      end

      # Returns the plans currently retained for the selected session.
      def plans(session_id : String) : Array(PlanSnapshot)
        @mutex.synchronize { @plans.each_value.select { |snapshot| snapshot.session_id == session_id }.to_a }
      end

      # Drops the plan state for one session.
      def forget_session(session_id : String) : Bool
        @mutex.synchronize do
          before = @plans.size
          @plans.reject! { |key, _| key[0] == session_id }
          @plans.size < before
        end
      end

      private def retain(session_id : String, update : Wire::PlanUpdate) : Bool
        plan = update.plan
        key = {session_id, plan.plan_id}
        raw = plan.raw
        meta = update.meta_raw
        bytes = session_id.bytesize.to_i64 + plan.plan_id.bytesize + raw.json.bytesize + (meta.try(&.json.bytesize) || 0)

        @mutex.synchronize do
          if (limit = @plan_byte_limit) && bytes > limit
            return !@plans.delete(key).nil?
          end
          if (limit = @plan_limit) && @plans.size >= limit && !@plans.has_key?(key)
            return false
          end

          @plans[key] = PlanSnapshot.new(session_id, plan.plan_id, raw, meta)
          true
        end
      end
    end
  end
end
