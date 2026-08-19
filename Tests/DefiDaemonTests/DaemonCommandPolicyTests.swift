import DefiModel
import Testing

@testable import DefiDaemon

struct DaemonCommandPolicyTests {
  @Test
  func crossMonitorMoveRefreshesEveryPreviousMonitor() {
    let source = MonitorID(rawValue: 1)
    let destination = MonitorID(rawValue: 2)
    let previousTransientMonitor = MonitorID(rawValue: 3)
    let owner = WindowID(rawValue: 10)
    let transient = WindowID(rawValue: 11)

    #expect(
      affectedMonitorIDsForWindowMove(
        commandMonitorID: source,
        resultMonitorID: destination,
        previousWindowMonitorIDs: [
          owner: source,
          transient: previousTransientMonitor,
        ],
        nextWindowMonitorIDs: [
          owner: destination,
          transient: destination,
        ]
      ) == [source, destination, previousTransientMonitor]
    )
  }

  @Test
  func crossMonitorMoveRebasesTheFreshlyObservedFloatingFrame() {
    let source = MonitorID(rawValue: 1)
    let destination = MonitorID(rawValue: 2)
    let windowID = WindowID(rawValue: 10)
    let freshFrame = Rect(x: 350, y: 80, width: 300, height: 200)

    #expect(
      rebasedFloatingWindowFrames(
        [windowID: freshFrame],
        previousViewports: [
          source: Rect(x: 0, y: 0, width: 1_000, height: 800)
        ],
        nextViewports: [
          destination: Rect(x: 1_000, y: 0, width: 2_000, height: 800)
        ],
        previousMonitorIDs: [windowID: source],
        nextMonitorIDs: [windowID: destination]
      )[windowID] == Rect(x: 1_850, y: 80, width: 300, height: 200)
    )
  }
}
