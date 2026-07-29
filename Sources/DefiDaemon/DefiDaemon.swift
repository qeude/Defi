import AppKit
import DefiConfig
import DefiCore
import DefiIPC
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation
import OSLog

private let performanceLogger = Logger(
  subsystem: "com.quentin.defi",
  category: "Performance"
)

private let displayLogger = Logger(
  subsystem: "com.quentin.defi",
  category: "Display"
)

private struct ScrollAnimationKey: Hashable {
  let monitorID: MonitorID
  let workspaceID: WorkspaceID
}

private struct ScrollAnimation {
  var target: Double
  var velocity: Double
  var lastStepAt: TimeInterval
  var startedAt: TimeInterval
}

@main
struct DefiDaemonMain {
  @MainActor
  static func main() {
    do {
      let options = try DaemonOptions(arguments: Array(CommandLine.arguments.dropFirst()))
      let daemon = try Daemon(options: options)
      daemon.run()
    } catch {
      FileHandle.standardError.write(Data("defi-daemon: \(error)\n".utf8))
      exit(1)
    }
  }
}

private struct DaemonOptions {
  let configURL: URL?
  let socketURL: URL

  init(arguments: [String]) throws {
    var configURL: URL?
    var socketURL = SocketPath.defaultURL
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--config":
        index += 1
        guard arguments.indices.contains(index) else {
          throw DaemonError.usage
        }
        configURL = URL(filePath: arguments[index])
      case "--socket":
        index += 1
        guard arguments.indices.contains(index) else {
          throw DaemonError.usage
        }
        socketURL = URL(filePath: arguments[index])
      case "--help", "-h":
        print("usage: defi-daemon [--config <path>] [--socket <path>]")
        exit(0)
      default:
        throw DaemonError.usage
      }
      index += 1
    }
    self.configURL = configURL
    self.socketURL = socketURL
  }
}

private enum DaemonError: Error, CustomStringConvertible {
  case usage

  var description: String {
    "usage: defi-daemon [--config <path>] [--socket <path>]"
  }
}

@MainActor
private final class Daemon: NSObject {
  private let config: Config
  private let platform = MacOSPlatform()
  private let server: UnixSocketServer
  private var state: RuntimeState
  private var hotKeys: HotKeyManager?
  private var menuBar: MenuBarController?
  private var timer: DispatchSourceTimer?
  private var timerFrequencyHz = 60.0
  private var activeMonitorID: MonitorID?
  private var latestMonitors: [MonitorSnapshot] = []
  private var tickCount = 0
  private var shouldShutdown = false
  private var signalSources: [DispatchSourceSignal] = []
  private var pendingHotKeyCommands: [String] = []
  private var processedHotKeyCount = 0
  private var needsDesktopSync = true
  private var observedPlatformEventCount = 0
  private var targetMismatchCount = 0
  private var targetMismatches: [FrameMismatch] = []
  private var activelyResizedWindowID: WindowID?
  private var persistentWidthDriftCounts: [WindowID: Int] = [:]
  private var scrollAnimations: [ScrollAnimationKey: ScrollAnimation] = [:]
  private var animationFrameCount = 0
  private var currentAnimationFrameCount = 0
  private var lastAnimationFrameCount = 0
  private var lastAnimationStepDurationMS = 0.0
  private var maximumAnimationStepDurationMS = 0.0
  private var lastAnimationDurationMS = 0.0
  private var lastCommandDurationMS = 0.0
  private var suppressNativeFocusUntil: TimeInterval = 0
  private var pendingAnimatedFocusWindowID: WindowID?
  private var frameNotificationsSuspended = false
  private var animationActivity: NSObjectProtocol?
  private var displayedFrameRebaseCount = 0
  private var lastDisplayedFrameRebaseDelta = 0.0
  private var displayConfigurationEventCount = 0
  private var pendingDisplaySyncDeadlines: [TimeInterval] = []

