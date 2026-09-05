import Foundation
import Testing

@testable import DefiDaemon

struct DaemonInstanceLockTests {
  @Test
  func secondDaemonCannotAcquireTheSameLock() throws {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "defi-lock-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }

    let first = try DaemonInstanceLock(url: url)
    _ = withExtendedLifetime(first) {
      #expect(throws: DaemonInstanceLockError.alreadyRunning) {
        try DaemonInstanceLock(url: url)
      }
    }
  }
}
