import DefiConfig
import DefiModel
import DefiRuntime
import Testing

struct RuntimeFocusTests {
  private let monitorID = MonitorID(rawValue: 1)

  @Test
  func `Changed state rejects boundary focus no op`() throws {
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
        isFrontmostAppSpawn: true,
        state: &state
      )
    }

    // Policy (ADR 0002): discovery inside the active workspace focuses the
    // newest window (which also runs scroll repair), so the rejection check
    // targets the semantic outcome - the selection stays pinned at the
    // boundary - rather than whole-structure equality.
    state.monitors[0].workspaces[0].focusedColumn = 0
    let rejected = try changedState(
      after: .focusColumn(.left), on: monitorID, from: state
    )
    #expect(
      rejected?.monitors[0].workspaces[0].focusedColumn
        == state.monitors[0].workspaces[0].focusedColumn)
    #expect(try changedState(after: .focusColumn(.right), on: monitorID, from: state) != nil)
  }

  @Test
  func `External focus activates containing workspace`() throws {
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
    #expect(state.monitors[0].activeWorkspace == WorkspaceID(rawValue: "dev"))

    #expect(focusWindow(window.id, state: &state))

    #expect(state.monitors[0].activeWorkspace == WorkspaceID(rawValue: "web"))
  }

  @Test
  func `External focus synchronizes never scroll using real viewport`() throws {
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

    #expect(
      abs(state.monitors[0].workspaces[0].targetScrollOffset - 0.1) <= 0.001
    )
  }

  @Test
  func `Native focus aligns focused column to left edge`() throws {
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

    #expect(
      abs(state.monitors[0].workspaces[0].targetScrollOffset) <= 0.001
    )
  }

}
