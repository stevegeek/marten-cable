require "marten"
require "cable"

require "./marten_cable/configuration"
require "./marten_cable/connection_message_limit"
require "./marten_cable/in_process_backend"
require "./marten_cable/session"
require "./marten_cable/tasker_timer_patch"
require "./marten_cable/upgrade_guard"
require "./marten_cable/use"

module MartenCable
  VERSION = "0.1.0"
end

# Register the in-process backend under a dedicated URI scheme. Users who
# don't go through `MartenCable.use` (e.g. test setups) can still opt in
# explicitly with `Cable.settings.url = "in-process://"`.
#
# **Why a require-time side-effect:** moving this into `MartenCable.use`
# (per review §13) would break the common spec-helper pattern of calling
# `Cable.configure { |s| s.url = "in-process://" }` *before* any
# `MartenCable.use` invocation — see `spec/round_trip_spec.cr` and
# `spec/upgrade_guard_spec.cr`, which both rely on the backend being
# registered just from `require "marten_cable"`. The side-effect is a
# pure registry mutation (no Marten settings touched, no fibers spawned)
# so the load-order coupling is benign.
MartenCable::InProcessBackend.register("in-process")
