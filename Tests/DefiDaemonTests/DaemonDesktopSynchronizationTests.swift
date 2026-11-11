import DefiConfig
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation
import Synchronization
import Testing

@testable import DefiDaemon

struct DaemonDesktopSynchronizationTests {
  @Test(arguments: [
    (CenterFocusedColumnConfig.always, UInt64(2), 0.25),
    (CenterFocusedColumnConfig.always, UInt64(3), 0.75),
    (CenterFocusedColumnConfig.never, UInt64(3), 0.5),
    (CenterFocusedColumnConfig.onOverflow, UInt64(2), 0.0),
    (CenterFocusedColumnConfig.onOverflow, UInt64(3), 0.75),
  ])
  @NavigationActor
  func nativeDesktopFocusRespectsConfiguredScroll(
    centering: CenterFocusedColumnConfig, focusedWindow: UInt64, expectedOffset: Double
  ) async throws {
    let directory = URL(filePath: "/tmp/defi-focus-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appending(path: "config.toml")
    let socketURL = directory.appending(path: "daemon.sock")
    let lockURL = directory.appending(path: "daemon.lock")
    let topologyStore = WorkspaceTopologyStore(url: directory.appending(path: "topology.json"))
    try """
      [layout]
      default_column_width = 0.5
      center_focused_column = "\(centering.rawValue)"
      gaps = 0
      [animation]
      enabled = false
      """.write(to: configURL, atomically: true, encoding: .utf8)
    let menuBar = await MainActor.run { MenuBarState(accessibilityTrusted: { false }) }
    let publications = Mutex<[Data]>([])

    func exerciseSnapshot() throws {
      let daemon = try Daemon(
        options: DaemonOptions(arguments: ["--config", configURL.path, "--socket", socketURL.path]),
        menuBar: menuBar,
        instanceLockURL: lockURL,
        topologyStore: topologyStore,
        workspaceStatePublisher: { data in publications.withLock { $0.append(data) } },
        desktopSnapshotOverviewUpdater: { _ in }
      )
      defer { daemon.flushPendingTopologyWrite() }
      daemon.restorationInFlight = true
      let monitorID = MonitorID(rawValue: 1)
      let monitor = MonitorSnapshot(
        id: monitorID, frame: Rect(x: 0, y: 0, width: 1_000, height: 700)
      )
      daemon.latestMonitors = [monitor]
      daemon.activeMonitorID = monitorID
      daemon.state.attachMonitor(monitorID)
      let windows = (1...4).map { id in
        Window(
          id: WindowID(rawValue: UInt64(id)), appID: "app-\(id)", title: "Window \(id)",
          frame: Rect(x: Double(id - 1) * 500, y: 0, width: 500, height: 700),
          monitorID: monitorID
        )
      }
      for window in windows {
        try discoverWindow(
          window, decision: RuleDecision(followFocus: true), isNativelyFocused: true,
          state: &daemon.state
        )
      }
      focusWindow(WindowID(rawValue: 1), state: &daemon.state)
      synchronizeScrollOffsets(state: &daemon.state, viewports: [monitorID: monitor.frame])
      daemon.state.monitors[0].workspaces[0].scrollOffset = 0
      daemon.state.monitors[0].workspaces[0].targetScrollOffset = 0
      #expect(daemon.state.selectedWindowID(on: monitorID) == WindowID(rawValue: 1))
      #expect(daemon.state.monitors[0].workspaces[0].columns.map(\.width)
        == Array(repeating: .fraction(0.5), count: 4))

      daemon.applyDesktopSnapshot(
        DesktopSnapshot(
          monitors: [monitor], windows: windows,
          focusedWindowID: WindowID(rawValue: focusedWindow), nativeFocusChanged: true,
          keyboardFocusIntentTimestamp: 1
        ),
        nativeFocusWasPending: true,
        forceFullWindowRefresh: false,
        forceWindowListRefresh: false,
        forceApplicationInventoryRefresh: false,
        targetedWindowRetryRefresh: false,
        consumePeriodicWindowRefresh: false
      )

      #expect(daemon.state.selectedWindowID(on: monitorID) == WindowID(rawValue: focusedWindow))
      #expect(daemon.state.monitors[0].workspaces[0].focusedColumn == Int(focusedWindow - 1))
      #expect(daemon.state.monitors[0].workspaces[0].targetScrollOffset == expectedOffset)
      #expect(daemon.state.monitors[0].workspaces[0].scrollOffset == expectedOffset)
      #expect(publications.withLock { $0.count } == 1)
      daemon.flushPendingTopologyWrite()
      #expect(try topologyStore.load(sessionID: daemon.topologySessionID) == daemon.state.topology)
    }

    try exerciseSnapshot()
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    #expect(!FileManager.default.fileExists(atPath: socketURL.path))
    let releasedLock = try DaemonInstanceLock(url: lockURL)
    withExtendedLifetime(releasedLock) {}
  }

