import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing

struct StackConstraintRuntimeTests {
  private let monitorID = MonitorID(rawValue: 1)

  private func makeState(windowCount: Int, minimumHeight: Double) throws -> RuntimeState {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    for rawID in 1...windowCount {
      let window = Window(
        id: WindowID(rawValue: UInt64(rawID)),
        appID: "editor",
        title: "Window \(rawID)",
        frame: Rect(x: 0, y: 0, width: 784, height: 684),
        monitorID: monitorID,
        minimumTiledHeight: minimumHeight
      )
      try discoverWindow(
        window, decision: RuleDecision(followFocus: true), isNativelyFocused: true, state: &state)
    }
    return state
  }

  @Test
  func `Joining a window that cannot fit is rejected without changing state`() throws {
    var state = try makeState(windowCount: 2, minimumHeight: 500)
    let before = state

    #expect(
      throws: ReducerError.stackConstraint(
        StackRejection(requiredHeight: 1_040, availableHeight: 800))
    ) {
      try reduce(
        .joinWindow(.left), on: monitorID, state: &state,
        viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 800)])
    }
    #expect(state == before)
    #expect(
      ReducerError.stackConstraint(StackRejection(requiredHeight: 1_040, availableHeight: 800))
        .description == "cannot join: stack needs 1040pt but only 800pt is available")
  }

  @Test
  func `Joining succeeds when the stack fits or no viewport is known`() throws {
    var fitting = try makeState(windowCount: 2, minimumHeight: 500)
    try reduce(
      .joinWindow(.left), on: monitorID, state: &fitting,
      viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 1_100)])
    var unknown = try makeState(windowCount: 2, minimumHeight: 500)
    try reduce(.joinWindow(.left), on: monitorID, state: &unknown)

    #expect(fitting.monitors[0].workspaces[0].columns.map(\.windows.count) == [2])
    #expect(unknown.monitors[0].workspaces[0].columns.map(\.windows.count) == [2])
  }

  @Test
  func `Scroll synchronization separates an impossible stack once`() throws {
    var state = try makeState(windowCount: 3, minimumHeight: 300)
    state.monitors[0].workspaces[0].columns = [
      Column(
        windows: (1...3).map { WindowID(rawValue: $0) }, focusedWindow: 2, width: .fraction(0.5))
    ]
    state.monitors[0].workspaces[0].focusedColumn = 0
    let focused = state.selectedWindowID(on: monitorID)
    let viewports = [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 800)]
    #expect(state.monitors[0].workspaces[0].columns.map(\.windows.count) == [3])

    #expect(separateInfeasibleStacks(state: &state, viewports: viewports))

    let workspace = state.monitors[0].workspaces[0]
    #expect(
      workspace.columns.map(\.windows) == [
        [WindowID(rawValue: 1), WindowID(rawValue: 2)], [WindowID(rawValue: 3)],
      ])
    #expect(state.selectedWindowID(on: monitorID) == focused)

    let separated = state
    synchronizeScrollOffsets(state: &state, viewports: viewports)
    #expect(!separateInfeasibleStacks(state: &state, viewports: viewports))
    #expect(state.monitors[0].workspaces[0].columns == separated.monitors[0].workspaces[0].columns)
  }

  @Test
  func `A workspace migrated from a lost display keeps its stacks`() throws {
    var state = try makeState(windowCount: 3, minimumHeight: 300)
    state.monitors[0].workspaces[0].columns = [
      Column(windows: (1...3).map { WindowID(rawValue: $0) }, focusedWindow: 0, width: .fraction(0.5))
    ]
    state.monitors[0].workspaces[0].affinity = MonitorID(rawValue: 2)
    let before = state

    #expect(!separateInfeasibleStacks(
      state: &state, viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 800)]))
    #expect(state == before)
  }
}
