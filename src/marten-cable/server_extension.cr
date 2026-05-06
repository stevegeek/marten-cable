module MartenCable
  # The handler chain we mirror from Marten::Server.handlers (Marten 0.6/0.7).
  #
  # We can't call previous_def or super on a module-level self method, so
  # the reopen has to restate the upstream chain. If Marten changes its
  # handlers, this needs updating in lockstep.
  #
  # Cable::Handler sits between Middleware and Routing:
  #
  #   - HTTP middleware (logger, error, session) wraps the WS handshake
  #     — important for session-based auth on connect.
  #   - WebSocket upgrades are intercepted before the router tries to
  #     dispatch them as ordinary HTTP handlers.
  #   - Plain HTTP requests fall through to Routing as normal.
end
