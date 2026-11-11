import DefiConfig
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation
import Testing

@testable import DefiDaemon

struct DaemonRecentWindowsTests {
  @Test @NavigationActor
  func switcherClosesWhenEveryListedWindowCloses() async throws {
    let directory = URL(filePath: "/tmp/defi-recent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appending(path: "config.toml")
    try "".write(to: configURL, atomically: true, encoding: .utf8)
    let menuBar = await MainActor.run { MenuBarState(accessibilityTrusted: { false }) }
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
    daemon.restorationInFlight = true
    let monitorID = MonitorID(rawValue: 1)
    daemon.activeMonitorID = monitorID
    daemon.state.attachMonitor(monitorID)
    try discoverWindow(
      Window(
        id: WindowID(rawValue: 1), appID: "app", title: "Window",
        frame: Rect(x: 0, y: 0, width: 500, height: 700), monitorID: monitorID),
      decision: RuleDecision(followFocus: true), isNativelyFocused: true, state: &daemon.state)

    #expect(daemon.handleRecentWindows(.next).ok)
    #expect(daemon.recentWindowsShowTask != nil)

    daemon.state.monitors[0].workspaces[0].columns = []
    daemon.refreshRecentWindowsIfOpen()

    #expect(!daemon.recentWindows.isOpen)
    #expect(daemon.recentWindowsShowTask == nil)
  }
}
