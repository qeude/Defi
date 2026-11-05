import ApplicationServices
import DefiConfig
import DefiCore
import DefiIPC
import DefiModel
import DefiRuntime
import Foundation

@testable import DefiDaemon
@testable import DefiMacOS

/// The real daemon and platform on a simulated macOS: keys reach the daemon's own
/// InputMonitor, focus and frame writes reach FakeMacOS, and the daemon's own desktop
/// synchronization reads the fake through a desktop snapshot.
@NavigationActor
final class DaemonFocusWorld {
  let monitor = MonitorSnapshot(
    id: MonitorID(rawValue: 1), frame: Rect(x: 0, y: 25, width: 1_440, height: 875),
    physicalFrame: Rect(x: 0, y: 0, width: 1_440, height: 900)
  )
  let windows = (1...4).map { WindowID(rawValue: UInt64($0)) }
  let processIDs: [pid_t]
  let owners: [WindowID: pid_t]
  let directory: URL
  let fake: FakeMacOS
  let platform: MacOSPlatform
  let daemon: Daemon
  var input: InputMonitor!
  var log: [String] = []
  // Ground truth for the oracle, kept apart from Defi's own view.
  var intendedWindowID: WindowID?
  var humanInputSinceIntent = false
  /// The window the user last typed into, until a newer intent: macOS must keep it.
  var typedIntoWindowID: WindowID?
  /// A focus notification macOS delivered that the next snapshot reports.
  private var focusNotificationDelivered = false

  /// Simulated time for every world of this process; the daemon reads it through DefiClock.
  nonisolated static let clock: VirtualClock = {
    let clock = VirtualClock()
    DefiClock.install(clock)
    return clock
  }()

  var clock: VirtualClock { Self.clock }

