require "spec"
require "http/server"
require "http/web_socket"
require "./support/cable_helper"


# These specs drive `MartenCable::UpgradeGuard` directly via an HTTP::Server
# so we exercise the guard exactly the way it sits in `Marten::Server.handlers`
# — wrapping a `Cable::Handler` instance.
#
# Config is applied inside `before_each` (not at the top level) so this file
# is robust to sibling spec files that mutate `Cable.settings` /
# `Marten.settings` — see `support/cable_helper.cr` for the MCR2 rationale.

class UpgradeGuardConnection < Cable::Connection
  identified_by :identifier

  def connect
    self.identifier = token.to_s
  end
end

# Stub handler used by the MCR-N3 rescue regression spec — raises
# unconditionally when called, so we can prove `UpgradeGuard#call`'s rescue
# block converts the exception into a 500 / socket close rather than
# letting it propagate to Marten's error handler. Standing in for
# `Cable::Handler` makes this much easier to reason about than raising
# inside the real Cable upgrade path (the real path defers most of its
# work into the upgrade_handler callback that fires *after* the wrapped
# handler returns).
class RaisingStubHandler
  include HTTP::Handler

  class IntentionalSpecError < Exception
  end

  def call(context)
    raise IntentionalSpecError.new("intentional spec failure during cable handler call")
  end
end

# Terminal handler standing in for the handlers mounted AFTER the guard in
# `Marten::Server.handlers` (Middleware/Routing). Records that the chain
# actually reached it — see the next-forwarding regression spec.
class TerminalStubHandler
  include HTTP::Handler

  getter calls = 0

  def call(context)
    @calls += 1
    context.response.status_code = 200
    context.response.print("terminal reached")
  end
end

# Wraps `HTTP::Server` setup so the test scaffolding stays compact. Picks an
# ephemeral port so concurrent spec runs don't collide.
class UpgradeGuardServer
  getter address : Socket::IPAddress

  def initialize(handler : HTTP::Handler)
    @server = HTTP::Server.new([handler] of HTTP::Handler)
    @address = @server.bind_tcp("127.0.0.1", 0)
    @ready = ::Channel(Nil).new
  end

  # Chained variant: exercises the guard the way `Marten::Server.handlers`
  # actually mounts it — with further handlers AFTER it in the array.
  def initialize(handlers : Array(HTTP::Handler))
    @server = HTTP::Server.new(handlers)
    @address = @server.bind_tcp("127.0.0.1", 0)
    @ready = ::Channel(Nil).new
  end

  def start
    spawn do
      @ready.send(nil)
      @server.listen
    end
    @ready.receive
    Fiber.yield
  end

  def stop
    @server.close
  end
end

private def upgrade_request(server : UpgradeGuardServer, host : String, origin : String?) : HTTP::Client::Response
  client = HTTP::Client.new(server.address.address, server.address.port)
  headers = HTTP::Headers{
    "Host"                  => host,
    "Upgrade"               => "websocket",
    "Connection"            => "Upgrade",
    "Sec-WebSocket-Key"     => "dGhlIHNhbXBsZSBub25jZQ==",
    "Sec-WebSocket-Version" => "13",
  }
  headers["Origin"] = origin unless origin.nil?
  client.get("/cable", headers: headers)
ensure
  client.try(&.close)
end

