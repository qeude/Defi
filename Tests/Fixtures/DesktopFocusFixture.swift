import AppKit

@MainActor
private final class ExplicitAXRaiseWindow: NSWindow {
  override func accessibilityPerformRaise() -> Bool {
    orderFrontRegardless()
    return true
  }
}

@MainActor
private final class DesktopFocusFixtureDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let window = ExplicitAXRaiseWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false
    )
    window.title = CommandLine.arguments[1]
    window.isReleasedWhenClosed = false
    window.level = .normal
    window.hidesOnDeactivate = false
    let textField = NSTextField(string: "Editable native focus fixture")
    textField.frame = NSRect(x: 24, y: 24, width: 560, height: 28)
    window.contentView?.addSubview(textField)
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(textField)
    self.window = window
    NSApplication.shared.activate()

    DispatchQueue.global().async {
      _ = FileHandle.standardInput.readDataToEndOfFile()
      DispatchQueue.main.async {
        window.close()
        NSApplication.shared.terminate(nil)
      }
    }
  }
}

@main
private struct DesktopFocusFixture {
  @MainActor static func main() {
    guard CommandLine.arguments.count == 2 else { exit(2) }
    let application = NSApplication.shared
    let delegate = DesktopFocusFixtureDelegate()
    application.setActivationPolicy(.regular)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
  }
}