  init() async throws {
    _ = Self.clock
    let space = FakeMacOS.spaceForNextWorld()
    let processIDs = (0..<3).map { -(space * 100 + 11 + pid_t($0)) }
    self.processIDs = processIDs
    let owners: [WindowID: pid_t] = [
      windows[0]: processIDs[0], windows[1]: processIDs[1],
      windows[2]: processIDs[1], windows[3]: processIDs[2],
    ]
    self.owners = owners
    let fake = FakeMacOS(
      space: space, owners: owners,
      focused: [processIDs[0]: windows[0], processIDs[1]: windows[1], processIDs[2]: windows[3]],
      frontmost: processIDs[0]
    )
    self.fake = fake
    for (index, window) in windows.enumerated() {
      fake.setFrame(Rect(x: Double(index) * 100, y: 25, width: 700, height: 875), of: window)
    }
    // Unix socket paths are limited to 104 bytes, so the run directory stays short.
    directory = Self.processDirectory.appending(path: String(UUID().uuidString.prefix(8)), directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let configURL = directory.appending(path: "config.toml")
    // Animations, borders and previews draw Defi panels; the simulated desktop has no screen.
    // The modifier is explicit so the posted shortcuts match every revision's defaults.
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

    let frameWriter = AXFrameAccessibilityWriter(
      positionWriter: { @Sendable write, point in fake.moveWindow(write.element, to: point) },
      sizeWriter: { @Sendable write, size in fake.resizeWindow(write.element, to: size) },
      sizeReader: { @Sendable element in
        fake.readFrame(element).map { CGSize(width: $0.width, height: $0.height) }
      },
      positionReader: { @Sendable element in fake.readFrame(element).map { CGPoint(x: $0.x, y: $0.y) } },
      frameReader: { @Sendable element in fake.readFrame(element) },
      enhancedUIWriter: { @Sendable application, _ in fake.setEnhancedUserInterface(application) },
      nativePositionReader: { @Sendable windowID, _ in fake.frame(of: windowID).map { CGPoint(x: $0.x, y: $0.y) } }
    )
    var snapshotSource: MacOSPlatformSystem.SnapshotSource?
    let system = MacOSPlatformSystem(
      snapshotSource: { config, completion in snapshotSource?(config, completion) },
      frontmostProcessID: { @Sendable in fake.frontmostProcessID }
    )
    platform = MacOSPlatform(
      frameCoordinator: AXFrameCoordinator(
        accessibilityWriter: frameWriter,
        messagingTimeoutAccess: fake.timeoutAccess
      ),
      focusOperations: fake.operations,
      system: system
    )
    let writer = platform.focusWriter
    fake.writerBusy = { writer.isBusy }
    let menuBar = await MainActor.run { MenuBarState(accessibilityTrusted: { true }) }
    daemon = try Daemon(
      options: DaemonOptions(arguments: [
        "--config", configURL.path, "--socket", directory.appending(path: "daemon.sock").path,
      ]),
      menuBar: menuBar,
      instanceLockURL: directory.appending(path: "daemon.lock"),
      topologyStore: WorkspaceTopologyStore(url: directory.appending(path: "topology.json")),
      workspaceStatePublisher: { _ in },
      desktopSnapshotOverviewUpdater: { _ in },
      platform: platform,
      diagnostics: DiagnosticRecorder(directoryURL: directory.appending(path: "diagnostics"))
    )
    snapshotSource = { [weak self] _, completion in
      guard let self else { return }
      completion(self.snapshot())
    }
    daemon.startHotKeys = { [weak self] manager in
      let input = manager.attachInputMonitorWithoutEventTaps(keyboardCaptured: { @Sendable in
        fake.tapCallout()
        return false
      })
      input.setHotKeysRegistered(true)
      self?.input = input
    }
    daemon.headless = true
    daemon.windowManagementStarted = true
    daemon.installHotKeys()
    daemon.synchronizeDesktop(
      forceFullWindowRefresh: true, forceWindowListRefresh: true, forceApplicationInventoryRefresh: true
    )
    await settle()
    // Start from the column macOS shows, like a daemon launched on a calm desktop.
    focusNotificationDelivered = true
    daemon.needsDesktopSync = true
    daemon.tick()
    await settle()
  }

  /// Every world of this test process lives here; the campaign removes it when it ends.
  nonisolated static let processDirectory = URL(
    filePath: "/tmp/defi-sim-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory
  )

  var selectedWindowID: WindowID? { daemon.state.selectedWindowID(on: monitor.id) }

  // shortcut: stands in for SnapshotEngine's Accessibility and WindowServer reads and its
  // focus bookkeeping (activation confirmation, internal-focus echo suppression); upgrade
  // by routing those raw reads through the simulated macOS so the real engine runs.
  func snapshot() -> DesktopSnapshot {
    for window in windows {
      platform.elements[window] = fake.windowElement(window)
      platform.processIDs[window] = owners[window]
    }
    for processID in processIDs {
      platform.applications[processID] = fake.applicationElement(processID)
      platform.applicationWindowCounts[processID] = owners.values.filter { $0 == processID }.count
    }
    let focused = fake.keyWindow
    let changed = focusNotificationDelivered
    focusNotificationDelivered = false
    platform.lastNativeFocusedWindowID = focused
    platform.nativeFocusEventPending = false
    let input = platform.userInputTracker.snapshot
    if changed, let focused {
      platform.userInputTracker.recordObservedFocus(windowID: focused, processID: owners[focused] ?? 0)
    }
    let activation = platform.userInputTracker.pendingApplicationActivation(
      frontmostProcessID: fake.frontmostProcessID
    )
    let isActivation = changed && activation != nil && focused.flatMap { owners[$0] } == activation?.processID
    var keyboardIntent: TimeInterval?
    if let intent = input.latestFocusIntent, case .keyboard = intent.source { keyboardIntent = intent.timestamp }
    // The real snapshot reports windows away from their targets (MacOSPlatform+Snapshot), so
    // Defi rewrites frames an app moved; a parked window that holds its park is no mismatch.
    let mismatches = windows.compactMap { id -> FrameMismatch? in
      guard let actual = fake.frame(of: id), let target = platform.targetFrames[id],
        !approximatelyEqual(actual, target),
        !(platform.isWindowHidden(id) && parkedFrameHolds(actual, target: target)),
        targetIntersectsAnyMonitor(target, monitors: [monitor])
      else { return nil }
      return FrameMismatch(windowID: id, actual: actual, target: target)
    }
    for mismatch in mismatches { platform.pendingFrameCorrections[mismatch.windowID] = mismatch.actual }
    return DesktopSnapshot(
      monitors: [monitor],
      windows: windows.map { id in
        Window(
          id: id, appID: "app\(owners[id]!)", title: "\(id.rawValue)",
          frame: fake.frame(of: id)!, processID: owners[id], monitorID: monitor.id
        )
      },
      focusedWindowID: focused,
      nativeFocusChanged: changed,
      nativeFocusIsApplicationActivation: isActivation,
      applicationActivationTimestamp: isActivation ? activation?.timestamp : nil,
      latestUserInputTimestamp: input.latestEventTimestamp,
      keyboardFocusIntentTimestamp: keyboardIntent,
      targetMismatches: mismatches,
      frontmostProcessID: fake.frontmostProcessID
    )
  }

  /// Whether the last column press had a column to go to; a no-op press is no command.
  var pressHadTarget = true
  /// The workspace the latest workspace command chose, until other input follows.
  var intendedWorkspaceID: WorkspaceID?

  /// Where a workspace command lands: the adjacent workspace, which moving a column away from
  /// the empty trailing workspace keeps; nil when it would not move.
  func workspaceID(after down: Bool, moving: Bool) -> WorkspaceID? {
    let monitor = daemon.state.monitors[0]
    guard let index = monitor.workspaces.firstIndex(where: { $0.id == monitor.activeWorkspace }) else { return nil }
    if moving, monitor.workspaces[index].columns.isEmpty { return nil }
    let target = index + (down ? 1 : -1)
    guard monitor.workspaces.indices.contains(target) else { return nil }
    return monitor.workspaces[target].id
  }

  var activeWorkspaceID: WorkspaceID { daemon.state.monitors[0].activeWorkspace }

  /// Native moves of the last column press, per window (AGENTS.md: one move per motion).
  var pressMoves: [WindowID: Int] = [:]
  /// A violation a step observed while it ran, reported by the next check.
  var stepViolation: FocusViolation?
  /// Frame writes in the second half of the calm rounds, when nothing should move any more.
  var lateCalmWrites = 0

  func run(_ step: FocusStep) async {
    if step != .writerStep && step != .writerRuns { fake.noteStepWhileWriterWaits() }
    _ = fake.takeMoves()
    _ = fake.takeWrites()
    let hiddenBefore = Set(windows.filter(platform.isWindowHidden))
    let generationBefore = daemon.commandGeneration
    switch step {
    case .appRestoresHiddenWindow(let index):
      let window = windows[index]
      guard platform.isWindowHidden(window), let frame = fake.frame(of: window) else { break }
      fake.appMoves(window, to: Rect(x: monitor.frame.x + 100, y: frame.y, width: frame.width, height: frame.height))
      // What the AX moved notification does: ask for a desktop sync.
      daemon.needsDesktopSync = true
    case .switchWorkspace(let down), .moveColumnToWorkspace(let down):
      let moves = if case .moveColumnToWorkspace = step { true } else { false }
      // The latest intent is the workspace; its remembered selection is Defi's to choose.
      intendedWindowID = nil
      intendedWorkspaceID = workspaceID(after: down, moving: moves)
      humanInputSinceIntent = false
      typedIntoWindowID = nil
      post(keyCode: down ? 125 : 126, flags: moves ? [.maskControl, .maskAlternate, .maskShift] : [.maskControl, .maskAlternate])
    case .press(let preferRight, let writerStepsDuringTap):
      let columns = activeColumns
      intendedWorkspaceID = nil
      pressHadTarget = columns.count > 1
      guard pressHadTarget else {
        // One column or none: the press has nowhere to go and changes nothing.
        intendedWindowID = nil
        post(keyCode: preferRight ? 124 : 123, flags: [.maskControl, .maskAlternate])
        break
      }
      // The user aims from where they last aimed, or from the screen after typing.
      let column = humanInputSinceIntent || intendedWindowID == nil
        ? focusedColumn
        : columns.firstIndex(of: intendedWindowID!) ?? focusedColumn
      let right = column == 0 ? true : column == columns.count - 1 ? false : preferRight
      intendedWindowID = columns[column + (right ? 1 : -1)]
      humanInputSinceIntent = false
      typedIntoWindowID = nil
      fake.writerStepsDuringTapCallout = writerStepsDuringTap
      post(keyCode: right ? 124 : 123, flags: [.maskControl, .maskAlternate])
      fake.writerStepsDuringTapCallout = false
    case .type:
      humanInputSinceIntent = true
      typedIntoWindowID = fake.keyWindow
      post(keyCode: 0, flags: [])
    case .writerStep:
      if let operation = fake.gate.step(writerBusy: { platform.focusWriter.isBusy }) {
        log.append("  writer: \(operation)")
      }
    case .writerRuns:
      while let operation = fake.gate.step(writerBusy: { platform.focusWriter.isBusy }) {
        log.append("  writer: \(operation)")
      }
    case .setBusy(let app, let busy, let landLateWrites):
      fake.setBusy(processIDs[app], busy, landLateWrites: landLateWrites)
    case .deliverFocusNotification:
      if fake.takeFocusNotification() {
        // What the workspace and AX focus observers do: record the activation, mark the
        // event and ask for a desktop sync.
        platform.userInputTracker.recordApplicationActivation(processID: fake.frontmostProcessID)
        focusNotificationDelivered = true
        platform.nativeFocusEventPending = true
        daemon.needsDesktopSync = true
      }
    case .tick:
      await advance(by: 0.016)
      daemon.tick()
      await settle()
    case .setAccessibility(let granted):
      fake.setAccessibility(granted: granted)
    case .userFocuses(let index):
      // A Command-Tab or a click takes longer than a whole focus write: each AX call ends
      // within its timeout (16 or 50 ms, AXFocusWriterExecution), so the writer finishes first.
      while let operation = fake.gate.step(writerBusy: { platform.focusWriter.isBusy }) {
        log.append("  writer before the user's switch: \(operation)")
      }
      // Defi follows an outside focus change only once macOS reports it; until the
      // next calm the step oracle has no Defi intent to hold the selection to.
      humanInputSinceIntent = true
      intendedWindowID = nil
      intendedWorkspaceID = nil
      typedIntoWindowID = nil
      post(keyCode: 48, flags: .maskCommand)
      fake.userFocuses(windows[index])
    }
    await settle()
    switch step {
    case .press, .switchWorkspace, .moveColumnToWorkspace: pressMoves = fake.takeMoves()
    default: pressMoves = [:]
    }
    observe(step, hiddenBefore: hiddenBefore, generationBefore: generationBefore)
  }

  /// Oracles that need what happened during the step, not only where it ended.
  private func observe(_ step: FocusStep, hiddenBefore: Set<WindowID>, generationBefore: UInt64) {
    guard stepViolation == nil else { return }
    // Without Accessibility every call fails; Defi waits instead of retrying in a loop.
    let refused = fake.takeDeniedAttempts()
    // A busy app holds each call until its messaging timeout; Defi bounds focus writes to 16
    // then 50 ms (AXFocusWriterExecution) and layout writes to 50 ms (positionTimeoutSeconds).
    let slowest = fake.takeSlowestBusyCall()
    if slowest > 0.05 + 0.000_1 {
      stepViolation = FocusViolation(
        invariant: "busy-app-call-unbounded",
        detail: "a call to a busy app could hold Defi \(Int(slowest * 1_000)) ms, over the 50 ms budget"
      )
    }
    if refused > 24 {
      stepViolation = FocusViolation(
        invariant: "retry-storm-without-accessibility",
        detail: "\(refused) Accessibility calls refused in one step"
      )
    }
    // Every bound shortcut the tap sees becomes one command (AGENTS.md: keyboard capture and
    // command intake stay responsive while Accessibility work is pending).
    if case .press = step, pressHadTarget, daemon.commandGeneration != generationBefore &+ 1 {
      stepViolation = FocusViolation(
        invariant: "shortcut-lost",
        detail: "a column press produced \(daemon.commandGeneration &- generationBefore) commands"
      )
    }
    // A window hidden before and after a step never shows on the display in between
    // (AGENTS.md: parked windows never leak into visible monitor regions).
    let hiddenAfter = Set(windows.filter(platform.isWindowHidden))
    let visible = monitor.frame
    for write in fake.takeWrites() where hiddenBefore.contains(write.window) && hiddenAfter.contains(write.window) {
      let overlap = min(write.frame.x + write.frame.width, visible.x + visible.width) - max(write.frame.x, visible.x)
      if overlap > parkedSliverWidth + 1 {
        stepViolation = FocusViolation(
          invariant: "parked-window-shown",
          detail: "hidden window \(write.window.rawValue) was written \(Int(overlap)) pt onto the display"
        )
        return
      }
    }
  }

  /// Column order on the active workspace, one window per column in this world.
  var activeColumns: [WindowID] {
    let monitor = daemon.state.monitors[0]
    return monitor.workspaces.first { $0.id == monitor.activeWorkspace }!.columns.map { $0.windows[0] }
  }

  var focusedColumn: Int {
    let monitor = daemon.state.monitors[0]
    return monitor.workspaces.first { $0.id == monitor.activeWorkspace }!.focusedColumn
  }

  var stateLine: String {
    func id(_ window: WindowID?) -> String { window.map { "\($0.rawValue)" } ?? "-" }
    return "selected=\(id(selectedWindowID)) key=\(id(fake.keyWindow)) submitted=\(id(daemon.submittedCommandFocus?.windowID)) pending=\(id(daemon.pendingAnimatedFocus?.windowID)) writer=\(platform.focusWriter.isBusy ? "busy" : "idle") moves=\(pressMoves.values.reduce(0, +))"
  }

  func settle() async {
    _ = fake.gate.waitUntilParkedOrIdle(writerBusy: { platform.focusWriter.isBusy })
    for _ in 0..<50 {
      await MainActor.run {}
      for _ in 0..<3 {
        await withCheckedContinuation { continuation in
          NavigationActor.enqueue { continuation.resume() }
        }
      }
      if !platform.hasPendingFrameWrites { break }
      try? await Task.sleep(for: .milliseconds(1))
    }
  }

  /// Moves simulated time, letting each timer that comes due run and settle in order.
  func advance(by delta: TimeInterval) async {
    let target = clock.now + delta
    while let deadline = clock.nextDeadline, deadline <= target {
      clock.advance(to: deadline)
      await settle()
    }
    clock.advance(to: target)
  }

  private func post(keyCode: CGKeyCode, flags: CGEventFlags) {
    // A human types a few milliseconds apart; events carry the simulated clock.
    clock.advance(by: 0.005)
    let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
    event.flags = flags
    event.timestamp = UInt64(clock.now * 1_000_000_000)
    _ = input.handle(type: .keyDown, event: event)
  }

  /// macOS calms down: apps answer again and the daemon keeps ticking.
  func calm() async {
    fake.setAccessibility(granted: true)
    for app in processIDs.indices {
      fake.setBusy(processIDs[app], false, landLateWrites: true)
    }
    for round in 0..<20 {
      let before = (selectedWindowID, fake.keyWindow)
      _ = fake.takeWrites()
      await run(.deliverFocusNotification)
      // Calm lasts 2 s of simulated time, past the 1.4 s frame settlement re-check
      // (AXFrameCoordinatorSettlement); convergence must happen within it.
      await advance(by: 0.084)
      await run(.tick)
      // run() drained this round's writes for its own oracle; count them before they go.
      if round >= 10 { lateCalmWrites += fake.takeMoves().values.reduce(0, +) }
      while let operation = fake.gate.step(writerBusy: { platform.focusWriter.isBusy }) {
        log.append("  calm \(round) writer: \(operation)")
        await settle()
      }
      if before != (selectedWindowID, fake.keyWindow) {
        log.append("  calm \(round): " + stateLine)
      }
    }
  }

  func checkStep() -> FocusViolation? {
    if let stepViolation { return stepViolation }
    // Timers keep firing only while work is pending; a growing backlog is a busy loop.
    if clock.pendingTimerCount > 500 {
      return FocusViolation(invariant: "timer-storm", detail: "\(clock.pendingTimerCount) timers are pending")
    }
    if let intendedWindowID, !humanInputSinceIntent, selectedWindowID != intendedWindowID {
      return FocusViolation(
        invariant: "latest-intent-wins",
        detail: "selection is \(selectedWindowID.map { "\($0.rawValue)" } ?? "nil") but the latest command chose \(intendedWindowID.rawValue) and no human input followed"
      )
    }
    // AGENTS.md: stale native focus must not reactivate a workspace without newer human intent.
    if let intendedWorkspaceID, !humanInputSinceIntent, activeWorkspaceID != intendedWorkspaceID {
      return FocusViolation(
        invariant: "latest-workspace-wins",
        detail: "workspace \(activeWorkspaceID.rawValue) is active but the latest command chose \(intendedWorkspaceID.rawValue) and no human input followed"
      )
    }
    if let (window, moves) = pressMoves.first(where: { $0.value > 1 }) {
      return FocusViolation(
        invariant: "one-move-per-motion",
        detail: "window \(window.rawValue) moved \(moves) times for one column press"
      )
    }
    if let violation = daemon.state.validate().first {
      return FocusViolation(invariant: violation.code, detail: violation.message)
    }
    return nil
  }

  func checkCalm() -> FocusViolation? {
    if let violation = checkStep() { return violation }
    // Once macOS is calm nothing moves (AGENTS.md: frames converge without feedback loops).
    if lateCalmWrites > 0 {
      return FocusViolation(
        invariant: "writes-once-calm",
        detail: "\(lateCalmWrites) frame writes in the last 10 calm rounds"
      )
    }
    // Typing is the latest intent: no Defi focus write may take macOS away from that window.
    if let typed = typedIntoWindowID, fake.keyWindow != typed {
      return FocusViolation(
        invariant: "typing-target-kept",
        detail: "the user typed into window \(typed.rawValue) but macOS shows \(fake.keyWindow.map { "\($0.rawValue)" } ?? "nil") once calm"
      )
    }
    // Scrolling keeps focus visible (CONFIGURATION.md, center_focused_column).
    if let selected = selectedWindowID, let frame = fake.frame(of: selected),
      frame.x < monitor.frame.x - 1 || frame.x + frame.width > monitor.frame.x + monitor.frame.width + 1
    {
      return FocusViolation(
        invariant: "focus-visible",
        detail: "selected window \(selected.rawValue) spans x \(Int(frame.x))...\(Int(frame.x + frame.width)) outside the display once macOS is calm"
      )
    }
    // AGENTS.md: parking converges and self-repairs without leaking parked windows into
    // visible monitor regions.
    for window in windows where platform.isWindowHidden(window) {
      guard let frame = fake.frame(of: window) else { continue }
      let visible = monitor.frame
      let overlap = min(frame.x + frame.width, visible.x + visible.width) - max(frame.x, visible.x)
      if overlap > parkedSliverWidth + 1 {
        if ProcessInfo.processInfo.environment["DEFI_CALM_STAT"] != nil { print("leak-debug", window.rawValue, frame, platform.targetFrames[window] as Any, windows.map { (fake.frame(of: $0)!.x, platform.isWindowHidden($0)) }, activeColumns, daemon.state.monitors[0].workspaces.map { ($0.id.rawValue, $0.columns.count, $0.scrollOffset) }) }
        return FocusViolation(
          invariant: "parking-leak",
          detail: "hidden window \(window.rawValue) shows \(Int(overlap)) pt on the display once macOS is calm"
        )
      }
    }
    // An active empty workspace has no native focus target (AGENTS.md); macOS keeps its own.
    if let selectedWindowID, fake.keyWindow != selectedWindowID {
      return FocusViolation(
        invariant: "native-converges",
        detail: "macOS key window is \(fake.keyWindow.map { "\($0.rawValue)" } ?? "nil") but Defi selects \(selectedWindowID.rawValue) once macOS is calm"
      )
    }
    return nil
  }

  func shutdown() {
    fake.gate.openPermanently()
    daemon.flushPendingTopologyWrite()
    try? FileManager.default.removeItem(at: directory)
  }
}
