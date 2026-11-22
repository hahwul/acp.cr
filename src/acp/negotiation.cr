require "./v2_client"

module ACP
  # Starts an Agent subprocess and negotiates its ACP version. If the Agent
  # selects v1, restarts it with the v1 identity and capabilities on the wire.
  # Returns the initialized version-specific client. Close it when finished.
  def self.connect_negotiated(
    command : String,
    args : Array(String) = [] of String,
    *,
    info : Protocol::ClientInfo = Protocol::ClientInfo.new("acp-crystal", VERSION),
    v1_capabilities : Protocol::ClientCapabilities = Protocol::ClientCapabilities.new,
    v2_capabilities : Protocol::V2::ClientCapabilities = Protocol::V2::ClientCapabilities.new,
    env : Process::Env = nil,
    chdir : String? = nil,
    meta : Hash(String, JSON::Any) | Protocol::RawJson | Nil = nil,
  ) : Client | V2::Client
    connect_negotiated(info: info, v1_capabilities: v1_capabilities, v2_capabilities: v2_capabilities, meta: meta) do
      ProcessTransport.new(command, args, env, chdir)
    end
  end

  # Negotiates ACP over a transport factory. The factory opens a fresh
  # connection on every call and is called again only after a v1 selection.
  def self.connect_negotiated(
    *,
    info : Protocol::ClientInfo = Protocol::ClientInfo.new("acp-crystal", VERSION),
    v1_capabilities : Protocol::ClientCapabilities = Protocol::ClientCapabilities.new,
    v2_capabilities : Protocol::V2::ClientCapabilities = Protocol::V2::ClientCapabilities.new,
    meta : Hash(String, JSON::Any) | Protocol::RawJson | Nil = nil,
    &open_transport : -> Transport
  ) : Client | V2::Client
    v2 = V2::Client.new(open_transport.call, info, v2_capabilities)
    begin
      v2.initialize_connection(meta: meta)
      return v2
    rescue ex
      v2.close rescue nil
      raise ex unless ex.is_a?(VersionMismatchError) && ex.agent_version == PROTOCOL_VERSION
    end

    v1 = Client.new(open_transport.call, client_capabilities: v1_capabilities, client_info: info)
    begin
      v1.initialize_connection(meta: meta)
      v1
    rescue ex
      v1.close rescue nil
      raise ex
    end
  end
end
