import DefiConfig
import DefiCore
import DefiModel
import Testing

@testable import DefiRuntime

struct NativeFullscreenRuntimeTests {
  private let monitorID = MonitorID(rawValue: 1)

  @Test
  func `Entry compacts strip and keeps target after right edge`() throws {
    var state = try makeState()
    let fullscreenID = WindowID(rawValue: 2)
    state.monitors[0].workspaces[0].columns[1].width = .pixels(420)
    state.windows[fullscreenID]?.minimumTiledWidth = 900

    reconcileWindows(
      orderedWindows(in: state),
      config: Config(),
      nativeFullscreenWindowIDs: [fullscreenID],
      state: &state
    )

    #expect(columnWindowIDs(in: state) == [[1], [3], [2]])
    #expect(state.nativeFullscreenWindowIDs == [fullscreenID])
    #expect(state.windows[fullscreenID]?.minimumTiledWidth == nil)
    #expect(state.nativeFullscreenTiledPlacements[fullscreenID]?.columnIndex == 1)
    #expect(state.nativeFullscreenTiledPlacements[fullscreenID]?.column.width == .pixels(420))
    let layout = computeLayout(
      workspace: state.monitors[0].workspaces[0],
      viewport: Rect(x: 0, y: 0, width: 1_000, height: 800),
      windows: orderedWindows(in: state),
      settings: state.layout,
      excludingWindowIDs: state.nativeFullscreenWindowIDs
    )
    #expect(layout.map(\.windowID) == [WindowID(rawValue: 1), WindowID(rawValue: 3)])
  }

