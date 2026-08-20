import DefiConfig
import DefiModel
import DefiRuntime
import XCTest

final class RuntimeFocusTests: XCTestCase {
  private let monitorID = MonitorID(rawValue: 1)

  func testChangedStateRejectsBoundaryFocusNoOp() throws {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    for id in 1...2 {
      try discoverWindow(
        Window(
          id: WindowID(rawValue: UInt64(id)),
          appID: "app-\(id)",
          title: "Window \(id)",
          frame: Rect(x: 0, y: 0, width: 800, height: 700),
          monitorID: monitorID
        ),
        decision: RuleDecision(),
        state: &state
      )
    }

    XCTAssertNil(
      try changedState(after: .focusColumn(.left), on: monitorID, from: state)
    )
    XCTAssertNotNil(
      try changedState(after: .focusColumn(.right), on: monitorID, from: state)
    )
  }

  func testExternalFocusActivatesContainingWorkspace() throws {
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "browser",
      title: "Web",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )
    try discoverWindow(
      window,
      decision: RuleDecision(workspace: WorkspaceID(rawValue: "web")),
      state: &state
    )
    XCTAssertEqual(state.monitors[0].activeWorkspace, WorkspaceID(rawValue: "dev"))

    XCTAssertTrue(focusWindow(window.id, state: &state))

    XCTAssertEqual(state.monitors[0].activeWorkspace, WorkspaceID(rawValue: "web"))
  }

  func testExternalFocusSynchronizesNeverScrollUsingRealViewport() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let first = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "First",
      frame: Rect(x: 0, y: 0, width: 200, height: 700),
      monitorID: monitorID
    )
    let intrinsic = Window(
      id: WindowID(rawValue: 2),
      appID: "simulator",
      title: "Phone",
      frame: Rect(x: 200, y: 0, width: 900, height: 700),
      monitorID: monitorID
    )
    try discoverWindow(first, decision: RuleDecision(), state: &state)
    try discoverWindow(
      intrinsic,
      decision: RuleDecision(intrinsicSize: true),
      state: &state
    )
    state.monitors[0].workspaces[0].columns[0].width = .fraction(0.2)
    state.monitors[0].workspaces[0].columns[1].width = .fraction(0.2)

    focusWindow(intrinsic.id, state: &state)
    synchronizeScrollOffsets(
      state: &state,
      viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
    )

    XCTAssertEqual(
      state.monitors[0].workspaces[0].targetScrollOffset,
      0.1,
      accuracy: 0.001
    )
  }

  func testNativeFocusAlignsFocusedColumnToLeftEdge() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    for id in 1...3 {
      let window = Window(
        id: WindowID(rawValue: UInt64(id)),
        appID: "app-\(id)",
        title: "Window \(id)",
        frame: Rect(x: 0, y: 0, width: 800, height: 700),
        monitorID: monitorID
      )
      try discoverWindow(window, decision: RuleDecision(), state: &state)
    }
    let firstWindow = WindowID(rawValue: 1)
    focusWindow(firstWindow, state: &state)

    alignFocusedColumnLeft(
      on: monitorID,
      state: &state,
      viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
    )

    XCTAssertEqual(
      state.monitors[0].workspaces[0].targetScrollOffset,
      0,
      accuracy: 0.001
    )
  }

}
