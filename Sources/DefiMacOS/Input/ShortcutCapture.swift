import Synchronization

/// Bridges the shortcut recorder's key monitor to the platform's hotkey tap.
package enum ShortcutCapture {
  nonisolated static package let captureHandler = Mutex<(@Sendable (UInt16, UInt64, Bool) -> Void)?>(nil)
  nonisolated static package var capturesKeyboard: Bool { captureHandler.withLock { $0 != nil } }
}
