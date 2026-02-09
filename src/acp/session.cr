# ACP Session — Convenience Wrapper
#
# The `Session` class provides a higher-level, session-scoped interface
# on top of `ACP::Client`. Instead of passing session IDs to every call,
# you create a `Session` object and interact with it directly.
#
# A session represents a single conversation with the agent, from
# creation (or load) through multiple prompt/response cycles, to
# eventual close or disconnect.
#
# Usage:
#   ```
# client = ACP::Client.new(transport)
# client.initialize_connection
# session = ACP::Session.create(client, cwd: "/my/project")
# result = session.prompt("Explain this codebase")
# session.cancel # if needed
#   ```

require "./client"
require "./protocol/types"

module ACP
  class Session
    # The underlying client this session communicates through.
    getter client : Client

    # The unique session ID assigned by the agent.
    getter id : String

    # Mode state for this session (may be nil if agent doesn't support modes).
    getter modes : Protocol::SessionModeState?

    # Config options exposed by the agent for this session.
    getter config_options : Array(Protocol::ConfigOption)?

    # Whether this session has been explicitly cancelled or closed.
    getter? closed : Bool = false

    # ─── Factory Methods ──────────────────────────────────────────────

    # Creates a new session via `session/new`.
    #
    # - `client` — an initialized ACP::Client.
    # - `cwd` — the absolute path to the working directory.
    # - `mcp_servers` — optional MCP server references (as JSON::Any).
    #
    # The client must be in the Initialized (or SessionActive) state.
    # Returns a new `Session` instance bound to the created session.
    def self.create(
      client : Client,
      cwd : String,
      mcp_servers : Array(JSON::Any)? = nil,
    ) : Session
      result = client.session_new(cwd, mcp_servers || [] of JSON::Any)
      new(client, result.session_id, result.modes, result.config_options)
    end

    # Loads (resumes) a previous session via `session/load`.
    #
    # - `client` — an initialized ACP::Client.
    # - `session_id` — the ID of the session to resume.
    # - `cwd` — the absolute path to the working directory.
    # - `mcp_servers` — optional MCP server references (as JSON::Any).
    #
    # Returns a `Session` instance bound to the loaded session.
    def self.load(
      client : Client,
      session_id : String,
      cwd : String,
      mcp_servers : Array(JSON::Any)? = nil,
    ) : Session
      result = client.session_load(session_id, cwd, mcp_servers || [] of JSON::Any)
      new(client, session_id, result.modes, result.config_options)
    end

    # ─── Constructor ──────────────────────────────────────────────────

    # Direct constructor. Prefer `Session.create` or `Session.load`.
    def initialize(
      @client : Client,
      @id : String,
      @modes : Protocol::SessionModeState? = nil,
      @config_options : Array(Protocol::ConfigOption)? = nil,
    )
    end

    # ─── Prompt Methods ───────────────────────────────────────────────

    # Sends a prompt with an array of content blocks and waits for
    # the agent's response. Session update notifications will be
    # dispatched through the client's `on_update` callback while
    # the prompt is being processed.
    #
    # Returns the prompt result containing the stop reason.
    #
    # Raises `ACP::Error` if the session is closed.
    def prompt(content_blocks : Array(Protocol::ContentBlock)) : Protocol::SessionPromptResult
      ensure_open!
      @client.session_prompt(content_blocks, @id)
    end

    # Convenience: sends a simple text prompt.
    #
    # - `text` — the text to send as a single TextContentBlock.
    #
    # Returns the prompt result containing the stop reason.
    def prompt(text : String) : Protocol::SessionPromptResult
      ensure_open!
      @client.session_prompt_text(text, @id)
    end

    # Sends a prompt with multiple text strings, each as a separate
    # TextContentBlock.
    def prompt(*texts : String) : Protocol::SessionPromptResult
      blocks = texts.map { |text_item| Protocol::TextContentBlock.new(text_item.as(String)).as(Protocol::ContentBlock) }
      prompt(blocks.to_a)
    end

    # Sends a prompt built from a block. The block receives a
    # `PromptBuilder` for ergonomic content block construction.
    #
    # Example:
    #   ```
    # session.prompt do |b|
    #   b.text "Explain this file:"
    #   b.file "/path/to/file.cr"
    # end
    #   ```
    def prompt(& : PromptBuilder ->) : Protocol::SessionPromptResult
      builder = PromptBuilder.new
      yield builder
      prompt(builder.build)
    end

    # ─── Cancel ───────────────────────────────────────────────────────

    # Sends a `session/cancel` notification to abort the current
    # operation in this session. This is fire-and-forget.
    def cancel : Nil
      return if @closed
      @client.session_cancel(@id)
    end

    # ─── Mode ─────────────────────────────────────────────────────────

    # Switches the session to the specified mode.
    #
    # - `mode_id` — the ID of the mode to activate.
    def mode=(mode_id : String) : Nil
      ensure_open!
      @client.session_set_mode(mode_id, @id)
    end

    # :ditto:
    # @deprecated Use `#mode=` instead.
    # ameba:disable Naming/AccessorMethodName
    def set_mode(mode_id : String) : Nil
      self.mode = mode_id
    end

    # Returns the list of available mode IDs, or an empty array if
    # the agent doesn't support modes.
    def available_mode_ids : Array(String)
      @modes.try(&.available_modes.map(&.id)) || [] of String
    end

    # ─── Config Options ───────────────────────────────────────────────

    # Changes a session configuration option.
    #
    # - `config_id` — the ID of the config option to change.
    # - `value` — the new value to set.
    #
    # Returns the full set of config options and their current values.
    # See: https://agentclientprotocol.com/protocol/session-config-options
    def set_config_option(config_id : String, value : String) : Protocol::SessionSetConfigOptionResult
      ensure_open!
      result = @client.session_set_config_option(config_id, value, @id)
      @config_options = result.config_options
      result
    end

    # ─── State ────────────────────────────────────────────────────────

    # Marks this session as closed. Further prompt/cancel calls will
    # raise an error. Note: there is no explicit "session/close" method
    # in ACP; this is a client-side state flag.
    def close : Nil
      @closed = true
    end

    # Returns a human-readable summary of the session for debugging.
    def to_s(io : IO) : Nil
      io << "ACP::Session(id=#{@id}"
      io << ", closed" if @closed
      if m = @modes
        io << ", modes=[#{m.available_modes.map(&.id).join(", ")}]"
      end
      io << ")"
    end

    # Same as `to_s` but for `inspect`.
    def inspect(io : IO) : Nil
      to_s(io)
    end

    # ─── Private ──────────────────────────────────────────────────────

    private def ensure_open! : Nil
      raise InvalidStateError.new("Session #{@id} is closed") if @closed
      raise ConnectionClosedError.new if @client.closed?
    end
  end

  # ─── Prompt Builder ─────────────────────────────────────────────────

  # A small DSL helper for constructing arrays of content blocks in
  # a readable way. Used by `Session#prompt(&block)`.
  class PromptBuilder
    @blocks : Array(Protocol::ContentBlock) = [] of Protocol::ContentBlock

    # Adds a text content block.
    def text(content : String) : self
      @blocks << Protocol::TextContentBlock.new(content)
      self
    end

    # Adds an image content block from base64 data.
    def image(data : String, mime_type : String = "image/png") : self
      @blocks << Protocol::ImageContentBlock.new(data: data, mime_type: mime_type)
      self
    end

    # Adds an image content block from base64 data (alias).
    def image_data(data : String, mime_type : String = "image/png") : self
      image(data, mime_type)
    end

    # Adds an audio content block from base64 data.
    def audio(data : String, mime_type : String = "audio/wav") : self
      @blocks << Protocol::AudioContentBlock.new(data: data, mime_type: mime_type)
      self
    end

    # Adds an audio content block from base64 data (alias).
    def audio_data(data : String, mime_type : String = "audio/wav") : self
      audio(data, mime_type)
    end

    # Adds a resource link content block from a file path.
    def file(path : String, mime_type : String? = nil) : self
      @blocks << Protocol::ResourceLinkContentBlock.from_path(path, mime_type)
      self
    end

    # Adds an embedded resource content block with text content.
    def resource(uri : String, text : String, mime_type : String? = nil) : self
      @blocks << Protocol::ResourceContentBlock.text(uri: uri, text: text, mime_type: mime_type)
      self
    end

    # Adds a resource link content block.
    def resource_link(uri : String, name : String, mime_type : String? = nil) : self
      @blocks << Protocol::ResourceLinkContentBlock.new(uri: uri, name: name, mime_type: mime_type)
      self
    end

    # Returns the assembled array of content blocks.
    def build : Array(Protocol::ContentBlock)
      @blocks
    end

    # Returns the number of blocks added so far.
    def size : Int32
      @blocks.size
    end

    # Returns true if no blocks have been added.
    def empty? : Bool
      @blocks.empty?
    end
  end
end
