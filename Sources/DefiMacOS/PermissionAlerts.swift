import AppKit

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

/// macOS shows its prompt only while the decision is undetermined, so later launches stay silent.
public func requestDefiScreenRecordingIfNeeded() {
  guard Bundle.main.bundleURL.pathExtension == "app", !CGPreflightScreenCaptureAccess() else { return }
  _ = CGRequestScreenCaptureAccess()
}

@MainActor
public func openDefiAccessibilitySettings() {
  openDefiPrivacySettings("Privacy_Accessibility")
}

@MainActor
public func openDefiScreenRecordingSettings() {
  openDefiPrivacySettings("Privacy_ScreenCapture")
}

@MainActor
private func openDefiPrivacySettings(_ pane: String) {
  guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
  else { return }
  NSWorkspace.shared.open(url)
}

/// Whether macOS tiles a window dragged to a screen's side edge or to the menu bar, the places
/// where Defi's title-bar drag scrolls the strip or targets a column's top.
public func systemWindowTilingByEdgeDrag() -> (sides: Bool, top: Bool) {
  let domain = "com.apple.WindowManager" as CFString
  // Drops this process's cached copy, so a change in System Settings shows up.
  CFPreferencesAppSynchronize(domain)
  // A key never written keeps macOS's default: on.
  func enabled(_ key: String) -> Bool { CFPreferencesCopyAppValue(key as CFString, domain) as? Bool ?? true }
  return (enabled("EnableTilingByEdgeDrag"), enabled("EnableTopTilingByEdgeDrag"))
}

@MainActor
public func presentMacOSTilingNotice() {
  let alert = NSAlert()
  alert.messageText = "macOS Tiled This Window Too"
  alert.informativeText = "macOS also tiles a window you drag to a screen edge or the menu bar, so it resized "
    + "this one before Defi moved it where you dropped it. Turn off its tiling in Desktop & Dock to drag "
    + "there smoothly. Defi will not show this again; Settings › Input keeps a reminder while it is on."
  alert.addButton(withTitle: "Open Desktop & Dock")
  alert.addButton(withTitle: "Not Now")
  NSApplication.shared.activate(ignoringOtherApps: true)
  if alert.runModal() == .alertFirstButtonReturn { openDesktopAndDockSettings() }
}

@MainActor
public func openDesktopAndDockSettings() {
  NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
}

/// SwiftUI ignores `showSettingsWindow:` from code, so this triggers the app menu's ⌘, item that the
/// `Settings` scene installs, which also works while the menu bar item is hidden.
@MainActor
public func openDefiSettings() {
  guard let menu = NSApp.mainMenu?.items.first?.submenu,
    let index = menu.items.firstIndex(where: {
      $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
    })
  else { return }
  NSApp.activate(ignoringOtherApps: true)
  menu.performActionForItem(at: index)
}
