module MartenCable
  # Single-process, in-memory Cable backend. No Redis, no extra services.
  #
  # Wire model: `publish_message` spawns a fiber that hands the
  # `(stream_identifier, message)` pair to `Cable.server.fiber_channel`.
  # The server's `process_subscribed_messages` fiber pops it and fans out
  # to every locally-subscribed channel via `send_to_channels` — same code
  # path as the Redis backend, just without a network hop.
  #
  # ## Why publishes are spawned
  #
  # `Cable.server.fiber_channel` is unbuffered, and the sole drain fiber
  # calls `channel.connection.socket.send(...)` synchronously for each
  # subscriber. A single slow subscriber (slow network, TCP backpressure,
  # malicious client refusing to read) will stall the drain loop and
  # back-pressure the publisher's `fiber_channel.send`.
  #
  # Spawning the publish decouples the calling fiber from the drain. The
  # caller — which may be inside an HTTP request handler — returns
  # immediately even if the drain fiber is stalled on a slow subscriber.
  #
  # ## Remaining limitation
  #
  # Backpressure is now effectively infinite: each blocked publish parks
  # one fiber until the slow subscriber unblocks (or its socket is closed
  # by `MartenCable::UpgradeGuard`'s message-size enforcement or by the
  # client itself). Under sustained slow-subscriber pressure memory grows
  # in proportion to publish rate. The proper long-term fix is a
  # per-connection bounded send queue with overflow eviction (the
  # ActionCable approach); that's tracked as a follow-up in
  # `reviews/marten-cable-review.md` §3.
  #
  # ## Other deployment limits
  #
  # Single Marten process only. For multi-process / multi-machine
  # deployments swap this out for `cable-redis` (or another Cable backend).
  class InProcessBackend < ::Cable::BackendCore
    def publish_message(stream_identifier : String, message : String)
      # Spawn so the caller never blocks on a stalled drain fiber. See the
      # class docstring for the full rationale.
      spawn { ::Cable.server.fiber_channel.send({stream_identifier, message}) }
    end

    # The "subscribe" notion here is local — the Cable server keeps the
    # registry of channel ↔ stream_identifier in memory and we never need
    # to inform a broker. The remaining methods are intentional no-ops
    # for the same reason; they exist because `Cable::BackendCore`
    # requires them.
    #
    # ASSUMPTION (re-validate when bumping cable-cr): cable-cr's current
    # call sites for these methods (`Cable::Server`, `Cable::Channel`) do
    # not loop on a truthy return value, nor do they spin-retry on `nil`.
    # If a future cable-cr change starts retrying — e.g. busy-looping on
    # `open_subscribe_connection` until it returns a usable object — these
    # `nil`-returning no-ops would turn into a CPU-burn footgun. Search
    # cable-cr for callers of each method before assuming the stubs are
    # still safe.

    # :nodoc:
    def subscribe(stream_identifier : String)
    end

    # :nodoc:
    def unsubscribe(stream_identifier : String)
    end

    # :nodoc:
    def open_subscribe_connection(channel)
    end

    # :nodoc:
    def subscribe_connection
    end

    # :nodoc:
    def publish_connection
    end

    # :nodoc:
    def close_subscribe_connection
    end

    # :nodoc:
    def close_publish_connection
    end

    # :nodoc:
    def ping_subscribe_connection
    end

    # :nodoc:
    def ping_publish_connection
    end
  end
end
