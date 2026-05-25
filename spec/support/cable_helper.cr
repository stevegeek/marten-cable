require "spec"
require "../../src/marten_cable"

# Shared helpers for isolating per-spec-file Cable / Marten configuration
# across the suite (MCR2 — cross-spec global-state leakage).
#
# `Cable.settings`, `Marten.settings`, and `MartenCable.configuration` are
# all process-global. Each spec file used to set them at the top level, so
# whichever file was loaded LAST silently won and the others ran against a
# stale config (the upgrade_guard origin specs flaked because of this when
# the full suite was run).
#
# Each spec file now calls `CableSpecHelper.reset_cable_config` and
# `MartenCable::UpgradeGuard.reset_origin_cache!` inside a `before_each`
# block, then re-applies its own configuration. This is a `before_each`
# rather than `before_all` because the cost is microseconds and it makes
# any latent ordering dependency visible immediately.
module CableSpecHelper
  # Reset `Cable.settings` and `Cable.server` to a clean slate so the
  # caller can repopulate `Cable.settings.backend_class`,
  # `Cable.settings.url`, etc. without inheriting whatever the previous
  # spec file installed.
  def self.reset_cable_config : Nil
    # `Cable.reset_server` is the documented hook (see
    # `lib/cable/src/cable.cr#reset_server`). It nils out the memoised
    # `@@server` so the next `Cable.server` rebuilds with current
    # settings — without this, `Cable.server.fiber_channel` keeps a
    # reference to the previous spec's server.
    Cable.reset_server rescue nil
    # Reset `MartenCable.configuration` too — specs that fiddle with
    # `allowed_origins` or `max_message_size` should not leak state.
    MartenCable.configuration.allowed_origins = nil
    MartenCable.configuration.max_message_size = MartenCable::Configuration::DEFAULT_MAX_MESSAGE_SIZE
    MartenCable::UpgradeGuard.reset_origin_cache!
  end
end
