import DefiConfig
import DefiCore
import DefiModel
@testable import DefiRuntime
import Foundation
import Synchronization
import Testing

@testable import DefiDaemon
@testable import DefiMacOS
@testable import DefiUI

struct DaemonDesktopSynchronizationTests {
  @Test(arguments: [
    (CenterFocusedColumn.always, UInt64(2), 0.25),
    (CenterFocusedColumn.always, UInt64(3), 0.75),
    (CenterFocusedColumn.never, UInt64(3), 0.5),
    (CenterFocusedColumn.onOverflow, UInt64(2), 0.0),
    (CenterFocusedColumn.onOverflow, UInt64(3), 0.75),
  ])
  @NavigationActor
  func nativeDesktopFocusRespectsConfiguredScroll(
    centering: CenterFocusedColumn, focusedWindow: UInt64, expectedOffset: Double
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

  /// A restart hands windows over where they are: a floating window parked on an inactive
  /// workspace keeps the frame it returns to, which only the daemon's memory held.
  @Test
  @NavigationActor
  func restartHandoffKeepsParkedFloatingFrames() async throws {
    let directory = URL(filePath: "/tmp/defi-handoff-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appending(path: "config.toml")
    try "[animation]\nenabled = false\n".write(to: configURL, atomically: true, encoding: .utf8)
    let menuBar = await MainActor.run { MenuBarState(accessibilityTrusted: { false }) }
    func daemon(_ name: String) throws -> Daemon {
      try Daemon(
        options: DaemonOptions(arguments: [
          "--config", configURL.path, "--socket", directory.appending(path: "\(name).sock").path,
        ]),
        menuBar: menuBar,
        instanceLockURL: directory.appending(path: "\(name).lock"),
        topologyStore: WorkspaceTopologyStore(url: directory.appending(path: "topology.json")),
        workspaceStatePublisher: { _ in },
        desktopSnapshotOverviewUpdater: { _ in }
      )
    }
    let frame = Rect(x: 300, y: 200, width: 400, height: 300)
    let monitor = MonitorSnapshot(id: MonitorID(rawValue: 1), frame: Rect(x: 0, y: 0, width: 1_000, height: 700))
    // Parked at the screen edge, as on an inactive workspace.
    let parked = Window(id: WindowID(rawValue: 7), appID: "app", title: "Tool",
      frame: Rect(x: 999, y: 200, width: 400, height: 300), monitorID: monitor.id,
      floating: true, floatingOrigin: .automatic)
    let first = try daemon("first")
    first.state.attachMonitor(monitor.id)
    try discoverWindow(parked, decision: RuleDecision(), state: &first.state)
    first.floatingWindowFrames[parked.id] = frame
    first.saveTopologyForHandoff()

    let next = try daemon("next")
    next.restorationInFlight = true
    next.applyDesktopSnapshot(
      DesktopSnapshot(monitors: [monitor], windows: [parked], focusedWindowID: nil),
      nativeFocusWasPending: false, forceFullWindowRefresh: false, forceWindowListRefresh: false,
      forceApplicationInventoryRefresh: false, targetedWindowRetryRefresh: false,
      consumePeriodicWindowRefresh: false)
    #expect(next.floatingWindowFrames[parked.id] == frame)
  }

  /// A release over a stack the window cannot join changes nothing, also when a late
  /// mouse event makes the next snapshot look like a release-only gesture.
  @Test
  @NavigationActor
  func rejectedStackDropSurvivesALateGestureSnapshot() async throws {
    let directory = URL(filePath: "/tmp/defi-rejected-drop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appending(path: "config.toml")
    try "[layout]\ndefault_column_width = 0.5\n[animation]\nenabled = false\n"
      .write(to: configURL, atomically: true, encoding: .utf8)
    let menuBar = await MainActor.run { MenuBarState(accessibilityTrusted: { false }) }
    let daemon = try Daemon(
      options: DaemonOptions(arguments: ["--config", configURL.path, "--socket", directory.appending(path: "d.sock").path]),
      menuBar: menuBar,
      instanceLockURL: directory.appending(path: "d.lock"),
      topologyStore: WorkspaceTopologyStore(url: directory.appending(path: "topology.json")),
      workspaceStatePublisher: { _ in },
      desktopSnapshotOverviewUpdater: { _ in }
    )
    defer { daemon.flushPendingTopologyWrite() }
    let monitor = MonitorSnapshot(id: MonitorID(rawValue: 1), frame: Rect(x: 0, y: 0, width: 1_000, height: 700))
    daemon.latestMonitors = [monitor]
    daemon.activeMonitorID = monitor.id
    daemon.state.attachMonitor(monitor.id)
    // Frames at the layout's targets: the drag detection compares sizes with them.
    func window(_ id: UInt64, x: Double) -> Window {
      Window(id: WindowID(rawValue: id), appID: "app-\(id)", title: "Window \(id)",
        frame: Rect(x: x, y: 12, width: 480, height: 676), monitorID: monitor.id)
    }
    let f = WindowID(rawValue: 1), g = WindowID(rawValue: 2)
    for discovered in [window(1, x: 12), window(2, x: 508)] {
      try discoverWindow(discovered, decision: RuleDecision(), isNativelyFocused: false, state: &daemon.state)
    }
    focusWindow(g, state: &daemon.state)
    func columns() -> [[WindowID]] { daemon.state.monitors[0].workspaces[0].columns.map(\.windows) }
    func sync(gAt x: Double, buttonDown: Bool, gesture: Bool) {
      daemon.applyDesktopSnapshot(
        DesktopSnapshot(monitors: [monitor], windows: [window(1, x: 12), window(2, x: x)], focusedWindowID: g,
          externallyChangedFrames: gesture ? [g: window(2, x: x).frame] : [:], leftMouseButtonDown: buttonDown,
          mouseResizeGestureObserved: gesture, mouseFocusIntentWindowID: g),
        nativeFocusWasPending: false, forceFullWindowRefresh: false, forceWindowListRefresh: false,
        forceApplicationInventoryRefresh: false, targetedWindowRetryRefresh: false,
        consumePeriodicWindowRefresh: false)
    }
    leftPressPointerTravelled.store(true, ordering: .relaxed)
    defer { leftPressPointerTravelled.store(false, ordering: .relaxed) }

    sync(gAt: 508, buttonDown: false, gesture: false)
    #expect(columns() == [[f], [g]])
    daemon.beginMouseGesture()
    sync(gAt: 260, buttonDown: true, gesture: true)
    let rejected = MouseStackTarget(monitorID: monitor.id, workspaceID: daemon.state.monitors[0].workspaces[0].id,
      columnIndex: 0, row: 0)
    daemon.proxyPreviewTarget = .rejectedStack(rejected)
    sync(gAt: 20, buttonDown: false, gesture: true)
    #expect(columns() == [[f], [g]], "The rejected drop must change nothing")
    #expect(daemon.platform.frameCoordinatorTrace.contains("mouse-drop window=2 target=rejectedStack"))
    // The release's own mouse event can land after its snapshot and mark the next one.
    sync(gAt: 10, buttonDown: false, gesture: true)
    #expect(columns() == [[f], [g]], "A late gesture snapshot must not reorder the rejected window natively")
  }

  /// A floating window an app opens on another display, such as Settings where the app last
  /// left it, moves to its app's display or else to the active one, frame included, unless
  /// the active display shows a native fullscreen Space.
  @Test(arguments: [("editor", false, true), ("settings", false, true), ("settings", true, false)])
  @NavigationActor
  func newFloatingWindowOpensOnTheActiveDisplay(
    appID: String, activeDisplayIsFullscreen: Bool, moves: Bool
  ) async throws {
    let directory = URL(filePath: "/tmp/defi-floating-open-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appending(path: "config.toml")
    try "[animation]\nenabled = false\n".write(to: configURL, atomically: true, encoding: .utf8)
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
    daemon.restorationInFlight = true
    let first = MonitorSnapshot(id: MonitorID(rawValue: 1), frame: Rect(x: 0, y: 0, width: 1_000, height: 700))
    let second = MonitorSnapshot(
      id: MonitorID(rawValue: 2), frame: Rect(x: 1_000, y: 0, width: 1_000, height: 700))
    let editor = Window(id: WindowID(rawValue: 1), appID: "editor", title: "Editor",
      frame: Rect(x: 1_000, y: 0, width: 800, height: 700), processID: 1, monitorID: second.id)
    let settings = Window(id: WindowID(rawValue: 2), appID: appID, title: "Settings",
      frame: Rect(x: 100, y: 100, width: 400, height: 300), processID: appID == "editor" ? 1 : 2,
      monitorID: first.id, floating: true, floatingOrigin: .automatic)
    func apply(_ windows: [Window], focused: WindowID) {
      daemon.applyDesktopSnapshot(
        DesktopSnapshot(monitors: [first, second], windows: windows,
          activeNativeFullscreenWindowIDs: activeDisplayIsFullscreen ? [editor.id] : [],
          focusedWindowID: focused, nativeFocusChanged: true,
          frontmostProcessID: windows.last?.processID),
        nativeFocusWasPending: false, forceFullWindowRefresh: false, forceWindowListRefresh: false,
        forceApplicationInventoryRefresh: false, targetedWindowRetryRefresh: false,
        consumePeriodicWindowRefresh: false
      )
    }
    apply([editor], focused: editor.id)
    daemon.activeMonitorID = second.id

    apply([editor, settings], focused: settings.id)

    #expect(daemon.state.monitorID(containing: settings.id) == (moves ? second.id : first.id))
    #expect(daemon.floatingWindowFrames[settings.id] == Rect(x: moves ? 1_100 : 100, y: 100, width: 400, height: 300))

    // The app grows the window once it has moved (Finder's Settings): its size is the app's.
    var grown = settings
    grown.frame = Rect(x: moves ? 1_100 : 100, y: 100, width: 400, height: 310)
    grown.monitorID = moves ? second.id : first.id
    // The move's write still waits on a commit that the grown height never matches.
    if moves { daemon.platform.targetFrames[settings.id] = Rect(x: 1_100, y: 100, width: 400, height: 300) }
    apply([editor, grown], focused: settings.id)
    #expect(daemon.floatingWindowFrames[settings.id] == grown.frame)
  }

  /// A close that brings a parked column into view while native focus is pending holds that
  /// column back; the snapshot after the focus resolves must still write it.
  @Test
  @NavigationActor
  func windowHeldBackForPendingNativeFocusIsWrittenOnceFocusResolves() async throws {
    let directory = URL(filePath: "/tmp/defi-held-back-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appending(path: "config.toml")
    try "[layout]\ndefault_column_width = 0.5\ngaps = 0\n[animation]\nenabled = false\n"
      .write(to: configURL, atomically: true, encoding: .utf8)
    let menuBar = await MainActor.run { MenuBarState(accessibilityTrusted: { false }) }
    let daemon = try Daemon(
      options: DaemonOptions(arguments: ["--config", configURL.path, "--socket", directory.appending(path: "d.sock").path]),
      menuBar: menuBar,
      instanceLockURL: directory.appending(path: "d.lock"),
      topologyStore: WorkspaceTopologyStore(url: directory.appending(path: "topology.json")),
      workspaceStatePublisher: { _ in },
      desktopSnapshotOverviewUpdater: { _ in }
    )
    defer { daemon.flushPendingTopologyWrite() }
    let monitor = MonitorSnapshot(id: MonitorID(rawValue: 1), frame: Rect(x: 0, y: 0, width: 1_000, height: 700))
    daemon.latestMonitors = [monitor]
    daemon.activeMonitorID = monitor.id
    daemon.state.attachMonitor(monitor.id)
    let windows = (1...4).map { id in
      Window(id: WindowID(rawValue: UInt64(id)), appID: "app", title: "Window \(id)",
        frame: Rect(x: Double(id - 1) * 500, y: 0, width: 500, height: 700), monitorID: monitor.id)
    }
    for window in windows {
      try discoverWindow(window, decision: RuleDecision(followFocus: true), isNativelyFocused: true,
        state: &daemon.state)
    }
    focusWindow(windows[0].id, state: &daemon.state)
    synchronizeScrollOffsets(state: &daemon.state, viewports: [monitor.id: monitor.frame])
    daemon.state.monitors[0].workspaces[0].scrollOffset = 0
    daemon.state.monitors[0].workspaces[0].targetScrollOffset = 0
    func sync(_ windows: [Window], focusPending: Bool) {
      daemon.applyDesktopSnapshot(
        DesktopSnapshot(monitors: [monitor], windows: windows, focusedWindowID: windows[0].id,
          nativeFocusChanged: focusPending),
        nativeFocusWasPending: focusPending, forceFullWindowRefresh: false, forceWindowListRefresh: false,
        forceApplicationInventoryRefresh: false, targetedWindowRetryRefresh: false,
        consumePeriodicWindowRefresh: false)
    }
    sync(windows, focusPending: false)
    let third = windows[2].id
    #expect(daemon.platform.lastHiddenWindowIDs == [third, windows[3].id])

    daemon.needsDesktopSync = false
    sync([windows[0], windows[2], windows[3]], focusPending: true)
    #expect(daemon.platform.lastHiddenWindowIDs.contains(third), "Held back while native focus resolves")
    #expect(daemon.needsDesktopSync, "Nothing else is coming to write the window that should now show")

    sync([windows[0], windows[2], windows[3]], focusPending: false)
    #expect(daemon.platform.lastHiddenWindowIDs == [windows[3].id])
    #expect((daemon.platform.targetFrames[third]?.x ?? .infinity) < monitor.frame.width)
  }

  @Test func displayShowingAFullscreenSpaceGetsNoBorderOrDim() {
    let id = { WindowID(rawValue: $0) }
    let monitors: [WindowID: MonitorID] = [id(1): MonitorID(rawValue: 1), id(2): MonitorID(rawValue: 1),
      id(3): MonitorID(rawValue: 2)]
    let assignments = [1, 3].map { FrameAssignment(windowID: id($0), frame: Rect(x: 0, y: 0, width: 10, height: 10)) }
    let shown = borderAssignmentsOutsideFullscreen(
      assignments, fullscreenWindowIDs: [id(2)], monitorOf: { monitors[$0] })
    #expect(shown.map(\.windowID) == [id(3)])
  }
}
