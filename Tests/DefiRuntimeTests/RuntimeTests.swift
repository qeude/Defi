import DefiConfig
import DefiModel
import DefiRuntime
import XCTest

final class RuntimeTests: XCTestCase {
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

  func testMouseResizeLearnsRealColumnWidth() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "Editor",
      frame: Rect(x: 8, y: 8, width: 484, height: 684),
      monitorID: monitorID
    )
    try discoverWindow(window, decision: RuleDecision(), state: &state)
    state.monitors[0].workspaces[0].columns[0].width = .fraction(0.5)

    let learned = learnTiledWindowWidth(
      window.id,
      actualFrame: Rect(x: 8, y: 8, width: 584, height: 684),
      state: &state,
      viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
    )

    XCTAssertTrue(learned)
    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns[0].width,
      .pixels(600)
    )
  }

  func testMouseResizeDoesNotOverwriteIntrinsicWidth() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "simulator",
      title: "Phone",
      frame: Rect(x: 8, y: 8, width: 304, height: 684),
      monitorID: monitorID
    )
    try discoverWindow(
      window,
      decision: RuleDecision(intrinsicSize: true),
      state: &state
    )

    XCTAssertFalse(
      learnTiledWindowWidth(
        window.id,
        actualFrame: Rect(x: 8, y: 8, width: 404, height: 684),
        state: &state,
        viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
      )
    )
  }

  func testFullscreenWidthCannotBeLearnedFromAXDrift() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "Editor",
      frame: Rect(x: 8, y: 8, width: 784, height: 684),
      monitorID: monitorID
    )
    try discoverWindow(window, decision: RuleDecision(), state: &state)
    try reduce(.toggleFullscreen, on: monitorID, state: &state)

    XCTAssertFalse(
      learnTiledWindowWidth(
        window.id,
        actualFrame: Rect(x: 8, y: 8, width: 784, height: 684),
        state: &state,
        viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
      )
    )
    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns[0].width,
      .fraction(1)
    )
    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns[0].fullscreenPreviousWidth,
      .fraction(0.8)
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

  func testDisplayResizeScalesPixelAndFullscreenPreviousWidths() {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    state.monitors[0].workspaces[0].columns = [
      Column(
        windows: [WindowID(rawValue: 1)],
        focusedWindow: 0,
        width: .fraction(1),
        fullscreenPreviousWidth: .pixels(800)
      ),
      Column(window: WindowID(rawValue: 2), width: .pixels(1_000)),
    ]

    state.retainMonitors(
      [monitorID],
      previousViewports: [
        monitorID: Rect(x: 0, y: 0, width: 2_000, height: 1_000)
      ],
      nextViewports: [
        monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)
      ]
    )

    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns[0].fullscreenPreviousWidth,
      .pixels(400)
    )
    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns[1].width,
      .pixels(500)
    )
  }

  func testDisconnectedMonitorMergesAndScalesColumnsIntoRemainingDisplay() {
    let externalID = MonitorID(rawValue: 2)
    let config = Config(workspaces: WorkspacesConfig(names: ["dev"]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    state.attachMonitor(externalID)
    state.monitors[1].workspaces[0].columns = [
      Column(window: WindowID(rawValue: 9), width: .pixels(1_200))
    ]

    state.retainMonitors(
      [monitorID],
      previousViewports: [
        monitorID: Rect(x: 0, y: 0, width: 1_500, height: 900),
        externalID: Rect(x: 1_500, y: 0, width: 3_000, height: 1_600),
      ],
      nextViewports: [
        monitorID: Rect(x: 0, y: 0, width: 1_500, height: 900)
      ]
    )

    XCTAssertEqual(state.monitors.count, 1)
    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns[0].width,
      .pixels(600)
    )
  }

  func testEachMonitorOwnsIndependentNineWorkspaces() throws {
    let externalID = MonitorID(rawValue: 2)
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    state.attachMonitor(externalID)

    XCTAssertEqual(
      state.monitors[0].workspaces.map(\.id.rawValue),
      (1...9).map(String.init)
    )
    XCTAssertEqual(
      state.monitors[1].workspaces.map(\.id.rawValue),
      (1...9).map(String.init)
    )

    try reduce(
      .switchWorkspace(WorkspaceID(rawValue: "5")),
      on: externalID,
      state: &state
    )

    XCTAssertEqual(
      state.monitors.first(where: { $0.id == monitorID })?.activeWorkspace,
      WorkspaceID(rawValue: "1")
    )
    XCTAssertEqual(
      state.monitors.first(where: { $0.id == externalID })?.activeWorkspace,
      WorkspaceID(rawValue: "5")
    )
  }
}
