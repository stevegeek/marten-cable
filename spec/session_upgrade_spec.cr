require "spec"
require "http/server"
require "http/web_socket"
require "./support/cable_helper"

# Integration spec for the full WebSocket upgrade path when a valid Marten
# session cookie is present (review §19). This wires up:
#
#   - Marten with a 32-byte secret_key + an explicit allowed_hosts entry
#   - `MartenCable::UpgradeGuard` wrapping `Cable::Handler` on a real
#     HTTP::Server (same shape as `Marten::Server.handlers` post-`use`)
#   - A `Cable::Connection` subclass whose `connect` uses
#     `MartenCable::Session.for(request)` and reads `user_id` out of the
#     decrypted Marten cookie
#
# Asserts that an upgrade with a valid cookie reaches the welcome message,
# proving the cookie → identifier wiring works end-to-end (covering
# `Session.for` + `UpgradeGuard` together).

# Config moved to `before_each` so MCR2 cross-spec global-state leakage
# doesn't poison subsequent specs in the suite — see
# `support/cable_helper.cr`.
Spec.before_each do
  CableSpecHelper.reset_cable_config
  Marten.configure do |config|
    config.secret_key = "marten-cable-session-upgrade-spec-secret-key-32+"
    config.installed_apps = [] of Marten::Apps::Config.class
    # `HTTP::WebSocket` always sends `Host: <addr>:<port>` based on its `host`
    # constructor arg (`lib/crystal/src/http/web_socket/protocol.cr#325`), so
    # we can't talk to the test server with a synthetic Host like "test.local".
    # Allow `127.0.0.1` here — UpgradeGuard's host validation works in real apps
    # because production traffic carries a routable Host that the operator has
    # already enumerated in `allowed_hosts`.
    config.allowed_hosts = ["127.0.0.1"]
  end
  MartenCable::UpgradeGuard.reset_origin_cache!
  Cable.configure do |settings|
    settings.backend_class = MartenCable::InProcessBackend
    settings.url = "in-process://"
    settings.token = "tok"
    settings.route = "/cable"
  end
end

# Marten session cookie format: `Marten::Core::Encryptor.encrypt(json, expires: ...)`
private def make_session_cookie_for_upgrade(data : Hash(String, String)) : String
  Marten::Core::Encryptor.new.encrypt(value: data.to_json, expires: Time.local + 1.hour)
end

class SessionUpgradeConnection < Cable::Connection
  identified_by :user_id

  # cable-cr's `Connection#initialize` receives `HTTP::Request` but does not
  # expose it after construction, so we capture it on a property here. This
  # mirrors what an application's `ApplicationCable::Connection` would do.
  getter request : HTTP::Request

  def initialize(@request : HTTP::Request, socket : HTTP::WebSocket)
    super(@request, socket)
  end

  def connect
    session = MartenCable::Session.for(request)
    if session && (uid = session["user_id"]?)
      self.user_id = uid
    else
      reject_unauthorized_connection
    end
  end
end

class SessionUpgradeServer
  getter address : Socket::IPAddress

  def initialize
    @server = HTTP::Server.new([
      MartenCable::UpgradeGuard.new(Cable::Handler(SessionUpgradeConnection).new),
    ] of HTTP::Handler)
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

SESSION_UPGRADE_SERVER = SessionUpgradeServer.new

Spec.before_suite { SESSION_UPGRADE_SERVER.start }
Spec.after_suite { SESSION_UPGRADE_SERVER.stop }

describe "WS upgrade with a valid Marten session cookie" do
  it "establishes the connection and delivers a welcome frame" do
    cookie_value = make_session_cookie_for_upgrade({"user_id" => "1234"})
    cookie_header = "#{Marten.settings.sessions.cookie_name}=#{cookie_value}"

    ws = HTTP::WebSocket.new(
      host: SESSION_UPGRADE_SERVER.address.address,
      port: SESSION_UPGRADE_SERVER.address.port,
      path: "/cable?tok=hello",
      headers: HTTP::Headers{
        # Origin must match the derived-from-allowed_hosts allowlist
        # (UpgradeGuard derives `https://<h>` / `http://<h>` for every
        # allowed_hosts entry — "127.0.0.1" → "https://127.0.0.1" etc).
        "Origin"                 => "https://127.0.0.1",
        "Cookie"                 => cookie_header,
        "Sec-WebSocket-Protocol" => "actioncable-v1-json",
      },
    )

    welcome = ::Channel(String).new(capacity: 8)
    ws.on_message { |msg| welcome.send(msg) }
    spawn { ws.run rescue nil }

    select
    when frame = welcome.receive
      parsed = JSON.parse(frame)
      parsed["type"].as_s.should eq("welcome")
    when timeout(2.seconds)
      raise "timed out waiting for welcome frame — connection did not establish"
    end

    ws.close
  end

  it "rejects the connection when the cookie is missing" do
    # Without a session cookie, `Session.for` returns nil and `connect`
    # calls `reject_unauthorized_connection`, which on cable-cr closes
    # the socket immediately. The handshake itself still succeeds (101)
    # because rejection happens after upgrade — but the client sees
    # the socket close without a welcome frame.
    ws = HTTP::WebSocket.new(
      host: SESSION_UPGRADE_SERVER.address.address,
      port: SESSION_UPGRADE_SERVER.address.port,
      path: "/cable?tok=hello",
      headers: HTTP::Headers{
        "Origin"                 => "https://127.0.0.1",
        "Sec-WebSocket-Protocol" => "actioncable-v1-json",
      },
    )

    closed = ::Channel(Nil).new(capacity: 1)
    ws.on_close { closed.send(nil) }
    spawn { ws.run rescue nil }

    select
    when closed.receive
      # expected — rejection closed the socket
    when timeout(2.seconds)
      raise "expected socket close on rejected connection"
    end
  end
end
