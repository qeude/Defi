import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

public struct MonitorSnapshot: Equatable, Sendable {
  public let id: MonitorID
  public let frame: Rect
  public let physicalFrame: Rect
  public let refreshRateHz: Double

  public init(
    id: MonitorID,
    frame: Rect,
    physicalFrame: Rect? = nil,
    refreshRateHz: Double = 60
  ) {
    self.id = id
    self.frame = frame
    self.physicalFrame = physicalFrame ?? frame
    self.refreshRateHz = refreshRateHz
  }
}

public func monitorGeometryChanged(
  from previous: [MonitorSnapshot],
  to next: [MonitorSnapshot],
  tolerance: Double = 0.5
) -> Bool {
  guard previous.count == next.count else { return true }
  let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
  for monitor in next {
    guard let old = previousByID[monitor.id] else { return true }
    for (lhs, rhs) in [
      (old.frame.x, monitor.frame.x),
      (old.frame.y, monitor.frame.y),
      (old.frame.width, monitor.frame.width),
      (old.frame.height, monitor.frame.height),
      (old.physicalFrame.x, monitor.physicalFrame.x),
      (old.physicalFrame.y, monitor.physicalFrame.y),
      (old.physicalFrame.width, monitor.physicalFrame.width),
      (old.physicalFrame.height, monitor.physicalFrame.height),
    ] where abs(lhs - rhs) > tolerance {
      return true
    }
  }
  return false
}

public struct DesktopSnapshot: Sendable {
  public let monitors: [MonitorSnapshot]
  public let windows: [Window]
  public let nativeFullscreenWindowIDs: Set<WindowID>
  public let focusedWindowID: WindowID?
  public let nativeFocusChanged: Bool
  public let removedWindowIDs: Set<WindowID>
  public let latestUserInputTimestamp: TimeInterval
  public let userInputAfterWindowTopology: Bool
  public let externallyChangedFrames: [WindowID: Rect]
  public let leftMouseButtonDown: Bool
  public let mouseResizeGestureObserved: Bool
  public let mouseFocusReleaseObserved: Bool
  public let nativeFocusObservedAfterMouseRelease: Bool
  public let mouseFocusIntentWindowID: WindowID?
  public let mouseFocusIntentTimestamp: TimeInterval?
  public let keyboardFocusIntentTimestamp: TimeInterval?
  public let targetMismatchCount: Int
  public let targetMismatches: [FrameMismatch]
  public let frontmostProcessID: pid_t?

  public init(
    monitors: [MonitorSnapshot],
    windows: [Window],
    nativeFullscreenWindowIDs: Set<WindowID> = [],
    focusedWindowID: WindowID?,
    nativeFocusChanged: Bool = false,
    removedWindowIDs: Set<WindowID> = [],
    latestUserInputTimestamp: TimeInterval = 0,
    userInputAfterWindowTopology: Bool = false,
    externallyChangedFrames: [WindowID: Rect] = [:],
    leftMouseButtonDown: Bool = false,
    mouseResizeGestureObserved: Bool = false,
    mouseFocusReleaseObserved: Bool = false,
    nativeFocusObservedAfterMouseRelease: Bool = false,
    mouseFocusIntentWindowID: WindowID? = nil,
    mouseFocusIntentTimestamp: TimeInterval? = nil,
    keyboardFocusIntentTimestamp: TimeInterval? = nil,
    targetMismatchCount: Int = 0,
    targetMismatches: [FrameMismatch] = [],
    frontmostProcessID: pid_t? = nil
  ) {
    self.monitors = monitors
    self.windows = windows
    self.nativeFullscreenWindowIDs = nativeFullscreenWindowIDs
    self.focusedWindowID = focusedWindowID
    self.nativeFocusChanged = nativeFocusChanged
    self.removedWindowIDs = removedWindowIDs
    self.latestUserInputTimestamp = latestUserInputTimestamp
    self.userInputAfterWindowTopology = userInputAfterWindowTopology
    self.externallyChangedFrames = externallyChangedFrames
    self.leftMouseButtonDown = leftMouseButtonDown
    self.mouseResizeGestureObserved = mouseResizeGestureObserved
    self.mouseFocusReleaseObserved = mouseFocusReleaseObserved
    self.nativeFocusObservedAfterMouseRelease =
      nativeFocusObservedAfterMouseRelease
    self.mouseFocusIntentWindowID = mouseFocusIntentWindowID
    self.mouseFocusIntentTimestamp = mouseFocusIntentTimestamp
    self.keyboardFocusIntentTimestamp = keyboardFocusIntentTimestamp
    self.targetMismatchCount = targetMismatchCount
    self.targetMismatches = targetMismatches
    self.frontmostProcessID = frontmostProcessID
  }
}

public struct FrameMismatch: Equatable, Sendable {
  public let windowID: WindowID
  public let actual: Rect
  public let target: Rect

  public init(windowID: WindowID, actual: Rect, target: Rect) {
    self.windowID = windowID
    self.actual = actual
    self.target = target
  }
}

public enum PlatformError: Error, CustomStringConvertible {
  case accessibilityPermissionMissing
  case attribute(String, AXError)
  case action(String, AXError)
  case windowUnavailable(WindowID)

  public var description: String {
    switch self {
    case .accessibilityPermissionMissing:
      "Accessibility permission missing"
    case .attribute(let name, let error):
      "AX attribute \(name) failed: \(error.rawValue)"
    case .action(let name, let error):
      "AX action \(name) failed: \(error.rawValue)"
    case .windowUnavailable(let id):
      "window unavailable: \(id.rawValue)"
    }
  }
}
