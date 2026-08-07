import ApplicationServices
import DefiModel
import Testing

@testable import DefiMacOS

struct WindowSnapshotStabilityTests {
  private let processID: pid_t = 42
  private let frame = Rect(x: 4, y: 34, width: 1_200, height: 800)

  @Test func transientGeometryFailureRemainsUnavailable() {
    #expect(
      windowGeometryDiscovery(minimized: false, frame: nil) == .unavailable
    )
  }

  @Test func minimizedAndAuxiliarySizedWindowsRemainIgnored() {
    #expect(
      windowGeometryDiscovery(minimized: true, frame: frame) == .ignored
    )
    #expect(
      windowGeometryDiscovery(
        minimized: false,
        frame: Rect(x: 0, y: 0, width: 79, height: 60)
      ) == .ignored
    )
  }

  @Test func usableWindowGeometryRemainsDiscoverable() {
    #expect(
      windowGeometryDiscovery(minimized: false, frame: frame) == .usable(frame)
    )
  }

  @Test func existingCGWindowSurvivesTransientAccessibilityOmission() {
    let window = makeWindow(id: 42)

    #expect(
      cachedWindowIDsToRetain(
        processID: processID,
        previousWindows: [window],
        discoveredWindowIDs: [],
        ignoredWindowIDs: [],
        cgWindows: [makeCGWindow(id: 42)]
      ) == [window.id]
    )
  }

  @Test func rediscoveredIgnoredAndClosedWindowsDoNotUseCache() {
    let window = makeWindow(id: 42)
    let cgWindows = [makeCGWindow(id: 42)]

    #expect(
      cachedWindowIDsToRetain(
        processID: processID,
        previousWindows: [window],
        discoveredWindowIDs: [window.id],
        ignoredWindowIDs: [],
        cgWindows: cgWindows
      ).isEmpty
    )
    #expect(
      cachedWindowIDsToRetain(
        processID: processID,
        previousWindows: [window],
        discoveredWindowIDs: [],
        ignoredWindowIDs: [window.id],
        cgWindows: cgWindows
      ).isEmpty
    )
    #expect(
      cachedWindowIDsToRetain(
        processID: processID,
        previousWindows: [window],
        discoveredWindowIDs: [],
        ignoredWindowIDs: [],
        cgWindows: []
      ).isEmpty
    )
  }

  private func makeWindow(id: UInt64) -> Window {
    Window(
      id: WindowID(rawValue: id),
      appID: "com.example.app",
      title: "Window",
      frame: frame,
      processID: processID,
      monitorID: MonitorID(rawValue: 1)
    )
  }

  private func makeCGWindow(id: CGWindowID) -> CGWindowRecord {
    CGWindowRecord(
      id: id,
      processID: processID,
      layer: 0,
      title: "Window",
      frame: frame
    )
  }
}
