require "./transport"
require "./protocol/proxy"

module ACP
  # The direction of a message presented to a proxy handler.
  enum ProxyDirection
    # From the client toward the terminal agent.
    Downstream

    # From the agent toward the initial client.
    Upstream
  end

  # Routes the draft ACP Proxy Chains protocol over supplied transports.
  #
  # Use an exact-frame transport on every connection. This instance owns the
  # transports and closes the chain when any component disconnects.
  class Conductor
    # Handles one message before forwarding it in either direction.
    alias MessageHandler = (Protocol::ProxySuccessorMessage, ProxyDirection, Bool -> Protocol::ProxySuccessorMessage | Protocol::ProxyReply | Nil)

    # Transforms a successful local initialization response.
    alias InitializationHandler = (Protocol::RawJson -> Protocol::RawJson)

    # Runs synchronously on the routing fiber. Return a message to forward it,
    # a reply to handle a request locally, or nil to drop a notification or
    # return method-not-found for a request. The Bool is true for requests.
    property on_message : MessageHandler?

    # Runs synchronously on successful successor initialization. May change
    # advertised fields while retaining the negotiated protocol version.
    property on_initialize_result : InitializationHandler?

    private alias Raw = Protocol::RawJson
    private alias Method = Protocol::ProxyMethod
    private alias Message = Protocol::ProxySuccessorMessage
    private alias Reply = Protocol::ProxyReply
    private alias Id = Protocol::RequestId
    private alias RouteKey = Tuple(Int32, Id?)
    private alias Event = Tuple(Int32, Transport::IncomingFrame?)

    private INITIALIZE           = Protocol::AgentMethod::INITIALIZE
    private MAX_PENDING_ID_BYTES = StdioTransport::DEFAULT_MAX_LINE_BYTES
    private CANCEL               = Protocol::ProtocolMethod::CANCEL_REQUEST

    private record Endpoint, peer : Int32, wrapped : Bool = false
    private record Route,
      source : Int32,
      id : Raw,
      key : RouteKey,
      target : RouteKey,
      initialization : Initialization?

    private class Initialization
      getter offered : UInt16
      getter parent : Initialization?
      property child : Initialization?
      property? finished = false
      property version : UInt16?

      def initialize(@offered : UInt16, @parent : Initialization?)
      end
    end

    private class Frame
      getter id : Raw?
      getter method : Raw?
      getter params : Raw?
      getter result : Raw?
      getter error : Raw?
      getter? valid_version = false
      getter? repeated_id = false

      def initialize(wire : String)
        pull = JSON::PullParser.new(wire)
        return unless pull.kind.begin_object?

        pull.read_object do |key|
          case key
          when "jsonrpc" then @valid_version = Raw.new(pull).as_s? == "2.0"
          when "id"
            @repeated_id = true if @id
            @id = Raw.new(pull)
          when "method" then @method = Raw.new(pull)
          when "params" then @params = Raw.new(pull)
          when "result" then @result = Raw.new(pull)
          when "error"  then @error = Raw.new(pull)
          else               pull.skip
          end
        end
      end
    end

    @events = Channel(Event).new(8)
    @stop = Channel(Nil).new
    @lifecycle = Mutex.new
    @closed = false
    @running = false
    @version : UInt16?
    @pending_id_bytes = 0
    @started = false
    @root_initializing = false
    @next_id = 0_i64
    @requests = {} of RouteKey => Route
    @responses = {} of RouteKey => Route
    @handshakes = {} of Int32 => Initialization
    @peers : Array(Transport)
    @outbox : Array(Channel(Protocol::WireFrame))
    @proxy_count : Int32
    @terminal : Bool
    @versions : Array(UInt16)

    # Builds a terminal chain with an agent, or a nested chain with an external
    # successor if `agent` is nil. Proxies are ordered from client to agent.
    # `versions` controls local protocol negotiation. `max_pending` bounds the
    # total number of in-flight requests outside the initialization exchange.
    def initialize(upstream : Transport, agent : Transport?, *, proxies : Enumerable = [] of Transport,
                   versions : Array(UInt16) = [PROTOCOL_VERSION, Protocol::V2::VERSION],
                   @max_pending : Int32 = 256)
      @peers = [upstream] of Transport
      proxies.each { |proxy| @peers << proxy }
      @proxy_count = @peers.size - 1
      @terminal = !agent.nil?
      @peers << agent if agent
      @versions = versions.uniq.sort
      unless @versions.all? { |version| version.in?(PROTOCOL_VERSION, Protocol::V2::VERSION) }
        raise ArgumentError.new("Conductor supports ACP versions 1 and 2")
      end
      unless @peers.map(&.object_id).uniq.size == @peers.size
        raise ArgumentError.new("Each conductor peer requires its own transport")
      end
      if @peers.any? { |peer| peer.is_a?(StdioTransport) && !peer.exact_frames? }
        raise ArgumentError.new("Use exact_frames: true on conductor transports")
      end
      raise ArgumentError.new("max_pending must be positive") unless @max_pending > 0

      @outbox = Array.new(@peers.size) { Channel(Protocol::WireFrame).new(4) }
    end

    # Runs the relay until it is closed or a component disconnects. Call once.
    def run : Nil
      active = @lifecycle.synchronize do
        raise InvalidStateError.new("Conductor is already running") if @running
        next false if @closed

        @running = true
      end
      return unless active

      begin
        @peers.each_with_index do |peer, index|
          spawn read_peer(peer, index)
          spawn write_peer(peer, @outbox[index])
        end
        loop do
          select
          when event = @events.receive
            peer, frame = event
            break if !frame || @stop.closed?
            process(peer, frame)
          when @stop.receive?
            break
          end
        end
      rescue TransportError | Channel::ClosedError
        # A failed hop closes the chain, including all pending requests.
      ensure
        close
        @requests.clear
        @responses.clear
        @handshakes.clear
      end
    end

    # Stops the relay and closes its transports. Safe to call more than once.
    def close : Nil
      pending = @lifecycle.synchronize do
        next false if @closed

        @closed = true
        @stop.close
        @events.close
        @outbox.each(&.close)
        true
      end
      return unless pending

      # Close IO promptly on every hop even when subprocess termination waits.
      complete = Channel(Nil).new(@peers.size)
      @peers.each do |peer|
        spawn do
          begin
            peer.close
          rescue IO::Error | TransportError
            Log.warn { "Could not close an ACP conductor peer" }
          ensure
            complete.send(nil)
          end
        end
      end
      @peers.size.times { complete.receive }
      # Closed buffered channels retain their queued values until drained.
      while @events.receive?
      end
      @outbox.each do |queue|
        while queue.receive?
        end
      end
    end

    private def read_peer(peer : Transport, index : Int32) : Nil
      while frame = peer.receive_frame
        return unless report_event(index, frame)
      end
    rescue IO::Error | TransportError | Channel::ClosedError
      # Report the lost connection to the routing loop.
    ensure
      report_event(index, nil)
    end

    private def report_event(index : Int32, frame : Transport::IncomingFrame?) : Bool
      select
      when @events.send({index, frame})
        true
      when @stop.receive?
        false
      end
    rescue Channel::ClosedError
      false
    end

    private def write_peer(peer : Transport, queue : Channel(Protocol::WireFrame)) : Nil
      while frame = queue.receive?
        break if @stop.closed?
        peer.send_wire(frame) { nil }
      end
    rescue IO::Error | TransportError | ProtocolError | Channel::ClosedError
      close
    end

    private def emit(peer : Int32, &build : JSON::Builder ->) : Nil
      return if @stop.closed?

      wire = JSON.build do |json|
        json.max_nesting = 512
        json.object do
          json.field("jsonrpc", "2.0")
          build.call(json)
        end
      end
      frame = Protocol::WireFrame.new(wire, exact_params: true)
      select
      when @outbox[peer].send(frame)
      when @stop.receive?
      when timeout(5.seconds)
        raise TransportTimeoutError.new("ACP conductor output blocked")
      end
    end

    private def process(peer : Int32, incoming : Transport::IncomingFrame) : Nil
      wire = incoming.is_a?(Protocol::WireFrame) ? incoming.json : Protocol::WireFrame.encode(incoming)
      frame = Frame.new(wire)
      id = frame.id
      if frame.repeated_id?
        return reject(peer, frame.method ? Raw.from_json("null") : nil, JsonRpcError::INVALID_REQUEST, "Ambiguous JSON-RPC id")
      end
      if frame.method.try(&.as_s?).in?(CANCEL, Method::SUCCESSOR) &&
         !Protocol::WireFrame.repeated_members(wire, "jsonrpc", "method", "params").empty?
        return reject(peer, id ? Raw.from_json("null") : nil, JsonRpcError::INVALID_REQUEST, "Ambiguous cancellation or successor envelope")
      end
      unless frame.valid_version?
        return receive_response(peer, id, frame) if id && !frame.method
        return reject(peer, Raw.from_json("null"), JsonRpcError::INVALID_REQUEST, "Invalid request")
      end

      if method = frame.method
        name = method.as_s?
        unless name && !frame.result && !frame.error && (!id || valid_id?(id))
          return reject(peer, Raw.from_json("null"), JsonRpcError::INVALID_REQUEST, "Invalid request")
        end
        if id && @requests.has_key?({peer, key(id)})
          return reject(peer, Raw.from_json("null"), JsonRpcError::INVALID_REQUEST, "Request ID is already in use")
        end
        route(peer, name, frame.params, id)
      elsif id
        receive_response(peer, id, frame)
      else
        reject(peer, Raw.from_json("null"), JsonRpcError::INVALID_REQUEST, "Invalid request")
      end
    end

    private def proxy?(peer : Int32) : Bool
      peer > 0 && peer <= @proxy_count
    end

    private def downstream(peer : Int32) : Endpoint
      peer < @peers.size - 1 ? Endpoint.new(peer + 1) : Endpoint.new(0, wrapped: true)
    end

    private def upstream(peer : Int32) : Endpoint
      target = peer == 0 ? @proxy_count : peer - 1
      Endpoint.new(target, wrapped: proxy?(target))
    end

    private def route(peer : Int32, method : String, params : Raw?, id : Raw?) : Nil
      if method == CANCEL
        return cancel(peer, params, id)
      end

      expected = @terminal ? INITIALIZE : Method::INITIALIZE
      if peer == 0 && method == expected
        return initialize_root(peer, params, id)
      end

      wrapped = method == Method::SUCCESSOR
      direction = if wrapped
                    unless successor_peer?(peer)
                      return reject(peer, id, JsonRpcError::INVALID_REQUEST, "Invalid successor peer")
                    end
                    begin
                      inner = Message.from_json(params.try(&.json) || "null")
                    rescue JSON::Error
                      return reject(peer, id, JsonRpcError::INVALID_PARAMS, "Invalid successor envelope")
                    end
                    method, params = inner.method, inner.params
                    if method == CANCEL
                      return cancel(peer, params, id)
                    end
                    if method == INITIALIZE && proxy?(peer)
                      return initialize_successor(peer, params, id)
                    end
                    peer == 0 ? ProxyDirection::Upstream : ProxyDirection::Downstream
                  else
                    peer == 0 ? ProxyDirection::Downstream : ProxyDirection::Upstream
                  end

      if reserved?(method) || !@version || @root_initializing
        return reject(peer, id, JsonRpcError::INVALID_REQUEST, "Unexpected method for this connection")
      end
      if params && !params.object? && !params.array? && !params.null?
        return reject(peer, id, JsonRpcError::INVALID_PARAMS, "Params must be an object or array")
      end
      @started = true if id
      target = direction.downstream? ? downstream(peer) : upstream(peer)
      original = Message.new(method, params)
      decision = begin
        callback = @on_message
        callback ? callback.call(original, direction, !id.nil?) : original
      rescue
        return reject(peer, id, JsonRpcError::INTERNAL_ERROR, "Proxy handler failed")
      end
      case decision
      when Message
        if reserved?(decision.method) || decision.method == CANCEL
          return reject(peer, id, JsonRpcError::INTERNAL_ERROR, "Proxy handler returned a reserved method")
        end
        forward(peer, target, decision, id)
      when Reply
        respond(peer, id, decision.result, decision.error) if id
      when Nil
        reject(peer, id, JsonRpcError::METHOD_NOT_FOUND, "Method not found")
      end
    end

    private def successor_peer?(peer : Int32) : Bool
      if peer == 0
        !@terminal && !!(@version || @root_initializing)
      else
        proxy?(peer) && (!!@version || @handshakes.has_key?(peer))
      end
    end

    private def reserved?(method : String) : Bool
      method.in?(INITIALIZE, Method::INITIALIZE, Method::SUCCESSOR)
    end

    private def initialize_root(peer : Int32, params : Raw?, id : Raw?) : Nil
      return unless id
      if @root_initializing || @started || (@version && !@versions.includes?(Protocol::V2::VERSION))
        return reject(peer, id, JsonRpcError::INVALID_REQUEST, "Unexpected initialization")
      end

      initialize_hop(peer, params, id)
    end

    private def initialize_successor(peer : Int32, params : Raw?, id : Raw?) : Nil
      return unless id
      handshake = @handshakes[peer]?
      unless handshake && !handshake.child
        return reject(peer, id, JsonRpcError::INVALID_REQUEST, "Unexpected successor initialization")
      end

      initialize_hop(peer, params, id, handshake)
    end

    private def initialize_hop(peer : Int32, params : Raw?, id : Raw, parent : Initialization? = nil) : Nil
      offered = version(params)
      unless offered && params
        return reject(peer, id, JsonRpcError::INVALID_PARAMS, "Invalid protocolVersion")
      end
      if id.null? && (offered >= Protocol::V2::VERSION || @version == Protocol::V2::VERSION)
        return reject(peer, id, JsonRpcError::INVALID_REQUEST, "Null request ID")
      end

      selected = @versions.reverse_each.find { |supported| supported <= offered }
      # The reference conductor applies v1's legacy fallback below v1 when
      # v1 is available, including on builds that also support v2.
      if offered == 0 && @versions.includes?(PROTOCOL_VERSION)
        selected = PROTOCOL_VERSION
      end
      unless selected
        data = Raw.from_json(Protocol::WireFrame.encode(Protocol::V2::UnsupportedProtocolVersionData.new(offered, @versions)))
        return reject(peer, id, JsonRpcError::UNSUPPORTED_PROTOCOL_VERSION, "Unsupported protocol version", data)
      end
      if parent && selected > parent.offered
        return reject(peer, id, JsonRpcError::INVALID_PARAMS, "Protocol version increased across a proxy")
      end

      if id.json.bytesize > MAX_PENDING_ID_BYTES - @pending_id_bytes
        return reject(peer, id, JsonRpcError::INTERNAL_ERROR, "Too much pending request ID data")
      end
      pending = Initialization.new(selected, parent)
      if parent
        parent.child = pending
      else
        @root_initializing = true
      end
      target = downstream(peer)
      proxy_target = proxy?(target.peer) && !target.wrapped
      @handshakes[target.peer] = pending if proxy_target
      forwarded = selected == offered ? params : rewrite_version(params, selected)
      forward(peer, target, Message.new(proxy_target ? Method::INITIALIZE : INITIALIZE, forwarded), id, pending)
    end

    private def version(value : Raw?) : UInt16?
      number = value.try(&.field("protocolVersion")).try(&.as_i64?)
      number.to_u16 if number && (0..UInt16::MAX).includes?(number)
    end

    private def rewrite_version(params : Raw, selected : UInt16) : Raw
      incompatible = selected == PROTOCOL_VERSION ? {"info", "capabilities"} : {"clientInfo", "clientCapabilities"}
      pull = JSON::PullParser.new(params.json)
      json = JSON.build do |builder|
        builder.max_nesting = pull.max_nesting
        builder.object do
          pull.read_object do |key|
            if key == "protocolVersion" || incompatible.includes?(key)
              pull.skip
            else
              builder.field(key) { pull.read_raw(builder) }
            end
          end
          builder.field("protocolVersion", selected)
        end
      end
      Raw.from_json(json)
    end

    private def forward(source : Int32, target : Endpoint, message : Message, id : Raw?, initialization : Initialization? = nil) : Nil
      next_id = nil
      if id
        unless initialization
          if @requests.size >= @max_pending || id.json.bytesize > MAX_PENDING_ID_BYTES - @pending_id_bytes
            return reject(source, id, JsonRpcError::INTERNAL_ERROR, "Too many pending requests")
          end
        end
        @pending_id_bytes += id.json.bytesize
        @next_id += 1
        next_id = @next_id
        source_key = {source, key(id)}
        target_key = {target.peer, next_id.as(Id?)}
        route = Route.new(source, id, source_key, target_key, initialization)
        @requests[source_key] = route
        @responses[target_key] = route
      end

      emit(target.peer) do |json|
        json.field("id", next_id) if next_id
        if target.wrapped
          json.field("method", Method::SUCCESSOR)
          json.field("params", message)
        else
          json.field("method", message.method)
          json.field("params", message.params) if message.params
        end
      end
    end

    private def cancel(peer : Int32, params : Raw?, id : Raw?) : Nil
      return reject(peer, id, JsonRpcError::INVALID_REQUEST, "Expected a cancellation notification") if id
      return unless params && Protocol::WireFrame.repeated_members(params.json, "requestId").empty?

      request_id = params.field("requestId")
      return unless request_id && valid_id?(request_id)
      return unless route = @requests[{peer, key(request_id)}]?

      target, target_id = route.target
      emit(target) do |json|
        json.field("method", CANCEL)
        json.field("params") do
          json.object { json.field("requestId", target_id) }
        end
      end
    end

    private def receive_response(peer : Int32, id : Raw, frame : Frame) : Nil
      target = {peer, key(id)}
      return unless route = @responses.delete(target)

      @requests.delete(route.key)
      @pending_id_bytes -= route.id.json.bytesize
      result, error = frame.result, frame.error
      if !frame.valid_version? || (result && error) || (!result && !valid_error?(error))
        if route.initialization
          raise TransportError.new("Invalid initialization response from ACP peer")
        end
        reply = Reply.failure(JsonRpcError::INTERNAL_ERROR, "Invalid response from ACP peer")
        result, error = reply.result, reply.error
      end
      if pending = route.initialization
        result, error = finish_initialization(peer, pending, result, error)
      end
      respond(route.source, route.id, result, error)
    end

    private def finish_initialization(peer : Int32, pending : Initialization, result : Raw?, error : Raw?) : Tuple(Raw?, Raw?)
      proxy_target = @handshakes.delete(peer)
      @root_initializing = false unless pending.parent
      pending.finished = true
      child = pending.child
      if child && !child.finished?
        raise TransportError.new("Proxy answered initialization before its successor")
      end
      unless result
        # A peer that already accepted the new handshake cannot be rolled back.
        if child.try(&.version)
          raise TransportError.new("Proxy rejected an accepted successor initialization")
        end
        return {nil, error}
      end

      chosen = version(result)
      unless chosen && @versions.includes?(chosen) && chosen <= pending.offered &&
             (!proxy_target || child.try(&.version) == chosen)
        raise TransportError.new("Invalid protocol version returned during initialization")
      end
      unless pending.parent
        result = transform_initialization(result, chosen)
        @version = chosen
      end
      pending.version = chosen
      {result, nil}
    end

    private def transform_initialization(result : Raw, chosen : UInt16) : Raw
      callback = @on_initialize_result
      return result unless callback

      transformed = begin
        callback.call(result)
      rescue
        raise TransportError.new("Proxy initialization handler failed after the successor accepted")
      end
      unless version(transformed) == chosen
        raise TransportError.new("Proxy cannot change the negotiated protocol version")
      end
      transformed
    end

    private def valid_id?(id : Raw) : Bool
      !key(id).nil? || (@version != Protocol::V2::VERSION && id.null?)
    end

    private def key(id : Raw) : Id?
      id.as_i64? || id.as_s?
    end

    private def valid_error?(error : Raw?) : Bool
      return false unless error
      !error.field("code").try(&.as_i64?).nil? && !error.field("message").try(&.as_s?).nil?
    end

    private def reject(peer : Int32, id : Raw?, code : Int32, message : String, data : Raw? = nil) : Nil
      respond(peer, id, nil, Reply.failure(code, message, data).error) if id
    end

    private def respond(peer : Int32, id : Raw, result : Raw?, error : Raw?) : Nil
      emit(peer) do |json|
        json.field("id", id)
        if error
          json.field("error", error)
        else
          json.field("result", result)
        end
      end
    end
  end

  # A draft ACP proxy component that communicates with one conductor.
  #
  # With no callbacks installed, the proxy forwards ordinary ACP messages in
  # both directions and retains the successor's initialization result.
  class Proxy
    # Installs an optional message handler. See `Conductor#on_message`.
    delegate :on_message, :on_message=, to: @relay

    # Installs an optional initialization result transformer.
    delegate :on_initialize_result, :on_initialize_result=, to: @relay

    # Runs the proxy until it closes or loses its conductor.
    delegate run, to: @relay

    # Stops the proxy and closes the conductor transport.
    delegate close, to: @relay

    # Builds a proxy on a transport that preserves exact wire frames.
    def initialize(conductor : Transport, *, versions : Array(UInt16) = [PROTOCOL_VERSION, Protocol::V2::VERSION],
                   max_pending : Int32 = 256)
      @relay = Conductor.new(conductor, nil, versions: versions, max_pending: max_pending)
    end

    # Builds a stdio proxy, preserving exact JSON in both directions.
    def initialize(reader : IO, writer : IO, *, versions : Array(UInt16) = [PROTOCOL_VERSION, Protocol::V2::VERSION],
                   max_pending : Int32 = 256)
      transport = StdioTransport.new(reader, writer, exact_frames: true)
      @relay = begin
        Conductor.new(transport, nil, versions: versions, max_pending: max_pending)
      rescue ex
        transport.close
        raise ex
      end
    end
  end
end
