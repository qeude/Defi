import AppKit
import ApplicationServices

private struct FixtureCommand: Decodable, Sendable {
  let seq: Int
  let command: String
  let id: String?
  let delay: Double?
}

@MainActor
private final class InputEditor: NSTextView {
  var received: ((NSEvent) -> Void)?
  override func keyDown(with event: NSEvent) {
    received?(event)
    super.keyDown(with: event)
  }
}

@MainActor
private final class InputView: NSTextField {
  let editor = InputEditor(frame: .zero)
}

@MainActor
private final class PerformanceFixtureDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var windows: [String: NSWindow] = [:]
  private var used: Set<String> = []
  private var completed = 0, errors = 0, keyChanges = 0, pending = 0
  private var delay = 0.0
  private var events: [[String: Any]] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    DispatchQueue.global().async { [self] in
      while let line = readLine() {
        let data = Data(line.utf8)
        DispatchQueue.main.async { [self] in
          do { try handle(JSONDecoder().decode(FixtureCommand.self, from: data)) }
          catch { errors += 1; report(seq: -1, error: String(describing: error)) }
        }
      }
      DispatchQueue.main.async { [self] in quit() }
    }
  }

  private func keyChanged(_ notification: Notification, key: Bool) {
    keyChanges += 1
    let id = windows.first { $0.value === notification.object as? NSWindow }?.key ?? "closed"
    events.append(["kind": "key", "id": id, "key": key, "at": ProcessInfo.processInfo.systemUptime])
  }
  func windowDidBecomeKey(_ notification: Notification) { keyChanged(notification, key: true) }
  func windowDidResignKey(_ notification: Notification) { keyChanged(notification, key: false) }
  func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
    (client as? InputView)?.editor
  }
  func windowWillClose(_ notification: Notification) {
    if let window = notification.object as? NSWindow {
      windows = windows.filter { $0.value !== window }
    }
  }

  @objc private func clicked(_ sender: NSButton) {
    events.append(["kind": "button", "id": sender.identifier?.rawValue ?? "", "at": ProcessInfo.processInfo.systemUptime])
  }

  private func create(_ id: String) {
    let window = NSWindow(contentRect: NSRect(x: 120, y: 160, width: 640, height: 440),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "Defi Performance \(getpid()) \(id)"
    window.isReleasedWhenClosed = false
    window.delegate = self
    let input = InputView(string: "Type here to verify the keyboard recipient")
    input.frame = NSRect(x: 24, y: 24, width: 540, height: 28)
    input.setAccessibilityLabel("Performance input \(id)")
    input.editor.isFieldEditor = true
    input.editor.received = { [weak self] event in
      self?.events.append(["kind": "keyboard", "id": id, "keyCode": event.keyCode,
                           "characters": event.characters ?? "", "at": event.timestamp])
    }
    let button = NSButton(title: "Record click", target: self, action: #selector(clicked(_:)))
    button.identifier = NSUserInterfaceItemIdentifier(id)
    button.frame = NSRect(x: 24, y: 72, width: 160, height: 32)
    window.contentView?.addSubview(input)
    window.contentView?.addSubview(button)
    windows[id] = window
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(input)
    NSApplication.shared.activate()
    completed += 1
  }

  private func nativeFocus() -> [String: Any] {
    var result: [String: Any] = ["available": false,
      "pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1]
    guard AXIsProcessTrusted(), let pid = result["pid"] as? pid_t else { return result }
    let app = AXUIElementCreateApplication(pid)
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &raw) == .success,
      let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return result }
    let window = unsafeBitCast(raw, to: AXUIElement.self)
    var position: CFTypeRef?, size: CFTypeRef?, title: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
      AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
      let position, let size, CFGetTypeID(position) == AXValueGetTypeID(),
      CFGetTypeID(size) == AXValueGetTypeID() else { return result }
    var point = CGPoint.zero, dimensions = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
      AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return result }
    _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
    result["available"] = true
    result["title"] = title as? String ?? ""
    result["frame"] = [point.x, point.y, dimensions.width, dimensions.height]
    return result
  }

  private func report(seq: Int, error: String? = nil, includeNativeFocus: Bool = false) {
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    let rows = windows.sorted { $0.key < $1.key }.map { id, window -> [String: Any] in
      let frame = window.frame
      return ["id": id, "windowNumber": window.windowNumber, "key": window.isKeyWindow,
              "frame": [frame.minX, top - frame.maxY, frame.width, frame.height]]
    }
    var value: [String: Any] = ["seq": seq, "pid": getpid(), "at": ProcessInfo.processInfo.systemUptime,
      "completed": completed, "errors": errors, "pending": pending, "keyChanges": keyChanges,
      "windows": rows, "events": events, "error": error ?? "", "active": NSApplication.shared.isActive,
      "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1]
    if includeNativeFocus { value["nativeFocus"] = nativeFocus() }
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
      FileHandle.standardOutput.write(data + Data([10]))
    }
  }

  private func handle(_ value: FixtureCommand) throws {
    let duration = value.delay ?? 0
    guard value.seq > 0, duration.isFinite,
      duration >= 0, duration <= 2 else { throw NSError(domain: "Invalid command", code: 1) }
    switch value.command {
    case "create", "delayed-create":
      guard let id = value.id, !id.isEmpty, id.count <= 80, used.insert(id).inserted else {
        throw NSError(domain: "Invalid or reused window ID", code: 2)
      }
      if value.command == "create" { create(id) }
      else {
        pending += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [self] in
          pending -= 1
          create(id)
        }
      }
    case "close":
      guard let id = value.id, let window = windows[id] else { throw NSError(domain: "Unknown ID", code: 3) }
      window.close()
      completed += 1
    case "set-delay": delay = duration; completed += 1
    case "report": break
    case "native-focus": report(seq: value.seq, includeNativeFocus: true); return
    case "quit": report(seq: value.seq); quit(); return
    default: throw NSError(domain: "Unknown command", code: 4)
    }
    report(seq: value.seq)
    if delay > 0 { Thread.sleep(forTimeInterval: delay) }
  }

  private func quit() {
    for window in Array(windows.values) { window.close() }
    NSApplication.shared.terminate(nil)
  }
}

@main
private struct PerformanceFixture {
  @MainActor static func main() {
    let application = NSApplication.shared
    let delegate = PerformanceFixtureDelegate()
    application.setActivationPolicy(.regular)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
  }
}
