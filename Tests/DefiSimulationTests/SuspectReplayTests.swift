import AppKit
import DefiConfig
import DefiModel
import DefiRuntime
import Foundation
import Testing

@testable import DefiDaemon
@testable import DefiMacOS

/// Replays the known focus suspects (docs/testing/known-suspects.md) with the real daemon and the
/// real MacOSPlatform against two Defi fixture apps on a real desktop. A fixture's main thread
/// goes busy before each press, so Defi's focus write to it times out as in the simulation.
///
/// The daemon manages every window on the desktop, so this suite runs only on the CI runner
/// (`DEFI_E2E_SUSPECTS=1`, set by the desktop workflow), never on a person's Mac.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DEFI_E2E_SUSPECTS"] == "1"
  && !RealResourceGuard.isEnforced))
struct SuspectReplayTests {
  @Test @NavigationActor
  func knownFocusSuspectsOnTheRealDesktop() async throws {
    let desk = try await RealDesk()
    defer { desk.close() }
    var results: [String: [Bool]] = [:]
    var details: [String] = []
    for _ in 0..<12 {
      // seed 9: typing while a column focus is in flight.
      for (name, presses) in [("typing-during-focus", 1), ("superseded-write-then-typing", 2)] {
        let outcome = await desk.replay(presses: presses)
        results[name, default: []].append(outcome.agreed)
        if !outcome.agreed { details.append("DEFI_E2E suspect-round \(name) \(outcome.detail)") }
      }
    }
    var lines: [String] = []
    for (name, outcomes) in results.sorted(by: { $0.key < $1.key }) {
      let diverged = outcomes.filter { !$0 }.count
      lines.append("DEFI_E2E suspect \(name) diverged=\(diverged)/\(outcomes.count)")
    }
    lines += details
    print(lines.joined(separator: "\n"))
    if let out = ProcessInfo.processInfo.environment["DEFI_SUSPECT_OUT"] {
      try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }
    #expect(results.values.allSatisfy { $0.count == 12 })
  }
}

/// Two fixture apps, each with one window, managed by an in-process daemon on the real platform.
@NavigationActor
final class RealDesk {
  let platform = MacOSPlatform()
  let daemon: Daemon
  var input: InputMonitor!
  private let processes = [Process(), Process()]
  private let inputs = [Pipe(), Pipe()]
  private let directory: URL
  private(set) var windows: [WindowID: Int] = [:]