describe MartenCable::UpgradeGuard do
  # `before_each` (vs top-level configure / before_suite) so each example
  # gets an unpoisoned Cable / Marten / MartenCable config — guards
  # against MCR2-style cross-spec leakage.
  before_each do
    CableSpecHelper.reset_cable_config
    Marten.configure do |config|
      config.secret_key = "marten-cable-upgrade-guard-spec-secret-32-chars"
      config.installed_apps = [] of Marten::Apps::Config.class
      config.allowed_hosts = ["allowed.test"]
    end
    Cable.configure do |settings|
      settings.backend_class = MartenCable::InProcessBackend
      settings.url = "in-process://"
      settings.token = "tok"
      # See round_trip_spec.cr for why `route` must be set explicitly.
      settings.route = "/cable"
    end
    MartenCable::UpgradeGuard.reset_origin_cache!
  end

  after_each do
    Cable.reset_server rescue nil
  end

  describe "host + origin validation" do
    server = UpgradeGuardServer.new(
      MartenCable::UpgradeGuard.new(Cable::Handler(UpgradeGuardConnection).new)
    )

    Spec.before_suite { server.start }
    Spec.after_suite { server.stop }

    it "rejects WS upgrade with a disallowed Host header (400)" do
      response = upgrade_request(server, host: "evil.test", origin: "https://allowed.test")
      response.status_code.should eq(400)
    end

    it "rejects WS upgrade with a disallowed Origin header (403)" do
      response = upgrade_request(server, host: "allowed.test", origin: "https://evil.test")
      response.status_code.should eq(403)
    end

    it "rejects WS upgrade with a missing Origin header (403)" do
      response = upgrade_request(server, host: "allowed.test", origin: nil)
      response.status_code.should eq(403)
    end

    it "permits WS upgrade with an allowed Host and Origin (101)" do
      response = upgrade_request(server, host: "allowed.test", origin: "https://allowed.test")
      response.status_code.should eq(101)
    end

    it "honors an explicit MartenCable.configuration.allowed_origins allowlist" do
      MartenCable.configure do |c|
        c.allowed_origins = ["https://explicit.test"]
      end

      # Host header still has to pass — keep it on the Marten allowlist.
      response = upgrade_request(server, host: "allowed.test", origin: "https://explicit.test")
      response.status_code.should eq(101)

      # The derived-from-allowed_hosts default is now bypassed.
      response = upgrade_request(server, host: "allowed.test", origin: "https://allowed.test")
      response.status_code.should eq(403)
    end

    it "passes non-WebSocket requests through to the wrapped handler unchanged" do
      # No Upgrade headers => guard is a pass-through. Cable's handler then
      # calls call_next, which on our minimal server has nothing further to
      # invoke (HTTP::Handler default falls back to 404).
      client = HTTP::Client.new(server.address.address, server.address.port)
      response = client.get("/cable", headers: HTTP::Headers{"Host" => "evil.test"})
      client.close

      # If the guard had mistakenly run host validation here, this would be a
      # 400. The default fallback in HTTP::Server is 404.
      response.status_code.should eq(404)
    end

    # Regression (found via marten-writebook, 2026-08-10): `HTTP::Server`
    # links the handler ARRAY via `#next=`, but the wrapped Cable handler is
    # not in the array. Without `UpgradeGuard#next=` forwarding the link, the
    # wrapped handler's `call_next` hit `nil` and every plain HTTP request
    # short-circuited to a bare stdlib 404 instead of reaching the handlers
    # after the guard (Marten's Middleware/Routing in a real app).
    it "continues the outer handler chain for non-WebSocket requests" do
      terminal = TerminalStubHandler.new
      guard = MartenCable::UpgradeGuard.new(Cable::Handler(UpgradeGuardConnection).new)
      chained_server = UpgradeGuardServer.new([guard, terminal] of HTTP::Handler)
      chained_server.start

      begin
        client = HTTP::Client.new(chained_server.address.address, chained_server.address.port)
        response = client.get("/books", headers: HTTP::Headers{"Host" => "allowed.test"})
        client.close

        response.status_code.should eq(200)
        response.body.should eq("terminal reached")
        terminal.calls.should eq(1)
      ensure
        chained_server.stop
      end
    end
  end

  # MCR-N1 regression: wildcard entries in `allowed_hosts` must be honoured
  # rather than silently dropped from the derived origin allowlist. The
  # earlier implementation skipped `"*"` and `".example.com"` entries, so
  # the derived allowlist became empty and every upgrade 403'd.
  describe "wildcard allowed_hosts handling (MCR-N1)" do
    it "accepts any Origin when allowed_hosts contains '*' and emits a one-time warning" do
      Marten.configure do |config|
        config.allowed_hosts = ["*"]
      end
      MartenCable::UpgradeGuard.reset_origin_cache!

      # Capture warn-level Marten log output via a fresh in-memory
      # backend; assert the wildcard warning fires on the first upgrade.
      log_io = IO::Memory.new
      ::Log.setup("marten", :warn, ::Log::IOBackend.new(log_io))

      server = UpgradeGuardServer.new(
        MartenCable::UpgradeGuard.new(Cable::Handler(UpgradeGuardConnection).new)
      )
      server.start

      begin
        # `allowed_hosts = ["*"]` accepts any Host, so we can use any
        # value here. Pick something distinct from the test server's bind
        # address to prove the wildcard is what's accepting it.
        host = "anything.test:#{server.address.port}"
        response = upgrade_request(server, host: host, origin: "https://anything.example")
        response.status_code.should eq(101)

        # Second upgrade — warning should NOT be re-emitted.
        response2 = upgrade_request(server, host: host, origin: "https://different.example")
        response2.status_code.should eq(101)
      ensure
        server.stop
        # Reset Marten Log to defaults for subsequent tests.
        ::Log.setup("marten", :info, ::Log::IOBackend.new)
      end

      log_text = log_io.to_s
      log_text.should contain("allowed_hosts")
      # Exactly one warning emission (matches "accepts any Origin" once).
      log_text.scan(/accepts any Origin/).size.should eq(1)
    end

    it "accepts an Origin matching a suffix wildcard entry (.example.com)" do
      # Include `127.0.0.1` (the actual Host header value HTTP::Client sends
      # to a local TCP socket) alongside the wildcard entry under test —
      # this way the host check passes and we isolate the Origin assertion.
      Marten.configure do |config|
        config.allowed_hosts = [".example.com", "127.0.0.1"]
      end
      MartenCable::UpgradeGuard.reset_origin_cache!

      server = UpgradeGuardServer.new(
        MartenCable::UpgradeGuard.new(Cable::Handler(UpgradeGuardConnection).new)
      )
      server.start
      begin
        host = "127.0.0.1:#{server.address.port}"

        # `.example.com` allows the bare domain plus any subdomain.
        upgrade_request(server, host: host, origin: "https://foo.example.com").status_code.should eq(101)
        upgrade_request(server, host: host, origin: "https://example.com").status_code.should eq(101)
        upgrade_request(server, host: host, origin: "https://deep.sub.example.com").status_code.should eq(101)

        # Sibling host that happens to contain the substring must not match.
        upgrade_request(server, host: host, origin: "https://evilexample.com").status_code.should eq(403)
        upgrade_request(server, host: host, origin: "https://evil.com").status_code.should eq(403)
      ensure
        server.stop
      end
    end

    it "treats a plain hostname entry as an exact match (no subdomain widening)" do
      Marten.configure do |config|
        config.allowed_hosts = ["app.example.com", "127.0.0.1"]
      end
      MartenCable::UpgradeGuard.reset_origin_cache!

      server = UpgradeGuardServer.new(
        MartenCable::UpgradeGuard.new(Cable::Handler(UpgradeGuardConnection).new)
      )
      server.start
      begin
        host = "127.0.0.1:#{server.address.port}"

        upgrade_request(server, host: host, origin: "https://app.example.com").status_code.should eq(101)
        upgrade_request(server, host: host, origin: "http://app.example.com").status_code.should eq(101)

        # Other subdomains must NOT match a literal hostname entry.
        upgrade_request(server, host: host, origin: "https://other.example.com").status_code.should eq(403)
      ensure
        server.stop
      end
    end

    it "explicit configuration.allowed_origins overrides wildcard derivation" do
      Marten.configure do |config|
        config.allowed_hosts = ["*"]
      end
      MartenCable.configure do |c|
        c.allowed_origins = ["https://explicit.example"]
      end
      MartenCable::UpgradeGuard.reset_origin_cache!

      server = UpgradeGuardServer.new(
        MartenCable::UpgradeGuard.new(Cable::Handler(UpgradeGuardConnection).new)
      )
      server.start
      begin
        host = "127.0.0.1:#{server.address.port}"
        # Wildcard would have accepted this — explicit allowlist wins.
        upgrade_request(server, host: host, origin: "https://other.example").status_code.should eq(403)
        upgrade_request(server, host: host, origin: "https://explicit.example").status_code.should eq(101)
      ensure
        server.stop
      end
    end
  end

  # MCR-N3 regression: an exception raised inside the wrapped cable
  # handler must NOT propagate to Marten's error handler (which would try
  # to render an HTTP 500 into a connection that may already be hijacked).
  # The guard's rescue block writes a best-effort 500 and swallows the
  # exception. Without this rescue the error bubbles up to the outer
  # HTTP::Server, which prints "Unhandled exception in spawn" and tears
  # down the connection without an HTTP-shaped response.
  describe "rescues exceptions raised by the wrapped cable handler (MCR-N3)" do
    it "writes a 500 and swallows the exception rather than letting it bubble" do
      Marten.configure do |config|
        config.allowed_hosts = ["allowed.test"]
      end
      MartenCable::UpgradeGuard.reset_origin_cache!

      # Wrap the stub (not the real Cable::Handler) so the raise happens
      # synchronously inside `@cable_handler.call(context)` — that's the
      # exact codepath the rescue exists to protect (use the real
      # `Cable::Handler` and the raise would happen in the deferred
      # `upgrade_handler` callback, which the rescue can't reach
      # regardless of how it's written).
      server = UpgradeGuardServer.new(MartenCable::UpgradeGuard.new(RaisingStubHandler.new))
      server.start
      begin
        client = HTTP::Client.new(server.address.address, server.address.port)
        response = client.get("/cable", headers: HTTP::Headers{
          "Host"                  => "allowed.test",
          "Upgrade"               => "websocket",
          "Connection"            => "Upgrade",
          "Sec-WebSocket-Key"     => "dGhlIHNhbXBsZSBub25jZQ==",
          "Sec-WebSocket-Version" => "13",
          "Origin"                => "https://allowed.test",
        })
        client.close

        # Critical assertions: status came back as a proper HTTP 500
        # (proves the response wasn't half-written and the exception
        # didn't leak to the outer handler), and the body looks like
        # what `close_upgrade_socket` writes.
        response.status_code.should eq(500)
        response.body.should contain("Internal Server Error")
      ensure
        server.stop
      end
    end
  end
end
