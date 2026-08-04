import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

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
    cgWindows: [CGWindowRecord],
    monitors: [MonitorSnapshot],
    preferredWindowID: WindowID?,
    excluding usedCGWindowIDs: Set<CGWindowID>
  ) -> (Window, CGWindowID)? {
    guard value(element, attribute: kAXMinimizedAttribute, as: Bool.self) != true,
      let frame = frame(of: element),
      frame.width >= 80,
      frame.height >= 60
    else {
      return nil
    }
    let title = value(element, attribute: kAXTitleAttribute, as: String.self) ?? ""
    let role = value(element, attribute: kAXRoleAttribute, as: String.self)
    let subrole = value(element, attribute: kAXSubroleAttribute, as: String.self)
    let record =
      (preferredWindowID.flatMap { preferred in
        cgWindows.first {
          $0.id == CGWindowID(preferred.rawValue)
            && $0.processID == processID
            && !usedCGWindowIDs.contains($0.id)
        }
      }
        ?? bestCGWindow(
          processID: processID,
          title: title,
          frame: frame,
          records: cgWindows,
          excluding: usedCGWindowIDs
        ))
    guard
      let resolvedWindowID = resolvedCGWindowID(
        matchedRecord: record,
        preferredWindowID: preferredWindowID
      )
    else {
      return nil
    }
    let monitorID = monitor(containing: frame, monitors: monitors)?.id
    return (
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
      ), resolvedWindowID
    )
  }

  func windowDisposition(
    _ window: Window,
    element: AXUIElement,
    configuredFloating: Bool,
    forceTiling: Bool,
    wasPreviouslyTracked: Bool
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
      shouldDeferStandardWindowClassification(
        role: window.role,
        subrole: window.subrole,
        closeButtonError: closeButtonError,
        sizeSettableError: sizeSettableError,
        wasPreviouslyTracked: wasPreviouslyTracked
      )
    {
      return .ignored
    }
    return classifyWindow(
      role: window.role,
      subrole: window.subrole,
      appID: window.appID,
      hasCloseButton: shouldTreatWindowAsClosable(
        error: closeButtonError,
        hasValue: closeButton != nil,
        wasPreviouslyManaged: wasPreviouslyTracked
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
    let ranked = windows.filter {
      $0.processID == focusedProcessID
    }.sorted {
      frameDistance($0.frame, focusedFrame) < frameDistance($1.frame, focusedFrame)
    }
    guard let closest = ranked.first else { return nil }
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