  /// A window whose title arrives just after it opens ends where it would have opened with that title.
  @Test(arguments: [
    "[[rules]]\ntitle = \"Web Inspector\"\nworkspace = \"web\"",
    "[[rules]]\ntitle = \"Web Inspector\"\nwindow = \"force-floating\"\nmonitor = \"Second\"",
    // Already floating when it opens.
    "[[rules]]\napp_id = \"dialog\"\nwindow = \"force-floating\"\n[[rules]]\ntitle = \"Web Inspector\"\nmonitor = \"Second\"",
  ])
  @NavigationActor
  func lateTitleRuleMovesTheWindowAsAnOpeningWould(rules: String) async throws {
    struct Outcome: Equatable {
      var monitorID: MonitorID?
      var workspaceID: WorkspaceID?
      var activeWorkspaceID: WorkspaceID?
      var selected: Bool
      var activeMonitorID: MonitorID?
      var floatingFrame: Rect?
    }
    let menuBar = await MainActor.run { MenuBarState(accessibilityTrusted: { false }) }
    func open(late: Bool) throws -> Outcome {
      let directory = URL(filePath: "/tmp/defi-late-title-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let configURL = directory.appending(path: "config.toml")
      try """
        [workspaces]
        names = ["web"]
        [animation]
        enabled = false
        \(rules)
        """.write(to: configURL, atomically: true, encoding: .utf8)
      let daemon = try Daemon(
        options: DaemonOptions(arguments: [
          "--config", configURL.path, "--socket", directory.appending(path: "daemon.sock").path,
        ]),
        menuBar: menuBar,
        instanceLockURL: directory.appending(path: "daemon.lock"),
        topologyStore: WorkspaceTopologyStore(url: directory.appending(path: "topology.json")),
        workspaceStatePublisher: { _ in },
        desktopSnapshotOverviewUpdater: { _ in }
      )
      defer { daemon.flushPendingTopologyWrite() }
      daemon.restorationInFlight = true
      let first = MonitorSnapshot(
        id: MonitorID(rawValue: 1), frame: Rect(x: 0, y: 0, width: 1_000, height: 700), name: "First")
      let second = MonitorSnapshot(
        id: MonitorID(rawValue: 2), frame: Rect(x: 1_000, y: 0, width: 1_000, height: 700), name: "Second")
      let editor = Window(id: WindowID(rawValue: 1), appID: "app", title: "Editor",
        frame: Rect(x: 0, y: 0, width: 800, height: 700), monitorID: first.id)
      var opened = Window(id: WindowID(rawValue: 2), appID: "dialog", title: late ? "" : "Web Inspector",
        frame: Rect(x: 100, y: 100, width: 400, height: 300), monitorID: first.id)
      func apply(_ windows: [Window]) {
        daemon.applyDesktopSnapshot(
          DesktopSnapshot(monitors: [first, second], windows: windows, focusedWindowID: windows.last?.id,
            nativeFocusChanged: true),
          nativeFocusWasPending: false, forceFullWindowRefresh: false, forceWindowListRefresh: false,
          forceApplicationInventoryRefresh: false, targetedWindowRetryRefresh: false,
          consumePeriodicWindowRefresh: false
        )
      }
      apply([editor])
      apply([editor, opened])
      if late {
        opened.title = "Web Inspector"
        apply([editor, opened])
      }
      let location = daemon.state.location(containing: opened.id)
      return Outcome(
        monitorID: location?.monitorID,
        workspaceID: location?.workspaceID,
        activeWorkspaceID: daemon.state.monitors.first { $0.id == location?.monitorID }?.activeWorkspace,
        selected: location.map { daemon.state.selectedWindowID(on: $0.monitorID) == opened.id } ?? false,
        activeMonitorID: daemon.activeMonitorID,
        floatingFrame: daemon.floatingWindowFrames[opened.id]
      )
    }
    let immediate = try open(late: false)
    #expect(immediate.workspaceID == WorkspaceID(rawValue: "web") || immediate.monitorID == MonitorID(rawValue: 2))
    let late = try open(late: true)
    #expect(late == immediate)
  }
}
