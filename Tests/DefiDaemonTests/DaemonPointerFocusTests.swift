import DefiConfig
import DefiModel
import DefiRuntime
import Foundation
import Testing

@testable import DefiDaemon
@testable import DefiMacOS
@testable import DefiUI

struct DaemonPointerFocusTests {
  @Test(arguments: [("isolated", true), ("suspended", false)])
  @NavigationActor
  func pointerFocusWaitsWhileSystemSettingsLiftsTheStaircase(
    arrangement: String, follows: Bool
  ) async throws {
    let directory = URL(filePath: "/tmp/defi-pointer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appending(path: "config.toml")
    try "[input]\nfocus_follows_mouse = true\n[animation]\nenabled = false\n"
      .write(to: configURL, atomically: true, encoding: .utf8)
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
    defer { daemon.flushPendingTopologyWrite() }
    let monitorID = MonitorID(rawValue: 1)
    let frame = Rect(x: 0, y: 0, width: 1_000, height: 700)
    daemon.latestMonitors = [MonitorSnapshot(id: monitorID, frame: frame)]
    daemon.activeMonitorID = monitorID
    daemon.state.attachMonitor(monitorID)
    for id in 1...2 {
      try discoverWindow(
        Window(
          id: WindowID(rawValue: UInt64(id)), appID: "app-\(id)", title: "Window \(id)",
          frame: Rect(x: Double(id - 1) * 500, y: 0, width: 500, height: 700), monitorID: monitorID
        ),
        decision: RuleDecision(followFocus: true), isNativelyFocused: id == 1, state: &daemon.state
      )
    }
    focusWindow(WindowID(rawValue: 1), state: &daemon.state)
    daemon.displayArrangementStatus = arrangement

    let target = WindowID(rawValue: 2)
    daemon.applyPointerMotion(
      PointerMotionInvocation(windowID: target, timestamp: .greatestFiniteMagnitude),
      pointerWindowID: target
    )

    #expect((daemon.lastPointerWindowID == target) == follows)
  }
}
