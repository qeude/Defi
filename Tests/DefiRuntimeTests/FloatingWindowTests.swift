import DefiConfig
import DefiModel
import Testing

@testable import DefiRuntime

struct FloatingWindowTests {
  private let monitorID = MonitorID(rawValue: 1)

  @Test
  func `Floating layer activation and cycling wrap`() throws {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    let tiled = window(40)
    let floaters = [window(41, floating: true), window(42, floating: true)]
    try discoverWindow(tiled, decision: RuleDecision(), state: &state)
    for floater in floaters {
      try discoverWindow(floater, decision: RuleDecision(), state: &state)
    }

    #expect(state.selectedWindowID(on: monitorID) == tiled.id)
    try reduce(.activateFloating, on: monitorID, state: &state)
    #expect(state.selectedWindowID(on: monitorID) == floaters[0].id)
    try reduce(.focusFloating(.previous), on: monitorID, state: &state)
    #expect(state.selectedWindowID(on: monitorID) == floaters[1].id)
    try reduce(.focusFloating(.next), on: monitorID, state: &state)
    #expect(state.selectedWindowID(on: monitorID) == floaters[0].id)
  }

  @Test(arguments: [
    Command.focusColumn(.next),
    .focusWindow(.next),
    .cycleWidth(.next),
    .maximizeColumn,
  ])
  func `Tiled commands preserve focused floater without columns`(
    command: Command
  ) throws {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    let floaters = [window(43, floating: true), window(44, floating: true)]
    for floater in floaters {
      try discoverWindow(floater, decision: RuleDecision(), state: &state)
    }
    try reduce(.activateFloating, on: monitorID, state: &state)
    try reduce(.focusFloating(.next), on: monitorID, state: &state)

    try reduce(command, on: monitorID, state: &state)

    #expect(state.selectedWindowID(on: monitorID) == floaters[1].id)
    #expect(state.monitors[0].workspaces[0].focusedLayer == .floating)
  }

  @Test
  func `Toggle floating uses fallback selected floater without columns`() throws {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    let floaters = [window(50, floating: true), window(51, floating: true)]
    for floater in floaters {
      try discoverWindow(floater, decision: RuleDecision(), state: &state)
    }
    state.monitors[0].workspaces[0].focusedLayer = .tiled
    state.monitors[0].workspaces[0].focusedFloatingWindow = 1

    try reduce(.toggleFloating, on: monitorID, state: &state)

    #expect(state.monitors[0].workspaces[0].floatingWindows == [floaters[0].id])
    #expect(state.monitors[0].workspaces[0].columns[0].windows == [floaters[1].id])
    #expect(state.windows[floaters[1].id]?.floatingOrigin == .user)
  }

  @Test
  func `Tiling last focused floater clamps remaining selection`() throws {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    let floaters = [window(52, floating: true), window(53, floating: true)]
    for floater in floaters {
      try discoverWindow(floater, decision: RuleDecision(), state: &state)
    }
    try reduce(.activateFloating, on: monitorID, state: &state)
    try reduce(.focusFloating(.next), on: monitorID, state: &state)

    try reduce(.toggleFloating, on: monitorID, state: &state)
    try reduce(.activateFloating, on: monitorID, state: &state)

    #expect(state.monitors[0].workspaces[0].focusedFloatingWindow == 0)
    #expect(state.selectedWindowID(on: monitorID) == floaters[0].id)
  }

