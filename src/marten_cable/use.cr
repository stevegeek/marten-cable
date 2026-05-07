module MartenCable
  # User-facing wiring macro. In the user's project (typically alongside
  # config), call:
  #
  #     MartenCable.use ApplicationCable::Connection
  #
  # That:
  #   - Sets Cable.settings.backend_class to MartenCable::InProcessBackend
  #     and Cable.settings.url to "in-process://" by default. Override
  #     after `use` if you want cable-redis or another backend.
  #   - Reopens Marten::Server.handlers to slot Cable::Handler(C) ABOVE
  #     Marten's Middleware handler. On a WebSocket upgrade Cable hijacks
  #     the socket and returns without writing to
  #     `context.marten.response`. If Cable sat between Middleware and
  #     Routing, Marten's Middleware adapter would unconditionally call
  #     `context.marten.response.not_nil!` after `call_next` returned —
  #     boom, NilAssertionError. Putting Cable above Middleware lets a
  #     successful upgrade short-circuit Marten's chain cleanly. Non-WS
  #     requests fall through `Cable::Handler#call_next` and proceed
  #     into Marten's normal Middleware → Routing chain unchanged.
  macro use(connection_class)
    {% if !flag?(:marten_cable_skip_default_backend) %}
      ::Cable.configure do |settings|
        settings.backend_class = ::MartenCable::InProcessBackend
        settings.url = "in-process://"
      end
    {% end %}

    module ::Marten::Server
      def self.handlers
        [
          ::HTTP::ErrorHandler.new,
          ::Marten.settings.debug? ? ::Marten::Server::Handlers::DebugLogger.new : ::Marten::Server::Handlers::Logger.new,
          ::Marten::Server::Handlers::Error.new,
          ::Cable::Handler({{ connection_class }}).new,
          ::Marten::Server::Handlers::Middleware.new,
          ::Marten::Server::Handlers::Routing.new,
        ] of ::HTTP::Handler
      end
    end
  end
end
