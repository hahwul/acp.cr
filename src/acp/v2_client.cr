require "./client"
require "./protocol/v2/methods"
require "./protocol/v2/interactions"
require "./protocol/v2/updates"

module ACP
  # Explicit opt-in API for the ACP v2 Preview wire protocol.
  module V2
    # Client for an ACP v2 connection over an existing transport.
    class Client
      private alias Wire = Protocol::V2
      private alias AgentMethod = Wire::AgentMethod
      private alias ClientMethod = Wire::ClientMethod

      private class Connection < ACP::Client
        property on_v2_update : (Protocol::V2::SessionUpdateParams -> Nil)?

        def initialization_result : Protocol::V2::InitializeResult?
          v2_initialization_result
        end

        private def v2_wire? : Bool
          true
        end

        private def handle_session_update(params : JSON::Any?) : Nil
          if params
            begin
              update = Protocol::V2::SessionUpdateParams.from_json(params.to_json)
              return unless observe_v2_session_update(update.session_id, params["update"].as_h)
            rescue ex : JSON::ParseException
              ClientLog.warn { "Failed to parse v2 session/update: #{ex.message}" }
              deliver_raw_notification(Protocol::V2::ClientMethod::SESSION_UPDATE, params)
              return
            end
            if handler = @on_v2_update
              begin
                handler.call(update)
              rescue ex
                ClientLog.error { "Error in v2 session update handler: #{ex.message}" }
              end
              return
            end
          end
          deliver_raw_notification(Protocol::V2::ClientMethod::SESSION_UPDATE, params)
        end

        private def route_agent_request(method_name : String, params : JSON::Any?) : JSON::Any | Protocol::JsonRpcErrorObject
          if method_name == Protocol::V2::ClientMethod::SESSION_REQUEST_PERMISSION ||
             method_name == Protocol::V2::ClientMethod::ELICITATION_CREATE ||
             Protocol::ExtensionMethod.extension?(method_name)
            return super
          end

          Protocol::JsonRpcErrorObject.new(JsonRpcError::METHOD_NOT_FOUND, "Client does not handle method: #{method_name}")
        end
      end

      # Transport used by this protocol connection.
      getter transport : Transport

      # Implementation identity included in the handshake.
      getter info : Wire::Implementation

      # Client capabilities included in the handshake.
      getter capabilities : Wire::ClientCapabilities

      # Handler for permission requests. The default outcome is cancelled.
      property on_request_permission : (Wire::RequestPermissionParams -> Wire::RequestPermissionResult)?

      # Handler for custom Agent-to-Client requests.
      property on_extension_request : AgentRequestHandler?

      @initializing = Atomic(Bool).new(false)
      @terminal_auth_running = Atomic(Bool).new(false)

      # Creates a v2 client over an existing transport.
      def initialize(
        @transport : Transport,
        @info : Wire::Implementation = Wire::Implementation.new("acp-crystal", ACP::VERSION),
        @capabilities : Wire::ClientCapabilities = Wire::ClientCapabilities.new,
      )
        @connection = Connection.new(@transport,
          client_capabilities: Protocol::ClientCapabilities.new(elicitation: @capabilities.elicitation))
        @connection.on_agent_request = ->handle_agent_request(String, JSON::Any)
      end

      # Default timeout in seconds for requests.
      delegate request_timeout, :"request_timeout=", to: @connection

      # Timeout in seconds for prompt insertion acknowledgements.
      delegate prompt_timeout, :"prompt_timeout=", to: @connection

      # Callback for v2 session updates in wire order.
      def on_update : (Wire::SessionUpdateParams -> Nil)?
        @connection.on_v2_update
      end

      # Sets the callback for v2 session updates.
      def on_update=(handler : (Wire::SessionUpdateParams -> Nil)?) : Nil
        @connection.on_v2_update = handler
      end

      # Callback for other notifications and updates without a v2 handler.
      delegate on_notification, :"on_notification=", to: @connection

      # Callback when the connection is unexpectedly lost.
      delegate on_disconnect, :"on_disconnect=", to: @connection

      # Callback for advertised elicitation modes and their URL completion.
      delegate on_create_elicitation, :"on_create_elicitation=", on_elicitation_complete, :"on_elicitation_complete=", to: @connection

      # Closes this connection and its transport.
      delegate close, closed?, to: @connection

      # Agent identity, capabilities and auth methods after initialization.
      def initialization_result : Wire::InitializeResult?
        @connection.initialization_result
      end

      # Wire protocol version selected after a successful handshake.
      def negotiated_protocol_version : UInt16?
        initialization_result.try(&.protocol_version)
      end

      # Child associations and effective session workspace roots.
      delegate subagent, subagents, session_workspace, to: @connection

      # Sends initialize and verifies the selected protocol version.
      def initialize_connection : Wire::InitializeResult
        _, started = @initializing.compare_and_set(false, true)
        raise InvalidStateError.new("ACP v2 initialization is already in progress") unless started

        begin
          raise InvalidStateError.new("ACP v2 connection already initialized") if initialization_result
          raw = @connection.send_request(AgentMethod::INITIALIZE, Wire::InitializeParams.new(@info, capabilities: @capabilities))
          version = raw.as_h?.try(&.["protocolVersion"]?).try(&.as_i64?)
          unless version == Wire::VERSION
            close
            decode(Protocol::InitializeResult, raw, AgentMethod::INITIALIZE) if version == ACP::PROTOCOL_VERSION
            reported = version.to_u16 if version && (0..UInt16::MAX.to_i).includes?(version)
            raise VersionMismatchError.new(Wire::VERSION, reported)
          end
          initialization_result || decode(Wire::InitializeResult, raw, AgentMethod::INITIALIZE)
        rescue ex : JsonRpcError
          close if ex.unsupported_protocol_version?
          raise ex
        ensure
          @initializing.set(false)
        end
      end

      # Selects an advertised Agent-managed authentication flow.
      def auth_login(method_id : String) : Wire::AuthLoginResult
        method = ready.auth_methods.find { |candidate| candidate.method_id == method_id }
        raise InvalidStateError.new("An advertised Agent auth method is required") unless method && method.agent?

        request(AgentMethod::AUTH_LOGIN, Wire::AuthLoginParams.new(method_id), Wire::AuthLoginResult)
      end

      # Ends authentication when the Agent advertised authentication methods.
      def auth_logout : Wire::AuthLogoutResult
        raise InvalidStateError.new("The Agent advertised no auth methods") if ready.auth_methods.empty?

        request(AgentMethod::AUTH_LOGOUT, Wire::AuthLogoutParams.new, Wire::AuthLogoutResult)
      end

      # Runs the approved terminal auth flow and returns the reinitialized client.
      def authenticate_terminal(method_id : String, &approve : Wire::AuthMethod -> Bool) : Client
        _, started = @terminal_auth_running.compare_and_set(false, true)
        raise InvalidStateError.new("Terminal authentication is already in progress") unless started

        begin
          terminal_auth_flow(method_id, approve)
        ensure
          @terminal_auth_running.set(false)
        end
      end

      # Creates a session with typed workspace and MCP settings.
      def session_new(params : Wire::SessionNewParams) : Wire::SessionNewResult
        caps = session_capabilities
        validate_setup(caps, params.cwd, params.additional_directories, params.mcp_servers, params.system_prompt)
        request(AgentMethod::SESSION_NEW, params, Wire::SessionNewResult)
      end

      # Creates a session in the given absolute directory.
      def session_new(cwd : String) : Wire::SessionNewResult
        session_new(Wire::SessionNewParams.new(cwd))
      end

      # Attaches to an existing session and can request history replay.
      def session_resume(params : Wire::SessionResumeParams) : Wire::SessionResumeResult
        caps = session_capabilities
        validate_setup(caps, params.cwd, params.additional_directories, params.mcp_servers, params.system_prompt)
        request(AgentMethod::SESSION_RESUME, params, Wire::SessionResumeResult)
      end

      # Lists available sessions using the provided filter and cursor.
      def session_list(params : Wire::SessionListParams = Wire::SessionListParams.new) : Wire::SessionListResult
        session_capabilities
        request(AgentMethod::SESSION_LIST, params, Wire::SessionListResult)
      end

      # Enqueues prompt insertion. The returned message ID acknowledges insertion.
      def session_prompt(params : Wire::SessionPromptParams) : Wire::SessionPromptResult
        caps = session_capabilities
        validate_prompt(caps.prompt, params.prompt)
        raw = @connection.send_request(AgentMethod::SESSION_PROMPT, params, prompt_timeout)
        decode(Wire::SessionPromptResult, raw, AgentMethod::SESSION_PROMPT)
      end

      # Inserts a text prompt in a session.
      def session_prompt_text(session_id : String, text : String, idempotency_key : String? = nil) : Wire::SessionPromptResult
        blocks = [Protocol::TextContentBlock.new(text)] of Protocol::ContentBlock
        session_prompt(Wire::SessionPromptParams.new(session_id, blocks, idempotency_key))
      end

      # Requests foreground cancellation. The Agent identifies affected requests.
      def session_cancel(session_id : String) : Nil
        session_capabilities
        @connection.send_notification(AgentMethod::SESSION_CANCEL, Wire::SessionCancelParams.new(session_id))
      end

      # Closes a session and its background work.
      def session_close(session_id : String) : Wire::SessionCloseResult
        session_capabilities
        request(AgentMethod::SESSION_CLOSE, Wire::SessionCloseParams.new(session_id), Wire::SessionCloseResult)
      end

      # Deletes a session when the Agent advertises deletion.
      def session_delete(session_id : String) : Wire::SessionDeleteResult
        raise InvalidStateError.new("The Agent did not advertise session deletion") unless session_capabilities.delete

        request(AgentMethod::SESSION_DELETE, Wire::SessionDeleteParams.new(session_id), Wire::SessionDeleteResult)
      end

      # Changes a session configuration option.
      def session_set_config_option(params : Wire::SessionSetConfigOptionParams) : Wire::SessionSetConfigOptionResult
        session_capabilities
        request(AgentMethod::SESSION_SET_CONFIG_OPTION, params, Wire::SessionSetConfigOptionResult)
      end

      # Cancels a tool call with an advertised cancel marker.
      def tool_call_cancel(session_id : String, tool_call_id : String) : Wire::ToolCallCancelResult
        session_capabilities
        request(AgentMethod::TOOL_CALL_CANCEL, Wire::ToolCallCancelParams.new(session_id, tool_call_id), Wire::ToolCallCancelResult)
      end

      # Cancels an Agent-owned terminal with an advertised cancel marker.
      def terminal_cancel(session_id : String, terminal_id : String) : Wire::TerminalCancelResult
        session_capabilities
        request(AgentMethod::TERMINAL_CANCEL, Wire::TerminalCancelParams.new(session_id, terminal_id), Wire::TerminalCancelResult)
      end

      # Cancels a client-originated request by its JSON-RPC ID.
      def cancel_request(request_id : Protocol::RequestId) : Nil
        ready
        @connection.cancel_request(request_id)
      end

      # Calls a custom ACP extension method.
      def ext_method(method : String, params : JSON::Any = JSON::Any.new(nil), timeout : Float64? = request_timeout) : JSON::Any
        ready
        @connection.ext_method(method, params, timeout)
      end

      # Sends a custom ACP extension notification.
      def ext_notification(method : String, params : JSON::Any = JSON::Any.new(nil)) : Nil
        ready
        @connection.ext_notification(method, params)
      end

      private def ready : Wire::InitializeResult
        raise ConnectionClosedError.new if closed?

        initialization_result || raise InvalidStateError.new("ACP v2 initialization is required")
      end

      private def session_capabilities : Wire::SessionCapabilities
        ready.capabilities.session || raise InvalidStateError.new("The Agent did not advertise ACP v2 sessions")
      end

      private def request(method : String, params : JSON::Serializable, type : T.class) : T forall T
        decode(type, @connection.send_request(method, params), method)
      end

      private def decode(type : T.class, raw : JSON::Any, method : String) : T forall T
        T.from_json(raw.to_json)
      rescue ex : JSON::ParseException
        raise ProtocolError.new("Agent returned a malformed result for '#{method}': #{ex.message}", ex)
      end

      private def handle_agent_request(method : String, params : JSON::Any) : JSON::Any
        if method == ClientMethod::SESSION_REQUEST_PERMISSION
          input = begin
            Wire::RequestPermissionParams.from_json(params.to_json)
          rescue ex : JSON::ParseException
            raise JsonRpcError.new(JsonRpcError::INVALID_PARAMS, "Malformed v2 permission request")
          end
          result = @on_request_permission.try(&.call(input)) || Wire::RequestPermissionResult.cancelled
          return JSON.parse(result.to_json)
        end

        if Protocol::ExtensionMethod.extension?(method) && (handler = @on_extension_request)
          return handler.call(method, params)
        end
        raise JsonRpcError.new(JsonRpcError::METHOD_NOT_FOUND, "Client does not handle method: #{method}")
      end

      private def validate_setup(
        caps : Wire::SessionCapabilities,
        cwd : String,
        directories : Array(String)?,
        servers : Array(Wire::McpServer)?,
        system_prompt : Protocol::SystemPrompt?,
      ) : Nil
        unless Path[cwd].absolute? && (directories.nil? || directories.all? { |directory| Path[directory].absolute? })
          raise ArgumentError.new("ACP v2 session directories must be absolute")
        end
        if directories && !directories.empty? && !caps.additional_directories
          raise InvalidStateError.new("The Agent did not advertise additionalDirectories")
        end
        servers.try &.each do |server|
          case server.transport_type
          when "stdio"
            raise InvalidStateError.new("The Agent did not advertise MCP stdio") unless caps.mcp.try(&.stdio)
          when "http"
            raise InvalidStateError.new("The Agent did not advertise MCP HTTP") unless caps.mcp.try(&.http)
          end
        end
        if system_prompt
          support = caps.system_prompt || raise InvalidStateError.new("The Agent did not advertise systemPrompt")
          if system_prompt.mode == "override" && !support.override?
            raise InvalidStateError.new("The Agent did not advertise systemPrompt override")
          end
        end
      end

      private def validate_prompt(caps : Wire::PromptCapabilities?, blocks : Array(JSON::Any)) : Nil
        blocks.each do |block|
          kind = block.as_h?.try(&.["type"]?).try(&.as_s?)
          case kind
          when "image"
            raise InvalidStateError.new("The Agent did not advertise image prompts") unless caps.try(&.image)
          when "audio"
            raise InvalidStateError.new("The Agent did not advertise audio prompts") unless caps.try(&.audio)
          when "resource"
            raise InvalidStateError.new("The Agent did not advertise embedded context") unless caps.try(&.embedded_context)
          end
        end
      end

      private def terminal_auth_flow(method_id : String, approve : Wire::AuthMethod -> Bool) : Client
        method = ready.auth_methods.find { |candidate| candidate.method_id == method_id }
        transport = @transport.as?(ProcessTransport)
        unless transport && @capabilities.auth.try(&.terminal) && method && (settings = method.terminal_settings)
          raise InvalidStateError.new("Terminal authentication requires an advertised terminal method and process transport")
        end
        raise AuthenticationError.new("Terminal authentication declined") unless approve.call(method)
        ready

        invocation = Protocol::TerminalAuthMethod.new(method_id, method.name, method.description, settings.args, settings.environment)
        status = transport.run_terminal_authentication(invocation)
        raise AuthenticationError.new("Terminal authentication exited unsuccessfully") unless status.success?
        ready

        replacement = Client.new(transport.reconnect, @info, @capabilities)
        replacement.request_timeout = request_timeout
        replacement.prompt_timeout = prompt_timeout
        replacement.on_update = on_update
        replacement.on_notification = on_notification
        replacement.on_disconnect = on_disconnect
        replacement.on_request_permission = on_request_permission
        replacement.on_extension_request = on_extension_request
        replacement.on_create_elicitation = on_create_elicitation
        replacement.on_elicitation_complete = on_elicitation_complete
        begin
          replacement.initialize_connection
          close
        rescue ex
          replacement.close rescue nil
          raise ex
        end
        replacement
      end
    end

    # Starts and initializes an Agent subprocess for an ACP v2 connection.
    def self.connect(
      command : String,
      args : Array(String) = [] of String,
      *,
      info : Protocol::V2::Implementation = Protocol::V2::Implementation.new("acp-crystal", ACP::VERSION),
      capabilities : Protocol::V2::ClientCapabilities = Protocol::V2::ClientCapabilities.new,
      env : Process::Env = nil,
      chdir : String? = nil,
    ) : Client
      client = Client.new(ProcessTransport.new(command, args, env, chdir), info, capabilities)
      begin
        client.initialize_connection
      rescue ex
        client.close rescue nil
        raise ex
      end
      client
    end
  end
end
