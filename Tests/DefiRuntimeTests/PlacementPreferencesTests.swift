import DefiConfig
import DefiModel
import DefiRuntime
import Testing

struct PlacementPreferencesTests {
  private let monitorID = MonitorID(rawValue: 1)

  @Test
  func `Frontmost application spawn follows persisted workspace`() throws {
    let web = WorkspaceID(rawValue: "web")
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", web.rawValue]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let selected = Window(
      id: WindowID(rawValue: 1),
      appID: "com.example.Editor",
      title: "Editor",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      processID: 7,
      monitorID: monitorID
    )
    let launched = Window(
      id: WindowID(rawValue: 2),
      appID: "com.example.Chat",
      title: "Chat",
      frame: Rect(x: 600, y: 0, width: 600, height: 800),
      processID: 42,
      monitorID: monitorID
    )
    let preferences = PlacementPreferences(
      applications: [
        "com.example.chat": WindowPlacementPreference(
          workspaceID: web,
          monitorID: monitorID
        )
      ]
    )
    try discoverWindow(
      selected,
      decision: RuleDecision(followFocus: true),
      isNativelyFocused: true,
      state: &state
    )

    reconcileWindows(
      [selected, launched],
      config: config,
      placementPreferences: preferences,
      frontmostProcessID: 42,
      state: &state
    )