  init(options: DaemonOptions) throws {
    config = try Config.load(from: options.configURL)
    server = try UnixSocketServer(url: options.socketURL)
    state = RuntimeState(config: config)
    super.init()
  }

  func run() {
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.finishLaunching()
    installSignalHandlers()
    let trusted = platform.accessibilityTrusted(prompt: true)
    if !trusted {
      log("Accessibility permission pending. Grant Defi access in System Settings.")
    }
    platform.startObserving(
      { [weak self] in
        self?.observedPlatformEventCount += 1
        self?.needsDesktopSync = true
      },
      displayConfigurationHandler: { [weak self] in
        self?.scheduleDisplayReconciliation()
      }
    )

    do {
      let manager = try HotKeyManager(config: config) { [weak self] command in
        self?.enqueueHotKey(command)
      }
      try manager.start()
      hotKeys = manager
    } catch {
      log("hotkeys unavailable: \(error)")
    }
    menuBar = MenuBarController { [weak self] command in
      _ = self?.handle(command)
    }

    synchronizeDesktop()
    replaceTimer(frequencyHz: 60)
    log("running; socket=\(server.url.path)")
    NSApplication.shared.run()
  }

  private func tick() {
    processPendingHotKeys()
    pollIPC()
    finishPendingAnimatedFocusIfReady()
    if let deadline = pendingDisplaySyncDeadlines.first,
      ProcessInfo.processInfo.systemUptime >= deadline
    {
      pendingDisplaySyncDeadlines.removeFirst()
      needsDesktopSync = true
    }
    tickCount += 1
    let animatedWritesPending = platform.hasPendingAnimatedFrameWrites
    if scrollAnimations.isEmpty && !animatedWritesPending {
      if let animationActivity {
        ProcessInfo.processInfo.endActivity(animationActivity)
        self.animationActivity = nil
      }
      if frameNotificationsSuspended {
        platform.setFrameNotificationsEnabled(true)
        frameNotificationsSuspended = false
        needsDesktopSync = true
      }
      setTimerFrequency(60)
    }
    if scrollAnimations.isEmpty && !animatedWritesPending
      && (needsDesktopSync || tickCount.isMultiple(of: 18))
    {
      needsDesktopSync = false
      synchronizeDesktop()
    }
  }

  private func enqueueHotKey(_ command: String) {
    guard pendingHotKeyCommands.count < 64 else { return }
    pendingHotKeyCommands.append(command)
  }

  private func processPendingHotKeys() {
    for _ in 0..<min(pendingHotKeyCommands.count, 8) {
      let command = pendingHotKeyCommands.removeFirst()
      _ = handle(command)
      processedHotKeyCount += 1
    }
  }

  private func pollIPC() {
    do {
      for _ in 0..<16 {
        let handled = try server.poll { [weak self] command in
          self?.handle(command) ?? .failure("daemon unavailable")
        }
        if !handled { break }
      }
      if shouldShutdown {
        shutdown()
      }
    } catch {
      log("IPC error: \(error)")
    }
  }

