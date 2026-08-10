module MartenCable
  # Reopens tasker's top-level `Timer#start_timer` to drop the
  # `same_thread: true` spawn argument.
  #
  # **Why:** Crystal 1.21 runs fibers on the execution-contexts scheduler,
  # and `Fiber::ExecutionContext::Parallel::Scheduler#spawn` raises a
  # `RuntimeError` ("doesn't support same_thread:true") when asked to pin
  # a fiber to the current thread. Cable's `WebsocketPinger` calls
  # `Tasker.every` on every WebSocket upgrade, which reaches
  # `Timer#start_timer` (`lib/tasker/src/tasker/timer.cr`) and crashes the
  # per-connection handler fiber right after the welcome frame — killing
  # every connection on Crystal >= 1.21.
  #
  # Upstream tasker removed `same_thread:` from its spawns after v3.1.0
  # (commit 742ceeeb "feat: remove same_thread on fibers"), but cable pins
  # `tasker: ~> 2.1`, so the fix can't arrive via dependency resolution.
  # This patch mirrors the upstream change for the one method on Cable's
  # code path. The timer body only touches a `Channel` (thread-safe), so
  # dropping the thread pin is sound; on Crystal < 1.21 the pin was a
  # no-op in single-threaded builds anyway.
  #
  # Drop this file once cable depends on tasker >= 3.2 (or any release
  # containing 742ceeeb).
  module TaskerTimerPatch
  end
end

class Timer
  def start_timer : Nil
    Log.trace { "timer start called, id: #{self.object_id}" }
    spawn { schedule_wait }
    Fiber.yield
  end
end