  @Test
  func `Floating focus command requires valid floating selection`() {
    let tiled = WindowID(rawValue: 70)
    let floating = WindowID(rawValue: 71)

    #expect(
      commandShouldFocusWindow(
        .activateFloating,
        previousSelectedWindowID: tiled,
        selectedWindowID: tiled,
        selectedFloatingWindowID: nil
      ) == false)
    #expect(
      commandShouldFocusWindow(
        .focusFloating(.next),
        previousSelectedWindowID: floating,
        selectedWindowID: floating,
        selectedFloatingWindowID: floating
      ))
  }

  @Test
  func `Native floating focus activates its workspace`() throws {
    let tools = WorkspaceID(rawValue: "tools")
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev", tools.rawValue]))
    )
    state.attachMonitor(monitorID)
    let floater = window(60, floating: true)
    try discoverWindow(
      floater,
      decision: RuleDecision(workspace: tools),
      state: &state
    )

    #expect(focusWindow(floater.id, state: &state))
    #expect(state.monitors[0].activeWorkspace == tools)
    #expect(state.selectedWindowID(on: monitorID) == floater.id)
  }

  @Test
  func `Move focused floater preserves layer`() throws {
    let tools = WorkspaceID(rawValue: "tools")
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev", tools.rawValue]))
    )
    state.attachMonitor(monitorID)
    let floater = window(61, floating: true)
    try discoverWindow(floater, decision: RuleDecision(), state: &state)
    try reduce(.activateFloating, on: monitorID, state: &state)
    state.suspendedTiledPlacements[floater.id] = SuspendedTiledPlacement(
      monitorID: monitorID,
      workspaceID: state.monitors[0].activeWorkspace,
      columnIndex: 0,
      windowIndex: 0,
      column: Column(window: floater.id, width: .pixels(900))
    )

    try reduce(.moveWindowToWorkspace(tools), on: monitorID, state: &state)

    #expect(state.monitors[0].activeWorkspace == tools)
    #expect(state.monitors[0].workspaces[1].floatingWindows == [floater.id])
    #expect(state.selectedWindowID(on: monitorID) == floater.id)
    #expect(state.suspendedTiledPlacements[floater.id] == nil)
  }

  @Test
  func `Move focused tile selects tiled layer in target workspace`() throws {
    let tools = WorkspaceID(rawValue: "tools")
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev", tools.rawValue]))
    )
    state.attachMonitor(monitorID)
    let tile = window(68)
    let floater = window(69, floating: true)
    try discoverWindow(tile, decision: RuleDecision(), state: &state)
    try discoverWindow(
      floater,
      decision: RuleDecision(workspace: tools, followFocus: true),
      isNativelyFocused: true,
      state: &state
    )
    try reduce(.switchWorkspace(WorkspaceID(rawValue: "dev")), on: monitorID, state: &state)

    try reduce(.moveWindowToWorkspace(tools), on: monitorID, state: &state)

    #expect(state.monitors[0].activeWorkspace == tools)
    #expect(state.monitors[0].workspaces[1].focusedLayer == .tiled)
    #expect(state.selectedWindowID(on: monitorID) == tile.id)
  }

  @Test
  func `Move fallback selected floater without columns`() throws {
    let tools = WorkspaceID(rawValue: "tools")
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev", tools.rawValue]))
    )
    state.attachMonitor(monitorID)
    let floater = window(62, floating: true)
    try discoverWindow(floater, decision: RuleDecision(), state: &state)
    #expect(state.monitors[0].workspaces[0].focusedLayer == .tiled)

    try reduce(.moveWindowToWorkspace(tools), on: monitorID, state: &state)

    #expect(state.monitors[0].activeWorkspace == tools)
    #expect(state.monitors[0].workspaces[0].floatingWindows.isEmpty)
    #expect(state.monitors[0].workspaces[1].floatingWindows == [floater.id])
    #expect(state.selectedWindowID(on: monitorID) == floater.id)
  }

  @Test
  func `Follow focus selects new floating window`() throws {
    let tools = WorkspaceID(rawValue: "tools")
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev", tools.rawValue]))
    )
    state.attachMonitor(monitorID)
    let first = window(63, floating: true)
    let followed = window(64, floating: true)
    try discoverWindow(
      first,
      decision: RuleDecision(workspace: tools),
      state: &state
    )

    try discoverWindow(
      followed,
      decision: RuleDecision(workspace: tools, followFocus: true),
      isNativelyFocused: true,
      state: &state
    )

    #expect(state.monitors[0].activeWorkspace == tools)
    #expect(state.monitors[0].workspaces[1].focusedLayer == .floating)
    #expect(state.selectedWindowID(on: monitorID) == followed.id)
  }

  @Test
  func `Follow focus selects new tiled window from floating layer`() throws {
    let tools = WorkspaceID(rawValue: "tools")
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev", tools.rawValue]))
    )
    state.attachMonitor(monitorID)
    let floater = window(65, floating: true)
    try discoverWindow(
      floater,
      decision: RuleDecision(workspace: tools, followFocus: true),
      isNativelyFocused: true,
      state: &state
    )

    let followed = window(66)
    try discoverWindow(
      followed,
      decision: RuleDecision(workspace: tools, followFocus: true),
      isNativelyFocused: true,
      state: &state
    )

    #expect(state.monitors[0].activeWorkspace == tools)
    #expect(state.monitors[0].workspaces[1].focusedLayer == .tiled)
    #expect(state.selectedWindowID(on: monitorID) == followed.id)
  }

  @Test
  func `Automatic floater reclassifies as tiled without stealing focus`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let selectedTile = window(72)
    var automatic = window(73, floating: true)
    automatic.floatingOrigin = .automatic
    try discoverWindow(selectedTile, decision: RuleDecision(), state: &state)
    try discoverWindow(automatic, decision: RuleDecision(), state: &state)
    var observed = automatic
    observed.floating = false
    observed.floatingOrigin = nil

    reconcileWindows([selectedTile, observed], config: config, state: &state)

    let workspace = state.monitors[0].workspaces[0]
    #expect(workspace.floatingWindows.isEmpty)
    #expect(workspace.columns.flatMap(\.windows) == [selectedTile.id, automatic.id])
    #expect(state.windows[automatic.id]?.floating == false)
    #expect(state.windows[automatic.id]?.floatingOrigin == nil)
    #expect(state.selectedWindowID(on: monitorID) == selectedTile.id)
  }

  @Test
  func `Existing tile becoming modal reclassifies as automatic floater`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let selectedTile = window(77)
    let modalTile = window(78)
    try discoverWindow(selectedTile, decision: RuleDecision(), state: &state)
    try discoverWindow(modalTile, decision: RuleDecision(), state: &state)
    focusWindow(selectedTile.id, state: &state)
    var observed = modalTile
    observed.floating = true
    observed.floatingOrigin = .automatic

    reconcileWindows([selectedTile, observed], config: config, state: &state)

    let workspace = state.monitors[0].workspaces[0]
    #expect(workspace.floatingWindows == [modalTile.id])
    #expect(workspace.columns.flatMap(\.windows) == [selectedTile.id])
    #expect(state.windows[modalTile.id]?.floating == true)
    #expect(state.windows[modalTile.id]?.floatingOrigin == .automatic)
    #expect(state.selectedWindowID(on: monitorID) == selectedTile.id)
  }

  @Test
  func `Temporary modal restores stack and column width`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let sibling = window(82)
    let modal = window(83)
    try discoverWindow(sibling, decision: RuleDecision(), state: &state)
    try discoverWindow(modal, decision: RuleDecision(), state: &state)
    var workspace = state.monitors[0].workspaces[0]
    workspace.columns = [
      Column(
        windows: [sibling.id, modal.id],
        focusedWindow: 0,
        width: .pixels(913),
        preMaximizedWidth: .fraction(0.7)
      )
    ]
    state.monitors[0].workspaces[0] = workspace
    var observedModal = modal
    observedModal.floating = true
    observedModal.floatingOrigin = .automatic
    reconcileWindows([sibling, observedModal], config: config, state: &state)
    var observedTiled = modal
    observedTiled.floating = false
    observedTiled.floatingOrigin = nil

    reconcileWindows([sibling, observedTiled], config: config, state: &state)

    let restored = state.monitors[0].workspaces[0]
    #expect(restored.columns.count == 1)
    #expect(restored.columns[0].windows == [sibling.id, modal.id])
    #expect(restored.columns[0].width == .pixels(913))
    #expect(restored.columns[0].preMaximizedWidth == .fraction(0.7))
  }

  @Test
  func `Temporary modal preserves sibling width edits`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let sibling = window(84)
    let modal = window(85)
    try discoverWindow(sibling, decision: RuleDecision(), state: &state)
    try discoverWindow(modal, decision: RuleDecision(), state: &state)
    state.monitors[0].workspaces[0].columns = [
      Column(
        windows: [sibling.id, modal.id],
        focusedWindow: 0,
        width: .pixels(700)
      )
    ]
    var observedModal = modal
    observedModal.floating = true
    observedModal.floatingOrigin = .automatic
    reconcileWindows([sibling, observedModal], config: config, state: &state)
    state.monitors[0].workspaces[0].columns[0].width = .pixels(950)
    var observedTiled = modal
    observedTiled.floating = false
    observedTiled.floatingOrigin = nil

    reconcileWindows([sibling, observedTiled], config: config, state: &state)

    #expect(state.monitors[0].workspaces[0].columns[0].width == .pixels(950))
  }

  @Test
  func `Concurrent temporary modals restore original stack order`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let windows = [window(90), window(91), window(92)]
    for window in windows {
      try discoverWindow(window, decision: RuleDecision(), state: &state)
    }
    state.monitors[0].workspaces[0].columns = [
      Column(
        windows: windows.map(\.id),
        focusedWindow: 0,
        width: .fraction(state.layout.defaultColumnWidth)
      )
    ]

    var firstModal = windows[0]
    firstModal.floating = true
    firstModal.floatingOrigin = .automatic
    reconcileWindows([firstModal, windows[1], windows[2]], config: config, state: &state)
    var secondModal = windows[1]
    secondModal.floating = true
    secondModal.floatingOrigin = .automatic
    reconcileWindows([firstModal, secondModal, windows[2]], config: config, state: &state)
    var firstTiled = windows[0]
    firstTiled.floating = false
    reconcileWindows([firstTiled, secondModal, windows[2]], config: config, state: &state)
    var secondTiled = windows[1]
    secondTiled.floating = false
    reconcileWindows([firstTiled, secondTiled, windows[2]], config: config, state: &state)

    #expect(state.monitors[0].workspaces[0].columns[0].windows == windows.map(\.id))
  }

  @Test
  func `Concurrent standalone modals restore original column order`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let windows = [window(94), window(95), window(96)]
    for window in windows {
      try discoverWindow(window, decision: RuleDecision(), state: &state)
    }
    state.monitors[0].workspaces[0].columns = windows.map {
      Column(window: $0.id, width: .pixels(900))
    }

    var firstModal = windows[0]
    firstModal.floating = true
    firstModal.floatingOrigin = .automatic
    var secondModal = windows[1]
    secondModal.floating = true
    secondModal.floatingOrigin = .automatic
    reconcileWindows([firstModal, secondModal, windows[2]], config: config, state: &state)

    var firstTiled = windows[0]
    firstTiled.floating = false
    reconcileWindows([firstTiled, secondModal, windows[2]], config: config, state: &state)
    var secondTiled = windows[1]
    secondTiled.floating = false
    reconcileWindows([firstTiled, secondTiled, windows[2]], config: config, state: &state)

    #expect(state.monitors[0].workspaces[0].columns.map(\.windows) == windows.map { [$0.id] })
  }

  @Test
  func `Restored modal restores inactive column focus`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let windows = [window(97), window(98), window(99)]
    for window in windows {
      try discoverWindow(window, decision: RuleDecision(), state: &state)
    }
    state.monitors[0].workspaces[0].columns = [
      Column(window: windows[0].id, width: .pixels(900)),
      Column(
        windows: [windows[1].id, windows[2].id],
        focusedWindow: 1,
        width: .pixels(900)
      ),
    ]
    state.monitors[0].workspaces[0].focusedColumn = 0

    var modal = windows[2]
    modal.floating = true
    modal.floatingOrigin = .automatic
    reconcileWindows([windows[0], windows[1], modal], config: config, state: &state)
    modal.floating = false
    reconcileWindows([windows[0], windows[1], modal], config: config, state: &state)

    #expect(state.monitors[0].workspaces[0].columns[1].focusedWindow == 1)
    #expect(state.selectedWindowID(on: monitorID) == windows[0].id)
  }

  @Test
  func `Restored modal preserves newer focus inside its stack`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let windows = [window(100), window(101), window(102)]
    for item in windows {
      try discoverWindow(item, decision: RuleDecision(), state: &state)
    }
    state.monitors[0].workspaces[0].columns = [
      Column(
        windows: windows.map(\.id),
        focusedWindow: 0,
        width: .pixels(900)
      )
    ]
    state.monitors[0].workspaces[0].focusedColumn = 0

    var modal = windows[0]
    modal.floating = true
    modal.floatingOrigin = .automatic
    reconcileWindows([modal, windows[1], windows[2]], config: config, state: &state)
    state.monitors[0].workspaces[0].focusedLayer = .tiled
    state.monitors[0].workspaces[0].columns[0].focusedWindow = 1

    var restored = modal
    restored.floating = false
    restored.floatingOrigin = nil
    reconcileWindows(
      [restored, windows[1], windows[2]],
      config: config,
      state: &state
    )

    #expect(state.monitors[0].workspaces[0].columns[0].focusedWindow == 2)
    #expect(state.selectedWindowID(on: monitorID) == windows[2].id)
  }

  @Test
  func `Manual tiling clears suspended modal placement`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    var modal = window(93, floating: true)
    modal.floatingOrigin = .automatic
    try discoverWindow(modal, decision: RuleDecision(), state: &state)
    state.suspendedTiledPlacements[modal.id] = SuspendedTiledPlacement(
      monitorID: monitorID,
      workspaceID: state.monitors[0].activeWorkspace,
      columnIndex: 0,
      windowIndex: 0,
      column: Column(window: modal.id, width: .pixels(900))
    )

    try reduce(.toggleFloating, on: monitorID, state: &state)

    #expect(state.suspendedTiledPlacements[modal.id] == nil)
    #expect(state.windows[modal.id]?.floatingOrigin == .user)
  }

  @Test
  func `Restored modal keeps focused window identity after column shift`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let modal = window(86)
    let selected = window(87)
    try discoverWindow(modal, decision: RuleDecision(), state: &state)
    try discoverWindow(selected, decision: RuleDecision(), state: &state)
    focusWindow(selected.id, state: &state)
    var observedModal = modal
    observedModal.floating = true
    observedModal.floatingOrigin = .automatic
    reconcileWindows(
      [modal, selected].map { $0.id == modal.id ? observedModal : $0 }, config: config,
      state: &state)
    var observedTiled = modal
    observedTiled.floating = false
    observedTiled.floatingOrigin = nil

    reconcileWindows([observedTiled, selected], config: config, state: &state)

    #expect(state.selectedWindowID(on: monitorID) == selected.id)
    #expect(state.monitors[0].workspaces[0].columns.flatMap(\.windows) == [modal.id, selected.id])
  }

  @Test
  func `Focused tile becoming modal remains selected as floater`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let modalTile = window(79)
    try discoverWindow(modalTile, decision: RuleDecision(), state: &state)
    var observed = modalTile
    observed.floating = true
    observed.floatingOrigin = .automatic

    reconcileWindows([observed], config: config, state: &state)

    let workspace = state.monitors[0].workspaces[0]
    #expect(workspace.focusedLayer == .floating)
    #expect(state.selectedWindowID(on: monitorID) == modalTile.id)
  }

  @Test
  func `Manual tile override survives automatic floating observation`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    var manualTile = window(80)
    manualTile.floatingOrigin = .user
    try discoverWindow(manualTile, decision: RuleDecision(), state: &state)
    var observed = manualTile
    observed.floating = true
    observed.floatingOrigin = .automatic

    reconcileWindows([observed], config: config, state: &state)

    let workspace = state.monitors[0].workspaces[0]
    #expect(workspace.floatingWindows.isEmpty)
    #expect(workspace.columns.flatMap(\.windows) == [manualTile.id])
    #expect(state.windows[manualTile.id]?.floating == false)
    #expect(state.windows[manualTile.id]?.floatingOrigin == .user)
  }

  @Test
  func `Forced tile survives automatic floating observation`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    var forcedTile = window(81)
    forcedTile.forceTiling = true
    try discoverWindow(
      forcedTile,
      decision: RuleDecision(forceTiling: true),
      state: &state
    )
    var observed = forcedTile
    observed.floating = true
    observed.floatingOrigin = .automatic

    reconcileWindows([observed], config: config, state: &state)

    let workspace = state.monitors[0].workspaces[0]
    #expect(workspace.floatingWindows.isEmpty)
    #expect(workspace.columns.flatMap(\.windows) == [forcedTile.id])
    #expect(state.windows[forcedTile.id]?.floating == false)
    #expect(state.windows[forcedTile.id]?.forceTiling == true)
  }

  @Test
  func `Focused automatic floater remains selected when reclassified`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let selectedTile = window(74)
    var automatic = window(75, floating: true)
    automatic.floatingOrigin = .automatic
    try discoverWindow(selectedTile, decision: RuleDecision(), state: &state)
    try discoverWindow(automatic, decision: RuleDecision(), state: &state)
    focusWindow(automatic.id, state: &state)
    var observed = automatic
    observed.floating = false
    observed.floatingOrigin = nil

    reconcileWindows([selectedTile, observed], config: config, state: &state)

    #expect(state.monitors[0].workspaces[0].focusedLayer == .tiled)
    #expect(state.selectedWindowID(on: monitorID) == automatic.id)
  }

  @Test
  func `User floating override survives tiled observation`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    var userFloater = window(76, floating: true)
    userFloater.floatingOrigin = .user
    try discoverWindow(userFloater, decision: RuleDecision(), state: &state)
    var observed = userFloater
    observed.floating = false
    observed.floatingOrigin = nil

    reconcileWindows([observed], config: config, state: &state)

    #expect(state.monitors[0].workspaces[0].floatingWindows == [userFloater.id])
    #expect(state.windows[userFloater.id]?.floating == true)
    #expect(state.windows[userFloater.id]?.floatingOrigin == .user)
  }

  @Test
  func `Dragged floater moves to target monitor active workspace`() throws {
    let externalMonitorID = MonitorID(rawValue: 2)
    let tools = WorkspaceID(rawValue: "tools")
    var state = RuntimeState(
      config: Config(
        workspaces: WorkspacesConfig(
          names: ["dev", tools.rawValue],
          monitors: [tools.rawValue: 2]
        )
      )
    )
    state.attachMonitor(monitorID)
    state.attachMonitor(externalMonitorID)
    state.monitors[1].activeWorkspace = tools
    let floater = window(67, floating: true)
    try discoverWindow(floater, decision: RuleDecision(), state: &state)
    state.suspendedTiledPlacements[floater.id] = SuspendedTiledPlacement(
      monitorID: monitorID,
      workspaceID: state.monitors[0].activeWorkspace,
      columnIndex: 0,
      windowIndex: 0,
      column: Column(window: floater.id, width: .pixels(900))
    )

    #expect(moveFloatingWindow(floater.id, to: externalMonitorID, state: &state))

    #expect(state.monitors[0].workspaces[0].floatingWindows.isEmpty)
    #expect(state.monitors[0].workspaces[0].focusedLayer == .tiled)
    #expect(state.monitors[1].workspaces[0].floatingWindows == [floater.id])
    #expect(state.monitors[1].workspaces[0].focusedLayer == .floating)
    #expect(state.selectedWindowID(on: externalMonitorID) == floater.id)
    #expect(state.windows[floater.id]?.monitorID == externalMonitorID)
    #expect(state.suspendedTiledPlacements[floater.id] == nil)
  }

  private func window(_ rawValue: UInt64, floating: Bool = false) -> Window {
    Window(
      id: WindowID(rawValue: rawValue),
      appID: "app-\(rawValue)",
      title: "Window \(rawValue)",
      frame: Rect(x: 100, y: 100, width: 500, height: 300),
      monitorID: monitorID,
      floating: floating
    )
  }
}
