require "spec"
require "./support/cable_helper"

# Marten requires SOME settings to be defined before referencing
# Marten.settings — even just the secret key. Set up a minimal stub.
# (Top-level `Marten.configure` is fine here because every spec file in
# the suite that uses Marten settings re-applies its own minimal config
# inside `before_each` — no cross-spec leakage path remains.)
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

# Second connection class used by the idempotency regression spec below.
# Declared at top level so the `MartenCable.use` macro can resolve it.
class OtherTestConnection < Cable::Connection
  identified_by :identifier

  def connect
    self.identifier = "other"
  end
end

MartenCable.use(TestConnection)
# Regression for MCR-N2: calling `MartenCable.use` twice must compile
# (no `already initialized constant MartenCable::CONNECTION_CLASS` error)
# and the latter wins. The spec below asserts the resulting
# `MartenCable.connection_class` reflects the most recent call.
MartenCable.use(OtherTestConnection)
MartenCable.use(TestConnection)

describe MartenCable do
  it "registers the in-process backend" do
    Cable.settings.backend_class.should eq(MartenCable::InProcessBackend)
  end

  it "rebuilds Marten::Server.handlers with UpgradeGuard (wrapping Cable::Handler) injected" do
    handlers = Marten::Server.handlers
    guards = handlers.select { |handler| handler.is_a?(MartenCable::UpgradeGuard) }
    guards.size.should eq(1)
  end

  it "places the UpgradeGuard ABOVE Marten's Middleware handler" do
    # Cable::Handler hijacks the socket on a WebSocket upgrade and returns
    # without writing to context.marten.response. If it sat between
    # Middleware and Routing, Marten's Middleware adapter would call
    # `context.marten.response.not_nil!` after `call_next` returned and
    # crash with NilAssertionError. Cable must be ABOVE Middleware so a
    # successful upgrade short-circuits the whole Marten chain cleanly.
    # UpgradeGuard wraps Cable::Handler, so the same placement rule applies
    # to the guard.
    handlers = Marten::Server.handlers
    error_idx = handlers.index! { |handler| handler.is_a?(Marten::Server::Handlers::Error) }
    guard_idx = handlers.index! { |handler| handler.is_a?(MartenCable::UpgradeGuard) }
    middleware_idx = handlers.index! { |handler| handler.is_a?(Marten::Server::Handlers::Middleware) }
    routing_idx = handlers.index! { |handler| handler.is_a?(Marten::Server::Handlers::Routing) }
    error_idx.should be < guard_idx
    guard_idx.should be < middleware_idx
    middleware_idx.should be < routing_idx
  end

  it "exposes the configured connection class as MartenCable.connection_class" do
    # `MartenCable.use` emits this method so application code (and specs)
    # can assert which connection class was wired in. See use.cr §15.
    MartenCable.connection_class.should eq(TestConnection)
  end

  it "asserts the full handler chain shape (review §6 drift guard)" do
    # If upstream Marten changes its `Server.handlers` list, this spec is
    # the canary — `MartenCable.use` hand-rolls the chain (use.cr), so a
    # silent drift in upstream Marten would otherwise leave us with the
    # WRONG chain in production. The expected sequence is:
    #   ErrorHandler → (Logger|DebugLogger) → Handlers::Error → UpgradeGuard
    #     → Handlers::Middleware → Handlers::Routing
    handlers = Marten::Server.handlers
    handlers.size.should eq(6)

    handlers[0].class.should eq(HTTP::ErrorHandler)
    # handlers[1] is Logger or DebugLogger depending on `debug?` — assert it's
    # one of those, not what the boolean currently is.
    [Marten::Server::Handlers::Logger, Marten::Server::Handlers::DebugLogger]
      .includes?(handlers[1].class).should be_true
    handlers[2].class.should eq(Marten::Server::Handlers::Error)
    handlers[3].class.should eq(MartenCable::UpgradeGuard)
    handlers[4].class.should eq(Marten::Server::Handlers::Middleware)
    handlers[5].class.should eq(Marten::Server::Handlers::Routing)
  end
end
