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
  public let activeNativeFullscreenWindowIDs: Set<WindowID>
  public let focusedWindowID: WindowID?
  public let nativeFocusChanged: Bool
  public let removedWindowIDs: Set<WindowID>
  public let windowIDReplacements: [WindowID: WindowID]
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
  public let targetMismatches: [FrameMismatch]
  public let frontmostProcessID: pid_t?

  public init(
    monitors: [MonitorSnapshot],
    windows: [Window],
    nativeFullscreenWindowIDs: Set<WindowID> = [],
    activeNativeFullscreenWindowIDs: Set<WindowID> = [],
    focusedWindowID: WindowID?,
    nativeFocusChanged: Bool = false,
    removedWindowIDs: Set<WindowID> = [],
    windowIDReplacements: [WindowID: WindowID] = [:],
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
    targetMismatches: [FrameMismatch] = [],
    frontmostProcessID: pid_t? = nil
  ) {
    self.monitors = monitors
    self.windows = windows
    self.nativeFullscreenWindowIDs = nativeFullscreenWindowIDs
    self.activeNativeFullscreenWindowIDs = activeNativeFullscreenWindowIDs
    self.focusedWindowID = focusedWindowID
    self.nativeFocusChanged = nativeFocusChanged
    self.removedWindowIDs = removedWindowIDs
    self.windowIDReplacements = windowIDReplacements
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
