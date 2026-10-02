import AppKit
import QuartzCore
import Synchronization

/// Coalesces display pulses without letting queue delay change their cadence.
struct FrameAnimationPulseState {
  var stopped = false
  var queued = false
  var pendingLaneCompletion = false
  var lastDisplayPulse = -Double.infinity
  var lastTick = -Double.infinity
  var lastTickExecutedAt = -Double.infinity
  var displayPulseCount = 0
  var maximumDisplayGapMS = 0.0
  var timerSampleCount = 0
  var laneSampleCount = 0

  mutating func enqueue(
    now: TimeInterval, displayTimestamp: TimeInterval?,
    interval: TimeInterval, refreshInterval: TimeInterval,
    afterLaneCompletion: Bool = false
  ) -> Bool {
    guard !stopped else { return false }
    if displayTimestamp != nil {
      if lastDisplayPulse.isFinite {
        maximumDisplayGapMS = max(maximumDisplayGapMS, (now - lastDisplayPulse) * 1_000)
      }
      displayPulseCount += 1
      lastDisplayPulse = now
    }
    // A callback that cannot advance the ribbon must not starve the fallback.
    // Timer pulses use execution time: a late display timestamp is not elapsed
    // time since the last accepted sample.
    let elapsed = displayTimestamp.map { $0 - lastTick } ?? (now - lastTickExecutedAt)
    // A lane completion may recover a missed refresh, never start one early.
    let tolerance = afterLaneCompletion ? 0 : min(interval, refreshInterval) * 0.25
    if queued {
      if afterLaneCompletion { pendingLaneCompletion = true }
      return false
    }
    guard elapsed >= interval - tolerance
    else { return false }
    queued = true
    return true
  }

  func beginTick() -> Bool {
    return !stopped
  }

  @discardableResult
  mutating func finishTick(
    at timestamp: TimeInterval, executedAt: TimeInterval? = nil, advanced: Bool
  ) -> Bool {
    // Busy-lane polls do not consume the display cadence. Queue delay still
    // cannot retime an accepted ribbon sample against the next refresh.
    if advanced {
      lastTick = timestamp
      lastTickExecutedAt = executedAt ?? timestamp
    }
    queued = false
    let retry = pendingLaneCompletion && !advanced && !stopped
    pendingLaneCompletion = false
    return retry
  }
}

/// Display callbacks only enqueue work; AX stays on the coordinator's queues.
final class FrameAnimationDriver: @unchecked Sendable {
  private let state = Mutex(FrameAnimationPulseState())
  private let interval: TimeInterval
  private let refreshInterval: TimeInterval
  private let queue: DispatchQueue
  private let tick: @Sendable (FrameAnimationDriver) -> Bool
  private let timer: DispatchSourceTimer
  @MainActor private var displayTarget: DisplayTarget?

  init(
    interval: TimeInterval, refreshInterval: TimeInterval,
    displayIDs: Set<UInt64>, queue: DispatchQueue,
    tick: @escaping @Sendable (FrameAnimationDriver) -> Bool
  ) {
    self.interval = interval
    self.refreshInterval = refreshInterval
    self.queue = queue
    self.tick = tick
    timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
    timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .microseconds(100))
    timer.setEventHandler { [weak self] in self?.requestTick() }
    timer.resume()
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.state.withLock({ $0.stopped }), displayIDs.count == 1,
        let screen = NSScreen.screens.first(where: {
          ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { displayIDs.contains($0.uint64Value) } == true
        })
      else { return }
      self.displayTarget = DisplayTarget(screen: screen, driver: self)
    }
  }

  func stop() {
    let stopped = state.withLock { state in
      guard !state.stopped else { return false }
      state.stopped = true
      return true
    }
    guard stopped else { return }
    timer.cancel()
    DispatchQueue.main.async { [self] in
      displayTarget?.invalidate()
      displayTarget = nil
    }
  }

  var diagnosticSummary: String {
    state.withLock {
      "displayPulses=\($0.displayPulseCount) displayGapMs=\(String(format: "%.2f", $0.maximumDisplayGapMS)) timerSteps=\($0.timerSampleCount) laneSteps=\($0.laneSampleCount)"
    }
  }

  func requestTick(displayTimestamp: TimeInterval? = nil, afterLaneCompletion: Bool = false) {
    let now = ProcessInfo.processInfo.systemUptime
    let enqueue = state.withLock { state in
      // Fallback also handles disconnected screens and a stalled main run loop.
      state.enqueue(now: now, displayTimestamp: displayTimestamp,
                    interval: interval, refreshInterval: refreshInterval,
                    afterLaneCompletion: afterLaneCompletion)
    }
    guard enqueue else { return }
    queue.async { [self] in
      let runs = state.withLock { $0.beginTick() }
      let executedAt = ProcessInfo.processInfo.systemUptime
      let advanced = runs && tick(self)
      let retry = state.withLock {
        if advanced, afterLaneCompletion { $0.laneSampleCount += 1 }
        else if advanced, displayTimestamp == nil { $0.timerSampleCount += 1 }
        return $0.finishTick(at: displayTimestamp ?? now, executedAt: executedAt, advanced: advanced)
      }
      // A lane can become ready after tick checked it but before queued clears.
      // Recheck readiness now; an accepted sample still owns the full interval.
      if retry { requestTick(afterLaneCompletion: true) }
    }
  }
}

@MainActor
private final class DisplayTarget: NSObject {
  private weak var driver: FrameAnimationDriver?
  private var link: CADisplayLink?

  init(screen: NSScreen, driver: FrameAnimationDriver) {
    self.driver = driver
    super.init()
    let link = screen.displayLink(target: self, selector: #selector(pulse(_:)))
    self.link = link
    link.add(to: .main, forMode: .common)
  }

  @objc private func pulse(_ link: CADisplayLink) { driver?.requestTick(displayTimestamp: link.timestamp) }
  func invalidate() { link?.invalidate(); link = nil }
}
