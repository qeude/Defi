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
  case discovered(Window, CGWindowID, RuleDecision)
}

@MainActor
extension MacOSPlatform {

  public func discoverMonitors() -> [MonitorSnapshot] {
    let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
    return NSScreen.screens.compactMap { screen in
      guard
        let number = screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber
      else {
        return nil
      }
      let visible = screen.visibleFrame
      let physical = screen.frame
      return MonitorSnapshot(
        id: MonitorID(rawValue: number.uint64Value),
        frame: Rect(
          x: visible.minX,
          y: mainTop - visible.maxY,
          width: visible.width,
          height: visible.height
        ),
        physicalFrame: Rect(
          x: physical.minX,
          y: mainTop - physical.maxY,
          width: physical.width,
          height: physical.height
        ),
        refreshRateHz: Double(screen.maximumFramesPerSecond)
      )
    }
  }

  func makeWindow(
    element: AXUIElement,
    processID: pid_t,
    appID: String,
    config: Config,
    cgWindows: [CGWindowRecord],
    monitors: [MonitorSnapshot],
    preferredWindowID: WindowID?,
    excluding usedCGWindowIDs: Set<CGWindowID>
  ) -> WindowDiscoveryResult {
    let geometry = windowGeometryDiscovery(
      minimized: value(element, attribute: kAXMinimizedAttribute, as: Bool.self),
      frame: { self.frame(of: element) }
    )
    let frame: Rect
    switch geometry {
    case .unavailable:
      return .unavailable
    case .ignored:
      return .ignored
    case .usable(let usableFrame):
      frame = usableFrame
    }
    let title = value(element, attribute: kAXTitleAttribute, as: String.self) ?? ""
    let role = value(element, attribute: kAXRoleAttribute, as: String.self)
    let subrole = value(element, attribute: kAXSubroleAttribute, as: String.self)
    let decision = config.decision(appID: appID, title: title, role: role)
    let eligibleCGWindows = eligibleCGWindowRecords(
      role: role,
      for: subrole,
      allowsConfiguredNonzeroLayer: decision.floating || decision.forceTiling,
      in: cgWindows
    )
    let record =
      (preferredWindowID.flatMap { preferred in
        eligibleCGWindows.first {
          $0.id == CGWindowID(preferred.rawValue)
            && $0.processID == processID
            && !usedCGWindowIDs.contains($0.id)
        }
      }
        ?? bestCGWindow(
          processID: processID,
          title: title,
          frame: frame,
          records: eligibleCGWindows,
          excluding: usedCGWindowIDs
        ))
    guard
      let resolvedWindowID = resolvedCGWindowID(
        matchedRecord: record,
        preferredWindowID: preferredWindowID
      )
    else {
      return .ignored
    }
    let monitorID = monitor(containing: frame, monitors: monitors)?.id
    return .discovered(
      Window(
        id: WindowID(rawValue: UInt64(resolvedWindowID)),
        appID: appID,
        title: title,
        frame: frame,
        role: role,
        subrole: subrole,
        processID: processID,
        monitorID: monitorID,
        forceTiling: false
      ), resolvedWindowID, decision
    )
  }

  func windowDisposition(
    _ window: Window,
    element: AXUIElement,
    configuredFloating: Bool,
    forceTiling: Bool,
    previousDisposition: WindowDisposition?
  ) -> WindowDisposition {
    var closeButton: CFTypeRef?
    let closeButtonError = AXUIElementCopyAttributeValue(
      element,
      kAXCloseButtonAttribute as CFString,
      &closeButton
    )
    var sizeSettable = DarwinBoolean(false)
    let sizeSettableError = AXUIElementIsAttributeSettable(
      element,
      kAXSizeAttribute as CFString,
      &sizeSettable
    )
    if !configuredFloating,
      !forceTiling,
      let fallbackDisposition = fallbackDispositionForTransientWindowMetadata(
        role: window.role,
        subrole: window.subrole,
        closeButtonError: closeButtonError,
        sizeSettableError: sizeSettableError,
        previousDisposition: previousDisposition
      )
    {
      return fallbackDisposition
    }
    return classifyWindow(
      role: window.role,
      subrole: window.subrole,
      appID: window.appID,
      hasCloseButton: shouldTreatWindowAsClosable(
        error: closeButtonError,
        hasValue: closeButton != nil,
        wasPreviouslyManaged: previousDisposition != nil
      ),
      canResize: windowCanResize(
        sizeSettableError: sizeSettableError,
        isSettable: sizeSettable.boolValue
      ),
      configuredFloating: configuredFloating,
      forceTiling: forceTiling
    )
  }

