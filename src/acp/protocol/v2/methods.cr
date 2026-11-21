require "../client_methods"

module ACP
  module Protocol
    module V2
      # Methods and notifications sent to Agents in ACP v2 Preview.
      module AgentMethod
        INITIALIZE                = "initialize"
        AUTH_LOGIN                = "auth/login"
        AUTH_LOGOUT               = "auth/logout"
        AUTH_STATUS               = Protocol::AgentMethod::AUTH_STATUS
        SESSION_NEW               = "session/new"
        SESSION_SET_CONFIG_OPTION = "session/set_config_option"
        SESSION_PROMPT            = "session/prompt"
        SESSION_CANCEL            = "session/cancel"
        SESSION_LIST              = "session/list"
        SESSION_STATUS            = Protocol::AgentMethod::SESSION_STATUS
        SESSION_DELETE            = "session/delete"
        SESSION_RESUME            = "session/resume"
        SESSION_CLOSE             = "session/close"
        TOOL_CALL_CANCEL          = "tool_call/cancel"
        TERMINAL_CANCEL           = "terminal/cancel"
      end

      # Methods and notifications sent to Clients in ACP v2 Preview.
      module ClientMethod
        SESSION_REQUEST_PERMISSION = "session/request_permission"
        SESSION_UPDATE             = "session/update"
        ELICITATION_CREATE         = "elicitation/create"
        ELICITATION_COMPLETE       = "elicitation/complete"
        AUTH_STATUS_UPDATE         = Protocol::ClientMethod::AUTH_STATUS_UPDATE
      end

      # Methods and notifications shared by ACP v2 Preview peers.
      module ProtocolMethod
        CANCEL_REQUEST = Protocol::ProtocolMethod::CANCEL_REQUEST
      end
    end
  end
end
