import DefiConfig
import DefiModel
import XCTest

@testable import DefiRuntime

final class FloatingWindowTests: XCTestCase {
  private let monitorID = MonitorID(rawValue: 1)

  func testFloatingLayerActivationAndCyclingWrap() throws {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    let tiled = window(40)
    let floaters = [window(41, floating: true), window(42, floating: true)]
    try discoverWindow(tiled, decision: RuleDecision(), state: &state)
    for floater in floaters {
      try discoverWindow(floater, decision: RuleDecision(), state: &state)
    }

    XCTAssertEqual(state.selectedWindowID(on: monitorID), tiled.id)
    try reduce(.activateFloating, on: monitorID, state: &state)
    XCTAssertEqual(state.selectedWindowID(on: monitorID), floaters[0].id)
    try reduce(.focusFloating(.previous), on: monitorID, state: &state)
    XCTAssertEqual(state.selectedWindowID(on: monitorID), floaters[1].id)
    try reduce(.focusFloating(.next), on: monitorID, state: &state)
    XCTAssertEqual(state.selectedWindowID(on: monitorID), floaters[0].id)
  }

  func testTiledCommandsPreserveFocusedFloaterWithoutColumns() throws {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    let floaters = [window(43, floating: true), window(44, floating: true)]
    for floater in floaters {
      try discoverWindow(floater, decision: RuleDecision(), state: &state)
    }
    try reduce(.activateFloating, on: monitorID, state: &state)
    try reduce(.focusFloating(.next), on: monitorID, state: &state)

    for command in [
      Command.focusColumn(.next),
      .focusWindow(.next),
      .cycleWidth(.next),
      .maximizeColumn,
    ] {
      try reduce(command, on: monitorID, state: &state)
      XCTAssertEqual(state.selectedWindowID(on: monitorID), floaters[1].id)
      XCTAssertEqual(state.monitors[0].workspaces[0].focusedLayer, .floating)
    }
  }

  func testToggleFloatingUsesFallbackSelectedFloaterWithoutColumns() throws {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    let floaters = [window(50, floating: true), window(51, floating: true)]
    for floater in floaters {
      try discoverWindow(floater, decision: RuleDecision(), state: &state)
    }
    state.monitors[0].workspaces[0].focusedLayer = .tiled
    state.monitors[0].workspaces[0].focusedFloatingWindow = 1

    try reduce(.toggleFloating, on: monitorID, state: &state)

    XCTAssertEqual(state.monitors[0].workspaces[0].floatingWindows, [floaters[0].id])
    XCTAssertEqual(state.monitors[0].workspaces[0].columns[0].windows, [floaters[1].id])
    XCTAssertEqual(state.windows[floaters[1].id]?.floatingOrigin, .user)
  }

  func testTilingLastFocusedFloaterClampsRemainingSelection() throws {
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

    XCTAssertEqual(state.monitors[0].workspaces[0].focusedFloatingWindow, 0)
    XCTAssertEqual(state.selectedWindowID(on: monitorID), floaters[0].id)
  }

  func testFloatingFocusCommandRequiresValidFloatingSelection() {
    let tiled = WindowID(rawValue: 70)
    let floating = WindowID(rawValue: 71)

    XCTAssertFalse(
      commandShouldFocusWindow(
        .activateFloating,
        previousSelectedWindowID: tiled,
        selectedWindowID: tiled,
        selectedFloatingWindowID: nil
      )
    )
    XCTAssertTrue(
      commandShouldFocusWindow(
        .focusFloating(.next),
        previousSelectedWindowID: floating,
        selectedWindowID: floating,
        selectedFloatingWindowID: floating
      )
    )
  }

  func testNativeFloatingFocusActivatesItsWorkspace() throws {
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

    XCTAssertTrue(focusWindow(floater.id, state: &state))
    XCTAssertEqual(state.monitors[0].activeWorkspace, tools)
    XCTAssertEqual(state.selectedWindowID(on: monitorID), floater.id)
  }

  func testMoveFocusedFloaterPreservesLayer() throws {
    let tools = WorkspaceID(rawValue: "tools")
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev", tools.rawValue]))
    )
    state.attachMonitor(monitorID)
    let floater = window(61, floating: true)
    try discoverWindow(floater, decision: RuleDecision(), state: &state)
    try reduce(.activateFloating, on: monitorID, state: &state)

    try reduce(.moveWindowToWorkspace(tools), on: monitorID, state: &state)

