import DefiConfig
import DefiCore
import DefiModel
import Testing
import XCTest

@testable import DefiRuntime

final class RuntimeMonitorTests: XCTestCase {
  private let monitorID = MonitorID(rawValue: 1)

  func testReservedEdgesAreReducedPerMonitor() throws {
    let externalID = MonitorID(rawValue: 2)
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    state.attachMonitor(externalID)

    try reduce(
      .setReservedEdges([
        monitorID: ReservedEdges(top: 36, bottom: 12)
      ]),
      state: &state
    )

    XCTAssertEqual(
      state.reservedEdgesByMonitor[monitorID],
      ReservedEdges(top: 36, bottom: 12)
    )
    XCTAssertNil(state.reservedEdgesByMonitor[externalID])

    try reduce(.clearReservedEdges([monitorID]), state: &state)

    XCTAssertNil(state.reservedEdgesByMonitor[monitorID])
  }

  func testDisplayResizeScalesPixelAndPreMaximizedWidths() {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    state.monitors[0].workspaces[0].columns = [
      Column(
        windows: [WindowID(rawValue: 1)],
        focusedWindow: 0,
        width: .fraction(1),
        preMaximizedWidth: .pixels(800)
      ),
      Column(window: WindowID(rawValue: 2), width: .pixels(1_000)),
    ]

    state.retainMonitors(
      [monitorID],
      previousViewports: [
        monitorID: Rect(x: 0, y: 0, width: 2_000, height: 1_000)
      ],
      nextViewports: [
        monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)
      ]
    )

    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns[0].preMaximizedWidth,
      .pixels(400)
    )
    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns[1].width,
      .pixels(500)
    )
  }

  func testDisconnectedMonitorMergesAndScalesColumnsIntoRemainingDisplay() {
    let externalID = MonitorID(rawValue: 2)
    let config = Config(workspaces: WorkspacesConfig(names: ["dev"]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    state.attachMonitor(externalID)
    state.monitors[1].workspaces[0].columns = [
      Column(window: WindowID(rawValue: 9), width: .pixels(1_200))
    ]

    state.retainMonitors(
      [monitorID],
      previousViewports: [
        monitorID: Rect(x: 0, y: 0, width: 1_500, height: 900),
        externalID: Rect(x: 1_500, y: 0, width: 3_000, height: 1_600),
      ],
      nextViewports: [
        monitorID: Rect(x: 0, y: 0, width: 1_500, height: 900)
      ]
    )

    XCTAssertEqual(state.monitors.count, 1)
    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns[0].width,
      .pixels(600)
    )
  }

  func testDisconnectedMonitorMigratesAndScalesSuspendedPlacement() {
    let externalID = MonitorID(rawValue: 2)
    let workspaceID = WorkspaceID(rawValue: "dev")
    let modalID = WindowID(rawValue: 10)
    let config = Config(workspaces: WorkspacesConfig(names: [workspaceID.rawValue]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    state.attachMonitor(externalID)
    state.monitors[0].workspaces[0].columns = [
      Column(window: WindowID(rawValue: 1), width: .fraction(0.5))
    ]
    state.monitors[1].workspaces[0].columns = [
      Column(window: WindowID(rawValue: 9), width: .pixels(1_000))
    ]
    state.suspendedTiledPlacements[modalID] = SuspendedTiledPlacement(
      monitorID: externalID,
      workspaceID: workspaceID,
      columnIndex: 1,
      windowIndex: 0,
      column: Column(
        windows: [modalID],
        focusedWindow: 0,
        width: .pixels(1_200),
        preMaximizedWidth: .pixels(800)
      )
    )

    state.retainMonitors(
      [monitorID],
      previousViewports: [
        monitorID: Rect(x: 0, y: 0, width: 1_500, height: 900),
        externalID: Rect(x: 1_500, y: 0, width: 3_000, height: 1_600),
      ],
      nextViewports: [
        monitorID: Rect(x: 0, y: 0, width: 1_500, height: 900)
      ]
    )

    XCTAssertEqual(
      state.suspendedTiledPlacements[modalID],
      SuspendedTiledPlacement(
        monitorID: monitorID,
        workspaceID: workspaceID,
        columnIndex: 2,
        windowIndex: 0,
        column: Column(
          windows: [modalID],
          focusedWindow: 0,
          width: .pixels(600),
          preMaximizedWidth: .pixels(400)
        )
      )
    )
  }

  func testDisconnectedMonitorPlacesMigratedSuspensionAfterTargetSuspensions() {
    let externalID = MonitorID(rawValue: 2)
    let workspaceID = WorkspaceID(rawValue: "dev")
    let targetModalID = WindowID(rawValue: 8)
    let sourceModalID = WindowID(rawValue: 10)
    let config = Config(workspaces: WorkspacesConfig(names: [workspaceID.rawValue]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    state.attachMonitor(externalID)
    state.monitors[0].workspaces[0].columns = [
      Column(window: WindowID(rawValue: 1), width: .fraction(0.5))
    ]
    state.suspendedTiledPlacements[targetModalID] = SuspendedTiledPlacement(
      monitorID: monitorID,
      workspaceID: workspaceID,
      columnIndex: 1,
      windowIndex: 0,
      column: Column(window: targetModalID, width: .pixels(600))
    )
    state.suspendedTiledPlacements[sourceModalID] = SuspendedTiledPlacement(
      monitorID: externalID,
      workspaceID: workspaceID,
      columnIndex: 1,
      windowIndex: 0,
      column: Column(window: sourceModalID, width: .pixels(600))
    )

    state.retainMonitors(
      [monitorID],
      previousViewports: [
        monitorID: Rect(x: 0, y: 0, width: 1_500, height: 900),
        externalID: Rect(x: 1_500, y: 0, width: 3_000, height: 1_600),
      ],
      nextViewports: [
        monitorID: Rect(x: 0, y: 0, width: 1_500, height: 900)
      ]
    )

    XCTAssertEqual(state.suspendedTiledPlacements[sourceModalID]?.columnIndex, 3)
  }

  func testDisconnectedMonitorPlacesMigrationAfterHighestSuspendedColumn() {
    let externalID = MonitorID(rawValue: 2)
    let workspaceID = WorkspaceID(rawValue: "dev")
    let targetModalID = WindowID(rawValue: 8)
    let sourceModalID = WindowID(rawValue: 10)
    let config = Config(workspaces: WorkspacesConfig(names: [workspaceID.rawValue]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    state.attachMonitor(externalID)
    state.suspendedTiledPlacements[targetModalID] = SuspendedTiledPlacement(
      monitorID: monitorID,
      workspaceID: workspaceID,
      columnIndex: 2,
      windowIndex: 0,
      column: Column(window: targetModalID, width: .pixels(600))
    )
    state.suspendedTiledPlacements[sourceModalID] = SuspendedTiledPlacement(
      monitorID: externalID,
      workspaceID: workspaceID,
      columnIndex: 1,
      windowIndex: 0,
      column: Column(window: sourceModalID, width: .pixels(600))
    )

    state.retainMonitors(
      [monitorID],
      previousViewports: [
        monitorID: Rect(x: 0, y: 0, width: 1_500, height: 900),
        externalID: Rect(x: 1_500, y: 0, width: 3_000, height: 1_600),
      ],
      nextViewports: [
        monitorID: Rect(x: 0, y: 0, width: 1_500, height: 900)
      ]
    )

    XCTAssertEqual(state.suspendedTiledPlacements[sourceModalID]?.columnIndex, 4)
  }

  func testReboundFocusMonitorRequiresMigratedWindowToRemainSelected() {
    let externalID = MonitorID(rawValue: 2)
    let config = Config(workspaces: WorkspacesConfig(names: ["dev"]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    state.attachMonitor(externalID)
    state.monitors[0].workspaces[0].columns = [
      Column(window: WindowID(rawValue: 1), width: .fraction(0.5))
    ]
    state.monitors[1].workspaces[0].columns = [
      Column(window: WindowID(rawValue: 9), width: .fraction(0.5))
    ]

    state.retainMonitors(
      [monitorID],
      previousViewports: [
        monitorID: Rect(x: 0, y: 0, width: 1_000, height: 800),
        externalID: Rect(x: 1_000, y: 0, width: 1_000, height: 800),
      ],
      nextViewports: [
        monitorID: Rect(x: 0, y: 0, width: 1_000, height: 800)
      ]
    )

    XCTAssertNil(
      state.reboundFocusMonitorID(
        for: WindowID(rawValue: 9),
        requestedWorkspaceID: WorkspaceID(rawValue: "dev")
      )
    )
    state.monitors[0].workspaces[0].focusedColumn = 1
    XCTAssertEqual(
      state.reboundFocusMonitorID(
        for: WindowID(rawValue: 9),
        requestedWorkspaceID: WorkspaceID(rawValue: "dev")
      ),
      monitorID
    )
  }

  func testEachMonitorOwnsIndependentNineWorkspaces() throws {
    let externalID = MonitorID(rawValue: 2)
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    state.attachMonitor(externalID)

    XCTAssertEqual(
      state.monitors[0].workspaces.map(\.id.rawValue),
      (1...9).map(String.init)
    )
    XCTAssertEqual(
      state.monitors[1].workspaces.map(\.id.rawValue),
      (1...9).map(String.init)
    )

    try reduce(
      .switchWorkspace(WorkspaceID(rawValue: "5")),
      on: externalID,
      state: &state
    )

    XCTAssertEqual(
      state.monitors.first(where: { $0.id == monitorID })?.activeWorkspace,
      WorkspaceID(rawValue: "1")
    )
    XCTAssertEqual(
      state.monitors.first(where: { $0.id == externalID })?.activeWorkspace,
      WorkspaceID(rawValue: "5")
    )
  }

  func testMoveColumnToMonitorKeepsStackScalesPixelsAndMovesTransient() throws {
    let externalID = MonitorID(rawValue: 2)
    var state = twoMonitorState(externalID: externalID)
    state.monitors[0].workspaces[0].columns = [
      Column(
        windows: [WindowID(rawValue: 1), WindowID(rawValue: 2)],
        focusedWindow: 1,
        width: .pixels(1_000)
      )
    ]
    state.monitors[0].workspaces[0].floatingWindows = [WindowID(rawValue: 3)]
    state.monitors[1].workspaces[0].columns = [
      Column(window: WindowID(rawValue: 9), width: .fraction(0.5))
    ]
    state.windows = [
      windowID(1): window(1, monitorID: monitorID),
      windowID(2): window(2, monitorID: monitorID),
      windowID(3): Window(
        id: WindowID(rawValue: 3),
        appID: "app",
        title: "Dialog",
        frame: Rect(x: 100, y: 100, width: 300, height: 200),
        transientOwnerID: WindowID(rawValue: 1),
        monitorID: monitorID,
        floating: true,
        floatingOrigin: .automatic
      ),
      windowID(9): window(9, monitorID: externalID),
    ]

    try reduce(
      .moveColumnToMonitor(.right),
      on: monitorID,
      state: &state,
      monitorFrames: monitorFrames(externalID: externalID),
      viewports: monitorFrames(externalID: externalID)
    )

    XCTAssertTrue(state.monitors[0].workspaces[0].columns.isEmpty)
    XCTAssertEqual(
      state.monitors[1].workspaces[0].columns[1].windows,
      [windowID(1), windowID(2)]
    )
    XCTAssertEqual(state.monitors[1].workspaces[0].columns[1].width, .pixels(2_000))
    XCTAssertEqual(state.monitors[1].workspaces[0].floatingWindows, [windowID(3)])
    XCTAssertEqual(state.selectedWindowID(on: externalID), WindowID(rawValue: 2))
    XCTAssertEqual(state.windows[windowID(3)]?.monitorID, externalID)
  }

  func testMoveWindowToMonitorCreatesIndependentColumn() throws {
    let externalID = MonitorID(rawValue: 2)
    var state = twoMonitorState(externalID: externalID)
    state.monitors[0].workspaces[0].columns = [
      Column(
        windows: [WindowID(rawValue: 1), WindowID(rawValue: 2)],
        focusedWindow: 1,
        width: .fraction(0.6)
      )
    ]
    state.windows = [
      windowID(1): window(1, monitorID: monitorID),
      windowID(2): window(2, monitorID: monitorID),
    ]

    try reduce(
      .moveWindowToMonitor(.right),
      on: monitorID,
      state: &state,
      monitorFrames: monitorFrames(externalID: externalID),
      viewports: monitorFrames(externalID: externalID)
    )

    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns[0].windows,
      [windowID(1)]
    )
    XCTAssertEqual(
      state.monitors[1].workspaces[0].columns[0].windows,
      [windowID(2)]
    )
    XCTAssertEqual(state.monitors[1].workspaces[0].columns[0].width, .fraction(0.6))
    XCTAssertEqual(state.selectedWindowID(on: externalID), WindowID(rawValue: 2))
  }

  func testMoveToMissingSpatialMonitorIsStrictNoOp() throws {
    var state = twoMonitorState(externalID: MonitorID(rawValue: 2))
    state.monitors[0].workspaces[0].columns = [
      Column(window: windowID(1), width: .fraction(0.5))
    ]
    state.windows = [windowID(1): window(1, monitorID: monitorID)]

    let changed = try changedState(
      after: .moveColumnToMonitor(.left),
      on: monitorID,
      from: state,
      monitorFrames: monitorFrames(externalID: MonitorID(rawValue: 2))
    )

    XCTAssertNil(changed)
  }

  private func twoMonitorState(externalID: MonitorID) -> RuntimeState {
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev"]))
    )
    state.attachMonitor(monitorID)
    state.attachMonitor(externalID)
    return state
  }

  private func monitorFrames(externalID: MonitorID) -> [MonitorID: Rect] {
    [
      monitorID: Rect(x: 0, y: 0, width: 1_000, height: 800),
      externalID: Rect(x: 1_000, y: 0, width: 2_000, height: 1_000),
    ]
  }

  private func window(_ rawID: UInt64, monitorID: MonitorID) -> Window {
    Window(
      id: WindowID(rawValue: rawID),
      appID: "app",
      title: "Window \(rawID)",
      frame: Rect(x: 0, y: 0, width: 500, height: 700),
      monitorID: monitorID
    )
  }

  private func windowID(_ rawValue: UInt64) -> WindowID {
    WindowID(rawValue: rawValue)
  }
}

struct MonitorMoveFocusTests {
  @Test
  func movingTheLastColumnKeepsSourceFocusOnItsLastRemainingColumn() throws {
    let sourceID = MonitorID(rawValue: 1)
    let targetID = MonitorID(rawValue: 2)
    let windowIDs = (1...3).map { WindowID(rawValue: UInt64($0)) }
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev"]))
    )
    state.attachMonitor(sourceID)
    state.attachMonitor(targetID)
    state.monitors[0].workspaces[0].columns = windowIDs.map {
      Column(window: $0, width: .fraction(0.5))
    }
    state.monitors[0].workspaces[0].focusedColumn = 2
    state.windows = Dictionary(uniqueKeysWithValues: windowIDs.map {
      ($0, Window(
        id: $0,
        appID: "app",
        title: "Window \($0.rawValue)",
        frame: Rect(x: 0, y: 0, width: 500, height: 700),
        monitorID: sourceID
      ))
    })

    try reduce(
      .moveColumnToMonitor(.right),
      on: sourceID,
      state: &state,
      monitorFrames: [
        sourceID: Rect(x: 0, y: 0, width: 1_000, height: 800),
        targetID: Rect(x: 1_000, y: 0, width: 1_000, height: 800),
      ]
    )

    #expect(state.monitors[0].workspaces[0].focusedColumn == 1)
    #expect(state.selectedWindowID(on: sourceID) == windowIDs[1])
  }
}
