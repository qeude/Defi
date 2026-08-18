import AppKit
import ApplicationServices
import CoreGraphics
import DefiModel
public final class UserInputTracker: @unchecked Sendable {
  public enum FocusIntentSource: Equatable, Sendable {
    case keyboard
    case mouse(windowID: WindowID?)
  }

  public struct FocusIntent: Equatable, Sendable {
    public let timestamp: TimeInterval
    public let source: FocusIntentSource
  }

  public struct FocusRecoveryTarget: Equatable, Sendable {
    public let timestamp: TimeInterval
    public let windowID: WindowID?
    public let processID: pid_t?
  }

  public struct Snapshot: Equatable, Sendable {
    public let latestEventTimestamp: TimeInterval
    public let latestFocusIntent: FocusIntent?
    public let latestCloseIntent: TimeInterval
  }

  private struct ObservedFocusTarget: Equatable {
    let windowID: WindowID?
    let processID: pid_t?
  }

  private let lock = NSLock()
  private var latestTimestamp: TimeInterval = 0
  private var latestFocusIntent: FocusIntent?
  private var latestCloseIntentTimestamp: TimeInterval = 0
  private var observedFocusIntentTimestamp: TimeInterval = 0
  private var observedFocusTargets: [ObservedFocusTarget] = []

  public init() {}

  public func record(
    timestamp: TimeInterval,
    focusIntent: FocusIntentSource? = nil,
    closeIntent: Bool = false
  ) {
    lock.lock()
    latestTimestamp = max(latestTimestamp, timestamp)
    if let focusIntent,
      latestFocusIntent.map({ timestamp >= $0.timestamp }) ?? true
    {
      if latestFocusIntent.map({ timestamp > $0.timestamp }) ?? true {
        observedFocusIntentTimestamp = 0
        observedFocusTargets.removeAll(keepingCapacity: true)
      }
      latestFocusIntent = FocusIntent(
        timestamp: timestamp,
        source: focusIntent
      )
    }
    if closeIntent {
      latestCloseIntentTimestamp = max(latestCloseIntentTimestamp, timestamp)
    }
    lock.unlock()
  }

  public func invalidate(at timestamp: TimeInterval) {
    lock.lock()
    latestTimestamp = max(latestTimestamp, timestamp).nextUp
    latestFocusIntent = nil
    observedFocusIntentTimestamp = 0
    observedFocusTargets.removeAll(keepingCapacity: true)
    lock.unlock()
  }

  public func recordObservedFocus(
    windowID: WindowID?,
    processID: pid_t?
  ) {
    lock.lock()
    guard let focusIntent = latestFocusIntent,
      focusIntent.timestamp > latestCloseIntentTimestamp,
      windowID != nil || processID != nil
    else {
      lock.unlock()
      return
    }
    if observedFocusIntentTimestamp != focusIntent.timestamp {
      observedFocusIntentTimestamp = focusIntent.timestamp
      observedFocusTargets.removeAll(keepingCapacity: true)
    }
    let target = ObservedFocusTarget(
      windowID: windowID,
      processID: processID
    )
    if let windowID,
      let index = observedFocusTargets.lastIndex(where: {
        $0.windowID == nil && $0.processID == processID
      })
    {
      observedFocusTargets[index] = ObservedFocusTarget(
        windowID: windowID,
        processID: processID
      )
    } else if !observedFocusTargets.contains(target) {
      observedFocusTargets.append(target)
      if observedFocusTargets.count > 8 {
        observedFocusTargets.removeFirst()
      }
    }
    lock.unlock()
  }

  public func consumeFocusIntent(at timestamp: TimeInterval) {
    lock.lock()
    guard latestFocusIntent?.timestamp == timestamp else {
      lock.unlock()
      return
    }
    latestFocusIntent = nil
    observedFocusIntentTimestamp = 0
    observedFocusTargets.removeAll(keepingCapacity: true)
    lock.unlock()
  }

  public func focusRecoveryTarget(
    after timestamp: TimeInterval,
    excludingWindowID: WindowID? = nil,
    excludingProcessID: pid_t? = nil,
    fallbackWindowID: WindowID? = nil,
    fallbackProcessID: pid_t? = nil
  ) -> FocusRecoveryTarget? {
    lock.lock()
    defer { lock.unlock() }
    guard latestTimestamp > timestamp else {
      return nil
    }
    if let focusIntent = latestFocusIntent,
      focusIntent.timestamp > timestamp
    {
      guard focusIntent.timestamp > latestCloseIntentTimestamp else {
        return nil
      }
      let observedTarget = {
        guard self.observedFocusIntentTimestamp == focusIntent.timestamp else {
          return nil as ObservedFocusTarget?
        }
        return self.observedFocusTargets.reversed().first(where: {
          if let excludingWindowID, $0.windowID == excludingWindowID {
            return false
          }
          if $0.windowID == nil,
            let excludingProcessID,
            $0.processID == excludingProcessID
          {
            return false
          }
          return true
        })
      }
      switch focusIntent.source {
      case .keyboard:
        guard let target = observedTarget() else { return nil }
        return FocusRecoveryTarget(
          timestamp: latestTimestamp,
          windowID: target.windowID,
          processID: target.processID
        )
      case .mouse(let windowID):
        if let target = observedTarget(), target.windowID != windowID {
          return FocusRecoveryTarget(
            timestamp: latestTimestamp,
            windowID: target.windowID,
            processID: target.processID
          )
        }
        if let windowID {
          return FocusRecoveryTarget(
            timestamp: latestTimestamp,
            windowID: windowID,
            processID: nil
          )
        }
        guard let target = observedTarget() else { return nil }
        return FocusRecoveryTarget(
          timestamp: latestTimestamp,
          windowID: target.windowID,
          processID: target.processID
        )
      }
    }
    guard latestCloseIntentTimestamp <= timestamp else { return nil }
    if let fallbackWindowID, fallbackWindowID == excludingWindowID {
      return nil
    }
    if fallbackWindowID == nil,
      let fallbackProcessID,
      fallbackProcessID == excludingProcessID
    {
      return nil
    }
    guard fallbackWindowID != nil || fallbackProcessID != nil else {
      return nil
    }
    return FocusRecoveryTarget(
      timestamp: latestTimestamp,
      windowID: fallbackWindowID,
      processID: fallbackProcessID
    )
  }

  public var latestEventTimestamp: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return latestTimestamp
  }

  public var snapshot: Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return Snapshot(
      latestEventTimestamp: latestTimestamp,
      latestFocusIntent: latestFocusIntent,
      latestCloseIntent: latestCloseIntentTimestamp
    )
  }
}
