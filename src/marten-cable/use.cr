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
  #   - Reopens Marten::Server.handlers to slot Cable::Handler(C) between
  #     Marten's Middleware and Routing handlers.
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
          ::Marten::Server::Handlers::Middleware.new,
          ::Cable::Handler({{connection_class}}).new,
          ::Marten::Server::Handlers::Routing.new,
        ] of ::HTTP::Handler
      end
    end
  end
end
