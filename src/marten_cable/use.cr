module MartenCable
  # User-facing wiring macro. In the user's project (typically alongside
  # config), call:
  #
  #     MartenCable.use ApplicationCable::Connection
  #
  # That:
  #   - Sets `Cable.settings.backend_class` to `MartenCable::InProcessBackend`
  #     and `Cable.settings.url` to `"in-process://"` **only if Cable's
  #     defaults are still in place** (i.e. `backend_class` is still the
  #     sentinel `Cable::BackendRegistry`). A prior `Cable.configure` block
  #     that already picked a backend (e.g. `Cable::RedisBackend`) is left
  #     alone — so `MartenCable.use` no longer silently clobbers it. To
  #     force-revert to the in-process backend, set the fields back to
  #     `Cable::BackendRegistry` / `nil`-equivalent and call `use` again, or
  #     simply set them yourself after `use` returns.
  #   - Reopens `Marten::Server.handlers` to slot
  #     `MartenCable::UpgradeGuard.new(Cable::Handler(C).new)` ABOVE
  #     Marten's Middleware handler. On a WebSocket upgrade Cable hijacks
  #     the socket and returns without writing to
  #     `context.marten.response`. If Cable sat between Middleware and
  #     Routing, Marten's Middleware adapter would unconditionally call
  #     `context.marten.response.not_nil!` after `call_next` returned —
  #     boom, NilAssertionError. Putting Cable above Middleware lets a
  #     successful upgrade short-circuit Marten's chain cleanly. Non-WS
  #     requests fall through `Cable::Handler#call_next` and proceed
  #     into Marten's normal Middleware → Routing chain unchanged.
  #
  # `UpgradeGuard` enforces `allowed_hosts`, `Origin`, and per-message
  # size limits at the upgrade boundary — see `upgrade_guard.cr` for the
  # rationale. The non-WS pass-through case is untouched.
  #
  # ## Handler-chain drift
  #
  # The reopened `Marten::Server.handlers` reproduces upstream Marten's
  # handler list verbatim (see `lib/marten/src/marten/server.cr`) and
  # inserts `UpgradeGuard` between `Handlers::Error` and `Handlers::Middleware`.
  # `previous_def` would be the principled splice — but `Marten::Server`
  # currently returns `Array(HTTP::Handler)` without exposing splice points,
  # and the order between Error/Middleware/Routing is load-bearing for
  # the WS hijack to work. The hand-rolled copy is intentional, and the
  # smoke spec asserts the chain shape end-to-end so any upstream Marten
  # change to `Server.handlers` immediately surfaces as a spec failure
  # here rather than as a silent drop of a handler in production.
  macro use(connection_class)
    {% raise "MartenCable.use: #{connection_class} must be a Cable::Connection subclass" unless connection_class.resolve <= ::Cable::Connection %}

    # Exposed for assertions / exception messages — e.g. tests that want
    # to confirm `MartenCable.use` wired in a specific connection class.
    # Emitted as a method (not a constant) so calling `MartenCable.use`
    # twice with different connection classes is well-defined (the
    # latter wins, mirroring the handler-chain replacement below) rather
    # than raising "already initialized constant MartenCable::CONNECTION_CLASS"
    # at compile time. Common triggers for the second call: a host app
    # that wires Cable in production but the spec helper does the same
    # for tests; multi-binary build setups; require'ing both library and
    # test config files.
    module ::MartenCable
      def self.connection_class : ::Cable::Connection.class
        {{ connection_class }}
      end
    end

    # Only set the default in-process backend if Cable's settings are still
    # at their out-of-the-box defaults. A prior `Cable.configure` (e.g. for
    # cable-redis) wins. `Cable::BackendRegistry` is the sentinel default —
    # see `lib/cable/src/cable.cr` `setting backend_class`.
    if ::Cable.settings.backend_class == ::Cable::BackendRegistry
      ::Cable.configure do |settings|
        settings.backend_class = ::MartenCable::InProcessBackend
        settings.url = "in-process://"
      end
    end

    module ::Marten::Server
      def self.handlers
        [
          ::HTTP::ErrorHandler.new,
          ::Marten.settings.debug? ? ::Marten::Server::Handlers::DebugLogger.new : ::Marten::Server::Handlers::Logger.new,
          ::Marten::Server::Handlers::Error.new,
          ::MartenCable::UpgradeGuard.new(::Cable::Handler({{ connection_class }}).new),
          ::Marten::Server::Handlers::Middleware.new,
          ::Marten::Server::Handlers::Routing.new,
        ] of ::HTTP::Handler # load-bearing: do not remove during cleanup — without the explicit element type Crystal infers the union of the concrete classes and `HTTP::Server#initialize` rejects the array.
      end
    end
  end
end
