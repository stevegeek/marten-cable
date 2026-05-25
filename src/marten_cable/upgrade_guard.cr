module MartenCable
  # `HTTP::Handler` that wraps `Cable::Handler` and enforces three
  # security checks at the WebSocket upgrade boundary that the bare Cable
  # handler skips:
  #
  # 1. **Allowed-hosts** — Cable consumes the upgrade request from the raw
  #    `HTTP::Server::Context` before Marten's middleware ever materialises
  #    a `Marten::HTTP::Request`, so `Marten::HTTP::Request#host` (which
  #    triggers the `allowed_hosts` check) never runs. Without this guard
  #    an attacker can upgrade with an arbitrary `Host:` header.
  #
  # 2. **Origin** — browsers don't include CSRF tokens on the WebSocket
  #    handshake. The standard defence against cross-site WebSocket
  #    hijacking is to validate `Origin` against an allowlist. We derive
  #    the allowlist from `Marten.settings.allowed_hosts` so it tracks
  #    the host check 1:1 (mirroring Marten/Django wildcard semantics):
  #
  #      - `"*"` opts into accept-any-origin and logs a one-time warning
  #        on the first upgrade. Useful for development; never for prod.
  #      - `".example.com"` matches the bare domain `example.com` and any
  #        subdomain (`foo.example.com`, `a.b.example.com`, ...). The
  #        Origin host is compared with `URI.parse(origin).host`.
  #      - Any other entry is treated as a literal hostname; both
  #        `https://<h>` and `http://<h>` are accepted.
  #
  #    Set `MartenCable.configuration.allowed_origins` to short-circuit
  #    the derivation entirely (the configured list is exact-matched
  #    against the raw Origin string).
  #
  #    A missing `Origin` header is rejected with 403. Browsers always
  #    send `Origin` on a WS upgrade; a missing header signals a non-browser
  #    client which shouldn't be silently allowed through a cookie-auth
  #    boundary.
  #
  # 3. **Message size** — enforced separately by the runtime patch in
  #    `connection_message_limit.cr` (loaded alongside this handler) which
  #    intercepts `Cable::Connection#receive` to close oversize messages
  #    with WS close code 1009.
  #
  # Non-WebSocket requests pass through unchanged to the wrapped Cable
  # handler, which itself defers to `call_next` for non-upgrade paths.
  class UpgradeGuard
    include ::HTTP::Handler

    # Raised inside `call` to short-circuit the upgrade with a specific
    # HTTP status. Caught by `call` and translated to a response.
    class InvalidUpgradeError < Exception
      getter status_code : Int32

      def initialize(@status_code : Int32, message : String)
        super(message)
      end
    end

    def initialize(@cable_handler : ::HTTP::Handler)
    end

    # Reset memoised derivation of the origin allowlist from
    # `Marten.settings.allowed_hosts`. The allowlist is built lazily on the
    # first upgrade (so that `Marten.configure` blocks running after this
    # handler is constructed are picked up) and cached after that. Specs
    # that mutate `Marten.settings.allowed_hosts` between examples should
    # call this to force rebuild.
    def self.reset_origin_cache! : Nil
      @@origin_cache_mutex.synchronize do
        @@cached_allowed_hosts = nil
        @@cached_literal_origins = nil
        @@cached_origin_matchers = nil
        @@cached_allow_any_origin = false
        @@wildcard_warning_emitted = false
      end
    end

    @@origin_cache_mutex = Mutex.new
    @@cached_allowed_hosts : Array(String)? = nil
    @@cached_literal_origins : Array(String)? = nil
    @@cached_origin_matchers : Array(OriginMatcher)? = nil
    @@cached_allow_any_origin : Bool = false
    @@wildcard_warning_emitted : Bool = false

    # Matches a parsed `Origin` host against a host suffix pattern derived
    # from a Marten `allowed_hosts` wildcard entry (e.g. `.example.com`).
    # Accepts both the bare domain (`example.com`) and any subdomain
    # (`*.example.com`) — same semantics as Django/Marten's host check.
    private record OriginMatcher, base_host : String do
      def matches?(host : String) : Bool
        host == base_host || host.ends_with?(".#{base_host}")
      end
    end

    def call(context)
      is_upgrade = websocket_upgrade?(context.request)

      if is_upgrade
        begin
          validate_host!(context)
          validate_origin!(context)
        rescue ex : InvalidUpgradeError
          # Pre-upgrade rejection: socket hasn't been hijacked yet, so write
          # a normal HTTP response and return.
          context.response.status_code = ex.status_code
          context.response.content_type = "text/plain"
          context.response.print(ex.message)
          return
        end

        # Exceptions raised once Cable has accepted the upgrade must NOT be
        # allowed to propagate up to `Marten::Server::Handlers::Error`. By the
        # time Cable's handler is mid-upgrade the socket may already be
        # hijacked, and Marten's error handler would try to render a 500 into
        # a connection that no longer speaks HTTP. Catch everything, log it,
        # and best-effort close the WS with code 1011 ("internal error").
        begin
          @cable_handler.call(context)
        rescue ex : Exception
          ::Cable::Logger.error(exception: ex) do
            "MartenCable::UpgradeGuard: exception on WebSocket upgrade path — closing socket 1011"
          end
          close_upgrade_socket(context)
        end
      else
        # Non-upgrade path: a plain HTTP request flowing through Cable's
        # handler (it'll `call_next` for us). Let any exception bubble — the
        # outer Marten chain (`Handlers::Error`) handles it correctly because
        # the socket hasn't been hijacked.
        @cable_handler.call(context)
      end
    end

    private def close_upgrade_socket(context) : Nil
      response = context.response
      # If the response is still writable (we caught the exception BEFORE
      # Cable finished the WS handshake), emit a 500 so the client sees
      # something rather than a half-open connection. `closed?` is the only
      # publicly observable predicate; once Cable has upgraded the socket
      # the response's underlying output is closed and writes raise IO::Error
      # which we swallow.
      return if response.closed?
      response.status_code = 500
      response.content_type = "text/plain"
      response.print("Internal Server Error")
    rescue ::IO::Error
      # Response stream is in a broken state (e.g. socket already hijacked
      # or peer disconnected) — nothing useful to do, and propagating would
      # bubble the secondary IO error to Marten's error handler.
    end

    private def websocket_upgrade?(request : ::HTTP::Request) : Bool
      upgrade = request.headers["Upgrade"]?
      return false if upgrade.nil?
      return false unless upgrade.compare("websocket", case_insensitive: true) == 0
      request.headers.includes_word?("Connection", "Upgrade")
    end

    private def validate_host!(context)
      # Marten's host check lives in a private method, but it fires lazily
      # off `Marten::HTTP::Request#host`. Materialise one and ask for the
      # host — it raises `UnexpectedHost` if disallowed.
      ::Marten::HTTP::Request.new(context.request).host
    rescue ::Marten::HTTP::Errors::UnexpectedHost
      raise InvalidUpgradeError.new(400, "Disallowed Host header")
    end

    private def validate_origin!(context)
      origin = context.request.headers["Origin"]?
      if origin.nil? || origin.empty?
        raise InvalidUpgradeError.new(403, "Missing Origin header")
      end

      # Explicit `allowed_origins` overrides all derivation — exact-match
      # the raw Origin string (operators set the full scheme + host).
      if configured = MartenCable.configuration.allowed_origins
        return if configured.includes?(origin)
        raise InvalidUpgradeError.new(403, "Disallowed Origin")
      end

      derive_origin_cache!

      # `allowed_hosts = ["*"]` opts into accept-any-origin (with a loud
      # one-time warning at the first upgrade — operators sometimes forget
      # they set this in development).
      if @@cached_allow_any_origin
        emit_wildcard_warning_once
        return
      end

      origin_uri = parse_origin(origin)
      origin_host = origin_uri.try(&.host)

      # `derive_origin_cache!` above is the only writer of these caches and
      # always sets both, so the `||` fallbacks are unreachable in practice
      # — they're there to satisfy the type system without resorting to
      # `not_nil!` (which `ameba`'s `Lint/NotNil` flags).
      literal_origins = @@cached_literal_origins || [] of String
      return if literal_origins.includes?(origin)

      if origin_host
        matchers = @@cached_origin_matchers || [] of OriginMatcher
        return if matchers.any?(&.matches?(origin_host))
      end

      raise InvalidUpgradeError.new(403, "Disallowed Origin")
    end

    private def parse_origin(origin : String) : URI?
      URI.parse(origin)
    rescue URI::Error
      nil
    end

    private def emit_wildcard_warning_once : Nil
      @@origin_cache_mutex.synchronize do
        return if @@wildcard_warning_emitted
        @@wildcard_warning_emitted = true
        ::Marten::Log.warn do
          "MartenCable::UpgradeGuard: `allowed_hosts = [\"*\"]` accepts any Origin; not safe for production"
        end
      end
    end

    # Rebuild the cached allowlist if the source `allowed_hosts` array has
    # changed since the last build (spec-friendly: tests that mutate
    # `Marten.settings.allowed_hosts` between examples don't need to
    # remember to reset the cache).
    private def derive_origin_cache! : Nil
      hosts = ::Marten.settings.allowed_hosts
      return if @@cached_allowed_hosts == hosts && !@@cached_literal_origins.nil?

      @@origin_cache_mutex.synchronize do
        # Recheck after taking the lock — another fiber may have rebuilt.
        return if @@cached_allowed_hosts == hosts && !@@cached_literal_origins.nil?

        literal = [] of String
        matchers = [] of OriginMatcher
        allow_any = false

        hosts.each do |host|
          if host == "*"
            allow_any = true
            next
          end

          if host.starts_with?(".")
            # `.example.com` → match the bare domain and any subdomain.
            matchers << OriginMatcher.new(host[1..])
            next
          end

          # Plain hostname: derive both schemes; exact-equality check.
          literal << "https://#{host}"
          literal << "http://#{host}"
        end

        @@cached_allowed_hosts = hosts.dup
        @@cached_literal_origins = literal
        @@cached_origin_matchers = matchers
        # When toggling away from `["*"]`, also clear the
        # one-time-warning flag so a future flip-back will warn again.
        @@wildcard_warning_emitted = false unless allow_any
        @@cached_allow_any_origin = allow_any
      end
    end
  end
end
