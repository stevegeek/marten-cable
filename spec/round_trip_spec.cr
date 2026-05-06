require "spec"
require "http/server"
require "http/web_socket"
require "../src/marten_cable"

# An HTTP::Server with just Cable's handler is enough to exercise the
# round-trip path (in-process backend → WebSocket fan-out). Marten ↔
# Cable handler-chain wiring is covered separately by smoke_spec.cr.

Cable.configure do |settings|
  settings.backend_class = MartenCable::InProcessBackend
  settings.url = "in-process://"
  settings.token = "tok"
  # Workaround: cable-cr's default for `route` is `Cable.message(:default_mount_path)`
  # which crashes because :default_mount_path lives at the top of INTERNAL,
  # not under :message_types. Setting it explicitly bypasses the broken default.
  settings.route = "/cable"
end

class RtConnection < Cable::Connection
  identified_by :identifier

  def connect
    self.identifier = token.to_s
  end
end

class RtChannel < Cable::Channel
  def subscribed
    stream_from "items"
  end
end

class TestServer
  getter address : Socket::IPAddress

  def initialize
    @server = HTTP::Server.new([Cable::Handler(RtConnection).new] of HTTP::Handler)
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
    Cable.server.shutdown rescue nil
    Cable.reset_server
  end
end

TEST_SERVER = TestServer.new

Spec.before_suite { TEST_SERVER.start }
Spec.after_suite { TEST_SERVER.stop }

private def open_ws
  HTTP::WebSocket.new(
    host: TEST_SERVER.address.address,
    port: TEST_SERVER.address.port,
    path: "/cable?tok=hello",
    headers: HTTP::Headers{"Sec-WebSocket-Protocol" => "actioncable-v1-json"},
  )
end

private def collect_messages(ws : HTTP::WebSocket, count : Int32, timeout = 2.seconds) : Array(String)
  messages = [] of String
  done = ::Channel(Nil).new(capacity: 1)
  ws.on_message do |msg|
    messages << msg
    done.send(nil) if messages.size >= count
  end
  spawn { ws.run rescue nil }

  select
  when done.receive
    # got 'em
  when timeout(timeout)
    raise "timed out waiting for #{count} messages, got #{messages.size}: #{messages}"
  end

  messages
end

describe "round trip" do
  it "delivers a broadcast to a subscribed client" do
    ws = open_ws

    ws.send({
      command:    "subscribe",
      identifier: {channel: "RtChannel"}.to_json,
    }.to_json)

    spawn do
      sleep 100.milliseconds
      Cable.server.publish("items", {hello: "world"}.to_json)
    end

    # Expected sequence (Action Cable wire protocol):
    #   1. {"type":"welcome"}
    #   2. {"type":"confirm_subscription","identifier":"..."}
    #   3. {"identifier":"...","message":{...}}  (the broadcast)
    messages = collect_messages(ws, 3)
    ws.close

    welcome = JSON.parse(messages[0])
    welcome["type"].as_s.should eq("welcome")

    confirm = JSON.parse(messages[1])
    confirm["type"].as_s.should eq("confirm_subscription")

    payload = JSON.parse(messages[2])
    payload["message"]["hello"].as_s.should eq("world")
  end
end
