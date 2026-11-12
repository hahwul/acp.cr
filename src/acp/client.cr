# ACP Client — Main Client Class
#
# The `Client` class is the primary interface for communicating with an
# ACP-compatible coding agent. It manages:
#
#   - Transport lifecycle (connection, disconnection)
#   - JSON-RPC 2.0 request/response correlation via pending request channels
#   - Background message dispatch (reader loop in a fiber)
#   - All ACP protocol methods: initialize, authenticate, session/new,
#     session/prompt, session/cancel, etc.
#   - Handling of agent-initiated methods (e.g., session/request_permission)
#   - Event callbacks for notifications (session/update)
#
# Concurrency model:
#   The client spawns a dispatcher fiber that reads from the transport
#   and routes messages to the appropriate handler:
#     - Responses go to pending request channels (keyed by request ID)
#     - Notifications go to registered callback blocks
#     - Agent-initiated requests go to registered method handlers, each
#       run in its own fiber so a blocking handler can't stall the reader
#
# Usage:
#   ```
# transport = ACP::ProcessTransport.new("my-agent")
# client = ACP::Client.new(transport)
# client.initialize_connection
# session = client.session_new("/path/to/project")
# client.session_prompt(session.session_id, "Hello, agent!")
#   ```

require "json"
require "log"
require "./protocol/types"
require "./protocol/client_methods"
require "./transport"
require "./errors"

