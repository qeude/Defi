import DefiConfig
import DefiModel
import Testing

@testable import DefiRuntime

struct TransientReconciliationTests {
  @Test
  func ownerlessTransientDoesNotFollowAnotherInstanceOfTheSameApplication() throws {
    let monitorID = MonitorID(rawValue: 1)
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    let selected = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "Other instance",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      processID: 200,
      monitorID: monitorID
    )
    try discoverWindow(selected, decision: RuleDecision(), state: &state)
    let transient = Window(
      id: WindowID(rawValue: 2),
      appID: "editor",
      title: "Sheet",
      frame: Rect(x: 100, y: 100, width: 300, height: 200),
      processID: 100,
      isModal: true,
      floating: true,
      floatingOrigin: .automatic
    )

    #expect(transientPlacementLocation(for: transient, state: state) == nil)
  }

  @Test
  func movingTransientToWorkspaceMovesItsWholeOwnershipChain() throws {
    let monitorID = MonitorID(rawValue: 1)
    let targetWorkspace = WorkspaceID(rawValue: "web")
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev", targetWorkspace.rawValue]))
    )
    state.attachMonitor(monitorID)
    let owner = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "Document",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )
    let transient = Window(
      id: WindowID(rawValue: 2),
      appID: "editor",
      title: "Sheet",
      frame: Rect(x: 100, y: 100, width: 300, height: 200),
      transientOwnerID: owner.id,
      isModal: true,
      monitorID: monitorID,
      floating: true,
      floatingOrigin: .automatic
    )
    try discoverWindow(owner, decision: RuleDecision(), state: &state)
    try discoverWindow(transient, decision: RuleDecision(), state: &state)
    _ = focusWindow(transient.id, state: &state)

    try reduce(.moveWindowToWorkspace(targetWorkspace), on: monitorID, state: &state)

    #expect(state.location(containing: owner.id)?.workspaceID == targetWorkspace)
    #expect(state.location(containing: transient.id)?.workspaceID == targetWorkspace)
    #expect(state.selectedWindowID(on: monitorID) == transient.id)
  }

  @Test
  func delayedOwnershipRebasesSuspendedTiledPlacement() throws {
    let sourceMonitor = MonitorID(rawValue: 1)
    let targetMonitor = MonitorID(rawValue: 2)
    let web = WorkspaceID(rawValue: "web")
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", web.rawValue]))
    var state = RuntimeState(config: config)
    state.attachMonitor(sourceMonitor)
    state.attachMonitor(targetMonitor)
    var transient = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "Sheet",
      frame: Rect(x: 100, y: 100, width: 300, height: 200),
      isModal: true,
      monitorID: sourceMonitor,
      floating: true,
      floatingOrigin: .automatic
    )
    let owner = Window(
      id: WindowID(rawValue: 2),
      appID: "editor",
      title: "Owner",
      frame: Rect(x: 1_000, y: 0, width: 600, height: 800),
      monitorID: targetMonitor
    )
    try discoverWindow(transient, decision: RuleDecision(), state: &state)
    try discoverWindow(
      owner,
      decision: RuleDecision(workspace: web),
      state: &state
    )
    state.suspendedTiledPlacements[transient.id] = SuspendedTiledPlacement(
      monitorID: sourceMonitor,
      workspaceID: WorkspaceID(rawValue: "dev"),
      columnIndex: 1,
      windowIndex: 0,
      column: Column(window: transient.id, width: .pixels(500))
    )

    transient.transientOwnerID = owner.id
    _ = reconcileWindows(
      [transient, owner],
      config: config,
      viewports: [
        sourceMonitor: Rect(x: 0, y: 0, width: 1_000, height: 800),
        targetMonitor: Rect(x: 1_000, y: 0, width: 2_000, height: 800),
      ],
      state: &state
    )

    let placement = try #require(state.suspendedTiledPlacements[transient.id])
    #expect(placement.monitorID == targetMonitor)
    #expect(placement.workspaceID == web)
    #expect(placement.columnIndex == 1)
    #expect(placement.column.width == .pixels(1_000))
  }

  @Test
  func newlyDiscoveredTransientChainConvergesRegardlessOfSnapshotOrder() {
    let firstMonitor = MonitorID(rawValue: 1)
    let secondMonitor = MonitorID(rawValue: 2)
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(firstMonitor)
    state.attachMonitor(secondMonitor)
    let owner = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "Owner",
      frame: Rect(x: 1_000, y: 0, width: 600, height: 800),
      monitorID: secondMonitor
    )
    let sheet = Window(
      id: WindowID(rawValue: 2),
      appID: "editor",
      title: "Sheet",
      frame: Rect(x: 100, y: 100, width: 300, height: 200),
      transientOwnerID: owner.id,
      isModal: true,
      monitorID: firstMonitor,
      floating: true,
      floatingOrigin: .automatic
    )
    let child = Window(
      id: WindowID(rawValue: 3),
      appID: "editor",
      title: "Child sheet",
      frame: Rect(x: 120, y: 120, width: 250, height: 180),
      transientOwnerID: sheet.id,
      isModal: true,
      monitorID: firstMonitor,
      floating: true,
      floatingOrigin: .automatic
    )

    let relocated = reconcileWindows(
      [child, sheet, owner],
      config: config,
      state: &state
    )

    #expect(relocated == [child.id, sheet.id])
    #expect(state.location(containing: sheet.id)?.monitorID == secondMonitor)
    #expect(state.location(containing: child.id)?.monitorID == secondMonitor)
  }

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

    var selectedTransient = Window(
      id: WindowID(rawValue: 4),
      appID: "editor",
      title: "Selected sheet",
      frame: Rect(x: 120, y: 120, width: 300, height: 200),
      isModal: true,
      monitorID: firstMonitor,
      floating: true,
      floatingOrigin: .automatic
    )
    try discoverWindow(selectedTransient, decision: RuleDecision(), state: &state)
    _ = focusWindow(selectedTransient.id, state: &state)
    selectedTransient.transientOwnerID = owner.id

    _ = reconcileWindows(
      [decoy, owner, transient, selectedTransient],
      config: config,
      state: &state
    )

    #expect(state.monitors[1].activeWorkspace.rawValue == "web")
    #expect(state.selectedWindowID(on: secondMonitor) == selectedTransient.id)
  }
}
