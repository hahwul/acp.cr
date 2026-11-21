require "set"
require "./errors"
require "./protocol/cursor_update"
require "./protocol/v2/sessions"

module ACP
  # The reported position and current capabilities of an Agent-owned cursor.
  struct SessionCursor
    # ID of the transcript containing this cursor.
    getter session_id : String

    # Opaque ID scoped to the session.
    getter cursor_id : String

    # First reported anchor. It can be absent if the first announcement was missed.
    getter anchor : Protocol::CursorAnchor?

    # Methods that currently accept the cursor.
    getter capabilities : Protocol::CursorCapabilities?

    # Extension metadata representable as JSON::Any, after applying patches.
    def meta : Hash(String, JSON::Any)?
      @metadata.try(&.to_h)
    end

    # Exact JSON for a reported metadata entry.
    def raw_meta_field(key : String) : String?
      @metadata.try(&.raw_field(key))
    end

    # Creates a snapshot of an announced cursor.
    def initialize(
      @session_id : String,
      @cursor_id : String,
      @anchor : Protocol::CursorAnchor? = nil,
      @capabilities : Protocol::CursorCapabilities? = nil,
      meta : Hash(String, JSON::Any)? = nil,
    )
      @metadata = meta.try { |fields| Protocol::CursorMetadata.new(fields) }
    end

    # :nodoc:
    def initialize(
      @session_id : String,
      @cursor_id : String,
      @anchor : Protocol::CursorAnchor?,
      @capabilities : Protocol::CursorCapabilities?,
      *,
      @metadata : Protocol::CursorMetadata?,
    )
    end

    # :nodoc:
    getter metadata : Protocol::CursorMetadata?

    # Whether the Agent has advertised a fork at this cursor.
    def fork? : Bool
      !@capabilities.try(&.fork).nil?
    end

    # :nodoc:
    def snapshot : SessionCursor
      SessionCursor.new(
        @session_id,
        @cursor_id,
        @anchor.try { |item| Protocol::CursorAnchor.from_json(Protocol::WireFrame.encode(item)) },
        @capabilities.try { |item| Protocol::CursorCapabilities.from_json(Protocol::WireFrame.encode(item)) },
        metadata: @metadata,
      )
    end
  end

  # Tracks patches and stages replacements during a full replay.
  private class CursorRegistry
    private alias Cursors = Hash(String, SessionCursor)

    private class Replay
      getter? full : Bool
      getter staged = {} of String => Cursors
      getter sessions = Set(String).new

      def initialize(@full : Bool)
      end
    end

    @sessions = {} of String => Cursors
    @replay_requests = {} of String => Replay
    @replaying = {} of String => Replay

    def initialize(@v2 : Bool)
    end

    def cursor(session_id : String, cursor_id : String) : SessionCursor?
      @sessions[session_id]?.try(&.[cursor_id]?).try(&.snapshot)
    end

    def cursors(session_id : String) : Array(SessionCursor)
      @sessions[session_id]?.try(&.values.map(&.snapshot)) || [] of SessionCursor
    end

    def observe(session_id : String, update : Protocol::CursorUpdate) : Nil
      replay = @replaying[session_id]?
      staged = replay.try(&.staged[session_id]?)
      records = staged || (@sessions[session_id] ||= Cursors.new)
      previous = records[update.cursor_id]?
      patch = Protocol::CursorUpdate.from_json(Protocol::WireFrame.encode(update))
      old = @sessions[session_id]?.try(&.[patch.cursor_id]?) if staged
      anchor = previous.try(&.anchor)
      if staged && replay.try(&.full?) && anchor && anchor == old.try(&.anchor)
        # A live update can arrive before replay starts. Let replay remap
        # the former anchor once, then keep the new anchor fixed.
        anchor = patch.anchor || anchor
      end
      capabilities = patch.capabilities_present? ? patch.capabilities : previous.try(&.capabilities)
      metadata = previous.try(&.metadata)
      if @v2 && staged && previous.nil?
        metadata = old.try(&.metadata)
      end
      if patch.meta_present?
        metadata = @v2 ? patch.metadata.try(&.apply_to(metadata)) : patch.metadata
      end
      records[patch.cursor_id] = SessionCursor.new(session_id, patch.cursor_id, anchor || patch.anchor, capabilities, metadata: metadata)
    end

    def start_replay(request_id : String, session_id : String, *, full : Bool) : Nil
      if @replaying.has_key?(session_id)
        raise InvalidStateError.new("A session replay is already pending for #{session_id.inspect}")
      end

      replay = Replay.new(full)
      @replay_requests[request_id] = replay
      stage(replay, session_id)
    end

    def include_child(parent_id : String, child_id : String) : Nil
      if (replay = @replaying[parent_id]?) && !@replaying.has_key?(child_id)
        stage(replay, child_id)
      end
    end

    def replay_complete(session_id : String) : Nil
      if records = @replaying[session_id]?.try(&.staged.delete(session_id))
        @sessions[session_id] = records
      end
    end

    def finish_replay(request_id : String, response : JSON::Any? = nil) : Nil
      return unless replay = @replay_requests.delete(request_id)

      complete = replay_succeeded?(response)
      replay.sessions.each do |session_id|
        @replaying.delete(session_id)
      end
      if complete
        replay.staged.each { |session_id, records| @sessions[session_id] = records }
      end
    end

    def clear : Nil
      @sessions.clear
      @replay_requests.clear
      @replaying.clear
    end

    private def stage(replay : Replay, session_id : String) : Nil
      replay.staged[session_id] = if replay.full?
                                    Cursors.new
                                  else
                                    @sessions[session_id]?.try(&.dup) || Cursors.new
                                  end
      replay.sessions.add(session_id)
      @replaying[session_id] = replay
    end

    private def replay_succeeded?(response : JSON::Any?) : Bool
      return false unless response && !response["error"]? && (result = response["result"]?)

      if @v2
        Protocol::V2::SessionResumeResult.from_json(result.to_json)
      else
        Protocol::SessionLoadResult.from_json(result.to_json)
      end
      true
    rescue JSON::Error
      false
    end
  end
end
