require "uuid"
require "./transport"

module ACP
  # Supported MCP-over-ACP protocol revision.
  MCP_PROTOCOL_VERSION = "2026-07-28"

  private class McpFrameLimitError < ProtocolError
  end

  # Counts exact frames while their writers wait on the shared transport.
  private class McpOutputBudget
    MAX_BYTES = 32 * 1024 * 1024
    @bytes = 0_i64
    @mutex = Mutex.new

    def write(transport : Transport, frame : Protocol::WireFrame, &preflight : -> Nil) : Nil
      size = frame.json.bytesize
      @mutex.synchronize do
        if @bytes + size > MAX_BYTES
          raise McpFrameLimitError.new("MCP pending output exceeds the connection limit")
        end
        @bytes += size
      end
      begin
        transport.send_wire(frame, &preflight)
      ensure
        @mutex.synchronize { @bytes -= size }
      end
    end
  end

  # An active MCP operation supplied to a registered handler.
  class McpRequestContext
    SUBSCRIBE_METHOD    = "subscriptions/listen"
    SUBSCRIPTION_ACK    = "notifications/subscriptions/acknowledged"
    SUBSCRIPTION_ID_KEY = "io.modelcontextprotocol/subscriptionId"

    # Request envelope and the caller's exact MCP parameters.
    getter request : Protocol::MessageMcpRequest

    # The outer ACP request ID. MCP uses request.request_id instead.
    getter outer_id : Protocol::RequestId

    # Closes when the consumer, provider, or connection cancels the operation.
    getter cancellation = Channel(Nil).new

    @cancelled = Atomic(Bool).new(false)
    @finished = false
    @writing = Mutex.new
    @notifying = Atomic(Bool).new(false)
    @acknowledged = false

    # :nodoc:
    def initialize(@transport : Transport, @request : Protocol::MessageMcpRequest, @outer_id : Protocol::RequestId,
                   @output : McpOutputBudget)
    end

    # Whether the handler should stop its work and clean up.
    def cancelled? : Bool
      @cancelled.get
    end

    # Sends an MCP notification on this active operation. The handler is
    # responsible for selecting notifications using the MCP request context.
    def notify(method : String, params : Protocol::McpJson? = nil, *, meta : Protocol::McpJson? = nil) : Nil
      _, claimed = @notifying.compare_and_set(false, true)
      unless claimed
        cancel
        raise McpFrameLimitError.new("MCP operation already has a notification waiting to be written")
      end

      begin
        @writing.synchronize do
          ensure_notifiable
          subscription = @request.method == SUBSCRIBE_METHOD
          if subscription
            if @acknowledged == (method == SUBSCRIPTION_ACK)
              raise InvalidStateError.new("MCP subscriptions require one acknowledgement before other notifications")
            end
            params = subscription_metadata(params || Protocol::McpJson.from_json("{}"))
          end
          message = Protocol::MessageMcpNotification.new(@request.server_id, @request.request_id, method, params, meta)
          frame = frame_for({jsonrpc: "2.0", method: Protocol::AgentMethod::MCP_MESSAGE, params: message})
          raise McpFrameLimitError.new("MCP notification exceeds the frame limit") unless frame

          @output.write(@transport, frame) { ensure_notifiable }
          @acknowledged = true if subscription
        end
      ensure
        @notifying.set(false)
      end
    end

    # :nodoc:
    def cancel : Nil
      _, changed = @cancelled.compare_and_set(false, true)
      @cancellation.close if changed
    end

    # :nodoc:
    def finish(reply : Protocol::MessageMcpResponse | Protocol::JsonRpcErrorObject) : Nil
      @writing.synchronize do
        @finished = true
        return if @transport.closed?

        if cancelled?
          reply = Protocol::JsonRpcErrorObject.new(JsonRpcError::REQUEST_CANCELLED, "MCP request cancelled")
        elsif @request.method == SUBSCRIBE_METHOD && reply.is_a?(Protocol::MessageMcpResponse) && (result = reply.result)
          unless @acknowledged && result.object?
            raise ProtocolError.new("Successful MCP subscriptions require an acknowledgement and an object result")
          end
          reply = Protocol::MessageMcpResponse.success(subscription_metadata(result), reply.meta)
        end

        frame = if reply.is_a?(Protocol::MessageMcpResponse)
                  frame_for({jsonrpc: "2.0", id: @outer_id, result: reply})
                else
                  frame_for({jsonrpc: "2.0", id: @outer_id, error: reply})
                end
        raise McpFrameLimitError.new("MCP response exceeds the frame limit") unless frame

        @output.write(@transport, frame) { }
      end
    end

    private def frame_for(value) : Protocol::WireFrame?
      wire = Protocol::WireFrame.encode(value)
      Protocol::WireFrame.new(wire) if wire.bytesize <= StdioTransport::DEFAULT_MAX_LINE_BYTES
    end

    private def ensure_notifiable : Nil
      raise RequestCancelledError.new(@outer_id) if cancelled?
      raise InvalidStateError.new("The MCP operation has already finished") if @finished
    end

    private def subscription_metadata(payload : Protocol::McpJson) : Protocol::McpJson
      metadata = payload.field("_meta")
      metadata = Protocol::McpJson.from_json("{}") unless metadata.try(&.object?)
      payload.with_field("_meta", metadata.not_nil!.with_field(
        SUBSCRIPTION_ID_KEY, Protocol::McpJson.new(JSON::Any.new(@request.request_id))))
    end
  end

  # User handler for one admitted MCP request, including any cooperative cleanup.
  alias McpRequestHandler = McpRequestContext -> Protocol::MessageMcpResponse

  # Connection-local admission, routing, and cancellation for native MCP.
  private class McpProvider
    private MAX_OUTER_ID_BYTES = 1024
    private MAX_REQUEST_BYTES  = 32 * 1024 * 1024

    private record Registration, declaration : Protocol::McpServerAcp, handler : McpRequestHandler, published : Bool = false
    private record Rejection, id : Protocol::RequestId?, code : Int32, message : String
    private alias RequestKey = Tuple(String, String)

    @servers = {} of String => Registration
    @active = {} of RequestKey => McpRequestContext
    @by_outer_id = {} of Protocol::RequestId => McpRequestContext
    @rejection_ids = Set(Protocol::RequestId).new
    @rejection_count = 0
    @mutex = Mutex.new
    @output = McpOutputBudget.new
    @request_bytes = 0_i64
    @reject_started = false
    @closed = false
    @namespace : String?
    @sequence = 0_u64

    def initialize(@transport : Transport, @limit : Int32)
      raise ArgumentError.new("MCP request limit must be positive") unless @limit > 0

      @rejections = Channel(Rejection).new(32)
    end

    def register(name : String, meta : Hash(String, JSON::Any)?, handler : McpRequestHandler) : Protocol::McpServerAcp
      @mutex.synchronize do
        raise ConnectionClosedError.new if @closed || @transport.closed?

        @sequence += 1
        namespace = @namespace ||= UUID.random.to_s
        declaration = Protocol::McpServerAcp.new(name, "#{namespace}:#{@sequence}", meta)
        @servers[declaration.server_id] = Registration.new(declaration, handler)
        declaration
      end
    end

    def publish(ids : Array(String)) : Nil
      @mutex.synchronize do
        raise ConnectionClosedError.new if @closed

        registrations = ids.map do |id|
          @servers[id]? || raise InvalidStateError.new("ACP MCP server must be registered on this connection")
        end
        registrations.each do |registration|
          @servers[registration.declaration.server_id] = registration.copy_with(published: true)
        end
      end
    end

    def release(server_id : String) : Bool
      @mutex.synchronize do
        return false unless @servers.delete(server_id)

        @active.each_value { |context| context.cancel if context.request.server_id == server_id }
        true
      end
    end

    def cancel(id : Protocol::RequestId) : Bool
      @mutex.synchronize do
        return false unless context = @by_outer_id[id]?

        context.cancel
        true
      end
    end

    def active_outer?(id : Protocol::RequestId) : Bool
      @mutex.synchronize { @by_outer_id.has_key?(id) || @rejection_ids.includes?(id) }
    end

    def reject_collision : Nil
      reject(nil, JsonRpcError::INVALID_REQUEST, "MCP request outer ID is already active")
    end

    def reject_invalid_envelope : Nil
      reject(nil, JsonRpcError::INVALID_REQUEST, "MCP requests require JSON-RPC 2.0 and a usable outer ID")
    end

    def close(*, abort_writes : Bool = false) : Nil
      pending_writes = @mutex.synchronize do
        return if @closed

        @closed = true
        @servers.clear
        @active.each_value(&.cancel)
        @rejections.close
        !@active.empty? || @rejection_count > 0
      end
      @transport.close if abort_writes && pending_writes
    end

    def receive(id : Protocol::RequestId?, raw : String, collision : Bool = false) : Nil
      return reject(nil, JsonRpcError::INVALID_REQUEST, "MCP request requires a unique outer ID") unless id && !collision
      if id.is_a?(String) && id.bytesize > MAX_OUTER_ID_BYTES
        return reject(nil, JsonRpcError::MCP_RESOURCE_LIMIT, "MCP request outer ID exceeds the size limit")
      end
      return reject_collision if active_outer?(id)
      bytes = raw.bytesize.to_i64 + (id.is_a?(String) ? id.bytesize : 8)
      if bytes > StdioTransport::DEFAULT_MAX_LINE_BYTES
        return reject(id, JsonRpcError::MCP_RESOURCE_LIMIT, "MCP request exceeds the frame limit")
      end

      request = Protocol::MessageMcpRequest.from_json(raw)
      key = {request.server_id, request.request_id}
      admitted = @mutex.synchronize do
        return if @closed

        server = @servers[request.server_id]?
        if !server || !server.published
          Rejection.new(id, JsonRpcError::MCP_SERVER_UNAVAILABLE, "MCP server registration unavailable")
        elsif @active.has_key?(key)
          Rejection.new(id, JsonRpcError::INVALID_PARAMS, "MCP logical request is already active")
        elsif @active.size >= @limit || @request_bytes + bytes > MAX_REQUEST_BYTES
          Rejection.new(id, JsonRpcError::MCP_RESOURCE_LIMIT, "MCP active request limit exceeded")
        else
          context = McpRequestContext.new(@transport, request, id, @output)
          @active[key] = context
          @by_outer_id[id] = context
          @request_bytes += bytes
          {context, server.handler}
        end
      end
      case admitted
      in Rejection
        reject(admitted.id, admitted.code, admitted.message)
      in Tuple
        context, handler = admitted
        spawn(name: "acp-mcp-request") { execute(key, context, handler, bytes) }
      end
    rescue JSON::Error
      reject(id, JsonRpcError::INVALID_PARAMS, "Malformed MCP request envelope")
    end

    private def execute(key : RequestKey, context : McpRequestContext, handler : McpRequestHandler, bytes : Int64) : Nil
      outcome = if context.cancelled?
                  Protocol::JsonRpcErrorObject.new(JsonRpcError::REQUEST_CANCELLED, "MCP request cancelled")
                else
                  run_handler(context, handler)
                end
      context.finish(outcome)
    rescue McpFrameLimitError
      send_rejection(Rejection.new(context.outer_id, JsonRpcError::MCP_RESOURCE_LIMIT, "MCP response exceeds the frame limit"))
    rescue ex : ProtocolError | JSON::Error
      send_rejection(Rejection.new(context.outer_id, JsonRpcError::MCP_BACKEND_FAILURE, "MCP response could not be sent"))
    rescue TransportError
      # The connection closed during the operation.
    ensure
      @mutex.synchronize do
        @active.delete(key)
        @by_outer_id.delete(context.outer_id)
        @request_bytes -= bytes
      end
    end

    private def run_handler(context : McpRequestContext, handler : McpRequestHandler) : Protocol::MessageMcpResponse | Protocol::JsonRpcErrorObject
      request = context.request
      if error = validate_metadata(request)
        return Protocol::MessageMcpResponse.failure(error)
      end
      if request.method.in?("initialize", "notifications/initialized")
        return Protocol::MessageMcpResponse.failure(Protocol::McpError.new(JsonRpcError::METHOD_NOT_FOUND, "MCP method unavailable in this revision"))
      end
      outcome = handler.call(context)
      if request.method == "server/discover" && (result = outcome.result)
        versions = result.field("supportedVersions").try(&.to_json_any.as_a?)
        supported = versions.try(&.any? { |version| version.as_s? == MCP_PROTOCOL_VERSION })
        narrowed = supported ? [MCP_PROTOCOL_VERSION] : [] of String
        outcome = Protocol::MessageMcpResponse.success(
          result.with_field("supportedVersions", Protocol::McpJson.from_json(narrowed.to_json)), outcome.meta)
      end
      outcome
    rescue McpFrameLimitError
      Protocol::JsonRpcErrorObject.new(JsonRpcError::MCP_RESOURCE_LIMIT, "MCP notification exceeds the frame limit")
    rescue
      Protocol::JsonRpcErrorObject.new(JsonRpcError::MCP_BACKEND_FAILURE, "MCP handler failed")
    end

    private def validate_metadata(request : Protocol::MessageMcpRequest) : Protocol::McpError?
      metadata = request.params.try(&.field("_meta"))
      version = metadata.try(&.field("io.modelcontextprotocol/protocolVersion")).try(&.as_s?)
      if version && version != MCP_PROTOCOL_VERSION
        data = Protocol::McpJson.from_json({supported: [MCP_PROTOCOL_VERSION], requested: version}.to_json)
        return Protocol::McpError.new(-32022, "Unsupported MCP protocol version", data)
      end
      if !version || !metadata.try(&.field("io.modelcontextprotocol/clientCapabilities")).try(&.object?)
        return Protocol::McpError.new(JsonRpcError::INVALID_PARAMS, "MCP request requires protocol version and client capabilities")
      end
      if info = metadata.try(&.field("io.modelcontextprotocol/clientInfo"))
        unless info.field("name").try(&.as_s?) && info.field("version").try(&.as_s?)
          return Protocol::McpError.new(JsonRpcError::INVALID_PARAMS, "Malformed MCP client information")
        end
      end
      nil
    end

    private def reject(id : Protocol::RequestId?, code : Int32, message : String) : Nil
      @mutex.synchronize do
        return if @closed

        unless @reject_started
          @reject_started = true
          spawn(name: "acp-mcp-rejections") do
            while rejection = @rejections.receive?
              begin
                send_rejection(rejection)
              ensure
                @mutex.synchronize do
                  @rejection_ids.delete(rejection.id)
                  @rejection_count -= 1
                end
              end
            end
          end
        end
        select
        when @rejections.send(Rejection.new(id, code, message))
          @rejection_ids.add(id) if id
          @rejection_count += 1
        else
          # A peer that stops reading cannot grow an unbounded rejection queue.
          # Stop accepting new work and close outside the dispatcher.
          @closed = true
          @servers.clear
          @active.each_value(&.cancel)
          @rejections.close
          spawn(name: "acp-mcp-overload-close") { @transport.close }
        end
      end
    end

    private def send_rejection(rejection : Rejection) : Nil
      @transport.send(Protocol.build_error_response(rejection.id, rejection.code, rejection.message))
    rescue TransportError
    end
  end
end
