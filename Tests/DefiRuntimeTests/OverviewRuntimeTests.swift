import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing

struct OverviewRuntimeTests {
  let firstMonitor = MonitorID(rawValue: 1)
  let secondMonitor = MonitorID(rawValue: 2)
  let firstWorkspace = WorkspaceID(rawValue: "1")
  let secondWorkspace = WorkspaceID(rawValue: "2")
  let remoteWorkspace = WorkspaceID(rawValue: "remote")

  @Test func overviewFloatingSelectionCannotEditAnUnrelatedTiledColumn() throws {
    var state = makeState()
    let id = WindowID(rawValue: 99)
    var floating = window(id, monitorID: firstMonitor)
    floating.floating = true
    state.windows[id] = floating
    state.monitors[0].workspaces[0].floatingWindows = [id]
    let original = state
    #expect(throws: OverviewRuntimeError.invalidDropTarget) {
      try applyOverviewLayoutCommand(.cycleWidth(.next), intent: OverviewWindowIntent(
        windowID: id, expectedAppID: "app", sourceMonitorID: firstMonitor,
        sourceWorkspaceID: firstWorkspace), viewports: [:], state: &state)
    }
    #expect(state == original)
  }

  @Test func overviewWidthEditClearsNativeFullscreenWidthReset() throws {
    var state = makeState()
    let id = WindowID(rawValue: 99)
    state.windows[id] = window(id, monitorID: firstMonitor)
    state.monitors[0].workspaces[0].columns = [Column(window: id, width: .fraction(0.5))]
    state.pendingNativeFullscreenWidthResetWindowIDs.insert(id)
    try applyOverviewLayoutCommand(.cycleWidth(.next), intent: OverviewWindowIntent(
      windowID: id, expectedAppID: "app", sourceMonitorID: firstMonitor,
      sourceWorkspaceID: firstWorkspace), viewports: [:], state: &state)
    #expect(!state.pendingNativeFullscreenWidthResetWindowIDs.contains(id))
  }

  @Test(arguments: [Command.cycleWidth(.next), .maximizeColumn, .moveColumn(.right), .unjoinWindows])
  func layoutEditUsesOverviewSelectionWithoutActivatingItsWorkspace(command: Command) throws {
    var state = makeState()
    let ids = (11...13).map { WindowID(rawValue: UInt64($0)) }
    state.monitors[0].workspaces[1].columns = ids.map { Column(window: $0, width: .fraction(0.5)) }
    if command == .unjoinWindows {
      state.monitors[0].workspaces[1].columns = [
        Column(windows: [ids[0], ids[1]], focusedWindow: 0, width: .fraction(0.5)),
        Column(window: ids[2], width: .fraction(0.5))]
    }
    for id in ids { state.windows[id] = window(id, monitorID: firstMonitor) }
    let originalMonitor = state.monitors[0]
    let intent = OverviewWindowIntent(windowID: ids[1], expectedAppID: "app",
      sourceMonitorID: firstMonitor, sourceWorkspaceID: secondWorkspace)
    try applyOverviewLayoutCommand(command, intent: intent,
      viewports: [firstMonitor: Rect(x: 0, y: 0, width: 1_000, height: 800)], state: &state)
    #expect(state.monitors[0].activeWorkspace == originalMonitor.activeWorkspace)
    #expect(state.monitors[0].workspaces[0] == originalMonitor.workspaces[0])
    #expect(state.monitors[1] == makeState().monitors[1])
    let edited = state.monitors[0].workspaces[1]
    if command == .moveColumn(.right) {
      #expect(edited.columns.map(\.windows) == [[ids[0]], [ids[2]], [ids[1]]])
    } else if command == .unjoinWindows {
      #expect(edited.columns.map(\.windows) == [[ids[0]], [ids[1]], [ids[2]]])
    } else if command == .cycleWidth(.next) || command == .maximizeColumn {
      #expect(edited.columns[1].width != originalMonitor.workspaces[1].columns[1].width)
      #expect(edited.columns[0].width == originalMonitor.workspaces[1].columns[0].width)
    }
    let beforeStale = state
    #expect(throws: OverviewRuntimeError.staleWindow(ids[1])) {
      try applyOverviewLayoutCommand(command,
        intent: OverviewWindowIntent(windowID: ids[1], expectedAppID: "other",
          sourceMonitorID: firstMonitor, sourceWorkspaceID: secondWorkspace),
        viewports: [:], state: &state)
    }
    #expect(state == beforeStale)
  }

  @Test
  func `Commits overview ribbon positions once without touching other workspaces`() {
    var state = makeState()

    let changed = applyOverviewScrollOffsets(
      [firstMonitor: [firstWorkspace: 0.5]],
      state: &state
    )

    #expect(changed == Set([firstMonitor]))
    #expect(state.monitors[0].workspaces[0].scrollOffset == 0.5)
    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 0.5)
    #expect(state.monitors[0].workspaces[1].scrollOffset == 0)
    #expect(state.monitors[1].workspaces[0].scrollOffset == 0)
    #expect(
      applyOverviewScrollOffsets(
        [firstMonitor: [firstWorkspace: 0.5]],
        state: &state
      ).isEmpty
    )
  }

  @Test
  func `Moves a tiled window to an exact stack atomically`() throws {
    let moving = WindowID(rawValue: 1)
    let target = WindowID(rawValue: 2)
    var state = makeState()
    state.monitors[0].workspaces[0].columns = [
      Column(window: moving, width: .fraction(0.8))
    ]
    state.monitors[0].workspaces[1].columns = [
      Column(window: target, width: .fraction(0.5))
    ]
    state.windows[moving] = window(moving, monitorID: firstMonitor)
    state.windows[target] = window(target, monitorID: firstMonitor)

    let result = try applyOverviewDrop(
      intent(for: moving),
      target: .stack(
        monitorID: firstMonitor,
        workspaceID: secondWorkspace,
        columnIndex: 0,
        windowIndex: 1
      ),
      viewports: [firstMonitor: Rect(x: 0, y: 0, width: 1_000, height: 800)],
      state: &state
    )

    #expect(state.monitors[0].workspaces[0].columns.isEmpty)
    #expect(state.monitors[0].workspaces[1].columns[0].windows == [target, moving])
    #expect(state.monitors[0].activeWorkspace == secondWorkspace)
    #expect(result.focusedWindowID == moving)

    let layout = computeLayout(
      workspace: state.monitors[0].workspaces[1],
      viewport: Rect(x: 0, y: 0, width: 1_000, height: 800),
      windows: Array(state.windows.values),
      settings: LayoutSettings(
        innerHorizontalGap: 0,
        innerVerticalGap: 0,
        outerTopGap: 0,
        outerRightGap: 0,
        outerBottomGap: 0,
        outerLeftGap: 0
      )
    )
    #expect(
      layout.map(\.frame) == [
        Rect(x: 0, y: 0, width: 500, height: 400),
        Rect(x: 0, y: 400, width: 500, height: 400),
      ])
  }

  @Test
  func `Dropping a sole window onto its own card keeps its column`() throws {
    let moving = WindowID(rawValue: 1)
    let neighbor = WindowID(rawValue: 2)
    var state = makeState()
    state.monitors[0].workspaces[0].columns = [
      Column(window: moving, width: .fraction(0.8)),
      Column(window: neighbor, width: .fraction(0.5)),
    ]
    state.windows[moving] = window(moving, monitorID: firstMonitor)
    state.windows[neighbor] = window(neighbor, monitorID: firstMonitor)

    _ = try applyOverviewDrop(
      intent(for: moving),
      target: .stack(
        monitorID: firstMonitor,
        workspaceID: firstWorkspace,
        columnIndex: 0,
        windowIndex: 1
      ),
      viewports: [firstMonitor: Rect(x: 0, y: 0, width: 1_000, height: 800)],
      state: &state
    )

    #expect(
      state.monitors[0].workspaces[0].columns.map(\.windows) == [
        [moving], [neighbor],
      ])
  }

  @Test
  func `Rejects stale and fullscreen drops without mutation`() {
    let moving = WindowID(rawValue: 1)
    var state = makeState()
    state.monitors[0].workspaces[0].columns = [
      Column(window: moving, width: .fraction(0.8))
    ]
    state.windows[moving] = window(moving, monitorID: firstMonitor)
    state.nativeFullscreenWindowIDs = [moving]
    let before = state

    #expect(throws: OverviewRuntimeError.nativeFullscreen(moving)) {
      try applyOverviewDrop(
        intent(for: moving),
        target: .newColumn(
          monitorID: firstMonitor,
          workspaceID: secondWorkspace,
          columnIndex: 0
        ),
        viewports: [:],
        state: &state
      )
    }
    #expect(state == before)

    var stale = before
    stale.nativeFullscreenWindowIDs = []
    let staleBefore = stale
    #expect(throws: OverviewRuntimeError.staleSource(moving)) {
      try applyOverviewDrop(
        OverviewWindowIntent(
          windowID: moving,
          expectedAppID: "app",
          sourceMonitorID: firstMonitor,
          sourceWorkspaceID: secondWorkspace
        ),
        target: .newColumn(
          monitorID: firstMonitor,
          workspaceID: secondWorkspace,
          columnIndex: 0
        ),
        viewports: [:],
        state: &stale
      )
    }
    #expect(stale == staleBefore)
  }

  @Test
  func `Floating cross monitor drop retains classification and frame`() throws {
    let moving = WindowID(rawValue: 1)
    var state = makeState()
    state.monitors[0].workspaces[0].floatingWindows = [moving]
    state.windows[moving] = Window(
      id: moving,
      appID: "app",
      title: "window",
      frame: Rect(x: 100, y: 100, width: 300, height: 200),
      monitorID: firstMonitor,
      floating: true
    )

    let result = try applyOverviewDrop(
      intent(for: moving),
      target: .floating(
        monitorID: secondMonitor,
        workspaceID: remoteWorkspace,
        relativeFrame: Rect(x: 0.25, y: 0.25, width: 0.3, height: 0.25)
      ),
      viewports: [
        firstMonitor: Rect(x: 0, y: 0, width: 1_000, height: 800),
        secondMonitor: Rect(x: 1_000, y: 0, width: 2_000, height: 1_200),
      ],
      state: &state
    )

    #expect(state.windows[moving]?.floating == true)
    #expect(state.windows[moving]?.monitorID == secondMonitor)
    #expect(state.monitors[1].workspaces[0].floatingWindows == [moving])
    #expect(
      result.floatingFrameUpdates[moving]
        == Rect(x: 1_500, y: 300, width: 600, height: 300)
    )
  }

  @Test
  func `Floating drop follows topology and clamps the logical frame`() throws {
    let moving = WindowID(rawValue: 1)
    var state = makeState()
    state.monitors[0].workspaces[0].floatingWindows = [moving]
    state.windows[moving] = Window(
      id: moving,
      appID: "app",
      title: "window",
      frame: Rect(x: -9_000, y: -9_000, width: 300, height: 200),
      monitorID: firstMonitor,
      floating: true,
      forceTiling: true
    )

    let result = try applyOverviewDrop(
      intent(for: moving),
      target: .floating(
        monitorID: secondMonitor,
        workspaceID: remoteWorkspace,
        relativeFrame: Rect(x: 0.9, y: -0.2, width: 0.3, height: 0.25)
      ),
      viewports: [
        firstMonitor: Rect(x: 0, y: 0, width: 1_000, height: 800),
        secondMonitor: Rect(x: 1_000, y: 0, width: 2_000, height: 1_200),
      ],
      state: &state
    )

    #expect(
      result.floatingFrameUpdates[moving]
        == Rect(x: 2_400, y: 0, width: 600, height: 300)
    )
  }

  @Test
  func `Owner move carries its transient but transient cannot move alone`() throws {
    let owner = WindowID(rawValue: 1)
    let transient = WindowID(rawValue: 2)
    var state = makeState()
    state.monitors[0].workspaces[0].columns = [
      Column(window: owner, width: .fraction(0.8))
    ]
    state.monitors[0].workspaces[0].floatingWindows = [transient]
    state.windows[owner] = window(owner, monitorID: firstMonitor)
    state.windows[transient] = Window(
      id: transient,
      appID: "app",
      title: "dialog",
      frame: Rect(x: -9_000, y: -9_000, width: 300, height: 200),
      transientOwnerID: owner,
      monitorID: firstMonitor,
      floating: true
    )

    #expect(throws: OverviewRuntimeError.transientWindow(transient)) {
      try applyOverviewDrop(
        intent(for: transient),
        target: .floating(
          monitorID: firstMonitor,
          workspaceID: secondWorkspace,
          relativeFrame: Rect(x: 0.2, y: 0.2, width: 0.3, height: 0.25)
        ),
        viewports: [firstMonitor: Rect(x: 0, y: 0, width: 1_000, height: 800)],
        state: &state
      )
    }

    let result = try applyOverviewDrop(
      intent(for: owner),
      target: .newColumn(
        monitorID: firstMonitor,
        workspaceID: secondWorkspace,
        columnIndex: 0
      ),
      viewports: [firstMonitor: Rect(x: 0, y: 0, width: 1_000, height: 800)],
      floatingFrames: [
        transient: Rect(x: 200, y: 200, width: 300, height: 200)
      ],
      state: &state
    )
    #expect(state.monitors[0].workspaces[1].columns[0].windows == [owner])
    #expect(state.monitors[0].workspaces[1].floatingWindows == [transient])
    #expect(
      result.floatingFrameUpdates[transient]
        == Rect(x: 200, y: 200, width: 300, height: 200)
    )
  }

  @Test
  func `Logical overview restores fullscreen stacks without changing runtime state`() {
    var state = makeState()
    let first = WindowID(rawValue: 1)
    let fullscreen = WindowID(rawValue: 2)
    let removed = WindowID(rawValue: 3)
    let floating = WindowID(rawValue: 4)
    let column = Column(
      windows: [first, fullscreen, removed], focusedWindow: 1,
      width: .pixels(420), preMaximizedWidth: .fraction(0.5)
    )
    for id in [first, fullscreen, removed, floating] {
      state.windows[id] = window(id, monitorID: firstMonitor)
    }
    state.windows[floating]?.floating = true
    state.monitors[0].workspaces[0].columns = [column]
    state.monitors[0].workspaces[0].floatingWindows = [floating]
    let config = Config(workspaces: WorkspacesConfig(names: ["1", "2", "remote"]))
    reconcileWindows(
      [first, fullscreen, removed, floating].compactMap { state.windows[$0] },
      config: config,
      nativeFullscreenWindowIDs: [fullscreen, floating],
      state: &state
    )
    state.windows[removed] = nil
    state.monitors[0].workspaces[0].scrollOffset = 45
    state.monitors[0].workspaces[0].targetScrollOffset = 80
    let original = state
    let projected = logicalOverviewMonitors(state: state)
    let workspace = projected[0].workspaces[0]

    #expect(workspace.columns.count == 1)
    #expect(workspace.columns[0].windows == [first, fullscreen])
    #expect(workspace.columns[0].width == .pixels(420))
    #expect(workspace.columns[0].preMaximizedWidth == .fraction(0.5))
    #expect(workspace.columns[0].focusedWindow == 1)
    #expect(workspace.floatingWindows == [floating])
    #expect(workspace.scrollOffset == 45)
    #expect(workspace.targetScrollOffset == 80)
    #expect(projected[1] == original.monitors[1])
    #expect(state == original)
  }

  private func makeState() -> RuntimeState {
    var state = RuntimeState(
      config: Config(
        workspaces: WorkspacesConfig(
          names: ["1", "2", "remote"],
          defaultName: "1",
          monitors: ["remote": 2]
        )
      )
    )
    state.attachMonitor(firstMonitor)
    state.attachMonitor(secondMonitor)
    return state
  }

  private func window(_ id: WindowID, monitorID: MonitorID) -> Window {
    Window(
      id: id,
      appID: "app",
      title: "window",
      frame: Rect(x: 0, y: 0, width: 800, height: 800),
      monitorID: monitorID
    )
  }

  private func intent(for id: WindowID) -> OverviewWindowIntent {
    OverviewWindowIntent(
      windowID: id,
      expectedAppID: "app",
      sourceMonitorID: firstMonitor,
      sourceWorkspaceID: firstWorkspace
    )
  }
}
