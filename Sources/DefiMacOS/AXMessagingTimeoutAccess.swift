import ApplicationServices
import Foundation

final class AXMessagingTimeoutAccess: @unchecked Sendable {
  static let shared = AXMessagingTimeoutAccess()

  private struct LockEntry {
    let lock: NSRecursiveLock
    var users: Int
  }

  private struct LockAcquisition {
    let locks: [(key: UInt, lock: NSRecursiveLock)]
    let ownedKeys: Set<UInt>
  }

  private let registryLock = NSLock()
  private var entries: [UInt: LockEntry] = [:]

  func withTimeout<Result>(
    _ timeout: Float,
    elements: [AXUIElement],
    perform: () throws -> Result
  ) rethrows -> Result {
    let acquisition = acquireLocks(for: elements)
    defer {
      releaseLocks(acquisition, elements: elements)
    }
    // Keep each operation bounded even when another caller owns one of the
    // shared elements. Timeout writes are cheap and the reset is deferred
    // until the last user releases the entry.
    for element in elements {
      AXUIElementSetMessagingTimeout(element, timeout)
    }
    return try perform()
  }

  private func acquireLocks(
    for elements: [AXUIElement]
  ) -> LockAcquisition {
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
    var ownedKeys = Set<UInt>()
    for item in locks {
      if item.lock.try() {
        ownedKeys.insert(item.key)
      }
    }
    return LockAcquisition(locks: locks, ownedKeys: ownedKeys)
  }

  private func releaseLocks(
    _ acquisition: LockAcquisition,
    elements: [AXUIElement]
  ) {
    var elementsByKey: [UInt: AXUIElement] = [:]
    for element in elements {
      elementsByKey[elementIdentity(element)] = element
    }
    registryLock.lock()
    for item in acquisition.locks {
      guard var entry = entries[item.key] else { continue }
      entry.users -= 1
      if entry.users == 0 {
        if !acquisition.ownedKeys.contains(item.key), !item.lock.try() {
          entry.users = 1
          entries[item.key] = entry
          continue
        }
        if let element = elementsByKey[item.key] {
          AXUIElementSetMessagingTimeout(element, 0)
        }
        if !acquisition.ownedKeys.contains(item.key) {
          item.lock.unlock()
        }
        entries[item.key] = nil
      } else {
        entries[item.key] = entry
      }
    }
    registryLock.unlock()
    for item in acquisition.locks.reversed()
    where acquisition.ownedKeys.contains(item.key) {
      item.lock.unlock()
    }
  }

  private func elementIdentity(_ element: AXUIElement) -> UInt {
    UInt(bitPattern: Unmanaged.passUnretained(element).toOpaque())
  }
}
