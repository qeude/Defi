import AppKit

@MainActor
public func showAccessibilityOnboardingIfNeeded() {
  let defaults = UserDefaults.standard
  let key = "didShowAccessibilityOnboarding"
  guard defaults.bool(forKey: key) == false else { return }
  defaults.set(true, forKey: key)

  let alert = NSAlert()
  alert.alertStyle = .informational
  alert.messageText = "Allow Defi to Manage Windows"
  alert.informativeText =
    "Defi needs Accessibility permission to discover, focus, move, and resize windows."
  alert.addButton(withTitle: "Open Accessibility Settings")
  alert.addButton(withTitle: "Later")
  NSApplication.shared.activate(ignoringOtherApps: true)
  if alert.runModal() == .alertFirstButtonReturn {
    openDefiAccessibilitySettings()
  }
}

@MainActor
public func presentDefiStartupError(_ error: Error) {
  guard Bundle.main.bundleURL.pathExtension == "app" else { return }
  NSApplication.shared.setActivationPolicy(.accessory)
  NSApplication.shared.finishLaunching()
  presentDefiAlert(
    title: "Defi Could Not Start",
    message: String(describing: error),
  )
}

@MainActor
public func presentDefiConfigurationError(_ error: Error) {
  presentDefiAlert(
    title: "Defi Hotkeys Are Disabled",
    message: String(describing: error),
  )
}

@MainActor
func presentDefiAlert(title: String, message: String) {
  let alert = NSAlert()
  alert.alertStyle = .warning
  alert.messageText = title
  alert.informativeText = message
  alert.addButton(withTitle: "OK")
  NSApplication.shared.activate(ignoringOtherApps: true)
  alert.runModal()
}

@MainActor
func openDefiAccessibilitySettings() {
  guard let url = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
  ) else { return }
  NSWorkspace.shared.open(url)
}
