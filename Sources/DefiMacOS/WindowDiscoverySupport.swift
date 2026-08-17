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

struct AXWindowAttributes: Sendable {
  let minimized: Bool?
  let frame: Rect?
  let title: String
  let role: String?
  let subrole: String?
  let modal: Bool?

  init(
    minimized: Bool?,
    frame: Rect?,
    title: String,
    role: String?,
    subrole: String?,
    modal: Bool? = nil
  ) {
    self.minimized = minimized
    self.frame = frame
    self.title = title
    self.role = role
    self.subrole = subrole
    self.modal = modal
  }
}

struct PreparedAXWindowElement: @unchecked Sendable {
  let windowID: WindowID
  let processID: pid_t
  let element: AXUIElement
}

struct PreparedAXApplicationElement: @unchecked Sendable {
  let processID: pid_t
  let element: AXUIElement
}

struct PreparedAXApplicationWindows: @unchecked Sendable {
  let elements: [AXUIElement]
  let durationMS: Double
}

final class AXWindowIDProvider {
  private typealias GetWindowFunc =
    @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

  private let libraryHandle: UnsafeMutableRawPointer?
  private let getWindow: GetWindowFunc?

  init() {
    let handle = dlopen(
      "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
      RTLD_LAZY | RTLD_LOCAL
    )
    libraryHandle = handle
    getWindow = handle.flatMap { handle in
      dlsym(handle, "_AXUIElementGetWindow").map {
        unsafeBitCast($0, to: GetWindowFunc.self)
      }
    }
  }

  deinit {
    if let libraryHandle {
      dlclose(libraryHandle)
    }
  }

  var isAvailable: Bool { getWindow != nil }

  func windowID(for element: AXUIElement) -> CGWindowID? {
    guard let getWindow else { return nil }
    var windowID: CGWindowID = 0
    guard getWindow(element, &windowID) == .success, windowID != 0 else {
      return nil
    }
    return windowID
  }
}

func preparedAXWindowAttributesAreCurrent(
  capturedGeneration: UInt64,
  currentGeneration: UInt64,
  capturedInputTimestamp: TimeInterval,
  currentInputTimestamp: TimeInterval,
  capturedWindowIDs: Set<WindowID>,
  currentWindowIDs: Set<WindowID>,
  capturedProcessIDs: Set<pid_t>,
  currentProcessIDs: Set<pid_t>
) -> Bool {
  capturedGeneration == currentGeneration
    && capturedInputTimestamp == currentInputTimestamp
    && capturedWindowIDs == currentWindowIDs
    && capturedProcessIDs == currentProcessIDs
}

func copyBatchedWindowAttributes(
  _ element: AXUIElement
) -> (error: AXError, attributes: AXWindowAttributes?) {
  let names = [
    kAXMinimizedAttribute,
    kAXPositionAttribute,
    kAXSizeAttribute,
    kAXTitleAttribute,
    kAXRoleAttribute,
    kAXSubroleAttribute,
    kAXModalAttribute,
  ]
  var copiedValues: CFArray?
  let error = AXUIElementCopyMultipleAttributeValues(
    element,
    names as CFArray,
    AXCopyMultipleAttributeOptions(rawValue: 0),
    &copiedValues
  )
  guard error == .success,
    let values = copiedValues as? [AnyObject],
    values.count == names.count
  else {
    return (error, nil)
  }
  return (
    error,
    AXWindowAttributes(
      minimized: axAttributeValue(values[0]) as? Bool,
      frame: frameFromAXValues(
        positionValue: axAttributeValue(values[1]),
        sizeValue: axAttributeValue(values[2])
      ),
      title: axAttributeValue(values[3]) as? String ?? "",
      role: axAttributeValue(values[4]) as? String,
      subrole: axAttributeValue(values[5]) as? String,
      modal: axAttributeValue(values[6]) as? Bool
    )
  )
}

private func frameFromAXValues(
  positionValue: CFTypeRef?,
  sizeValue: CFTypeRef?
) -> Rect? {
  guard let positionValue,
    let sizeValue,
    CFGetTypeID(positionValue) == AXValueGetTypeID(),
    CFGetTypeID(sizeValue) == AXValueGetTypeID()
  else {
    return nil
  }
  var position = CGPoint.zero
  var size = CGSize.zero
  guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
  else {
    return nil
  }
  return Rect(
    x: position.x,
    y: position.y,
    width: size.width,
    height: size.height
  )
}

struct WindowManagementCapabilities: Equatable {
  let hasCloseButton: Bool
  let canResize: Bool
  let isModal: Bool
}

func shouldDisableBatchedWindowAttributeReads(failureCount: Int) -> Bool {
  failureCount >= 3
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
  frontmostProcessID: pid_t?,
  verifiedNativeFocusProcessID: pid_t? = nil
) -> pid_t? {
  if let accessibilityProcessID,
    let frontmostProcessID,
    accessibilityProcessID != frontmostProcessID
  {
    return verifiedNativeFocusProcessID == frontmostProcessID
      ? frontmostProcessID
      : nil
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
