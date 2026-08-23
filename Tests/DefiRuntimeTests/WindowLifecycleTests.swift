import DefiConfig
import DefiModel
import DefiRuntime
import Testing

struct WindowLifecycleTests {
  private let monitorID = MonitorID(rawValue: 1)

  @Test
  func `Discovery uses rule workspace and follow focus`() throws {
    let config = Config(
      workspaces: WorkspacesConfig(names: ["dev", "web"]),
      rules: [Rule(appID: "browser", workspace: "web", followFocus: true)]
    )
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "browser",
      title: "Web",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )

    try discoverWindow(
      window,
      decision: config.decision(for: window),
      isNativelyFocused: true,
      state: &state
    )

    #expect(state.monitors[0].activeWorkspace == WorkspaceID(rawValue: "web"))
    #expect(state.monitors[0].workspaces[1].columns[0].windows == [window.id])
  }

  @Test
  func `Transient inherits owners workspace without activating it`() throws {
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let owner = Window(
      id: WindowID(rawValue: 1),
      appID: "finder",
      title: "Trash",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )
    try discoverWindow(
      owner,
      decision: RuleDecision(workspace: WorkspaceID(rawValue: "web")),
      state: &state
    )
    let dialog = Window(
      id: WindowID(rawValue: 2),
      appID: "finder",
      title: "Empty Trash?",
      frame: Rect(x: 100, y: 100, width: 300, height: 200),
      transientOwnerID: owner.id,
      isModal: true,
      monitorID: monitorID,
      floating: true,
      floatingOrigin: .automatic
    )

    try discoverWindow(dialog, decision: RuleDecision(), state: &state)

    #expect(state.monitors[0].activeWorkspace == WorkspaceID(rawValue: "dev"))
    #expect(state.location(containing: dialog.id)?.workspaceID == WorkspaceID(rawValue: "web"))
  }

  @Test
  func `Background transient ignores follow focus rule`() throws {
    let web = WorkspaceID(rawValue: "web")
    let config = Config(
      workspaces: WorkspacesConfig(names: ["dev", web.rawValue]),
      rules: [Rule(appID: "finder", followFocus: true)]
    )
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let owner = Window(
      id: WindowID(rawValue: 1),
      appID: "finder",
      title: "Trash",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )
    try discoverWindow(owner, decision: RuleDecision(workspace: web), state: &state)
    let dialog = Window(
      id: WindowID(rawValue: 2),
      appID: "finder",
      title: "Empty Trash?",
      frame: Rect(x: 100, y: 100, width: 300, height: 200),
      transientOwnerID: owner.id,
      isModal: true,
      monitorID: monitorID,
      floating: true,
      floatingOrigin: .automatic
    )

    reconcileWindows([owner, dialog], config: config, state: &state)

    #expect(state.monitors[0].activeWorkspace == WorkspaceID(rawValue: "dev"))
    #expect(state.location(containing: dialog.id)?.workspaceID == web)

    reconcileWindows([owner], config: config, state: &state)
    reconcileWindows(
      [owner, dialog],
      config: config,
      nativeFocusedWindowID: dialog.id,
      state: &state
    )

    #expect(state.monitors[0].activeWorkspace == web)
  }

  @Test
  func `Move window to workspace follows`() throws {
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "Editor",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )
    try discoverWindow(window, decision: RuleDecision(), state: &state)

    try reduce(
      .moveWindowToWorkspace(WorkspaceID(rawValue: "web")),
      on: monitorID,
      state: &state
    )

    #expect(state.monitors[0].activeWorkspace == WorkspaceID(rawValue: "web"))
    #expect(state.monitors[0].workspaces[1].columns[0].windows == [window.id])
    #expect(state.monitors[0].workspaces[0].columns.isEmpty)
  }

  @Test
  func `Reconcile removes closed window`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "Editor",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )
    try discoverWindow(window, decision: RuleDecision(), state: &state)

    reconcileWindows([], config: config, state: &state)

    #expect(state.windows.isEmpty)
    #expect(state.monitors[0].workspaces[0].columns.isEmpty)
  }

  @Test
  func `Reconcile preserves intrinsic dimensions after applied gaps`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let initial = Window(
      id: WindowID(rawValue: 1),
      appID: "simulator",
      title: "Phone",
      frame: Rect(x: 0, y: 0, width: 320, height: 640),
      monitorID: monitorID,
      intrinsicSize: true
    )
    try discoverWindow(
      initial,
      decision: RuleDecision(intrinsicSize: true),
      state: &state
    )
    let observedAfterLayout = Window(
      id: initial.id,
      appID: initial.appID,
      title: initial.title,
      frame: Rect(x: 8, y: 8, width: 304, height: 624),
      monitorID: monitorID
    )

    reconcileWindows([observedAfterLayout], config: config, state: &state)

    #expect(state.windows[initial.id]?.frame.width == 320)
    #expect(state.windows[initial.id]?.frame.height == 640)
  }

  @Test
  func `Reconcile adopts external intrinsic resize`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let initial = Window(
      id: WindowID(rawValue: 1),
      appID: "simulator",
      title: "Phone",
      frame: Rect(x: 0, y: 0, width: 320, height: 640),
      monitorID: monitorID,
      intrinsicSize: true
    )
    try discoverWindow(
      initial,
      decision: RuleDecision(intrinsicSize: true),
      state: &state
    )
    let resized = Window(
      id: initial.id,
      appID: initial.appID,
      title: initial.title,
      frame: Rect(x: 0, y: 0, width: 430, height: 860),
      monitorID: monitorID
    )

    reconcileWindows(
      [resized],
      config: config,
      externallyChangedWindowIDs: [initial.id],
      state: &state
    )

    #expect(state.windows[initial.id]?.frame.width == 430)
    #expect(state.windows[initial.id]?.frame.height == 860)
  }

}
