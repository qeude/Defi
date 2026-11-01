import Carbon
import Foundation
import Synchronization

/// The keyboard type of the last real key the input tap saw, 0 until then. The tap writes an integer
/// here and never calls TIS; with several keyboards attached it is the one in use.
let observedKeyboardType = Mutex<UInt32>(0)

/// The ASCII-capable layout rather than the selected source, so Romaji and kana keep the layout
/// that shortcuts use. Main thread only: TIS is not safe on the tap thread or the navigation actor.
@MainActor
func currentKeyboardLayout() -> KeyboardLayout? {
  guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
  let observed = observedKeyboardType.withLock { $0 }
  return keyboardLayout(of: source, keyboardType: observed != 0 ? observed : UInt32(LMGetKbdType()))
}

/// Reads an installed layout without selecting it.
@MainActor
func keyboardLayout(inputSourceID: String, keyboardType: UInt32) -> KeyboardLayout? {
  let sources = TISCreateInputSourceList([kTISPropertyInputSourceID as String: inputSourceID] as CFDictionary, true)?
    .takeRetainedValue() as? [TISInputSource]
  return sources?.first.flatMap { keyboardLayout(of: $0, keyboardType: keyboardType) }
}

@MainActor
private func keyboardLayout(of source: TISInputSource, keyboardType: UInt32) -> KeyboardLayout? {
  guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
  let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
  return CFDataGetBytePtr(data).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
    var characters: [KeyboardLayer: [UInt16: String]] = [:]
    for bits in 0..<8 {
      let layer = KeyboardLayer(rawValue: bits)
      var modifiers = 0
      if layer.contains(.shift) { modifiers |= shiftKey }
      if layer.contains(.option) { modifiers |= optionKey }
      if layer.contains(.command) { modifiers |= cmdKey }
      for code in layoutScannedKeyCodes where keyExists(code, keyboardType) {
        if let character = printedCharacter(layout, code, modifiers: UInt32(modifiers >> 8), keyboardType) {
          characters[layer, default: [:]][code] = character
        }
      }
    }
    return KeyboardLayout(characters: characters)
  }
}

/// UCKeyTranslate prints for the ISO-only key (10) and the JIS-only keys (93, 94) on every keyboard
/// type; a shortcut on a key the hardware lacks could never be pressed.
private func keyExists(_ code: UInt16, _ keyboardType: UInt32) -> Bool {
  let type = KBGetLayoutType(Int16(truncatingIfNeeded: keyboardType))
  return switch code {
  case 10: type != OSType(kKeyboardANSI) && type != OSType(kKeyboardJIS)
  case 93, 94: type != OSType(kKeyboardANSI) && type != OSType(kKeyboardISO)
  default: true
  }
}

private func printedCharacter(
  _ layout: UnsafePointer<UCKeyboardLayout>, _ code: UInt16, modifiers: UInt32, _ keyboardType: UInt32
) -> String? {
  var deadKeyState: UInt32 = 0
  var buffer = [UniChar](repeating: 0, count: 4)
  var length = 0
  func translate(_ code: UInt16, _ modifiers: UInt32) -> Bool {
    UCKeyTranslate(
      layout, code, UInt16(kUCKeyActionDown), modifiers, keyboardType, 0, &deadKeyState,
      buffer.count, &length, &buffer) == noErr
  }
  guard translate(code, modifiers) else { return nil }
  // A dead key prints nothing until Space completes it; that spacing character is its keycap.
  if length == 0, deadKeyState != 0, !translate(49, 0) { return nil }
  let text = String(utf16CodeUnits: buffer, count: length)
  guard text.count == 1, let scalar = text.unicodeScalars.first, scalar.value >= 32, scalar.value != 127 else {
    return nil
  }
  return text.lowercased()
}

/// Calls `changed` when the selected input source changes, and again shortly after because the
/// notification can arrive before TIS reports the new source. Callers gate on equality.
/// The distributed centre delivers immediately even while the daemon is inactive.
@MainActor
final class KeyboardLayoutObserver {
  private let changed: @MainActor () -> Void

  init(_ changed: @escaping @MainActor () -> Void) {
    self.changed = changed
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDistributedCenter(), Unmanaged.passUnretained(self).toOpaque(),
      { _, observer, _, _, _ in
        guard let observer else { return }
        MainActor.assumeIsolated { Unmanaged<KeyboardLayoutObserver>.fromOpaque(observer).takeUnretainedValue().fire() }
      },
      kTISNotifySelectedKeyboardInputSourceChanged, nil, .deliverImmediately)
  }

  private func fire() {
    changed()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      MainActor.assumeIsolated { self?.changed() }
    }
  }

  isolated deinit {
    CFNotificationCenterRemoveEveryObserver(
      CFNotificationCenterGetDistributedCenter(), Unmanaged.passUnretained(self).toOpaque())
  }
}
