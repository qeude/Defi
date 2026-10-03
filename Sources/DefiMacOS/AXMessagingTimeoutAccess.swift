import ApplicationServices
import Foundation

final class AXMessagingTimeoutAccess: @unchecked Sendable {
  static let shared = AXMessagingTimeoutAccess()

  private struct LockEntry {
    let lock: NSRecursiveLock
    var users: Int
    var ownerThread: ObjectIdentifier?
    var ownerDepth: Int
    var resetting = false
  }

  private struct LockAcquisition {
    let locks: [(key: UInt, lock: NSRecursiveLock)]
    let ownedKeys: Set<UInt>
  }

  private let timeoutSetter: (AXUIElement, Float) -> Void

  init(timeoutSetter: @escaping (AXUIElement, Float) -> Void = { element, timeout in
    AXUIElementSetMessagingTimeout(element, timeout)
  }) {
    self.timeoutSetter = timeoutSetter
  }

  private let registryLock = NSCondition()
  private var entries: [UInt: LockEntry] = [:]

  func withTimeout<Result>(
    _ timeout: Float,
    elements: [AXUIElement],
    observeWait: ((TimeInterval) -> Void)? = nil,
    perform: () throws -> Result
  ) rethrows -> Result {
    let waitingSince = observeWait.map { _ in ProcessInfo.processInfo.systemUptime }
    let acquisition = acquireLocks(for: elements)
    if let waitingSince { observeWait?(ProcessInfo.processInfo.systemUptime - waitingSince) }
    defer {
      releaseLocks(acquisition, elements: elements)
    }
    // A contended element keeps the owner's finite timeout until the final
    // user releases it; only its owner may mutate that timeout.
    for element in elements
    where acquisition.ownedKeys.contains(elementIdentity(element)) {
      timeoutSetter(element, timeout)
    }
    return try perform()
  }

  private func acquireLocks(
    for elements: [AXUIElement]
  ) -> LockAcquisition {
    let keys = Set(elements.map(elementIdentity)).sorted()
    let currentThread = ObjectIdentifier(Thread.current)
    registryLock.lock()
    // A reset blocks only new users of those elements, never unrelated apps.
    while keys.contains(where: { entries[$0]?.resetting == true }) {
      registryLock.wait()
    }
    let lockCandidates = keys.map { key in
      if var entry = entries[key] {
        entry.users += 1
        let isRecursiveOwner = entry.ownerThread == currentThread
          && entry.ownerDepth > 0
        if isRecursiveOwner {
          entry.ownerDepth += 1
        }
        entries[key] = entry
        return (key: key, lock: entry.lock, owns: isRecursiveOwner)
      }
      let entry = LockEntry(
        lock: NSRecursiveLock(),
        users: 1,
        ownerThread: currentThread,
        ownerDepth: 1
      )
      entries[key] = entry
      return (key: key, lock: entry.lock, owns: true)
    }
    registryLock.unlock()
    var ownedKeys = Set<UInt>()
    for item in lockCandidates where item.owns {
      item.lock.lock()
      ownedKeys.insert(item.key)
    }
    return LockAcquisition(
      locks: lockCandidates.map { (key: $0.key, lock: $0.lock) },
      ownedKeys: ownedKeys
    )
  }

  private func releaseLocks(
    _ acquisition: LockAcquisition,
    elements: [AXUIElement]
  ) {
    var elementsByKey: [UInt: AXUIElement] = [:]
    for element in elements {
      elementsByKey[elementIdentity(element)] = element
    }
    var resets: [(key: UInt, element: AXUIElement)] = []
    registryLock.lock()
    for item in acquisition.locks {
      guard var entry = entries[item.key] else { continue }
      entry.users -= 1
      if acquisition.ownedKeys.contains(item.key) {
        entry.ownerDepth = max(entry.ownerDepth - 1, 0)
        if entry.ownerDepth == 0 { entry.ownerThread = nil }
      }
      if entry.users == 0, let element = elementsByKey[item.key] {
        entry.resetting = true
        resets.append((item.key, element))
      }
      entries[item.key] = entry
    }
    registryLock.unlock()
    for reset in resets { timeoutSetter(reset.element, 0) }
    if !resets.isEmpty {
      registryLock.lock()
      for reset in resets { entries[reset.key] = nil }
      registryLock.broadcast()
      registryLock.unlock()
    }
    for item in acquisition.locks.reversed()
    where acquisition.ownedKeys.contains(item.key) {
      item.lock.unlock()
    }
  }

  private func elementIdentity(_ element: AXUIElement) -> UInt {
    UInt(bitPattern: Unmanaged.passUnretained(element).toOpaque())
  }
}
