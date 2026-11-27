import AppKit
import DefiConfig
import SwiftUI
import DefiMacOS

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
    let pinned = physical.map { Int($0) != nil || acceleratorKeyKeepsName(keyCode) } ?? false
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

/// A shortcut pill that morphs into a tinted "Type keys…" capsule while it records, then settles on the
/// new keys. The AppKit recorder that captures the keys sits invisibly over it only while needed: the
/// Keyboard page lists one per action, and an AppKit view in every row made the page slow to open.
struct SettingsShortcutField: View {
  let label: String
  let command: String
  /// Keeps the recorder itself in place, for the action a search just revealed.
  var live = false
  /// The action has no shortcut yet; a quiet outline invites one instead of a full pill.
  var unset = false
  let onRecord: (String) -> Void
  @State private var recording = false
  /// Keys were pressed and saved; the capsule stays lit until the new label arrives, then folds onto it.
  @State private var saving = false
  /// The face the content currently shows; trails `face` by the fade-out, so old and new never overlap.
  @State private var shown: Face?
  @State private var contentVisible = true

  private static let morph = Animation.spring(duration: 0.5, bounce: 0.3)

  private enum Face: Hashable {
    case label(String), unset, recording, saved
  }

  private var face: Face { saving ? .saved : recording ? .recording : unset ? .unset : .label(label) }
  private var lit: Bool { recording || saving }

  var body: some View {
    Button { withAnimation(Self.morph) { recording = true } } label: { pill }
      .buttonStyle(.plain)
      .overlay {
        if live || recording {
          SettingsShortcutRecorder(
            label: label, command: command, startsRecording: recording, transparent: true,
            onRecord: { accelerator in
              withAnimation(Self.morph) { saving = true }
              onRecord(accelerator)
              // The label may not change, such as for the same keys; never stay lit.
              Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.9))
                if saving { withAnimation(Self.morph) { saving = false } }
              }
            },
            onStart: { Task { @MainActor in if !recording { withAnimation(Self.morph) { recording = true } } } },
            onStop: { Task { @MainActor in withAnimation(Self.morph) { recording = false } } })
        }
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
      .onChange(of: label) {
        if saving {
          Task { @MainActor in
            // Let "Saved" read for a moment before the capsule folds onto the new keys.
            try? await Task.sleep(for: .seconds(0.45))
            if saving { withAnimation(Self.morph) { saving = false } }
          }
        }
      }
      .animation(Self.morph, value: label)
      .accessibilityLabel("Record shortcut for \(command)")
      .accessibilityValue(recording ? "Recording" : label)
  }

  /// An invisible copy of the target content sizes the capsule, so its width springs to the new face at
  /// once, while the content it shows fades out and only then blooms in as the new face: the two never
  /// overlap.
  private var pill: some View {
    content(face)
      .hidden()
      .padding(.horizontal, lit ? 12 : 10)
      .padding(.vertical, 4)
      .overlay {
        content(shown ?? face)
          .fixedSize()
          .opacity(contentVisible ? 1 : 0)
          .blur(radius: contentVisible ? 0 : 3)
          .scaleEffect(contentVisible ? 1 : 0.85)
      }
      .background { ShortcutCapsule(lit: lit, unset: unset && !lit) }
      .clipShape(Capsule())
      .scaleEffect(lit ? 1.05 : 1)
      .contentShape(Capsule())
      .onChange(of: face) { old, _ in
        if shown == nil { shown = old }
        withAnimation(.easeOut(duration: 0.1)) {
          contentVisible = false
        } completion: {
          shown = face
          withAnimation(.spring(duration: 0.3, bounce: 0.2)) { contentVisible = true }
        }
      }
  }

  private func content(_ face: Face) -> some View {
    HStack(spacing: 5) {
      switch face {
      case .recording:
        Image(systemName: "keyboard").symbolEffect(.pulse, options: .repeating)
        Text("Type keys…")
      case .saved:
        Image(systemName: "checkmark")
        Text("Saved")
      case .unset:
        Text("Add")
      case .label(let label):
        Text(label).font(.system(size: NSFont.systemFontSize, weight: .medium, design: .monospaced))
      }
    }
    .font(.callout.weight(face == .recording || face == .saved ? .semibold : .regular))
    .lineLimit(1)
    .foregroundStyle(face == .recording || face == .saved ? AnyShapeStyle(.white)
      : face == .unset ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
  }
}

/// One capsule for every state, so recording morphs its fill and outline instead of swapping views:
/// an accent fill with a glassy sheen while lit, a quiet fill for a shortcut, a dashed outline when there
/// is none. Plain fills keep a page with a pill per action cheap to scroll.
private struct ShortcutCapsule: View {
  let lit: Bool
  let unset: Bool

  var body: some View {
    Capsule()
      .fill(lit ? Color.accentColor : unset ? Color.accentColor.opacity(0) : Color.primary.opacity(0.1))
      .overlay {
        if lit {
          Capsule().fill(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0)],
            startPoint: .top, endPoint: .center))
            .transition(.opacity)
        }
      }
      .overlay {
        if unset {
          Capsule().strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            .transition(.opacity)
        }
      }
  }
}

struct SettingsShortcutRecorder: NSViewRepresentable {
  let label: String
  let command: String
  var startsRecording = false
  /// Draws nothing, for a SwiftUI pill that shows the state itself.
  var transparent = false
  let onRecord: (String) -> Void
  var onStart: (() -> Void)?
  var onStop: (() -> Void)?

  func makeNSView(context: Context) -> ShortcutRecorderButton {
    let button = ShortcutRecorderButton()
    button.drawsNothing = transparent
    if startsRecording {
      DispatchQueue.main.async { button.beginRecording() }
    }
    return button
  }

  func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
    button.shortcutLabel = label
    button.onRecord = onRecord
    button.onStart = onStart
    button.onStop = onStop
    button.setAccessibilityLabel("Record shortcut for \(command)")
    button.refreshTitle()
  }

  static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) {
    button.stopRecording()
  }
}

final class ShortcutRecorderButton: NSButton {
  private var recordingID: UUID?
  private var keyMonitor: Any?
  var shortcutLabel = ""
  var onRecord: ((String) -> Void)?
  var onStart: (() -> Void)?
  var onStop: (() -> Void)?
  private(set) var isRecording = false
  /// Draws nothing; a SwiftUI view underneath shows the shortcut and the recording state.
  var drawsNothing = false {
    didSet {
      isBordered = !drawsNothing
      refreshTitle()
    }
  }

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

  func beginRecording() {
    if !isRecording { startRecording() }
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
    ShortcutCapture.captureHandler.withLock { handler in
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
    onStart?()
  }

  @objc func stopRecording() {
    guard isRecording else { return }
    isRecording = false
    recordingID = nil
    ShortcutCapture.captureHandler.withLock { $0 = nil }
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }
    refreshTitle()
    onStop?()
  }

  func refreshTitle() {
    let text = isRecording ? "Press shortcut…" : shortcutLabel
    title = drawsNothing ? "" : text
    setAccessibilityValue(text)
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
      setAccessibilityValue("Use ⌃, ⌥ or ⌘ + key")
      if !drawsNothing { title = "Use ⌃, ⌥ or ⌘ + key" }
      NSSound.beep()
      return
    }
    stopRecording()
    onRecord?(accelerator)
  }
}
