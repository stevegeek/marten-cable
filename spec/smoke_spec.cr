require "spec"
require "../src/marten_cable"

# Marten requires SOME settings to be defined before referencing
# Marten.settings — even just the secret key. Set up a minimal stub.
Marten.configure do |config|
  config.secret_key = "marten-cable-spec-secret"
  config.installed_apps = [] of Marten::Apps::Config.class
end

class TestConnection < Cable::Connection
  identified_by :identifier

  def connect
    self.identifier = "anon"
  end
end

MartenCable.use(TestConnection)

describe MartenCable do
  it "registers the in-process backend" do
    Cable.settings.backend_class.should eq(MartenCable::InProcessBackend)
  end

  it "rebuilds Marten::Server.handlers with Cable::Handler injected" do
    handlers = Marten::Server.handlers
    cable_handlers = handlers.select { |handler| handler.is_a?(Cable::Handler(TestConnection)) }
    cable_handlers.size.should eq(1)
  end

  it "places Cable::Handler ABOVE Marten's Middleware handler" do
    # Cable::Handler hijacks the socket on a WebSocket upgrade and returns
    # without writing to context.marten.response. If it sat between
    # Middleware and Routing, Marten's Middleware adapter would call
    # `context.marten.response.not_nil!` after `call_next` returned and
    # crash with NilAssertionError. Cable must be ABOVE Middleware so a
    # successful upgrade short-circuits the whole Marten chain cleanly.
    handlers = Marten::Server.handlers
    error_idx = handlers.index! { |handler| handler.is_a?(Marten::Server::Handlers::Error) }
    cable_idx = handlers.index! { |handler| handler.is_a?(Cable::Handler(TestConnection)) }
    middleware_idx = handlers.index! { |handler| handler.is_a?(Marten::Server::Handlers::Middleware) }
    routing_idx = handlers.index! { |handler| handler.is_a?(Marten::Server::Handlers::Routing) }
    error_idx.should be < cable_idx
    cable_idx.should be < middleware_idx
    middleware_idx.should be < routing_idx
  end
end
