import ApplicationServices
import Foundation

/// AppKit answers Accessibility on Defi's own windows (the tiled Settings window) on the
/// calling thread, and moving an NSWindow off the main thread traps. Such writes hop to
/// main, bounded so a main thread waiting on a write queue never deadlocks; a write that
/// has not started by then is dropped, one already running may still land.
func performAccessibilityWrite(on element: AXUIElement, _ write: @escaping () -> AXError) -> AXError {
  var processID: pid_t = 0
  guard !Thread.isMainThread, AXUIElementGetPid(element, &processID) == .success,
    processID == ProcessInfo.processInfo.processIdentifier
  else { return write() }
  let pending = PendingOwnWindowWrite(write)
  DispatchQueue.main.async { pending.run() }
  return pending.wait(timeout: 0.25)
}

private final class PendingOwnWindowWrite: @unchecked Sendable {
  private let write: () -> AXError
  private let done = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var abandoned = false
  private var result = AXError.cannotComplete

  init(_ write: @escaping () -> AXError) { self.write = write }

  func run() {
    guard !lock.withLock({ abandoned }) else { return }
    result = write()
    done.signal()
  }

  func wait(timeout: TimeInterval) -> AXError {
    guard done.wait(timeout: .now() + timeout) == .success else {
      lock.withLock { abandoned = true }
      return .cannotComplete
    }
    return result
  }
}
