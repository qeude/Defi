import DefiConfig
import DefiCore
import DefiModel
import Testing

@testable import DefiRuntime

struct NativeFullscreenRuntimeTests {
  private let monitorID = MonitorID(rawValue: 1)

  @Test
  func entryCompactsStripAndKeepsTargetAfterRightEdge() throws {
    var state = try makeState()
    let fullscreenID = WindowID(rawValue: 2)
    state.monitors[0].workspaces[0].columns[1].width = .pixels(420)

    reconcileWindows(
      orderedWindows(in: state),
      config: Config(),
      nativeFullscreenWindowIDs: [fullscreenID],
      state: &state
    )

    #expect(columnWindowIDs(in: state) == [[1], [3], [2]])
    #expect(state.nativeFullscreenWindowIDs == [fullscreenID])
    #expect(state.nativeFullscreenTiledPlacements[fullscreenID]?.columnIndex == 1)
    #expect(state.nativeFullscreenTiledPlacements[fullscreenID]?.column.width == .pixels(420))
    let layout = computeLayout(
      workspace: state.monitors[0].workspaces[0],
      viewport: Rect(x: 0, y: 0, width: 1_000, height: 800),
      windows: orderedWindows(in: state),
      settings: state.layout,
      excludingWindowIDs: state.nativeFullscreenWindowIDs
    )
    #expect(layout.frames.map(\.windowID) == [WindowID(rawValue: 1), WindowID(rawValue: 3)])
  }

  @Test
  func fullscreenSpaceDoesNotForgetWindowsHiddenFromDiscovery() throws {
    var state = try makeState()
    let fullscreenID = WindowID(rawValue: 2)

    reconcileWindows(
      [state.windows[fullscreenID]!],
      config: Config(),
      nativeFullscreenWindowIDs: [fullscreenID],
      state: &state
    )

    #expect(Set(state.windows.keys) == Set([1, 2, 3].map { WindowID(rawValue: $0) }))
    #expect(columnWindowIDs(in: state) == [[1], [3], [2]])
  }

  @Test
  func fullscreenDoesNotConsumeAnAutomaticFloatPlacement() throws {
    var state = try makeState()
    let fullscreenID = WindowID(rawValue: 2)
    let placement = SuspendedTiledPlacement(
      monitorID: monitorID,
      workspaceID: state.monitors[0].workspaces[0].id,
      columnIndex: 1,
      windowIndex: 0,
      column: state.monitors[0].workspaces[0].columns[1]
    )
    state.suspendedTiledPlacements[fullscreenID] = placement
    removeWindow(
      fullscreenID,
      from: &state.monitors[0].workspaces[0],
      settings: state.layout
    )
    state.monitors[0].workspaces[0].floatingWindows.append(fullscreenID)
    state.windows[fullscreenID]?.floating = true
    state.windows[fullscreenID]?.floatingOrigin = .automatic

    reconcileWindows(
      orderedWindows(in: state),
      config: Config(),
      nativeFullscreenWindowIDs: [fullscreenID],
      state: &state
    )
    reconcileWindows(orderedWindows(in: state), config: Config(), state: &state)

    #expect(state.suspendedTiledPlacements[fullscreenID] == placement)
    #expect(state.nativeFullscreenTiledPlacements[fullscreenID] == nil)
    #expect(state.monitors[0].workspaces[0].floatingWindows.contains(fullscreenID))
  }

  @Test
  func fullscreenTargetRemainsNavigableButCannotBeMutated() throws {
    var state = try makeState()
    let fullscreenID = WindowID(rawValue: 2)
    reconcileWindows(
      orderedWindows(in: state),
      config: Config(),
      nativeFullscreenWindowIDs: [fullscreenID],
      state: &state
    )
    _ = focusWindow(WindowID(rawValue: 3), state: &state)

    try reduce(.focusColumn(.right), on: monitorID, state: &state)
    #expect(state.selectedWindowID(on: monitorID) == fullscreenID)
    let beforeMutation = state
    try reduce(.maximizeColumn, on: monitorID, state: &state)
    #expect(state == beforeMutation)

    try reduce(.focusColumn(.left), on: monitorID, state: &state)
    #expect(state.selectedWindowID(on: monitorID) == WindowID(rawValue: 3))
  }

