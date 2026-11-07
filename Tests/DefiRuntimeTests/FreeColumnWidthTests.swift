import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing

struct FreeColumnWidthTests {
  let monitorID = MonitorID(rawValue: 1)
  let viewport = Rect(x: 0, y: 0, width: 1_000, height: 800)

  func state(widths: [Double], focused: Int, centering: CenterFocusedColumnConfig = .never) -> RuntimeState {
    var state = RuntimeState(config: Config(layout: LayoutConfig(centerFocusedColumn: centering)))
    state.attachMonitor(monitorID)
    state.monitors[0].workspaces[0].columns = widths.indices.map {
      let id = WindowID(rawValue: UInt64($0 + 1))
      state.windows[id] = Window(
        id: id, appID: "app", title: "\($0)", frame: Rect(x: 0, y: 0, width: 400, height: 800))
      return Column(window: id, width: .fraction(widths[$0]))
    }
    state.monitors[0].workspaces[0].focusedColumn = focused
    // Adds the trailing workspace every reduce keeps, so a no-op command changes nothing.
    state.maintainWorkspaceLifecycle()
    return state
  }

  var strip: Double { stripViewport(viewport, settings: RuntimeState(config: Config()).layout).width }
  var gaps: Double { horizontalGaps(settings: RuntimeState(config: Config()).layout) }

  func points(_ width: ColumnWidth) -> Double? {
    if case .pixels(let points) = width { points } else { nil }
  }

  func width(_ change: ColumnWidthChange, from state: inout RuntimeState) throws -> ColumnWidth {
    try reduce(.setColumnWidth(change), on: monitorID, state: &state, viewports: [monitorID: viewport])
    return state.monitors[0].workspaces[0].columns[state.monitors[0].workspaces[0].focusedColumn].width
  }

  @Test
  func setColumnWidthSetsAdjustsAndClampsToTheUsableWidth() throws {
    var state = state(widths: [0.5], focused: 0)
    #expect(try width(.set(.fraction(0.6)), from: &state) == .fraction(0.6))
    guard case .fraction(let grown) = try width(.adjust(.fraction(0.05)), from: &state) else {
      Issue.record("expected a fraction"); return
    }
    #expect(abs(grown - 0.65) < 1e-9)
    #expect(try width(.adjust(.fraction(2)), from: &state) == .fraction(1))
    #expect(try width(.adjust(.fraction(-2)), from: &state) == .fraction(0.05))
    #expect(points(try width(.set(.pixels(960)), from: &state)).map { abs($0 - 960 - gaps) < 1e-6 } == true)
    #expect(points(try width(.adjust(.pixels(-60)), from: &state)).map { abs($0 - 900 - gaps) < 1e-6 } == true)
    #expect(points(try width(.set(.pixels(5_000)), from: &state)).map { abs($0 - strip) < 1e-6 } == true)
  }

  @Test
  func setColumnWidthRespectsVerifiedBoundsAndLeavesMaximize() throws {
    var state = state(widths: [0.5], focused: 0)
    state.windows[WindowID(rawValue: 1)]?.maximumTiledWidth = 600 - gaps
    #expect(try width(.set(.fraction(0.9)), from: &state) == .fraction(600 / strip))
    state.windows[WindowID(rawValue: 1)]?.maximumTiledWidth = nil
    state.windows[WindowID(rawValue: 1)]?.minimumTiledWidth = 300 - gaps
    #expect(try width(.set(.fraction(0.1)), from: &state) == .fraction(300 / strip))

    try reduce(.maximizeColumn, on: monitorID, state: &state)
    #expect(try width(.set(.fraction(0.6)), from: &state) == .fraction(0.6))
    #expect(state.monitors[0].workspaces[0].columns[0].preMaximizedWidth == nil)
  }

  @Test
  func cyclingFromAFreeWidthStepsToTheNearestPreset() throws {
    var state = state(widths: [0.5], focused: 0)
    _ = try width(.set(.fraction(0.6)), from: &state)
    try reduce(.cycleWidth(.next), on: monitorID, state: &state, viewports: [monitorID: viewport])
    #expect(state.monitors[0].workspaces[0].columns[0].width == .fraction(0.66))
    _ = try width(.set(.fraction(0.6)), from: &state)
    try reduce(.cycleWidth(.previous), on: monitorID, state: &state, viewports: [monitorID: viewport])
    #expect(state.monitors[0].workspaces[0].columns[0].width == .fraction(0.5))
  }

  @Test
  func setColumnWidthNeedsTheMonitorViewport() throws {
    let state = state(widths: [0.5], focused: 0)
    #expect(try changedState(after: .setColumnWidth(.set(.fraction(0.6))), on: monitorID, from: state) == nil)
  }

  @Test
  func expandFillsTheFreeSpaceBesideTheOtherVisibleColumns() throws {
    var state = state(widths: [0.5, 0.25], focused: 1)
    try reduce(.expandColumnToAvailableWidth, on: monitorID, state: &state, viewports: [monitorID: viewport])
    let columns = state.monitors[0].workspaces[0].columns
    #expect(columns[0].width == .fraction(0.5))
    guard case .fraction(let width) = columns[1].width else { Issue.record("expected a fraction"); return }
    #expect(abs(width - 0.5) < 1e-9)
    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 0)
  }

  @Test
  func expandIgnoresPartlyVisibleColumnsAndKeepsTheViewUnderCentering() throws {
    var state = state(widths: [0.5, 0.5, 0.5], focused: 1, centering: .always)
    state.monitors[0].workspaces[0].scrollOffset = 0.25
    state.monitors[0].workspaces[0].targetScrollOffset = 0.25
    try reduce(.expandColumnToAvailableWidth, on: monitorID, state: &state, viewports: [monitorID: viewport])
    synchronizeScrollOffsets(state: &state, viewports: [monitorID: viewport])
    let workspace = state.monitors[0].workspaces[0]
    guard case .fraction(let width) = workspace.columns[1].width else { Issue.record("expected a fraction"); return }
    #expect(abs(width - 1) < 1e-9)
    #expect(workspace.columns[0].width == .fraction(0.5))
    #expect(workspace.columns[2].width == .fraction(0.5))
    #expect(abs(workspace.targetScrollOffset - 0.5) < 1e-9)
  }

  @Test
  func expandStopsAtTheVerifiedMaximumAndDoesNothingWithoutFreeSpace() throws {
    var state = state(widths: [0.25], focused: 0)
    state.windows[WindowID(rawValue: 1)]?.maximumTiledWidth = 600 - gaps
    try reduce(.expandColumnToAvailableWidth, on: monitorID, state: &state, viewports: [monitorID: viewport])
    guard case .fraction(let width) = state.monitors[0].workspaces[0].columns[0].width else {
      Issue.record("expected a fraction"); return
    }
    #expect(abs(width - 600 / strip) < 1e-9)
    #expect(try changedState(
      after: .expandColumnToAvailableWidth, on: monitorID, from: state, viewports: [monitorID: viewport]) == nil)

    let full = self.state(widths: [0.5, 0.5], focused: 0)
    #expect(try changedState(
      after: .expandColumnToAvailableWidth, on: monitorID, from: full, viewports: [monitorID: viewport]) == nil)
  }
}
