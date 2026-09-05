import Foundation
import Testing

@testable import DefiDaemon

@MainActor
private final class ReloadCounter {
  var value = 0
}

struct ConfigFileWatcherTests {
  @Test @MainActor
  func observesFirstConfigCreatedAfterStartup() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appending(path: "defi/config.toml")
    let counter = ReloadCounter()
    let watcher = ConfigFileWatcher(configURL: configURL) { counter.value += 1 }
    defer { watcher.stop() }

    try watcher.start()
    #expect(FileManager.default.fileExists(atPath: configURL.path) == false)
    try Data("[layout]\ngaps = 10\n".utf8).write(to: configURL, options: .atomic)
    try await waitForReloadCount(1, counter: counter)
    #expect(counter.value >= 1)
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
      counter.value += 1
    }
    try watcher.start()
    try Data("[layout]\ngaps = 10\n".utf8).write(to: configURL)
    try await waitForReloadCount(1, counter: counter)
    #expect(counter.value == 1)

    try Data("[layout]\ngaps = 12\n".utf8).write(to: configURL, options: .atomic)
    try await waitForReloadCount(2, counter: counter)
    watcher.stop()

    #expect(counter.value == 2)
  }

  @MainActor
  private func waitForReloadCount(_ expected: Int, counter: ReloadCounter) async throws {
    for _ in 0..<100 {
      if counter.value >= expected { return }
      try await Task.sleep(for: .milliseconds(50))
    }
  }
}
