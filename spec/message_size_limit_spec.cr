require "spec"
require "http/server"
require "http/web_socket"
require "./support/cable_helper"

# Drives the message-size limit enforced by the runtime patch in
# `src/marten_cable/connection_message_limit.cr`. We spin up a minimal
# `HTTP::Server` with just `Cable::Handler` (no UpgradeGuard wrapper —
# that's not needed to exercise the size cap, and skipping it avoids
# Origin/Host handshake gymnastics) and assert that a message larger
# than `MartenCable.configuration.max_message_size` triggers a
# close-code-1009 from the server side.
#
# Cable config is applied inside `before_each` so MCR2 cross-spec
# leakage doesn't poison the run when this spec runs alongside the
# others.

Spec.before_each do
  CableSpecHelper.reset_cable_config
  Cable.configure do |settings|
    settings.backend_class = MartenCable::InProcessBackend
    settings.url = "in-process://"
    settings.token = "tok"
    settings.route = "/cable"
  end
end

class SizeLimitConnection < Cable::Connection
  identified_by :identifier

  def connect
    self.identifier = token.to_s
  end
end

class SizeLimitServer
  getter address : Socket::IPAddress

  def initialize
    @server = HTTP::Server.new([Cable::Handler(SizeLimitConnection).new] of HTTP::Handler)
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

SIZE_LIMIT_SERVER = SizeLimitServer.new

Spec.before_suite { SIZE_LIMIT_SERVER.start }
Spec.after_suite { SIZE_LIMIT_SERVER.stop }

describe "message size limit" do
  it "closes the socket with code 1009 when a message exceeds the configured cap" do
    original = MartenCable.configuration.max_message_size
    begin
      MartenCable.configure do |c|
        c.max_message_size = 1024
      end

      ws = HTTP::WebSocket.new(
        host: SIZE_LIMIT_SERVER.address.address,
        port: SIZE_LIMIT_SERVER.address.port,
        path: "/cable?tok=hello",
        headers: HTTP::Headers{"Sec-WebSocket-Protocol" => "actioncable-v1-json"},
      )

      close_info = ::Channel({HTTP::WebSocket::CloseCode, String}).new(capacity: 1)
      ws.on_close do |code, msg|
        close_info.send({code, msg})
      end
      spawn { ws.run rescue nil }

      # Send a payload comfortably larger than the 1 KiB cap.
      ws.send("x" * 2048)

      select
      when info = close_info.receive
        info[0].should eq(HTTP::WebSocket::CloseCode::MessageTooBig)
      when timeout(2.seconds)
        raise "timed out waiting for server-side close"
      end
    ensure
      MartenCable.configuration.max_message_size = original
    end
  end
end
