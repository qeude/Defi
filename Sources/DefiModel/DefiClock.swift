import Foundation
import Synchronization

/// Defi's uptime clock and delayed work. Production reads the system uptime and schedules on
/// real time; a simulated desktop installs a `VirtualClock` so every timestamp and timer in
/// the daemon follows simulated time and a seed replays identically.
public enum DefiClock {
  private static let installed = Mutex<VirtualClock?>(nil)

  public static var uptime: TimeInterval {
    installed.withLock { $0 }?.now ?? ProcessInfo.processInfo.systemUptime
  }

  public static var virtual: VirtualClock? { installed.withLock { $0 } }

  /// Runs `work` on `queue` once `delay` seconds of this clock have passed.
  public static func after(
    _ delay: TimeInterval, on queue: DispatchQueue, execute work: @escaping @Sendable () -> Void
  ) {
    if let clock = virtual {
      clock.schedule(after: delay) { queue.async(execute: work) }
    } else {
      queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
  }

  /// Suspends for `delay` seconds of this clock.
  public static func sleep(_ delay: TimeInterval) async throws {
    if let clock = virtual {
      try await clock.sleep(delay)
    } else {
      try await Task.sleep(for: .seconds(delay))
    }
  }

  /// Installs a virtual clock for the rest of the process; one simulated desktop per process.
  public static func install(_ clock: VirtualClock) {
    installed.withLock { $0 = clock }
  }
}

/// Simulated time: it moves only when `advance(to:)` is called, firing due timers in order.
public final class VirtualClock: Sendable {
  private struct Timer {
    let deadline: TimeInterval
    let order: UInt64
    let fire: @Sendable () -> Void
  }

  private struct State {
    var now: TimeInterval
    var timers: [Timer] = []
    var nextOrder: UInt64 = 0
  }

  private let state: Mutex<State>

  public init(startingAt now: TimeInterval = 1_000) {
    state = Mutex(State(now: now))
  }

  public var now: TimeInterval { state.withLock { $0.now } }

  public var pendingTimerCount: Int { state.withLock { $0.timers.count } }

  /// The earliest pending deadline, if any timer is waiting.
  public var nextDeadline: TimeInterval? { state.withLock { $0.timers.map(\.deadline).min() } }

  public func schedule(after delay: TimeInterval, fire: @escaping @Sendable () -> Void) {
    state.withLock {
      $0.timers.append(Timer(deadline: $0.now + max(delay, 0), order: $0.nextOrder, fire: fire))
      $0.nextOrder += 1
    }
  }

  public func sleep(_ delay: TimeInterval) async throws {
    try Task.checkCancellation()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      schedule(after: delay) { continuation.resume() }
    }
    try Task.checkCancellation()
  }

  /// Moves time forward, firing every timer due by `target` in deadline order. Returns how
  /// many fired; the caller lets fired work settle before advancing again.
  @discardableResult
  public func advance(to target: TimeInterval) -> Int {
    let due: [Timer] = state.withLock { state in
      state.now = max(state.now, target)
      let due = state.timers.filter { $0.deadline <= state.now }
        .sorted { ($0.deadline, $0.order) < ($1.deadline, $1.order) }
      state.timers.removeAll { $0.deadline <= state.now }
      return due
    }
    due.forEach { $0.fire() }
    return due.count
  }

  @discardableResult
  public func advance(by delta: TimeInterval) -> Int { advance(to: now + delta) }
}