  @Test
  func `Late fullscreen observation preserves windows hidden by its space`() throws {
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
  func `Explicit window closure is applied while a fullscreen space hides discovery`() throws {
    var state = try makeState()
    let fullscreenID = WindowID(rawValue: 2)
    let closedID = WindowID(rawValue: 1)
    let remainingID = WindowID(rawValue: 3)

    reconcileWindows(
      [state.windows[fullscreenID]!, state.windows[remainingID]!],
      config: Config(),
      nativeFullscreenWindowIDs: [fullscreenID],
      explicitlyRemovedWindowIDs: [closedID],
      state: &state
    )

    #expect(Set(state.windows.keys) == [fullscreenID, remainingID])
    #expect(state.location(containing: closedID) == nil)
    #expect(state.nativeFullscreenWindowIDs == [fullscreenID])

    reconcileWindows(
      [state.windows[remainingID]!],
      config: Config(),
      explicitlyRemovedWindowIDs: [fullscreenID],
      state: &state
    )

    #expect(Set(state.windows.keys) == [remainingID])
    #expect(state.nativeFullscreenWindowIDs.isEmpty)
    #expect(state.nativeFullscreenTiledPlacements.isEmpty)
    #expect(state.pendingNativeFullscreenWidthResetWindowIDs.isEmpty)
    #expect(state.location(containing: fullscreenID) == nil)
  }

  @Test
  func `Closing an earlier column preserves fullscreen return order`() throws {
    var state = try makeState()
    let fullscreenID = WindowID(rawValue: 2)
    let closedID = WindowID(rawValue: 1)
    let remainingID = WindowID(rawValue: 3)

    reconcileWindows(
      orderedWindows(in: state),
      config: Config(),
      nativeFullscreenWindowIDs: [fullscreenID],
      state: &state
    )
    reconcileWindows(
      [try #require(state.windows[fullscreenID]), try #require(state.windows[remainingID])],
      config: Config(),
      nativeFullscreenWindowIDs: [fullscreenID],
      explicitlyRemovedWindowIDs: [closedID],
      state: &state
    )

    #expect(state.nativeFullscreenTiledPlacements[fullscreenID]?.columnIndex == 0)

    reconcileWindows(
      [try #require(state.windows[fullscreenID]), try #require(state.windows[remainingID])],
      config: Config(),
      state: &state
    )

    #expect(columnWindowIDs(in: state) == [[2], [3]])
  }

  @Test
  func `Fullscreen exit preserves the latest workspace and focus intent`() throws {
    let config = Config(
      workspaces: WorkspacesConfig(names: ["home", "other"], defaultName: "home")
    )
    var state = try makeState(config: config)
    let fullscreenID = WindowID(rawValue: 2)
    let homeID = WorkspaceID(rawValue: "home")
    let otherID = WorkspaceID(rawValue: "other")
    let otherWindowID = WindowID(rawValue: 4)
    try discoverWindow(
      Window(
        id: otherWindowID,
        appID: "other-app",
        title: "Other workspace",
        frame: Rect(x: 0, y: 0, width: 800, height: 700),
        monitorID: monitorID
      ),
      decision: RuleDecision(workspace: otherID),
      state: &state
    )

    reconcileWindows(
      orderedWindows(in: state),
      config: config,
      nativeFullscreenWindowIDs: [fullscreenID],
      state: &state
    )
    _ = focusWindow(WindowID(rawValue: 1), state: &state)
    try reduce(.switchWorkspace(otherID), on: monitorID, state: &state)
    _ = focusWindow(otherWindowID, state: &state)

    reconcileWindows(
      orderedWindows(in: state),
      config: config,
      nativeFullscreenWindowIDs: [],
      state: &state
    )

    #expect(state.monitors[0].activeWorkspace == otherID)
    #expect(state.selectedWindowID(on: monitorID) == otherWindowID)
    #expect(state.location(containing: fullscreenID)?.workspaceID == homeID)
    #expect(columnWindowIDs(in: state) == [[1], [2], [3]])
  }

  @Test
  func `Fullscreen placement migrates with its workspace when its monitor disconnects`() throws {
    var state = try makeState()
    let fallbackMonitorID = MonitorID(rawValue: 2)
    let fullscreenID = WindowID(rawValue: 2)
    state.monitors[0].workspaces[0].columns[1].width = .pixels(420)
    state.attachMonitor(fallbackMonitorID)
    reconcileWindows(
      orderedWindows(in: state),
      config: Config(),
      nativeFullscreenWindowIDs: [fullscreenID],
      state: &state
    )

    state.retainMonitors(
      [fallbackMonitorID],
      previousViewports: [
        monitorID: Rect(x: 0, y: 0, width: 1_000, height: 800),
        fallbackMonitorID: Rect(x: 1_000, y: 0, width: 1_000, height: 800),
      ],
      nextViewports: [fallbackMonitorID: Rect(x: 1_000, y: 0, width: 1_200, height: 900)]
    )

    #expect(state.nativeFullscreenTiledPlacements[fullscreenID]?.monitorID == fallbackMonitorID)

    reconcileWindows(
      orderedWindows(in: state),
      config: Config(),
      nativeFullscreenWindowIDs: [],
      state: &state
    )

    #expect(state.monitorID(containing: fullscreenID) == fallbackMonitorID)
    #expect(columnWindowIDs(in: state) == [[1], [2], [3]])
    #expect(state.monitors[0].workspaces[0].columns[1].width == .pixels(504))
    #expect(state.nativeFullscreenTiledPlacements[fullscreenID] == nil)
  }

  @Test
  func `Fullscreen does not consume an automatic float placement`() throws {
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

    #expect(state.monitors[0].workspaces[0].floatingWindows.isEmpty)
    #expect(columnWindowIDs(in: state) == [[1], [3], [2]])
    #expect(state.nativeFullscreenFloatingWindowIDs == [fullscreenID])

    reconcileWindows(orderedWindows(in: state), config: Config(), state: &state)

    #expect(state.suspendedTiledPlacements[fullscreenID] == placement)
    #expect(state.nativeFullscreenTiledPlacements[fullscreenID] == nil)
    #expect(state.nativeFullscreenFloatingWindowIDs.isEmpty)
    #expect(state.monitors[0].workspaces[0].floatingWindows.contains(fullscreenID))
  }

  @Test
  func `Fullscreen target remains navigable but cannot be mutated`() throws {
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
  func `Fullscreen placeholder can drive ribbon scroll`() throws {
    var state = try makeState()
    let fullscreenID = WindowID(rawValue: 2)
    let viewport = Rect(x: 0, y: 0, width: 1_000, height: 800)
    reconcileWindows(
      orderedWindows(in: state),
      config: Config(),
      nativeFullscreenWindowIDs: [fullscreenID],
      state: &state
    )
    _ = focusWindow(fullscreenID, state: &state)

    synchronizeScrollOffsets(state: &state, viewports: [monitorID: viewport])
    var workspace = state.monitors[0].workspaces[0]
    #expect(workspace.targetScrollOffset > 0)

    workspace.scrollOffset = workspace.targetScrollOffset
    let placeholderFrame = computeLayout(
      workspace: workspace,
      viewport: viewport,
      windows: orderedWindows(in: state),
      settings: state.layout
    ).first { $0.windowID == fullscreenID }?.frame
    #expect(placeholderFrame.map { $0.x < viewport.width } == true)
    #expect(placeholderFrame.map { $0.x + $0.width > viewport.x } == true)
  }

  @Test
  func `Exit restores exact slot and width without changing selection`() throws {
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
    #expect(state.pendingNativeFullscreenWidthResetWindowIDs == [fullscreenID])
  }

  @Test
  func `First width cycle after fullscreen reevaluates the window minimum`() throws {
    var state = try makeState()
    let fullscreenID = WindowID(rawValue: 2)
    reconcileWindows(
      orderedWindows(in: state),
      config: Config(),
      nativeFullscreenWindowIDs: [fullscreenID],
      state: &state
    )
    reconcileWindows(orderedWindows(in: state), config: Config(), state: &state)
    _ = focusWindow(fullscreenID, state: &state)
    state.windows[fullscreenID]?.minimumTiledWidth = 900

    try reduce(
      .cycleWidth(.next),
      on: monitorID,
      state: &state,
      viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 800)]
    )

    #expect(state.windows[fullscreenID]?.minimumTiledWidth == nil)
    #expect(state.pendingNativeFullscreenWidthResetWindowIDs.isEmpty)
  }

  @Test
  func `Multiple fullscreen targets keep original order`() throws {
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
  func `Stacked window returns to its exact position`() throws {
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
  func `Joining toward fullscreen column does nothing`() throws {
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

  @Test(arguments: [1, 2, 3, 4], [[], [1], [3], [1, 3], [1, 2, 3, 4]])
  func `Closure uses logical column order with multiple fullscreen windows`(
    closed: Int, nextFullscreen: [Int]
  ) throws {
    var state = try makeState(windowCount: 4)
    let fullscreenIDs = Set([1, 3].map { WindowID(rawValue: $0) })
    let closedID = WindowID(rawValue: UInt64(closed))
    reconcileWindows(
      orderedWindows(in: state),
      config: Config(),
      nativeFullscreenWindowIDs: fullscreenIDs,
      state: &state
    )
    reconcileWindows(
      orderedWindows(in: state).filter { $0.id != closedID },
      config: Config(),
      nativeFullscreenWindowIDs: Set(nextFullscreen.map { WindowID(rawValue: UInt64($0)) }),
      explicitlyRemovedWindowIDs: [closedID],
      state: &state
    )
    reconcileWindows(orderedWindows(in: state), config: Config(), state: &state)

    #expect(columnWindowIDs(in: state) == (1...4).filter { $0 != closed }.map { [UInt64($0)] })
  }

  @Test(arguments: [1, 2], [false, true])
  func `Closing a sibling keeps its column in the logical order`(
    closed: Int, bothFullscreen: Bool
  ) throws {
    var state = try makeState(windowCount: 5)
    state.monitors[0].workspaces[0].columns[0].windows.append(WindowID(rawValue: 2))
    state.monitors[0].workspaces[0].columns.remove(at: 1)
    let fullscreenIDs = Set((bothFullscreen ? [1, 2, 3] : [1, 3]).map {
      WindowID(rawValue: UInt64($0))
    })
    let closedID = WindowID(rawValue: UInt64(closed))
    for ids: Set<WindowID> in [[WindowID(rawValue: 3)], fullscreenIDs] {
      reconcileWindows(
        orderedWindows(in: state),
        config: Config(),
        nativeFullscreenWindowIDs: ids,
        state: &state
      )
    }
    reconcileWindows(
      orderedWindows(in: state).filter { $0.id != closedID },
      config: Config(),
      nativeFullscreenWindowIDs: fullscreenIDs,
      explicitlyRemovedWindowIDs: [closedID],
      state: &state
    )
    reconcileWindows(orderedWindows(in: state), config: Config(), state: &state)

    #expect(columnWindowIDs(in: state) == [[UInt64(closed == 1 ? 2 : 1)], [3], [4], [5]])
  }

  private func makeState(config: Config = Config(), windowCount: Int = 3) throws -> RuntimeState {
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    for id in 1...windowCount {
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
