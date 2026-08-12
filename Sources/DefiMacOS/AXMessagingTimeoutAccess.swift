import ApplicationServices
import Foundation

final class AXMessagingTimeoutAccess: @unchecked Sendable {
  static let shared = AXMessagingTimeoutAccess()

  private struct LockEntry {
    let lock: NSRecursiveLock
    var users: Int
  }

  private let registryLock = NSLock()
  private var entries: [UInt: LockEntry] = [:]

  func withTimeout<Result>(
    _ timeout: Float,
    elements: [AXUIElement],
    perform: () throws -> Result
  ) rethrows -> Result {
    let locks = acquireLocks(for: elements)
    defer { releaseLocks(locks) }
    for element in elements {
      AXUIElementSetMessagingTimeout(element, timeout)
    }
    defer {
      for element in elements.reversed() {
        AXUIElementSetMessagingTimeout(element, 0)
      }
    }
    return try perform()
  }

  private func acquireLocks(
    for elements: [AXUIElement]
  ) -> [(key: UInt, lock: NSRecursiveLock)] {
    let keys = Set(elements.map(elementIdentity)).sorted()
    registryLock.lock()
    let locks = keys.map { key in
      if var entry = entries[key] {
        entry.users += 1
        entries[key] = entry
        return (key: key, lock: entry.lock)
      }
      let entry = LockEntry(lock: NSRecursiveLock(), users: 1)
      entries[key] = entry
      return (key: key, lock: entry.lock)
    }
    registryLock.unlock()
    for item in locks {
      item.lock.lock()
    }
    return locks
  }

  private func releaseLocks(
    _ locks: [(key: UInt, lock: NSRecursiveLock)]
  ) {
    for item in locks.reversed() {
      item.lock.unlock()
    }
    registryLock.lock()
    for item in locks {
      guard var entry = entries[item.key] else { continue }
      entry.users -= 1
      if entry.users == 0 {
        entries[item.key] = nil
      } else {
        entries[item.key] = entry
      }
    }
    registryLock.unlock()
  }

  private func elementIdentity(_ element: AXUIElement) -> UInt {
    UInt(bitPattern: Unmanaged.passUnretained(element).toOpaque())
  }
}
