import DefiConfig
import DefiModel
import DefiRuntime
import XCTest

final class PlacementPreferencesTests: XCTestCase {
  private let monitorID = MonitorID(rawValue: 1)

  func testReconcileRestoresPersistedApplicationWorkspace() throws {
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

    XCTAssertEqual(
      state.location(containing: window.id)?.workspaceID,
      WorkspaceID(rawValue: "web")
    )
  }

  func testConfiguredRuleOverridesPersistedApplicationWorkspace() throws {
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

    XCTAssertEqual(
      state.location(containing: window.id)?.workspaceID,
      WorkspaceID(rawValue: "dev")
    )
  }

  func testRecordingPlacementsKeepsClosedApplicationPreferences() throws {
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

    XCTAssertEqual(
      preferences.applications["com.example.chat"]?.workspaceID,
      WorkspaceID(rawValue: "web")
    )
    XCTAssertEqual(
      preferences.applications["com.example.closed"]?.workspaceID,
      WorkspaceID(rawValue: "dev")
    )
  }

  func testRecordingSharedWorkspaceAcrossMonitorsOmitsMonitor() throws {
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

    XCTAssertEqual(
      preferences.applications["com.example.chat"],
      WindowPlacementPreference(workspaceID: WorkspaceID(rawValue: "web"))
    )
  }

  func testRecordingFallbackRetainsDisconnectedMonitor() throws {
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

    XCTAssertEqual(
      preferences.applications["com.example.chat"]?.monitorID,
      disconnectedMonitorID
    )
  }

  func testDisconnectMigratesLiveWindowWithoutOverwritingPreferredMonitor() throws {
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

    XCTAssertEqual(state.location(containing: window.id)?.monitorID, monitorID)

    preferences.recordPlacements(from: state)

    XCTAssertEqual(
      preferences.applications["com.example.chat"]?.monitorID,
      externalMonitorID
    )
  }

  func testAutomaticFloatersDoNotAffectPlacementPreferences() throws {
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

    XCTAssertEqual(
      preferences.applications[normal.appID]?.workspaceID,
      WorkspaceID(rawValue: "dev")
    )
  }
}
