require "uri"
require "./client"
require "./protocol/raw_json"
require "./protocol/v2/methods"
require "./protocol/v2/interactions"
require "./protocol/v2/updates"
require "./protocol/v2/session_status"

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
        property on_request_permission : (Wire::RequestPermissionParams -> Wire::RequestPermissionResult)?

        def initialization_result : Protocol::V2::InitializeResult?
          v2_initialization_result
        end

        def request_typed(method : String, params : JSON::Serializable, type : T.class) : T forall T
          send_typed_request(method, params, type)
        end

        def retire_session(method : String, params : JSON::Serializable, type : T.class) : T forall T
          send_session_retirement_request(method, params, type)
        end

        def attach_with_choices(method : String, params : JSON::Serializable, type : T.class, session_id : String? = nil) : T forall T
          send_cached_request(method, params, type) do |result, wire|
            sid = result.is_a?(Wire::SessionNewResult) ? result.session_id : session_id
            @session_choices.replace(sid, wire, reattach: !session_id.nil?) if sid && !closed?
          end
        end

        def request_option_change(params : Wire::SessionSetConfigOptionParams) : Wire::SessionSetConfigOptionResult
          send_choice_request(AgentMethod::SESSION_SET_CONFIG_OPTION, params, Wire::SessionSetConfigOptionResult)
        end

        def config_options(session_id : String) : Array(Wire::ConfigOption)?
          @pending_mutex.synchronize { @session_choices[session_id].try(&.v2_options) }
        end

        def config_options_raw(session_id : String) : Protocol::RawJson?
          @pending_mutex.synchronize { @session_choices[session_id].try(&.options) }
        end

        def state_raw(session_id : String) : Protocol::RawJson?
          @pending_mutex.synchronize { @subagent_registry.try(&.root_state(session_id)) }
        end

        def available_commands(session_id : String) : Array(Wire::AvailableCommand)?
          @pending_mutex.synchronize do
            commands = @session_choices.commands(session_id)
            if commands && !@skill_commands_negotiated
              commands.reject! { |command| command.type == "skill" }
            end
            commands
          end
        end

        def available_commands_raw(session_id : String) : Protocol::RawJson?
          @pending_mutex.synchronize { @session_choices.commands_raw(session_id) }
        end

        @skill_commands_negotiated = false

        @initialize_offer : Wire::InitializeParams?

        def initialization_offer : Wire::InitializeParams?
          @pending_mutex.synchronize { @initialize_offer }
        end

        # Keep capability checks and their write on the same negotiation.
        # Other ordinary requests may proceed while this one waits for its reply.
        def with_request(&block : -> T) : T forall T
          @pending_mutex.synchronize do
            check_v2_request_order(false)
            @v2_request_operations += 1
          end
          begin
            yield
          ensure
            @pending_mutex.synchronize { @v2_request_operations -= 1 }
          end
        end

        def initialize_v2(offer : Wire::InitializeParams) : Wire::InitializeResult
          method = AgentMethod::INITIALIZE
          outcome = nil
          observe = ->(response : PendingResponse) do
            outcome = begin
              result = decode_initialization_response(response)
              apply_initialization(offer, result)
              result
            rescue ex : JsonRpcError
              ex
            rescue ex : ProtocolError
              @v2_contract_unknown.set(true)
              ex
            end
            nil
          end
          builder = ->(id : Int64) { Protocol.build_request(id, method, offer) }
          begin
            send_and_await_response(method, builder, on_response: observe)
          rescue ex : RequestTimeoutError | TransportError
            close
            raise ex
          end

          begin
            case result = outcome
            when Wire::InitializeResult
              result
            when Error
              raise result
            else
              raise ProtocolError.new("Missing initialization outcome")
            end
          rescue ex : ProtocolError
            close
            raise ex
          ensure
            @pending_mutex.synchronize { @initialize_request = nil }
          end
        end

        private def decode_initialization(json : String) : Wire::InitializeResult
          data = Protocol::RawJson.from_json(json)
          number = data.field("protocolVersion").try(&.as_i64?)
          version = number.to_u16 if number && (0..UInt16::MAX).includes?(number)
          if version != Wire::VERSION
            if version == ACP::PROTOCOL_VERSION
              decode_result_json(Protocol::InitializeResult, json, AgentMethod::INITIALIZE)
            end
            raise VersionMismatchError.new(Wire::VERSION, version)
          end

          decode_result_json(Wire::InitializeResult, json, AgentMethod::INITIALIZE)
        end

        # Commit the client offer and the Agent's result before dispatching the
        # next frame. The dispatcher already holds the pending mutex.
        private def apply_initialization(offer : Wire::InitializeParams, result : Wire::InitializeResult) : Nil
          advertised = offer.capabilities
          session = advertised.session
          suggestions = session.try(&.prompt_suggestions)
          prompt = result.capabilities.session.try(&.prompt)
          @client_capabilities.elicitation = advertised.elicitation
          @skill_commands_negotiated = !!session.try(&.commands).try(&.skill) && !!prompt.try(&.skill)
          @mcp_acp_supported = !!result.capabilities.session.try(&.mcp).try(&.acp)
          @auth_status_supported = result.capabilities.auth_status?
          @suggestion_content_types = suggestions.try &.content_types(
            image: !!prompt.try(&.image), audio: !!prompt.try(&.audio),
            embedded_context: !!prompt.try(&.embedded_context))
          @initialize_offer = offer
          @v2_initialization_result = result
        end

        private def decode_initialization_response(response : PendingResponse) : Wire::InitializeResult
          raise response if response.is_a?(ProtocolError)

          wire = response.is_a?(Protocol::WireFrame) ? response.json : Protocol::WireFrame.encode(response)
          envelope = Protocol::RawJson.from_json(wire)
          unless envelope.field("jsonrpc").try(&.as_s?) == "2.0"
            raise ProtocolError.new("Agent returned a malformed initialization response")
          end
          error = envelope.field("error")
          result = envelope.field("result")
          return decode_initialization(result.json) if result && !error

          code = error.try(&.field("code")).try(&.as_i64?)
          message = error.try(&.field("message")).try(&.as_s?)
          unless !result && code && (Int32::MIN..Int32::MAX).includes?(code) && message
            raise ProtocolError.new("Agent returned a malformed initialization response")
          end

          data = begin
            error.try(&.field("data")).try(&.to_json_any)
          rescue JSON::ParseException
            nil
          end
          raise JsonRpcError.new(code.to_i32, message, data, received: true)
        end

        def submit_with_skills(params : Wire::SessionPromptParams, names : Array(String)) : JSON::Any
          method = AgentMethod::SESSION_PROMPT
          session_id = params.session_id
          builder = ->(id : Int64) { Protocol.build_request(id, method, params) }
          check_skills = -> do
            @pending_mutex.synchronize do
              raise ConnectionClosedError.new if @disconnected
              if @cursor_registry.try(&.replaying?(session_id))
                raise InvalidStateError.new("Skill references require a current command list after session replay")
              end

              advertised = @session_choices.command_skill_names(session_id)
              if name = names.find { |candidate| !advertised.try(&.includes?(candidate)) }
                raise InvalidStateError.new("Skill #{name.inspect} is not currently advertised for session #{session_id.inspect}")
              end
            end
          end
          response_result(send_and_await_response(method, builder, prompt_timeout, before_send: check_skills), method)
        end

        private def v2_wire? : Bool
          true
        end

        private def handle_session_update(params : JSON::Any?, params_json : String?) : Nil
          if params
            raw_update = params.as_h?.try(&.["update"]?).try(&.as_h?)
            suggestion_update = raw_update.try(&.["sessionUpdate"]?).try(&.as_s?) == "prompt_suggestions_update"
            return if suggestion_update && !@suggestion_content_types

            begin
              update = Protocol::V2::SessionUpdateParams.from_json(params_json || Protocol::WireFrame.encode(params))
              if params_json && update.update.session_update.in?("state_update", "subagent_update", "available_commands_update", "config_option_update")
                update_json = Protocol::WireFrame.field(params_json, "update")
              end
              return unless observe_v2_session_update(update.session_id, params["update"].as_h, update_json)
              if update.update.session_update == "cursor_update" && (cursor = update.update.typed.as?(Protocol::CursorUpdate))
                observe_cursor_update(update.session_id, cursor)
              end
              if suggestion_update && (types = @suggestion_content_types)
                suggestions = update.update.typed.as?(Wire::PromptSuggestionsUpdate) || return
                suggestions.suggestions.select! { |suggestion| suggestion.allowed?(types) }
                suggestion_list = JSON.parse(Protocol::WireFrame.encode(suggestions.suggestions))
                update.update.json_unmapped["suggestions"] = suggestion_list
              end
            rescue ex : JSON::ParseException
              ClientLog.warn { "Failed to parse v2 session/update: #{ex.message}" }
              deliver_raw_session_update(params, params_json) unless suggestion_update
              return
            end
            return if deliver_update(update)
            if suggestion_list
              deliver_suggestion_notification(params, params_json, suggestion_list)
              return
            end
          end
          deliver_raw_session_update(params, params_json)
        end

        private def deliver_update(update : Wire::SessionUpdateParams) : Bool
          return false unless handler = @on_v2_update

          begin
            handler.call(update)
          rescue ex
            ClientLog.error { "Error in v2 session update handler: #{ex.message}" }
          end
          true
        end

        private def prepare_agent_request(id : Protocol::RequestId?, method_name : String, params : JSON::Any?, params_json : String?) : (-> AgentReply)?
          return super unless method_name == ClientMethod::SESSION_REQUEST_PERMISSION

          input = Wire::RequestPermissionParams.from_json(params_json || params.to_json)
          input.request_id = id
          subject = input.typed_subject
          if command = subject.try(&.command)
            unless Wire.absolute_path?(command.cwd)
              return invalid_permission("The command's working directory must be absolute")
            end
          end
          if input.options.empty? || input.options.map(&.option_id).uniq.size != input.options.size
            return invalid_permission("Permission requests require a non-empty list of unique option IDs")
          end
          if subject && subject.tool_call
            fields = subject.json_unmapped["toolCall"].as_h.dup
            fields["sessionUpdate"] = JSON::Any.new("tool_call_update")
            if observe_v2_session_update(input.session_id, fields)
              fields.delete("sessionUpdate")
              update = Wire::SessionUpdate.new("tool_call_update", fields)
              deliver_update(Wire::SessionUpdateParams.new(input.session_id, update))
            end
          end
          -> { handle_v2_permission(input) }
        rescue JSON::ParseException
          invalid_permission("Malformed ACP v2 permission request")
        end

        private def invalid_permission(message : String) : -> AgentReply
          -> { Protocol::JsonRpcErrorObject.new(JsonRpcError::INVALID_PARAMS, message).as(AgentReply) }
        end

        private def handle_v2_permission(input : Wire::RequestPermissionParams) : AgentReply
          result = @on_request_permission.try(&.call(input)) || Wire::RequestPermissionResult.cancelled
          JSON.parse(result.to_json)
        rescue ex
          ClientLog.error { "Error handling permission request: #{ex.message}" }
          handler_error_reply(ex, "Permission handler error: #{ex.message}")
        end

        private def route_agent_request(method_name : String, params : JSON::Any?, params_json : String?) : JSON::Any | Protocol::JsonRpcErrorObject
          if method_name == Protocol::V2::ClientMethod::ELICITATION_CREATE ||
             Protocol::ExtensionMethod.extension?(method_name)
            return super
          end

          Protocol::JsonRpcErrorObject.new(JsonRpcError::METHOD_NOT_FOUND, "Client does not handle method: #{method_name}")
        end
      end

      private struct InheritMetadata
      end

      # Transport used by this protocol connection.
      getter transport : Transport

      # Implementation identity of the latest successful handshake, or the initial default.
      def info : Wire::Implementation
        @connection.initialization_offer.try(&.info) || @info
      end

      # Client capabilities of the latest successful handshake, or the initial default.
      def capabilities : Wire::ClientCapabilities
        @connection.initialization_offer.try(&.capabilities) || @capabilities
      end

      # Handler for custom Agent-to-Client requests.
      property on_extension_request : AgentRequestHandler?

      # Resolves custom system prompt modes advertised through an ACP extension.
      property on_system_prompt_mode : Protocol::SystemPromptModeResolver?

      @initializing = Atomic(Bool).new(false)
      @terminal_auth_running = Atomic(Bool).new(false)

      # Creates a v2 client over an existing transport.
      def initialize(
        @transport : Transport,
        @info : Wire::Implementation = Wire::Implementation.new("acp-crystal", ACP::VERSION),
        @capabilities : Wire::ClientCapabilities = Wire::ClientCapabilities.new,
        *,
        @mcp_request_limit : Int32 = 32,
      )
        @connection = Connection.new(@transport, mcp_request_limit: @mcp_request_limit)
        @connection.on_agent_request = ->handle_extension_request(String, JSON::Any)
      end

      # Default timeout in seconds for requests.
      delegate request_timeout, :"request_timeout=", to: @connection

      # Registers a native MCP handler for use in this connection's sessions.
      def register_mcp_server(name : String, *, meta : Hash(String, JSON::Any)? = nil, &handler : McpRequestHandler) : Wire::McpServerAcp
        @connection.register_mcp_server(name, meta: meta, &handler)
      end

      # Retires a registration and signals cancellation to its active handlers.
      def unregister_mcp_server(server_id : Wire::McpServerAcpId) : Bool
        @connection.unregister_mcp_server(server_id)
      end

      # Timeout in seconds for prompt insertion acknowledgements.
      delegate prompt_timeout, :"prompt_timeout=", to: @connection

      # Callback for v2 session updates and permission tool patches in wire order.
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

      # Handler for permission requests. The default outcome is cancelled.
      delegate on_request_permission, :"on_request_permission=", to: @connection

      # Callback for advertised elicitation modes and their URL completion.
      delegate on_create_elicitation, :"on_create_elicitation=", on_elicitation_complete, :"on_elicitation_complete=", to: @connection

      # Callback for draft authentication status changes from the Agent.
      delegate on_auth_status_update, :"on_auth_status_update=", to: @connection

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

      # Cursor snapshots scoped to their originating session.
      delegate session_cursor, session_cursors, to: @connection

      # Initializes the connection or repeats the handshake before its first
      # other request. Optional arguments replace the advertised values on
      # success. An Agent error leaves the last successful handshake active.
      def initialize_connection(*, info : Wire::Implementation? = nil,
                                capabilities : Wire::ClientCapabilities? = nil,
                                meta : Hash(String, JSON::Any) | Nil | InheritMetadata = InheritMetadata.new) : Wire::InitializeResult
        _, started = @initializing.compare_and_set(false, true)
        raise InvalidStateError.new("ACP v2 initialization is already in progress") unless started

        previous = initialization_result
        begin
          if @terminal_auth_running.get
            raise InvalidStateError.new("Cannot initialize during terminal authentication")
          end
          previous_offer = @connection.initialization_offer
          metadata = meta.is_a?(InheritMetadata) ? previous_offer.try(&.meta) : meta
          offer = Wire::InitializeParams.new(info || previous_offer.try(&.info) || @info,
            capabilities: capabilities || previous_offer.try(&.capabilities) || @capabilities, meta: metadata)
          @connection.initialize_v2(offer)
        rescue ex : JsonRpcError
          close if !previous && ex.unsupported_protocol_version?
          raise ex
        ensure
          @initializing.set(false)
        end
      end

      # Selects an advertised Agent-managed authentication flow.
      def auth_login(method_id : String) : Wire::AuthLoginResult
        @connection.with_request do
          method = ready.auth_methods.find { |candidate| candidate.method_id == method_id }
          raise InvalidStateError.new("An advertised Agent auth method is required") unless method && method.agent?

          request(AgentMethod::AUTH_LOGIN, Wire::AuthLoginParams.new(method_id), Wire::AuthLoginResult)
        end
      end

      # Ends authentication when the Agent advertised authentication methods.
      def auth_logout : Wire::AuthLogoutResult
        @connection.with_request do
          raise InvalidStateError.new("The Agent advertised no auth methods") if ready.auth_methods.empty?

          request(AgentMethod::AUTH_LOGOUT, Wire::AuthLogoutParams.new, Wire::AuthLogoutResult)
        end
      end

      # Queries the Agent's draft authentication status when it advertises support.
      def auth_status(params : Wire::AuthStatusParams = Wire::AuthStatusParams.new) : Wire::AuthStatusResult
        @connection.with_request do
          unless ready.capabilities.auth_status?
            raise InvalidStateError.new("The Agent did not advertise auth.status")
          end

          request(AgentMethod::AUTH_STATUS, params, Wire::AuthStatusResult)
        end
      end

      # Lists the Agent's configurable model providers and current routing.
      def providers_list(params : Wire::ListProvidersParams = Wire::ListProvidersParams.new) : Wire::ListProvidersResult
        @connection.with_request do
          ensure_provider_support
          @connection.request_typed(AgentMethod::PROVIDERS_LIST, params, Wire::ListProvidersResult)
        end
      end

      # Replaces the full routing configuration for one provider.
      def providers_set(params : Wire::SetProviderParams) : Wire::SetProviderResult
        @connection.with_request do
          ensure_provider_support
          unless valid_provider_url?(params.base_url)
            raise ArgumentError.new("ACP v2 provider base URLs must be absolute URIs")
          end
          @connection.request_typed(AgentMethod::PROVIDERS_SET, params, Wire::SetProviderResult)
        end
      end

      # Disables a provider after checking that the Agent does not require it.
      def providers_disable(params : Wire::DisableProviderParams) : Wire::DisableProviderResult
        @connection.with_request do
          ensure_provider_support
          if providers_list.required?(params.provider_id)
            raise InvalidStateError.new("The Agent requires this provider")
          end
          @connection.request_typed(AgentMethod::PROVIDERS_DISABLE, params, Wire::DisableProviderResult)
        end
      end

      # Disables the specified non-mandatory provider.
      def providers_disable(provider_id : Wire::ProviderId) : Wire::DisableProviderResult
        providers_disable(Wire::DisableProviderParams.new(provider_id))
      end

      # Runs the approved terminal auth flow and returns the reinitialized client.
      def authenticate_terminal(method_id : String, &approve : Wire::AuthMethod -> Bool) : Client
        _, started = @terminal_auth_running.compare_and_set(false, true)
        raise InvalidStateError.new("Terminal authentication is already in progress") unless started

        begin
          if @initializing.get
            raise InvalidStateError.new("Cannot authenticate a terminal during initialization")
          end
          terminal_auth_flow(method_id, approve)
        ensure
          @terminal_auth_running.set(false)
        end
      end

      # Creates a session with typed workspace and MCP settings.
      def session_new(params : Wire::SessionNewParams) : Wire::SessionNewResult
        @connection.with_request do
          caps = session_capabilities
          validate_setup(caps, params.cwd, params.additional_directories, params.mcp_servers, params.system_prompt, params.config_options)
          @connection.attach_with_choices(AgentMethod::SESSION_NEW, params, Wire::SessionNewResult)
        end
      end

      # Creates a session in the given absolute directory.
      def session_new(cwd : String, *, config_options : Array(Wire::InitialSessionConfigOption)? = nil) : Wire::SessionNewResult
        session_new(Wire::SessionNewParams.new(cwd, config_options: config_options))
      end

      # Attaches to an existing session and can request history replay.
      def session_resume(params : Wire::SessionResumeParams) : Wire::SessionResumeResult
        @connection.with_request do
          caps = session_capabilities
          validate_setup(caps, params.cwd, params.additional_directories, params.mcp_servers, params.system_prompt, params.config_options)
          @connection.attach_with_choices(AgentMethod::SESSION_RESUME, params, Wire::SessionResumeResult, params.session_id)
        end
      end

      # Forks a session and returns the new active session's initial state.
      def session_fork(params : Wire::SessionForkParams) : Wire::SessionForkResult
        @connection.with_request do
          caps = session_capabilities
          raise InvalidStateError.new("The Agent did not advertise session.fork") unless caps.fork

          validate_setup(caps, params.cwd, params.additional_directories, params.mcp_servers, params.system_prompt, params.config_options)
          @connection.attach_with_choices(AgentMethod::SESSION_FORK, params, Wire::SessionForkResult)
        end
      end

      # Forks a source session into the given working directory.
      def session_fork(session_id : String, cwd : String, *, cursor_id : String? = nil) : Wire::SessionForkResult
        session_fork(Wire::SessionForkParams.new(session_id, cwd, cursor_id: cursor_id))
      end

      # Lists available sessions using the provided filter and cursor.
      def session_list(params : Wire::SessionListParams = Wire::SessionListParams.new) : Wire::SessionListResult
        @connection.with_request do
          caps = session_capabilities
          if params.archived && !caps.archive
            raise InvalidStateError.new("The Agent did not advertise session.archive")
          end
          if (cwd = params.cwd) && !Wire.absolute_path?(cwd)
            raise ArgumentError.new("The ACP v2 session list directory must be absolute")
          end
          @connection.request_typed(AgentMethod::SESSION_LIST, params, Wire::SessionListResult)
        end
      end

      # Previews options and commands before creating or restoring a session.
      def session_options(params : Wire::SessionOptionsParams) : Wire::SessionOptionsResult
        @connection.with_request do
          raise InvalidStateError.new("The Agent did not advertise session.options") unless session_capabilities.options
          unless Protocol.absolute_workspace?(params.cwd, params.additional_directories)
            raise ArgumentError.new("ACP v2 session directories must be absolute")
          end

          @connection.request_typed(AgentMethod::SESSION_OPTIONS, params, Wire::SessionOptionsResult)
        end
      end

      # Previews options and commands for a new session in the given workspace.
      def session_options(cwd : String) : Wire::SessionOptionsResult
        session_options(Wire::SessionOptionsParams.new(cwd))
      end

      # Queries a session and its foreground snapshot without attaching to it.
      def session_status(session_id : String, *, meta : Hash(String, JSON::Any)? = nil) : Wire::SessionStatusResult
        @connection.with_request do
          unless session_capabilities.status
            raise InvalidStateError.new("The Agent did not advertise session.status")
          end

          @connection.request_typed(AgentMethod::SESSION_STATUS, Wire::SessionStatusParams.new(session_id, meta), Wire::SessionStatusResult)
        end
      end

      # Sets the title of a session and returns the title the Agent stored.
      def session_set_title(session_id : String, title : String, *, meta : Hash(String, JSON::Any)? = nil) : Wire::SetSessionTitleResult
        @connection.with_request do
          unless session_capabilities.title
            raise InvalidStateError.new("The Agent did not advertise session.title")
          end

          @connection.request_typed(AgentMethod::SESSION_SET_TITLE, Wire::SetSessionTitleParams.new(session_id, title, meta), Wire::SetSessionTitleResult)
        end
      end

      # Closes and archives the session while preserving its saved history.
      def session_archive(session_id : String, *, meta : Hash(String, JSON::Any)? = nil) : Wire::SessionArchiveResult
        @connection.with_request do
          ensure_archive_support
          @connection.request_typed(AgentMethod::SESSION_ARCHIVE, Wire::SessionArchiveParams.new(session_id, meta), Wire::SessionArchiveResult)
        end
      end

      # Restores the session to default list results without attaching to it.
      def session_unarchive(session_id : String, *, meta : Hash(String, JSON::Any)? = nil) : Wire::SessionUnarchiveResult
        @connection.with_request do
          ensure_archive_support
          @connection.request_typed(AgentMethod::SESSION_UNARCHIVE, Wire::SessionUnarchiveParams.new(session_id, meta), Wire::SessionUnarchiveResult)
        end
      end

      # Enqueues prompt insertion. The returned message ID acknowledges insertion.
      # Set retry_submission only when resending the original prompt and key.
      def session_prompt(params : Wire::SessionPromptParams, *, retry_submission : Bool = false) : Wire::SessionPromptResult
        @connection.with_request do
          caps = session_capabilities
          if key = params.idempotency_key
            unless key.size.in?(1..255)
              raise ArgumentError.new("ACP v2 idempotency keys must contain 1 to 255 characters")
            end
          elsif retry_submission
            raise ArgumentError.new("Retrying an ACP v2 submission requires its original idempotency key")
          end
          skills = validate_prompt(caps.prompt, params.prompt)
          # The Agent resolves keyed retries even if the command list has changed
          # since insertion or since an earlier connection.
          raw = if !skills.empty? && !retry_submission
                  @connection.submit_with_skills(params, skills)
                else
                  @connection.send_request(AgentMethod::SESSION_PROMPT, params, prompt_timeout)
                end
          decode(Wire::SessionPromptResult, raw, AgentMethod::SESSION_PROMPT)
        end
      end

      # Inserts a text prompt in a session.
      def session_prompt_text(session_id : String, text : String, idempotency_key : String? = nil) : Wire::SessionPromptResult
        blocks = [Protocol::TextContentBlock.new(text)] of Protocol::ContentBlock
        session_prompt(Wire::SessionPromptParams.new(session_id, blocks, idempotency_key))
      end

      # Requests foreground cancellation. The Agent identifies affected requests.
      def session_cancel(session_id : String) : Nil
        @connection.with_request do
          session_capabilities
          @connection.send_notification(AgentMethod::SESSION_CANCEL, Wire::SessionCancelParams.new(session_id))
        end
      end

      # Closes a session and its background work.
      def session_close(session_id : String) : Wire::SessionCloseResult
        @connection.with_request do
          session_capabilities
          @connection.retire_session(AgentMethod::SESSION_CLOSE, Wire::SessionCloseParams.new(session_id), Wire::SessionCloseResult)
        end
      end

      # Deletes a session when the Agent advertises deletion.
      def session_delete(session_id : String) : Wire::SessionDeleteResult
        @connection.with_request do
          raise InvalidStateError.new("The Agent did not advertise session deletion") unless session_capabilities.delete

          @connection.retire_session(AgentMethod::SESSION_DELETE, Wire::SessionDeleteParams.new(session_id), Wire::SessionDeleteResult)
        end
      end

      # Latest foreground and background snapshot for an attached root session.
      def session_state(session_id : String) : Wire::StateSnapshot?
        if snapshot = session_state_raw(session_id)
          Wire::StateSnapshot.from_json(snapshot.json)
        end
      end

      # Session state with exact extension fields and numeric values.
      def session_state_raw(session_id : String) : Protocol::RawJson?
        @connection.state_raw(session_id)
      end

      # Latest unambiguous command advertisements for an attached session.
      def session_available_commands(session_id : String) : Array(Wire::AvailableCommand)?
        @connection.available_commands(session_id)
      end

      # Exact advertised list, including extension commands and precise numbers.
      def session_available_commands_raw(session_id : String) : Protocol::RawJson?
        @connection.available_commands_raw(session_id)
      end

      # Latest configuration options for an attached session in Agent order.
      def session_config_options(session_id : String) : Array(Wire::ConfigOption)?
        @connection.config_options(session_id)
      end

      # Exact option list, including extension variants and wide numbers.
      def session_config_options_raw(session_id : String) : Protocol::RawJson?
        @connection.config_options_raw(session_id)
      end

      # Changes a session configuration option.
      def session_set_config_option(params : Wire::SessionSetConfigOptionParams) : Wire::SessionSetConfigOptionResult
        @connection.with_request do
          session_capabilities
          case params.value_type
          when "id"
            raise ArgumentError.new("ACP v2 configuration IDs must be strings") if params.value.as_s?.nil?
          when "boolean"
            raise ArgumentError.new("ACP v2 boolean option values must be booleans") if params.value.as_bool?.nil?
          end
          @connection.request_option_change(params)
        end
      end

      # Cancels a tool call with an advertised cancel marker.
      def tool_call_cancel(session_id : String, tool_call_id : String) : Wire::ToolCallCancelResult
        @connection.with_request do
          session_capabilities
          request(AgentMethod::TOOL_CALL_CANCEL, Wire::ToolCallCancelParams.new(session_id, tool_call_id), Wire::ToolCallCancelResult)
        end
      end

      # Cancels an Agent-owned terminal with an advertised cancel marker.
      def terminal_cancel(session_id : String, terminal_id : String) : Wire::TerminalCancelResult
        @connection.with_request do
          session_capabilities
          request(AgentMethod::TERMINAL_CANCEL, Wire::TerminalCancelParams.new(session_id, terminal_id), Wire::TerminalCancelResult)
        end
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

      private def ensure_archive_support : Nil
        unless session_capabilities.archive
          raise InvalidStateError.new("The Agent did not advertise session.archive")
        end
      end

      private def ensure_provider_support : Nil
        unless ready.capabilities.providers
          raise InvalidStateError.new("The Agent did not advertise providers")
        end
      end

      private def valid_provider_url?(value : String) : Bool
        return false if value.each_byte.any? { |byte| byte <= 32 || byte == 127 }

        uri = URI.parse(value)
        return false unless uri.absolute?
        return !uri.host.to_s.empty? if uri.scheme.try(&.downcase).in?("http", "https")

        true
      rescue URI::Error
        false
      end

      private def request(method : String, params : JSON::Serializable, type : T.class) : T forall T
        decode(type, @connection.send_request(method, params), method)
      end

      private def decode(type : T.class, raw : JSON::Any, method : String) : T forall T
        T.from_json(raw.to_json)
      rescue ex : JSON::ParseException
        raise ProtocolError.new("Agent returned a malformed result for '#{method}': #{ex.message}", ex)
      end

      private def handle_extension_request(method : String, params : JSON::Any) : JSON::Any
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
        config_options : Array(Wire::InitialSessionConfigOption)?,
      ) : Nil
        unless Protocol.absolute_workspace?(cwd, directories)
          raise ArgumentError.new("ACP v2 session directories must be absolute")
        end
        if directories && !caps.additional_directories
          raise InvalidStateError.new("The Agent did not advertise additionalDirectories")
        end
        if config_options
          raise InvalidStateError.new("The Agent did not advertise session.options") unless caps.options
          Protocol.validate_initial_config_options(config_options)
        end
        validate_mcp_servers(caps.mcp, servers) if servers
        if system_prompt
          support = caps.system_prompt || raise InvalidStateError.new("The Agent did not advertise systemPrompt")
          unless support.supports_mode?(system_prompt.mode, @on_system_prompt_mode)
            raise InvalidStateError.new("The Agent did not advertise systemPrompt #{system_prompt.mode.inspect}")
          end
          if system_prompt.content.empty? || !system_prompt.content.all?(Protocol::TextContentBlock)
            raise ArgumentError.new("ACP v2 system prompts require one or more text content blocks")
          end
        end
      end

      private def validate_mcp_servers(caps : Wire::McpCapabilities?, servers : Array(Wire::McpServer)) : Nil
        names = Set(String).new
        servers.each do |server|
          case server.transport_type
          when "stdio"
            raise InvalidStateError.new("The Agent did not advertise MCP stdio") unless caps.try(&.stdio)
            config = server.stdio_config || raise ArgumentError.new("Malformed ACP v2 MCP stdio configuration")
            raise ArgumentError.new("ACP v2 MCP commands must be absolute") unless Wire.absolute_path?(config.command)
          when "http"
            raise InvalidStateError.new("The Agent did not advertise MCP HTTP") unless caps.try(&.http)
            config = server.http_config || raise ArgumentError.new("Malformed ACP v2 MCP HTTP configuration")
            url = URI.parse(config.url)
            unless url.scheme.try(&.downcase).in?("http", "https") && url.host.try { |host| !host.empty? }
              raise ArgumentError.new("ACP v2 MCP HTTP servers require an absolute HTTP(S) URL")
            end
          when "sse"
            raise ArgumentError.new("ACP v2 does not define the MCP SSE transport")
          end
          if (name = server.json_unmapped["name"]?.try(&.as_s?)) && !names.add?(name)
            raise ArgumentError.new("ACP v2 MCP server names must be unique")
          end
        end
      rescue URI::Error
        raise ArgumentError.new("ACP v2 MCP HTTP servers require an absolute HTTP(S) URL")
      end

      private def validate_prompt(caps : Wire::PromptCapabilities?, blocks : Array(JSON::Any)) : Array(String)
        raise ArgumentError.new("ACP v2 prompts require at least one content block") if blocks.empty?

        skills = [] of String
        blocks.each_with_index do |block, index|
          kind = block.as_h?.try(&.["type"]?).try(&.as_s?) ||
                 raise ArgumentError.new("ACP v2 prompt content blocks require a type")
          case kind
          when "text", "resource_link"
          when "image"
            raise InvalidStateError.new("The Agent did not advertise image prompts") unless caps.try(&.image)
          when "audio"
            raise InvalidStateError.new("The Agent did not advertise audio prompts") unless caps.try(&.audio)
          when "resource"
            raise InvalidStateError.new("The Agent did not advertise embedded context") unless caps.try(&.embedded_context)
          when "skill"
            unless capabilities.session.try(&.commands).try(&.skill)
              raise InvalidStateError.new("The Client did not advertise support for skill commands")
            end
            support = caps.try(&.skill) || raise InvalidStateError.new("The Agent did not advertise skill prompts")
            if index != 0 && !support.inline
              raise ArgumentError.new("Only the first prompt block can reference a skill without inline support")
            end
            skill = Wire::SkillReference.from_content_block(block) || raise ArgumentError.new("Malformed ACP v2 skill reference")
            skills << skill.name
            next
          else
            next
          end
          Protocol::ContentBlock.from_json(block.to_json)
        end
        skills
      rescue JSON::ParseException
        raise ArgumentError.new("Malformed ACP v2 prompt content block")
      end

      private def terminal_auth_flow(method_id : String, approve : Wire::AuthMethod -> Bool) : Client
        method = ready.auth_methods.find { |candidate| candidate.method_id == method_id }
        transport = @transport.as?(ProcessTransport)
        unless transport && capabilities.auth.try(&.terminal) && method && (settings = method.terminal_settings)
          raise InvalidStateError.new("Terminal authentication requires an advertised terminal method and process transport")
        end
        raise AuthenticationError.new("Terminal authentication declined") unless approve.call(method)
        ready

        invocation = Protocol::TerminalAuthMethod.new(method_id, method.name, method.description, settings.args, settings.environment)
        status = transport.run_terminal_authentication(invocation)
        raise AuthenticationError.new("Terminal authentication exited unsuccessfully") unless status.success?
        ready

        replacement = Client.new(transport.reconnect, info, capabilities, mcp_request_limit: @mcp_request_limit)
        replacement.request_timeout = request_timeout
        replacement.prompt_timeout = prompt_timeout
        replacement.on_update = on_update
        replacement.on_notification = on_notification
        replacement.on_disconnect = on_disconnect
        replacement.on_request_permission = on_request_permission
        replacement.on_extension_request = on_extension_request
        replacement.on_create_elicitation = on_create_elicitation
        replacement.on_elicitation_complete = on_elicitation_complete
        replacement.on_auth_status_update = on_auth_status_update
        replacement.on_system_prompt_mode = on_system_prompt_mode
        begin
          replacement.initialize_connection(meta: @connection.initialization_offer.try(&.meta))
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
