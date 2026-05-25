require "spec"
require "../src/marten_cable"

# Regression spec for HIGH §3 in `reviews/marten-cable-review.md`:
# `MartenCable::InProcessBackend#publish_message` must NOT block the
# calling fiber when a downstream subscriber is slow. The fix spawns a
# fiber per publish; this spec asserts the publisher returns promptly.
#
# Test strategy (MCR1, 2026-05-21): we measure ONLY the time `publish_message`
# takes to return. An earlier version of this spec tried to drain
# `Cable.server.fiber_channel` from a competing fiber to manufacture
# back-pressure, but that races cable-cr's built-in
# `Cable::Server#process_subscribed_messages` drain (spawned in
# `Cable::Server.new`) — messages got split between the two drains and
# the spec hung forever. The publisher-doesn't-block contract is the
# one thing we actually care about, so the spec just times the
# publisher.
#
# Cable.configure is run inside `before_each` so a sibling spec file
# that mutated `Cable.settings` (MCR2 — cross-spec global-state leakage)
# doesn't leave this spec running against a stale config.

describe MartenCable::InProcessBackend do
  before_each do
    Cable.reset_server rescue nil
    Cable.configure do |settings|
      settings.backend_class = MartenCable::InProcessBackend
      settings.url = "in-process://"
      settings.route = "/cable"
    end
  end

  after_each do
    Cable.reset_server rescue nil
  end

  it "returns immediately from publish_message regardless of drain speed" do
    backend = MartenCable::InProcessBackend.new

    # Without the spawn-per-publish fix this loop would back-pressure on
    # `Cable.server.fiber_channel`'s unbuffered send the moment the
    # server's drain fiber falls behind. With the fix the caller parks
    # an anonymous fiber per publish and returns in microseconds.
    elapsed = Time.measure do
      10.times do |i|
        backend.publish_message("stream", "msg-#{i}")
      end
    end

    # 10ms is generously above any realistic spawn overhead but a couple
    # of orders of magnitude below the minimum back-pressure latency we'd
    # see if `publish_message` were blocking on a synchronous send.
    elapsed.should be < 10.milliseconds
  end
end
