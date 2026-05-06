require "marten"
require "cable"

require "./marten_cable/in_process_backend"
require "./marten_cable/use"

module MartenCable
  VERSION = "0.1.0"
end

# Register the in-process backend under a dedicated URI scheme. Users who
# don't go through `MartenCable.use` (e.g. test setups) can still opt in
# explicitly with `Cable.settings.url = "in-process://"`.
MartenCable::InProcessBackend.register("in-process")
