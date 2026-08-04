import AppKit
import DefiConfig
import DefiCore
import DefiIPC
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation
import OSLog

@MainActor
extension Daemon {
  func status() -> String {
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
    let initialSettlement = platform.initialSettlementPerformance
    let frameCommit = platform.frameCommitPerformance
    let borders = platform.windowBorderPerformance
    let borderOpacity = String(format: "%.2f", borders.activeOpacity)
    let borderSurfaceMiB = String(
      format: "%.2f",
      Double(borders.estimatedSurfacePixels * 4) / 1_048_576
    )
    let visibility = "topology-parking"
    let commandMS = String(format: "%.2f", lastCommandDurationMS)
    let frameMS = String(format: "%.2f", platform.frameApplyDurationMS)
    let focusPerformance = platform.focusPerformance
    let focusMS = String(format: "%.2f", focusPerformance.durationMS)
    let focusMainMS = String(
      format: "%.2f",
      focusPerformance.mainDurationMS
    )
    let focusRaiseMS = String(
      format: "%.2f",
      focusPerformance.raiseDurationMS
    )
    let focusActivateMS = String(
      format: "%.2f",
      focusPerformance.activationDurationMS
    )
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
      return
        "\(columnWidthStatus(column.width))/prev:\(column.fullscreenPreviousWidth.map(columnWidthStatus) ?? "none")"
    }()
    let displaySizes = latestMonitors.map {
      "\($0.id.rawValue):\(Int($0.frame.width))x\(Int($0.frame.height))"
    }.joined(separator: ",")
    return
      "running monitors=\(state.monitors.count)[\(displaySizes)] windows=\(managedCount) workspace=\(workspace) focused=\(focused) columnWidth=\(focusedColumnState) menuBar=\(menuBar == nil ? "missing" : "installed") hotkeys=\(hotKeyState) bindings=\(bindingCount) captured=\(capturedHotKeyCount) processed=\(processedHotKeyCount) queued=\(pendingHotKeyCommands.count) tapReenables=\(tapReenableCount) events=\(observedPlatformEventCount) focusDedup=\(ignoredRedundantNativeFocusCount) displayEvents=\(displayConfigurationEventCount) displayRetries=\(pendingDisplaySyncDeadlines.count) drift=\(targetMismatchCount)[\(driftDetails)] resize=\(resize) visibility=\(visibility) hidden=\(platform.hiddenWindowCount) borders=\(borders.visible) borderNodes=\(borders.allocated) borderDormant=\(borders.dormant) borderOpacity=\(borderOpacity) borderSurfaceMiB=\(borderSurfaceMiB) borderCapture=\(borders.captureEnabled) borderPlans=\(borders.appliedPlans) borderSkips=\(borders.skippedPlans) borderGeometry=\(borders.geometryUpdates) parkingChecks=\(parking.checks) parkingRepairs=\(parking.repairs) initialChecks=\(initialSettlement.checks) initialRepairs=\(initialSettlement.repairs) settling=\(frameCommit.settling) deferredCommits=\(frameCommit.deferred) observedCommits=\(frameCommit.observed) observedCommitMaxMs=\(observedCommitMaxMS) slowApps=\(platform.latencySensitiveProcessCount) slowDeferred=\(deferredSlowWindowIDs.count) slowDeferrals=\(slowLaneDeferralCount) slowSettlements=\(slowLaneSettlementCount) posWrites=\(platform.successfulPositionWriteCount) stalePos=\(platform.skippedStalePositionWriteCount) droppedFrames=\(platform.droppedPositionFrameCount) displayedRebases=\(displayedFrameRebaseCount) displayedDelta=\(displayedRebaseDelta) sizeWrites=\(platform.successfulSizeWriteCount) displayHz=\(displayHz) timerHz=\(timerHz) axPending=\(platform.hasPendingAnimatedFrameWrites) axFrameMs=\(axFrameMS) axFrameMaxMs=\(axFrameMaxMS) axSlowFrames=\(axFramePerformance.slowFrames) focusPending=\(platform.hasPendingFocusWrite) focusFast=\(focusPerformance.fastPaths) focusCancelled=\(focusPerformance.cancelled) focusRetries=\(focusPerformance.retries) focusMainMs=\(focusMainMS) focusRaiseMs=\(focusRaiseMS) focusActivateMs=\(focusActivateMS) animating=\(platform.hasPendingAnimatedFrameWrites) animationFrames=\(axFramePerformance.animationFrames) animationMs=\(coordinatorAnimationMS) commandMs=\(commandMS) frameMs=\(frameMS) focusMs=\(focusMS)"
  }

  private func columnWidthStatus(_ width: ColumnWidth) -> String {
    switch width {
    case .fraction(let fraction):
      "fraction:\(String(format: "%.3f", fraction))"
    case .pixels(let pixels):
      "pixels:\(String(format: "%.1f", pixels))"
    }
  }

  func updateMenuBar() {
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

  var activeDisplayRefreshRate: Double {
    let refreshRate =
      activeMonitorID
      .flatMap { monitorID in
        latestMonitors.first(where: { $0.id == monitorID })?.refreshRateHz
      }
      ?? latestMonitors.first?.refreshRateHz
      ?? 60
    return min(max(refreshRate, 30), 240)
  }

  func setTimerFrequency(_ frequencyHz: Double) {
    let frequencyHz = min(max(frequencyHz, 30), 240)
    guard abs(timerFrequencyHz - frequencyHz) >= 0.5 else { return }
    replaceTimer(frequencyHz: frequencyHz)
  }

  func replaceTimer(frequencyHz: Double) {
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

  func installSignalHandlers() {
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

  func restoreAllWindows() {
    platform.prepareForSynchronousRestore()
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

  func requestShutdown() {
    shouldShutdown = true
  }

  func shutdown() -> Never {
    timer?.cancel()
    platform.hideWindowBorders()
    restoreAllWindows()
    server.removeSocketFile()
    log("stopped; windows restored")
    exit(0)
  }

  func log(_ message: String) {
    FileHandle.standardError.write(Data("[defi] \(message)\n".utf8))
  }
}
