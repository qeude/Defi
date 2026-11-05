import ApplicationServices
import DefiConfig
import DefiModel
import DefiRuntime
import Foundation
import Testing

@testable import DefiDaemon
@testable import DefiMacOS

/// Which motions the daemon animates, checked on a daemon that is never started: nothing draws.
@NavigationActor
struct DaemonAnimationGateTests {
  private let monitorID = MonitorID(rawValue: 1)
  private let windowID = WindowID(rawValue: 1)

  private func withDaemon(_ body: (Daemon) throws -> Void) async throws {
    let directory = URL(filePath: "/tmp/defi-anim-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appending(path: "config.toml")
    try """
      [workspaces]
      names = ["dev", "web"]
      [animation]
      enabled = true
      """.write(to: configURL, atomically: true, encoding: .utf8)
    let menuBar = await MainActor.run { MenuBarState(accessibilityTrusted: { false }) }
    let daemon = try Daemon(
      options: DaemonOptions(arguments: [
        "--config", configURL.path, "--socket", directory.appending(path: "daemon.sock").path,
      ]),
      menuBar: menuBar,
      instanceLockURL: directory.appending(path: "daemon.lock"),
      topologyStore: WorkspaceTopologyStore(url: directory.appending(path: "topology.json")),
      workspaceStatePublisher: { _ in },
      desktopSnapshotOverviewUpdater: { _ in },
      diagnostics: DiagnosticRecorder(directoryURL: directory.appending(path: "diagnostics"))
    )
    defer { daemon.flushPendingTopologyWrite() }
    daemon.restorationInFlight = true
    let frame = Rect(x: 0, y: 0, width: 1_000, height: 700)
    daemon.latestMonitors = [MonitorSnapshot(id: monitorID, frame: frame)]
    daemon.state.attachMonitor(monitorID)
    try discoverWindow(
      Window(id: windowID, appID: "editor", title: "Editor", frame: frame, monitorID: monitorID),
      decision: RuleDecision(followFocus: true), isNativelyFocused: true, state: &daemon.state
    )
    // A negative pid names no real process, so the element is a harmless frame-writable handle.
    let processID: pid_t = -4_242
    daemon.platform.elements[windowID] = AXUIElementCreateApplication(processID)
    daemon.platform.processIDs[windowID] = processID
    daemon.platform.applications[processID] = AXUIElementCreateApplication(processID)
    try body(daemon)
  }

  private func switchToWeb(_ daemon: Daemon) throws -> WorkspaceTransitionIntent {
    try #require(workspaceTransitionIntent(targetWorkspaceID: WorkspaceID(rawValue: "web"), state: daemon.state))
  }

  @Test
  func `A workspace switch on a lone display slides vertically`() async throws {
    try await withDaemon { daemon in
      #expect(daemon.animationsEnabled)
      let intent = try switchToWeb(daemon)
      #expect(daemon.safeWorkspaceVerticalTransition(intent)?.monitorID == monitorID)
    }
  }

  @Test
  func `A display the desktop does not report yet switches workspaces at once`() async throws {
    try await withDaemon { daemon in
      daemon.state.attachMonitor(MonitorID(rawValue: 2))
      let intent = try switchToWeb(daemon)
      #expect(daemon.safeWorkspaceVerticalTransition(intent) == nil)
    }
  }

  @Test
  func `Reduce Motion turns animations off`() async throws {
    try await withDaemon { daemon in
      daemon.platform.presentationStatus.reduceMotion = true
      #expect(!daemon.animationsEnabled)
    }
  }

  private func commandFocus(_ daemon: Daemon) -> PendingAnimatedFocus {
    PendingAnimatedFocus(
      windowID: windowID, previousSelectedWindowID: nil, monitorID: monitorID,
      sourceWorkspaceID: daemon.state.monitors[0].activeWorkspace, commandGeneration: daemon.commandGeneration,
      focusInputTimestamp: 1, cursorWarpInputTimestamp: nil)
  }

  @Test
  func `A mouse gesture that interrupts a scroll animation drops the focus the navigation still owed`() async throws {
    try await withDaemon { daemon in
      let workspaceID = daemon.state.monitors[0].activeWorkspace
      daemon.scrollAnimations[ScrollAnimationKey(monitorID: monitorID, workspaceID: workspaceID)] =
        ScrollAnimation(target: 0, velocity: 0, lastStepAt: 0, startedAt: 0)
      _ = daemon.focus.submitCommand(commandFocus(daemon))
      daemon.focus.queueCommand(commandFocus(daemon))
      daemon.cancelAnimationForMouseGesture()
      #expect(daemon.scrollAnimations.isEmpty)
      #expect(daemon.pendingAnimatedFocus == nil)
      #expect(daemon.focus.submittedCommandFocus == nil)
    }
  }

  @Test
  func `A preempted mouse gesture stays preempted until the next press`() async throws {
    try await withDaemon { daemon in
      daemon.beginMouseGesture()
      daemon.preemptMouseGesture()
      #expect(daemon.mouseGesturePreempted)
      daemon.beginMouseGesture()
      #expect(!daemon.mouseGesturePreempted)
    }
  }
}