  @discardableResult
  private func handle(_ rawCommand: String) -> CommandResponse {
    if rawCommand == "status" {
      return .success(status())
    }
    if rawCommand == "trace" {
      return .success(platform.frameCoordinatorTrace)
    }
    if rawCommand == "restore" {
      restoreAllWindows()
      return .success("restored")
    }
    if rawCommand == "quit" {
      shouldShutdown = true
      return .success("stopping")
    }
    do {
      let commandStartedAt = ProcessInfo.processInfo.systemUptime
      let command = try parseCommand(rawCommand)
      let previouslySelectedWindowID =
        activeMonitorID.flatMap { state.selectedWindowID(on: $0) }
      if !scrollAnimations.isEmpty || platform.hasPendingAnimatedFrameWrites {
        rebaseActiveScrollOffsetToDisplayedFrames()
      }
      if case .switchWorkspace = command {
        suppressNativeFocusUntil = commandStartedAt + 0.25
        pendingAnimatedFocusWindowID = nil
      }
      try reduce(command, on: activeMonitorID, state: &state)
      updateMenuBar()
      synchronizeScrollOffsets(state: &state, viewports: viewportsByMonitor)
      let switchesWorkspace: Bool
      if case .switchWorkspace = command {
        switchesWorkspace = true
        snapScrollOffsetsToTargets()
      } else {
        switchesWorkspace = false
        startScrollAnimationsIfNeeded()
      }
      if switchesWorkspace || !dispatchScrollAnimationIfNeeded() {
        applyCurrentLayout(
          asynchronousPositions: true,
          updateVisibility: scrollAnimations.isEmpty,
          positionTimeoutSeconds: scrollAnimations.isEmpty ? 0.05 : 0.016,
          source: switchesWorkspace ? "workspace-command" : "command"
        )
      }
      if let monitorID = activeMonitorID ?? state.monitors.first?.id,
        let selected = state.selectedWindowID(on: monitorID),
        selected != previouslySelectedWindowID
      {
        if scrollAnimations.isEmpty && !platform.hasPendingAnimatedFrameWrites {
          platform.focus(selected)
        } else {
          pendingAnimatedFocusWindowID = selected
        }
      }
      lastCommandDurationMS =
        (ProcessInfo.processInfo.systemUptime - commandStartedAt) * 1_000
      performanceLogger.debug(
        "command applied command=\(rawCommand, privacy: .public) duration_ms=\(self.lastCommandDurationMS, format: .fixed(precision: 2)) animations=\(self.scrollAnimations.count)"
      )
      return .success()
    } catch {
      return .failure(String(describing: error))
    }
  }

  private func synchronizeDesktop() {
    let snapshot = platform.snapshot(config: config)
    let previousViewports = viewportsByMonitor
    let displayGeometryChanged = monitorGeometryChanged(
      from: latestMonitors,
      to: snapshot.monitors
    )
    if displayGeometryChanged {
      let previous = displayGeometryDescription(latestMonitors)
      let next = displayGeometryDescription(snapshot.monitors)
      displayLogger.info(
        "geometry changed previous=\(previous, privacy: .public) next=\(next, privacy: .public)"
      )
      platform.invalidateFrameStateForDisplayChange()
      scrollAnimations.removeAll(keepingCapacity: true)
      pendingAnimatedFocusWindowID = nil
      persistentWidthDriftCounts.removeAll(keepingCapacity: true)
    }
    latestMonitors = snapshot.monitors
    targetMismatchCount = displayGeometryChanged ? 0 : snapshot.targetMismatchCount
    targetMismatches = displayGeometryChanged ? [] : snapshot.targetMismatches
    state.retainMonitors(
      snapshot.monitors.map(\.id),
      previousViewports: previousViewports,
      nextViewports: viewportsByMonitor
    )
    var nativelyFocusedMonitorID: MonitorID?
    reconcileWindows(snapshot.windows, config: config, state: &state)
    if let focusedWindowID = snapshot.focusedWindowID,
      activeMonitorID == nil
        || (snapshot.nativeFocusChanged
          && ProcessInfo.processInfo.systemUptime >= suppressNativeFocusUntil)
    {
      focusWindow(focusedWindowID, state: &state)
      activeMonitorID = state.monitorID(containing: focusedWindowID)
      nativelyFocusedMonitorID = activeMonitorID
    }
    if let activeMonitorID,
      !state.monitors.contains(where: { $0.id == activeMonitorID })
    {
      self.activeMonitorID = nil
    }
    activeMonitorID =
      activeMonitorID
      ?? snapshot.focusedWindowID.flatMap { state.monitorID(containing: $0) }
      ?? state.monitors.first?.id

    if !displayGeometryChanged && snapshot.leftMouseButtonDown {
      for (windowID, frame) in snapshot.externallyChangedFrames {
        if learnTiledWindowWidth(
          windowID,
          actualFrame: frame,
          state: &state,
          viewports: viewportsByMonitor
        ) {
          activelyResizedWindowID = windowID
        }
      }
    } else {
      activelyResizedWindowID = nil
      learnPersistentWidthConstraints(targetMismatches)
    }
    synchronizeScrollOffsets(state: &state, viewports: viewportsByMonitor)
    if let nativelyFocusedMonitorID {
      alignFocusedColumnLeft(
        on: nativelyFocusedMonitorID,
        state: &state,
        viewports: viewportsByMonitor
      )
    }
    snapScrollOffsetsToTargets()
    applyCurrentLayout(
      asynchronousPositions: true,
      updateVisibility: true,
      positionTimeoutSeconds: 0.05,
      source: "desktop-sync"
    )
    updateMenuBar()
  }