  func focusedWindowID(
    in windows: [Window]
  ) -> WindowID? {
    let frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    var focusedApplication: CFTypeRef?
    let system = AXUIElementCreateSystemWide()
    guard
      AXUIElementCopyAttributeValue(
        system,
        kAXFocusedApplicationAttribute as CFString,
        &focusedApplication
      ) == .success,
      let focusedApplication
    else {
      return stableWindowID(processID: frontmostProcessID, in: windows)
    }
    var focusedProcessID: pid_t = 0
    guard
      AXUIElementGetPid(
        focusedApplication as! AXUIElement,
        &focusedProcessID
      ) == .success
    else {
      return stableWindowID(processID: frontmostProcessID, in: windows)
    }
    let resolvedProcessID = consistentFocusedProcessID(
      accessibilityProcessID: focusedProcessID,
      frontmostProcessID: frontmostProcessID
    )
    guard resolvedProcessID == focusedProcessID else {
      return nil
    }
    var focusedWindow: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        focusedApplication as! AXUIElement,
        kAXFocusedWindowAttribute as CFString,
        &focusedWindow
      ) == .success,
      let focusedWindow
    else {
      return stableWindowID(processID: focusedProcessID, in: windows)
    }
    let focusedElement = focusedWindow as! AXUIElement
    if let exact = elements.first(where: { CFEqual($0.value, focusedElement) }) {
      return exact.key
    }
    guard let focusedFrame = frame(of: focusedElement) else {
      return stableWindowID(processID: focusedProcessID, in: windows)
    }
    return focusedWindowIDMatchingFrame(
      processID: focusedProcessID,
      focusedFrame: focusedFrame,
      windows: windows
    )
  }

  func stableWindowID(
    processID: pid_t?,
    in windows: [Window]
  ) -> WindowID? {
    guard let processID else { return nil }
    let candidates = windows.filter { $0.processID == processID }
    if let previous = lastFocusedWindowByProcess[processID],
      candidates.contains(where: { $0.id == previous })
    {
      return previous
    }
    return candidates.count == 1 ? candidates[0].id : nil
  }

  func frame(of element: AXUIElement) -> Rect? {
    guard let positionValue = copyAttribute(element, name: kAXPositionAttribute),
      let sizeValue = copyAttribute(element, name: kAXSizeAttribute),
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
    return Rect(x: position.x, y: position.y, width: size.width, height: size.height)
  }

  func copyAttribute(_ element: AXUIElement, name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  func value<Value>(
    _ element: AXUIElement,
    attribute: String,
    as type: Value.Type
  ) -> Value? {
    copyAttribute(element, name: attribute) as? Value
  }

  func copyElements(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
    copyAttribute(element, name: attribute) as? [AXUIElement]
  }
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
  cgWindows: [CGWindowRecord],
  cachedMinimizedState: ((WindowID) -> Bool?)?
) -> Set<WindowID> {
  let liveWindowIDs = Set(
    cgWindows.lazy
      .filter { $0.processID == processID }
      .map { WindowID(rawValue: UInt64($0.id)) }
  )
  let retainedWindowIDs = Set(previousWindows.map(\.id))
    .intersection(liveWindowIDs)
    .subtracting(discoveredWindowIDs)
    .subtracting(ignoredWindowIDs)
  guard let cachedMinimizedState else { return retainedWindowIDs }
  return Set(retainedWindowIDs.filter { cachedMinimizedState($0) != true })
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
