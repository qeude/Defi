import DefiRuntime
import Foundation
import Testing

@testable import DefiDaemon

struct PlacementStoreTests {
  @Test
  func finalFlushWaitsForRunningOlderSave() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "defi-placement-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = PlacementStore(url: directory.appending(path: "placements.json"))
    let queue = DispatchQueue(label: "com.quentin.defi.tests.placements")
    let olderWriteStarted = DispatchSemaphore(value: 0)
    let releaseOlderWrite = DispatchSemaphore(value: 0)

    queue.async {
      olderWriteStarted.signal()
      releaseOlderWrite.wait()
      try! store.save(PlacementPreferences(version: 1))
    }
    #expect(olderWriteStarted.wait(timeout: .now() + 1) == .success)

    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
      releaseOlderWrite.signal()
    }
    try flushPlacementStore(
      store,
      preferences: PlacementPreferences(version: 2),
      on: queue
    )
    queue.sync {}

    #expect(try store.load() == PlacementPreferences(version: 2))
  }
}
