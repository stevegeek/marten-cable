module MartenCable
  # Single-process, in-memory Cable backend. No Redis, no extra services.
  #
  # Wire model: publish_message hands the (stream_identifier, message) pair
  # straight to the Cable server's fiber_channel. The server's
  # process_subscribed_messages fiber pops it and fans out to every
  # locally-subscribed channel via send_to_channels — same code path as
  # the Redis backend, just without a network hop.
  #
  # Limits: single Marten process only. For multi-process / multi-machine
  # deployments swap this out for cable-redis (or another Cable backend).
  class InProcessBackend < ::Cable::BackendCore
    def publish_message(stream_identifier : String, message : String)
      ::Cable.server.fiber_channel.send({stream_identifier, message})
    end

    # The "subscribe" notion here is local — the Cable server keeps the
    # registry of channel ↔ stream_identifier in memory and we never need
    # to inform a broker.
    def subscribe(stream_identifier : String)
    end

    def unsubscribe(stream_identifier : String)
    end

    def open_subscribe_connection(channel)
    end

    def subscribe_connection
    end

    def publish_connection
    end

    def close_subscribe_connection
    end

    def close_publish_connection
    end

    def ping_subscribe_connection
    end

    def ping_publish_connection
    end
  end
end
