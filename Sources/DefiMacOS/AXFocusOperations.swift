import AppKit
import ApplicationServices

struct AXFocusOperations: @unchecked Sendable {
  var targetIsFocused: (AXUIElement, AXUIElement) -> Bool = { element, application in
    AXMessagingTimeoutAccess.shared.withTimeout(0.016, elements: [application, element]) {
      // Main-window state alone does not establish the keyboard recipient.
      targetWindowFocusIsConfirmed(readFocused(element)) {
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
          application, kAXFocusedWindowAttribute as CFString, &focusedWindow
        ) == .success, let focusedWindow,
          CFGetTypeID(focusedWindow) == AXUIElementGetTypeID()
        else { return false }
        return CFEqual(focusedWindow, element)
      }
    }
  }
  var setMain: (AXUIElement) -> AXError = {
    AXUIElementSetAttributeValue($0, kAXMainAttribute as CFString, kCFBooleanTrue)
  }
  var raise: (AXUIElement) -> AXError = {
    AXUIElementPerformAction($0, kAXRaiseAction as CFString)
  }
  var applicationIsActive: (pid_t) -> Bool = {
    NSRunningApplication(processIdentifier: $0)?.isActive == true
  }
  var prepareActivation: () -> (AXUIElement) -> AXError = {
    let system = AXUIElementCreateSystemWide()
    return {
      AXUIElementSetAttributeValue(system, kAXFocusedApplicationAttribute as CFString, $0)
    }
  }
  var activateApplication: (pid_t) -> Bool = {
    NSRunningApplication(processIdentifier: $0)?.activate() == true
  }
  var withTimeout: (Float, [AXUIElement], () -> Void) -> Void = { timeout, elements, perform in
    AXMessagingTimeoutAccess.shared.withTimeout(timeout, elements: elements, perform: perform)
  }

  private static func readFocused(_ element: AXUIElement) -> Bool? {
    var rawValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element, kAXFocusedAttribute as CFString, &rawValue
    ) == .success, let rawValue, CFGetTypeID(rawValue) == CFBooleanGetTypeID()
    else { return nil }
    return CFBooleanGetValue(rawValue as! CFBoolean)
  }
}
