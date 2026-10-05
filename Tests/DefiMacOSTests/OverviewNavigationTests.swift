import AppKit
import DefiCore
import DefiModel
import Testing

@testable import DefiMacOS

@MainActor
struct OverviewNavigationTests {
  @Test(arguments: [false, true])
  func cancellationNeverCommitsDeferredSelection(pendingSelection: Bool) {
    let monitor = MonitorID(rawValue: .max)
    let ids = [WindowID(rawValue: 1), WindowID(rawValue: 2)]
    let workspace = Workspace(id: WorkspaceID(rawValue: "test"), columns:
      ids.map { Column(window: $0, width: .fraction(0.5)) })
    var focuses: [WindowID] = [], drops = 0, edits = 0
    let controller = OverviewController(focusWindow: { id, _, _, _ in focuses.append(id) },
      focusWorkspace: { _, _ in }, drop: { _, _, _, _, _ in drops += 1 }, activateMonitor: { _ in },
      openStateChanged: { _ in }, waitsForNativeSelectionCommit: true,
      notificationCenter: NotificationCenter(), layoutCommand: { _, _, _, _, _, _ in edits += 1 },
      commitScrollOffsets: { _ in })
    controller.open(snapshot: OverviewSnapshot(monitors: [Monitor(id: monitor,
      workspaces: [workspace], activeWorkspace: workspace.id)], monitorFrames: [:],
      windows: Dictionary(uniqueKeysWithValues: ids.map { id in
        (id, Window(id: id, appID: "test", title: "Window", frame: Rect(x: 0, y: 0, width: 100, height: 100)))
      })), layout: LayoutSettings())
    controller.handleKey(.right)
    #expect(focuses.isEmpty)
    if pendingSelection {
      controller.handleKey(.select)
      #expect(focuses == [ids[1]])
      controller.handleKey(.moveDown)
      #expect(!controller.applyLayoutCommand(.maximizeColumn))
      #expect(drops == 0 && edits == 0)
    }
    controller.handleKey(.cancel)
    #expect(!controller.isOpen)
    #expect(focuses == (pendingSelection ? [ids[1]] : []))
    controller.selectionCommitCompleted()
    #expect(!controller.isOpen)
  }