  init() async throws {
    let binary = try #require(ProcessInfo.processInfo.environment["DEFI_DESKTOP_FIXTURE_BINARY"])
    directory = URL(filePath: "/tmp/defi-suspects-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for index in processes.indices {
      let contents = directory.appending(path: "\(index).app/Contents")
      let executable = contents.appending(path: "MacOS/DefiDesktopFocusFixture")
      try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: URL(fileURLWithPath: binary), to: executable)
      let info = ["CFBundleIdentifier": "com.qeude.defi.suspect-fixture.\(index)", "CFBundlePackageType": "APPL",
        "CFBundleExecutable": "DefiDesktopFocusFixture", "NSPrincipalClass": "NSApplication"]
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appending(path: "Info.plist"))
      processes[index].executableURL = executable
      processes[index].arguments = ["Defi suspect fixture \(index)"]
      processes[index].standardInput = inputs[index]
      try processes[index].run()
    }
    let configURL = directory.appending(path: "config.toml")
    try """
      default_key_modifier = "ctrl-alt"
      [layout]
      default_column_width = 0.5
      [animation]
      enabled = false
      [decorations.borders]
      enabled = false
      [overview]
      window_previews = false
      [menu_bar]
      enabled = false
      """.write(to: configURL, atomically: true, encoding: .utf8)
    let menuBar = await MainActor.run { MenuBarState(accessibilityTrusted: { true }) }
    daemon = try Daemon(
      options: DaemonOptions(arguments: ["--config", configURL.path, "--socket", directory.appending(path: "d.sock").path]),
      menuBar: menuBar,
      instanceLockURL: directory.appending(path: "daemon.lock"),
      topologyStore: WorkspaceTopologyStore(url: directory.appending(path: "topology.json")),
      workspaceStatePublisher: { _ in },
      desktopSnapshotOverviewUpdater: { _ in },
      platform: platform,
      diagnostics: DiagnosticRecorder(directoryURL: directory.appending(path: "diagnostics"))
    )
    daemon.startHotKeys = { [weak self] manager in
      let input = manager.attachInputMonitorWithoutEventTaps(keyboardCaptured: { @Sendable in false })
      input.setHotKeysRegistered(true)
      self?.input = input
    }
    daemon.headless = true
    daemon.windowManagementStarted = true
    daemon.installHotKeys()
    // A launching app shows its window late; wait until both fixture windows are managed.
    for _ in 0..<200 where windows.count < 2 {
      daemon.needsDesktopSync = true
      await run(for: 0.05)
      for (index, process) in processes.enumerated() {
        if let window = daemon.state.windows.values.first(where: { $0.processID == process.processIdentifier }) {
          windows[window.id] = index
        }
      }
    }
    try #require(windows.count == 2, "both fixture windows must be discovered")
    await run(for: 1)
  }

  /// Ticks the daemon on real time. Without event observers, a sync every 100 ms stands in
  /// for the Accessibility notifications that would ask for one.
  func run(for seconds: TimeInterval) async {
    let deadline = Date().addingTimeInterval(seconds)
    var lastSync = Date.distantPast
    while Date() < deadline {
      if Date().timeIntervalSince(lastSync) >= 0.1 {
        daemon.needsDesktopSync = true
        lastSync = Date()
      }
      daemon.tick()
      try? await Task.sleep(for: .milliseconds(16))
    }
  }

  private func post(keyCode: CGKeyCode, flags: CGEventFlags) {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
    event.flags = flags
    event.timestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    _ = input.handle(type: .keyDown, event: event)
  }

  private var selected: WindowID? { daemon.state.selectedWindowID(on: daemon.state.monitors[0].id) }
  /// The window macOS focuses, as the daemon's latest real snapshot read it.
  private var nativeFocus: WindowID? { platform.lastNativeFocusedWindowID }

  /// Busy fixture, one or two column presses toward it, then typing; returns whether Defi and
  /// macOS agree on one window once calm, and typing kept its window.
  func replay(presses: Int) async -> (agreed: Bool, detail: String) {
    await run(for: 0.5)
    guard let current = selected, let other = windows.keys.first(where: { $0 != current }),
      let otherIndex = windows[other]
    else { return (false, "no selection") }
    inputs[otherIndex].fileHandleForWriting.write(Data("busy 300\n".utf8))
    let monitor = daemon.state.monitors[0]
    let columns = monitor.workspaces.first { $0.id == monitor.activeWorkspace }?.columns.flatMap(\.windows) ?? []
    // The first press goes toward the busy window, a second one comes back.
    let right = (columns.firstIndex(of: other) ?? 0) > (columns.firstIndex(of: current) ?? 0)
    for press in 0..<presses {
      post(keyCode: (press % 2 == 0) == right ? 124 : 123, flags: [.maskControl, .maskAlternate])
      try? await Task.sleep(for: .milliseconds(30))
    }
    let typedInto = nativeFocus
    post(keyCode: 0, flags: [])
    await run(for: 2)
    let native = nativeFocus
    let agreed = native == selected && (presses == 1 || native == typedInto)
    guard !agreed else { return (true, "") }
    let calm = "selected=\(id(selected)) native=\(id(native)) typedInto=\(id(typedInto)) from=\(id(current)) busy=\(id(other))"
    // A slow convergence is not a stuck one: look again after 3 more seconds.
    await run(for: 3)
    return (false, calm + " after3s selected=\(id(selected)) native=\(id(nativeFocus))")
  }

  private func id(_ window: WindowID?) -> String { window.map { "\($0.rawValue)" } ?? "-" }

  func close() {
    for input in inputs { try? input.fileHandleForWriting.close() }
    for process in processes where process.isRunning { process.terminate() }
    try? FileManager.default.removeItem(at: directory)
  }
}
