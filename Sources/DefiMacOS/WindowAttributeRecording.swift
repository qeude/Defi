import AppKit
import ApplicationServices
import DefiModel

/// The Accessibility attributes window classification reads, recorded from a real window
/// without its title or content, so it can become a classification fixture.
public struct WindowAttributeRecord: Codable, Equatable, Sendable {
  public var appID: String
  public var role: String?
  public var subrole: String?
  public var hasCloseButton: Bool
  public var canResize: Bool
  public var canGrow: Bool
  public var isModal: Bool
  /// What Defi decides for the window today: `tiled`, `floating`, `ignored` or `unavailable`.
  public var disposition: String

  init(appID: String, role: String?, subrole: String?, hasCloseButton: Bool,
       canResize: Bool, canGrow: Bool, isModal: Bool) {
    self.appID = appID
    self.role = role
    self.subrole = subrole
    self.hasCloseButton = hasCloseButton
    self.canResize = canResize
    self.canGrow = canGrow
    self.isModal = isModal
    disposition = ""
    disposition = currentDisposition
  }

  /// Classification as Defi decides it now, for fixtures recorded by an older build.
  public var currentDisposition: String {
    "\(classifyWindow(role: role, subrole: subrole, appID: appID, hasCloseButton: hasCloseButton, canResize: canResize, canGrow: canGrow, isModal: isModal, configuredFloating: false, forceTiling: false))"
  }
}

/// Reads every window of every running app, read-only, with a short Accessibility timeout.
/// Off the main thread: a slow app costs at most its timeout.
public func recordWindowAttributes() -> [WindowAttributeRecord] {
  func copy(_ element: AXUIElement, _ attribute: String) -> (AXError, CFTypeRef?) {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return (error, value)
  }
  func buttonEnabled(_ window: AXUIElement, _ attribute: String) -> Bool {
    guard case (.success, let button?) = copy(window, attribute),
      CFGetTypeID(button) == AXUIElementGetTypeID()
    else { return false }
    return copy(button as! AXUIElement, kAXEnabledAttribute).1 as? Bool ?? true
  }
  var records: [WindowAttributeRecord] = []
  for application in NSWorkspace.shared.runningApplications where application.activationPolicy != .prohibited {
    guard let appID = application.bundleIdentifier else { continue }
    let element = accessibilityApplication(application.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 0.1)
    for window in (copy(element, kAXWindowsAttribute).1 as? [AXUIElement]) ?? [] {
      AXUIElementSetMessagingTimeout(window, 0.1)
      var settable: DarwinBoolean = false
      AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable)
      records.append(WindowAttributeRecord(
        appID: appID,
        role: copy(window, kAXRoleAttribute).1 as? String,
        subrole: copy(window, kAXSubroleAttribute).1 as? String,
        hasCloseButton: copy(window, kAXCloseButtonAttribute).0 == .success,
        canResize: settable.boolValue,
        canGrow: buttonEnabled(window, kAXFullScreenButtonAttribute) || buttonEnabled(window, kAXZoomButtonAttribute),
        isModal: copy(window, kAXModalAttribute).1 as? Bool ?? false
      ))
    }
  }
  return records
}
