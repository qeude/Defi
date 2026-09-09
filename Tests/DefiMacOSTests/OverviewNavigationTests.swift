import AppKit
import DefiCore
import DefiModel
import Testing

@testable import DefiMacOS

@MainActor
struct OverviewNavigationTests {
  @Test(arguments: [OverviewKeyAction.left, .right, .up, .down])
  func delayedActivationAfterRepeatedArrowsKeepsOverviewOpen(action: OverviewKeyAction) {
    // A nonexistent display exercises the controller without creating desktop panels.
    let monitorID = MonitorID(rawValue: .max)
    let workspaceID = WorkspaceID(rawValue: "test")
    let windows = (1...3).map { index in
      Window(
        id: WindowID(rawValue: UInt64(index)), appID: "test.\(index)",
        title: "Test", frame: Rect(x: 0, y: 0, width: 100, height: 100),
        processID: index == 2 ? NSRunningApplication.current.processIdentifier : Int32(index)
      )
    }
    let startsAtEnd = action == .left || action == .up
    let vertical = action == .up || action == .down
    let workspaces = vertical
      ? windows.map { window in
        Workspace(
          id: WorkspaceID(rawValue: "test.\(window.id.rawValue)"),
          columns: [Column(window: window.id, width: .fraction(0.5))]
        )
      }
      : [Workspace(
        id: workspaceID,
        columns: windows.map { Column(window: $0.id, width: .fraction(0.5)) },
        focusedColumn: startsAtEnd ? 2 : 0
      )]
    var focused: [WindowID] = []
    let controller = OverviewController(
      focusWindow: { id, _, _, _ in focused.append(id) },
      focusWorkspace: { _, _ in }, drop: { _, _, _, _, _ in },
      activateMonitor: { _ in }, openStateChanged: { _ in },
      commitScrollOffsets: { _ in }
    )
    controller.open(
      snapshot: OverviewSnapshot(
        monitors: [Monitor(
          id: monitorID,
          workspaces: workspaces,
          activeWorkspace: workspaces[vertical && startsAtEnd ? 2 : 0].id
        )],
        monitorFrames: [:],
        windows: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
      ),
      layout: LayoutSettings()
    )
    defer { controller.close() }

    let lastWindowID = windows[startsAtEnd ? 0 : 2].id
    for _ in 0..<20 { controller.handleKey(action) }
    #expect(controller.isOpen)
    #expect(focused.last == lastWindowID)
    NSWorkspace.shared.notificationCenter.post(
      name: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]
    )
    #expect(controller.isOpen)
    #expect(focused == [windows[1].id, lastWindowID])
    controller.handleKey(.cancel)
    #expect(controller.isOpen == false)
  }
}
