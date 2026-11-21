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
        entries = @options.try(&.elements?) || return [] of Protocol::V2::ConfigOption
        entries.compact_map do |wire|
          option = Protocol::V2::ConfigOption.from_json(wire.json)
          case option.type
          when "select"  then option if option.selected_value && option.select_options
          when "boolean" then option unless option.boolean_value.nil?
          else                option
          end
        rescue JSON::Error
          nil
        end
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
        unless option.field("name").try(&.as_s?)
          raise InvalidStateError.new("The Agent did not offer a usable session configuration option")
        end

        raw_type = option.field("type")
        type = raw_type.try(&.as_s?)
        type ||= "select" unless @v2 || raw_type
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
          # V2 can carry extension-defined option and value discriminators.
          unless @v2 && type && !type.empty?
            raise InvalidStateError.new("Unsupported session configuration option type")
          end
        end
      end

      private def selectable?(option : Raw, value : String) : Bool
        if @v2
          case choices = Protocol::V2::ConfigOption.from_json(option.json).select_options
          when Array(Protocol::ConfigOptionValue)
            choices.any? { |item| item.value == value }
          when Array(Protocol::V2::ConfigOptionGroup)
            choices.any? { |group| group.values.any? { |item| item.value == value } }
          else
            false
          end
        else
          Protocol::ConfigOption.from_json(option.json).all_values.any? { |item| item.value == value }
        end
      rescue JSON::Error
        false
      end
    end

    private record Change, session_id : String, snapshot : Snapshot, mode : String?, revision : UInt64 = 0_u64, write : UInt64 = 0_u64
    private record Attachment, session_id : String, loading : Bool, replaying : Bool, expired : Bool = false

    @sessions = {} of String => Snapshot
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
      options = option_list(result)
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
      !!@attaching[session_id]?.try { |id| @attachments[id]?.try(&.loading) }
    end

    def replay_complete(session_id : String) : Nil
      if @v2 && (request_id = @attaching[session_id]?) && (attachment = @attachments[request_id]?)
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
      # timeout leaves the previously selected configuration uncertain.
      if attach = @attachments[request_id]?
        @sessions.delete(attach.session_id)
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
      elsif options = option_list(result)
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
      if (state = @sessions[session_id]?) && !replaying?(session_id) && (options = option_list(update))
        state.options = options
      end
    end

    def drop(session_id : String) : Bool
      !@sessions.delete(session_id).nil?
    end

    def clear : Nil
      @sessions.clear
      @attachments.clear
      @attaching.clear
      @changes.clear
      @late_changes.clear
    end

    private def replaying?(session_id : String) : Bool
      !!@attaching[session_id]?.try { |id| @attachments[id]?.try(&.replaying) }
    end

    private def option_list(wire : String) : Raw?
      value = field(wire, "configOptions")
      value if value.try(&.array?)
    end

    private def field(wire : String, name : String) : Raw?
      if raw = Protocol::WireFrame.field(wire, name)
        Raw.new(JSON::PullParser.new(raw))
      end
    rescue JSON::Error
      nil
    end
  end
end
