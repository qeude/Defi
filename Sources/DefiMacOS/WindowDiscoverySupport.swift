import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

enum WindowGeometryDiscovery: Equatable {
  case unavailable
  case ignored
  case usable(Rect)
}

enum WindowDiscoveryResult {
  case unavailable
  case ignored
  case transientGeometry
  case unmatched
  case discovered(Window, CGWindowID, RuleDecision)
}

struct AXWindowAttributes {
  let minimized: Bool?
  let frame: Rect?
  let title: String
  let role: String?
  let subrole: String?
}

struct WindowManagementCapabilities: Equatable {
  let hasCloseButton: Bool
  let canResize: Bool
  let isModal: Bool
}

func fallbackWindowAttributes(
  minimized: () -> Bool?,
  frame: () -> Rect?,
  title: () -> String?,
  role: () -> String?,
  subrole: () -> String?
) -> AXWindowAttributes {
  let minimizedValue = minimized()
  guard minimizedValue != true else {
    return AXWindowAttributes(
      minimized: true,
      frame: nil,
      title: "",
      role: nil,
      subrole: nil
    )
  }
  return AXWindowAttributes(
    minimized: minimizedValue,
    frame: frame(),
    title: title() ?? "",
    role: role(),
    subrole: subrole()
  )
}

func axAttributeValue(_ value: AnyObject) -> CFTypeRef? {
  let rawValue = value as CFTypeRef
  guard rawValue !== kCFNull else { return nil }
  if CFGetTypeID(rawValue) == AXValueGetTypeID(),
    AXValueGetType(rawValue as! AXValue) == .axError
  {
    return nil
  }
  return rawValue
}

func windowGeometryDiscovery(
  minimized: Bool?,
  frame: () -> Rect?
) -> WindowGeometryDiscovery {
  if minimized == true {
    return .ignored
  }
  guard let frame = frame() else {
    return .unavailable
  }
  guard frame.width >= 80, frame.height >= 60 else {
    return .ignored
  }
  return .usable(frame)
}

func cachedWindowIDsToRetain(
  processID: pid_t,
  previousWindows: [Window],
  discoveredWindowIDs: Set<WindowID>,
  ignoredWindowIDs: Set<WindowID>,
  cgWindows: [CGWindowRecord]?,
  cachedMinimizedState: ((WindowID) -> Bool?)?
) -> Set<WindowID> {
  var retainedWindowIDs = Set(previousWindows.map(\.id))
    .subtracting(discoveredWindowIDs)
    .subtracting(ignoredWindowIDs)
  if let cgWindows {
    let liveWindowIDs = Set(
      cgWindows.lazy
        .filter { $0.processID == processID }
        .map { WindowID(rawValue: UInt64($0.id)) }
    )
    retainedWindowIDs.formIntersection(liveWindowIDs)
  }
  guard let cachedMinimizedState else { return retainedWindowIDs }
  return Set(retainedWindowIDs.filter { cachedMinimizedState($0) != true })
}

func retainedWindowIDsWithinGracePeriod(
  _ candidates: Set<WindowID>,
  previousDeadlines: [WindowID: TimeInterval],
  now: TimeInterval,
  gracePeriod: TimeInterval = 0.75
) -> (windowIDs: Set<WindowID>, deadlines: [WindowID: TimeInterval]) {
  var retained = Set<WindowID>()
  var deadlines: [WindowID: TimeInterval] = [:]
  for windowID in candidates {
    let deadline = previousDeadlines[windowID] ?? now + gracePeriod
    guard now < deadline else { continue }
    retained.insert(windowID)
    deadlines[windowID] = deadline
  }
  return (retained, deadlines)
}

func consistentFocusedProcessID(
  accessibilityProcessID: pid_t?,
  frontmostProcessID: pid_t?
) -> pid_t? {
  if let accessibilityProcessID,
    let frontmostProcessID,
    accessibilityProcessID != frontmostProcessID
  {
    return nil
  }
  return accessibilityProcessID ?? frontmostProcessID
}

func focusedWindowIDMatchingFrame(
  processID: pid_t,
  focusedFrame: Rect,
  windows: [Window],
  maximumDistance: Double = 80
) -> WindowID? {
  let ranked = windows.filter {
    $0.processID == processID
  }.sorted {
    frameDistance($0.frame, focusedFrame) < frameDistance($1.frame, focusedFrame)
  }
  guard let closest = ranked.first,
    frameDistance(closest.frame, focusedFrame) <= maximumDistance
  else {
    return nil
  }
  if ranked.count > 1,
    abs(
      frameDistance(closest.frame, focusedFrame)
        - frameDistance(ranked[1].frame, focusedFrame)
    ) < 0.5
  {
    return nil
  }
  return closest.id
}