  @Test
  func exitRestoresExactSlotAndWidthWithoutChangingSelection() throws {
    var state = try makeState()
    let fullscreenID = WindowID(rawValue: 2)
    state.monitors[0].workspaces[0].columns[1].width = .pixels(420)
    reconcileWindows(
      orderedWindows(in: state),
      config: Config(),
      nativeFullscreenWindowIDs: [fullscreenID],
      state: &state
    )
    _ = focusWindow(WindowID(rawValue: 3), state: &state)

    reconcileWindows(
      orderedWindows(in: state),
      config: Config(),
      nativeFullscreenWindowIDs: [],
      state: &state
    )

    #expect(columnWindowIDs(in: state) == [[1], [2], [3]])
    #expect(state.monitors[0].workspaces[0].columns[1].width == .pixels(420))
    #expect(state.selectedWindowID(on: monitorID) == WindowID(rawValue: 3))
    #expect(state.nativeFullscreenTiledPlacements[fullscreenID] == nil)
  }

  @Test
  func multipleFullscreenTargetsKeepOriginalOrder() throws {
    var state = try makeState()
    reconcileWindows(
      orderedWindows(in: state),
      config: Config(),
      nativeFullscreenWindowIDs: [WindowID(rawValue: 3), WindowID(rawValue: 1)],
      state: &state
    )

    #expect(columnWindowIDs(in: state) == [[2], [1], [3]])
  }

  @Test
  func stackedWindowReturnsToItsExactPosition() throws {
    var state = try makeState()
    let fullscreenID = WindowID(rawValue: 2)
    state.monitors[0].workspaces[0].columns = [
      Column(
        windows: [WindowID(rawValue: 1), fullscreenID],
        focusedWindow: 0,
        width: .pixels(480)
      ),
      Column(window: WindowID(rawValue: 3), width: .fraction(0.5)),
    ]

    reconcileWindows(
      orderedWindows(in: state),
      config: Config(),
      nativeFullscreenWindowIDs: [fullscreenID],
      state: &state
    )
    #expect(columnWindowIDs(in: state) == [[1], [3], [2]])

    reconcileWindows(
      orderedWindows(in: state),
      config: Config(),
      state: &state
    )
    #expect(columnWindowIDs(in: state) == [[1, 2], [3]])
    #expect(state.monitors[0].workspaces[0].columns[0].width == .pixels(480))
  }

  @Test
  func joiningTowardFullscreenColumnDoesNothing() throws {
    var state = try makeState()
    let fullscreenID = WindowID(rawValue: 2)
    reconcileWindows(
      orderedWindows(in: state),
      config: Config(),
      nativeFullscreenWindowIDs: [fullscreenID],
      state: &state
    )
    _ = focusWindow(WindowID(rawValue: 3), state: &state)
    let beforeJoin = state

    try reduce(.joinWindow(.right), on: monitorID, state: &state)

    #expect(state == beforeJoin)
  }

  private func makeState() throws -> RuntimeState {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    for id in 1...3 {
      let window = Window(
        id: WindowID(rawValue: UInt64(id)),
        appID: "app-\(id)",
        title: "Window \(id)",
        frame: Rect(x: 0, y: 0, width: 800, height: 700),
        monitorID: monitorID
      )
      try discoverWindow(
        window,
        decision: RuleDecision(),
        isFrontmostAppSpawn: true,
        state: &state
      )
    }
    return state
  }

  private func orderedWindows(in state: RuntimeState) -> [Window] {
    state.windows.values.sorted { $0.id.rawValue < $1.id.rawValue }
  }

  private func columnWindowIDs(in state: RuntimeState) -> [[UInt64]] {
    state.monitors[0].workspaces[0].columns.map {
      $0.windows.map(\.rawValue)
    }
  }
}