module ACP
  # Logger for client-level diagnostics.
  ClientLog = ::Log.for("acp.client")

  # Alias for the callback type used to handle session updates.
  alias UpdateHandler = Protocol::SessionUpdateParams -> Nil

  # Alias for the callback type used to handle agent-initiated requests
  # like `session/request_permission`. The handler receives the raw
  # params as JSON::Any and must return a JSON::Any result.
  alias AgentRequestHandler = (String, JSON::Any) -> JSON::Any

  # Alias for a generic notification callback. Receives the method
  # name and raw params.
  alias NotificationHandler = (String, JSON::Any?) -> Nil

  # ─── Typed Client Method Handlers ─────────────────────────────────
  # These aliases provide strongly-typed handlers for agent-initiated
  # client methods (fs/*, terminal/*), as defined in the ACP spec.
  # See: https://agentclientprotocol.com/protocol/file-system
  # See: https://agentclientprotocol.com/protocol/terminals

  # Handler for `fs/read_text_file` requests from the agent.
  alias ReadTextFileHandler = Protocol::ReadTextFileParams -> Protocol::ReadTextFileResult

  # Handler for `fs/write_text_file` requests from the agent.
  alias WriteTextFileHandler = Protocol::WriteTextFileParams -> Protocol::WriteTextFileResult

  # Handler for `terminal/create` requests from the agent.
  alias CreateTerminalHandler = Protocol::CreateTerminalParams -> Protocol::CreateTerminalResult

  # Handler for `terminal/output` requests from the agent.
  alias TerminalOutputHandler = Protocol::TerminalOutputParams -> Protocol::TerminalOutputResult

  # Handler for `terminal/release` requests from the agent.
  alias ReleaseTerminalHandler = Protocol::ReleaseTerminalParams -> Protocol::ReleaseTerminalResult

  # Handler for `terminal/wait_for_exit` requests from the agent.
  alias WaitForTerminalExitHandler = Protocol::WaitForTerminalExitParams -> Protocol::WaitForTerminalExitResult

  # Handler for `terminal/kill` requests from the agent.
  alias KillTerminalHandler = Protocol::KillTerminalParams -> Protocol::KillTerminalResult

  # Handler for `elicitation/create` requests from the agent.
  alias CreateElicitationHandler = Protocol::CreateElicitationParams -> Protocol::CreateElicitationResult

  # Handler for `elicitation/complete` notifications from the agent.
  alias ElicitationCompleteHandler = Protocol::CompleteElicitationParams -> Nil

  # The state of the client through its lifecycle.
  enum ClientState
    # Client has been created but not yet initialized.
    Created

    # The `initialize` handshake has been completed successfully.
    Initialized

    # A session is active (session/new or session/load succeeded).
    SessionActive

    # The client is shutting down or has been closed.
    Closed
  end

  class Client
    # The current client state.
    getter state : ClientState = ClientState::Created

    # The transport used for communication with the agent.
    getter transport : Transport

    # Agent capabilities received during initialization.
    getter agent_capabilities : Protocol::AgentCapabilities?

    # Agent info received during initialization.
    getter agent_info : Protocol::AgentInfo?

    # Authentication methods the agent supports.
    getter auth_methods : Array(JSON::Any)?

    # The protocol version negotiated with the agent.
    getter negotiated_protocol_version : UInt16?

    # The active session ID, if any.
    getter session_id : String?

    # Mode state for the current session.
    getter session_modes : Protocol::SessionModeState?

    # Config options available for the current session.
    getter session_config_options : Array(Protocol::ConfigOption)?

    # ─── Configuration ──────────────────────────────────────────────

    # Client capabilities to advertise during initialization.
    property client_capabilities : Protocol::ClientCapabilities

    # Client info to send during initialization.
    property client_info : Protocol::ClientInfo

    # Default timeout for requests (in seconds). Nil means no timeout.
    property request_timeout : Float64? = 30.0

    # Timeout for session/prompt requests (in seconds). Prompts can take
    # significantly longer than other requests, so this defaults to 5 minutes.
    # Set to nil to wait indefinitely.
    property prompt_timeout : Float64? = 300.0

    # ─── Callbacks ──────────────────────────────────────────────────

    # Callback invoked for every `session/update` notification.
    # Set this to handle streaming agent responses, tool calls, etc.
    property on_update : UpdateHandler?

    # Callback invoked for agent-initiated method calls that the client
    # must respond to (e.g., `session/request_permission`). The handler
    # receives the method name and raw params, and must return the
    # result as JSON::Any. If not set, agent requests receive an error.
    property on_agent_request : AgentRequestHandler?

    # Callback invoked for any notification that is NOT `session/update`.
    # Useful for handling custom or future notification types.
    property on_notification : NotificationHandler?

    # Callback invoked when the transport connection is lost.
    property on_disconnect : (-> Nil)?

    # ─── Typed Client Method Handlers ───────────────────────────────
    # These handlers are invoked when the agent calls the corresponding
    # client method. Register them to provide file system and terminal
    # access to the agent. If a handler is not set but the corresponding
    # capability was advertised, the agent request will fall through to
    # `on_agent_request` or receive a "method not found" error.
    #
    # See: https://agentclientprotocol.com/protocol/file-system
    # See: https://agentclientprotocol.com/protocol/terminals

    # Handler for `fs/read_text_file` — read file contents from the editor.
    # Set this when advertising `fs.readTextFile` capability.
    property on_read_text_file : ReadTextFileHandler?

    # Handler for `fs/write_text_file` — write file contents.
    # Set this when advertising `fs.writeTextFile` capability.
    property on_write_text_file : WriteTextFileHandler?

    # Handler for `terminal/create` — create a new terminal and execute a command.
    # Set this when advertising the `terminal` capability.
    property on_create_terminal : CreateTerminalHandler?

    # Handler for `terminal/output` — get terminal output and exit status.
    # Set this when advertising the `terminal` capability.
    property on_terminal_output : TerminalOutputHandler?

    # Handler for `terminal/release` — release a terminal.
    # Set this when advertising the `terminal` capability.
    property on_release_terminal : ReleaseTerminalHandler?

    # Handler for `terminal/wait_for_exit` — wait for terminal command to exit.
    # Set this when advertising the `terminal` capability.
    property on_wait_for_terminal_exit : WaitForTerminalExitHandler?

    # Handler for `terminal/kill` — kill terminal command without releasing.
    # Set this when advertising the `terminal` capability.
    property on_kill_terminal : KillTerminalHandler?

    # Handler for `elicitation/create` — ask the user for input.
    # Set this when advertising `elicitation` capabilities. A request for a
    # mode not advertised there is answered with -32602 without reaching it.
    # See: https://agentclientprotocol.com/protocol/v1/elicitation
    property on_create_elicitation : CreateElicitationHandler?

    # Handler for the `elicitation/complete` notification (URL mode). If
    # unset, the notification goes to `on_notification`.
    property on_elicitation_complete : ElicitationCompleteHandler?

    # ─── Internal State ─────────────────────────────────────────────

    # Monotonically increasing request ID counter.
    @next_id : Int64 = 1_i64

    # Map of pending request IDs to their response channels.
    # When we send a request, we create a channel and store it here.
    # The dispatcher fiber sends the response into the channel when
    # it arrives, unblocking the caller.
    @pending : Hash(String, Channel(JSON::Any)) = Hash(String, Channel(JSON::Any)).new

    # Mutex for thread-safe access to @pending (though Crystal fibers
    # are cooperative, this protects against unexpected scheduling).
    @pending_mutex : Mutex = Mutex.new

    # Why `drain_pending_requests` last ran; the message of the
    # `ConnectionClosedError` the requests it cut off raise.
    @disconnect_reason : String = "Connection closed"

    # An agent request whose handler hasn't answered yet. Compared by
    # identity, so a duplicate ID can't claim another request's answer.
    private class InFlightRequest
      getter method : String
      getter session_id : String?

      def initialize(@method : String, @session_id : String?)
      end
    end

    # Agent requests (with a non-null ID) whose handler hasn't answered yet.
    # `session_cancel` and an incoming `$/cancel_request` answer some of
    # them early by removing them; the handler's late answer is then
    # dropped. Guarded by `@pending_mutex`.
    @in_flight : Hash(Protocol::RequestId, InFlightRequest) = Hash(Protocol::RequestId, InFlightRequest).new

    # Agent methods an incoming `$/cancel_request` answers right away,
    # because they only read or wait: answering early can't hide a side
    # effect the handler still performs. Others are left to their handler.
    CANCEL_ANSWERED_EARLY = {
      Protocol::ClientMethod::SESSION_REQUEST_PERMISSION,
      Protocol::ClientMethod::ELICITATION_CREATE,
      Protocol::ClientMethod::FS_READ_TEXT_FILE,
      Protocol::ClientMethod::TERMINAL_OUTPUT,
      Protocol::ClientMethod::TERMINAL_WAIT_FOR_EXIT,
    }

    # Whether the dispatcher fiber is running.
    @dispatcher_running : Bool = false

    # Tracks consecutive dispatch errors for detecting protocol corruption.
    # Atomic because agent-request fibers record their outcome too.
    @consecutive_dispatch_errors : Atomic(Int32) = Atomic(Int32).new(0)

    # When this many messages in a row fail to dispatch, the stream is assumed
    # to be corrupt (e.g. desynchronized framing) and the client tears down the
    # connection rather than spinning forever on un-dispatchable input. The
    # counter resets to zero after any successful dispatch. An agent request
    # counts once its handler fiber has (or has failed to) send the answer.
    MAX_CONSECUTIVE_DISPATCH_ERRORS = 10

    # Set when the caller invokes `close` explicitly. Used so the dispatcher
    # does NOT fire the `on_disconnect` ("connection lost") callback on an
    # intentional shutdown — that callback is reserved for unexpected loss
    # of the transport (EOF, transport error, or protocol corruption).
    @user_closed : Bool = false

    # ─── Constructor ────────────────────────────────────────────────

    # Creates a new ACP client connected to the given transport.
    #
    # - `transport` — the transport to use for communication.
    # - `client_name` — human-readable name of the client application.
    # - `client_version` — version string of the client.
    # - `capabilities` — client capabilities to advertise. Default: minimal.
    def initialize(
      @transport : Transport,
      client_name : String = "acp-crystal",
      client_version : String = ACP::VERSION,
      @client_capabilities : Protocol::ClientCapabilities = Protocol::ClientCapabilities.new,
    )
      @client_info = Protocol::ClientInfo.new(client_name, client_version)
      start_dispatcher
    end

    # ─── Lifecycle ──────────────────────────────────────────────────

    # Performs the ACP `initialize` handshake with the agent.
    #
    # Sends the client's protocol version, capabilities, and info.
    # Receives the agent's protocol version, capabilities, auth methods,
    # and info. Validates protocol version compatibility.
    #
    # Raises `VersionMismatchError` if the agent's protocol version
    # is incompatible. Raises `JsonRpcError` if the agent returns an error.
    def initialize_connection : Protocol::InitializeResult
      ensure_state(ClientState::Created, "initialize")

      params = Protocol::InitializeParams.new(
        protocol_version: ACP::PROTOCOL_VERSION,
        client_capabilities: @client_capabilities,
        client_info: @client_info
      )

      raw_result = send_request(Protocol::AgentMethod::INITIALIZE, params)
      result = decode_result(Protocol::InitializeResult, raw_result, Protocol::AgentMethod::INITIALIZE)

      # The handshake is a negotiation: the agent returns the version it will
      # use, which may be lower than we requested. Accept any version we still
      # support; only bail when the agent picks a version outside our range
      # (e.g. a newer version we can't speak).
      unless ACP.supports_protocol_version?(result.protocol_version)
        ClientLog.error do
          "Unsupported negotiated protocol version: client supports " \
          "#{ACP::MIN_PROTOCOL_VERSION}..#{ACP::PROTOCOL_VERSION}, " \
          "agent=#{result.protocol_version}"
        end
        close
        raise VersionMismatchError.new(ACP::PROTOCOL_VERSION, result.protocol_version)
      end

      # Store negotiated state, using the version the agent selected.
      @negotiated_protocol_version = result.protocol_version
      @agent_capabilities = result.agent_capabilities
      @agent_info = result.agent_info
      @auth_methods = result.auth_methods
      @state = ClientState::Initialized

      ClientLog.info do
        agent_name = result.agent_info.try(&.name) || "unknown"
        agent_ver = result.agent_info.try(&.version) || "?"
        "Initialized with agent: #{agent_name} v#{agent_ver}"
      end

      result
    end

    # Authenticates with the agent using the specified method ID.
    #
    # This should be called after `initialize_connection` if the agent
    # reported `authMethods` in its initialize response.
    #
    # Raises `InvalidStateError` if not in the Initialized state.
    # Raises `JsonRpcError` on authentication failure.
    def authenticate(method_id : String, credentials : JSON::Any? = nil) : Nil
      ensure_state(ClientState::Initialized, "authenticate")

      params = Protocol::AuthenticateParams.new(method_id, credentials)
      send_request(Protocol::AgentMethod::AUTHENTICATE, params)

      ClientLog.info { "Authenticated with method: #{method_id}" }
    end

    # Ends the current authenticated state with the agent (`logout`).
    #
    # Requires the agent to advertise `agentCapabilities.auth.logout`;
    # callers MUST check `agent_capabilities.try(&.auth).try(&.logout?)`
    # first. Afterwards, new sessions that need authentication require
    # `authenticate` again, and active sessions may start failing with
    # auth errors. Local client state is left unchanged.
    #
    # Raises `InvalidStateError` if not initialized.
    # See: https://agentclientprotocol.com/protocol/v1/authentication#logging-out
    def logout : Protocol::LogoutResult
      ensure_state(ClientState::Initialized, "logout")

      raw_result = send_request(Protocol::AgentMethod::LOGOUT, Protocol::LogoutParams.new)
      result = decode_result(Protocol::LogoutResult, raw_result, Protocol::AgentMethod::LOGOUT)

      ClientLog.info { "Logged out" }

      result
    end

    # Creates a new session with the agent.
    #
    # - `cwd` — the absolute path to the working directory.
    # - `mcp_servers` — optional list of MCP servers to connect to.
    # - `additional_directories` — extra absolute workspace roots; only pass
    #   when the agent advertises `sessionCapabilities.additionalDirectories`.
    # - `system_prompt` — system-level instructions; only pass when the agent
    #   advertises `sessionCapabilities.systemPrompt` (and `.mode.override`
    #   for an `override` prompt).
    #
    # Returns the session creation result with the session ID, modes,
    # and config options. Stores the session ID for subsequent calls.
    #
    # Raises `InvalidStateError` if not initialized.
    def session_new(
      cwd : String,
      mcp_servers : Array(JSON::Any) = [] of JSON::Any,
      *,
      additional_directories : Array(String)? = nil,
      system_prompt : Protocol::SystemPrompt? = nil,
    ) : Protocol::SessionNewResult
      ensure_state(ClientState::Initialized, "session/new")

      params = Protocol::SessionNewParams.new(cwd, mcp_servers,
        additional_directories: additional_directories, system_prompt: system_prompt)
      raw_result = send_request(Protocol::AgentMethod::SESSION_NEW, params)
      result = decode_result(Protocol::SessionNewResult, raw_result, Protocol::AgentMethod::SESSION_NEW)

      @session_id = result.session_id
      @session_modes = result.modes
      @session_config_options = result.config_options
      @state = ClientState::SessionActive

      ClientLog.info { "Session created: #{result.session_id}" }

      result
    end

    # Loads (resumes) a previous session by ID.
    #
    # - `session_id` — the session ID to load.
    # - `cwd` — optional working directory override.
    # - `additional_directories` / `system_prompt` — as for `session_new`.
    #   Send the full intended root list and the prompt the session was
    #   created with; neither is restored implicitly.
    #
    # Raises `InvalidStateError` if not initialized.
    # Raises `JsonRpcError` if the agent can't load the session.
    def session_load(
      session_id : String,
      cwd : String,
      mcp_servers : Array(JSON::Any) = [] of JSON::Any,
      *,
      additional_directories : Array(String)? = nil,
      system_prompt : Protocol::SystemPrompt? = nil,
    ) : Protocol::SessionLoadResult
      ensure_state(ClientState::Initialized, "session/load")

      params = Protocol::SessionLoadParams.new(session_id, cwd, mcp_servers,
        additional_directories: additional_directories, system_prompt: system_prompt)
      raw_result = send_request(Protocol::AgentMethod::SESSION_LOAD, params)
      result = decode_result(Protocol::SessionLoadResult, raw_result, Protocol::AgentMethod::SESSION_LOAD)

      @session_id = session_id
      @session_modes = result.modes
      @session_config_options = result.config_options
      @state = ClientState::SessionActive

      ClientLog.info { "Session loaded: #{session_id}" }

      result
    end

    # Lists available sessions from the agent.
    #
    # Requires the agent to advertise `sessionCapabilities.list` during
    # initialization.
    #
    # - `cwd` — optional filter: only return sessions with this working directory.
    # - `cursor` — optional pagination cursor from a previous response.
    #
    # Returns the list result with sessions and optional next cursor.
    #
    # Raises `InvalidStateError` if not initialized.
    # See: https://agentclientprotocol.com/protocol/session-setup#listing-sessions
    def session_list(
      cwd : String? = nil,
      cursor : String? = nil,
    ) : Protocol::SessionListResult
      ensure_state(ClientState::Initialized, "session/list")

      params = Protocol::SessionListParams.new(cwd: cwd, cursor: cursor)
      raw_result = send_request(Protocol::AgentMethod::SESSION_LIST, params)
      decode_result(Protocol::SessionListResult, raw_result, Protocol::AgentMethod::SESSION_LIST)
    end

    # Resumes an existing session by ID without replaying conversation history.
    #
    # Unlike `session/load`, the agent will NOT emit `session/update`
    # notifications to replay prior turns — it just restores context,
    # reconnects to the requested MCP servers, and returns once the
    # session is ready to continue.
    #
    # Requires the agent to advertise `sessionCapabilities.resume` during
    # initialization. Callers SHOULD check `agent_capabilities&.session_capabilities&.resume?`
    # before calling.
    #
    # Returns the resume result, which MAY include initial mode/config
    # state if the agent supports those features.
    #
    # `additional_directories` / `system_prompt` work as for `session_load`.
    #
    # Raises `InvalidStateError` if not initialized.
    # Raises `JsonRpcError` if the agent can't resume the session.
    # See: https://agentclientprotocol.com/protocol/session-setup#resuming-sessions
    def session_resume(
      session_id : String,
      cwd : String,
      mcp_servers : Array(JSON::Any) = [] of JSON::Any,
      *,
      additional_directories : Array(String)? = nil,
      system_prompt : Protocol::SystemPrompt? = nil,
    ) : Protocol::SessionResumeResult
      ensure_state(ClientState::Initialized, "session/resume")

      params = Protocol::SessionResumeParams.new(session_id, cwd, mcp_servers,
        additional_directories: additional_directories, system_prompt: system_prompt)
      raw_result = send_request(Protocol::AgentMethod::SESSION_RESUME, params)
      result = decode_result(Protocol::SessionResumeResult, raw_result, Protocol::AgentMethod::SESSION_RESUME)

      @session_id = session_id
      @session_modes = result.modes
      @session_config_options = result.config_options
      @state = ClientState::SessionActive

      ClientLog.info { "Session resumed: #{session_id}" }

      result
    end

    # Closes an active session, asking the agent to cancel any ongoing
    # work and release resources tied to the session.
    #
    # Requires the agent to advertise `sessionCapabilities.close` during
    # initialization. Callers SHOULD check
    # `agent_capabilities&.session_capabilities&.close?` before calling.
    #
    # If `session_id` is nil the active session is closed. After a
    # successful close the client transitions back to the Initialized
    # state so a new session can be created or another session resumed.
    #
    # Raises `InvalidStateError` if not initialized.
    # Raises `NoActiveSessionError` if no `session_id` is given and no
    # session is active.
    # See: https://agentclientprotocol.com/protocol/session-setup#closing-active-sessions
    def session_close(session_id : String? = nil) : Protocol::SessionCloseResult
      ensure_state(ClientState::Initialized, "session/close")

      sid = session_id || @session_id
      raise NoActiveSessionError.new unless sid

      params = Protocol::SessionCloseParams.new(sid)
      raw_result = begin
        send_request(Protocol::AgentMethod::SESSION_CLOSE, params)
      rescue ex : JsonRpcError
        # session-setup#closing-active-sessions: "Clients SHOULD treat a
        # -32002 response to `session/close` as a successful close."
        raise ex unless ex.resource_not_found?
        JSON::Any.new({} of String => JSON::Any)
      end
      result = decode_result(Protocol::SessionCloseResult, raw_result, Protocol::AgentMethod::SESSION_CLOSE)

      # If we just closed the active session, drop the cached session
      # state so subsequent prompt/cancel calls fail with the correct
      # error instead of silently re-using stale state.
      forget_session(sid)

      ClientLog.info { "Session closed: #{sid}" }

      result
    end

    # Removes a session from the agent's session history, so it no longer
    # appears in `session/list` results.
    #
    # Requires the agent to advertise `sessionCapabilities.delete`; callers
    # MUST check `agent_capabilities&.session_capabilities&.delete?` first.
    # A `-32002` (resource not found) answer counts as success, as the spec
    # recommends. What happens to an active session is up to the agent, so
    # the client's cached session state is left alone (see `forget_session`).
    #
    # Raises `InvalidStateError` if not initialized.
    # See: https://agentclientprotocol.com/protocol/v1/session-delete
    def session_delete(session_id : String) : Protocol::SessionDeleteResult
      ensure_state(ClientState::Initialized, "session/delete")

      params = Protocol::SessionDeleteParams.new(session_id)
      raw_result = begin
        send_request(Protocol::AgentMethod::SESSION_DELETE, params)
      rescue ex : JsonRpcError
        # session-delete#semantics: "Clients SHOULD treat a -32002 response
        # to `session/delete` as a successful delete."
        raise ex unless ex.resource_not_found?
        JSON::Any.new({} of String => JSON::Any)
      end
      result = decode_result(Protocol::SessionDeleteResult, raw_result, Protocol::AgentMethod::SESSION_DELETE)

      ClientLog.info { "Session deleted: #{session_id}" }

      result
    end

    # Drops the cached state for `session_id` if it is the active session,
    # returning the client to the Initialized state. Purely local — nothing
    # is sent to the agent.
    #
    # Use this when a session ends by some route other than a successful
    # `session/close`: the agent doesn't support `session/close`, the caller
    # skipped the remote call, or the remote call failed. Without it the
    # client keeps reporting a dead session as active, and a
    # `session_prompt` / `session_cancel` that omits an explicit ID silently
    # targets it instead of raising `NoActiveSessionError`.
    #
    # Returns true if cached state was actually dropped.
    def forget_session(session_id : String) : Bool
      return false unless @session_id == session_id

      @session_id = nil
      @session_modes = nil
      @session_config_options = nil
      # Only step back to Initialized from an active session; never resurrect
      # a client the caller has already closed.
      @state = ClientState::Initialized if @state == ClientState::SessionActive
      true
    end

    # Sends a prompt to the agent in the active session.
    #
    # - `prompt` — an array of content blocks forming the prompt.
    # - `session_id` — optional session ID override (uses active session if nil).
    #
    # This is a blocking call that waits for the agent to finish
    # processing the prompt. While waiting, `session/update` notifications
    # will be dispatched to the `on_update` callback.
    #
    # Returns the prompt result with the stop reason.
    #
    # Raises `NoActiveSessionError` if no session is active.
    def session_prompt(
      prompt : Array(Protocol::ContentBlock),
      session_id : String? = nil,
    ) : Protocol::SessionPromptResult
      sid = session_id || @session_id
      raise NoActiveSessionError.new unless sid

      params = Protocol::SessionPromptParams.new(sid, prompt)

      # Use a longer timeout for prompts since they can take a while.
      raw_result = send_request(Protocol::AgentMethod::SESSION_PROMPT, params, timeout: @prompt_timeout)
      decode_result(Protocol::SessionPromptResult, raw_result, Protocol::AgentMethod::SESSION_PROMPT)
    end

    # Convenience: sends a simple text prompt.
    #
    # - `text` — the text content to send as a prompt.
    # - `session_id` — optional session ID override.
    def session_prompt_text(
      text : String,
      session_id : String? = nil,
    ) : Protocol::SessionPromptResult
      blocks = [Protocol::TextContentBlock.new(text).as(Protocol::ContentBlock)]
      session_prompt(blocks, session_id)
    end

    # Sends a `session/cancel` notification to abort the current
    # operation in the active session.
    #
    # - `session_id` — optional session ID override.
    #
    # This is a fire-and-forget notification (no response expected).
    #
    # Per the spec the Client MUST answer every pending
    # `session/request_permission` of the session with the `cancelled`
    # outcome, so any permission handler still running for it has its
    # request answered here; whatever that handler later returns is dropped.
    def session_cancel(session_id : String? = nil) : Nil
      sid = session_id || @session_id
      raise NoActiveSessionError.new unless sid

      # Claim the pending permissions first so a handler's late answer is
      # dropped even if sending the notification below fails.
      ids = @pending_mutex.synchronize do
        pending = @in_flight.select do |_id, req|
          req.method == Protocol::ClientMethod::SESSION_REQUEST_PERMISSION && req.session_id == sid
        end.keys
        pending.each { |id| @in_flight.delete(id) }
        pending
      end

      params = Protocol::SessionCancelParams.new(sid)
      send_notification(Protocol::AgentMethod::SESSION_CANCEL, params)

      ClientLog.info { "Sent cancel for session: #{sid}" }

      return if ids.empty?

      ids.each { |id| respond_to_agent(id, cancelled_permission) }
    end

    # Changes the mode for the active session.
    #
    # - `mode_id` — the mode ID to switch to.
    # - `session_id` — optional session ID override.
    def session_set_mode(mode_id : String, session_id : String? = nil) : Nil
      sid = session_id || @session_id
      raise NoActiveSessionError.new unless sid

      params = Protocol::SessionSetModeParams.new(sid, mode_id)
      send_request(Protocol::AgentMethod::SESSION_SET_MODE, params)

      ClientLog.info { "Mode set to: #{mode_id}" }
    end

    # Changes a configuration option for the active session.
    #
    # - `config_id` — the ID of the configuration option to change.
    # - `value` — the new value: a value ID for a `select` option, a Bool
    #   for a `boolean` option (sent with `type: "boolean"`).
    # - `session_id` — optional session ID override.
    #
    # Returns the full set of configuration options and their current values.
    # See: https://agentclientprotocol.com/protocol/session-config-options#from-the-client
    def session_set_config_option(
      config_id : String,
      value : String | Bool,
      session_id : String? = nil,
    ) : Protocol::SessionSetConfigOptionResult
      sid = session_id || @session_id
      raise NoActiveSessionError.new unless sid

      params = Protocol::SessionSetConfigOptionParams.new(sid, config_id, value)
      raw_result = send_request(Protocol::AgentMethod::SESSION_SET_CONFIG_OPTION, params)
      result = decode_result(Protocol::SessionSetConfigOptionResult, raw_result, Protocol::AgentMethod::SESSION_SET_CONFIG_OPTION)

      @session_config_options = result.config_options

      ClientLog.info { "Config option '#{config_id}' set to '#{value}'" }

      result
    end

    # ─── Extension Methods ────────────────────────────────────────────
    # Extension methods provide a way to add custom functionality while
    # maintaining protocol compatibility. Method names are prefixed with
    # `_` on the wire automatically.
    # See: https://agentclientprotocol.com/protocol/extensibility

    # Sends a custom extension request to the agent and waits for a response.
    #
    # - `method` — the custom method name (WITHOUT the `_` prefix).
    # - `params` — the request parameters as raw JSON.
    # - `timeout` — optional timeout override (nil = use default).
    #
    # Returns the raw JSON response from the agent.
    #
    # Example:
    #   ```
    # result = client.ext_method("my_custom_method", JSON.parse(%({"key": "value"})))
    #   ```
    def ext_method(method : String, params : JSON::Any = JSON::Any.new(nil), timeout : Float64? = @request_timeout) : JSON::Any
      wire_method = Protocol::ExtensionMethod.add_prefix(method)
      send_request_raw(wire_method, params, timeout: timeout)
    end

    # Sends a custom extension notification to the agent (fire-and-forget).
    #
    # - `method` — the custom method name (WITHOUT the `_` prefix).
    # - `params` — the notification parameters as raw JSON.
    #
    # Example:
    #   ```
    # client.ext_notification("my_custom_event", JSON.parse(%({"status": "ok"})))
    #   ```
    def ext_notification(method : String, params : JSON::Any = JSON::Any.new(nil)) : Nil
      wire_method = Protocol::ExtensionMethod.add_prefix(method)
      send_notification_raw(wire_method, params)
    end

    # Closes the client, stopping the dispatcher and closing the transport.
    def close : Nil
      return if @state == ClientState::Closed
      @user_closed = true
      @state = ClientState::Closed

      ClientLog.info { "Closing client" }

      # Cancel all pending requests with a proper JSON-RPC error object.
      drain_pending_requests("Client closed")

      # Close the transport. This is also what stops the dispatcher: the
      # transport's `receive` returns nil once it is closed, which breaks
      # the dispatcher loop.
      @transport.close

      @dispatcher_running = false
    end

    # Returns true if the client has been closed.
    def closed? : Bool
      @state == ClientState::Closed
    end

    # Returns true if a session is currently active.
    def session_active? : Bool
      @state == ClientState::SessionActive && @session_id != nil
    end

    # ─── Low-Level API ──────────────────────────────────────────────

    # Sends a JSON-RPC request and waits for the response.
    #
    # - `method` — the RPC method name.
    # - `params` — the request parameters (JSON::Serializable).
    # - `timeout` — optional timeout in seconds (nil = use default).
    #
    # Returns the `result` field from the response as JSON::Any.
    # Raises `JsonRpcError` if the response contains an error.
    # Raises `RequestTimeoutError` if the request times out.
    # Raises `ConnectionClosedError` if the transport is closed.
    def send_request(
      method : String,
      params : JSON::Serializable,
      timeout : Float64? = @request_timeout,
    ) : JSON::Any
      message_builder = ->(id : Int64) { Protocol.build_request(id, method, params) }
      send_and_await_response(method, message_builder, timeout)
    end

    # Sends a JSON-RPC notification (no response expected).
    #
    # - `method` — the notification method name.
    # - `params` — the notification parameters.
    def send_notification(method : String, params : JSON::Serializable) : Nil
      raise ConnectionClosedError.new if closed?

      message = Protocol.build_notification(method, params)
      @transport.send(message)

      ClientLog.debug { "Sent notification method=#{method}" }
    end

    # Sends a JSON-RPC request with raw JSON::Any params and waits for the response.
    #
    # - `method` — the RPC method name.
    # - `params` — the request parameters as raw JSON::Any.
    # - `timeout` — optional timeout in seconds (nil = no timeout).
    #
    # Returns the `result` field from the response as JSON::Any.
    # Raises `JsonRpcError` if the response contains an error.
    # Raises `RequestTimeoutError` if the request times out.
    # Raises `ConnectionClosedError` if the transport is closed.
    def send_request_raw(
      method : String,
      params : JSON::Any,
      timeout : Float64? = @request_timeout,
    ) : JSON::Any
      message_builder = ->(id : Int64) { Protocol.build_request_raw(id, method, params) }
      send_and_await_response(method, message_builder, timeout)
    end

    # Sends a JSON-RPC notification with raw JSON::Any params (no response expected).
    #
    # - `method` — the notification method name.
    # - `params` — the notification parameters as raw JSON::Any.
    def send_notification_raw(method : String, params : JSON::Any) : Nil
      raise ConnectionClosedError.new if closed?

      message = Protocol.build_notification_raw(method, params)
      @transport.send(message)

      ClientLog.debug { "Sent raw notification method=#{method}" }
    end

    # Sends `$/cancel_request` asking the agent to cancel one of our
    # outstanding requests. The agent may ignore it; it still answers the
    # request, normally with a `-32800` (`JsonRpcError#request_cancelled?`)
    # error, which the waiting caller then receives. A request that times
    # out is cancelled this way automatically. To cancel a prompt turn, use
    # `session_cancel` instead.
    # See: https://agentclientprotocol.com/protocol/v1/cancellation
    def cancel_request(request_id : Protocol::RequestId) : Nil
      send_notification(Protocol::ProtocolMethod::CANCEL_REQUEST, Protocol::CancelRequestParams.new(request_id))
    end

    # Responds to an agent-initiated request.
    #
    # - `id` — the request ID from the agent's request; nil answers a request
    #   whose ID was null (`"id": null` on the wire).
    # - `result` — the result to send back.
    def respond_to_agent(id : Protocol::RequestId?, result : JSON::Any) : Nil
      raise ConnectionClosedError.new if closed?

      message = Protocol.build_response_raw(id, result)
      @transport.send(message)

      ClientLog.debug { "Sent response to agent request id=#{id}" }
    end

    # Responds to an agent-initiated request with an error.
    #
    # - `id` — the request ID from the agent's request; nil sends
    #   `"id": null`, as JSON-RPC 2.0 §5 requires when the request's ID was
    #   null or could not be read.
    # - `code` — the JSON-RPC error code.
    # - `error_message` — human-readable error description.
    # - `data` — optional structured value carrying additional information
    #   about the error (JSON-RPC 2.0 §5.1). Omitted from the wire when nil.
    def respond_to_agent_error(
      id : Protocol::RequestId?,
      code : Int32,
      error_message : String,
      data : JSON::Any? = nil,
    ) : Nil
      raise ConnectionClosedError.new if closed?

      message = Protocol.build_error_response(id, code, error_message, data)
      @transport.send(message)

      ClientLog.debug { "Sent error response to agent request id=#{id} code=#{code}" }
    end

    # ─── Private Methods ────────────────────────────────────────────

    # Core implementation for sending a JSON-RPC request and awaiting
    # its response. Both `send_request` and `send_request_raw` delegate
    # to this method, differing only in how they build the message.
    #
    # - `method` — the RPC method name (used for logging and error messages).
    # - `message_builder` — a proc that receives the request ID and returns
    #   the serialized message hash ready for transport.
    # - `timeout` — optional timeout in seconds (nil = no timeout).
    #
    # Returns the `result` field from the response as JSON::Any.
    # Raises `JsonRpcError` if the response contains an error.
    # Raises `RequestTimeoutError` if the request times out.
    # Raises `ConnectionClosedError` if the transport is closed.
    private def send_and_await_response(
      method : String,
      message_builder : Int64 -> Hash(String, JSON::Any),
      timeout : Float64? = @request_timeout,
    ) : JSON::Any
      raise ConnectionClosedError.new if closed?

      # Generate a unique ID and register the pending channel atomically.
      response_channel = Channel(JSON::Any).new(1)

      id = @pending_mutex.synchronize do
        current_id = @next_id
        @next_id += 1
        @pending[current_id.to_s] = response_channel
        current_id
      end
      id_str = id.to_s

      # Build and send the request. If the send fails (e.g. the transport was
      # closed underneath us), drop the pending entry we just registered so it
      # can never linger unresolved in `@pending`.
      message = message_builder.call(id)
      begin
        @transport.send(message)
      rescue ex
        @pending_mutex.synchronize { @pending.delete(id_str) }
        raise ex
      end

      ClientLog.debug { "Sent request id=#{id} method=#{method}" }

      # Wait for the response with optional timeout.
      raw_response = begin
        if timeout
          receive_with_timeout(response_channel, timeout, id)
        else
          response_channel.receive
        end
      rescue Channel::ClosedError
        # `drain_pending_requests` closed it: the connection is gone.
        raise ConnectionClosedError.new("#{@disconnect_reason} while waiting for response to #{method}")
      end

      # Check for errors in the response.
      if error = raw_response["error"]?
        if error.raw.is_a?(Hash)
          raise JsonRpcError.from_json_any(error)
        else
          raise JsonRpcError.new(
            JsonRpcError::INTERNAL_ERROR,
            error.as_s? || "Unknown error"
          )
        end
      end

      # Return the result.
      raw_response["result"]? || JSON::Any.new(nil)
    end

    # Deserializes an agent `result` payload into the expected protocol type.
    #
    # A misbehaving agent can return a result that does not match the ACP
    # schema — a missing `sessionId`, a number where a string belongs, or no
    # `result` member at all (JSON-RPC 2.0 §5 requires exactly one of
    # `result` / `error`). `JSON::Serializable` signals that with a
    # `JSON::SerializableError`, which would otherwise escape a public
    # `Client` method and break the library's contract that everything it
    # raises is an `ACP::Error`. Translate it into `ProtocolError`, keeping
    # the original as the cause.
    private def decode_result(type : T.class, raw : JSON::Any, method : String) : T forall T
      T.from_json(raw.to_json)
    rescue ex : JSON::ParseException
      raise ProtocolError.new(
        "Agent returned a malformed result for '#{method}': #{ex.message}",
        ex
      )
    end

    # Closes every pending request channel and clears the pending map, so
    # each waiting caller raises `ConnectionClosedError` with `reason` in its
    # message. Used during close and disconnect to unblock callers. (A fake
    # JSON-RPC error here would pose as an answer from the agent.)
    private def drain_pending_requests(reason : String) : Nil
      @pending_mutex.synchronize do
        @disconnect_reason = reason unless @pending.empty?
        @pending.each_value(&.close)
        @pending.clear
      end
    end

    # Ensures the client is in the expected state before performing
    # an operation. Raises `InvalidStateError` if not.
    private def ensure_state(expected : ClientState, operation : String) : Nil
      return if @state == expected

      # Allow session operations when session is active and we expected initialized.
      if expected == ClientState::Initialized && @state == ClientState::SessionActive
        return
      end

      raise InvalidStateError.new(
        "Cannot perform '#{operation}' in state #{@state}. Expected: #{expected}."
      )
    end

    # Waits for a response on the given channel with a timeout.
    private def receive_with_timeout(
      channel : Channel(JSON::Any),
      timeout_seconds : Float64,
      request_id : Int64,
    ) : JSON::Any
      timeout_span = timeout_seconds.seconds

      select
      when response = channel.receive
        response
      when timeout(timeout_span)
        # Clean up the pending entry.
        @pending_mutex.synchronize do
          @pending.delete(request_id.to_s)
        end
        # Nobody waits for the answer any more: tell the agent it can stop.
        begin
          cancel_request(request_id)
        rescue ex
          ClientLog.debug { "Could not send $/cancel_request for id=#{request_id}: #{ex.message}" }
        end
        raise RequestTimeoutError.new(request_id, timeout_seconds)
      end
    end

    # ─── Dispatcher ─────────────────────────────────────────────────

    # Starts the background dispatcher fiber that reads messages from
    # the transport and routes them to the appropriate handler.
    private def start_dispatcher
      return if @dispatcher_running
      @dispatcher_running = true

      spawn(name: "acp-client-dispatcher") do
        dispatcher_loop
      end
    end

    # The main dispatcher loop. Reads messages from the transport and
    # classifies them as responses, agent requests, or notifications.
    private def dispatcher_loop
      loop do
        break unless @dispatcher_running
        break if @transport.closed?

        msg = @transport.receive
        break if msg.nil?

        begin
          # An agent request's outcome is recorded by its handler fiber.
          @consecutive_dispatch_errors.set(0) unless dispatch_message(msg)
        rescue ex
          record_dispatch_failure(ex)
        end
      end

      @dispatcher_running = false

      # Notify pending requests that the connection is lost.
      drain_pending_requests("Connection lost")

      # Invoke the disconnect callback if set — but only for an UNEXPECTED loss
      # of the transport. When the caller asked for `close`, the dispatcher
      # exits too, and firing "connection lost" there would be a spurious
      # signal (it could, e.g., trigger reconnect logic on a clean shutdown).
      if !@user_closed && (cb = @on_disconnect)
        begin
          cb.call
        rescue ex
          ClientLog.error { "Error in disconnect callback: #{ex.message}" }
        end
      end
    end

    # Counts a failed dispatch and tears the connection down once
    # `MAX_CONSECUTIVE_DISPATCH_ERRORS` failures happened in a row.
    private def record_dispatch_failure(ex : Exception) : Nil
      count = @consecutive_dispatch_errors.add(1) + 1
      ClientLog.error { "Error dispatching message (#{count} consecutive): #{ex.message}" }
      return if count < MAX_CONSECUTIVE_DISPATCH_ERRORS

      # The input stream looks corrupt — continuing to read it would just
      # spin. This is an UNEXPECTED loss of the stream, so we tear the
      # connection down WITHOUT going through the public `close` (which
      # would mark it as an intentional shutdown): we leave `@user_closed`
      # false and let the dispatcher's post-loop cleanup drain pending
      # requests and fire the `on_disconnect` callback.
      ClientLog.error { "Reached #{MAX_CONSECUTIVE_DISPATCH_ERRORS} consecutive dispatch errors, possible protocol corruption; closing connection" }
      @state = ClientState::Closed
      @dispatcher_running = false
      @transport.close
    end

    # Routes a single incoming message to the appropriate handler. Returns
    # true for an agent request, whose handler fiber records the outcome.
    private def dispatch_message(msg : JSON::Any) : Bool
      # Every JSON-RPC 2.0 message is an object. ACP does not use batch
      # (array) requests, so a top-level array — or a bare number, string,
      # bool, or null — is not routable. Probing it for "id"/"method" would
      # raise, so answer it with a single -32600 (JSON-RPC 2.0 §5/§6, as the
      # ACP Rust SDK does) and move on without counting it as corruption.
      unless obj = msg.as_h?
        ClientLog.warn { "Rejecting non-object JSON-RPC frame" }
        reject_invalid_request
        return false
      end

      kind = Protocol.classify_message(msg)

      case kind
      when Protocol::MessageKind::Request
        # `session/update` is only ever a notification in ACP; some JSON-RPC
        # serializers write `"id": null` on notifications, so don't turn
        # those into a -32601 answer and lose the update.
        if obj["id"].raw.nil? && obj["method"].as_s == Protocol::AgentMethod::SESSION_UPDATE
          handle_notification(msg)
        else
          return handle_agent_request(msg)
        end
      when Protocol::MessageKind::Response
        handle_response(msg)
      when Protocol::MessageKind::Notification
        if obj["method"]?.try(&.as_s?)
          handle_notification(msg)
        elsif obj.has_key?("method") || !(obj.has_key?("result") || obj.has_key?("error"))
          # Neither a call nor a response (`{}`, a non-string method): an
          # Invalid Request. An id-less response has nothing to answer.
          ClientLog.warn { "Rejecting JSON-RPC object that is neither a request nor a response" }
          reject_invalid_request
        else
          ClientLog.warn { "Ignoring response without a JSON-RPC id" }
        end
      end
      false
    end

    # Answers an incoming value we could not read as a JSON-RPC message with
    # -32600, `"id": null` (JSON-RPC 2.0 §5: the id MUST be null when it
    # could not be detected).
    private def reject_invalid_request(detail : String? = nil) : Nil
      respond_to_agent_error(nil, JsonRpcError::INVALID_REQUEST, "Invalid request",
        detail.try { |d| JSON::Any.new(d) })
    rescue ex : TransportError
      # The link is going away; the dispatcher notices on its next read.
      ClientLog.debug { "Could not answer an invalid frame: #{ex.message}" }
    end

    # Handles a response to one of our pending requests.
    # Finds the corresponding channel by ID and sends the response into it.
    private def handle_response(msg : JSON::Any) : Nil
      id = Protocol.extract_id(msg)
      unless id
        ClientLog.warn { "Ignoring response with a missing or unusable JSON-RPC id" }
        return
      end

      id_str = id.to_s

      # Take the entry out as the response is delivered: a request gets one
      # response (JSON-RPC 2.0 §5), and the channel holds exactly one, so a
      # repeated response must not reach it — sending a second or third copy
      # into the full channel would block the dispatcher for good.
      delivered = @pending_mutex.synchronize do
        if channel = @pending.delete(id_str)
          channel.send(msg)
          true
        end
      end
      ClientLog.warn { "Received response for unknown request id=#{id_str}" } unless delivered
    end

    # Handles a method call from the agent (e.g., session/request_permission).
    # If we have a registered handler, we invoke it and send the result back.
    # Otherwise, we respond with a method-not-found error.
    #
    # The handler runs in its own fiber: a handler that blocks (on the user,
    # on I/O) must not stall the dispatcher, or responses and notifications
    # behind it — such as the `cancelled` prompt response that follows a
    # `session/cancel` — are not read until it returns. Each response goes
    # back through the transport's serialized `send`. Notifications stay on
    # the dispatcher so `session/update` order is preserved.
    #
    # Dispatch order:
    #   1. Well-known methods with typed handlers (permission, fs/*, terminal/*)
    #   2. Generic `on_agent_request` callback
    #   3. Method-not-found error
    #
    # Returns true when a handler fiber was started (it records the outcome).
    private def handle_agent_request(msg : JSON::Any) : Bool
      # A nil `id` here is either `"id": null` — a valid, if discouraged,
      # request ID that we echo back — or a value we cannot represent
      # (fractional, out of range, bool, container). Echoing a coerced ID
      # would answer the wrong request, so the latter gets -32600 with
      # `"id": null`, as JSON-RPC 2.0 §5 requires.
      id = Protocol.extract_id(msg)
      unless id || msg["id"]?.try(&.raw).nil?
        ClientLog.warn { "Rejecting agent request with an unusable JSON-RPC id" }
        reject_invalid_request("request id must be a string, an integer, or null")
        return false
      end

      method_name = msg["method"]?.try(&.as_s?)
      return false unless method_name

      params = msg["params"]?

      ClientLog.debug { "Agent request: method=#{method_name} id=#{id}" }

      # Track the request before handing it off, so a `session_cancel` or
      # `$/cancel_request` read right after it can still answer it.
      # A null-id request isn't tracked: every such request would share the
      # one `nil` key, and all but one would go unanswered.
      entry = nil
      unless id.nil?
        perm_sid = if method_name == Protocol::ClientMethod::SESSION_REQUEST_PERMISSION
                     params.try(&.as_h?).try(&.["sessionId"]?).try(&.as_s?)
                   end
        entry = InFlightRequest.new(method_name, perm_sid)
        @pending_mutex.synchronize { @in_flight[id] = entry }
      end

      spawn(name: "acp-agent-request") do
        reply = route_agent_request(method_name, params)
        if claim_agent_request(id, entry)
          case reply
          in Protocol::JsonRpcErrorObject then respond_to_agent_error(id, reply.code, reply.message, reply.data)
          in JSON::Any                    then respond_to_agent(id, reply)
          end
        end
        @consecutive_dispatch_errors.set(0)
      rescue ex
        # Only the response write itself lands here (handler errors are
        # answered as JSON-RPC errors).
        # Once the connection is gone (closed, or the dispatcher stopped on
        # EOF) a failed write is expected, not a sign of a corrupt stream.
        if closed? || !@dispatcher_running
          ClientLog.debug { "Dropping answer to agent request id=#{id}: connection closed" }
        else
          record_dispatch_failure(ex)
        end
      end
      true
    end

    # The answer to an agent request: a result, or a JSON-RPC error.
    private alias AgentReply = JSON::Any | Protocol::JsonRpcErrorObject

    # Runs the handler for an agent request and returns its answer; the
    # caller sends it unless the request was already answered by a cancel.
    private def route_agent_request(method_name : String, params : JSON::Any?) : AgentReply
      case method_name
      when Protocol::ClientMethod::SESSION_REQUEST_PERMISSION
        handle_permission_request(params)
      when Protocol::ClientMethod::FS_READ_TEXT_FILE
        handle_typed_client_method(params, @on_read_text_file, Protocol::ReadTextFileParams, method_name)
      when Protocol::ClientMethod::FS_WRITE_TEXT_FILE
        handle_typed_client_method(params, @on_write_text_file, Protocol::WriteTextFileParams, method_name)
      when Protocol::ClientMethod::TERMINAL_CREATE
        handle_typed_client_method(params, @on_create_terminal, Protocol::CreateTerminalParams, method_name)
      when Protocol::ClientMethod::TERMINAL_OUTPUT
        handle_typed_client_method(params, @on_terminal_output, Protocol::TerminalOutputParams, method_name)
      when Protocol::ClientMethod::TERMINAL_RELEASE
        handle_typed_client_method(params, @on_release_terminal, Protocol::ReleaseTerminalParams, method_name)
      when Protocol::ClientMethod::TERMINAL_WAIT_FOR_EXIT
        handle_typed_client_method(params, @on_wait_for_terminal_exit, Protocol::WaitForTerminalExitParams, method_name)
      when Protocol::ClientMethod::TERMINAL_KILL
        handle_typed_client_method(params, @on_kill_terminal, Protocol::KillTerminalParams, method_name)
      when Protocol::ClientMethod::ELICITATION_CREATE
        # elicitation#url-completion: "Requests using a mode the Client has
        # not advertised produce JSON-RPC -32602 (Invalid params)."
        mode = params.try(&.as_h?).try(&.["mode"]?).try(&.as_s?)
        unless @client_capabilities.elicitation.try(&.supports?(mode))
          return Protocol::JsonRpcErrorObject.new(JsonRpcError::INVALID_PARAMS,
            "Elicitation mode not advertised by the client: #{mode.inspect}")
        end
        handle_typed_client_method(params, @on_create_elicitation, Protocol::CreateElicitationParams, method_name)
      else
        handle_unknown_agent_request(method_name, params)
      end
    end

    # Delegates an unrecognized agent request to the generic handler, or
    # responds with -32601 Method not found if no handler is set.
    #
    # Extension methods (`_`-prefixed) reach `on_agent_request` under their
    # full wire name. Without a handler they get -32601 like any other
    # unknown method (extensibility#custom-requests: "If the receiving end
    # doesn't recognize the custom method name, it should respond with the
    # standard 'Method not found' error"), with the method name as `data`.
    private def handle_unknown_agent_request(method_name : String, params : JSON::Any?) : AgentReply
      if handler = @on_agent_request
        begin
          handler.call(method_name, params || JSON::Any.new(nil))
        rescue ex
          ClientLog.error { "Error in agent request handler for #{method_name}: #{ex.message}" }
          handler_error_reply(ex, ex.message || "Handler error")
        end
      else
        Protocol::JsonRpcErrorObject.new(
          JsonRpcError::METHOD_NOT_FOUND,
          "Client does not handle method: #{method_name}",
          JSON::Any.new(method_name)
        )
      end
    end

    # Generic typed dispatch for client methods. Tries the typed handler
    # first, then falls back like an unknown method (`on_agent_request`,
    # else -32601).
    private def handle_typed_client_method(
      params : JSON::Any?,
      handler,
      params_type,
      method_name : String,
    ) : AgentReply
      return handle_unknown_agent_request(method_name, params) unless h = handler

      typed_params = begin
        params_type.from_json((params || JSON::Any.new(nil)).to_json)
      rescue ex
        ClientLog.error { "Failed to parse #{method_name} params: #{ex.message}" }
        return Protocol::JsonRpcErrorObject.new(JsonRpcError::INVALID_PARAMS, "Invalid params for #{method_name}: #{ex.message}")
      end

      # Separate from the parse above: a JSON error raised by the handler's
      # own code is a handler failure, not invalid params.
      begin
        # Convert JSON::Serializable result to JSON::Any via round-trip;
        # Crystal has no direct JSON::Serializable → JSON::Any conversion.
        JSON.parse(h.call(typed_params).to_json)
      rescue ex
        ClientLog.error { "Error in #{method_name} handler: #{ex.message}" }
        handler_error_reply(ex, ex.message || "Handler error")
      end
    end

    # Handles a `session/request_permission` request from the agent.
    # Delegates to the on_agent_request handler or auto-denies.
    private def handle_permission_request(params : JSON::Any?) : AgentReply
      if handler = @on_agent_request
        begin
          handler.call("session/request_permission", params || JSON::Any.new(nil))
        rescue ex
          ClientLog.error { "Error handling permission request: #{ex.message}" }
          handler_error_reply(ex, "Permission handler error: #{ex.message}")
        end
      else
        # No handler — auto-cancel the permission request.
        #
        # The ACP spec models `RequestPermissionResponse.outcome` as a nested
        # `RequestPermissionOutcome` object, so the result MUST be
        # `{"outcome": {"outcome": "cancelled"}}`, not a bare
        # `{"outcome": "cancelled"}`. Agents (e.g. Gemini) silently reject the
        # un-nested form and keep re-requesting permission, which spins the
        # prompt turn until it times out. Reuse the typed builder so this path
        # stays consistent with `Protocol::RequestPermissionResult.cancelled`.
        ClientLog.warn { "No handler for permission request; auto-cancelling" }
        cancelled_permission
      end
    end

    # The `cancelled` outcome for a `session/request_permission` request.
    private def cancelled_permission : JSON::Any
      JSON.parse(Protocol::RequestPermissionResult.cancelled.to_json)
    end

    # The answer to an agent request whose handler raised. A handler that
    # raises `JsonRpcError` chooses the error the agent sees — e.g. -32002
    # for a missing file (error#unknown-sessions) or -32800 for a cancelled
    # request (cancellation) — so its code, message and data are sent as-is.
    # Any other exception becomes -32603 with `fallback` as the message.
    private def handler_error_reply(ex : Exception, fallback : String) : Protocol::JsonRpcErrorObject
      # An error the agent returned to a request the handler made itself
      # describes that other request, not this one: don't echo it back.
      if ex.is_a?(JsonRpcError) && !ex.received?
        Protocol::JsonRpcErrorObject.new(ex.code, ex.message || fallback, ex.data)
      else
        Protocol::JsonRpcErrorObject.new(JsonRpcError::INTERNAL_ERROR, fallback)
      end
    end

    # Removes an agent request from `@in_flight`. Returns false when a
    # cancel already answered it, so the caller must not respond again.
    # Untracked (null-id) requests are always answered.
    private def claim_agent_request(id : Protocol::RequestId?, entry : InFlightRequest?) : Bool
      return true unless id && entry
      @pending_mutex.synchronize do
        current = @in_flight[id]?
        # Gone: a cancel answered it. Replaced: the agent reused the ID of a
        # request still in flight; this one is still ours to answer.
        return false unless current
        @in_flight.delete(id) if current.same?(entry)
        true
      end
    end

    # Handles an incoming `$/cancel_request`. A tracked request whose method
    # is in `CANCEL_ANSWERED_EARLY` is answered now — `cancelled` for a
    # permission request, -32800 otherwise — and its handler's late answer is
    # dropped. Other requests are left to their handler, which still answers
    # them. The notification is then passed to `on_notification`, so the
    # application can stop the work.
    private def handle_cancel_request(params : JSON::Any?) : Nil
      id = params.try { |p| Protocol::CancelRequestParams.from_json(p.to_json).request_id rescue nil }
      entry = nil
      if id
        entry = @pending_mutex.synchronize do
          req = @in_flight[id]?
          @in_flight.delete(id) if req && CANCEL_ANSWERED_EARLY.includes?(req.method)
        end
      end

      if id && entry
        ClientLog.info { "Agent cancelled request id=#{id} (#{entry.method})" }
        begin
          if entry.method == Protocol::ClientMethod::SESSION_REQUEST_PERMISSION
            respond_to_agent(id, cancelled_permission)
          else
            respond_to_agent_error(id, JsonRpcError::REQUEST_CANCELLED, "Request cancelled")
          end
        rescue ex : TransportError
          ClientLog.debug { "Could not answer cancelled request id=#{id}: #{ex.message}" }
        end
      end

      deliver_raw_notification(Protocol::ProtocolMethod::CANCEL_REQUEST, params)
    end

    # Handles an incoming notification from the agent.
    private def handle_notification(msg : JSON::Any) : Nil
      method_name = msg["method"]?.try(&.as_s?)
      return unless method_name

      params = msg["params"]?

      ClientLog.debug { "Notification: method=#{method_name}" }

      case method_name
      when Protocol::AgentMethod::SESSION_UPDATE
        handle_session_update(params)
      when Protocol::ProtocolMethod::CANCEL_REQUEST
        handle_cancel_request(params)
      when Protocol::ClientMethod::ELICITATION_COMPLETE
        handle_elicitation_complete(params)
      else
        # Delegate to the generic notification handler.
        # Extension notifications (prefixed with `_`) are also routed here.
        if @on_notification
          deliver_raw_notification(method_name, params)
        else
          if Protocol::ExtensionMethod.extension?(method_name)
            ClientLog.debug { "Unhandled extension notification: #{method_name}" }
          else
            ClientLog.debug { "Unhandled notification: #{method_name}" }
          end
        end
      end
    end

    # Handles a `session/update` notification by parsing it and
    # invoking the registered update handler.
    private def handle_session_update(params : JSON::Any?) : Nil
      return unless params

      # Params that aren't a usable object can't be typed, but they are still
      # a notification the agent sent us: hand them to `on_notification`
      # rather than dropping them on the floor.
      raw_h = params.as_h?
      unless raw_h
        ClientLog.warn { "session/update params are not an object" }
        deliver_raw_notification(Protocol::AgentMethod::SESSION_UPDATE, params)
        return
      end

      # Compatibility: Ensure 'sessionUpdate' is present for discriminator.
      # The ACP spec uses "sessionUpdate" as the discriminator field.
      # Some legacy agents may send "type" instead, so we normalize
      # "type" → "sessionUpdate" for backward compatibility.
      raw_params = raw_h.dup
      if update = raw_params["update"]?
        update_h = update.as_h?
        unless update_h
          ClientLog.warn { "session/update `update` payload is not an object" }
          deliver_raw_notification(Protocol::AgentMethod::SESSION_UPDATE, params)
          return
        end
        update_h = update_h.dup
        if !update_h.has_key?("sessionUpdate") && update_h.has_key?("type")
          update_h["sessionUpdate"] = update_h["type"]
          raw_params["update"] = JSON::Any.new(update_h)
        end
      end
      normalized_params = JSON::Any.new(raw_params)

      unless handler = @on_update
        # No typed handler registered. `session/update` is still a
        # notification, so hand it to the generic notification handler rather
        # than dropping it — a client that only registers `on_notification`
        # would otherwise never see any session updates at all.
        deliver_raw_notification(Protocol::AgentMethod::SESSION_UPDATE, params)
        return
      end

      # Parse and invoke in separate steps. Folding them into one `begin`
      # would let a `JSON::SerializableError` raised by the *handler* (user
      # code deserializing something of its own) be mistaken for a failure to
      # parse the update, re-delivering the same notification to
      # `on_notification` a second time.
      update_params = begin
        Protocol::SessionUpdateParams.from_json(normalized_params.to_json)
      rescue ex : JSON::ParseException
        ClientLog.warn { "Failed to parse session/update: #{ex.message}" }
        # Try the raw notification handler as fallback.
        deliver_raw_notification(Protocol::AgentMethod::SESSION_UPDATE, params)
        return
      end

      begin
        handler.call(update_params)
      rescue ex
        ClientLog.error { "Error in update handler: #{ex.message}" }
      end
    end

    # Delivers `elicitation/complete` to `on_elicitation_complete`, or to
    # `on_notification` when that is unset or the params don't parse.
    private def handle_elicitation_complete(params : JSON::Any?) : Nil
      method = Protocol::ClientMethod::ELICITATION_COMPLETE
      handler = @on_elicitation_complete
      typed = params.try { |p| Protocol::CompleteElicitationParams.from_json(p.to_json) rescue nil }
      return deliver_raw_notification(method, params) unless handler && typed

      begin
        handler.call(typed)
      rescue ex
        ClientLog.error { "Error in elicitation/complete handler: #{ex.message}" }
      end
    end

    # Passes a notification to the generic `on_notification` callback, if one
    # is registered. Handler errors are logged, never propagated — a throwing
    # callback must not count against the dispatcher's corruption budget.
    private def deliver_raw_notification(method_name : String, params : JSON::Any?) : Nil
      return unless fallback = @on_notification

      begin
        fallback.call(method_name, params)
      rescue ex
        ClientLog.error { "Error in notification handler: #{ex.message}" }
      end
    end
  end
end
