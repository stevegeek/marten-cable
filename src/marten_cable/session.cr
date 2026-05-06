module MartenCable
  # Session-aware auth helper for WebSocket upgrade handshakes.
  #
  # Cable's `Connection#initialize` runs *before* Marten's middleware stack
  # has touched the request: see `marten_cable/use.cr`, which slots
  # `Cable::Handler` between `Marten::Server::Handlers::Middleware` and
  # `Routing`. The middleware operates on `Marten::HTTP::Request`, not on
  # the bare `HTTP::Server::Context` request that Cable's handler receives,
  # so `request.session` is never populated for the upgrade.
  #
  # `MartenCable::Session.for(request)` reads the Marten session cookie
  # directly off the raw `HTTP::Request` and instantiates the configured
  # session store. The store deserializes lazily on first key access (see
  # `Marten::HTTP::Session::Store::Base#session_hash`), so this helper is
  # cheap when no session cookie is present and the standard Marten
  # tamper/expiry checks still apply when one is.
  #
  # Example usage in an `ApplicationCable::Connection#connect`:
  #
  #     def connect
  #       session = MartenCable::Session.for(request)
  #       if session && (uid = session["user_id"]?)
  #         self.identifier = uid
  #       else
  #         reject_unauthorized_connection
  #       end
  #     end
  module Session
    # Returns a loaded Marten session store for `request`, or `nil` if no
    # session cookie is present. A returned store may still be empty (e.g.
    # the cookie was tampered with or expired) — Marten's cookie store
    # silently falls back to a fresh hash in that case.
    def self.for(request : ::HTTP::Request) : ::Marten::HTTP::Session::Store::Base?
      cookie_name = ::Marten.settings.sessions.cookie_name
      raw_cookie = request.cookies[cookie_name]?
      return nil if raw_cookie.nil?

      session_key = raw_cookie.value
      return nil if session_key.empty?

      store_class = ::Marten::HTTP::Session::Store.get(::Marten.settings.sessions.store)
      store_class.new(session_key)
    end
  end
end
