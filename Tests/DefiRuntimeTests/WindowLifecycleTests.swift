import DefiConfig
import DefiModel
import DefiRuntime
import XCTest

final class WindowLifecycleTests: XCTestCase {
  private let monitorID = MonitorID(rawValue: 1)

  func testDiscoveryUsesRuleWorkspaceAndFollowFocus() throws {
    let config = Config(
      workspaces: WorkspacesConfig(names: ["dev", "web"]),
      rules: [Rule(appID: "browser", workspace: "web", followFocus: true)]
    )
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "browser",
      title: "Web",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )

    try discoverWindow(window, decision: config.decision(for: window), state: &state)

    XCTAssertEqual(state.monitors[0].activeWorkspace, WorkspaceID(rawValue: "web"))
    XCTAssertEqual(state.monitors[0].workspaces[1].columns[0].windows, [window.id])
  }

  func testMoveWindowToWorkspaceFollows() throws {
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "Editor",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )
    try discoverWindow(window, decision: RuleDecision(), state: &state)

    try reduce(
      .moveWindowToWorkspace(WorkspaceID(rawValue: "web")),
      on: monitorID,
      state: &state
    )

    XCTAssertEqual(state.monitors[0].activeWorkspace, WorkspaceID(rawValue: "web"))
    XCTAssertEqual(state.monitors[0].workspaces[1].columns[0].windows, [window.id])
    XCTAssertTrue(state.monitors[0].workspaces[0].columns.isEmpty)
  }

  func testReconcileRemovesClosedWindow() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "Editor",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )
    try discoverWindow(window, decision: RuleDecision(), state: &state)

    reconcileWindows([], config: config, state: &state)

    XCTAssertTrue(state.windows.isEmpty)
    XCTAssertTrue(state.monitors[0].workspaces[0].columns.isEmpty)
  }

  func testReconcilePreservesIntrinsicDimensionsAfterAppliedGaps() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let initial = Window(
      id: WindowID(rawValue: 1),
      appID: "simulator",
      title: "Phone",
      frame: Rect(x: 0, y: 0, width: 320, height: 640),
      monitorID: monitorID,
      intrinsicSize: true
    )
    try discoverWindow(
      initial,
      decision: RuleDecision(intrinsicSize: true),
      state: &state
    )
    let observedAfterLayout = Window(
      id: initial.id,
      appID: initial.appID,
      title: initial.title,
      frame: Rect(x: 8, y: 8, width: 304, height: 624),
      monitorID: monitorID
    )

    reconcileWindows([observedAfterLayout], config: config, state: &state)

    XCTAssertEqual(state.windows[initial.id]?.frame.width, 320)
    XCTAssertEqual(state.windows[initial.id]?.frame.height, 640)
  }

}