  @Test(arguments: [WorkspaceTarget.named("b"), .position(2)])
  func directWorkspaceBindingSelectsItsFocusedWindow(target: WorkspaceTarget) {
    let monitor = MonitorID(rawValue: .max)
    let ids = (1...3).map { WindowID(rawValue: UInt64($0)) }
    let a = Workspace(id: WorkspaceID(rawValue: "a"), columns: [Column(window: ids[0], width: .fraction(0.5))])
    let b = Workspace(id: WorkspaceID(rawValue: "b"), columns: [
      Column(window: ids[1], width: .fraction(0.5)), Column(window: ids[2], width: .fraction(0.5))], focusedColumn: 1)
    var focused: [WindowID] = []
    let controller = OverviewController(focusWindow: { id, _, _, _ in focused.append(id) },
      focusWorkspace: { _, _ in }, drop: { _, _, _, _, _ in }, activateMonitor: { _ in },
      openStateChanged: { _ in }, notificationCenter: NotificationCenter(), commitScrollOffsets: { _ in })
    controller.open(snapshot: OverviewSnapshot(monitors: [Monitor(id: monitor, workspaces: [a, b], activeWorkspace: a.id)],
      monitorFrames: [:], windows: Dictionary(uniqueKeysWithValues: ids.map {
        ($0, Window(id: $0, appID: "test", title: "Window", frame: Rect(x: 0, y: 0, width: 100, height: 100)))
      })), layout: LayoutSettings())
    defer { controller.close() }
    controller.handleKey(.workspace(target))
    #expect(focused.isEmpty)
    #expect(controller.isOpen)
    controller.handleKey(.select)
    #expect(focused == [ids[2]])
  }
  @Test func layoutCommandUsesDeferredSelection() {
    let monitor = MonitorID(rawValue: .max)
    let ids = [WindowID(rawValue: 1), WindowID(rawValue: 2)]
    let workspaces = ids.enumerated().map { index, id in
      Workspace(id: WorkspaceID(rawValue: String(index)), columns: [Column(window: id, width: .fraction(0.5))])
    }
    var edits: [WindowID] = [], nativeFocus: [WindowID] = []
    let controller = OverviewController(focusWindow: { id, _, _, _ in nativeFocus.append(id) },
      focusWorkspace: { _, _ in }, drop: { _, _, _, _, _ in }, activateMonitor: { _ in },
      openStateChanged: { _ in }, notificationCenter: NotificationCenter(),
      layoutCommand: { command, id, app, display, workspace, _ in
        #expect(command == .maximizeColumn)
        #expect(app == "test")
        #expect(display == monitor)
        #expect(workspace == workspaces[1].id)
        edits.append(id)
      }, commitScrollOffsets: { _ in })
    controller.open(snapshot: OverviewSnapshot(monitors: [Monitor(id: monitor,
      workspaces: workspaces, activeWorkspace: workspaces[0].id)], monitorFrames: [:],
      windows: Dictionary(uniqueKeysWithValues: ids.map { id in
        (id, Window(id: id, appID: "test", title: "Window", frame: Rect(x: 0, y: 0, width: 100, height: 100)))
      })), layout: LayoutSettings(), windowPreviewsEnabled: false)
    defer { controller.close(); controller.close() }
    controller.handleKey(.workspaceDown)
    controller.handleKey(.layout(.maximizeColumn))
    #expect(edits == [ids[1]])
    var ipcSelections: [WindowID] = []
    #expect(controller.applyLayoutCommand(.maximizeColumn) { _, id, _, _, _, _ in
      ipcSelections.append(id)
    })
    #expect(ipcSelections == [ids[1]])
    #expect(edits == [ids[1]], "IPC must use its execution handler without duplicating the keyboard mutation")
    controller.close()
    #expect(!controller.applyLayoutCommand(.maximizeColumn) { _, id, _, _, _, _ in
      ipcSelections.append(id)
    })
    #expect(ipcSelections == [ids[1]], "A closed controller cannot enqueue IPC mutation")
    #expect(nativeFocus.isEmpty)
  }

  @Test(arguments: [OverviewKeyAction.firstColumn, .lastColumn])
  func endpointNavigationUsesLocallySelectedWorkspace(action: OverviewKeyAction) {
    let monitor = MonitorID(rawValue: .max)
    let ids = (1...5).map { WindowID(rawValue: UInt64($0)) }
    let windows = ids.map { Window(id: $0, appID: "test", title: "Window",
      frame: Rect(x: 0, y: 0, width: 100, height: 100), processID: 1) }
    let a = Workspace(id: WorkspaceID(rawValue: "native"), columns: [Column(window: ids[0], width: .fraction(0.5))])
    let b = Workspace(id: WorkspaceID(rawValue: "selected"), columns: [
      Column(windows: [ids[1], ids[2]], focusedWindow: 1, width: .fraction(0.5)),
      Column(window: ids[3], width: .fraction(0.5)), Column(window: ids[4], width: .fraction(0.5))], focusedColumn: 1)
    var focused: [WindowID] = []
    let controller = OverviewController(focusWindow: { id, _, _, _ in focused.append(id) },
      focusWorkspace: { _, _ in }, drop: { _, _, _, _, _ in }, activateMonitor: { _ in },
      openStateChanged: { _ in }, notificationCenter: NotificationCenter(),
      commitScrollOffsets: { _ in })
    controller.open(snapshot: OverviewSnapshot(monitors:
      [Monitor(id: monitor, workspaces: [a, b], activeWorkspace: a.id)],
      monitorFrames: [:], windows: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })),
      layout: LayoutSettings(), windowPreviewsEnabled: false)
    defer { controller.close(); controller.close() }
    controller.handleKey(.workspaceDown)
    controller.handleKey(action)
    // Workspace bindings skip a stacked sibling and return to the remembered column.
    controller.handleKey(.workspaceUp)
    controller.handleKey(.workspaceDown)
    #expect(focused.isEmpty)
    controller.handleKey(.select)
    #expect(focused == [action == .firstColumn ? ids[2] : ids[4]])
  }

  @Test func returningToWorkspaceKeepsItsLocalSelection() {
    let monitor = MonitorID(rawValue: .max)
    let ids = (1...3).map { WindowID(rawValue: UInt64($0)) }
    let windows = ids.map { Window(id: $0, appID: "test", title: "Window",
      frame: Rect(x: 0, y: 0, width: 100, height: 100), processID: 1) }
    let a = Workspace(id: WorkspaceID(rawValue: "a"), columns:
      ids.prefix(2).map { Column(window: $0, width: .fraction(0.5)) })
    let b = Workspace(id: WorkspaceID(rawValue: "b"), columns:
      [Column(window: ids[2], width: .fraction(0.5))])
    var focused: [WindowID] = []
    let controller = OverviewController(focusWindow: { id, _, _, _ in focused.append(id) },
      focusWorkspace: { _, _ in }, drop: { _, _, _, _, _ in }, activateMonitor: { _ in },
      openStateChanged: { _ in }, notificationCenter: NotificationCenter(),
      commitScrollOffsets: { _ in })
    controller.open(snapshot: OverviewSnapshot(monitors:
      [Monitor(id: monitor, workspaces: [a, b], activeWorkspace: a.id)],
      monitorFrames: [:], windows: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })),
      layout: LayoutSettings(), windowPreviewsEnabled: false)
    defer { controller.close(); controller.close() }
    controller.handleKey(.right)
    controller.handleKey(.down)
    controller.handleKey(.up)
    #expect(focused.isEmpty)
    controller.handleKey(.select)
    #expect(focused == [ids[1]])
  }

  @Test(arguments: [OverviewKeyAction.left, .right, .up, .down])
  func delayedActivationAfterRepeatedArrowsKeepsOverviewOpen(action: OverviewKeyAction) async throws {
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
      waitsForNativeSelectionCommit: true,
      notificationCenter: NotificationCenter(),
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
    #expect(focused.isEmpty)
    NSWorkspace.shared.notificationCenter.post(
      name: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]
    )
    #expect(controller.isOpen)
    #expect(focused.isEmpty)
    controller.handleKey(.select)
    #expect(focused == [lastWindowID])
    try await Task.sleep(for: .milliseconds(250))
    #expect(controller.isOpen, "The overview must cover pending native layout writes")
    controller.selectionCommitCompleted(sessionGeneration: controller.sessionGeneration &+ 1)
    #expect(controller.isOpen, "A different session cannot release the closing handoff")
    controller.selectionCommitCompleted()
    #expect(controller.isOpen == false)
  }
}
