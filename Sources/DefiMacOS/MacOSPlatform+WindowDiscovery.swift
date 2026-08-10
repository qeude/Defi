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
    publicCGWindows: () -> [CGWindowRecord]?,
    monitors: [MonitorSnapshot],
    preferredWindowID: WindowID?,
    excluding usedCGWindowIDs: Set<CGWindowID>
  ) -> WindowDiscoveryResult {
    let attributes = windowAttributes(element, processID: processID)
    let geometry = windowGeometryDiscovery(
      minimized: attributes.minimized,
      frame: { attributes.frame }
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
    let title = attributes.title
    let role = attributes.role
    let subrole = attributes.subrole
    let decision = config.decision(appID: appID, title: title, role: role)
    guard let publicCGWindows = publicCGWindows() else {
      return .unavailable
    }
    let eligibleCGWindows = eligibleCGWindowRecords(
      role: role,
      for: subrole,
      allowsConfiguredNonzeroLayer: decision.floating || decision.forceTiling,
      in: publicCGWindows
    )
    let record = cgWindowRecordForDiscovery(
      preferredWindowID: preferredWindowID,
      processID: processID,
      title: title,
      frame: frame,
      records: eligibleCGWindows,
      excluding: usedCGWindowIDs
    )
    guard let resolvedWindowID = record?.id else {
      return .unmatched
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
    previousDisposition: WindowDisposition?,
    reuseCachedCapabilities: Bool
  ) -> WindowDisposition {
    if forceTiling || configuredFloating
      || window.role != kAXWindowRole
      || window.subrole != kAXStandardWindowSubrole
    {
      return classifyWindow(
        role: window.role,
        subrole: window.subrole,
        appID: window.appID,
        hasCloseButton: false,
        canResize: false,
        configuredFloating: configuredFloating,
        forceTiling: forceTiling
      )
    }
    if reuseCachedCapabilities,
      let capabilities = windowManagementCapabilities[window.id]
    {
      windowManagementMetadataReuseCount += 1
      return classifyWindow(
        role: window.role,
        subrole: window.subrole,
        appID: window.appID,
        hasCloseButton: capabilities.hasCloseButton,
        canResize: capabilities.canResize,
        configuredFloating: false,
        forceTiling: false
      )
    }
    windowManagementMetadataReadCount += 1
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
    let capabilities = WindowManagementCapabilities(
      hasCloseButton: shouldTreatWindowAsClosable(
        error: closeButtonError,
        hasValue: closeButton != nil,
        wasPreviouslyManaged: previousDisposition != nil
      ),
      canResize: windowCanResize(
        sizeSettableError: sizeSettableError,
        isSettable: sizeSettable.boolValue
      )
    )
    windowManagementCapabilities[window.id] = capabilities
    return classifyWindow(
      role: window.role,
      subrole: window.subrole,
      appID: window.appID,
      hasCloseButton: capabilities.hasCloseButton,
      canResize: capabilities.canResize,
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

  func windowAttributes(
    _ element: AXUIElement,
    processID: pid_t
  ) -> AXWindowAttributes {
    if multipleAttributeReadsSupportedByProcess[processID] != false,
      let attributes = batchedWindowAttributes(element)
    {
      multipleAttributeReadsSupportedByProcess[processID] = true
      batchedWindowAttributeReadCount += 1
      return attributes
    }
    fallbackWindowAttributeReadCount += 1
    return AXWindowAttributes(
      minimized: value(
        element,
        attribute: kAXMinimizedAttribute,
        as: Bool.self
      ),
      frame: frame(of: element),
      title: value(
        element,
        attribute: kAXTitleAttribute,
        as: String.self
      ) ?? "",
      role: value(element, attribute: kAXRoleAttribute, as: String.self),
      subrole: value(
        element,
        attribute: kAXSubroleAttribute,
        as: String.self
      )
    )
  }

  private func batchedWindowAttributes(
    _ element: AXUIElement
  ) -> AXWindowAttributes? {
    let names = [
      kAXMinimizedAttribute,
      kAXPositionAttribute,
      kAXSizeAttribute,
      kAXTitleAttribute,
      kAXRoleAttribute,
      kAXSubroleAttribute,
    ]
    var copiedValues: CFArray?
    let result = AXUIElementCopyMultipleAttributeValues(
      element,
      names as CFArray,
      AXCopyMultipleAttributeOptions(rawValue: 0),
      &copiedValues
    )
    guard result == .success,
      let values = copiedValues as? [AnyObject],
      values.count == names.count
    else {
      if result == .notImplemented || result == .attributeUnsupported {
        var processID: pid_t = 0
        if AXUIElementGetPid(element, &processID) == .success {
          multipleAttributeReadsSupportedByProcess[processID] = false
        }
      }
      return nil
    }
    return AXWindowAttributes(
      minimized: axAttributeValue(values[0]) as? Bool,
      frame: frame(
        positionValue: axAttributeValue(values[1]),
        sizeValue: axAttributeValue(values[2])
      ),
      title: axAttributeValue(values[3]) as? String ?? "",
      role: axAttributeValue(values[4]) as? String,
      subrole: axAttributeValue(values[5]) as? String
    )
  }

  private func frame(
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
