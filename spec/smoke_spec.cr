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

  it "places Cable::Handler before Routing and after Middleware" do
    handlers = Marten::Server.handlers
    middleware_idx = handlers.index! { |handler| handler.is_a?(Marten::Server::Handlers::Middleware) }
    cable_idx = handlers.index! { |handler| handler.is_a?(Cable::Handler(TestConnection)) }
    routing_idx = handlers.index! { |handler| handler.is_a?(Marten::Server::Handlers::Routing) }
    middleware_idx.should be < cable_idx
    cable_idx.should be < routing_idx
  end
end
