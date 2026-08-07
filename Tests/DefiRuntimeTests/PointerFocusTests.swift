import DefiConfig
import DefiModel
import DefiRuntime
import Testing

struct PointerFocusTests {
  private let monitorID = MonitorID(rawValue: 1)
  private let viewport = Rect(x: 0, y: 0, width: 1_000, height: 800)

  @Test
  func pointerFocusChangesVisibleSelectionWithoutScrolling() throws {
    var state = try makeState(columnWidths: [0.4, 0.4])
    let originalOffset = state.monitors[0].workspaces[0].targetScrollOffset

    let focusedMonitor = focusWindowFromPointerWithoutScrolling(
      WindowID(rawValue: 2),
      activeMonitorID: monitorID,
      state: &state,
      viewports: [monitorID: viewport]
    )

    #expect(focusedMonitor == monitorID)
    #expect(state.selectedWindowID(on: monitorID) == WindowID(rawValue: 2))
    #expect(state.monitors[0].workspaces[0].targetScrollOffset == originalOffset)
  }

  @Test
  func pointerFocusRejectsTargetThatWouldScrollStrip() throws {
    var state = try makeState(columnWidths: [0.5, 0.5, 0.5])
    let original = state

    let focusedMonitor = focusWindowFromPointerWithoutScrolling(
      WindowID(rawValue: 3),
      activeMonitorID: monitorID,
      state: &state,
      viewports: [monitorID: viewport]
    )

    #expect(focusedMonitor == nil)
    #expect(state == original)
  }

  @Test
  func pointerFocusRejectsCenteringThatWouldMoveVisibleStrip() throws {
    var state = try makeState(
      columnWidths: [0.4, 0.4, 0.4],
      centerFocusedColumn: .always
    )
    let original = state

    let focusedMonitor = focusWindowFromPointerWithoutScrolling(
      WindowID(rawValue: 2),
      activeMonitorID: monitorID,
      state: &state,
      viewports: [monitorID: viewport]
    )

    #expect(focusedMonitor == nil)
    #expect(state == original)
  }

  @Test
  func repeatedPointerFocusDoesNothing() throws {
    var state = try makeState(columnWidths: [0.4, 0.4])

    let focusedMonitor = focusWindowFromPointerWithoutScrolling(
      WindowID(rawValue: 1),
      activeMonitorID: monitorID,
      state: &state,
      viewports: [monitorID: viewport]
    )

    #expect(focusedMonitor == nil)
  }

  @Test
  func cursorWarpRequiresEnabledKeyboardInput() {
    #expect(
      keyboardCursorWarpTimestamp(
        mouseFollowsFocus: true,
        capturedInputTimestamp: 12
      ) == 12
    )
    #expect(
      keyboardCursorWarpTimestamp(
        mouseFollowsFocus: true,
        capturedInputTimestamp: nil
      ) == nil
    )
    #expect(
      keyboardCursorWarpTimestamp(
        mouseFollowsFocus: false,
        capturedInputTimestamp: 12
      ) == nil
    )
  }

  @Test
  func pendingPointerFocusRequiresSameWindowAndNoNewerInput() {
    let windowID = WindowID(rawValue: 42)

    #expect(
      pointerFocusRetryIsCurrent(
        pendingWindowID: windowID,
        windowUnderPointerID: windowID,
        pointerTimestamp: 12,
        latestUserInputTimestamp: 12
      )
    )
    #expect(
      !pointerFocusRetryIsCurrent(
        pendingWindowID: windowID,
        windowUnderPointerID: WindowID(rawValue: 43),
        pointerTimestamp: 12,
        latestUserInputTimestamp: 12
      )
    )
    #expect(
      !pointerFocusRetryIsCurrent(
        pendingWindowID: windowID,
        windowUnderPointerID: windowID,
        pointerTimestamp: 12,
        latestUserInputTimestamp: 13
      )
    )
  }

  private func makeState(
    columnWidths: [Double],
    centerFocusedColumn: CenterFocusedColumnConfig = .never
  ) throws -> RuntimeState {
    let config = Config(
      layout: LayoutConfig(centerFocusedColumn: centerFocusedColumn)
    )
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    for (index, width) in columnWidths.enumerated() {
      let id = WindowID(rawValue: UInt64(index + 1))
      try discoverWindow(
        Window(
          id: id,
          appID: "app-\(index + 1)",
          title: "Window \(index + 1)",
          frame: viewport,
          monitorID: monitorID
        ),
        decision: RuleDecision(),
        state: &state
      )
      state.monitors[0].workspaces[0].columns[index].width = .fraction(width)
    }
    _ = focusWindow(WindowID(rawValue: 1), state: &state)
    synchronizeScrollOffsets(
      state: &state,
      viewports: [monitorID: viewport]
    )
    return state
  }
}
