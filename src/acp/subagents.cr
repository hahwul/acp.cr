require "path"
require "set"
require "./protocol/types"
require "./protocol/v2/sessions"
require "./protocol/v2/updates"
require "./errors"

module ACP
  # Workspace roots for an attached session, including inherited child values.
  record SessionWorkspace, cwd : String, additional_directories : Array(String)

  # The latest known state of an Agent-owned child session.
  record SubagentSession,
    session_id : String,
    parent_session_id : String,
    title : String?,
    description : String?,
    state : Protocol::SubagentState?,
    config_options : Array(Protocol::ConfigOption)?,
    cancel_allowed : Bool do
    # Whether the client can currently cancel this child's foreground work.
    def cancel? : Bool
      cancel_allowed
    end
  end

  # Client-owned state for exposed subagents. The client serializes calls
  # into this registry with its pending-request mutex.
  private class SubagentRegistry
    private class Child
      getter parent_id : String
      property title : String?
      property description : String?
      property cwd : String?
      property additional_directories : Array(String)?
      property capabilities : Protocol::SubagentSessionCapabilities?
      property state : Protocol::SubagentState?
      property config_options : Array(Protocol::ConfigOption)?

      def initialize(@parent_id : String)
      end

      def clear_runtime : Nil
        @capabilities = nil
        @state = nil
        @config_options = nil
      end
    end

    private class SetupRequest
      getter method : String
      getter session_id : String?
      getter workspace : SessionWorkspace?
      getter replay_markers : Set(String)?
      property state_revision : UInt64?
      property write_order : UInt64?
      property? retired = false
      property state : Protocol::RawJson?

      def initialize(@method : String, @session_id : String?, @workspace : SessionWorkspace?,
                     @replay_markers : Set(String)?)
      end

      def creates_session? : Bool
        @method.in?(Protocol::AgentMethod::SESSION_NEW, Protocol::AgentMethod::SESSION_FORK)
      end

      def written? : Bool
        !@state_revision.nil?
      end

      def observe_state(snapshot : Protocol::RawJson, *, retained : Bool) : Nil
        @state = snapshot.json.bytesize > MAX_EARLY_STATE_SIZE && retained ? nil : snapshot
      end
    end

    private record RootState, snapshot : Protocol::RawJson, attachment_order : UInt64
    private record EarlyState, payload : Protocol::RawJson, revision : UInt64

    private IDLE_STATE    = Protocol::RawJson.from_json(%({"state":"idle"}))
    private UNKNOWN_STATE = Protocol::RawJson.from_json(%({"state":"unknown"}))
    # Unknown IDs can only be staged during new/fork and have a bounded wire size.
    private MAX_EARLY_STATES     = 64
    private MAX_EARLY_STATE_SIZE = 64 * 1024
    private MAX_LATE_RESUMES     = 128

    @children = {} of String => Child
    @workspace = {} of String => SessionWorkspace
    @root_states = {} of String => RootState
    @early_states = {} of String => EarlyState
    @state_revision = 0_u64
    @setups = {} of String => SetupRequest
    @setup_by_session = {} of String => SetupRequest
    @late_resumes = {} of String => SetupRequest
    # An evicted or malformed reply cannot confirm the runtime. Keep the
    # session gated until a later successful attachment.
    @unconfirmed_roots = Set(String).new
    @closed_roots = Set(String).new
    @cancellable_entities = {} of Tuple(String, String, String) => UInt64

    def initialize(@v2 : Bool = false)
    end

    def child?(session_id : String) : Bool
      @children.has_key?(session_id)
    end

    def snapshot(session_id : String) : SubagentSession?
      return unless child = @children[session_id]?

      attaching = runtime_sync_pending?(session_id)
      state = child.state.try(&.dup) unless attaching
      config = child.config_options.try(&.dup) unless attaching
      SubagentSession.new(session_id, child.parent_id, child.title, child.description, state, config, cancel?(session_id))
    end

    def children(parent_id : String) : Array(SubagentSession)
      @children.each_key.compact_map do |sid|
        snapshot(sid) if @children[sid].parent_id == parent_id
      end.to_a
    end

    def workspace(session_id : String) : SessionWorkspace?
      sid = session_id
      cwd = nil
      additional_directories = nil
      while child = @children[sid]?
        cwd ||= child.cwd
        additional_directories ||= child.additional_directories
        sid = child.parent_id
      end

      root = @setup_by_session[sid]?.try(&.workspace) || @workspace[sid]?
      return unless root

      cwd ||= root.cwd
      additional_directories ||= root.additional_directories
      return unless Protocol.absolute_workspace?(cwd, additional_directories)

      SessionWorkspace.new(cwd, additional_directories.dup)
    end

    def root_state(session_id : String) : Protocol::RawJson?
      @root_states[session_id]?.try(&.snapshot)
    end

    def attachment_order(session_id : String) : UInt64?
      @root_states[session_id]?.try(&.attachment_order)
    end

    # Returns the order for an attached session or an in-flight reattachment.
    def plan_update_order(session_id : String) : UInt64?
      root = ancestors(session_id).last
      pending = @setup_by_session[root]?
      return pending.write_order if pending && pending.written? && !pending.retired?

      late_resume(root).try(&.write_order) || attachment_order(root)
    end

    # A new or forked session can report updates before its ID is confirmed.
    def accepts_early_plan_updates?(session_id : String) : Bool
      !@closed_roots.includes?(ancestors(session_id).last) && creating_session?
    end

    def creating_session? : Bool
      @setups.each_value.any? { |setup| setup.written? && setup.creates_session? }
    end

    def setup_waiting_to_write?(session_id : String) : Bool
      if setup = setup_for(session_id)
        return !setup.written?
      end
      false
    end

    def resume_timed_out?(session_id : String) : Bool
      !late_resume(ancestors(session_id).last).nil?
    end

    def root_setup_written(id : String, order : UInt64) : Nil
      if setup = @setups[id]?
        setup.state_revision = @state_revision
        setup.write_order = order
        if setup.method == Protocol::AgentMethod::SESSION_RESUME && (sid = setup.session_id)
          # An already attached root can keep its current entities without replay.
          clear_descendant_runtime(sid, include_root_entities: !!setup.replay_markers || !@root_states.has_key?(sid))
        end
      end
    end

    def observe_root_state(session_id : String, update : String) : Nil
      return if child?(session_id)

      written_setup = @setup_by_session[session_id]?
      written_setup = nil unless written_setup.try(&.written?)
      setup = written_setup || late_resume(session_id)
      if setup
        return unless current_updates?(session_id)
      elsif @closed_roots.includes?(session_id)
        return
      end

      attached = @root_states[session_id]?
      early = !attached && !setup && creating_session?
      return unless setup || attached || early

      wire = Protocol::RawJson.new(JSON::PullParser.new(update))
      return unless Protocol::StateFields.reported_state?(wire)

      state = wire.without_field("sessionUpdate")
      setup.try(&.observe_state(state, retained: written_setup.nil?))
      @root_states[session_id] = attached.copy_with(snapshot: state) if attached
      stage_early_state(session_id, state) if early
    end

    private def stage_early_state(session_id : String, state : Protocol::RawJson) : Nil
      @early_states.delete(session_id)
      return if session_id.bytesize.to_i64 + state.json.bytesize > MAX_EARLY_STATE_SIZE

      @state_revision += 1
      @early_states[session_id] = EarlyState.new(state, @state_revision)
      @early_states.shift if @early_states.size > MAX_EARLY_STATES
    end

    def cancel?(session_id : String) : Bool
      return false if runtime_sync_pending?(session_id)

      !@children[session_id]?.try(&.capabilities).try(&.cancel).nil?
    end

    def known_session?(session_id : String) : Bool
      child?(session_id) || reserved_root?(session_id)
    end

    private def reserved_root?(session_id : String) : Bool
      @workspace.has_key?(session_id) || @closed_roots.includes?(session_id) ||
        @setup_by_session.has_key?(session_id) || @unconfirmed_roots.includes?(session_id) || !late_resume(session_id).nil?
    end

    def request_sent(id : String, method : String, params : Hash(String, JSON::Any)?) : Nil
      sid = params.try(&.["sessionId"]?).try(&.as_s?)
      if entity_cancel?(method)
        check_entity_cancel(method, params)
        return
      end

      if sid && child?(sid)
        raise InvalidStateError.new("#{method} is unavailable for child session #{sid.inspect}")
      end

      case method
      when Protocol::AgentMethod::SESSION_LOAD, Protocol::AgentMethod::SESSION_RESUME
        return unless sid
        if @setup_by_session.has_key?(sid)
          raise InvalidStateError.new("A session setup is already pending for #{sid.inspect}")
        end
        clear_descendant_runtime(sid) unless @v2
      when Protocol::AgentMethod::SESSION_NEW, Protocol::AgentMethod::SESSION_FORK
      else
        return
      end

      cwd = params.try(&.["cwd"]?).try(&.as_s?)
      dirs = params.try(&.["additionalDirectories"]?).try(&.as_a?).try(&.compact_map(&.as_s?))
      workspace = SessionWorkspace.new(cwd, dirs || [] of String) if cwd
      replay_markers = Set(String).new if @v2 && method == Protocol::AgentMethod::SESSION_RESUME && !params.try(&.["replayFrom"]?).try(&.raw).nil?
      setup = SetupRequest.new(method, sid, workspace, replay_markers)
      @setups[id] = setup
      if sid && (method == Protocol::AgentMethod::SESSION_LOAD || method == Protocol::AgentMethod::SESSION_RESUME)
        @setup_by_session[sid] = setup
      end
    end

    def request_timed_out(id : String) : Nil
      if @v2 && (setup = @setups[id]?) && !setup.retired? && setup.method == Protocol::AgentMethod::SESSION_RESUME && (sid = setup.session_id)
        @setups.delete(id)
        @setup_by_session.delete(sid)
        if (snapshot = setup.state) && snapshot.json.bytesize > MAX_EARLY_STATE_SIZE
          setup.state = nil
        end
        @late_resumes[id] = setup
        if @late_resumes.size > MAX_LATE_RESUMES
          _, evicted = @late_resumes.shift
          @unconfirmed_roots.add(evicted.session_id.not_nil!)
        end
      else
        request_finished(id)
      end
    end

    # Preserve provisional updates until the actual result retires or
    # activates the attachment, even after the client stops waiting.
    def finish_late_resume(id : String, response : JSON::Any, frame : Protocol::WireFrame?, *, rejected : Bool) : {String, String?}?
      return unless (setup = @late_resumes.delete(id)) && (sid = setup.session_id)
      return {sid, nil} if child?(sid)

      if response["jsonrpc"]?.try(&.as_s?) == "2.0"
        result = Protocol::WireFrame.result_json(response, frame)
        if result && attach_result(setup.method, result)
          finish_resume(sid, setup)
          return {sid, result}
        end
      end

      pending = @setup_by_session[sid]?
      pending = nil unless pending.try(&.written?)
      newer = pending || late_resume(sid)
      unless newer && newer.write_order.not_nil! > setup.write_order.not_nil!
        active = @root_states.has_key?(sid)
        clear_descendant_runtime(sid, include_root_entities: !active)
        @unconfirmed_roots.add(sid) unless rejected && active
      end
      {sid, nil}
    end

    private def finish_resume(session_id : String, setup : SetupRequest) : Nil
      @closed_roots.delete(session_id)
      if workspace = setup.workspace
        @workspace[session_id] = workspace
      end
      if @v2
        order = setup.write_order.not_nil!
        attach_root_state(session_id, setup.state || root_state(session_id) || UNKNOWN_STATE, order)
        discard_late_resumes(session_id, before: order)
        @unconfirmed_roots.delete(session_id)
      end
    end

    private def late_resume(session_id : String) : SetupRequest?
      latest = nil
      @late_resumes.each_value do |setup|
        latest = setup if setup.session_id == session_id
      end
      latest
    end

    def retired_setup?(request_id : String) : Bool
      !!@setups[request_id]?.try(&.retired?)
    end

    # Applies a response at the dispatch boundary, before the next update.
    def request_finished(id : String, response : JSON::Any? = nil, frame : Protocol::WireFrame? = nil) : Nil
      return unless setup = @setups.delete(id)
      sid = setup.session_id
      method = setup.method
      workspace = setup.workspace

      case method
      when Protocol::AgentMethod::SESSION_LOAD, Protocol::AgentMethod::SESSION_RESUME
        return unless sid

        @setup_by_session.delete(sid)
        return if setup.retired?

        if attach_result(method, Protocol::WireFrame.result_json(response, frame))
          finish_resume(sid, setup)
        elsif !@v2 || setup.written?
          clear_descendant_runtime(sid, include_root_entities: !@root_states.has_key?(sid))
        end
      when Protocol::AgentMethod::SESSION_NEW, Protocol::AgentMethod::SESSION_FORK
        if workspace && (created = create_result(Protocol::WireFrame.result_json(response, frame))) && created.session_id != sid
          new_id = created.session_id
          @workspace[new_id] = workspace
          if @v2
            early = @early_states.delete(new_id)
            if early && (started = setup.state_revision) && early.revision > started
              initial = early.payload
            end
            attach_root_state(new_id, initial || IDLE_STATE, setup.write_order.not_nil!)
          end
        end
        @early_states.clear unless @setups.each_value.any?(&.creates_session?)
      end
      nil
    end

    private def attach_root_state(session_id : String, snapshot : Protocol::RawJson, order : UInt64) : Nil
      @root_states[session_id] = RootState.new(snapshot, order)
    end

    private def discard_late_resumes(session_id : String, *, before order : UInt64) : Nil
      @late_resumes.reject! do |_id, setup|
        setup.session_id == session_id && setup.write_order.not_nil! < order
      end
    end

    # Releases runtime tracking and returns the affected session IDs.
    def close_runtime(session_id : String, order : UInt64? = nil) : Array(String)
      preserve_after = nil
      if order
        @closed_roots.add(session_id) if reserved_root?(session_id)
        discard_late_resumes(session_id, before: order)
        if pending = @setup_by_session[session_id]?
          if written = pending.write_order
            pending.retired = true if written < order
            preserve_after = order if written > order
          end
        end
        preserve_after = order if late_resume(session_id)
      end
      drop_runtime(session_id, preserve_after: preserve_after)
      runtime_session_ids(session_id)
    end

    # The session and its tracked descendants.
    def runtime_session_ids(session_id : String) : Array(String)
      descendants(session_id).push(session_id)
    end

    def drop_runtime(session_id : String, *, preserve_after : UInt64? = nil) : Nil
      return if child?(session_id)

      @closed_roots.add(session_id) if @workspace.delete(session_id) || @children.any? { |_, child| child.parent_id == session_id }
      @root_states.delete(session_id)
      @early_states.delete(session_id)
      @unconfirmed_roots.delete(session_id)
      if preserve_after
        # A newer resume already cleared the previous child runtime at its
        # write. Hold the replacement until that resume's actual result.
        discard_old_entity_grants(session_id, preserve_after)
      else
        clear_descendant_runtime(session_id)
      end
    end

    def discard_old_entity_grants(session_id : String, order : UInt64) : Nil
      affected = runtime_session_ids(session_id)
      @cancellable_entities.reject! { |entity, written| affected.includes?(entity[0]) && written < order }
    end

    def clear : Nil
      @children.clear
      @workspace.clear
      @root_states.clear
      @early_states.clear
      @setups.clear
      @setup_by_session.clear
      @late_resumes.clear
      @unconfirmed_roots.clear
      @closed_roots.clear
      @cancellable_entities.clear
    end

    # Observes v2 capabilities at the wire boundary. Each replaying session
    # has its own marker. A marked parent's upsert can authorize its child.
    def observe_v2_update(session_id : String, update : Hash(String, JSON::Any), update_json : String?, *, replaying : Bool) : Bool
      case update["sessionUpdate"]?.try(&.as_s?)
      when "replay_complete"
        if (setup = setup_for(session_id)) && setup.written?
          setup.replay_markers.try(&.add(session_id))
        end
      when "subagent_update"
        wire = Protocol::RawJson.from_json(update_json || Protocol::WireFrame.encode(update))
        patch = Protocol::SubagentUpdate.from_json(Protocol::StateFields.normalize_patch(wire).json)
        return announce(session_id, patch, live: !replaying)
      when "state_update"
        if (child = @children[session_id]?) && !replaying && current_updates?(session_id)
          wire = Protocol::RawJson.from_json(update_json || Protocol::WireFrame.encode(update))
          return true unless Protocol::StateFields.reported_state?(wire)

          state = Protocol::SubagentState.from_json(wire.json)
          state.json_unmapped.delete("sessionUpdate")
          child.state = state
        end
      when "tool_call_update"
        observe_cancel_marker(session_id, "toolCallId", update) unless replaying
      when "terminal_update"
        observe_cancel_marker(session_id, "terminalId", update) unless replaying
      end
      true
    rescue JSON::ParseException
      false
    end

    def entity_cancel?(method : String) : Bool
      @v2 && !entity_cancel_key(method).nil?
    end

    def check_entity_cancel(method : String, params : Hash(String, JSON::Any)?) : Nil
      key = entity_cancel_key(method).not_nil!
      sid = params.try(&.["sessionId"]?).try(&.as_s?)
      entity_id = params.try(&.[key]?).try(&.as_s?)
      if sid && entity_id && !runtime_sync_pending?(sid) && @cancellable_entities.has_key?({sid, key, entity_id})
        return
      end
      raise InvalidStateError.new("#{method} requires a current cancel capability for this entity")
    end

    private def entity_cancel_key(method : String) : String?
      case method
      when "tool_call/cancel" then "toolCallId"
      when "terminal/cancel"  then "terminalId"
      end
    end

    private def observe_cancel_marker(session_id : String, key : String, update : Hash(String, JSON::Any)) : Nil
      return unless current_updates?(session_id) && (entity_id = update[key]?.try(&.as_s?)) && (caps = update["capabilities"]?)

      capabilities = caps.as_h?
      # Malformed capability patches default to omission.
      return if !caps.raw.nil? && !capabilities

      entity = {session_id, key, entity_id}
      if capabilities.try(&.["cancel"]?).try(&.as_h?)
        root = ancestors(session_id).last
        pending = @setup_by_session[root]?
        order = pending.try(&.write_order) || late_resume(root).try(&.write_order) || attachment_order(root)
        @cancellable_entities[entity] = order || 0_u64
      else
        @cancellable_entities.delete(entity)
      end
    end

    # Updates the association and effective child state. A historical update
    # can introduce a child but its state and capabilities stay unconfirmed.
    def announce(parent_id : String, patch : Protocol::SubagentUpdate, *, live : Bool = true) : Bool
      sid = patch.session_id
      if child = @children[sid]?
        return false if child.parent_id != parent_id
      else
        return false if reserved_root?(sid)
        return false if ancestors(parent_id).includes?(sid)
        child = Child.new(parent_id)
        @children[sid] = child
      end

      child.title = patch.title if patch.title_present?
      child.description = patch.description if patch.description_present?
      child.cwd = patch.cwd if patch.cwd_present?
      child.additional_directories = patch.additional_directories.try(&.dup) if patch.additional_directories_present?

      if live && current_updates?(@v2 ? parent_id : sid)
        child.capabilities = patch.capabilities if patch.capabilities_present?
        if patch.state_present?
          child.state = patch.state.try(&.dup)
        end
      end
      true
    end

    def update_config(session_id : String, options : Array(Protocol::ConfigOption)) : Nil
      if (child = @children[session_id]?) && current_updates?(session_id)
        child.config_options = options
      end
    end

    def replaying?(session_id : String) : Bool
      setup_for(session_id).try(&.method) == Protocol::AgentMethod::SESSION_LOAD
    end

    def current_updates?(session_id : String) : Bool
      ids = ancestors(session_id)
      if (setup = setup_for_ancestors(ids)) && (!@v2 || setup.written?)
        return false if setup.retired?

        if markers = setup.replay_markers
          return markers.includes?(session_id)
        end
        return setup.method == Protocol::AgentMethod::SESSION_RESUME
      end
      !@closed_roots.includes?(ids.last) || !late_resume(ids.last).nil?
    end

    private def runtime_sync_pending?(session_id : String) : Bool
      ids = ancestors(session_id)
      if (setup = setup_for_ancestors(ids)) && (!@v2 || setup.written?)
        return true
      end
      @unconfirmed_roots.includes?(ids.last) || !late_resume(ids.last).nil?
    end

    private def setup_for(session_id : String) : SetupRequest?
      return if @setup_by_session.empty?

      setup_for_ancestors(ancestors(session_id))
    end

    private def setup_for_ancestors(ids : Array(String)) : SetupRequest?
      ids.each do |sid|
        if setup = @setup_by_session[sid]?
          return setup
        end
      end
      nil
    end

    private def ancestors(session_id : String) : Array(String)
      ids = [session_id]
      while child = @children[ids.last]?
        ids << child.parent_id
      end
      ids
    end

    private def descendants(session_id : String) : Array(String)
      @children.keys.select { |sid| sid != session_id && ancestors(sid).includes?(session_id) }
    end

    private def clear_descendant_runtime(session_id : String, *, include_root_entities : Bool = true) : Nil
      children = descendants(session_id)
      children.each { |sid| @children[sid].clear_runtime }
      @cancellable_entities.reject! do |entity, _order|
        (include_root_entities && entity[0] == session_id) || children.includes?(entity[0])
      end
    end

    private def attach_result(method : String, result : String?)
      return unless result

      if @v2
        Protocol::V2::SessionResumeResult.from_json(result)
      elsif method == Protocol::AgentMethod::SESSION_LOAD
        Protocol::SessionLoadResult.from_json(result)
      else
        Protocol::SessionResumeResult.from_json(result)
      end
    rescue JSON::Error
      nil
    end

    private def create_result(result : String?)
      return unless result

      if @v2
        Protocol::V2::SessionNewResult.from_json(result)
      else
        Protocol::SessionNewResult.from_json(result)
      end
    rescue JSON::Error
      nil
    end
  end
end
