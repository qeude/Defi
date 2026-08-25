import DefiModel
import Testing

@testable import DefiDaemon

struct DaemonPointerFocusRecoveryTests {
  @Test(
    "Native tab replacement keeps displaced command-focus recovery current",
    .bug("https://github.com/qeude/Defi/pull/40#discussion_r3857044752")
  )
  func nativeTabReplacementRebindsDisplacedCommandFocusRecovery() {
    let previousID = WindowID(rawValue: 10)
    let replacementID = WindowID(rawValue: 11)
    let previousSelectionID = WindowID(rawValue: 20)
    let replacementSelectionID = WindowID(rawValue: 21)
    let request = PendingAnimatedFocus(
      windowID: previousID,
      previousSelectedWindowID: previousSelectionID,
      monitorID: MonitorID(rawValue: 1),
      sourceWorkspaceID: WorkspaceID(rawValue: "dev"),
      commandGeneration: 2,
      focusInputTimestamp: 3,
      cursorWarpInputTimestamp: nil
    )

    let recovery = reboundDisplacedPointerFocusRecovery(
      .command(request, timestamp: 4),
      using: [
        previousID: replacementID,
        previousSelectionID: replacementSelectionID,
      ]
    )

    guard case .command(let reboundRequest, _) = recovery else {
      Issue.record("Expected command-focus recovery")
      return
    }
    #expect(reboundRequest.windowID == replacementID)
    #expect(
      reboundRequest.previousSelectedWindowID == replacementSelectionID
    )
  }
}
