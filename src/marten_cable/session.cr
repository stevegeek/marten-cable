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
  # ## Auth is checked once
  #
  # The store is read at WS-upgrade time and never re-checked. That mirrors
  # the standard ActionCable model — but it means a user who logs out in
  # another tab keeps their existing WS connection until they reconnect or
  # the server forcibly disconnects them. To force-disconnect on logout,
  # call:
  #
  #     Cable.server.remote_connections.find(identifier: uid).disconnect
  #
  # from your logout handler.
  #
  # ## Tampered cookies and `modified?`
  #
  # If a tampered or expired session cookie is presented, Marten's
  # `Marten::HTTP::Session::Store::Cookie#load` rescues
  # `Marten::Core::Encryptor::InvalidValueError` and falls back to a fresh
  # empty `SessionHash` — but flips the store's `modified?` flag to `true`.
  # The current WS flow never persists the store (it has no per-request
  # `Marten::HTTP::Response` to attach a `Set-Cookie` header to), so this is
  # harmless today. **Anyone adding a "persist session on disconnect" hook
  # in future must explicitly skip persistence for stores returned from
  # this helper** — otherwise a tampered cookie would cause us to issue a
  # fresh `Set-Cookie` and inadvertently grant the attacker a clean session.
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
    # Cached configured session cookie name and store class symbol. Both
    # are read from `Marten.settings` exactly once per process, on the
    # first call to `.for`. Reconfiguring sessions after the first WS
    # upgrade has happened won't take effect. This is acceptable because
    # session configuration is a boot-time concern; tests that flip the
    # config (e.g. `session_spec.cr`) call `.reset_settings_cache!` to
    # invalidate the cache between examples.
    @@cached_cookie_name : String? = nil
    @@cached_store_id : String? = nil

    # Returns a loaded Marten session store for `request`, or `nil` if no
    # session cookie is present. A returned store may still be empty (e.g.
    # the cookie was tampered with or expired) — Marten's cookie store
    # silently falls back to a fresh hash in that case (and sets
    # `modified?`, see the module docstring).
    def self.for(request : ::HTTP::Request) : ::Marten::HTTP::Session::Store::Base?
      cookie_name = (@@cached_cookie_name ||= ::Marten.settings.sessions.cookie_name)
      raw_cookie = request.cookies[cookie_name]?
      return if raw_cookie.nil?

      # order matters: a present-but-empty cookie value would otherwise hit
      # the store constructor with `""`, which Marten's cookie store treats
      # as a corrupt-cookie load and would flip `modified?` for nothing.
      session_key = raw_cookie.value
      return if session_key.empty?

      store_id = (@@cached_store_id ||= ::Marten.settings.sessions.store)
      store_class = ::Marten::HTTP::Session::Store.get(store_id)
      store_class.new(session_key)
    end

    # Test-only: clear the boot-time cache of `cookie_name` / `store`.
    # Call from `before_each` when a spec mutates `Marten.settings.sessions`.
    def self.reset_settings_cache! : Nil
      @@cached_cookie_name = nil
      @@cached_store_id = nil
    end
  end
end