  private func displayGeometryDescription(
    _ monitors: [MonitorSnapshot]
  ) -> String {
    monitors.map {
      "\($0.id.rawValue):\(Int($0.frame.width))x\(Int($0.frame.height))"
    }.joined(separator: ",")
  }

  private func scheduleDisplayReconciliation() {
    displayConfigurationEventCount += 1
    let now = ProcessInfo.processInfo.systemUptime
    pendingDisplaySyncDeadlines = [0.05, 0.2, 0.5, 1.0, 2.0].map {
      now + $0
    }
    needsDesktopSync = true
  }

  private func startScrollAnimationsIfNeeded() {
    let wasAnimating = !scrollAnimations.isEmpty
    let duration = TimeInterval(config.animation.durationMS) / 1_000
    let now = ProcessInfo.processInfo.systemUptime
    for monitorIndex in state.monitors.indices {
      let activeWorkspace = state.monitors[monitorIndex].activeWorkspace
      for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
        let key = ScrollAnimationKey(
          monitorID: state.monitors[monitorIndex].id,
          workspaceID: state.monitors[monitorIndex].workspaces[workspaceIndex].id
        )
        let current = state.monitors[monitorIndex].workspaces[workspaceIndex].scrollOffset
        let target = state.monitors[monitorIndex].workspaces[workspaceIndex].targetScrollOffset
        guard state.monitors[monitorIndex].workspaces[workspaceIndex].id == activeWorkspace,
          config.animation.enabled,
          duration > 0,
          abs(current - target) >= 0.000_1
        else {
          state.monitors[monitorIndex].workspaces[workspaceIndex].scrollOffset = target
          scrollAnimations[key] = nil
          continue
        }
        if var animation = scrollAnimations[key] {
          if animation.target != target {
            animation.target = target
            animation.velocity = 0
            animation.lastStepAt = now
            animation.startedAt = now
            scrollAnimations[key] = animation
          }
        } else {
          scrollAnimations[key] = ScrollAnimation(
            target: target,
            velocity: 0,
            lastStepAt: now,
            startedAt: now
          )
        }
      }
    }
    if !scrollAnimations.isEmpty {
      if !wasAnimating {
        currentAnimationFrameCount = 0
        maximumAnimationStepDurationMS = 0
        animationActivity = ProcessInfo.processInfo.beginActivity(
          options: [.userInitiated, .latencyCritical],
          reason: "Defi scrolling animation"
        )
        platform.setFrameNotificationsEnabled(false)
        frameNotificationsSuspended = true
      }
      setTimerFrequency(min(activeDisplayRefreshRate, 60))
    }
  }

  private func snapScrollOffsetsToTargets() {
    scrollAnimations.removeAll()
    for monitorIndex in state.monitors.indices {
      for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
        state.monitors[monitorIndex].workspaces[workspaceIndex].scrollOffset =
          state.monitors[monitorIndex].workspaces[workspaceIndex].targetScrollOffset
      }
    }
  }

  private func dispatchScrollAnimationIfNeeded() -> Bool {
    guard !scrollAnimations.isEmpty else { return false }
    let duration = TimeInterval(config.animation.durationMS) / 1_000
    snapScrollOffsetsToTargets()
    applyCurrentLayout(
      asynchronousPositions: true,
      updateVisibility: true,
      positionTimeoutSeconds: 0.05,
      animationDuration: duration,
      source: "command-animation"
    )
    needsDesktopSync = true
    return true
  }

  private func finishPendingAnimatedFocusIfReady() {
    if scrollAnimations.isEmpty,
      !platform.hasPendingAnimatedFrameWrites,
      let pendingAnimatedFocusWindowID
    {
      self.pendingAnimatedFocusWindowID = nil
      platform.focus(pendingAnimatedFocusWindowID)
    }
  }

  private var viewportsByMonitor: [MonitorID: Rect] {
    Dictionary(uniqueKeysWithValues: latestMonitors.map { ($0.id, $0.frame) })
  }

  private func rebaseActiveScrollOffsetToDisplayedFrames() {
    guard
      let monitorID = activeMonitorID,
      let monitorIndex = state.monitors.firstIndex(where: { $0.id == monitorID }),
      let viewport = latestMonitors.first(where: { $0.id == monitorID })?.frame,
      let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
        where: { $0.id == state.monitors[monitorIndex].activeWorkspace }
      )
    else {
      return
    }
    let workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
    let windows = workspace.columns
      .flatMap(\.windows)
      .compactMap { state.windows[$0] }
    let assignments = computeLayout(
      workspace: workspace,
      viewport: viewport,
      windows: windows,
      settings: state.layout
    ).frames.map(preserveIntrinsicSize)
    let deltas = assignments.compactMap { assignment -> Double? in
      guard horizontalIntersection(assignment.frame, viewport) > 0.5,
        let completed = platform.completedPosition(for: assignment.windowID)
      else {
        return nil
      }
      return assignment.frame.x - Double(completed.x)
    }
    guard
      let rebase = rebaseScalarToDisplayedFrames(
        logicalValue: workspace.scrollOffset,
        expectedMinusDisplayedDeltas: deltas,
        maximumAbsoluteDelta: viewport.width
      )
    else {
      return
    }
    state.monitors[monitorIndex].workspaces[workspaceIndex].scrollOffset =
      rebase.value
    let key = ScrollAnimationKey(
      monitorID: monitorID,
      workspaceID: workspace.id
    )
    if var animation = scrollAnimations[key] {
      animation.lastStepAt = ProcessInfo.processInfo.systemUptime
      scrollAnimations[key] = animation
    }
    displayedFrameRebaseCount += 1
    lastDisplayedFrameRebaseDelta = rebase.delta
  }

  private func learnPersistentWidthConstraints(_ mismatches: [FrameMismatch]) {
    let mismatchedIDs = Set(mismatches.map(\.windowID))
    persistentWidthDriftCounts = persistentWidthDriftCounts.filter {
      mismatchedIDs.contains($0.key)
    }
    for mismatch in mismatches {
      guard abs(mismatch.actual.width - mismatch.target.width) >= 2,
        state.windows[mismatch.windowID]?.intrinsicSize != true
      else {
        continue
      }
      let count = persistentWidthDriftCounts[mismatch.windowID, default: 0] + 1
      persistentWidthDriftCounts[mismatch.windowID] = count
      if count >= 3,
        learnTiledWindowWidth(
          mismatch.windowID,
          actualFrame: mismatch.actual,
          state: &state,
          viewports: viewportsByMonitor
        )
      {
        persistentWidthDriftCounts[mismatch.windowID] = 0
      }
    }
  }

  private func applyCurrentLayout(
    asynchronousPositions: Bool = false,
    updateVisibility: Bool? = nil,
    positionTimeoutSeconds: Float = 0.016,
    animationDuration: TimeInterval = 0,
    source: String = "layout"
  ) {
    var assignments: [FrameAssignment] = []
    var hiddenWindowIDs = Set<WindowID>()
    let allPhysicalMonitorFrames = latestMonitors.map(\.physicalFrame)
    for monitorIndex in state.monitors.indices {
      let monitor = state.monitors[monitorIndex]
      guard
        let monitorSnapshot = latestMonitors.first(where: { $0.id == monitor.id })
      else {
        continue
      }
      let viewport = monitorSnapshot.frame
      let physicalFrame = monitorSnapshot.physicalFrame
      let activeWorkspaceIndex = monitor.workspaces.firstIndex {
        $0.id == monitor.activeWorkspace
      } ?? 0
      for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
        let workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
        let workspaceWindows = workspace.columns
          .flatMap(\.windows)
          .compactMap { state.windows[$0] }
        let layout = computeLayout(
          workspace: workspace,
          viewport: viewport,
          windows: workspaceWindows,
          settings: state.layout
        )
        let sizedFrames = layout.frames.map(preserveIntrinsicSize)
        if workspace.id == monitor.activeWorkspace {
          let strip = continuousStripFramesForActiveWorkspace(
            sizedFrames,
            viewport: viewport,
            ownerFrame: physicalFrame,
            parkingFrame: viewport,
            allMonitorFrames: allPhysicalMonitorFrames
          )
          assignments.append(contentsOf: strip.frames)
          hiddenWindowIDs.formUnion(strip.parkedWindowIDs)
        } else {
          hiddenWindowIDs.formUnion(sizedFrames.map(\.windowID))
          assignments.append(
            contentsOf: parkFramesInSafeCorner(
              sizedFrames,
              ownerFrame: physicalFrame,
              parkingFrame: viewport,
              allMonitorFrames: allPhysicalMonitorFrames,
              preferredSide: workspaceIndex < activeWorkspaceIndex ? .left : .right
            ).frames
          )
        }
      }
    }
    let skipped = activelyResizedWindowID.map { Set([$0]) } ?? []
    let platformAssignments = asynchronousPositions
      ? assignments.map(roundAnimatedPosition)
      : assignments
    platform.apply(
      platformAssignments,
      hiddenWindowIDs: hiddenWindowIDs,
      skipping: skipped,
      asynchronousPositions: asynchronousPositions,
      asynchronousPositionTimeoutSeconds: positionTimeoutSeconds,
      animationDuration: animationDuration,
      animationRefreshRateHz: activeDisplayRefreshRate,
      updateVisibility: updateVisibility ?? !asynchronousPositions,
      source: source
    )
  }

  private func roundAnimatedPosition(
    _ assignment: FrameAssignment
  ) -> FrameAssignment {
    FrameAssignment(
      windowID: assignment.windowID,
      frame: Rect(
        x: assignment.frame.x.rounded(),
        y: assignment.frame.y.rounded(),
        width: assignment.frame.width,
        height: assignment.frame.height
      )
    )
  }

  private func preserveIntrinsicSize(_ assignment: FrameAssignment) -> FrameAssignment {
    guard let window = state.windows[assignment.windowID], window.intrinsicSize else {
      return assignment
    }
    let width = window.frame.width
    let height = window.frame.height
    return FrameAssignment(
      windowID: assignment.windowID,
      frame: Rect(
        x: assignment.frame.x + (assignment.frame.width - width) / 2,
        y: assignment.frame.y + (assignment.frame.height - height) / 2,
        width: width,
        height: height
      )
    )
  }

  private func horizontalIntersection(_ frame: Rect, _ viewport: Rect) -> Double {
    max(
      min(frame.x + frame.width, viewport.x + viewport.width)
        - max(frame.x, viewport.x),
      0
    )
  }

  private func status() -> String {
    let managedCount = state.windows.values.filter { !$0.floating || $0.forceTiling }.count
    let workspace =
      activeMonitorID
      .flatMap { id in state.monitors.first(where: { $0.id == id }) }
      .map(\.activeWorkspace.rawValue)
      ?? "none"
    let hotKeyState = hotKeys?.isEnabled == true ? "enabled" : "disabled"
    let bindingCount = hotKeys?.bindingCount ?? 0
    let capturedHotKeyCount = hotKeys?.capturedKeyCount ?? 0
    let tapReenableCount = hotKeys?.tapReenableCount ?? 0
    let resize =
      activelyResizedWindowID.map { String($0.rawValue) }
      ?? "none"
    let focused =
      activeMonitorID
      .flatMap { state.selectedWindowID(on: $0) }
      .map { String($0.rawValue) }
      ?? "none"
    let driftDetails = targetMismatches.prefix(6).map { mismatch in
      let dx = Int((mismatch.actual.x - mismatch.target.x).rounded())
      let dy = Int((mismatch.actual.y - mismatch.target.y).rounded())
      let dw = Int((mismatch.actual.width - mismatch.target.width).rounded())
      let dh = Int((mismatch.actual.height - mismatch.target.height).rounded())
      let app = state.windows[mismatch.windowID]?.appID ?? "unknown"
      return "\(mismatch.windowID.rawValue)@\(app):\(dx),\(dy),\(dw),\(dh)"
    }.joined(separator: ";")
    let parking = platform.parkingPerformance
    let frameCommit = platform.frameCommitPerformance
    let capture = platform.screenCaptureAvailable ? "granted" : "missing"
    let visibility = "topology-parking"
    let commandMS = String(format: "%.2f", lastCommandDurationMS)
    let frameMS = String(format: "%.2f", platform.frameApplyDurationMS)
    let focusMS = String(format: "%.2f", platform.focusDurationMS)
    let axFramePerformance = platform.frameCoordinatorPerformance
    let axFrameMS = String(format: "%.2f", axFramePerformance.lastDurationMS)
    let axFrameMaxMS = String(format: "%.2f", axFramePerformance.maximumDurationMS)
    let coordinatorAnimationMS = String(
      format: "%.2f",
      axFramePerformance.animationDurationMS
    )
    let displayedRebaseDelta = String(
      format: "%.2f",
      lastDisplayedFrameRebaseDelta
    )
    let displayHz = Int(activeDisplayRefreshRate.rounded())
    let timerHz = Int(timerFrequencyHz.rounded())
    let observedCommitMaxMS = String(
      format: "%.2f",
      frameCommit.maximumObservedLatencyMS
    )
    let focusedColumnState: String = {
      guard let monitorID = activeMonitorID,
        let monitor = state.monitors.first(where: { $0.id == monitorID }),
        let workspace = monitor.workspaces.first(
          where: { $0.id == monitor.activeWorkspace }
        ),
        workspace.columns.indices.contains(workspace.focusedColumn)
      else {
        return "none"
      }
      let column = workspace.columns[workspace.focusedColumn]
      return "\(columnWidthStatus(column.width))/prev:\(column.fullscreenPreviousWidth.map(columnWidthStatus) ?? "none")"
    }()
    let displaySizes = latestMonitors.map {
      "\($0.id.rawValue):\(Int($0.frame.width))x\(Int($0.frame.height))"
    }.joined(separator: ",")
    return
      "running monitors=\(state.monitors.count)[\(displaySizes)] windows=\(managedCount) workspace=\(workspace) focused=\(focused) columnWidth=\(focusedColumnState) menuBar=\(menuBar == nil ? "missing" : "installed") hotkeys=\(hotKeyState) bindings=\(bindingCount) captured=\(capturedHotKeyCount) processed=\(processedHotKeyCount) queued=\(pendingHotKeyCommands.count) tapReenables=\(tapReenableCount) events=\(observedPlatformEventCount) displayEvents=\(displayConfigurationEventCount) displayRetries=\(pendingDisplaySyncDeadlines.count) drift=\(targetMismatchCount)[\(driftDetails)] resize=\(resize) visibility=\(visibility) capture=\(capture) hidden=\(platform.hiddenWindowCount) parkingChecks=\(parking.checks) parkingRepairs=\(parking.repairs) settling=\(frameCommit.settling) deferredCommits=\(frameCommit.deferred) observedCommits=\(frameCommit.observed) observedCommitMaxMs=\(observedCommitMaxMS) posWrites=\(platform.successfulPositionWriteCount) stalePos=\(platform.skippedStalePositionWriteCount) droppedFrames=\(platform.droppedPositionFrameCount) displayedRebases=\(displayedFrameRebaseCount) displayedDelta=\(displayedRebaseDelta) sizeWrites=\(platform.successfulSizeWriteCount) displayHz=\(displayHz) timerHz=\(timerHz) axPending=\(platform.hasPendingAnimatedFrameWrites) axFrameMs=\(axFrameMS) axFrameMaxMs=\(axFrameMaxMS) axSlowFrames=\(axFramePerformance.slowFrames) focusPending=\(platform.hasPendingFocusWrite) animating=\(platform.hasPendingAnimatedFrameWrites) animationFrames=\(axFramePerformance.animationFrames) animationMs=\(coordinatorAnimationMS) commandMs=\(commandMS) frameMs=\(frameMS) focusMs=\(focusMS)"
  }

  private func columnWidthStatus(_ width: ColumnWidth) -> String {
    switch width {
    case .fraction(let fraction):
      "fraction:\(String(format: "%.3f", fraction))"
    case .pixels(let pixels):
      "pixels:\(String(format: "%.1f", pixels))"
    }
  }

  private func updateMenuBar() {
    let workspace =
      activeMonitorID
      .flatMap { id in state.monitors.first(where: { $0.id == id }) }
      .map(\.activeWorkspace.rawValue)
      ?? ""
    menuBar?.update(
      activeWorkspace: workspace,
      workspaceNames: state.workspaceNames.map(\.rawValue)
    )
  }

  private var activeDisplayRefreshRate: Double {
    let refreshRate =
      activeMonitorID
      .flatMap { monitorID in
        latestMonitors.first(where: { $0.id == monitorID })?.refreshRateHz
      }
      ?? latestMonitors.first?.refreshRateHz
      ?? 60
    return min(max(refreshRate, 30), 240)
  }

  private func setTimerFrequency(_ frequencyHz: Double) {
    let frequencyHz = min(max(frequencyHz, 30), 240)
    guard abs(timerFrequencyHz - frequencyHz) >= 0.5 else { return }
    replaceTimer(frequencyHz: frequencyHz)
  }

  private func replaceTimer(frequencyHz: Double) {
    timer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    let intervalNanoseconds = max(Int(1_000_000_000 / frequencyHz), 1)
    timer.schedule(
      deadline: .now(),
      repeating: .nanoseconds(intervalNanoseconds),
      leeway: .microseconds(max(intervalNanoseconds / 20_000, 250))
    )
    timer.setEventHandler { [weak self] in
      self?.tick()
    }
    timer.resume()
    self.timer = timer
    timerFrequencyHz = frequencyHz
  }

  private func installSignalHandlers() {
    for signalNumber in [SIGINT, SIGTERM] {
      signal(signalNumber, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
      let handler = DispatchWorkItem(qos: .userInitiated, flags: []) { [weak self] in
        MainActor.assumeIsolated {
          self?.requestShutdown()
        }
      }
      source.setEventHandler(handler: handler)
      source.resume()
      signalSources.append(source)
    }
  }

  private func restoreAllWindows() {
    var assignments: [FrameAssignment] = []
    for monitor in state.monitors {
      guard let viewport = latestMonitors.first(where: { $0.id == monitor.id })?.frame else {
        continue
      }
      for var workspace in monitor.workspaces {
        workspace.scrollOffset = 0
        let windows = workspace.columns.flatMap(\.windows).compactMap { state.windows[$0] }
        assignments.append(
          contentsOf: computeLayout(
            workspace: workspace,
            viewport: viewport,
            windows: windows,
            settings: state.layout
          ).frames
        )
      }
    }
    platform.apply(assignments)
  }

  private func requestShutdown() {
    shouldShutdown = true
  }

  private func shutdown() -> Never {
    timer?.cancel()
    restoreAllWindows()
    server.removeSocketFile()
    log("stopped; windows restored")
    exit(0)
  }

  private func log(_ message: String) {
    FileHandle.standardError.write(Data("[defi] \(message)\n".utf8))
  }
}
