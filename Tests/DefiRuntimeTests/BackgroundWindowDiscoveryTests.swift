import DefiConfig
import DefiModel
import DefiRuntime
import Testing

struct BackgroundWindowDiscoveryTests {
  @Test
  func initialColumnWidthAppliesOnlyToNewTiledWindows() throws {
    let monitorID = MonitorID(rawValue: 1)
    var config = Config(rules: [Rule(appID: "device", initialColumnWidth: 0.44)])
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1), appID: "device", title: "Phone",
      frame: Rect(x: 0, y: 0, width: 824, height: 800), monitorID: monitorID
    )
    try discoverWindow(window, decision: config.decision(for: window), state: &state)
    #expect(state.monitors[0].workspaces[0].columns[0].width == .fraction(0.44))
    state.monitors[0].workspaces[0].columns[0].width = .pixels(900)
    config.rules[0].initialColumnWidth = 0.6
    reconcileWindows([window], config: config, state: &state)
    #expect(state.monitors[0].workspaces[0].columns[0].width == .pixels(900))
    state = RuntimeState(config: config, topology: state.topology)
    reconcileWindows([window], config: config, state: &state)
    #expect(state.monitors[0].workspaces[0].columns[0].width == .pixels(900))

    let other = Window(
      id: WindowID(rawValue: 2), appID: "other", title: "Other",
      frame: window.frame, monitorID: monitorID
    )
    try discoverWindow(other, decision: config.decision(for: other), state: &state)
    #expect(state.monitors[0].workspaces[0].columns.last?.width == .fraction(config.layout.defaultColumnWidth))

    let floating = Window(
      id: WindowID(rawValue: 3), appID: "device", title: "Floating",
      frame: window.frame, monitorID: monitorID
    )
    try discoverWindow(
      floating, decision: RuleDecision(floating: true, initialColumnWidth: 0.6), state: &state
    )
    #expect(state.windows[floating.id]?.frame == floating.frame)
    #expect(state.monitors[0].workspaces[0].columns.count == 2)
    #expect(state.monitors[0].workspaces[0].floatingWindows == [floating.id])
  }

  @Test
  func followFocusRuleDoesNotActivateUnfocusedBackgroundWindow() throws {
    let monitorID = MonitorID(rawValue: 1)
    let tools = WorkspaceID(rawValue: "tools")
    let config = Config(
      workspaces: WorkspacesConfig(names: ["dev", tools.rawValue]),
      rules: [Rule(appID: "proxy", workspace: tools.rawValue, followFocus: true)]
    )
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let selectedWindow = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "Selected",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      processID: 7,
      monitorID: monitorID
    )
    let backgroundWindow = Window(
      id: WindowID(rawValue: 2),
      appID: "proxy",
      title: "Background",
      frame: Rect(x: 600, y: 0, width: 600, height: 800),
      processID: 42,
      monitorID: monitorID
    )
    try discoverWindow(
      selectedWindow,
      decision: RuleDecision(followFocus: true),
      isNativelyFocused: true,
      state: &state
    )

    reconcileWindows(
      [selectedWindow, backgroundWindow],
      config: config,
      nativeFocusedWindowID: selectedWindow.id,
      frontmostProcessID: 7,
      state: &state
    )

    #expect(state.monitors[0].activeWorkspace.rawValue == "dev")
    #expect(state.selectedWindowID(on: monitorID) == selectedWindow.id)
    #expect(state.location(containing: backgroundWindow.id)?.workspaceID == tools)
  }

  @Test
  func tiledWindowDiscoveredWithoutFollowFocusPreservesSelectionAndScroll() throws {
    let monitorID = MonitorID(rawValue: 1)
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    let selectedWindow = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "Selected",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )
    let backgroundWindow = Window(
      id: WindowID(rawValue: 2),
      appID: "mail",
      title: "Background",
      frame: Rect(x: 600, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )

    try discoverWindow(
      selectedWindow,
      decision: RuleDecision(followFocus: true),
      isNativelyFocused: true,
      state: &state
    )
    state.monitors[0].workspaces[0].scrollOffset = 0.25
    state.monitors[0].workspaces[0].targetScrollOffset = 0.25

    try discoverWindow(backgroundWindow, decision: RuleDecision(), state: &state)

    #expect(state.selectedWindowID(on: monitorID) == selectedWindow.id)
    #expect(state.monitors[0].workspaces[0].scrollOffset == 0.25)
    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 0.25)
  }

  @Test
  func frontmostApplicationSpawnFollowsSelectedWindowAndTakesFocus() throws {
    let monitorID = MonitorID(rawValue: 1)
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    let windows = (1...3).map { rawValue in
      Window(
        id: WindowID(rawValue: UInt64(rawValue)),
        appID: "terminal",
        title: "Window \(rawValue)",
        frame: Rect(x: Double(rawValue - 1) * 600, y: 0, width: 600, height: 800),
        processID: 42,
        monitorID: monitorID
      )
    }
    try discoverWindow(
      windows[0],
      decision: RuleDecision(followFocus: true),
      isNativelyFocused: true,
      state: &state
    )
    try discoverWindow(windows[1], decision: RuleDecision(), state: &state)

    reconcileWindows(
      windows,
      config: Config(),
      frontmostProcessID: 42,
      state: &state
    )

    let workspace = state.monitors[0].workspaces[0]
    #expect(
      workspace.columns.map(\.windows)
        == [[windows[0].id], [windows[2].id], [windows[1].id]]
    )
    #expect(state.selectedWindowID(on: monitorID) == windows[2].id)
  }
}
