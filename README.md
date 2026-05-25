# marten-cable

ActionCable-shaped real-time WebSockets for [Marten](https://martenframework.com),
on top of [cable-cr/cable](https://github.com/cable-cr/cable).

> **Naming**: the shard's `shard.yml` `name:` is `marten_cable` (underscore — Crystal
> convention for shard names / module names), but the on-disk directory in this
> workspace is `marten-cable` (dash — directory-naming convention). Both refer
> to the same shard.

## What it adds on top of cable-cr

- `MartenCable.use ApplicationCable::Connection` wires Cable's `HTTP::Handler`
  into Marten's handler chain above the `Middleware` handler, so a successful
  WebSocket upgrade short-circuits Marten cleanly instead of crashing in
  `Middleware`'s `not_nil!` on a hijacked response.
- `MartenCable::UpgradeGuard` enforces `Marten.settings.allowed_hosts`,
  validates `Origin` against `MartenCable.configuration.allowed_origins`, and
  enforces a per-message size limit at the upgrade boundary.
- `MartenCable::Session.for(request)` reads the Marten session cookie off the
  raw `HTTP::Request` Cable receives, so `Connection#connect` can authenticate
  from cookie-based sessions without Marten's middleware running first.
- `MartenCable::InProcessBackend` is a zero-dependency single-process Cable
  backend (no Redis required) suitable for single-process deployments and tests.

## Quick start

```crystal
require "marten_cable"

# ... your usual Marten configuration ...

# Cable.settings.route must be set explicitly — see "Gotchas" below.
Cable.configure do |settings|
  settings.route = "/cable"
  settings.token = "your-token"  # or whatever auth scheme you use
end

class ApplicationCable::Connection < Cable::Connection
  identified_by :user_id

  def connect
    session = MartenCable::Session.for(request)
    if session && (uid = session["user_id"]?)
      self.user_id = uid
    else
      reject_unauthorized_connection
    end
  end
end

MartenCable.use ApplicationCable::Connection
```

## Gotchas

### Always set `Cable.settings.route` explicitly

cable-cr's default for `Cable.settings.route` is `Cable.message(:default_mount_path)`,
which crashes with `KeyError` because `:default_mount_path` lives at the top
level of cable-cr's `INTERNAL` constant, not under `:message_types` (see
`lib/cable/src/cable.cr:33`). The upstream bug means that reading the default
value blows up at boot, so this shard's specs and any application using it
**must** set `Cable.settings.route = "/cable"` (or whatever path you want) inside
your `Cable.configure` block before any cable code runs.

### Auth is checked once, at connect

`MartenCable::Session.for` reads the cookie at WS-upgrade time and never
re-checks. A logout in another tab will not disconnect existing WS connections;
you'll need to call:

```crystal
Cable.server.remote_connections.find(identifier: uid).disconnect
```

from your logout handler to force-disconnect.

### `MartenCable.use` and `Cable.configure` interaction

`MartenCable.use` will only set the in-process backend defaults
(`Cable.settings.backend_class = MartenCable::InProcessBackend`,
`Cable.settings.url = "in-process://"`) if `Cable.settings.backend_class`
is still the out-of-the-box default (`Cable::BackendRegistry`). If you've
already called `Cable.configure` to pick `cable-redis` or another backend,
`MartenCable.use` leaves those settings alone.

### In-process backend is single-process only

`MartenCable::InProcessBackend` keeps subscriptions and routing entirely in
process memory. For multi-process or multi-machine deployments, swap it out
for [`cable-redis`](https://github.com/cable-cr/cable-redis) (or another Cable
backend). Configure that backend **before** calling `MartenCable.use`.

## Configuration

```crystal
MartenCable.configure do |c|
  # Allowlist for the `Origin` header on WS upgrade. If nil (default), derived
  # from Marten.settings.allowed_hosts as both https:// and http:// variants.
  c.allowed_origins = ["https://app.example.com"]

  # Cap on a single inbound WS message (default 1 MiB). Oversize messages
  # cause the socket to be closed with WS close code 1009.
  c.max_message_size = 64 * 1024
end
```

## License

MIT
