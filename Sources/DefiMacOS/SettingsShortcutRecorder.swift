import AppKit
import DefiConfig
import SwiftUI
import Synchronization

/// Without a layout, uses the same physical key codes as the global hotkey engine. With one, records
/// the first name that resolves back to the pressed chord on that layout: a digit or arrow by name,
/// else the key's character, else its table name.
func recordedAccelerator(
  keyCode: UInt16, modifiers: NSEvent.ModifierFlags, layout: KeyboardLayout? = nil
) -> String? {
  guard !modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
  let physical = acceleratorKeyCodes.first(where: { $0.value == keyCode })?.key
  var names = [physical].compactMap { $0 }
  if let layout {
    let character = layout.baseCharacter(code: keyCode, command: modifiers.contains(.command))
      .map(canonicalKeyName)
    let pinned = physical.map { Int($0) != nil || keyCode >= 123 } ?? false
    names = pinned ? names : [character].compactMap { $0 } + names
  }
  var parts: [String] = []
  if modifiers.contains(.control) { parts.append("ctrl") }
  if modifiers.contains(.option) { parts.append("alt") }
  if modifiers.contains(.shift) { parts.append("shift") }
  if modifiers.contains(.command) { parts.append("cmd") }
  for name in names {
    guard let accelerator = normalizedAccelerator((parts + [name]).joined(separator: "-"), aliases: [:])
    else { continue }
    guard let layout else { return accelerator }
    guard let modifiers = try? parseAccelerator(accelerator, aliases: [:]).modifiers,
      let alone = try? resolveHotKeys([accelerator: ""], aliases: [:], layout: layout)
    else { continue }
    if alone.keys[Key(code: keyCode, flags: modifiers.rawValue)] != nil { return accelerator }
  }
  return nil
}

struct SettingsShortcutRecorder: NSViewRepresentable {
  let label: String
  let command: String
  let onRecord: (String) -> Void

  func makeNSView(context: Context) -> ShortcutRecorderButton {
    ShortcutRecorderButton()
  }

  func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
    button.shortcutLabel = label
    button.onRecord = onRecord
    button.setAccessibilityLabel("Record shortcut for \(command)")
    button.refreshTitle()
  }

  static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) {
    button.stopRecording()
  }
}

final class ShortcutRecorderButton: NSButton {
  nonisolated static let captureHandler = Mutex<(@Sendable (UInt16, UInt64, Bool) -> Void)?>(nil)
  nonisolated static var capturesKeyboard: Bool { captureHandler.withLock { $0 != nil } }
  private var recordingID: UUID?
  private var keyMonitor: Any?
  var shortcutLabel = ""
  var onRecord: ((String) -> Void)?
  private(set) var isRecording = false

  init() {
    super.init(frame: .zero)
    bezelStyle = .rounded
    setButtonType(.momentaryPushIn)
    font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    target = self
    action = #selector(startRecording)
    toolTip = "Click to record a shortcut. Escape cancels."
  }

  required init?(coder: NSCoder) { nil }

  override var acceptsFirstResponder: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self)
    if let window {
      NotificationCenter.default.addObserver(
        self, selector: #selector(stopRecording),
        name: NSWindow.didResignKeyNotification, object: window
      )
      NotificationCenter.default.addObserver(
        self, selector: #selector(stopRecording),
        name: NSWindow.willCloseNotification, object: window
      )
    } else {
      stopRecording()
    }
  }

  @objc private func startRecording() {
    guard window?.makeFirstResponder(self) == true else { return }
    if isRecording {
      stopRecording()
      return
    }
    isRecording = true
    let recordingID = UUID()
    self.recordingID = recordingID
    Self.captureHandler.withLock { handler in
      handler = { [weak self] keyCode, modifierBits, isRepeat in
        Task { @MainActor [weak self] in
          guard let self, self.recordingID == recordingID else { return }
          self.record(
            keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifierBits)),
            isRepeat: isRepeat)
        }
      }
    }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.isRecording, event.window === self.window else { return event }
      self.keyDown(with: event)
      return nil
    }
    refreshTitle()
  }

  @objc func stopRecording() {
    guard isRecording else { return }
    isRecording = false
    recordingID = nil
    Self.captureHandler.withLock { $0 = nil }
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }
    refreshTitle()
  }

  func refreshTitle() {
    title = isRecording ? "Press shortcut…" : shortcutLabel
    setAccessibilityValue(title)
  }

  override func resignFirstResponder() -> Bool {
    stopRecording()
    return super.resignFirstResponder()
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard isRecording, window?.isKeyWindow == true, window?.firstResponder === self else {
      return super.performKeyEquivalent(with: event)
    }
    keyDown(with: event)
    return true
  }

  override func keyDown(with event: NSEvent) {
    guard isRecording else {
      super.keyDown(with: event)
      return
    }
    record(keyCode: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat)
  }

  private func record(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool) {
    guard isRecording, !isRepeat else { return }
    if keyCode == 53 {
      stopRecording()
      return
    }
    guard
      let accelerator = recordedAccelerator(
        keyCode: keyCode, modifiers: modifiers, layout: currentKeyboardLayout()
      )
    else {
      title = "Use ⌃, ⌥ or ⌘ + key"
      setAccessibilityValue(title)
      NSSound.beep()
      return
    }
    stopRecording()
    onRecord?(accelerator)
  }
}