    #expect(state.monitors[0].activeWorkspace == web)
    #expect(state.selectedWindowID(on: monitorID) == launched.id)
  }

  @Test
  func `Reconcile restores persisted application workspace`() throws {
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "com.example.Chat",
      title: "Chat",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )
    let preferences = PlacementPreferences(
      applications: [
        "com.example.chat": WindowPlacementPreference(
          workspaceID: WorkspaceID(rawValue: "web"),
          monitorID: monitorID
        )
      ]
    )

    reconcileWindows(
      [window],
      config: config,
      placementPreferences: preferences,
      state: &state
    )

    #expect(state.location(containing: window.id)?.workspaceID == WorkspaceID(rawValue: "web"))
  }

  @Test
  func `Configured rule overrides persisted application workspace`() throws {
    let config = Config(
      workspaces: WorkspacesConfig(names: ["dev", "web"]),
      rules: [Rule(appID: "com.example.chat", workspace: "dev")]
    )
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "com.example.Chat",
      title: "Chat",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )
    let preferences = PlacementPreferences(
      applications: [
        "com.example.chat": WindowPlacementPreference(
          workspaceID: WorkspaceID(rawValue: "web")
        )
      ]
    )

    reconcileWindows(
      [window],
      config: config,
      placementPreferences: preferences,
      state: &state
    )

    #expect(state.location(containing: window.id)?.workspaceID == WorkspaceID(rawValue: "dev"))
  }

  @Test
  func `Automatic floater ignores persisted application placement`() throws {
    let externalMonitorID = MonitorID(rawValue: 2)
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    state.attachMonitor(externalMonitorID)
    let window = Window(
      id: WindowID(rawValue: 2),
      appID: "com.example.Chat",
      title: "Updating",
      frame: Rect(x: 100, y: 100, width: 400, height: 300),
      monitorID: monitorID,
      floating: true,
      floatingOrigin: .automatic
    )
    let preferences = PlacementPreferences(
      applications: [
        "com.example.chat": WindowPlacementPreference(
          workspaceID: WorkspaceID(rawValue: "web"),
          monitorID: externalMonitorID
        )
      ]
    )

    reconcileWindows(
      [window],
      config: config,
      placementPreferences: preferences,
      state: &state
    )

    #expect(state.location(containing: window.id)?.monitorID == monitorID)
    #expect(state.location(containing: window.id)?.workspaceID == WorkspaceID(rawValue: "dev"))
  }

  @Test
  func `Automatic floater restores workspace only preference on current monitor`() throws {
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 3),
      appID: "com.example.Chat",
      title: "Updating",
      frame: Rect(x: 100, y: 100, width: 400, height: 300),
      monitorID: monitorID,
      floating: true,
      floatingOrigin: .automatic
    )
    let preferences = PlacementPreferences(
      applications: [
        "com.example.chat": WindowPlacementPreference(
          workspaceID: WorkspaceID(rawValue: "web")
        )
      ]
    )

    reconcileWindows([window], config: config, placementPreferences: preferences, state: &state)
    var tiled = window
    tiled.floating = false
    tiled.floatingOrigin = nil
    reconcileWindows([tiled], config: config, placementPreferences: preferences, state: &state)

    #expect(state.location(containing: window.id)?.workspaceID == WorkspaceID(rawValue: "web"))
  }

  @Test
  func `Invalidating preference removes automatic floater destination`() {
    let window = Window(
      id: WindowID(rawValue: 4),
      appID: "com.example.Chat",
      title: "Updating",
      frame: Rect(x: 0, y: 0, width: 400, height: 300),
      monitorID: monitorID,
      floating: true,
      floatingOrigin: .automatic
    )
    var preferences = PlacementPreferences(
      applications: [
        "com.example.chat": WindowPlacementPreference(
          workspaceID: WorkspaceID(rawValue: "web")
        )
      ]
    )

    preferences.invalidatePreference(for: window)

    #expect(preferences.preference(for: window) == nil)
    #expect(preferences.suppressedWindowIDs == [window.id])
  }

  @Test
  func `Suppressed preference survives sibling recording until reclassification`() throws {
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let sibling = Window(
      id: WindowID(rawValue: 5),
      appID: "com.example.Chat",
      title: "Main",
      frame: Rect(x: 0, y: 0, width: 400, height: 300),
      monitorID: monitorID
    )
    let automatic = Window(
      id: WindowID(rawValue: 6),
      appID: sibling.appID,
      title: "Updating",
      frame: Rect(x: 0, y: 0, width: 400, height: 300),
      monitorID: monitorID,
      floating: true,
      floatingOrigin: .automatic
    )
    try discoverWindow(sibling, decision: RuleDecision(), state: &state)
    try discoverWindow(automatic, decision: RuleDecision(), state: &state)
    var preferences = PlacementPreferences(
      applications: [
        "com.example.chat": WindowPlacementPreference(
          workspaceID: WorkspaceID(rawValue: "web")
        )
      ]
    )

    preferences.invalidatePreference(for: automatic)
    preferences.recordPlacements(from: state)
    #expect(preferences.preference(for: automatic) == nil)
    #expect(preferences.preference(for: sibling)?.workspaceID == WorkspaceID(rawValue: "dev"))

    var reclassified = automatic
    reclassified.floating = false
    reclassified.floatingOrigin = nil
    state.windows[automatic.id] = reclassified
    preferences.recordPlacements(from: state)
    #expect(preferences.suppressedWindowIDs.isEmpty)
    #expect(preferences.preference(for: reclassified)?.workspaceID == WorkspaceID(rawValue: "dev"))

    state.windows[automatic.id] = nil
    preferences.recordPlacements(from: state)
    #expect(preferences.preference(for: sibling)?.workspaceID == WorkspaceID(rawValue: "dev"))
  }

  @Test
  func `Recording placements keeps closed application preferences`() throws {
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "com.example.Chat",
      title: "Chat",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )
    try discoverWindow(
      window,
      decision: RuleDecision(workspace: WorkspaceID(rawValue: "web")),
      state: &state
    )
    var preferences = PlacementPreferences(
      applications: [
        "com.example.closed": WindowPlacementPreference(
          workspaceID: WorkspaceID(rawValue: "dev")
        )
      ]
    )

    preferences.recordPlacements(from: state)

    #expect(
      preferences.applications["com.example.chat"]?.workspaceID == WorkspaceID(rawValue: "web"))
    #expect(
      preferences.applications["com.example.closed"]?.workspaceID == WorkspaceID(rawValue: "dev"))
  }

  @Test
  func `Recording global workspace keeps its owner monitor`() throws {
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    let externalMonitorID = MonitorID(rawValue: 2)
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    state.attachMonitor(externalMonitorID)
    let windows = [
      Window(
        id: WindowID(rawValue: 1),
        appID: "com.example.Chat",
        title: "Primary",
        frame: Rect(x: 0, y: 0, width: 600, height: 800),
        monitorID: monitorID
      ),
      Window(
        id: WindowID(rawValue: 2),
        appID: "com.example.Chat",
        title: "External",
        frame: Rect(x: 1_000, y: 0, width: 600, height: 800),
        monitorID: externalMonitorID
      ),
    ]
    for window in windows {
      try discoverWindow(
        window,
        decision: RuleDecision(workspace: WorkspaceID(rawValue: "web")),
        state: &state
      )
    }
    var preferences = PlacementPreferences()

    preferences.recordPlacements(from: state)

    #expect(
      preferences.applications["com.example.chat"]
        == WindowPlacementPreference(
          workspaceID: WorkspaceID(rawValue: "web"),
          monitorID: monitorID
        ))
  }

  @Test
  func `Recording fallback retains disconnected monitor`() throws {
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    let disconnectedMonitorID = MonitorID(rawValue: 99)
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "com.example.Chat",
      title: "Chat",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )
    try discoverWindow(
      window,
      decision: RuleDecision(workspace: WorkspaceID(rawValue: "web")),
      state: &state
    )
    var preferences = PlacementPreferences(
      applications: [
        "com.example.chat": WindowPlacementPreference(
          workspaceID: WorkspaceID(rawValue: "web"),
          monitorID: disconnectedMonitorID
        )
      ]
    )

    preferences.recordPlacements(from: state)

    #expect(preferences.applications["com.example.chat"]?.monitorID == disconnectedMonitorID)
  }

  @Test
  func `Disconnect migrates live window without overwriting preferred monitor`() throws {
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    let externalMonitorID = MonitorID(rawValue: 2)
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    state.attachMonitor(externalMonitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "com.example.Chat",
      title: "Chat",
      frame: Rect(x: 1_500, y: 0, width: 600, height: 800),
      monitorID: externalMonitorID
    )
    try discoverWindow(
      window,
      decision: RuleDecision(workspace: WorkspaceID(rawValue: "web")),
      state: &state
    )
    var preferences = PlacementPreferences(
      applications: [
        "com.example.chat": WindowPlacementPreference(
          workspaceID: WorkspaceID(rawValue: "web"),
          monitorID: externalMonitorID
        )
      ]
    )

    state.retainMonitors([monitorID])

    #expect(state.location(containing: window.id)?.monitorID == monitorID)

    preferences.recordPlacements(from: state)

    #expect(preferences.applications["com.example.chat"]?.monitorID == externalMonitorID)
  }

  @Test
  func `Automatic floaters do not affect placement preferences`() throws {
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let normal = Window(
      id: WindowID(rawValue: 10),
      appID: "com.example.chat",
      title: "Chat",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )
    let automatic = Window(
      id: WindowID(rawValue: 11),
      appID: normal.appID,
      title: "Updating",
      frame: Rect(x: 100, y: 100, width: 400, height: 300),
      monitorID: monitorID,
      floating: true,
      floatingOrigin: .automatic
    )
    try discoverWindow(normal, decision: RuleDecision(), state: &state)
    try discoverWindow(
      automatic,
      decision: RuleDecision(workspace: WorkspaceID(rawValue: "web")),
      state: &state
    )
    var preferences = PlacementPreferences()

    preferences.recordPlacements(from: state)

    #expect(preferences.applications[normal.appID]?.workspaceID == WorkspaceID(rawValue: "dev"))
  }

  @Test
  func `Initially automatic window uses persisted placement when tiled`() throws {
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 12),
      appID: "com.example.chat",
      title: "Updating",
      frame: Rect(x: 100, y: 100, width: 400, height: 300),
      monitorID: monitorID,
      floating: true,
      floatingOrigin: .automatic
    )
    let preferences = PlacementPreferences(
      applications: [
        "com.example.chat": WindowPlacementPreference(
          workspaceID: WorkspaceID(rawValue: "web"),
          monitorID: monitorID
        )
      ]
    )

    reconcileWindows(
      [window],
      config: config,
      placementPreferences: preferences,
      state: &state
    )
    var tiled = window
    tiled.floating = false
    tiled.floatingOrigin = nil
    reconcileWindows(
      [tiled],
      config: config,
      placementPreferences: preferences,
      state: &state
    )

    #expect(state.location(containing: window.id)?.workspaceID == WorkspaceID(rawValue: "web"))
  }
}
