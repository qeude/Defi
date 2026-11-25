import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing

struct PinColumnRuntimeTests {
  private let monitorID = MonitorID(rawValue: 1)
  private let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)
  private var viewports: [MonitorID: Rect] { [monitorID: viewport] }

  @Test
  func `The same pin command pins the focused column and returns it to the strip`() throws {
    var state = try makeState(windowCount: 3)
    try reduce(.pinColumn(.right), on: monitorID, state: &state, viewports: viewports)
    var workspace = state.monitors[0].workspaces[0]
    #expect(workspace.columns.map(\.pin) == [nil, nil, .right])
    #expect(workspace.selectedWindowID == WindowID(rawValue: 3))

    // One pinned column: pinning another returns the first to the strip.
    try reduce(.focusColumn(.first), on: monitorID, state: &state, viewports: viewports)
    try reduce(.pinColumn(.left), on: monitorID, state: &state, viewports: viewports)
    workspace = state.monitors[0].workspaces[0]
    #expect(workspace.columns.map(\.pin) == [.left, nil, nil])
    #expect(workspace.columns[0].windows == [WindowID(rawValue: 1)])

    try reduce(.pinColumn(.left), on: monitorID, state: &state, viewports: viewports)
    #expect(state.monitors[0].workspaces[0].columns.allSatisfy { $0.pin == nil })
  }

  @Test(arguments: [ColumnPin.left, .right])
  func `The pinned column shows on every workspace and keeps the trailing one empty`(
    edge: ColumnPin
  ) throws {
    var state = try makeState(windowCount: 2)
    try reduce(.pinColumn(edge), on: monitorID, state: &state, viewports: viewports)
    let pinned = WindowID(rawValue: 2)
    let home = state.monitors[0].activeWorkspace

    try reduce(.focusWorkspace(.relative(.down)), on: monitorID, state: &state, viewports: viewports)
    let trailing = state.monitors[0].workspaces.last!
    #expect(state.monitors[0].activeWorkspace == trailing.id)
    #expect(trailing.kind == .trailing)
    #expect(trailing.columns.map(\.windows) == [[pinned]])
    #expect(state.monitors[0].workspaces.count == 2)
    #expect(!state.monitors[0].workspaces[0].columns.contains { $0.windows.contains(pinned) })

    try reduce(.focusWorkspace(.relative(.up)), on: monitorID, state: &state, viewports: viewports)
    let back = state.monitors[0].workspaces[0]
    #expect(back.id == home)
    #expect(back.columns.map(\.pin) == (edge == .left ? [.left, nil] : [nil, .right]))
    #expect(state.monitors[0].workspaces.last!.isEmpty)
  }

  @Test
  func `Moving the pinned column to another workspace is refused`() throws {
    var state = try makeState(windowCount: 2)
    try reduce(.pinColumn(.left), on: monitorID, state: &state, viewports: viewports)
    let before = state.monitors[0]
    for command in [
      Command.moveColumnToWorkspace(.relative(.down), follow: true),
      .moveWindowToWorkspace(state.monitors[0].workspaces.last!.id),
    ] {
      #expect(throws: ReducerError.pinnedColumnStays) {
        try reduce(command, on: monitorID, state: &state, viewports: viewports)
      }
      #expect(state.monitors[0] == before)
    }
  }

  @Test
  func `Expanding beside a pinned column fills the room it leaves, not the whole screen`() throws {
    var state = try makeState(windowCount: 3)
    try reduce(.focusColumn(.first), on: monitorID, state: &state, viewports: viewports)
    try reduce(.setColumnWidth(.set(.fraction(0.3))), on: monitorID, state: &state, viewports: viewports)
    try reduce(.pinColumn(.left), on: monitorID, state: &state, viewports: viewports)
    for (index, width) in [(1, 0.3), (2, 0.2)] {
      state.monitors[0].workspaces[0].columns[index].width = .fraction(width)
    }
    state.monitors[0].workspaces[0].focusedColumn = 1
    state.monitors[0].workspaces[0].scrollOffset = 0
    state.monitors[0].workspaces[0].targetScrollOffset = 0

    try reduce(.expandColumnToAvailableWidth, on: monitorID, state: &state, viewports: viewports)

    let workspace = state.monitors[0].workspaces[0]
    let pinned = try frame(workspace.columns[0].windows[0], state)
    let last = try frame(workspace.columns[2].windows[0], state)
    // The outer gap mirrors the pinned column's at the other edge.
    #expect(abs(last.x + last.width - (viewport.width - pinned.x)) < 0.5)
  }

  @Test
  func `The pin survives a restart and display loss`() throws {
    var state = try makeState(windowCount: 2)
    try reduce(.pinColumn(.right), on: monitorID, state: &state, viewports: viewports)
    var restored = RuntimeState(config: Config(), topology: state.topology)
    restored.maintainWorkspaceLifecycle()
    #expect(restored.monitors[0].workspaces[0].columns.map(\.pin) == [nil, .right])

    let other = MonitorID(rawValue: 2)
    state.attachMonitor(other)
    try reduce(.focusColumn(.first), on: monitorID, state: &state, viewports: viewports)
    let frames = [monitorID: viewport, other: Rect(x: 1_000, y: 0, width: 1_000, height: 700)]
    try reduce(.moveColumnToMonitor(.right), on: monitorID, state: &state, monitorFrames: frames,
      viewports: frames)
    state.retainMonitors([other])
    let pins = state.monitors[0].workspaces.flatMap(\.columns).compactMap(\.pin)
    #expect(pins == [.right])
    let active = state.monitors[0].workspaces.first { $0.id == state.monitors[0].activeWorkspace }!
    #expect(active.columns.contains { $0.pin == .right })
  }

  @Test
  func `move-column refuses a pinned column`() throws {
    var state = try makeState(windowCount: 3)
    try reduce(.pinColumn(.right), on: monitorID, state: &state, viewports: viewports)
    let before = state.monitors[0].workspaces[0].columns
    try reduce(.moveColumn(.left), on: monitorID, state: &state, viewports: viewports)
    #expect(state.monitors[0].workspaces[0].columns == before)
  }

  @Test
  func `Dropping a pinned column at its own place unpins it`() throws {
    var state = try makeState(windowCount: 3)
    try reduce(.focusColumn(.first), on: monitorID, state: &state, viewports: viewports)
    try reduce(.pinColumn(.left), on: monitorID, state: &state, viewports: viewports)
    #expect(applyMouseDrop(WindowID(rawValue: 1), .column(index: 0), state: &state, viewports: viewports))
    #expect(state.monitors[0].workspaces[0].columns.allSatisfy { $0.pin == nil })
  }

  @Test
  func `Dropping a pinned column into the strip unpins it`() throws {
    var state = try makeState(windowCount: 3)
    try reduce(.focusColumn(.first), on: monitorID, state: &state, viewports: viewports)
    try reduce(.pinColumn(.left), on: monitorID, state: &state, viewports: viewports)
    let dragged = WindowID(rawValue: 1)
    #expect(applyMouseDrop(dragged, .column(index: 2), state: &state, viewports: viewports))
    let workspace = state.monitors[0].workspaces[0]
    #expect(workspace.columns.allSatisfy { $0.pin == nil })
    #expect(workspace.columns[2].windows == [dragged])
  }

  @Test
  func `Point width changes count in the whole strip for every column`() throws {
    var state = try makeState(windowCount: 2)
    try reduce(.setColumnWidth(.set(.fraction(0.25))), on: monitorID, state: &state, viewports: viewports)
    try reduce(.pinColumn(.left), on: monitorID, state: &state, viewports: viewports)
    for column in [0, 1] {
      if column == 1 {
        try reduce(.focusColumn(.right), on: monitorID, state: &state, viewports: viewports)
        // Room to grow beside the pinned column, which caps the strip columns.
        try reduce(.setColumnWidth(.set(.fraction(0.25))), on: monitorID, state: &state, viewports: viewports)
      }
      let windowID = state.monitors[0].workspaces[0].columns[column].windows[0]
      let before = try frame(windowID, state)
      try reduce(.setColumnWidth(.adjust(.pixels(100))), on: monitorID, state: &state, viewports: viewports)
      #expect(abs(try frame(windowID, state).width - before.width - 100) < 0.001)
    }
  }

  private func frame(_ windowID: WindowID, _ state: RuntimeState) throws -> Rect {
    let workspace = state.monitors[0].workspaces[0]
    return try #require(computeLayout(
      workspace: workspace, viewport: viewport,
      windows: workspace.columns.flatMap(\.windows).compactMap { state.windows[$0] },
      settings: state.layout
    ).first { $0.windowID == windowID }?.frame)
  }

  private func makeState(windowCount: Int) throws -> RuntimeState {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    for rawID in 1...windowCount {
      let window = Window(
        id: WindowID(rawValue: UInt64(rawID)), appID: "editor", title: "Window \(rawID)",
        frame: Rect(x: 0, y: 0, width: 784, height: 684), monitorID: monitorID)
      try discoverWindow(
        window, decision: RuleDecision(followFocus: true), isNativelyFocused: true, state: &state)
    }
    return state
  }
}
