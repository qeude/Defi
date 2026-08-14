import DefiConfig
import DefiModel
import XCTest

@testable import DefiRuntime

final class RuntimeMonitorTests: XCTestCase {
  private let monitorID = MonitorID(rawValue: 1)

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
}
