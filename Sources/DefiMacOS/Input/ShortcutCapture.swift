import Synchronization

/// Bridges the shortcut recorder's key monitor to the platform's hotkey tap.
enum ShortcutCapture {
  nonisolated static let captureHandler = Mutex<(@Sendable (UInt16, UInt64, Bool) -> Void)?>(nil)
  nonisolated static var capturesKeyboard: Bool { captureHandler.withLock { $0 != nil } }
}
