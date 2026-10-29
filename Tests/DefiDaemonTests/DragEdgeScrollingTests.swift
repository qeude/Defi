import DefiConfig
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation
import Testing

@testable import DefiDaemon

struct DaemonDragEdgeScrollingTests {
  @Test(arguments: ["cancel", "release", "native-release"]) @NavigationActor
  func heldTicksScrollWithoutSnapshotsAndCleanupRollsBack(outcome: String) async throws {
    let directory = URL(filePath: "/tmp/defi-edge-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let menuBar = await MainActor.run { MenuBarState(accessibilityTrusted: { false }) }
    let daemon = try Daemon(
      options: DaemonOptions(arguments: ["--config", directory.appending(path: "missing.toml").path,
        "--socket", directory.appending(path: "daemon.sock").path]),
      menuBar: menuBar, instanceLockURL: directory.appending(path: "daemon.lock"),
      topologyStore: WorkspaceTopologyStore(url: directory.appending(path: "topology.json")),
      workspaceStatePublisher: { _ in }, desktopSnapshotOverviewUpdater: { _ in })
    daemon.restorationInFlight = true
    defer { daemon.flushPendingTopologyWrite() }
    let monitor = MonitorID(rawValue: 1)
    let window = WindowID(rawValue: 1)
    let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)
    daemon.latestMonitors = [MonitorSnapshot(id: monitor, frame: viewport)]
    daemon.state.attachMonitor(monitor)
    for id in 1...5 {
      try discoverWindow(Window(id: WindowID(rawValue: UInt64(id)), appID: "test", title: "test",
        frame: viewport, monitorID: monitor), decision: RuleDecision(followFocus: true),
        isNativelyFocused: true, state: &daemon.state)
    }
    focusWindow(window, state: &daemon.state)
    daemon.state.monitors[0].workspaces[0].scrollOffset = 0
    daemon.state.monitors[0].workspaces[0].targetScrollOffset = 0
    daemon.beginMouseGesture()
    let initial = daemon.state
    // A held click has no confirmed translation and cannot start edge scrolling.
    #expect(!daemon.advanceDragEdgeScrolling(pointer: (995, 200), buttonDown: true, now: 0))
    #expect(daemon.state == initial)
    daemon.activelyResizedWindowID = window
    daemon.mouseGestureInitialFrame = viewport
    daemon.mouseGestureChangedWindowFrame = true
    daemon.dragEdgeScrolling = DragEdgeScrolling(windowID: window, generation: daemon.mouseGestureGeneration,
      state: daemon.state, viewports: daemon.viewportsByMonitor, monitorFrames: [monitor: viewport])
    if outcome == "native-release" {
      // A translation with no edge scroll and no preview retains the native
      // reorder/stack fallback, rather than treating the session as cancellation.
      var windows = Array(daemon.state.windows.values)
      let index = try #require(windows.firstIndex(where: { $0.id == window }))
      windows[index].frame.x = 1_600
      daemon.applyDesktopSnapshot(DesktopSnapshot(monitors: daemon.latestMonitors, windows: windows,
        focusedWindowID: window, leftMouseButtonDown: false), nativeFocusWasPending: false,
        forceFullWindowRefresh: false, forceWindowListRefresh: false,
        forceApplicationInventoryRefresh: false, targetedWindowRetryRefresh: false,
        consumePeriodicWindowRefresh: false)
      #expect(daemon.state.monitors[0].workspaces[0].columns != initial.monitors[0].workspaces[0].columns)
      #expect(daemon.state.selectedWindowID(on: monitor) == window)
      #expect(daemon.dragEdgeScrolling == nil)
      return
    }
    #expect(!daemon.advanceDragEdgeScrolling(pointer: (995, 200), buttonDown: true, now: 0))
    #expect(daemon.advanceDragEdgeScrolling(pointer: (995, 200), buttonDown: true, now: 0.3))
    #expect(daemon.state.monitors[0].workspaces[0].scrollOffset > 0)
    #expect(daemon.proxyPreviewTarget != nil)
    if outcome == "release" {
      for tick in 19...180 {
        daemon.advanceDragEdgeScrolling(pointer: (995, 200), buttonDown: true, now: Double(tick) / 60)
      }
      let offset = daemon.state.monitors[0].workspaces[0].scrollOffset
      let target = try #require(daemon.proxyPreviewTarget)
      var expected = daemon.state
      #expect(applyMouseDrop(window, target, state: &expected, viewports: daemon.viewportsByMonitor))
      var windows = Array(daemon.state.windows.values)
      let index = try #require(windows.firstIndex(where: { $0.id == window }))
      windows[index].frame.x += 100
      daemon.applyDesktopSnapshot(DesktopSnapshot(monitors: daemon.latestMonitors, windows: windows,
        focusedWindowID: window, leftMouseButtonDown: false), nativeFocusWasPending: false,
        forceFullWindowRefresh: false, forceWindowListRefresh: false,
        forceApplicationInventoryRefresh: false, targetedWindowRetryRefresh: false,
        consumePeriodicWindowRefresh: false)
      #expect(daemon.state.monitors[0].workspaces[0].columns == expected.monitors[0].workspaces[0].columns)
      #expect(daemon.state.monitors[0].workspaces[0].scrollOffset == offset)
    } else {
      #expect(!daemon.advanceDragEdgeScrolling(pointer: (995, 200), buttonDown: false, now: 1))
      daemon.preemptMouseGesture()
      #expect(daemon.state == initial)
    }
    #expect(daemon.dragEdgeScrolling == nil)
    #expect(daemon.proxyPreviewTarget == nil)
    #expect(!daemon.advanceDragEdgeScrolling(pointer: (995, 200), buttonDown: true, now: 2))
  }
}
