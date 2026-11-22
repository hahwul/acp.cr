require "./protocol/raw_json"
require "./protocol/types"
require "./protocol/v2/configuration"

module ACP
  # Wire-order session choices, guarded by the Client's pending mutex.
  private class SessionChoices
    alias Raw = Protocol::RawJson

    class Snapshot
      getter? v2 : Bool
      getter modes : Raw?
      property options : Raw?
      @mode_revision = 0_u64
      @mode_write = 0_u64
      @mode_confirmed = 0_u64

      def initialize(@v2 : Bool, @modes : Raw?, @options : Raw?)
      end

      def v1_modes : Protocol::SessionModeState?
        if raw = @modes
          Protocol::SessionModeState.from_json(raw.json)
        end
      rescue JSON::Error
        nil
      end

      def v1_options : Array(Protocol::ConfigOption)?
        if raw = @options
          Protocol::OptionalConfigOptions.from_json(JSON::PullParser.new(raw.json))
        end
      end

      def v2_options : Array(Protocol::V2::ConfigOption)
        Protocol::V2::ConfigOption.decode_list(@options)
      end

      def replace(modes : Raw?, options : Raw?) : Nil
        @modes = modes
        @options = options
        @mode_revision += 1
      end

      def observe_mode(mode_id : String) : Nil
        @mode_revision += 1
        set_mode(mode_id)
      end

      def propose_mode : {UInt64, UInt64}
        @mode_write += 1
        {@mode_revision, @mode_write}
      end

      def confirm_mode(mode_id : String, revision : UInt64, write : UInt64) : Nil
        if @mode_revision == revision && write > @mode_confirmed
          @mode_confirmed = write
          set_mode(mode_id)
        end
      end

      private def set_mode(mode_id : String) : Nil
        value = Raw.new(JSON::Any.new(mode_id))
        modes = @modes || Raw.from_json(%({"availableModes":[]}))
        @modes = modes.with_field("currentModeId", value)
      end

      def validate_mode(mode_id : String) : Nil
        modes = v1_modes
        unless modes && modes.available_modes.any? { |mode| mode.id == mode_id }
          raise InvalidStateError.new("The Agent did not offer that session mode")
        end
      end

      def validate_option(config_id : String, value_type : String, value : JSON::Any) : Nil
        key = @v2 ? "configId" : "id"
        matches = @options.try(&.elements?).try(&.select { |entry| entry.field(key).try(&.as_s?) == config_id })
        unless matches && matches.size == 1
          raise InvalidStateError.new("The Agent did not offer an unambiguous session configuration option")
        end

        option = matches.first
        if @v2
          validate_v2_option(option, value_type, value)
          return
        end
        unless option.field("name").try(&.as_s?)
          raise InvalidStateError.new("The Agent did not offer a usable session configuration option")
        end

        raw_type = option.field("type")
        type = raw_type.try(&.as_s?)
        type ||= "select" unless raw_type
        case type
        when "select"
          selected = value.as_s?
          unless option.field("currentValue").try(&.as_s?)
            raise InvalidStateError.new("The Agent did not offer a usable select option")
          end
          unless value_type == "id" && selected && selectable?(option, selected)
            raise ArgumentError.new("Choose an advertised value ID for this select option")
          end
        when "boolean"
          unless option.field("currentValue").try(&.json).in?("true", "false")
            raise InvalidStateError.new("The Agent did not offer a usable boolean option")
          end
          unless value_type == "boolean" && !value.as_bool?.nil?
            raise ArgumentError.new("This configuration option requires a boolean value")
          end
        else
          raise InvalidStateError.new("Unsupported session configuration option type")
        end
      end

      private def validate_v2_option(raw : Raw, value_type : String, value : JSON::Any) : Nil
        option = Protocol::V2::ConfigOption.decode_usable(raw)
        unless option && !option.type.empty?
          raise InvalidStateError.new("The Agent did not offer a usable session configuration option")
        end

        case option.type
        when "select"
          selected = value.as_s?
          unless value_type == "id" && selected && option.selectable_values.try(&.any? { |item| item.value == selected })
            raise ArgumentError.new("Choose an advertised value ID for this select option")
          end
        when "boolean"
          unless value_type == "boolean" && !value.as_bool?.nil?
            raise ArgumentError.new("This configuration option requires a boolean value")
          end
        end
      end

      private def selectable?(option : Raw, value : String) : Bool
        Protocol::ConfigOption.from_json(option.json).all_values.any? { |item| item.value == value }
      rescue JSON::Error
        false
      end
    end

    private class Commands
      getter raw : Raw
      @skill_names : Set(String)?
      @unconfirmed_retirements = 0_u64

      def initialize(@raw : Raw)
      end

      def replace(raw : Raw) : Nil
        @raw = raw
        @skill_names = nil
      end

      def current? : Bool
        @unconfirmed_retirements.zero?
      end

      def retirement_timed_out : Nil
        @unconfirmed_retirements += 1
      end

      def retirement_failed : Nil
        @unconfirmed_retirements -= 1
      end

      def entries : Array(Protocol::V2::AvailableCommand)
        Protocol::V2::AvailableCommandsJson.decode_list(@raw)
      end

      def skill_names : Set(String)
        @skill_names ||= entries.compact_map { |command| command.name if command.type == "skill" }.to_set
      end
    end

    private record Change, session_id : String, snapshot : Snapshot, mode : String?, revision : UInt64 = 0_u64, write : UInt64 = 0_u64
    private record Attachment, session_id : String, loading : Bool, replaying : Bool, expired : Bool = false, written : Bool = false

    EMPTY_COMMANDS = Raw.from_json("[]")

    @sessions = {} of String => Snapshot
    @commands = {} of String => Commands
    @attachments = {} of String => Attachment
    @attaching = {} of String => String
    @changes = {} of String => Change
    @late_changes = {} of String => Change

    # Retain a bounded number of response observers after their callers time out.
    LATE_CHANGE_LIMIT = 128

    def initialize(@v2 : Bool)
    end

    def [](session_id : String) : Snapshot?
      @sessions[session_id]?
    end

    def replace(session_id : String, result : String, *, reattach : Bool) : Nil
      modes = field(result, "modes") unless @v2
      modes = nil unless modes.try(&.object?)
      options = array_field(result, "configOptions", unique: @v2)
      if @v2
        @commands[session_id] = Commands.new(array_field(result, "availableCommands", unique: true) || EMPTY_COMMANDS)
      end
      if reattach && (snapshot = @sessions[session_id]?)
        snapshot.replace(modes, options)
      else
        @sessions[session_id] = Snapshot.new(@v2, modes, options)
      end
    end

    def seed(session_id : String, modes : Protocol::SessionModeState?, options : Array(Protocol::ConfigOption)?) : Nil
      @sessions[session_id] ||= Snapshot.new(false, modes.try { |m| Raw.from_json(Protocol::WireFrame.encode(m)) },
        options.try { |items| Raw.from_json(Protocol::WireFrame.encode(items)) })
    end

    def start_attachment(request_id : String, method : String, params : Hash(String, JSON::Any)?) : Nil
      return unless method.in?(Protocol::AgentMethod::SESSION_LOAD, Protocol::AgentMethod::SESSION_RESUME)
      return unless sid = params.try(&.["sessionId"]?).try(&.as_s?)

      if @attaching.has_key?(sid)
        raise InvalidStateError.new("A session setup is already pending for #{sid.inspect}")
      end
      loading = method == Protocol::AgentMethod::SESSION_LOAD
      replay = params.try(&.["replayFrom"]?)
      replaying = loading || (@v2 && !!replay && !replay.raw.nil?)
      @attaching[sid] = request_id
      @attachments[request_id] = Attachment.new(sid, loading, replaying)
    end

    def loading?(session_id : String) : Bool
      !!@attaching[session_id]?.try { |id| @attachments[id]?.try { |attach| attach.written && attach.loading } }
    end

    def attachment_written(request_id : String) : Nil
      if attach = @attachments[request_id]?
        @attachments[request_id] = attach.copy_with(written: true)
      end
    end

    def replay_complete(session_id : String) : Nil
      if @v2 && (request_id = @attaching[session_id]?) && (attachment = @attachments[request_id]?) && attachment.written
        if attachment.expired
          finish_attachment(request_id)
        else
          @attachments[request_id] = attachment.copy_with(replaying: false)
        end
      end
    end

    def finish_attachment(request_id : String) : Nil
      if attach = @attachments.delete(request_id)
        @attaching.delete(attach.session_id)
      end
    end

    def expire_attachment(request_id : String) : Nil
      # Disregard late snapshots until the Agent answers this attachment. A
      # timeout leaves the previously advertised session choices uncertain.
      if attach = @attachments[request_id]?
        drop(attach.session_id)
        if attach.replaying
          @attachments[request_id] = attach.copy_with(expired: true)
        else
          finish_attachment(request_id)
        end
      end
    end

    def change_method?(method : String) : Bool
      method == Protocol::AgentMethod::SESSION_SET_CONFIG_OPTION ||
        (!@v2 && method == Protocol::AgentMethod::SESSION_SET_MODE)
    end

    def start_change(request_id : String, method : String, params : Hash(String, JSON::Any)?,
                     *, validate : Bool, allow_boolean : Bool) : Nil
      return unless params && (session_id = params["sessionId"]?.try(&.as_s?))

      snapshot = validate ? for_change(session_id) : @sessions[session_id]?
      return unless snapshot

      if method == Protocol::AgentMethod::SESSION_SET_MODE
        return unless mode = params["modeId"]?.try(&.as_s?)

        snapshot.validate_mode(mode) if validate
        revision, write = snapshot.propose_mode
        @changes[request_id] = Change.new(session_id, snapshot, mode, revision, write)
      else
        if validate
          config_id = params["configId"].as_s
          value = params["value"]
          value_type = params["type"]?.try(&.as_s?) || "id"
          if value_type == "boolean" && !allow_boolean
            raise InvalidStateError.new("The Client did not advertise boolean configuration options")
          end
          snapshot.validate_option(config_id, value_type, value)
        end
        @changes[request_id] = Change.new(session_id, snapshot, nil)
      end
    end

    def change_pending?(request_id : String) : Bool
      @changes.has_key?(request_id) || @late_changes.has_key?(request_id)
    end

    def finish_change(request_id : String, result : String? = nil) : Nil
      change = @changes.delete(request_id) || @late_changes.delete(request_id)
      return unless result && change && @sessions[change.session_id]?.same?(change.snapshot)

      if mode = change.mode
        Protocol::SessionSetModeResult.from_json(result)
        change.snapshot.confirm_mode(mode, change.revision, change.write)
      elsif options = array_field(result, "configOptions", unique: @v2)
        change.snapshot.options = options
      end
    rescue JSON::Error
      # The caller reports malformed results. Preserve the last usable state.
    end

    def expire_change(request_id : String) : Nil
      if change = @changes.delete(request_id)
        @late_changes[request_id] = change
        if @late_changes.size > LATE_CHANGE_LIMIT
          _, evicted = @late_changes.shift
          if @sessions[evicted.session_id]?.same?(evicted.snapshot)
            @sessions.delete(evicted.session_id)
          end
        end
      end
    end

    private def for_change(session_id : String) : Snapshot
      if @attaching.has_key?(session_id)
        raise InvalidStateError.new("Session choices are unavailable during session setup")
      end

      @sessions[session_id]? || raise InvalidStateError.new("The Agent has not reported choices for this session")
    end

    def observe_mode(session_id : String, mode_id : String) : Nil
      @sessions[session_id]?.try(&.observe_mode(mode_id)) unless replaying?(session_id)
    end

    def observe_options(session_id : String, update : String) : Nil
      if (state = @sessions[session_id]?) && !replaying?(session_id) && (options = array_field(update, "configOptions", unique: @v2))
        state.options = options
      end
    end

    def observe_commands(session_id : String, update : String) : Nil
      if (state = @commands[session_id]?) && !replaying?(session_id) && (commands = array_field(update, "availableCommands", unique: true))
        state.replace(commands)
      end
    end

    def commands_raw(session_id : String) : Raw?
      current_commands(session_id).try(&.raw)
    end

    def commands(session_id : String) : Array(Protocol::V2::AvailableCommand)?
      current_commands(session_id).try(&.entries)
    end

    def command_skill_names(session_id : String) : Set(String)?
      current_commands(session_id).try(&.skill_names) unless @attaching.has_key?(session_id)
    end

    def retirement_timed_out(session_id : String) : Nil
      @commands[session_id]?.try(&.retirement_timed_out)
    end

    def retirement_failed(session_id : String) : Nil
      @commands[session_id]?.try(&.retirement_failed)
    end

    private def current_commands(session_id : String) : Commands?
      state = @commands[session_id]?
      state if state.try(&.current?)
    end

    def drop(session_id : String) : Nil
      @sessions.delete(session_id)
      @commands.delete(session_id)
    end

    def clear : Nil
      @sessions.clear
      @commands.clear
      @attachments.clear
      @attaching.clear
      @changes.clear
      @late_changes.clear
    end

    private def replaying?(session_id : String) : Bool
      !!@attaching[session_id]?.try do |id|
        @attachments[id]?.try { |attach| attach.written && attach.replaying }
      end
    end

    private def array_field(wire : String, name : String, *, unique : Bool = false) : Raw?
      value = field(wire, name, unique: unique)
      value if value.try(&.array?)
    end

    private def field(wire : String, name : String, *, unique : Bool = false) : Raw?
      if raw = Protocol::WireFrame.field(wire, name, unique: unique)
        Raw.new(JSON::PullParser.new(raw))
      end
    rescue JSON::Error
      nil
    end
  end
end
