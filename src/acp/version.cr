module ACP
  VERSION = "0.1.0"

  # The latest ACP protocol version this client implements. This is the
  # version sent in the `initialize` request.
  PROTOCOL_VERSION = 1_u16

  # The oldest ACP protocol version this client can still speak. The
  # `initialize` handshake is a negotiation: the agent replies with the
  # version it will use — the same version when it supports our request,
  # otherwise the latest version *it* supports (which may be lower). The
  # client accepts any returned version within
  # [`MIN_PROTOCOL_VERSION`, `PROTOCOL_VERSION`] and proceeds using it.
  MIN_PROTOCOL_VERSION = 1_u16

  # Whether this client can speak the given negotiated protocol version.
  def self.supports_protocol_version?(version : UInt16) : Bool
    version >= MIN_PROTOCOL_VERSION && version <= PROTOCOL_VERSION
  end
end
