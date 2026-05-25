module MartenCable
  # Shard-level configuration for the WebSocket upgrade guard and other
  # marten-cable concerns. Configured via `MartenCable.configure`:
  #
  #     MartenCable.configure do |c|
  #       c.allowed_origins = ["https://app.example.com"]
  #       c.max_message_size = 64 * 1024
  #     end
  #
  # Settings are read once at request time, not at configure time, so values
  # may be set or overridden any time before the first upgrade.
  class Configuration
    # 1 MiB default cap on inbound WebSocket text/binary messages. Frames
    # bigger than this will cause the socket to be closed with a 1009
    # ("Message Too Big") close code. Set to a larger value if your app
    # legitimately needs to receive bigger frames over WS.
    DEFAULT_MAX_MESSAGE_SIZE = 1_024 * 1024

    # Allowlist of `Origin` header values accepted on a WebSocket upgrade.
    # If `nil` (the default), the allowlist is derived from
    # `Marten.settings.allowed_hosts` at request time:
    #
    #   - Literal hostnames → `https://<host>` and `http://<host>` accepted.
    #   - `".example.com"` → bare domain + any subdomain accepted
    #     (matched against the parsed Origin's `host`).
    #   - `"*"` → any Origin accepted; logs a one-time warning on first
    #     upgrade. Useful in development; do not ship to production.
    #
    # Set this explicitly to lock the allowlist regardless of
    # `allowed_hosts` (e.g. when the public origin differs from the
    # internal `Host` header). When set, entries are exact-matched against
    # the raw Origin string.
    property allowed_origins : Array(String)? = nil

    # Maximum byte size of a single inbound WebSocket message. Defaults to
    # `DEFAULT_MAX_MESSAGE_SIZE` (1 MiB). Messages exceeding this size cause
    # the socket to be closed with close code 1009.
    #
    # NOTE: This is enforced post-frame-decode in `Cable::Connection#receive`.
    # The Crystal stdlib's `HTTP::WebSocket` doesn't expose a per-frame
    # streaming hook, so the message is still fully accumulated into memory
    # before this check fires. For hard protection against memory exhaustion
    # via huge frames, also configure a reverse proxy (e.g. nginx
    # `proxy_max_temp_file_size` or a WS-aware proxy frame size cap) ahead
    # of your Marten process.
    property max_message_size : Int32 = DEFAULT_MAX_MESSAGE_SIZE
  end

  @@configuration = Configuration.new

  # Returns the current `MartenCable::Configuration`. Mutate directly or via
  # `MartenCable.configure`.
  def self.configuration : Configuration
    @@configuration
  end

  # Yields the current configuration for block-style setup:
  #
  #     MartenCable.configure do |c|
  #       c.allowed_origins = ["https://app.example.com"]
  #     end
  def self.configure(&)
    yield @@configuration
  end
end