    XCTAssertEqual(state.monitors[0].activeWorkspace, tools)
    XCTAssertEqual(state.monitors[0].workspaces[1].floatingWindows, [floater.id])
    XCTAssertEqual(state.selectedWindowID(on: monitorID), floater.id)
  }

  func testMoveFocusedTileSelectsTiledLayerInTargetWorkspace() throws {
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
      state: &state
    )
    try reduce(.switchWorkspace(WorkspaceID(rawValue: "dev")), on: monitorID, state: &state)

    try reduce(.moveWindowToWorkspace(tools), on: monitorID, state: &state)

    XCTAssertEqual(state.monitors[0].activeWorkspace, tools)
    XCTAssertEqual(state.monitors[0].workspaces[1].focusedLayer, .tiled)
    XCTAssertEqual(state.selectedWindowID(on: monitorID), tile.id)
  }

  func testMoveFallbackSelectedFloaterWithoutColumns() throws {
    let tools = WorkspaceID(rawValue: "tools")
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev", tools.rawValue]))
    )
    state.attachMonitor(monitorID)
    let floater = window(62, floating: true)
    try discoverWindow(floater, decision: RuleDecision(), state: &state)
    XCTAssertEqual(state.monitors[0].workspaces[0].focusedLayer, .tiled)

    try reduce(.moveWindowToWorkspace(tools), on: monitorID, state: &state)

    XCTAssertEqual(state.monitors[0].activeWorkspace, tools)
    XCTAssertTrue(state.monitors[0].workspaces[0].floatingWindows.isEmpty)
    XCTAssertEqual(state.monitors[0].workspaces[1].floatingWindows, [floater.id])
    XCTAssertEqual(state.selectedWindowID(on: monitorID), floater.id)
  }

  func testFollowFocusSelectsNewFloatingWindow() throws {
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
      state: &state
    )

    XCTAssertEqual(state.monitors[0].activeWorkspace, tools)
    XCTAssertEqual(state.monitors[0].workspaces[1].focusedLayer, .floating)
    XCTAssertEqual(state.selectedWindowID(on: monitorID), followed.id)
  }

  func testFollowFocusSelectsNewTiledWindowFromFloatingLayer() throws {
    let tools = WorkspaceID(rawValue: "tools")
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev", tools.rawValue]))
    )
    state.attachMonitor(monitorID)
    let floater = window(65, floating: true)
    try discoverWindow(
      floater,
      decision: RuleDecision(workspace: tools, followFocus: true),
      state: &state
    )

    let followed = window(66)
    try discoverWindow(
      followed,
      decision: RuleDecision(workspace: tools, followFocus: true),
      state: &state
    )

    XCTAssertEqual(state.monitors[0].activeWorkspace, tools)
    XCTAssertEqual(state.monitors[0].workspaces[1].focusedLayer, .tiled)
    XCTAssertEqual(state.selectedWindowID(on: monitorID), followed.id)
  }

  func testAutomaticFloaterReclassifiesAsTiledWithoutStealingFocus() throws {
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
    XCTAssertTrue(workspace.floatingWindows.isEmpty)
    XCTAssertEqual(workspace.columns.flatMap(\.windows), [selectedTile.id, automatic.id])
    XCTAssertEqual(state.windows[automatic.id]?.floating, false)
    XCTAssertNil(state.windows[automatic.id]?.floatingOrigin)
    XCTAssertEqual(state.selectedWindowID(on: monitorID), selectedTile.id)
  }

  func testFocusedAutomaticFloaterRemainsSelectedWhenReclassified() throws {
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

    XCTAssertEqual(state.monitors[0].workspaces[0].focusedLayer, .tiled)
    XCTAssertEqual(state.selectedWindowID(on: monitorID), automatic.id)
  }

  func testUserFloatingOverrideSurvivesTiledObservation() throws {
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

    XCTAssertEqual(state.monitors[0].workspaces[0].floatingWindows, [userFloater.id])
    XCTAssertEqual(state.windows[userFloater.id]?.floating, true)
    XCTAssertEqual(state.windows[userFloater.id]?.floatingOrigin, .user)
  }

  func testDraggedFloaterMovesToTargetMonitorActiveWorkspace() throws {
    let externalMonitorID = MonitorID(rawValue: 2)
    let tools = WorkspaceID(rawValue: "tools")
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev", tools.rawValue]))
    )
    state.attachMonitor(monitorID)
    state.attachMonitor(externalMonitorID)
    state.monitors[1].activeWorkspace = tools
    let floater = window(67, floating: true)
    try discoverWindow(floater, decision: RuleDecision(), state: &state)

    XCTAssertTrue(
      moveFloatingWindow(floater.id, to: externalMonitorID, state: &state)
    )

    XCTAssertTrue(state.monitors[0].workspaces[0].floatingWindows.isEmpty)
    XCTAssertEqual(state.monitors[0].workspaces[0].focusedLayer, .tiled)
    XCTAssertEqual(state.monitors[1].workspaces[1].floatingWindows, [floater.id])
    XCTAssertEqual(state.monitors[1].workspaces[1].focusedLayer, .floating)
    XCTAssertEqual(state.selectedWindowID(on: externalMonitorID), floater.id)
    XCTAssertEqual(state.windows[floater.id]?.monitorID, externalMonitorID)
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
