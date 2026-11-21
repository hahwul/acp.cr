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
    end

    private record RootState, snapshot : Protocol::RawJson, generation : UInt64
    private record EarlyState, payload : Protocol::RawJson, revision : UInt64

    private IDLE_STATE    = Protocol::RawJson.from_json(%({"state":"idle"}))
    private UNKNOWN_STATE = Protocol::RawJson.from_json(%({"state":"unknown"}))
    # Unknown IDs can only be staged during new/fork and have a bounded wire size.
    private MAX_EARLY_STATES     = 64
    private MAX_EARLY_STATE_SIZE = 64 * 1024

    @children = {} of String => Child
    @workspace = {} of String => SessionWorkspace
    @root_states = {} of String => RootState
    @root_generation = 0_u64
    @early_states = {} of String => EarlyState
    @state_revision = 0_u64
    @setups = {} of String => SetupRequest
    @setup_by_session = {} of String => SetupRequest
    @closed_roots = Set(String).new
    @cancellable_entities = Set(Tuple(String, String, String)).new

    def initialize(@v2 : Bool = false)
    end

    def child?(session_id : String) : Bool
      @children.has_key?(session_id)
    end

    def snapshot(session_id : String) : SubagentSession?
      return unless child = @children[session_id]?

      attaching = !setup_for(session_id).nil?
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

    def root_generation(session_id : String) : UInt64?
      @root_states[session_id]?.try(&.generation)
    end

    def setup_waiting_to_write?(session_id : String) : Bool
      if setup = setup_for(session_id)
        return !setup.written?
      end
      false
    end

    def root_setup_written(id : String) : Nil
      if setup = @setups[id]?
        setup.state_revision = @state_revision
      end
    end

    def observe_root_state(session_id : String, update : String) : Nil
      return if child?(session_id)

      setup = @setup_by_session[session_id]?
      setup = nil unless setup.try(&.written?)
      if setup
        return unless current_updates?(session_id)
      elsif @closed_roots.includes?(session_id)
        return
      end

      attached = @root_states[session_id]?
      early = !attached && !setup && @setups.each_value.any? { |candidate| candidate.written? && candidate.creates_session? }
      return unless setup || attached || early

      wire = Protocol::RawJson.new(JSON::PullParser.new(update))
      return unless wire.field("state").try(&.as_s?)

      state = wire.without_field("sessionUpdate")
      setup.state = state if setup
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
      return false if setup_for(session_id)

      !@children[session_id]?.try(&.capabilities).try(&.cancel).nil?
    end

    def known_session?(session_id : String) : Bool
      @workspace.has_key?(session_id) || @children.has_key?(session_id) ||
        @closed_roots.includes?(session_id) || @setup_by_session.has_key?(session_id)
    end

    def request_sent(id : String, method : String, params : Hash(String, JSON::Any)?) : Nil
      sid = params.try(&.["sessionId"]?).try(&.as_s?)
      if @v2 && (key = entity_cancel_key(method))
        entity_id = params.try(&.[key]?).try(&.as_s?)
        if sid && entity_id && !setup_for(sid) && @cancellable_entities.includes?({sid, key, entity_id})
          return
        end
        raise InvalidStateError.new("#{method} requires a current cancel capability for this entity")
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
        clear_descendant_runtime(sid)
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
        if attach_result(method, Protocol::WireFrame.result_json(response, frame))
          @closed_roots.delete(sid)
          @workspace[sid] = workspace if workspace
          attach_root_state(sid, setup.state || root_state(sid) || UNKNOWN_STATE) if @v2
        else
          clear_descendant_runtime(sid)
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
            attach_root_state(new_id, initial || IDLE_STATE)
          end
        end
        @early_states.clear unless @setups.each_value.any?(&.creates_session?)
      end
      nil
    end

    private def attach_root_state(session_id : String, snapshot : Protocol::RawJson) : Nil
      @root_generation += 1
      @root_states[session_id] = RootState.new(snapshot, @root_generation)
    end

    # Releases runtime tracking and returns the affected session IDs.
    def close_runtime(session_id : String) : Array(String)
      drop_runtime(session_id)
      descendants(session_id).push(session_id)
    end

    def drop_runtime(session_id : String) : Nil
      return if child?(session_id)

      @closed_roots.add(session_id) if @workspace.delete(session_id) || @children.any? { |_, child| child.parent_id == session_id }
      @root_states.delete(session_id)
      @early_states.delete(session_id)
      clear_descendant_runtime(session_id)
    end

    def clear : Nil
      @children.clear
      @workspace.clear
      @root_states.clear
      @early_states.clear
      @setups.clear
      @setup_by_session.clear
      @closed_roots.clear
      @cancellable_entities.clear
    end

    # Observes v2 capabilities at the wire boundary. Each replaying session
    # has its own marker. A marked parent's upsert can authorize its child.
    def observe_v2_update(session_id : String, update : Hash(String, JSON::Any), update_json : String?) : Bool
      case update["sessionUpdate"]?.try(&.as_s?)
      when "replay_complete"
        if (setup = setup_for(session_id)) && setup.written?
          setup.replay_markers.try(&.add(session_id))
        end
      when "subagent_update"
        return announce(session_id, Protocol::SubagentUpdate.from_json(update_json || Protocol::WireFrame.encode(update)))
      when "state_update"
        if (child = @children[session_id]?) && current_updates?(session_id)
          state = Protocol::SubagentState.from_json(update_json || Protocol::WireFrame.encode(update))
          state.json_unmapped.delete("sessionUpdate")
          child.state = state
        end
      when "tool_call_update"
        observe_cancel_marker(session_id, "toolCallId", update)
      when "terminal_update"
        observe_cancel_marker(session_id, "terminalId", update)
      end
      true
    rescue JSON::ParseException
      false
    end

    private def entity_cancel_key(method : String) : String?
      case method
      when "tool_call/cancel" then "toolCallId"
      when "terminal/cancel"  then "terminalId"
      end
    end

    private def observe_cancel_marker(session_id : String, key : String, update : Hash(String, JSON::Any)) : Nil
      return unless current_updates?(session_id) && (entity_id = update[key]?.try(&.as_s?)) && (caps = update["capabilities"]?)

      entity = {session_id, key, entity_id}
      if caps.as_h?.try(&.["cancel"]?).try(&.as_h?)
        @cancellable_entities.add(entity)
      else
        @cancellable_entities.delete(entity)
      end
    end

    # Updates the association and effective child state. A historical update
    # can introduce a child but its state and capabilities stay unconfirmed.
    def announce(parent_id : String, patch : Protocol::SubagentUpdate) : Bool
      sid = patch.session_id
      if child = @children[sid]?
        return false if child.parent_id != parent_id
      else
        return false if @workspace.has_key?(sid) || @setup_by_session.has_key?(sid) || @closed_roots.includes?(sid)
        return false if ancestors(parent_id).includes?(sid)
        child = Child.new(parent_id)
        @children[sid] = child
      end

      child.title = patch.title if patch.title_present?
      child.description = patch.description if patch.description_present?
      child.cwd = patch.cwd if patch.cwd_present?
      child.additional_directories = patch.additional_directories.try(&.dup) if patch.additional_directories_present?

      if current_updates?(@v2 ? parent_id : sid)
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
      if setup = setup_for_ancestors(ids)
        if markers = setup.replay_markers
          return markers.includes?(session_id)
        end
        return setup.method == Protocol::AgentMethod::SESSION_RESUME
      end
      !@closed_roots.includes?(ids.last)
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

    private def clear_descendant_runtime(session_id : String) : Nil
      children = descendants(session_id)
      children.each { |sid| @children[sid].clear_runtime }
      @cancellable_entities.reject! { |entity| entity[0] == session_id || children.includes?(entity[0]) }
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
