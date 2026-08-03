import DefiConfig
import DefiModel
import Testing

@testable import DefiRuntime

struct NativeFocusTests {
  private let monitorID = MonitorID(rawValue: 1)

  @Test
  func alreadySelectedWindowDoesNotChangeNativeFocusSelection() throws {
    var state = try makeState()
    let selected = WindowID(rawValue: 1)
    #expect(focusWindow(selected, state: &state) == false)

    #expect(
      nativeFocusChangesSelection(
        selected,
        activeMonitorID: monitorID,
        state: state
      ) == false
    )
  }

  @Test
  func focusInsideActiveWorkspaceDoesNotReportWorkspaceActivation() throws {
    var state = try makeState()

    #expect(focusWindow(WindowID(rawValue: 2), state: &state) == false)
  }

  @Test
  func differentWindowChangesNativeFocusSelection() throws {
    var state = try makeState()
    focusWindow(WindowID(rawValue: 1), state: &state)

    #expect(
      nativeFocusChangesSelection(
        WindowID(rawValue: 2),
        activeMonitorID: monitorID,
        state: state
      )
    )
  }

  @Test
  func selectedWindowOnDifferentActiveMonitorChangesSelection() throws {
    var state = try makeState()
    let selected = WindowID(rawValue: 1)
    focusWindow(selected, state: &state)

    #expect(
      nativeFocusChangesSelection(
        selected,
        activeMonitorID: MonitorID(rawValue: 2),
        state: state
      )
    )
  }

  @Test
  func nativeFocusPreservesTwoVisibleColumns() throws {
    var state = try makeState(windowCount: 2)
    setColumnWidths(.fraction(0.5), state: &state)
    focusWindow(WindowID(rawValue: 2), state: &state)

    alignFocusedColumnLeft(
      on: monitorID,
      state: &state,
      viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
    )

    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 0)
  }

  @Test
  func nativeFocusPreservesVisibleColumnInsideOverflowingStrip() throws {
    var state = try makeState(windowCount: 4)
    setColumnWidths(.fraction(0.5), state: &state)
    focusWindow(WindowID(rawValue: 3), state: &state)
    state.monitors[0].workspaces[0].scrollOffset = 0.5

    alignFocusedColumnLeft(
      on: monitorID,
      state: &state,
      viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
    )

    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 0.5)
  }

  @Test
  func nativeFocusAlignmentCannotOverscrollPastStripEnd() throws {
    var state = try makeState(windowCount: 4)
    setColumnWidths(.fraction(0.5), state: &state)
    focusWindow(WindowID(rawValue: 4), state: &state)

    alignFocusedColumnLeft(
      on: monitorID,
      state: &state,
      viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
    )

    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 1)
  }

  private func makeState(windowCount: Int = 2) throws -> RuntimeState {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    for id in 1...windowCount {
      let window = Window(
        id: WindowID(rawValue: UInt64(id)),
        appID: "app-\(id)",
        title: "Window \(id)",
        frame: Rect(x: 0, y: 0, width: 800, height: 700),
        monitorID: monitorID
      )
      try discoverWindow(window, decision: RuleDecision(), state: &state)
    }
    return state
  }

  private func setColumnWidths(_ width: ColumnWidth, state: inout RuntimeState) {
    for index in state.monitors[0].workspaces[0].columns.indices {
      state.monitors[0].workspaces[0].columns[index].width = width
    }
  }
}
