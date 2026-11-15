import DefiConfig
import DefiCore
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation
import Testing

@testable import DefiDaemon

struct DaemonOverviewSnapshotTests {
  @Test @NavigationActor
  func overviewShowsFullscreenPlaceholderWhereTheStripDoes() async throws {
    let directory = URL(filePath: "/tmp/defi-overview-\(UUID().uuidString)")
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
    let monitorID = MonitorID(rawValue: 1)
    daemon.state.attachMonitor(monitorID)
    let windows = (1...3).map {
      Window(
        id: WindowID(rawValue: $0), appID: "app", title: "Window",
        frame: Rect(x: 0, y: 0, width: 500, height: 700), monitorID: monitorID)
    }
    reconcileWindows(windows, config: Config(), state: &daemon.state)
    reconcileWindows(
      windows, config: Config(), nativeFullscreenWindowIDs: [WindowID(rawValue: 1)],
      state: &daemon.state)

    let strip = daemon.state.monitors[0].workspaces[0].columns.map(\.windows)
    #expect(strip.last == [WindowID(rawValue: 1)])
    let overview = daemon.makeOverviewSnapshot().monitors[0].workspaces[0].columns.map(\.windows)
    #expect(overview == strip)
  }
}
