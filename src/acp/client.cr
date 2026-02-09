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
#     - Agent-initiated requests go to registered method handlers
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

    # Whether the dispatcher fiber is running.
    @dispatcher_running : Bool = false

    # Channel used to signal the dispatcher to stop.
    # Buffered with capacity 1 so that `close` never blocks if
    # nobody is receiving from this channel.
    @stop_channel : Channel(Nil) = Channel(Nil).new(1)

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

      raw_result = send_request("initialize", params)
      result = Protocol::InitializeResult.from_json(raw_result.to_json)

      # Validate protocol version compatibility.
      if result.protocol_version != ACP::PROTOCOL_VERSION
        ClientLog.error {
          "Protocol version mismatch: client=#{ACP::PROTOCOL_VERSION}, " \
          "agent=#{result.protocol_version}"
        }
        close
        raise VersionMismatchError.new(ACP::PROTOCOL_VERSION, result.protocol_version)
      end

      # Store negotiated state.
      @negotiated_protocol_version = result.protocol_version
      @agent_capabilities = result.agent_capabilities
      @agent_info = result.agent_info
      @auth_methods = result.auth_methods
      @state = ClientState::Initialized

      ClientLog.info {
        agent_name = result.agent_info.try(&.name) || "unknown"
        agent_ver = result.agent_info.try(&.version) || "?"
        "Initialized with agent: #{agent_name} v#{agent_ver}"
      }

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
      send_request("authenticate", params)

      ClientLog.info { "Authenticated with method: #{method_id}" }
    end

    # Creates a new session with the agent.
    #
    # - `cwd` — the absolute path to the working directory.
    # - `mcp_servers` — optional list of MCP servers to connect to.
    #
    # Returns the session creation result with the session ID, modes,
    # and config options. Stores the session ID for subsequent calls.
    #
    # Raises `InvalidStateError` if not initialized.
    def session_new(
      cwd : String,
      mcp_servers : Array(JSON::Any) = [] of JSON::Any,
    ) : Protocol::SessionNewResult
      ensure_state(ClientState::Initialized, "session/new")

      params = Protocol::SessionNewParams.new(cwd, mcp_servers)
      raw_result = send_request("session/new", params)
      result = Protocol::SessionNewResult.from_json(raw_result.to_json)

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
    #
    # Raises `InvalidStateError` if not initialized.
    # Raises `JsonRpcError` if the agent can't load the session.
    def session_load(
      session_id : String,
      cwd : String,
      mcp_servers : Array(JSON::Any) = [] of JSON::Any,
    ) : Protocol::SessionLoadResult
      ensure_state(ClientState::Initialized, "session/load")

      params = Protocol::SessionLoadParams.new(session_id, cwd, mcp_servers)
      raw_result = send_request("session/load", params)
      result = Protocol::SessionLoadResult.from_json(raw_result.to_json)

      @session_id = session_id
      @session_modes = result.modes
      @session_config_options = result.config_options
      @state = ClientState::SessionActive

      ClientLog.info { "Session loaded: #{session_id}" }

      result
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
      raw_result = send_request("session/prompt", params, timeout: nil)
      Protocol::SessionPromptResult.from_json(raw_result.to_json)
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
    def session_cancel(session_id : String? = nil) : Nil
      sid = session_id || @session_id
      raise NoActiveSessionError.new unless sid

      params = Protocol::SessionCancelParams.new(sid)
      send_notification("session/cancel", params)

      ClientLog.info { "Sent cancel for session: #{sid}" }
    end

    # Changes the mode for the active session.
    #
    # - `mode_id` — the mode ID to switch to.
    # - `session_id` — optional session ID override.
    def session_set_mode(mode_id : String, session_id : String? = nil) : Nil
      sid = session_id || @session_id
      raise NoActiveSessionError.new unless sid

      params = Protocol::SessionSetModeParams.new(sid, mode_id)
      send_request("session/set_mode", params)

      ClientLog.info { "Mode set to: #{mode_id}" }
    end

    # Changes a configuration option for the active session.
    #
    # - `config_id` — the ID of the configuration option to change.
    # - `value` — the new value to set.
    # - `session_id` — optional session ID override.
    #
    # Returns the full set of configuration options and their current values.
    # See: https://agentclientprotocol.com/protocol/session-config-options#from-the-client
    def session_set_config_option(
      config_id : String,
      value : String,
      session_id : String? = nil,
    ) : Protocol::SessionSetConfigOptionResult
      sid = session_id || @session_id
      raise NoActiveSessionError.new unless sid

      params = Protocol::SessionSetConfigOptionParams.new(sid, config_id, value)
      raw_result = send_request("session/set_config_option", params)
      result = Protocol::SessionSetConfigOptionResult.from_json(raw_result.to_json)

      @session_config_options = result.config_options

      ClientLog.info { "Config option '#{config_id}' set to '#{value}'" }

      result
    end

    # Closes the client, stopping the dispatcher and closing the transport.
    def close : Nil
      return if @state == ClientState::Closed
      @state = ClientState::Closed

      ClientLog.info { "Closing client" }

      # Cancel all pending requests.
      @pending_mutex.synchronize do
        @pending.each do |_id, ch|
          begin
            # Send a nil-like error response to unblock waiters.
            error_any = JSON.parse(%({"error": "Client closed"}))
            ch.send(error_any)
          rescue Channel::ClosedError
            # Already closed.
          end
        end
        @pending.clear
      end

      # Stop the dispatcher.
      begin
        @stop_channel.send(nil)
      rescue Channel::ClosedError
        # Already stopped.
      end

      # Close the transport.
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
      timeout : Float64? | Nil = @request_timeout,
    ) : JSON::Any
      raise ConnectionClosedError.new if closed?

      # Generate a unique ID for this request.
      id = next_id
      id_str = id.to_s

      # Create a channel to receive the response.
      response_channel = Channel(JSON::Any).new(1)

      @pending_mutex.synchronize do
        @pending[id_str] = response_channel
      end

      # Build and send the request.
      message = Protocol.build_request(id, method, params)
      @transport.send(message)

      ClientLog.debug { "Sent request id=#{id} method=#{method}" }

      # Wait for the response with optional timeout.
      raw_response = if timeout
                       receive_with_timeout(response_channel, timeout, id)
                     else
                       begin
                         response_channel.receive
                       rescue Channel::ClosedError
                         raise ConnectionClosedError.new("Channel closed while waiting for response to #{method}")
                       end
                     end

      # Clean up the pending entry.
      @pending_mutex.synchronize do
        @pending.delete(id_str)
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

    # Responds to an agent-initiated request.
    #
    # - `id` — the request ID from the agent's request.
    # - `result` — the result to send back.
    def respond_to_agent(id : Protocol::RequestId, result : JSON::Any) : Nil
      raise ConnectionClosedError.new if closed?

      message = Protocol.build_response_raw(id, result)
      @transport.send(message)

      ClientLog.debug { "Sent response to agent request id=#{id}" }
    end

    # Responds to an agent-initiated request with an error.
    #
    # - `id` — the request ID from the agent's request.
    # - `code` — the JSON-RPC error code.
    # - `error_message` — human-readable error description.
    def respond_to_agent_error(
      id : Protocol::RequestId,
      code : Int32,
      error_message : String,
    ) : Nil
      raise ConnectionClosedError.new if closed?

      message = Protocol.build_error_response(id, code, error_message)
      @transport.send(message)

      ClientLog.debug { "Sent error response to agent request id=#{id} code=#{code}" }
    end

    # ─── Private Methods ────────────────────────────────────────────

    private def next_id : Int64
      id = @next_id
      @next_id += 1
      id
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

        # Use select to also listen for the stop signal.
        msg = @transport.receive
        break if msg.nil?

        begin
          dispatch_message(msg)
        rescue ex
          ClientLog.error { "Error dispatching message: #{ex.message}" }
        end
      end

      @dispatcher_running = false

      # Notify pending requests that the connection is lost.
      @pending_mutex.synchronize do
        @pending.each do |_id, ch|
          begin
            error_any = JSON.parse(%({"error": "Connection lost"}))
            ch.send(error_any)
          rescue Channel::ClosedError
            # Already closed.
          end
        end
        @pending.clear
      end

      # Invoke the disconnect callback if set.
      if cb = @on_disconnect
        begin
          cb.call
        rescue ex
          ClientLog.error { "Error in disconnect callback: #{ex.message}" }
        end
      end
    end

    # Routes a single incoming message to the appropriate handler.
    private def dispatch_message(msg : JSON::Any) : Nil
      kind = Protocol.classify_message(msg)

      case kind
      when Protocol::MessageKind::Response
        handle_response(msg)
      when Protocol::MessageKind::Request
        handle_agent_request(msg)
      when Protocol::MessageKind::Notification
        handle_notification(msg)
      end
    end

    # Handles a response to one of our pending requests.
    # Finds the corresponding channel by ID and sends the response into it.
    private def handle_response(msg : JSON::Any) : Nil
      id = Protocol.extract_id(msg)
      return unless id

      id_str = id.to_s

      channel = @pending_mutex.synchronize do
        @pending[id_str]?
      end

      if channel
        begin
          channel.send(msg)
        rescue Channel::ClosedError
          ClientLog.warn { "Response channel already closed for id=#{id_str}" }
        end
      else
        ClientLog.warn { "Received response for unknown request id=#{id_str}" }
      end
    end

    # Handles a method call from the agent (e.g., session/request_permission).
    # If we have a registered handler, we invoke it and send the result back.
    # Otherwise, we respond with a method-not-found error.
    #
    # Dispatch order:
    #   1. Well-known methods with typed handlers (permission, fs/*, terminal/*)
    #   2. Generic `on_agent_request` callback
    #   3. Method-not-found error
    private def handle_agent_request(msg : JSON::Any) : Nil
      id = Protocol.extract_id(msg)
      return unless id

      method_name = msg["method"]?.try(&.as_s?)
      return unless method_name

      params = msg["params"]?

      ClientLog.debug { "Agent request: method=#{method_name} id=#{id}" }

      # Special handling for well-known agent methods.
      case method_name
      when Protocol::ClientMethod::SESSION_REQUEST_PERMISSION
        handle_permission_request(id, params)
      when Protocol::ClientMethod::FS_READ_TEXT_FILE
        handle_typed_client_method(id, params, @on_read_text_file, Protocol::ReadTextFileParams, method_name)
      when Protocol::ClientMethod::FS_WRITE_TEXT_FILE
        handle_typed_client_method(id, params, @on_write_text_file, Protocol::WriteTextFileParams, method_name)
      when Protocol::ClientMethod::TERMINAL_CREATE
        handle_typed_client_method(id, params, @on_create_terminal, Protocol::CreateTerminalParams, method_name)
      when Protocol::ClientMethod::TERMINAL_OUTPUT
        handle_typed_client_method(id, params, @on_terminal_output, Protocol::TerminalOutputParams, method_name)
      when Protocol::ClientMethod::TERMINAL_RELEASE
        handle_typed_client_method(id, params, @on_release_terminal, Protocol::ReleaseTerminalParams, method_name)
      when Protocol::ClientMethod::TERMINAL_WAIT_FOR_EXIT
        handle_typed_client_method(id, params, @on_wait_for_terminal_exit, Protocol::WaitForTerminalExitParams, method_name)
      when Protocol::ClientMethod::TERMINAL_KILL
        handle_typed_client_method(id, params, @on_kill_terminal, Protocol::KillTerminalParams, method_name)
      else
        # Delegate to the generic agent request handler.
        if handler = @on_agent_request
          begin
            result = handler.call(method_name, params || JSON::Any.new(nil))
            respond_to_agent(id, result)
          rescue ex
            ClientLog.error { "Error in agent request handler: #{ex.message}" }
            respond_to_agent_error(id, JsonRpcError::INTERNAL_ERROR, ex.message || "Handler error")
          end
        else
          # No handler registered — respond with method not found.
          respond_to_agent_error(
            id,
            JsonRpcError::METHOD_NOT_FOUND,
            "Client does not handle method: #{method_name}"
          )
        end
      end
    end

    # Generic typed dispatch for client methods. Tries the typed handler
    # first, then falls back to `on_agent_request`, then returns an error.
    private def handle_typed_client_method(
      id : Protocol::RequestId,
      params : JSON::Any?,
      handler,
      params_type,
      method_name : String,
    ) : Nil
      if h = handler
        begin
          typed_params = params_type.from_json((params || JSON::Any.new(nil)).to_json)
          result = h.call(typed_params)
          respond_to_agent(id, JSON.parse(result.to_json))
        rescue ex : JSON::SerializableError
          ClientLog.error { "Failed to parse #{method_name} params: #{ex.message}" }
          respond_to_agent_error(id, JsonRpcError::INVALID_PARAMS, "Invalid params for #{method_name}: #{ex.message}")
        rescue ex
          ClientLog.error { "Error in #{method_name} handler: #{ex.message}" }
          respond_to_agent_error(id, JsonRpcError::INTERNAL_ERROR, ex.message || "Handler error")
        end
      elsif fallback = @on_agent_request
        begin
          result = fallback.call(method_name, params || JSON::Any.new(nil))
          respond_to_agent(id, result)
        rescue ex
          ClientLog.error { "Error in agent request handler for #{method_name}: #{ex.message}" }
          respond_to_agent_error(id, JsonRpcError::INTERNAL_ERROR, ex.message || "Handler error")
        end
      else
        respond_to_agent_error(
          id,
          JsonRpcError::METHOD_NOT_FOUND,
          "Client does not handle method: #{method_name}"
        )
      end
    end

    # Handles a `session/request_permission` request from the agent.
    # Delegates to the on_agent_request handler or auto-denies.
    private def handle_permission_request(id : Protocol::RequestId, params : JSON::Any?) : Nil
      if handler = @on_agent_request
        begin
          result = handler.call("session/request_permission", params || JSON::Any.new(nil))
          respond_to_agent(id, result)
        rescue ex
          ClientLog.error { "Error handling permission request: #{ex.message}" }
          # On error, respond with cancellation.
          cancelled = JSON.parse(%({"outcome": "cancelled"}))
          respond_to_agent(id, cancelled)
        end
      else
        # No handler — auto-cancel the permission request.
        ClientLog.warn { "No handler for permission request; auto-cancelling" }
        cancelled = JSON.parse(%({"outcome": "cancelled"}))
        respond_to_agent(id, cancelled)
      end
    end

    # Handles an incoming notification from the agent.
    private def handle_notification(msg : JSON::Any) : Nil
      method_name = msg["method"]?.try(&.as_s?)
      return unless method_name

      params = msg["params"]?

      ClientLog.debug { "Notification: method=#{method_name}" }

      case method_name
      when "session/update"
        handle_session_update(params)
      else
        # Delegate to the generic notification handler.
        if handler = @on_notification
          begin
            handler.call(method_name, params)
          rescue ex
            ClientLog.error { "Error in notification handler: #{ex.message}" }
          end
        else
          ClientLog.debug { "Unhandled notification: #{method_name}" }
        end
      end
    end

    # Handles a `session/update` notification by parsing it and
    # invoking the registered update handler.
    private def handle_session_update(params : JSON::Any?) : Nil
      return unless params

      # Compatibility: Ensure 'sessionUpdate' is present for discriminator.
      # The ACP spec uses "sessionUpdate" as the discriminator field.
      # Some legacy agents may send "type" instead, so we normalize
      # "type" → "sessionUpdate" for backward compatibility.
      raw_params = params.as_h.dup
      if update = raw_params["update"]?
        update_h = update.as_h.dup
        if !update_h.has_key?("sessionUpdate") && update_h.has_key?("type")
          update_h["sessionUpdate"] = update_h["type"]
          raw_params["update"] = JSON::Any.new(update_h)
        end
      end
      normalized_params = JSON::Any.new(raw_params)

      if handler = @on_update
        begin
          update_params = Protocol::SessionUpdateParams.from_json(normalized_params.to_json)
          handler.call(update_params)
        rescue ex : JSON::SerializableError
          ClientLog.warn { "Failed to parse session/update: #{ex.message}" }
          # Try the raw notification handler as fallback.
          if fallback = @on_notification
            fallback.call("session/update", params)
          end
        rescue ex
          ClientLog.error { "Error in update handler: #{ex.message}" }
        end
      end
    end
  end
end
