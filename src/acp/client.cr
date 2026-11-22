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
require "set"
require "uri"
require "./protocol/types"
require "./protocol/session_fork"
require "./protocol/client_methods"
require "./transport"
require "./mcp_provider"
require "./errors"
require "./subagents"
require "./cursors"
require "./session_choices"

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

    # Latest mode state for the given session, or the current session.
    def session_modes(session_id : String? = nil) : Protocol::SessionModeState?
      @pending_mutex.synchronize do
        if sid = session_id || @session_id
          @session_choices[sid].try(&.v1_modes)
        end
      end
    end

    # Latest configuration options for the given session, or the current session.
    def session_config_options(session_id : String? = nil) : Array(Protocol::ConfigOption)?
      @pending_mutex.synchronize do
        if sid = session_id || @session_id
          @session_choices[sid].try(&.v1_options)
        end
      end
    end

    # :nodoc:
    def seed_session_choices(session_id : String, modes : Protocol::SessionModeState?, options : Array(Protocol::ConfigOption)?) : Nil
      @pending_mutex.synchronize { @session_choices.seed(session_id, modes, options) unless @disconnected }
    end

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

    # Resolves custom system prompt modes advertised through an ACP extension.
    property on_system_prompt_mode : Protocol::SystemPromptModeResolver?

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

    # Callback for draft authentication status changes from the Agent.
    property on_auth_status_update : (Protocol::AuthStatusUpdateParams -> Nil)?

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
    private alias PendingResponse = JSON::Any | Protocol::WireFrame | ProtocolError
    private alias ForkCursorGrant = {String, String, UInt64}

    private record PendingRequest,
      response : Channel(PendingResponse),
      closing_session : String?,
      close_on_missing : Bool,
      creating_session : String?,
      fork_source : String?,
      fork_cursor : ForkCursorGrant?,
      on_result : (String -> Nil)?,
      on_response : (PendingResponse -> Nil)?,
      armed : Bool,
      retirement_order : UInt64? = nil,
      exact_response : Bool = false

    @pending = {} of String => PendingRequest

    # A timed-out v2 close, archive, or delete can still retire runtime.
    private record LateSessionRetirement, session_id : String, write_order : UInt64, close_on_missing : Bool
    @session_lifecycle_order = 0_u64
    @late_session_retirements = {} of String => LateSessionRetirement
    private MAX_LATE_SESSION_RETIREMENTS = 128
    private MAX_EARLY_PLAN_IDS           =  64
    private MAX_EARLY_PLAN_ID_SIZE       = 64 * 1024

    # V1 session IDs learned through successful setup, guarded by @pending_mutex.
    @known_session_ids = Set(String).new
    @session_choices : SessionChoices
    @v1_boolean_config_supported = false

    # Negotiated once by the dispatcher before delivering any suggestions.
    @suggestion_content_types : Set(String)?
    @mcp_acp_supported = false

    # Keep v1 history out of the composer until the wire reply, even after a timeout.
    @suggestion_loads = {} of String => String

    # Mutex for thread-safe access to @pending (though Crystal fibers
    # are cooperative, this protects against unexpected scheduling).
    @pending_mutex : Mutex = Mutex.new

    # Set by `drain_pending_requests`: the connection is gone, so a new
    # request must not register (nothing would ever answer or drain it).
    # Guarded by `@pending_mutex`.
    @disconnected : Bool = false

    # Matches initialize at the dispatcher boundary so the next frame uses
    # the newly negotiated protocol and authentication status capability.
    @initialize_request : String?
    @v2_initialization_result : Protocol::V2::InitializeResult?
    @v2_request_sent = false
    @v2_request_operations = 0
    @v2_initialize_armed = false
    @v2_contract_unknown = Atomic(Bool).new(false)
    @auth_status_supported = false

    # Plan IDs and their attachment order, grouped by session. Guarded by @pending_mutex.
    @plan_ids = {} of String => Hash(String, UInt64)
    @early_plan_sessions = Set(String).new

    # Optional child sessions and their setup lifecycle. Guarded by @pending_mutex.
    @subagent_registry : SubagentRegistry?

    # Session history positions and replays. Guarded by @pending_mutex.
    @cursor_registry : CursorRegistry?

    @terminal_auth_running = Atomic(Bool).new(false)

    # An agent request whose handler hasn't answered yet. Compared by
    # identity, so a duplicate ID can't claim another request's answer.
    private class InFlightRequest
      getter method : String
      getter session_id : String?

      # Set (under `@pending_mutex`) when a cancel answered the request.
      property? answered : Bool = false

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
    # - `client_capabilities` — client capabilities to advertise. Default: minimal.
    # - `client_info` — full implementation metadata to send during initialization.
    def initialize(
      @transport : Transport,
      client_name : String = "acp-crystal",
      client_version : String = ACP::VERSION,
      @client_capabilities : Protocol::ClientCapabilities = Protocol::ClientCapabilities.new,
      *,
      client_info : Protocol::ClientInfo? = nil,
      @mcp_request_limit : Int32 = 32,
    )
      @client_info = client_info || Protocol::ClientInfo.new(client_name, client_version)
      @mcp_provider = McpProvider.new(@transport, @mcp_request_limit)
      @session_choices = SessionChoices.new(v2_wire?)
      @subagent_registry = SubagentRegistry.new(v2: v2_wire?) if v2_wire? || @client_capabilities.subagents
      @cursor_registry = CursorRegistry.new(v2: v2_wire?) if v2_wire? || @client_capabilities.session.try(&.cursors)
      start_dispatcher
    end

    # Registers an MCP handler on this connection. Include the declaration in
    # session setup to let the Agent make requests to it.
    def register_mcp_server(name : String, *, meta : Hash(String, JSON::Any)? = nil, &handler : McpRequestHandler) : Protocol::McpServerAcp
      @mcp_provider.register(name, meta, handler)
    end

    # Retires the registration and signals cancellation to its active handlers.
    def unregister_mcp_server(server_id : Protocol::McpServerAcpId) : Bool
      @mcp_provider.release(server_id)
    end

    private def v2_wire? : Bool
      false
    end

    protected def v2_initialization_result : Protocol::V2::InitializeResult?
      @pending_mutex.synchronize { @v2_initialization_result }
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

      result = send_typed_request(Protocol::AgentMethod::INITIALIZE, params, Protocol::InitializeResult)

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
      @v1_boolean_config_supported = !!params.client_capabilities.session.try(&.config_options).try(&.boolean)
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

      # A terminal descriptor can never be passed to the protocol method.
      # Inspect its discriminator even if its other fields could not decode.
      method = @auth_methods.try(&.find { |entry| entry.as_h?.try(&.["id"]?).try(&.as_s?) == method_id })
      raise InvalidStateError.new("Authentication method #{method_id.inspect} was not advertised") unless method
      if (kind = method["type"]?) && !kind.raw.nil? && kind.as_s? != "agent"
        raise InvalidStateError.new("Authentication method #{method_id.inspect} requires a different flow")
      end

      params = Protocol::AuthenticateParams.new(method_id, credentials)
      send_request(Protocol::AgentMethod::AUTHENTICATE, params)

      ClientLog.info { "Authenticated with method: #{method_id}" }
    end

    # Decoded authentication methods from the initialize handshake.
    def typed_auth_methods : Array(Protocol::AuthenticationMethod)
      Protocol.typed_auth_methods(@auth_methods)
    end

    # Runs an advertised terminal login, then returns a new initialized client.
    # The approval block receives the additional arguments and environment to
    # present to the user. Declining or a failed login preserves this connection.
    # Requires a ProcessTransport, terminal auth capability, and no active session.
    def authenticate_terminal(method_id : String, &approve : Protocol::TerminalAuthMethod -> Bool) : Client
      _, started = @terminal_auth_running.compare_and_set(false, true)
      raise InvalidStateError.new("Terminal authentication is already in progress") unless started

      begin
        authenticate_terminal_flow(method_id, approve)
      ensure
        @terminal_auth_running.set(false)
      end
    end

    private def authenticate_terminal_flow(method_id : String, approve : Protocol::TerminalAuthMethod -> Bool) : Client
      unless @state == ClientState::Initialized
        raise InvalidStateError.new("Terminal authentication requires an initialized connection before session setup")
      end
      unless @client_capabilities.auth.try(&.terminal?) && (process_transport = @transport.as?(ProcessTransport))
        raise InvalidStateError.new("Terminal authentication requires an advertised capability and a process transport")
      end

      method = typed_auth_methods.find { |candidate| candidate.id == method_id }.as?(Protocol::TerminalAuthMethod)
      raise InvalidStateError.new("Unknown terminal authentication method #{method_id.inspect}") unless method
      raise AuthenticationError.new("Terminal authentication declined") unless approve.call(method)
      ensure_terminal_auth_state

      status = process_transport.run_terminal_authentication(method)
      raise AuthenticationError.new("Terminal authentication exited unsuccessfully") unless status.success?
      ensure_terminal_auth_state

      replacement = Client.new(process_transport.reconnect, client_capabilities: @client_capabilities,
        client_info: @client_info, mcp_request_limit: @mcp_request_limit)
      replacement.request_timeout = @request_timeout
      replacement.prompt_timeout = @prompt_timeout
      replacement.on_update = @on_update
      replacement.on_agent_request = @on_agent_request
      replacement.on_notification = @on_notification
      replacement.on_disconnect = @on_disconnect
      replacement.on_auth_status_update = @on_auth_status_update
      replacement.on_system_prompt_mode = @on_system_prompt_mode
      replacement.on_read_text_file = @on_read_text_file
      replacement.on_write_text_file = @on_write_text_file
      replacement.on_create_terminal = @on_create_terminal
      replacement.on_terminal_output = @on_terminal_output
      replacement.on_release_terminal = @on_release_terminal
      replacement.on_wait_for_terminal_exit = @on_wait_for_terminal_exit
      replacement.on_kill_terminal = @on_kill_terminal
      replacement.on_create_elicitation = @on_create_elicitation
      replacement.on_elicitation_complete = @on_elicitation_complete

      begin
        replacement.initialize_connection
        ensure_terminal_auth_state
        close
      rescue ex
        replacement.close rescue nil
        raise ex
      end

      replacement
    end

    private def ensure_terminal_auth_state : Nil
      unless @state == ClientState::Initialized
        raise InvalidStateError.new("Client state changed during terminal authentication")
      end
    end

    # Ends the current authenticated state with the agent (`logout`).
    #
    # Requires the agent to advertise `agentCapabilities.auth.logout`.
    # Afterwards, new sessions that need authentication require
    # `authenticate` again, and active sessions may start failing with
    # auth errors. Local client state is left unchanged.
    #
    # Raises `InvalidStateError` if not initialized.
    # See: https://agentclientprotocol.com/protocol/v1/authentication#logging-out
    def logout : Protocol::LogoutResult
      ensure_state(ClientState::Initialized, "logout")
      unless @agent_capabilities.try(&.auth).try(&.logout?)
        raise InvalidStateError.new("The Agent did not advertise logout")
      end

      raw_result = send_request(Protocol::AgentMethod::LOGOUT, Protocol::LogoutParams.new)
      result = decode_result(Protocol::LogoutResult, raw_result, Protocol::AgentMethod::LOGOUT)

      ClientLog.info { "Logged out" }

      result
    end

    # Queries the Agent's draft authentication status when it advertises support.
    def auth_status(params : Protocol::AuthStatusParams = Protocol::AuthStatusParams.new) : Protocol::AuthStatusResult
      ensure_state(ClientState::Initialized, Protocol::AgentMethod::AUTH_STATUS)
      unless @agent_capabilities.try(&.auth).try(&.status)
        raise InvalidStateError.new("The Agent did not advertise auth.status")
      end

      method = Protocol::AgentMethod::AUTH_STATUS
      decode_result(Protocol::AuthStatusResult, send_request(method, params), method)
    end

    # Lists the Agent's configurable model providers and current routing.
    def providers_list(params : Protocol::ListProvidersParams = Protocol::ListProvidersParams.new) : Protocol::ListProvidersResult
      method = Protocol::AgentMethod::PROVIDERS_LIST
      ensure_provider_support(method)
      send_typed_request(method, params, Protocol::ListProvidersResult)
    end

    # Replaces the full routing configuration for one provider.
    def providers_set(params : Protocol::SetProviderParams) : Protocol::SetProviderResult
      method = Protocol::AgentMethod::PROVIDERS_SET
      ensure_provider_support(method)
      send_typed_request(method, params, Protocol::SetProviderResult)
    end

    # Disables a provider after checking that the Agent does not require it.
    def providers_disable(params : Protocol::DisableProviderParams) : Protocol::DisableProviderResult
      method = Protocol::AgentMethod::PROVIDERS_DISABLE
      ensure_provider_support(method)
      if providers_list.required?(params.provider_id)
        raise InvalidStateError.new("The Agent requires this provider")
      end
      send_typed_request(method, params, Protocol::DisableProviderResult)
    end

    # Disables the specified non-mandatory provider.
    def providers_disable(provider_id : Protocol::ProviderId) : Protocol::DisableProviderResult
      providers_disable(Protocol::DisableProviderParams.new(provider_id))
    end

    private def ensure_provider_support(method : String) : Nil
      ensure_state(ClientState::Initialized, method)
      unless @agent_capabilities.try(&.providers)
        raise InvalidStateError.new("The Agent did not advertise providers")
      end
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
      config_options : Array(Protocol::InitialSessionConfigOption)? = nil,
    ) : Protocol::SessionNewResult
      ensure_state(ClientState::Initialized, "session/new")
      validate_session_setup(cwd, additional_directories, system_prompt, mcp_servers, config_options)

      params = Protocol::SessionNewParams.new(cwd, mcp_servers,
        additional_directories: additional_directories, system_prompt: system_prompt, config_options: config_options)
      result = attach_session(Protocol::AgentMethod::SESSION_NEW, params, Protocol::SessionNewResult)

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
      config_options : Array(Protocol::InitialSessionConfigOption)? = nil,
    ) : Protocol::SessionLoadResult
      ensure_state(ClientState::Initialized, "session/load")
      unless @agent_capabilities.try(&.load_session?)
        raise InvalidStateError.new("The Agent did not advertise loadSession")
      end
      validate_session_setup(cwd, additional_directories, system_prompt, mcp_servers, config_options)

      params = Protocol::SessionLoadParams.new(session_id, cwd, mcp_servers,
        additional_directories: additional_directories, system_prompt: system_prompt, config_options: config_options)
      result = attach_session(Protocol::AgentMethod::SESSION_LOAD, params, Protocol::SessionLoadResult, session_id)

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
    # - `archived` — optional archive filter when the agent supports archiving.
    #
    # Returns the list result with sessions and optional next cursor.
    #
    # Raises `InvalidStateError` if not initialized.
    # See: https://agentclientprotocol.com/protocol/session-setup#listing-sessions
    def session_list(
      cwd : String? = nil,
      cursor : String? = nil,
      *,
      archived : String? = nil,
    ) : Protocol::SessionListResult
      ensure_state(ClientState::Initialized, "session/list")
      unless @agent_capabilities.try(&.session_capabilities).try(&.list?)
        raise InvalidStateError.new("The Agent did not advertise sessionCapabilities.list")
      end
      if cwd && !Protocol.absolute_path?(cwd)
        raise ArgumentError.new("The ACP session list directory must be absolute")
      end
      ensure_archive_support("session/list") if archived

      params = Protocol::SessionListParams.new(cwd: cwd, cursor: cursor, archived: archived)
      send_typed_request(Protocol::AgentMethod::SESSION_LIST, params, Protocol::SessionListResult, exact_response: true)
    end

    # Previews options before creating or restoring a session.
    def session_options(params : Protocol::SessionOptionsParams) : Protocol::SessionOptionsResult
      method = Protocol::AgentMethod::SESSION_OPTIONS
      ensure_state(ClientState::Initialized, method)
      agent = @agent_capabilities
      caps = agent.try(&.session_capabilities)
      raise InvalidStateError.new("The Agent did not advertise sessionCapabilities.options") unless caps.try(&.options)
      if params.session_id && !(agent.try(&.load_session?) || caps.try(&.resume) || caps.try(&.fork))
        raise InvalidStateError.new("The Agent did not advertise session load, resume, or fork")
      end
      unless Protocol.absolute_workspace?(params.cwd, params.additional_directories)
        raise ArgumentError.new("ACP session directories must be absolute")
      end

      send_typed_request(method, params, Protocol::SessionOptionsResult)
    end

    # Previews options for a new session in the given workspace.
    def session_options(cwd : String) : Protocol::SessionOptionsResult
      session_options(Protocol::SessionOptionsParams.new(cwd))
    end

    # Forks a session and makes the returned session active on this client.
    def session_fork(params : Protocol::SessionForkParams) : Protocol::SessionForkResult
      method = Protocol::AgentMethod::SESSION_FORK
      ensure_state(ClientState::Initialized, method)
      agent = @agent_capabilities
      caps = agent.try(&.session_capabilities)
      unless caps && caps.fork
        raise InvalidStateError.new("The Agent did not advertise sessionCapabilities.fork")
      end
      validate_session_setup(params.cwd, params.additional_directories, params.system_prompt,
        params.mcp_servers, params.config_options)

      attach_session(method, params, Protocol::SessionForkResult)
    end

    # Forks a source session into the given working directory.
    def session_fork(session_id : String, cwd : String, *, cursor_id : String? = nil) : Protocol::SessionForkResult
      session_fork(Protocol::SessionForkParams.new(session_id, cwd, cursor_id: cursor_id))
    end

    # Queries a session without attaching to it. Requires draft status support.
    def session_status(session_id : String, *, meta : Hash(String, JSON::Any)? = nil) : Protocol::SessionStatusResult
      method = Protocol::AgentMethod::SESSION_STATUS
      ensure_state(ClientState::Initialized, method)
      unless @agent_capabilities.try(&.session_capabilities).try(&.status)
        raise InvalidStateError.new("The Agent did not advertise sessionCapabilities.status")
      end

      send_typed_request(method, Protocol::SessionStatusParams.new(session_id, meta), Protocol::SessionStatusResult)
    end

    # Sets the title of a session and returns the title the Agent stored.
    def session_set_title(session_id : String, title : String, *, meta : Hash(String, JSON::Any)? = nil) : Protocol::SetSessionTitleResult
      method = Protocol::AgentMethod::SESSION_SET_TITLE
      ensure_state(ClientState::Initialized, method)
      unless @agent_capabilities.try(&.session_capabilities).try(&.title)
        raise InvalidStateError.new("The Agent did not advertise sessionCapabilities.title")
      end

      send_typed_request(method, Protocol::SetSessionTitleParams.new(session_id, title, meta), Protocol::SetSessionTitleResult)
    end

    # Closes and archives the session while preserving its saved history.
    def session_archive(session_id : String, *, meta : Hash(String, JSON::Any)? = nil) : Protocol::SessionArchiveResult
      method = Protocol::AgentMethod::SESSION_ARCHIVE
      ensure_archive_support(method)
      send_typed_request(method, Protocol::SessionArchiveParams.new(session_id, meta), Protocol::SessionArchiveResult)
    end

    # Restores the session to default list results without attaching to it.
    def session_unarchive(session_id : String, *, meta : Hash(String, JSON::Any)? = nil) : Protocol::SessionUnarchiveResult
      method = Protocol::AgentMethod::SESSION_UNARCHIVE
      ensure_archive_support(method)
      send_typed_request(method, Protocol::SessionUnarchiveParams.new(session_id, meta), Protocol::SessionUnarchiveResult)
    end

    private def ensure_archive_support(method : String) : Nil
      ensure_state(ClientState::Initialized, method)
      unless @agent_capabilities.try(&.session_capabilities).try(&.archive)
        raise InvalidStateError.new("The Agent did not advertise sessionCapabilities.archive")
      end
    end

    private def validate_session_setup(
      cwd : String, directories : Array(String)?, prompt : Protocol::SystemPrompt?,
      servers : Array(JSON::Any)?, config_options : Array(Protocol::InitialSessionConfigOption)?,
    ) : Nil
      unless Protocol.absolute_workspace?(cwd, directories)
        raise ArgumentError.new("ACP session directories must be absolute")
      end

      caps = @agent_capabilities.try(&.session_capabilities)
      if directories && !caps.try(&.additional_directories?)
        raise InvalidStateError.new("The Agent did not advertise additionalDirectories")
      end
      if prompt
        support = caps.try(&.system_prompt) || raise InvalidStateError.new("The Agent did not advertise systemPrompt")
        unless support.supports_mode?(prompt.mode, @on_system_prompt_mode)
          raise InvalidStateError.new("The Agent did not advertise systemPrompt #{prompt.mode.inspect}")
        end
        if prompt.content.empty? || !prompt.content.all?(Protocol::TextContentBlock)
          raise ArgumentError.new("ACP system prompts require one or more text content blocks")
        end
      end
      validate_initial_config_options(config_options) if config_options
      validate_session_mcp_servers(servers) if servers
    end

    private def validate_session_mcp_servers(servers : Array(JSON::Any)) : Nil
      caps = @agent_capabilities.try(&.mcp_capabilities)
      servers.each do |server|
        fields = server.as_h? || raise ArgumentError.new("ACP MCP servers must be objects")
        type = fields["type"]?
        unless type.nil? || type.raw.nil? || type.as_s?
          raise ArgumentError.new("ACP MCP transport type must be a string")
        end

        transport = type.try(&.as_s?) || "stdio"
        next unless transport.in?("stdio", "http", "sse")

        unless fields["name"]?.try(&.as_s?)
          raise ArgumentError.new("ACP MCP servers require a string name")
        end
        if transport == "stdio"
          command = fields["command"]?.try(&.as_s?)
          unless command && Protocol.absolute_path?(command)
            raise ArgumentError.new("ACP MCP stdio commands must be absolute")
          end
          unless mcp_list(fields, "args").all?(&.as_s?)
            raise ArgumentError.new("ACP MCP args must contain strings")
          end
          validate_mcp_named_values(fields, "env")
        else
          supported = transport == "http" ? caps.try(&.http?) : caps.try(&.sse?)
          raise InvalidStateError.new("The Agent did not advertise MCP #{transport.upcase}") unless supported

          validate_mcp_url(fields["url"]?.try(&.as_s?))
          validate_mcp_named_values(fields, "headers")
        end
      end
    end

    private def mcp_list(fields : Hash(String, JSON::Any), key : String) : Array(JSON::Any)
      value = fields[key]? || raise ArgumentError.new("ACP MCP servers require #{key}")
      return [] of JSON::Any if value.raw.nil?

      value.as_a? || raise ArgumentError.new("ACP MCP #{key} must be an array")
    end

    private def validate_mcp_named_values(fields : Hash(String, JSON::Any), key : String) : Nil
      unless mcp_list(fields, key).all? { |entry| (pair = entry.as_h?) && pair["name"]?.try(&.as_s?) && pair["value"]?.try(&.as_s?) }
        raise ArgumentError.new("ACP MCP #{key} entries require string names and values")
      end
    end

    private def validate_mcp_url(value : String?) : Nil
      if value && valid_uri_text?(value)
        uri = URI.parse(value)
        port = uri.port
        if uri.scheme.try(&.downcase).in?("http", "https") && valid_uri_text?(uri.host.to_s) &&
           (!port || (0..65535).includes?(port))
          return
        end
      end
      raise ArgumentError.new("ACP MCP HTTP and SSE servers require an absolute HTTP(S) URL")
    rescue URI::Error | OverflowError
      raise ArgumentError.new("ACP MCP HTTP and SSE servers require an absolute HTTP(S) URL")
    end

    private def valid_uri_text?(value : String) : Bool
      !value.empty? && value.each_byte.none? { |byte| byte <= 32 || byte == 127 }
    end

    private def validate_initial_config_options(values : Array(Protocol::InitialSessionConfigOption)) : Nil
      unless @agent_capabilities.try(&.session_capabilities).try(&.options)
        raise InvalidStateError.new("The Agent did not advertise sessionCapabilities.options")
      end
      Protocol.validate_initial_config_options(values)
      if values.any? { |option| option.value_type == "boolean" } && !@client_capabilities.session.try(&.config_options).try(&.boolean)
        raise InvalidStateError.new("The Client did not advertise boolean config options")
      end
    end

    # Resumes an existing session by ID without replaying conversation history.
    #
    # Unlike `session/load`, the agent will NOT emit `session/update`
    # notifications to replay prior turns — it just restores context,
    # reconnects to the requested MCP servers, and returns once the
    # session is ready to continue.
    #
    # Requires the agent to advertise `sessionCapabilities.resume` during
    # initialization.
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
      config_options : Array(Protocol::InitialSessionConfigOption)? = nil,
    ) : Protocol::SessionResumeResult
      ensure_state(ClientState::Initialized, "session/resume")
      unless @agent_capabilities.try(&.session_capabilities).try(&.resume?)
        raise InvalidStateError.new("The Agent did not advertise sessionCapabilities.resume")
      end
      validate_session_setup(cwd, additional_directories, system_prompt, mcp_servers, config_options)

      params = Protocol::SessionResumeParams.new(session_id, cwd, mcp_servers,
        additional_directories: additional_directories, system_prompt: system_prompt, config_options: config_options)
      result = attach_session(Protocol::AgentMethod::SESSION_RESUME, params, Protocol::SessionResumeResult, session_id)

      ClientLog.info { "Session resumed: #{session_id}" }

      result
    end

    # Closes an active session, asking the agent to cancel any ongoing
    # work and release resources tied to the session.
    #
    # Requires the agent to advertise `sessionCapabilities.close` during
    # initialization.
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
      unless @agent_capabilities.try(&.session_capabilities).try(&.close?)
        raise InvalidStateError.new("The Agent did not advertise sessionCapabilities.close")
      end

      params = Protocol::SessionCloseParams.new(sid)
      result = send_session_retirement_request(Protocol::AgentMethod::SESSION_CLOSE, params, Protocol::SessionCloseResult)

      ClientLog.info { "Session closed: #{sid}" }

      result
    end

    # Removes a session from the agent's session history, so it no longer
    # appears in `session/list` results.
    #
    # Requires the agent to advertise `sessionCapabilities.delete`.
    # A `-32002` (resource not found) answer counts as success, as the spec
    # recommends. What happens to an active session is up to the agent, so
    # the client's cached session state is left alone (see `forget_session`).
    #
    # Raises `InvalidStateError` if not initialized.
    # See: https://agentclientprotocol.com/protocol/v1/session-delete
    def session_delete(session_id : String) : Protocol::SessionDeleteResult
      ensure_state(ClientState::Initialized, "session/delete")
      unless @agent_capabilities.try(&.session_capabilities).try(&.delete?)
        raise InvalidStateError.new("The Agent did not advertise sessionCapabilities.delete")
      end

      params = Protocol::SessionDeleteParams.new(session_id)
      result = send_session_retirement_request(Protocol::AgentMethod::SESSION_DELETE, params, Protocol::SessionDeleteResult)

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
      @pending_mutex.synchronize do
        @plan_ids.delete(session_id)
        @early_plan_sessions.delete(session_id)
        @session_choices.drop(session_id)
        @subagent_registry.try(&.drop_runtime(session_id))
        forget_active_session(session_id)
      end
    end

    private def forget_active_session(session_id : String) : Bool
      return false unless @session_id == session_id

      @session_id = nil
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
    # Returns the stop reason and any token usage reported by the agent.
    #
    # Raises `NoActiveSessionError` if no session is active.
    def session_prompt(
      prompt : Array(Protocol::ContentBlock),
      session_id : String? = nil,
    ) : Protocol::SessionPromptResult
      sid = session_id || @session_id
      raise NoActiveSessionError.new unless sid
      raise InvalidStateError.new("ACP initialization is required") if @state.created?

      caps = @agent_capabilities.try(&.prompt_capabilities)
      prompt.each do |block|
        case block.type
        when "image"
          raise InvalidStateError.new("The Agent did not advertise image prompts") unless caps.try(&.image?)
        when "audio"
          raise InvalidStateError.new("The Agent did not advertise audio prompts") unless caps.try(&.audio?)
        when "resource"
          raise InvalidStateError.new("The Agent did not advertise embedded context") unless caps.try(&.embedded_context?)
        end
      end

      params = Protocol::SessionPromptParams.new(sid, prompt)

      # Use a longer timeout for prompts since they can take a while.
      send_typed_request(Protocol::AgentMethod::SESSION_PROMPT, params, Protocol::SessionPromptResult, timeout: @prompt_timeout)
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

      params = Protocol::SessionCancelParams.new(sid)
      send_notification(Protocol::AgentMethod::SESSION_CANCEL, params)

      ClientLog.info { "Sent cancel for session: #{sid}" }
    end

    # The effective state of an announced child session, if subagents are enabled.
    def subagent(session_id : String) : SubagentSession?
      @pending_mutex.synchronize { @subagent_registry.try(&.snapshot(session_id)) }
    end

    # Child sessions announced under this parent, when subagents are enabled.
    def subagents(parent_id : String) : Array(SubagentSession)
      @pending_mutex.synchronize { @subagent_registry.try(&.children(parent_id)) || [] of SubagentSession }
    end

    # Effective workspace roots inherited by a session, when subagents are
    # enabled and an enclosing workspace is known. Use these in request
    # handlers together with your application's workspace policy.
    def session_workspace(session_id : String) : SessionWorkspace?
      @pending_mutex.synchronize { @subagent_registry.try(&.workspace(session_id)) }
    end

    # Returns an announced history cursor scoped to one session.
    def session_cursor(session_id : String, cursor_id : String) : SessionCursor?
      @pending_mutex.synchronize { @cursor_registry.try(&.cursor(session_id, cursor_id)) }
    end

    # Returns the stored cursor snapshots for a session.
    def session_cursors(session_id : String) : Array(SessionCursor)
      @pending_mutex.synchronize { @cursor_registry.try(&.cursors(session_id)) || [] of SessionCursor }
    end

    # Changes the mode for the active session.
    #
    # - `mode_id` — the mode ID to switch to.
    # - `session_id` — optional session ID override.
    def session_set_mode(mode_id : String, session_id : String? = nil) : Nil
      sid = session_id || @session_id
      raise NoActiveSessionError.new unless sid

      params = Protocol::SessionSetModeParams.new(sid, mode_id)
      send_choice_request(Protocol::AgentMethod::SESSION_SET_MODE, params, Protocol::SessionSetModeResult)

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
      result = send_choice_request(Protocol::AgentMethod::SESSION_SET_CONFIG_OPTION, params, Protocol::SessionSetConfigOptionResult)

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

      # Cut off all pending requests; their callers raise ConnectionClosedError.
      drain_pending_requests

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
      response_result(send_and_await_response(method, message_builder, timeout), method)
    end

    # Decodes from original JSON for wide results and requests that need exact values.
    protected def send_typed_request(method : String, params : JSON::Serializable, type : T.class,
                                     *, timeout : Float64? = @request_timeout, exact_response : Bool = false) : T forall T
      message_builder = ->(id : Int64) { Protocol.build_request(id, method, params) }
      response = send_and_await_response(method, message_builder, timeout,
        check_fork_cursor: method == Protocol::AgentMethod::SESSION_FORK, exact_response: exact_response)
      decode_typed_response(method, response, type)
    end

    # Close and delete are idempotent when the Agent reports a missing session.
    protected def send_session_retirement_request(method : String, params : JSON::Serializable, type : T.class) : T forall T
      message_builder = ->(id : Int64) { Protocol.build_request(id, method, params) }
      response = send_and_await_response(method, message_builder)
      return T.new if missing_session_response?(response)

      decode_typed_response(method, response, type)
    end

    private def decode_typed_response(method : String, response : PendingResponse, type : T.class) : T forall T
      if response.is_a?(Protocol::WireFrame) && !Protocol::WireFrame.field(response.json, "error")
        return decode_result_json(type, Protocol::WireFrame.field(response.json, "result") || "null", method)
      end
      decode_result_json(type, Protocol::WireFrame.encode(response_result(response, method)), method)
    end

    # Sends a JSON-RPC notification (no response expected).
    #
    # - `method` — the notification method name.
    # - `params` — the notification parameters.
    def send_notification(method : String, params : JSON::Serializable) : Nil
      raise ConnectionClosedError.new if closed?

      message = Protocol.build_notification(method, params)
      send_client_notification(method, message)

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
      response_result(send_and_await_response(method, message_builder, timeout), method)
    end

    # Sends a JSON-RPC notification with raw JSON::Any params (no response expected).
    #
    # - `method` — the notification method name.
    # - `params` — the notification parameters as raw JSON::Any.
    def send_notification_raw(method : String, params : JSON::Any) : Nil
      raise ConnectionClosedError.new if closed?

      message = Protocol.build_notification_raw(method, params)
      send_client_notification(method, message)

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
      write_client_message(message)

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
      write_client_message(message)

      ClientLog.debug { "Sent error response to agent request id=#{id} code=#{code}" }
    end

    # ─── Private Methods ────────────────────────────────────────────

    protected def send_choice_request(method : String, params : JSON::Serializable, type : T.class) : T forall T
      message_builder = ->(id : Int64) { Protocol.build_request(id, method, params) }
      response = send_and_await_response(method, message_builder, validate_choice: true, exact_response: v2_wire?)
      decode_typed_response(method, response, type)
    end

    # Commits attachment before dispatching later frames such as archive.
    private def attach_session(method : String, params : JSON::Serializable, type : T.class, session_id : String? = nil) : T forall T
      send_cached_request(method, params, type) do |attached, wire|
        attached_id = attached.is_a?(Protocol::SessionNewResult) ? attached.session_id : session_id
        if attached_id && !closed?
          @known_session_ids.add(attached_id)
          @session_id = attached_id
          @session_choices.replace(attached_id, wire, reattach: !session_id.nil?)
          @state = ClientState::SessionActive
        end
      end
    end

    # Applies an internal cache update in wire order after a result decodes.
    private def send_cached_request(method : String, params : JSON::Serializable, type : T.class, &apply : T, String -> Nil) : T forall T
      message_builder = ->(id : Int64) { Protocol.build_request(id, method, params) }
      decoded = nil
      observe = ->(payload : String) do
        begin
          result = T.from_json(payload)
          apply.call(result, payload)
          decoded = result
        rescue JSON::Error
          # Leave the cache alone. The waiting caller reports the decoding error.
        end
        nil
      end

      exact_response = v2_wire? || method.in?(Protocol::AgentMethod::SESSION_NEW, Protocol::AgentMethod::SESSION_FORK)
      response = send_and_await_response(method, message_builder, on_result: observe,
        check_fork_cursor: method == Protocol::AgentMethod::SESSION_FORK, exact_response: exact_response)
      cached_result = decoded
      return cached_result if cached_result

      decode_typed_response(method, response, type)
    end

    # Core implementation for sending a JSON-RPC request and awaiting
    # its response. Both `send_request` and `send_request_raw` delegate
    # to this method, differing only in how they build the message.
    #
    # - `method` — the RPC method name (used for logging and error messages).
    # - `message_builder` — a proc that receives the request ID and returns
    #   the serialized message hash ready for transport.
    # - `timeout` — optional timeout in seconds (nil = no timeout).
    # - `on_result` — internal cache update from a successful result's JSON.
    # - `on_response` — internal observer for a correlated response envelope.
    # - `validate_choice` — checks advertised choices just before a setter is written.
    # - `wire_params` — exact params to send alongside a separate JSON::Any routing view.
    #
    # Returns the correlated response envelope.
    # Raises `RequestTimeoutError` if the request times out.
    # Raises `ConnectionClosedError` if the transport is closed.
    private def send_and_await_response(
      method : String,
      message_builder : Int64 -> Hash(String, JSON::Any),
      timeout : Float64? = @request_timeout,
      *,
      on_result : (String -> Nil)? = nil,
      on_response : (PendingResponse -> Nil)? = nil,
      check_fork_cursor : Bool = false,
      validate_choice : Bool = false,
      exact_response : Bool = false,
      before_send : (-> Nil)? = nil,
      wire_params : Protocol::RawJson? = nil,
    ) : PendingResponse
      raise ConnectionClosedError.new if closed?

      # Generate a unique ID and build the frame before registering it.
      # Serialization can fail without leaving a request or setup pending.
      response_channel = Channel(PendingResponse).new(1)

      id = @pending_mutex.synchronize do
        raise ConnectionClosedError.new if @disconnected
        current_id = @next_id
        @next_id += 1
        current_id
      end
      id_str = id.to_s
      message = message_builder.call(id)
      if wire_params
        envelope = JSON.build do |json|
          json.object do
            message.each do |key, value|
              if key == "params"
                json.field(key, wire_params)
              else
                json.field(key, value)
              end
            end
          end
        end
        wire_frame = Protocol::WireFrame.new(envelope, exact_params: true)
      end
      params = message["params"]?.try(&.as_h?)
      mcp_servers = mcp_declarations(method, params)
      close_on_missing = method == Protocol::AgentMethod::SESSION_CLOSE ||
                         (v2_wire? && method == Protocol::AgentMethod::SESSION_DELETE)
      if close_on_missing || method == Protocol::AgentMethod::SESSION_ARCHIVE
        closing_session = params.try(&.["sessionId"]?).try(&.as_s?)
      end
      if method == Protocol::AgentMethod::SESSION_FORK
        fork_source = params.try(&.["sessionId"]?).try(&.as_s?)
        creating_session = method if fork_source
      elsif method == Protocol::AgentMethod::SESSION_NEW
        creating_session = method
      end
      if !v2_wire? && method == Protocol::AgentMethod::SESSION_LOAD
        loading_session = params.try(&.["sessionId"]?).try(&.as_s?)
      end

      fork_cursor = nil
      initialize = method == Protocol::AgentMethod::INITIALIZE
      v2_request = v2_wire? && !initialize
      changes_choice = @session_choices.change_method?(method)
      v2_retirement_session = closing_session if v2_wire?
      state_setup = v2_wire? && method.in?(Protocol::AgentMethod::SESSION_NEW, Protocol::AgentMethod::SESSION_RESUME, Protocol::AgentMethod::SESSION_FORK)
      entity_cancel = @subagent_registry.try(&.entity_cancel?(method))
      arm_at_write = changes_choice || state_setup || entity_cancel || !v2_retirement_session.nil?
      @pending_mutex.synchronize do
        raise ConnectionClosedError.new if @disconnected
        check_v2_request_order(initialize) if v2_wire?
        fork_cursor = fork_cursor_grant(params) if check_fork_cursor
        begin
          @session_choices.start_attachment(id_str, method, params)
          start_cursor_replay(id_str, method, params)
          @subagent_registry.try(&.request_sent(id_str, method, params))
        rescue ex
          @session_choices.finish_attachment(id_str)
          @cursor_registry.try(&.finish_replay(id_str))
          raise ex
        end
        if loading_session && @suggestion_content_types
          @suggestion_loads[id_str] = loading_session
        end
        @pending[id_str] = PendingRequest.new(response_channel, closing_session, close_on_missing, creating_session, fork_source, fork_cursor,
          on_result, on_response, !arm_at_write, exact_response: exact_response)
        if initialize
          @initialize_request = id_str
          @v2_initialize_armed = false if v2_wire?
        end
      end
      begin
        if v2_wire? && initialize
          @transport.send_checked(message) do
            @pending_mutex.synchronize do
              raise ConnectionClosedError.new if @disconnected

              @v2_initialize_armed = true
            end
          end
        elsif wire_frame || fork_cursor || arm_at_write || before_send || mcp_servers
          preflight = -> do
            refresh_fork_grant(id_str, params) if fork_cursor
            before_send.try(&.call)
            @mcp_provider.publish(mcp_servers) if mcp_servers
            if arm_at_write
              @pending_mutex.synchronize do
                raise ConnectionClosedError.new if @disconnected

                if changes_choice
                  @session_choices.start_change(id_str, method, params, validate: validate_choice,
                    allow_boolean: v2_wire? || @v1_boolean_config_supported)
                end
                @subagent_registry.try(&.check_entity_cancel(method, params)) if entity_cancel
                if state_setup || v2_retirement_session
                  @session_lifecycle_order += 1
                end
                @subagent_registry.try(&.root_setup_written(id_str, @session_lifecycle_order)) if state_setup
                retirement_order = @session_lifecycle_order if v2_retirement_session
                @pending[id_str] = @pending[id_str].copy_with(armed: true, retirement_order: retirement_order)
              end
            end
            mark_v2_request_sent if v2_request
          end
          if wire_frame
            @transport.send_wire(wire_frame, &preflight)
          else
            @transport.send_checked(message, &preflight)
          end
        else
          mark_v2_request_sent if v2_request
          @transport.send(message)
        end
      rescue ex
        @pending_mutex.synchronize do
          @pending.delete(id_str)
          @session_choices.finish_attachment(id_str)
          @session_choices.finish_change(id_str)
          @initialize_request = nil if @initialize_request == id_str
          @suggestion_loads.delete(id_str)
          @subagent_registry.try(&.request_finished(id_str))
          settle_early_plan_sessions if creating_session
          @cursor_registry.try(&.finish_replay(id_str))
        end
        raise ex
      end

      ClientLog.debug { "Sent request id=#{id} method=#{method}" }

      # Wait for the response with optional timeout.
      begin
        if timeout
          receive_with_timeout(response_channel, timeout, id)
        else
          response_channel.receive
        end
      rescue Channel::ClosedError
        # `drain_pending_requests` closed it: the connection is gone.
        raise ConnectionClosedError.new("#{@user_closed ? "Client closed" : "Connection lost"} while waiting for response to #{method}")
      end
    end

    # Runs under the pending mutex so initialization and ordinary requests
    # cannot both reserve the next write.
    private def check_v2_request_order(initialize : Bool) : Nil
      raise ConnectionClosedError.new if @disconnected || @v2_contract_unknown.get

      if @initialize_request
        raise InvalidStateError.new("ACP v2 initialization is in progress")
      end

      if initialize
        if @v2_request_sent || @v2_request_operations > 0 || !@pending.empty?
          raise InvalidStateError.new("ACP v2 initialization must precede other requests")
        end
      elsif !@v2_initialization_result
        raise InvalidStateError.new("ACP v2 initialization is required")
      end
    end

    private def mark_v2_request_sent : Nil
      @pending_mutex.synchronize { @v2_request_sent = true }
    end

    # Only session setup can publish an MCP registration to the Agent.
    private def mcp_declarations(method : String, params : Hash(String, JSON::Any)?) : Array(String)?
      return unless method.in?(Protocol::AgentMethod::SESSION_NEW, Protocol::AgentMethod::SESSION_LOAD,
                      Protocol::AgentMethod::SESSION_RESUME, Protocol::AgentMethod::SESSION_FORK)
      return unless servers = params.try(&.["mcpServers"]?).try(&.as_a?)

      ids = servers.compact_map do |entry|
        next unless (fields = entry.as_h?) && fields["type"]?.try(&.as_s?) == "acp"

        unless fields["name"]?.try(&.as_s?) && (id = fields["serverId"]?.try(&.as_s?))
          raise ArgumentError.new("ACP MCP declarations require a name and server ID")
        end
        id
      end
      return if ids.empty?

      unless @pending_mutex.synchronize { @mcp_acp_supported }
        raise InvalidStateError.new("The Agent did not advertise MCP over ACP")
      end
      ids
    end

    # Rechecks the cursor once the transport is ready to write the request.
    private def refresh_fork_grant(request_id : String, params : Hash(String, JSON::Any)?) : Nil
      @pending_mutex.synchronize do
        pending = @pending[request_id]? || raise ConnectionClosedError.new("Fork request is no longer pending")
        @pending[request_id] = pending.copy_with(fork_cursor: fork_cursor_grant(params))
      end
    end

    # Runs under the pending-request mutex, immediately before registration.
    private def fork_cursor_grant(params : Hash(String, JSON::Any)?) : ForkCursorGrant?
      return unless params && (value = params["cursorId"]?) && !value.raw.nil?

      cursor_id = value.as_s? || raise ArgumentError.new("ACP fork cursor IDs must be strings")
      session_id = params["sessionId"]?.try(&.as_s?) || raise ArgumentError.new("ACP fork requires a source session ID")
      revision = @cursor_registry.try(&.fork_revision(session_id, cursor_id))
      unless revision
        raise InvalidStateError.new("Cursor #{cursor_id.inspect} does not currently permit forking session #{session_id.inspect}")
      end
      {session_id, cursor_id, revision}
    end

    private def response_result(raw_response : PendingResponse, method : String) : JSON::Any
      raise raw_response if raw_response.is_a?(ProtocolError)

      if raw_response.is_a?(Protocol::WireFrame)
        if error_json = Protocol::WireFrame.field(raw_response.json, "error")
          error = Protocol::RawJson.from_json(error_json)
          raise JsonRpcError.from_wire(error) if error.object?
          raise JsonRpcError.new(JsonRpcError::INTERNAL_ERROR, error.as_s? || "Unknown error")
        end
        raise ProtocolError.new("Response to '#{method}' contains a number outside the range of JSON::Any")
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

    # Checks child session permissions before sending a notification. Direct
    # session cancellation also claims and resolves pending user input.
    private def send_client_notification(method : String, message : Hash(String, JSON::Any)) : Nil
      sid = message["params"]?.try(&.as_h?).try(&.["sessionId"]?).try(&.as_s?)
      cancel = method == Protocol::AgentMethod::SESSION_CANCEL
      @pending_mutex.synchronize { check_session_notification(method, sid, cancel) }
      pending = nil
      if sid
        @transport.send_checked(message) do
          @pending_mutex.synchronize do
            check_session_notification(method, sid, cancel)
            if cancel && !v2_wire?
              pending = claim_session_inputs([sid], elicitations: !@subagent_registry.nil?)
            end
          end
        end
      else
        write_client_message(message)
      end
      if claimed = pending
        answer_cancelled_session_inputs(claimed)
      end
    end

    private def check_session_notification(method : String, session_id : String?, cancel : Bool) : Nil
      raise ConnectionClosedError.new if @disconnected || (v2_wire? && @v2_contract_unknown.get)
      if session_id && (registry = @subagent_registry) && registry.child?(session_id)
        unless cancel && registry.cancel?(session_id)
          raise InvalidStateError.new("#{method} is unavailable for child session #{session_id.inspect}")
        end
      end
    end

    private def write_client_message(message : Hash(String, JSON::Any)) : Nil
      if v2_wire?
        @transport.send_checked(message) do
          raise ConnectionClosedError.new if @v2_contract_unknown.get
        end
      else
        @transport.send(message)
      end
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
      decode_result_json(type, raw.to_json, method)
    end

    private def decode_result_json(type : T.class, json : String, method : String) : T forall T
      T.from_json(json)
    rescue ex : JSON::ParseException
      raise ProtocolError.new(
        "Agent returned a malformed result for '#{method}': #{ex.message}",
        ex
      )
    end

    # Closes every pending request channel and clears the pending map, so
    # each waiting caller raises `ConnectionClosedError`, and refuses new
    # requests from then on. Used during close and disconnect to unblock
    # callers. (A fake JSON-RPC error here would pose as an answer from the
    # agent.)
    private def drain_pending_requests(*, abort_mcp_writes : Bool = false) : Nil
      @mcp_provider.close(abort_writes: abort_mcp_writes)
      @pending_mutex.synchronize do
        @disconnected = true
        @pending.each_value { |request| request.response.close }
        @pending.clear
        @late_session_retirements.clear
        @initialize_request = nil
        @known_session_ids.clear
        @session_choices.clear
        @suggestion_loads.clear
        @plan_ids.clear
        @early_plan_sessions.clear
        @subagent_registry.try(&.clear)
        @cursor_registry.try(&.clear)
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
      channel : Channel(PendingResponse),
      timeout_seconds : Float64,
      request_id : Int64,
    ) : PendingResponse
      timeout_span = timeout_seconds.seconds

      select
      when response = channel.receive
        response
      when timeout(timeout_span)
        # Clean up the pending entry. If it is already gone, the response was
        # delivered (or the channel closed) after the timer fired: use that.
        initialization = false
        removed = @pending_mutex.synchronize do
          id = request_id.to_s
          pending = @pending.delete(id)
          if pending
            @session_choices.expire_attachment(id)
            @session_choices.expire_change(id)
            if (session_id = pending.closing_session) && (order = pending.retirement_order)
              @session_choices.retirement_timed_out(session_id) if retirement_applies?(session_id, order)
              @late_session_retirements[id] = LateSessionRetirement.new(session_id, order, pending.close_on_missing)
              @late_session_retirements.shift if @late_session_retirements.size > MAX_LATE_SESSION_RETIREMENTS
            end
            @subagent_registry.try(&.request_timed_out(id))
            settle_early_plan_sessions if pending.creating_session
            initialization = v2_wire? && @initialize_request == id
            @v2_contract_unknown.set(true) if initialization
          end
          # The Agent may still send history after a local timeout. Keep
          # staging cursors until the wire replay or response ends.
          pending
        end
        return channel.receive unless removed
        # Nobody waits for the answer any more: tell the agent it can stop.
        unless initialization
          begin
            cancel_request(request_id)
          rescue ex
            ClientLog.debug { "Could not send $/cancel_request for id=#{request_id}: #{ex.message}" }
          end
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

        frame = @transport.receive_frame
        break if frame.nil?

        begin
          # An agent request's outcome is recorded by its handler fiber.
          handling_request = case frame
                             in Protocol::WireFrame then dispatch_message(frame.project_for_routing, frame)
                             in JSON::Any           then dispatch_message(frame)
                             end
          @consecutive_dispatch_errors.set(0) unless handling_request
        rescue ex
          record_dispatch_failure(ex)
        end
      end

      @dispatcher_running = false

      # Notify pending requests that the connection is lost.
      drain_pending_requests(abort_mcp_writes: true)

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
    private def dispatch_message(msg : JSON::Any, wire_frame : Protocol::WireFrame? = nil) : Bool
      return false if v2_wire? && @v2_contract_unknown.get

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

      if obj["method"]?.try(&.as_s?) == Protocol::ClientMethod::MCP_MESSAGE
        handle_mcp_request(msg, wire_frame) if obj.has_key?("id")
        return false
      end

      if v2_wire? && obj["jsonrpc"]?.try(&.as_s?) != "2.0"
        if kind == Protocol::MessageKind::Response
          handle_response(msg, wire_frame, initialization_only: true)
        else
          reject_invalid_request("ACP v2 requires JSON-RPC 2.0")
        end
        return false
      end

      if v2_wire? && kind != Protocol::MessageKind::Response && !v2_initialization_result
        if kind == Protocol::MessageKind::Request
          respond_to_agent_error(Protocol.extract_id(msg), JsonRpcError::INVALID_REQUEST, "ACP v2 initialization is required")
        end
        return false
      end

      case kind
      when Protocol::MessageKind::Request
        if v2_wire? && obj["id"].raw.nil?
          reject_invalid_request("ACP v2 request IDs must be strings or integers")
          return false
        end
        # `session/update` is only ever a notification in ACP; some JSON-RPC
        # serializers write `"id": null` on notifications, so don't turn
        # those into a -32601 answer and lose the update.
        if obj["id"].raw.nil? && obj["method"].as_s == Protocol::AgentMethod::SESSION_UPDATE
          handle_notification(msg, wire_frame)
        else
          params_json = wire_frame.try(&.params_json)
          if wire_frame && obj["method"].as_s == Protocol::ClientMethod::SESSION_REQUEST_PERMISSION
            if v2_wire?
              params_json ||= Protocol::WireFrame.field(wire_frame.json, "params")
            elsif wire_frame.representable
              params_json = nil
            end
          end
          return handle_agent_request(msg, params_json)
        end
      when Protocol::MessageKind::Response
        handle_response(msg, wire_frame)
      when Protocol::MessageKind::Notification
        if obj["method"]?.try(&.as_s?)
          handle_notification(msg, wire_frame)
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

    # Handles the binding's request direction without blocking the dispatcher.
    private def handle_mcp_request(msg : JSON::Any, frame : Protocol::WireFrame?) : Nil
      unless msg["jsonrpc"]?.try(&.as_s?) == "2.0" && (id = Protocol.extract_id(msg))
        return @mcp_provider.reject_invalid_envelope
      end

      params = frame.try(&.params_json)
      params ||= Protocol::WireFrame.field(frame.json, "params") if frame
      collision = @pending_mutex.synchronize { @in_flight.has_key?(id) }
      @mcp_provider.receive(id, params || Protocol::WireFrame.encode(msg["params"]?), collision: collision)
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
    private def handle_response(msg : JSON::Any, wire_frame : Protocol::WireFrame? = nil, *, initialization_only : Bool = false) : Nil
      # All Client-issued IDs are integers. Read the response ID without
      # coercing numbers from a floating-point representation.
      unless id = msg["id"]?.try(&.as_i64?)
        ClientLog.warn { "Ignoring response without a usable integer JSON-RPC id" }
        return
      end

      repeated = wire_frame.try { |frame| Protocol::WireFrame.repeated_members(frame.json, *Protocol::WireFrame::RESPONSE_FIELDS) }
      if repeated.try(&.includes?("id"))
        ClientLog.warn { "Ignoring response with an ambiguous JSON-RPC id" }
        return
      end
      if malformed = response_outcome_error(msg, wire_frame, repeated)
        # Finish the request without exposing an invalid outcome to the cache observers.
        envelope = msg.as_h.dup
        envelope.delete("result")
        envelope.delete("error")
        msg = JSON::Any.new(envelope)
        wire_frame = nil
      end

      id_str = id.to_s

      # Take the entry out as the response is delivered: a request gets one
      # response (JSON-RPC 2.0 §5), and the channel holds exactly one, so a
      # repeated response must not reach it — sending a second or third copy
      # into the full channel would block the dispatcher for good.
      cancelled_inputs = nil
      wide_frame = wire_frame if wire_frame.try(&.wide_response?)
      error_frame = wire_frame if msg["error"]?
      response = malformed || error_frame || wide_frame || msg
      observed_reply = false
      channel = @pending_mutex.synchronize do
        initializing = v2_wire? && @initialize_request == id_str
        next if initialization_only && !initializing
        next if initializing && !@v2_initialize_armed

        next if (waiting = @pending[id_str]?) && !waiting.armed

        @cursor_registry.try(&.finish_replay(id_str, msg, wide_frame))
        @session_choices.finish_attachment(id_str)
        if observed_reply = @session_choices.change_pending?(id_str)
          @session_choices.finish_change(id_str, Protocol::WireFrame.result_json(msg, wire_frame))
        end
        @suggestion_loads.delete(id_str)
        if request = @pending.delete(id_str)
          response = wire_frame if request.exact_response && wire_frame && !msg["error"]?
          if (grant = request.fork_cursor) && response_error_code(msg) == JsonRpcError::INVALID_PARAMS
            @cursor_registry.try(&.reject_fork(*grant))
          end
          if !v2_wire? && @initialize_request == id_str
            @initialize_request = nil
            if result = Protocol::WireFrame.result_json(msg, wire_frame)
              observe_initialize_response(result)
            end
          end
          if error = created_session_response_error(request.creating_session, request.fork_source, msg, wire_frame)
            response = error
            @subagent_registry.try(&.request_finished(id_str))
          else
            retired_setup = @subagent_registry.try(&.retired_setup?(id_str))
            @subagent_registry.try(&.request_finished(id_str, msg, wire_frame))
            request.on_response.try(&.call(initializing && wire_frame ? wire_frame : response))
            if !retired_setup && (observer = request.on_result) && (result = Protocol::WireFrame.result_json(msg, wire_frame))
              observer.call(result)
            end
          end
          settle_early_plan_sessions if request.creating_session
          if (session_id = request.closing_session) && closes_session?(msg, request.close_on_missing)
            if (closed_sessions = apply_retirement(session_id, request.retirement_order)) && !v2_wire?
              cancelled_inputs = claim_session_inputs(closed_sessions, elicitations: true)
            end
          end
          request.response
        elsif retirement = @late_session_retirements.delete(id_str)
          observed_reply = true
          session_id = retirement.session_id
          if closes_session?(msg, retirement.close_on_missing)
            apply_retirement(session_id, retirement.write_order)
          elsif retirement_applies?(session_id, retirement.write_order) && response_error_code(msg)
            @session_choices.retirement_failed(session_id)
          end
          nil
        elsif resumed = @subagent_registry.try(&.finish_late_resume(id_str, msg, wire_frame, rejected: !response_error_code(msg).nil?))
          observed_reply = true
          session_id, result = resumed
          apply_session_choices(session_id, result, reattach: true) if result
          nil
        end
      end
      if channel
        begin
          answer_cancelled_session_inputs(cancelled_inputs) if cancelled_inputs
        ensure
          channel.send(response)
        end
      elsif !observed_reply
        ClientLog.warn { "Received response for unknown request id=#{id_str}" }
      end
    end

    private def response_outcome_error(msg : JSON::Any, frame : Protocol::WireFrame?, repeated : Set(String)?) : ProtocolError?
      if repeated && !repeated.empty?
        return ProtocolError.new("Ambiguous JSON-RPC response fields: #{repeated.join(", ")}")
      end

      error = msg["error"]?
      if msg["result"]?.nil? == error.nil?
        return ProtocolError.new("JSON-RPC response must contain exactly one of result or error")
      end

      if error && frame && (wire = Protocol::WireFrame.field(frame.json, "error"))
        repeated_error = Protocol::WireFrame.repeated_members(wire, "code", "message")
        unless repeated_error.empty?
          return ProtocolError.new("Ambiguous JSON-RPC error fields: #{repeated_error.join(", ")}")
        end
      end
    end

    # Checks newly allocated IDs before the workspace or capability cache can change.
    private def created_session_response_error(method : String?, source : String?, msg : JSON::Any, frame : Protocol::WireFrame?) : ProtocolError?
      return unless method && !msg["error"]?

      if frame && (payload = Protocol::WireFrame.result_json(msg, frame))
        unless Protocol::WireFrame.repeated_members(payload, "sessionId").empty?
          return ProtocolError.new("Ambiguous sessionId in the Agent's #{method} result")
        end
      end
      return unless id = msg["result"]?.try(&.as_h?).try(&.["sessionId"]?).try(&.as_s?)

      if id == source
        ProtocolError.new("The Agent returned the source session ID for session/fork")
      elsif @known_session_ids.includes?(id) || @subagent_registry.try(&.known_session?(id))
        ProtocolError.new("The Agent returned an existing session ID for #{method}")
      end
    end

    private def retirement_applies?(session_id : String, order : UInt64?) : Bool
      attached = @subagent_registry.try(&.attachment_order(session_id))
      !order || !attached || attached < order
    end

    protected def apply_session_choices(session_id : String, result : String, *, reattach : Bool) : Nil
      @session_choices.replace(session_id, result, reattach: reattach)
      @late_session_retirements.each_value do |retirement|
        if retirement.session_id == session_id && retirement_applies?(session_id, retirement.write_order)
          @session_choices.retirement_timed_out(session_id)
        end
      end
    end

    private def apply_retirement(session_id : String, order : UInt64?) : Array(String)?
      unless retirement_applies?(session_id, order)
        registry = @subagent_registry.not_nil!
        registry.discard_old_entity_grants(session_id, order.not_nil!)
        registry.runtime_session_ids(session_id).each { |sid| retire_plan_ids(sid, order) }
        return
      end

      closed_sessions = @subagent_registry.try(&.close_runtime(session_id, order)) || [session_id]
      closed_sessions.each do |sid|
        retire_plan_ids(sid, order)
        @session_choices.drop(sid)
      end
      forget_active_session(session_id)
      closed_sessions
    end

    # Close, archive, and v2 delete retire runtime in receive order.
    private def closes_session?(response : JSON::Any, close_on_missing : Bool) : Bool
      return false unless response["jsonrpc"]?.try(&.as_s?) == "2.0"

      if response["error"]?
        close_on_missing && missing_session_response?(response)
      else
        # These result objects have only optional metadata.
        !!response["result"]?.try(&.as_h?)
      end
    end

    private def missing_session_response?(response : PendingResponse) : Bool
      message = response.is_a?(Protocol::WireFrame) ? response.project_for_routing : response
      message.is_a?(JSON::Any) && response_error_code(message) == JsonRpcError::RESOURCE_NOT_FOUND
    end

    private def response_error_code(response : JSON::Any) : Int32?
      return unless response["jsonrpc"]?.try(&.as_s?) == "2.0" && !response["result"]?
      return unless (error = response["error"]?.try(&.as_h?)) && error["message"]?.try(&.as_s?)

      JsonRpcError.int32_code(error["code"]?.try(&.as_i64?))
    end

    # Runs under the pending-request mutex before releasing the initialize waiter.
    private def observe_initialize_response(result : String) : Nil
      typed = Protocol::InitializeResult.from_json(result)
      if ACP.supports_protocol_version?(typed.protocol_version)
        @mcp_acp_supported = typed.agent_capabilities.mcp_capabilities.try(&.acp?) || false
        @auth_status_supported = !typed.agent_capabilities.auth.try(&.status).nil?
        prompt = typed.agent_capabilities.prompt_capabilities
        @suggestion_content_types = @client_capabilities.session.try(&.prompt_suggestions).try &.content_types(
          image: prompt.try(&.image?) || false, audio: prompt.try(&.audio?) || false,
          embedded_context: prompt.try(&.embedded_context?) || false)
      end
    rescue JSON::ParseException
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
    private def handle_agent_request(msg : JSON::Any, params_json : String? = nil) : Bool
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
      if id && @mcp_provider.active_outer?(id)
        @mcp_provider.reject_collision
        return false
      end

      ClientLog.debug { "Agent request: method=#{method_name} id=#{id}" }

      # Track the request before handing it off, so a `session_cancel` or
      # `$/cancel_request` read right after it can still answer it.
      # A null-id request isn't tracked: every such request would share the
      # one `nil` key, and all but one would go unanswered.
      entry = nil
      unless id.nil?
        session_id = params.try(&.as_h?).try(&.["sessionId"]?).try(&.as_s?)
        entry = InFlightRequest.new(method_name, session_id)
        @pending_mutex.synchronize { @in_flight[id] = entry }
      end

      prepared = prepare_agent_request(id, method_name, params, params_json)
      spawn(name: "acp-agent-request") do
        reply = prepared ? prepared.call : route_agent_request(method_name, params, params_json)
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

    # Allows version-specific request handling to observe wire-ordered state
    # on the dispatcher before running the user handler on its own fiber.
    private def prepare_agent_request(id : Protocol::RequestId?, method_name : String, params : JSON::Any?, params_json : String?) : (-> AgentReply)?
      nil
    end

    # Runs the handler for an agent request and returns its answer; the
    # caller sends it unless the request was already answered by a cancel.
    private def route_agent_request(method_name : String, params : JSON::Any?, params_json : String?) : AgentReply
      case method_name
      when Protocol::ClientMethod::SESSION_REQUEST_PERMISSION
        handle_permission_request(params, params_json)
      when Protocol::ClientMethod::FS_READ_TEXT_FILE
        handle_typed_client_method(params, @on_read_text_file, Protocol::ReadTextFileParams, method_name, params_json)
      when Protocol::ClientMethod::FS_WRITE_TEXT_FILE
        handle_typed_client_method(params, @on_write_text_file, Protocol::WriteTextFileParams, method_name, params_json)
      when Protocol::ClientMethod::TERMINAL_CREATE
        handle_typed_client_method(params, @on_create_terminal, Protocol::CreateTerminalParams, method_name, params_json)
      when Protocol::ClientMethod::TERMINAL_OUTPUT
        handle_typed_client_method(params, @on_terminal_output, Protocol::TerminalOutputParams, method_name, params_json)
      when Protocol::ClientMethod::TERMINAL_RELEASE
        handle_typed_client_method(params, @on_release_terminal, Protocol::ReleaseTerminalParams, method_name, params_json)
      when Protocol::ClientMethod::TERMINAL_WAIT_FOR_EXIT
        handle_typed_client_method(params, @on_wait_for_terminal_exit, Protocol::WaitForTerminalExitParams, method_name, params_json)
      when Protocol::ClientMethod::TERMINAL_KILL
        handle_typed_client_method(params, @on_kill_terminal, Protocol::KillTerminalParams, method_name, params_json)
      when Protocol::ClientMethod::ELICITATION_CREATE
        # elicitation#url-completion: "Requests using a mode the Client has
        # not advertised produce JSON-RPC -32602 (Invalid params)."
        fields = params.try(&.as_h?)
        mode = fields.try(&.["mode"]?).try(&.as_s?)
        unless @client_capabilities.elicitation.try(&.supports?(mode))
          code = v2_wire? && !@client_capabilities.elicitation ? JsonRpcError::METHOD_NOT_FOUND : JsonRpcError::INVALID_PARAMS
          return Protocol::JsonRpcErrorObject.new(code,
            "Elicitation mode not advertised by the client: #{mode.inspect}")
        end
        if v2_wire? && fields
          session = fields["sessionId"]?
          request = fields["requestId"]?
          valid_scope = if session
                          !request && !session.as_s?.nil?
                        elsif request
                          !request.as_s?.nil? || !request.as_i64?.nil?
                        else
                          false
                        end
          unless valid_scope
            return Protocol::JsonRpcErrorObject.new(JsonRpcError::INVALID_PARAMS,
              "ACP v2 elicitation requires exactly one sessionId or requestId")
          end
          valid_mode = if mode == "form"
                         fields["requestedSchema"]?.try(&.as_h?)
                       else
                         fields["elicitationId"]?.try(&.as_s?) && fields["url"]?.try(&.as_s?)
                       end
          unless valid_mode
            return Protocol::JsonRpcErrorObject.new(JsonRpcError::INVALID_PARAMS,
              "Missing ACP v2 elicitation fields for #{mode.inspect}")
          end
        end
        handle_typed_client_method(params, @on_create_elicitation, Protocol::CreateElicitationParams, method_name, params_json)
      else
        handle_unknown_agent_request(method_name, params, params_json)
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
    private def handle_unknown_agent_request(method_name : String, params : JSON::Any?, params_json : String?) : AgentReply
      if handler = @on_agent_request
        return unrepresentable_request_params if params_json
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
      params_json : String?,
    ) : AgentReply
      return handle_unknown_agent_request(method_name, params, params_json) unless h = handler

      typed_params = begin
        params_type.from_json(params_json || params.to_json)
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
    private def handle_permission_request(params : JSON::Any?, params_json : String?) : AgentReply
      if handler = @on_agent_request
        return unrepresentable_request_params if params_json
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
    private def unrepresentable_request_params : Protocol::JsonRpcErrorObject
      Protocol::JsonRpcErrorObject.new(JsonRpcError::INVALID_PARAMS, "Request parameters cannot be represented as JSON::Any")
    end

    private def cancelled_permission : JSON::Any
      JSON.parse(Protocol::RequestPermissionResult.cancelled.to_json)
    end

    # Marks pending user input answered. The caller holds @pending_mutex.
    private def claim_session_inputs(session_ids : Array(String), *, elicitations : Bool) : Hash(Protocol::RequestId, InFlightRequest)
      pending = @in_flight.select do |_id, req|
        method = req.method
        session = req.session_id
        session && session_ids.includes?(session) &&
          (method == Protocol::ClientMethod::SESSION_REQUEST_PERMISSION ||
            (elicitations && method == Protocol::ClientMethod::ELICITATION_CREATE))
      end
      pending.each do |id, req|
        req.answered = true
        @in_flight.delete(id)
      end
      pending
    end

    # Resolves claimed user input independently from the callback fibers.
    private def answer_cancelled_session_inputs(pending : Hash(Protocol::RequestId, InFlightRequest)) : Nil
      pending.each do |id, req|
        result = if req.method == Protocol::ClientMethod::SESSION_REQUEST_PERMISSION
                   cancelled_permission
                 else
                   JSON.parse(Protocol::CreateElicitationResult.cancel.to_json)
                 end
        respond_to_agent(id, result)
      rescue ex : TransportError
        ClientLog.debug { "Could not answer cancelled input id=#{id}: #{ex.message}" }
      end
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
        # Ask the entry, not the map: when the agent reused the ID of a request
        # still in flight, the map holds only the newer one, and whichever of
        # the two finishes first must not make the other look cancelled.
        return false if entry.answered?
        @in_flight.delete(id) if @in_flight[id]?.try(&.same?(entry))
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
      if id && !@mcp_provider.cancel(id)
        entry = @pending_mutex.synchronize do
          req = @in_flight[id]?
          if req && CANCEL_ANSWERED_EARLY.includes?(req.method)
            req.answered = true
            @in_flight.delete(id)
          end
        end
      end

      if id && entry
        ClientLog.info { "Agent cancelled request id=#{id} (#{entry.method})" }
        begin
          if entry.method == Protocol::ClientMethod::SESSION_REQUEST_PERMISSION
            respond_to_agent(id, cancelled_permission)
          elsif v2_wire? && entry.method == Protocol::ClientMethod::ELICITATION_CREATE
            respond_to_agent(id, JSON.parse(Protocol::CreateElicitationResult.cancel.to_json))
          else
            respond_to_agent_error(id, JsonRpcError::REQUEST_CANCELLED, "Request cancelled")
          end
        rescue ex : TransportError
          ClientLog.debug { "Could not answer cancelled request id=#{id}: #{ex.message}" }
        end
      end

      deliver_raw_notification(Protocol::ProtocolMethod::CANCEL_REQUEST, params)
    end

    # Tracks v2 child associations and per-entity cancel markers before the
    # next application callback sees the update.
    protected def observe_v2_session_update(session_id : String, update : Hash(String, JSON::Any), update_json : String? = nil) : Bool
      @pending_mutex.synchronize do
        return false if @disconnected

        registry = @subagent_registry.not_nil!
        waiting_to_write = registry.setup_waiting_to_write?(session_id) && !registry.resume_timed_out?(session_id)
        replaying = !waiting_to_write && !!@cursor_registry.try(&.replaying?(session_id))
        applied = registry.observe_v2_update(session_id, update, update_json, replaying: replaying)
        return true if applied.nil? # Deliver the raw update without follow-up effects.
        return false unless applied

        case update["sessionUpdate"]?.try(&.as_s?)
        when "subagent_update"
          if child_id = update["sessionId"]?.try(&.as_s?)
            @cursor_registry.try(&.include_child(session_id, child_id))
          end
        when "replay_complete"
          unless waiting_to_write
            @cursor_registry.try(&.replay_complete(session_id))
            @session_choices.replay_complete(session_id)
          end
        when "prompt_suggestions_update"
          return false unless @suggestion_content_types &&
                              !@cursor_registry.try(&.replaying?(session_id)) &&
                              !registry.child?(session_id) &&
                              registry.current_updates?(session_id)
        when "state_update"
          unless replaying
            registry.observe_root_state(session_id, update_json || Protocol::WireFrame.encode(update))
          end
        when "config_option_update"
          @session_choices.observe_options(session_id, update_json || Protocol::WireFrame.encode(update))
        when "available_commands_update"
          if registry.current_updates?(session_id) && !@cursor_registry.try(&.replaying?(session_id))
            @session_choices.observe_commands(session_id, update_json || Protocol::WireFrame.encode(update))
          end
        end
        true
      end
    end

    # Records cursor state before notifying an application handler.
    protected def observe_cursor_update(session_id : String, update : Protocol::CursorUpdate) : Nil
      @pending_mutex.synchronize do
        @cursor_registry.try(&.observe(session_id, update)) unless @disconnected
      end
    end

    # Runs under the pending-request mutex.
    private def start_cursor_replay(request_id : String, method : String, params : Hash(String, JSON::Any)?) : Nil
      return unless (registry = @cursor_registry) && params && (session_id = params["sessionId"]?.try(&.as_s?))

      if v2_wire?
        return unless method == Protocol::AgentMethod::SESSION_RESUME
        return unless replay_type = params["replayFrom"]?.try(&.as_h?).try(&.["type"]?).try(&.as_s?)

        registry.start_replay(request_id, session_id, full: replay_type == "start")
      else
        return unless method == Protocol::AgentMethod::SESSION_LOAD

        registry.start_replay(request_id, session_id, full: true)
      end
    end

    # Handles an incoming notification from the agent.
    private def handle_notification(msg : JSON::Any, frame : Protocol::WireFrame? = nil) : Nil
      method_name = msg["method"]?.try(&.as_s?)
      return unless method_name

      params = msg["params"]?
      params_json = frame.try(&.params_json)
      if frame && !params_json && method_name == Protocol::AgentMethod::SESSION_UPDATE
        params_json = Protocol::WireFrame.field(frame.json, "params")
      end
      if params_json && !method_name.in?(Protocol::AgentMethod::SESSION_UPDATE, Protocol::ProtocolMethod::CANCEL_REQUEST)
        ClientLog.warn { "Ignoring notification with parameters outside the range of JSON::Any" }
        return
      end

      ClientLog.debug { "Notification: method=#{method_name}" }

      case method_name
      when Protocol::AgentMethod::SESSION_UPDATE
        handle_session_update(params, params_json)
      when Protocol::ProtocolMethod::CANCEL_REQUEST
        handle_cancel_request(params)
      when Protocol::ClientMethod::ELICITATION_COMPLETE
        handle_elicitation_complete(params)
      when Protocol::ClientMethod::AUTH_STATUS_UPDATE
        handle_auth_status_update(params)
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

    private def deliver_raw_session_update(params : JSON::Any?, params_json : String?) : Nil
      return unless @on_notification && raw_session_update_representable?(params_json)

      deliver_raw_notification(Protocol::AgentMethod::SESSION_UPDATE, params)
    end

    # A wide routing projection cannot be delivered as application data.
    private def raw_session_update_representable?(params_json : String?) : Bool
      JSON.parse(params_json) if params_json
      true
    rescue JSON::ParseException
      false
    end

    # Handles a `session/update` notification by parsing it and
    # invoking the registered update handler.
    private def handle_session_update(params : JSON::Any?, params_json : String?) : Nil
      return unless params

      # Params that aren't a usable object can't be typed, but they are still
      # a notification the agent sent us: hand them to `on_notification`
      # rather than dropping them on the floor.
      raw_h = params.as_h?
      unless raw_h
        ClientLog.warn { "session/update params are not an object" }
        deliver_raw_session_update(params, params_json)
        return
      end

      # Compatibility: Ensure 'sessionUpdate' is present for discriminator.
      # The ACP spec uses "sessionUpdate" as the discriminator field.
      # Some legacy agents may send "type" instead, so we normalize
      # "type" → "sessionUpdate" for backward compatibility.
      raw_params = raw_h.dup
      plan_operation = false
      child_state_update = false
      cursor_update = false
      if update = raw_params["update"]?
        update_h = update.as_h?
        unless update_h
          ClientLog.warn { "session/update `update` payload is not an object" }
          deliver_raw_session_update(params, params_json)
          return
        end
        update_h = update_h.dup
        if !update_h.has_key?("sessionUpdate") && update_h.has_key?("type")
          update_h["sessionUpdate"] = update_h["type"]
          raw_params["update"] = JSON::Any.new(update_h)
          params_json = replace_session_update_field(params_json, "sessionUpdate", update_h["type"]) if params_json
        end
        kind = update_h["sessionUpdate"]?.try(&.as_s?)
        plan_operation = kind == "plan_update" || kind == "plan_removed"
        child_state_update = kind == "subagent_update" || kind == "config_option_update" || kind == "config_options_update"
        cursor_update = kind == "cursor_update"
      end

      if update_h && (sid = raw_params["sessionId"]?.try(&.as_s?))
        case kind
        when "current_mode_update"
          if mode = update_h["currentModeId"]?.try(&.as_s?)
            @pending_mutex.synchronize { @session_choices.observe_mode(sid, mode) unless @disconnected }
          end
        when "config_option_update", "config_options_update"
          wire = params_json ? Protocol::WireFrame.field(params_json, "update") : Protocol::WireFrame.encode(update_h)
          if wire
            @pending_mutex.synchronize { @session_choices.observe_options(sid, wire) unless @disconnected }
          end
        end
      end

      return if cursor_update && !@cursor_registry
      if kind == "prompt_suggestions_update"
        return unless (suggestion_types = @suggestion_content_types) && prompt_suggestions_live?(raw_params)
      end

      handler = @on_update
      unless handler || cursor_update || suggestion_types || (plan_operation && @client_capabilities.plan) || (child_state_update && @subagent_registry)
        # No typed handler registered. `session/update` is still a
        # notification, so hand it to the generic notification handler rather
        # than dropping it — a client that only registers `on_notification`
        # would otherwise never see any session updates at all.
        deliver_raw_session_update(params, params_json)
        return
      end

      # Parse and invoke in separate steps. Folding them into one `begin`
      # would let a `JSON::SerializableError` raised by the *handler* (user
      # code deserializing something of its own) be mistaken for a failure to
      # parse the update, re-delivering the same notification to
      # `on_notification` a second time.
      update_params = begin
        json = params_json || ((cursor_update || suggestion_types) ? Protocol::WireFrame.encode(raw_params) : raw_params.to_json)
        Protocol::SessionUpdateParams.from_json(json)
      rescue ex : JSON::ParseException
        ClientLog.warn { "Failed to parse session/update: #{ex.message}" }
        # Try the raw notification handler as fallback.
        deliver_raw_session_update(params, params_json) unless suggestion_types
        return
      end

      @pending_mutex.synchronize do
        update_params.before_load_response = @session_choices.loading?(update_params.session_id)
      end
      if plan_operation && @client_capabilities.plan
        return unless track_plan_operation(update_params.session_id, update_params.update)
      end
      if registry = @subagent_registry
        update_params = observe_subagent_update(registry, update_params) || return
      end
      if cursor = update_params.update.as?(Protocol::CursorUpdate)
        observe_cursor_update(update_params.session_id, cursor)
      end
      if suggestion_types && (suggestions = update_params.update.as?(Protocol::PromptSuggestionsUpdate))
        suggestions.suggestions.select! { |suggestion| suggestion.allowed?(suggestion_types) }
        unless handler
          list = JSON.parse(Protocol::WireFrame.encode(suggestions.suggestions))
          deliver_suggestion_notification(JSON::Any.new(raw_params), params_json, list)
          return
        end
      end
      unless handler
        deliver_raw_session_update(params, params_json)
        return
      end

      begin
        handler.call(update_params)
      rescue ex
        ClientLog.error { "Error in update handler: #{ex.message}" }
      end
    end

    # Replayed history does not offer suggestions to the current composer.
    private def prompt_suggestions_live?(params : Hash(String, JSON::Any)) : Bool
      return false unless sid = params["sessionId"]?.try(&.as_s?)

      @pending_mutex.synchronize do
        !@suggestion_loads.has_value?(sid) && !@subagent_registry.try(&.child?(sid))
      end
    end

    # Gives the generic callback the usable list while preserving other envelope fields.
    protected def deliver_suggestion_notification(params : JSON::Any, params_json : String?, suggestions : JSON::Any) : Nil
      if params_json
        params = JSON.parse(replace_session_update_field(params_json, "suggestions", suggestions))
      else
        envelope = params.as_h.dup
        update = envelope["update"].as_h.dup
        update["suggestions"] = suggestions
        envelope["update"] = JSON::Any.new(update)
        params = JSON::Any.new(envelope)
      end
      deliver_raw_notification(Protocol::AgentMethod::SESSION_UPDATE, params)
    rescue JSON::ParseException
      # Other fields can still be outside the generic callback's numeric range.
    end

    # Adds or replaces an update field while keeping every other original number.
    private def replace_session_update_field(params_json : String, name : String, value : JSON::Any) : String
      pull = JSON::PullParser.new(params_json)
      JSON.build do |json|
        json.max_nesting = pull.max_nesting
        json.object do
          pull.read_object do |key|
            if key == "update"
              json.field(key) do
                json.object do
                  json.field(name, value)
                  pull.read_object do |field|
                    if field == name
                      pull.skip
                    else
                      json.field(field) { pull.read_raw(json) }
                    end
                  end
                end
              end
            else
              json.field(key) { pull.read_raw(json) }
            end
          end
        end
      end
    end

    # Tracks child session state before dispatching the application callback.
    private def observe_subagent_update(registry : SubagentRegistry, params : Protocol::SessionUpdateParams) : Protocol::SessionUpdateParams?
      pending = @pending_mutex.synchronize do
        return if @disconnected

        sid = params.session_id
        params.before_load_response = params.before_load_response? || registry.replaying?(sid)
        case update = params.update
        when Protocol::SubagentUpdate
          return unless registry.announce(sid, update)

          @cursor_registry.try(&.include_child(sid, update.session_id))
          state = update.state
          if state && state.state == "idle" && state.stop_reason == "cancelled" && registry.current_updates?(update.session_id)
            claim_session_inputs([update.session_id], elicitations: true)
          end
        when Protocol::ConfigOptionUpdate
          registry.update_config(sid, update.typed_config_options)
          nil
        end
      end
      answer_cancelled_session_inputs(pending) if pending
      params
    end

    # Tracks announced IDs even for raw handlers so an unknown removal has no effect.
    protected def track_plan_operation(session_id : String, update : Protocol::SessionUpdate | Protocol::V2::PlanUpdate) : Bool
      @pending_mutex.synchronize do
        return false if @disconnected

        plan_id = update.is_a?(Protocol::V2::PlanUpdate) ? update.plan.plan_id : nil
        order = v2_wire? ? plan_update_order(session_id, plan_id) : 0_u64
        return false unless order

        case update
        when Protocol::IdentifiedPlanUpdate, Protocol::V2::PlanUpdate
          ids = @plan_ids[session_id] ||= {} of String => UInt64
          ids[update.plan.plan_id] = order
        when Protocol::PlanRemovedUpdate
          return false unless ids = @plan_ids[session_id]?
          return false unless ids.delete(update.plan_id)

          if ids.empty?
            @plan_ids.delete(session_id)
            @early_plan_sessions.delete(session_id)
          end
        end
        true
      end
    end

    # Tracks only sessions whose update scope is attached, attaching, or being allocated.
    private def plan_update_order(session_id : String, plan_id : String?) : UInt64?
      registry = @subagent_registry.not_nil!
      if order = registry.plan_update_order(session_id)
        return order
      end
      return unless registry.accepts_early_plan_updates?(session_id)
      return 0_u64 if @early_plan_sessions.includes?(session_id) && (!plan_id || @plan_ids[session_id].has_key?(plan_id))
      return unless plan_id && session_id.bytesize.to_i64 + plan_id.bytesize <= MAX_EARLY_PLAN_ID_SIZE
      return unless @early_plan_sessions.sum { |sid| @plan_ids[sid].size } < MAX_EARLY_PLAN_IDS

      @early_plan_sessions.add(session_id)
      0_u64
    end

    private def settle_early_plan_sessions : Nil
      return if @early_plan_sessions.empty?

      registry = @subagent_registry.not_nil!
      creating = registry.creating_session?
      @early_plan_sessions.reject! do |sid|
        if order = registry.plan_update_order(sid)
          @plan_ids[sid]?.try(&.transform_values! { order })
          true
        elsif !creating
          @plan_ids.delete(sid)
          true
        else
          false
        end
      end
    end

    # Removes plans from the retired attachment while keeping any newer replay.
    private def retire_plan_ids(session_id : String, order : UInt64?) : Nil
      if order && (ids = @plan_ids[session_id]?)
        ids.reject! { |_, updated| updated < order }
        @plan_ids.delete(session_id) if ids.empty?
      else
        @plan_ids.delete(session_id)
      end
      @early_plan_sessions.delete(session_id)
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

    # Delivers advertised authentication status updates in receive order.
    private def handle_auth_status_update(params : JSON::Any?) : Nil
      if (handler = @on_auth_status_update) && @pending_mutex.synchronize { @auth_status_supported }
        if update = params.try { |p| Protocol::AuthStatusUpdateParams.from_json(p.to_json) rescue nil }
          handler.call(update)
          return
        end
      end
      deliver_raw_notification(Protocol::ClientMethod::AUTH_STATUS_UPDATE, params)
    rescue ex
      ClientLog.error { "Error in auth/status_update handler: #{ex.class}" }
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
