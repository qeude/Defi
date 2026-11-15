import CoreGraphics
import DefiConfig
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation
import Testing

@testable import DefiDaemon

struct ScrollPanTests {
  // A laptop below-left of a taller external display, as in a staircase arrangement.
  private let displays: [(MonitorID, Rect)] = [
    (MonitorID(rawValue: 1), Rect(x: 0, y: 0, width: 2560, height: 1440)),
    (MonitorID(rawValue: 2), Rect(x: -1512, y: 1440, width: 1512, height: 982)),
  ]

  @Test
  func `A gesture moves the display under the pointer, and only that one`() {
    #expect(scrollPanMonitorID(at: CGPoint(x: 1280, y: 700), displays: displays) == MonitorID(rawValue: 1))
    #expect(scrollPanMonitorID(at: CGPoint(x: -700, y: 2000), displays: displays) == MonitorID(rawValue: 2))
    #expect(scrollPanMonitorID(at: CGPoint(x: -700, y: 700), displays: displays) == nil)
  }

  @Test
  func `The strip shift rubber-bands past the ends and the workspace stack holds one step`() {
    let pan = ScrollPan(id: 1, vertical: true, monitorID: MonitorID(rawValue: 1),
      workspaceID: WorkspaceID(rawValue: "a"), viewport: Rect(x: 0, y: 0, width: 2560, height: 1440),
      start: 0, scale: 1440 / scrollPanWorkspaceTravel, bounds: -1440...0, dimension: 72, stiffness: 0.5,
      rest: 0, stripWidth: 2560, workspaceHeight: 1440, steps: 0...1)
    #expect(pan.shift(travel: -100) == -100 * 1440 / scrollPanWorkspaceTravel)
    // Pulling up from the top workspace stays within Niri's 5% band.
    #expect(pan.shift(travel: 10_000) < 72)
    #expect(pan.shift(travel: -10_000) > -1440 - 72)
    #expect(abs(scrollPanProjection - 0.333) < 0.001)
  }

  /// A swipe reaches the native fullscreen placeholder at the strip's end, as key presses do,
  /// and only selects it: the fullscreen Space stays where it is.
  @Test @NavigationActor
  func `A swipe selects the fullscreen placeholder without focusing its window`() async throws {
    let directory = URL(filePath: "/tmp/defi-swipe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appending(path: "config.toml")
    try "[layout]\ndefault_column_width = 0.5\ngaps = 0\n[animation]\nenabled = false\n"
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
    let monitor = MonitorSnapshot(id: monitorID, frame: Rect(x: 0, y: 0, width: 1_000, height: 700))
    daemon.latestMonitors = [monitor]
    daemon.activeMonitorID = monitorID
    daemon.state.attachMonitor(monitorID)
    for id in 1...4 {
      try discoverWindow(
        Window(id: WindowID(rawValue: UInt64(id)), appID: "app-\(id)", title: "Window \(id)",
          frame: Rect(x: 0, y: 0, width: 500, height: 700), monitorID: monitorID),
        decision: RuleDecision(followFocus: true), isNativelyFocused: true, state: &daemon.state)
    }
    // Window 4 went native fullscreen: its column is the placeholder at the end.
    daemon.state.nativeFullscreenWindowIDs = [WindowID(rawValue: 4)]
    focusWindow(WindowID(rawValue: 3), state: &daemon.state)
    synchronizeScrollOffsets(state: &daemon.state, viewports: [monitorID: monitor.frame])
    daemon.state.monitors[0].workspaces[0].scrollOffset = 0.5
    #expect(daemon.state.monitors[0].workspaces[0].targetScrollOffset == 0.5)

    // Half a screen to the left, released at rest.
    daemon.handleScrollGesture(.panBegan(id: 1, vertical: false, location: CGPoint(x: 500, y: 350), timestamp: 0))
    daemon.handleScrollGesture(.panEnded(id: 1, travel: -750, velocity: 0, timestamp: 0.3))

    #expect(daemon.state.monitors[0].workspaces[0].focusedColumn == 3)
    #expect(daemon.state.monitors[0].workspaces[0].targetScrollOffset == 1)
    #expect(daemon.focus.pendingAnimatedFocus == nil)
    #expect(daemon.focus.submittedCommandFocus == nil)
  }
}
