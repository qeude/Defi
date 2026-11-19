import Foundation
import Testing

@testable import DefiDaemon

@MainActor
private final class ReloadCounter {
  private(set) var value = 0
  private var waiter: (count: Int, continuation: CheckedContinuation<Bool, Never>)?

  func record() {
    value += 1
    resumeWaiterIfReached()
  }

  /// Awaits the watcher's callback; false when it never arrives, so a failure names itself here.
  func waitForReload(_ count: Int, timeout: Duration = .seconds(5)) async -> Bool {
    guard value < count else { return true }
    let deadline = Task { @MainActor in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled, let waiter = self.waiter else { return }
      self.waiter = nil
      waiter.continuation.resume(returning: false)
    }
    let reached = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      self.waiter = (count, continuation)
      self.resumeWaiterIfReached()
    }
    deadline.cancel()
    return reached
  }

  private func resumeWaiterIfReached() {
    guard let waiter, value >= waiter.count else { return }
    self.waiter = nil
    waiter.continuation.resume(returning: true)
  }
}

struct ConfigFileWatcherTests {
  @Test @MainActor
  func observesFirstConfigCreatedAfterStartup() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appending(path: "defi/config.toml")
    let counter = ReloadCounter()
    let watcher = ConfigFileWatcher(configURL: configURL) { counter.record() }
    defer { watcher.stop() }

    try watcher.start()
    #expect(FileManager.default.fileExists(atPath: configURL.path) == false)
    try Data("[layout]\ngaps = 10\n".utf8).write(to: configURL, options: .atomic)
    #expect(await counter.waitForReload(1))
  }

  @Test @MainActor
  func observesInPlaceAndAtomicConfigSavesAfterDebouncing() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let configURL = directory.appending(path: "config.toml")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("[layout]\ngaps = 8\n".utf8).write(to: configURL)

    let counter = ReloadCounter()
    let watcher = ConfigFileWatcher(configURL: configURL) {
      counter.record()
    }
    try watcher.start()
    try Data("[layout]\ngaps = 10\n".utf8).write(to: configURL)
    #expect(await counter.waitForReload(1))
    #expect(counter.value == 1)

    try Data("[layout]\ngaps = 12\n".utf8).write(to: configURL, options: .atomic)
    #expect(await counter.waitForReload(2))
    watcher.stop()

    #expect(counter.value == 2)
  }
}
