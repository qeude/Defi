import DefiConfig
import DefiModel
import DefiRuntime
import Testing

struct TransientReconciliationTests {
  @Test
  func delayedOwnershipRelocatesTransientToOwnerWorkspace() throws {
    let firstMonitor = MonitorID(rawValue: 1)
    let secondMonitor = MonitorID(rawValue: 2)
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    var state = RuntimeState(config: config)
    state.attachMonitor(firstMonitor)
    state.attachMonitor(secondMonitor)
    let decoy = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "Other document",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: firstMonitor
    )
    let owner = Window(
      id: WindowID(rawValue: 2),
      appID: "editor",
      title: "Owner",
      frame: Rect(x: 1_000, y: 0, width: 600, height: 800),
      monitorID: secondMonitor
    )
    var transient = Window(
      id: WindowID(rawValue: 3),
      appID: "editor",
      title: "Sheet",
      frame: Rect(x: 100, y: 100, width: 300, height: 200),
      isModal: true,
      monitorID: firstMonitor,
      floating: true,
      floatingOrigin: .automatic
    )
    try discoverWindow(decoy, decision: RuleDecision(), state: &state)
    try discoverWindow(
      owner,
      decision: RuleDecision(workspace: WorkspaceID(rawValue: "web")),
      state: &state
    )
    try discoverWindow(transient, decision: RuleDecision(), state: &state)
    #expect(state.location(containing: transient.id)?.monitorID == firstMonitor)

    transient.transientOwnerID = owner.id
    let relocated = reconcileWindows(
      [decoy, owner, transient],
      config: config,
      state: &state
    )

    let location = try #require(state.location(containing: transient.id))
    #expect(relocated == [transient.id])
    #expect(location.monitorID == secondMonitor)
    #expect(location.workspaceID == WorkspaceID(rawValue: "web"))
    #expect(state.monitors.allSatisfy { $0.activeWorkspace.rawValue == "dev" })
  }
}
