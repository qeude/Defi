import AppKit
import ApplicationServices
import DefiConfig
import Foundation

/// What classification reads from one window. `defi inspect-window` prints it, and the fixtures
/// in `Tests/Fixtures/WindowClassification` replay it.
struct WindowClassificationInput: Codable, Equatable, Sendable {
  var appID: String
  var role: String?
  var subrole: String?
  var title = ""
  var identifier: String?
  /// Each button is nil when the window has none, else whether it is enabled.
  var closeButton: Bool?
  var zoomButton: Bool?
  var fullScreenButton: Bool?
  var resizable = false
  var modal = false
  var layer = 0
}

struct WindowClassification: Codable, Equatable, Sendable {
  var disposition: WindowDisposition
  var reason: String
}

/// One window's inputs and outcome: the output of `defi inspect-window`, and one fixture.
struct WindowClassificationReport: Codable, Equatable, Sendable {
  var rule: RuleWindow?
  var window: WindowClassificationInput
  var disposition: WindowDisposition
  var reason: String
}

private let ignoredWindowApplicationIDs: Set<String> = [
  "com.apple.dock",
  "com.apple.systemuiserver",
  "com.raycast.macos",
]

let automaticFloatingWindowSubroles: Set<String> = [
  "AXDialog",
  "AXFloatingWindow",
  "AXSystemDialog",
  "AXSystemFloatingWindow",
]

private let automaticFloatingWindowApplicationIDs: Set<String> = [
  "com.apple.quicklook.quicklookuiservice"
]

func isIgnoredWindowApplication(_ appID: String) -> Bool {
  ignoredWindowApplicationIDs.contains(appID.lowercased())
}

/// Windows above the normal level are menus, panels, and overlays unless they float by nature or by rule.
func windowLayerIsEligible(_ layer: Int, role: String?, subrole: String?, allowsConfiguredNonzeroLayer: Bool) -> Bool {
  layer == 0
    || (layer > 0
      && (allowsConfiguredNonzeroLayer || role == kAXSheetRole
        || subrole.map(automaticFloatingWindowSubroles.contains) == true))
}

/// App-drawn menus and palettes, such as Yab's action menu. A modal one is a real dialog.
func isAppDrawnPopup(subrole: String?, isModal: Bool) -> Bool {
  !isModal && (subrole == "AXSystemDialog" || subrole == "AXSystemFloatingWindow")
}

/// A system text accessory: a remote view TextEdit shows as an untitled dialog each time its
/// text settles. It animates its own size and refuses to move, so managing it opened a floating
/// window on the overlay and held every workspace landing until it timed out.
func isSystemTextAccessory(title: String, hasCloseButton: Bool, isModal: Bool) -> Bool {
  title.isEmpty && !hasCloseButton && !isModal
}

/// A new window that is a system text accessory, such as an input method's candidate list,
/// read with a short timeout; false when the app does not answer in time.
func isTextInputAccessory(_ element: AXUIElement) -> Bool {
  AXMessagingTimeoutAccess.shared.withTimeout(accessibilityReadTimeoutSeconds, elements: [element]) {
    var values: CFArray?
    AXUIElementCopyMultipleAttributeValues(element,
      [kAXSubroleAttribute, kAXTitleAttribute, kAXCloseButtonAttribute, kAXModalAttribute] as CFArray,
      [], &values)
    let read = values as? [AnyObject] ?? []
    // A missing attribute reads back as an AXValue error, not as the attribute's type.
    guard read.count == 4, read[0] as? String == kAXDialogSubrole else { return false }
    return isSystemTextAccessory(title: read[1] as? String ?? "",
      hasCloseButton: CFGetTypeID(read[2]) == AXUIElementGetTypeID(), isModal: read[3] as? Bool ?? false)
  }
}

/// Nil when the window has no such button, else whether it is enabled. An unknown read counts as
/// an enabled button.
func windowButtonState(_ element: AXUIElement, _ attribute: String) -> Bool? {
  var button: CFTypeRef?
  let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &button)
  guard error == .success, let button else {
    return error == .noValue || error == .attributeUnsupported ? nil : true
  }
  var enabled: CFTypeRef?
  guard AXUIElementCopyAttributeValue(
    (button as! AXUIElement), kAXEnabledAttribute as CFString, &enabled) == .success
  else {
    return true
  }
  return enabled as? Bool ?? true
}

