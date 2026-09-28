import AppKit
import DefiConfig
import SwiftUI
import Synchronization

/// Uses the same physical key codes as the global hotkey engine.
func recordedAccelerator(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
  guard !modifiers.intersection([.command, .control, .option]).isEmpty,
    let key = acceleratorKeyCodes.first(where: { $0.value == keyCode })?.key
  else { return nil }
  var parts: [String] = []
  if modifiers.contains(.control) { parts.append("ctrl") }
  if modifiers.contains(.option) { parts.append("alt") }
  if modifiers.contains(.shift) { parts.append("shift") }
  if modifiers.contains(.command) { parts.append("cmd") }
  return normalizedAccelerator((parts + [key]).joined(separator: "-"), aliases: [:])
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
        keyCode: keyCode, modifiers: modifiers
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
