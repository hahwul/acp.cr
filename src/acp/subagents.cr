require "path"
require "set"
require "./protocol/types"
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

    private record SetupRequest, method : String, session_id : String?, workspace : SessionWorkspace?

    @children = {} of String => Child
    @workspace = {} of String => SessionWorkspace
    @setups = {} of String => SetupRequest
    @setup_by_session = {} of String => SetupRequest
    @closed_roots = Set(String).new

    def child?(session_id : String) : Bool
      @children.has_key?(session_id)
    end

    def snapshot(session_id : String) : SubagentSession?
      return unless child = @children[session_id]?

      attaching = !setup_for(session_id).nil?
      state = child.state.try { |value| Protocol::SubagentState.new(value.state, value.json_unmapped.dup) } unless attaching
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
      return unless Path[cwd].absolute? && additional_directories.all? { |directory| Path[directory].absolute? }

      SessionWorkspace.new(cwd, additional_directories.dup)
    end

    def cancel?(session_id : String) : Bool
      return false if setup_for(session_id)

      !@children[session_id]?.try(&.capabilities).try(&.cancel).nil?
    end

    def request_sent(id : String, method : String, params : Hash(String, JSON::Any)?) : Nil
      sid = params.try(&.["sessionId"]?).try(&.as_s?)
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
      when Protocol::AgentMethod::SESSION_NEW, Protocol::AgentMethod::SESSION_CLOSE
      else
        return
      end

      cwd = params.try(&.["cwd"]?).try(&.as_s?)
      dirs = params.try(&.["additionalDirectories"]?).try(&.as_a?).try(&.compact_map(&.as_s?))
      workspace = SessionWorkspace.new(cwd, dirs || [] of String) if cwd
      setup = SetupRequest.new(method, sid, workspace)
      @setups[id] = setup
      if sid && method != Protocol::AgentMethod::SESSION_CLOSE
        @setup_by_session[sid] = setup
      end
    end

    # Applies a response at the dispatch boundary, before the next update.
    # Returns closed session IDs whose pending user input needs a reply.
    def request_finished(id : String, response : JSON::Any? = nil) : Array(String)?
      return unless setup = @setups.delete(id)
      sid = setup.session_id
      method = setup.method
      workspace = setup.workspace
      raw_result = response.try(&.["result"]?)

      case method
      when Protocol::AgentMethod::SESSION_LOAD, Protocol::AgentMethod::SESSION_RESUME
        return unless sid

        @setup_by_session.delete(sid)
        if valid_attach_result?(method, response, raw_result)
          @closed_roots.delete(sid)
          @workspace[sid] = workspace if workspace
        else
          clear_descendant_runtime(sid)
        end
      when Protocol::AgentMethod::SESSION_NEW
        if workspace && raw_result && !response.try(&.["error"]?) && (created_id = raw_result.as_h?.try(&.["sessionId"]?).try(&.as_s?))
          @workspace[created_id] = workspace
        end
      when Protocol::AgentMethod::SESSION_CLOSE
        if sid && closed_session?(response, raw_result)
          drop_runtime(sid)
          return descendants(sid).push(sid)
        end
      end
      nil
    end

    def drop_runtime(session_id : String) : Nil
      return if child?(session_id)

      @closed_roots.add(session_id) if @workspace.delete(session_id) || @children.any? { |_, child| child.parent_id == session_id }
      clear_descendant_runtime(session_id)
    end

    def clear : Nil
      @children.clear
      @workspace.clear
      @setups.clear
      @setup_by_session.clear
      @closed_roots.clear
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

      if current_updates?(sid)
        child.capabilities = patch.capabilities if patch.capabilities_present?
        if patch.state_present?
          child.state = patch.state.try { |value| Protocol::SubagentState.new(value.state, value.json_unmapped.dup) }
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
      descendants(session_id).each { |sid| @children[sid].clear_runtime }
    end

    private def valid_attach_result?(method : String, response : JSON::Any?, result : JSON::Any?) : Bool
      return false unless result && !response.try(&.["error"]?)

      if method == Protocol::AgentMethod::SESSION_LOAD
        Protocol::SessionLoadResult.from_json(result.to_json)
      else
        Protocol::SessionResumeResult.from_json(result.to_json)
      end
      true
    rescue JSON::ParseException
      false
    end

    private def closed_session?(response : JSON::Any?, result : JSON::Any?) : Bool
      if error = response.try(&.["error"]?)
        return error.as_h?.try(&.["code"]?).try(&.as_i64?) == JsonRpcError::RESOURCE_NOT_FOUND
      end
      return false unless result

      Protocol::SessionCloseResult.from_json(result.to_json)
      true
    rescue JSON::ParseException
      false
    end
  end
end