func classifyWindow(_ window: WindowClassificationInput, rule: RuleWindow?) -> WindowClassification {
  func outcome(_ disposition: WindowDisposition, _ reason: String) -> WindowClassification {
    WindowClassification(disposition: disposition, reason: reason)
  }
  let appID = window.appID.lowercased()
  guard windowLayerIsEligible(window.layer, role: window.role, subrole: window.subrole,
    allowsConfiguredNonzeroLayer: rule != nil)
  else { return outcome(.ignored, "window-layer:\(window.layer)") }
  switch rule {
  case .forceTiled: return outcome(.tiled, "rule:force-tiled")
  case .forceFloating: return outcome(.floating, "rule:force-floating")
  case nil: break
  }
  if window.subrole == kAXDialogSubrole,
    isSystemTextAccessory(title: window.title, hasCloseButton: window.closeButton != nil, isModal: window.modal)
  {
    return outcome(.ignored, "text-accessory")
  }
  if ignoredWindowApplicationIDs.contains(appID) { return outcome(.ignored, applicationPolicyIgnoreReason) }
  if window.role == kAXSheetRole { return outcome(.floating, "sheet") }
  guard let role = window.role else { return outcome(.unavailable, "role-unavailable") }
  guard role == kAXWindowRole else { return outcome(.ignored, "unsupported-role:\(role)") }
  // Only standard windows and app-drawn popups are read for modality.
  if window.modal,
    window.subrole == kAXStandardWindowSubrole || isAppDrawnPopup(subrole: window.subrole, isModal: false)
  {
    return outcome(.floating, "modal")
  }
  if automaticFloatingWindowApplicationIDs.contains(appID) { return outcome(.floating, "floating-application") }
  guard let subrole = window.subrole else { return outcome(.unavailable, "subrole-unavailable") }
  if isAppDrawnPopup(subrole: subrole, isModal: false) { return outcome(.ignored, "app-drawn-popup") }
  if subrole == kAXStandardWindowSubrole {
    guard window.closeButton != nil else { return outcome(.floating, "no-close-button") }
    guard window.resizable else { return outcome(.floating, "fixed-size") }
    // A window without an enabled full-screen or zoom button is not designed to be big, such as Finder copy progress.
    guard window.fullScreenButton == true || window.zoomButton == true else { return outcome(.floating, "cannot-grow") }
    return outcome(.tiled, "standard-window")
  }
  if automaticFloatingWindowSubroles.contains(subrole) { return outcome(.floating, "floating-subrole:\(subrole)") }
  return outcome(.ignored, "unsupported-subrole:\(subrole)")
}

extension RuleDecision {
  var window: RuleWindow? {
    if forceTiling { return .forceTiled }
    return floating ? .forceFloating : nil
  }
}

@MainActor
extension MacOSPlatform {
  /// The focused window's classification inputs and outcome, as fixture JSON.
  public func inspectFocusedWindow(config: Config) -> String? {
    guard let application = NSWorkspace.shared.frontmostApplication,
      let element = applicationFocusedWindow(application.processIdentifier)
    else { return nil }
    AXUIElementSetMessagingTimeout(element, Float(accessibilityReadTimeoutSeconds))
    func read(_ attribute: String) -> CFTypeRef? {
      var value: CFTypeRef?
      AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
      return value
    }
    var sizeSettable = DarwinBoolean(false)
    let sizeSettableError = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &sizeSettable)
    let input = WindowClassificationInput(
      appID: fallbackApplicationIdentity(bundleIdentifier: application.bundleIdentifier,
        ownerName: application.localizedName, processID: application.processIdentifier),
      role: read(kAXRoleAttribute) as? String,
      subrole: read(kAXSubroleAttribute) as? String,
      title: read(kAXTitleAttribute) as? String ?? "",
      identifier: read(kAXIdentifierAttribute) as? String,
      closeButton: windowButtonState(element, kAXCloseButtonAttribute),
      zoomButton: windowButtonState(element, kAXZoomButtonAttribute),
      fullScreenButton: windowButtonState(element, kAXFullScreenButtonAttribute),
      resizable: windowCanResize(sizeSettableError: sizeSettableError, isSettable: sizeSettable.boolValue),
      modal: read(kAXModalAttribute) as? Bool ?? false,
      layer: windowIDProvider.windowID(for: element)
        .flatMap { ribbonProxyWindowDescriptions([$0]).first?[kCGWindowLayer as String] as? Int } ?? 0
    )
    let rule = config.decision(appID: input.appID, title: input.title, role: input.role).window
    let classification = classifyWindow(input, rule: rule)
    let report = WindowClassificationReport(
      rule: rule, window: input, disposition: classification.disposition, reason: classification.reason)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(report)).map { String(decoding: $0, as: UTF8.self) }
  }
}
