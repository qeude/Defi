import AppKit
import ApplicationServices
import CoreGraphics
import DefiModel
public final class PointerMotionTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var timestamp: TimeInterval = 0

  public init() {}

  public func record(timestamp: TimeInterval) {
    lock.lock()
    self.timestamp = max(self.timestamp, timestamp)
    lock.unlock()
  }

  public func invalidate(at timestamp: TimeInterval) {
    lock.lock()
    self.timestamp = max(self.timestamp, timestamp).nextUp
    lock.unlock()
  }

  public var latestTimestamp: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return timestamp
  }
}

struct PointerWindowTransitionState {
  private var previousRawWindowID: Int64?

  mutating func changed(to rawWindowID: Int64) -> Bool {
    guard previousRawWindowID != rawWindowID else { return false }
    previousRawWindowID = rawWindowID
    return true
  }

  mutating func reset() {
    previousRawWindowID = nil
  }
}

func pointerMotionDeliveryDelay(
  rawWindowID: Int64,
  eventTimestamp: TimeInterval,
  lastDeliveryTimestamp: TimeInterval?,
  maximumFrequencyHz: Double = 120
) -> TimeInterval {
  guard maximumFrequencyHz > 0,
    let lastDeliveryTimestamp
  else {
    return 0
  }
  let minimumInterval = 1 / maximumFrequencyHz
  let elapsed = max(0, eventTimestamp - lastDeliveryTimestamp)
  return max(0, minimumInterval - elapsed)
}

struct PointerMotionDeliveryPlan: Equatable {
  let shouldSchedule: Bool
  let delay: TimeInterval
}

func pointerMotionDeliveryPlan(
  rawWindowChanged: Bool,
  refreshDelay: TimeInterval,
  deliveryScheduled: Bool
) -> PointerMotionDeliveryPlan {
  PointerMotionDeliveryPlan(
    shouldSchedule: !deliveryScheduled,
    delay: rawWindowChanged ? 0 : refreshDelay
  )
}
