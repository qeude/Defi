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
    let floatingCount = state.windows.count - managedCount
    let workspace =
      activeMonitorID
      .flatMap { id in state.monitors.first(where: { $0.id == id }) }
      .map(\.activeWorkspace.rawValue)
      ?? "none"
    let hotKeyState =
      hotKeys?.isHotKeyCaptureEnabled == true
      ? "enabled"
      : "disabled"
    let bindingCount = hotKeys?.bindingCount ?? 0
    let capturedHotKeyCount = hotKeys?.capturedKeyCount ?? 0
    let tapReenableCount = hotKeys?.tapReenableCount ?? 0
    let pointerTransitionCount = hotKeys?.pointerTransitionCount ?? 0
    let cursorWarps = platform.cursorWarpPerformance
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
    let commandLatency = platform.commandLatencyPerformance
    func latencyStatus(_ value: LatencyPercentiles) -> String {
      let p50 = String(format: "%.2f", value.p50MS)
      let p95 = String(format: "%.2f", value.p95MS)
      let p99 = String(format: "%.2f", value.p99MS)
      return "\(value.count)/\(p50)/\(p95)/\(p99)"
    }
    let frameMS = String(format: "%.2f", platform.frameApplyDurationMS)
    let snapshotPerformance = platform.windowSnapshotPerformance
    let attributeReads = platform.windowAttributeReadPerformance
    let observationCoverage = platform.desktopObservationCoverage
    let snapshotMS = String(
      format: "%.2f",
      snapshotPerformance.lastDurationMS
    )
    let snapshotMaxMS = String(
      format: "%.2f",
      snapshotPerformance.maximumDurationMS
    )
    let snapshotP50MS = String(
      format: "%.2f",
      snapshotPerformance.p50DurationMS
    )
    let snapshotP95MS = String(
      format: "%.2f",
      snapshotPerformance.p95DurationMS
    )
    let snapshotCGMS = String(
      format: "%.2f",
      snapshotPerformance.lastCGCopyDurationMS
    )
    let snapshotCGMaxMS = String(
      format: "%.2f",
      snapshotPerformance.maximumCGCopyDurationMS
    )
    let applicationInventoryP50MS = String(
      format: "%.2f",
      snapshotPerformance.applicationInventoryP50MS
    )
    let applicationInventoryP95MS = String(
      format: "%.2f",
      snapshotPerformance.applicationInventoryP95MS
    )
    let applicationWindowListP50MS = String(
      format: "%.2f",
      snapshotPerformance.applicationWindowListP50MS
    )
    let applicationWindowListP95MS = String(
      format: "%.2f",
      snapshotPerformance.applicationWindowListP95MS
    )
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
        "\(columnWidthStatus(column.width))/pre-max:\(column.preMaximizedWidth.map(columnWidthStatus) ?? "none")"
    }()
    let displaySizes = latestMonitors.map {
      "\($0.id.rawValue):\(Int($0.frame.width))x\(Int($0.frame.height))"
    }.joined(separator: ",")
    return
      "running monitors=\(state.monitors.count)[\(displaySizes)] windows=\(managedCount) floating=\(floatingCount) workspace=\(workspace) focused=\(focused) columnWidth=\(focusedColumnState) menuBar=\(menuBar == nil ? "missing" : "installed") hotkeys=\(hotKeyState) bindings=\(bindingCount) captured=\(capturedHotKeyCount) processed=\(processedHotKeyCount) queued=\(pendingHotKeyCommands.count) tapReenables=\(tapReenableCount) events=\(observedPlatformEventCount) focusDedup=\(ignoredRedundantNativeFocusCount) closeFocusPreserved=\(preservedWindowRemovalFocusCount) displayEvents=\(displayConfigurationEventCount) displayRetries=\(pendingDisplaySyncDeadlines.count) drift=\(targetMismatchCount)[\(driftDetails)] resize=\(resize) visibility=\(visibility) hidden=\(platform.hiddenWindowCount) borders=\(borders.visible) borderNodes=\(borders.allocated) borderDormant=\(borders.dormant) borderOpacity=\(borderOpacity) borderSurfaceMiB=\(borderSurfaceMiB) borderCapture=\(borders.captureEnabled) borderPlans=\(borders.appliedPlans) borderSkips=\(borders.skippedPlans) borderGeometry=\(borders.geometryUpdates) snapshots=\(snapshotPerformance.full)/\(snapshotPerformance.incremental)/\(snapshotPerformance.cached) appInventories=\(snapshotPerformance.applicationInventories) snapshotMs=\(snapshotMS) snapshotMaxMs=\(snapshotMaxMS) snapshotCG=\(snapshotPerformance.cgCopies)/\(snapshotCGMS)/\(snapshotCGMaxMS) axReads=\(attributeReads.batched)/\(attributeReads.fallback) parkingChecks=\(parking.checks) parkingRepairs=\(parking.repairs) initialChecks=\(initialSettlement.checks) initialRepairs=\(initialSettlement.repairs) settling=\(frameCommit.settling) deferredCommits=\(frameCommit.deferred) observedCommits=\(frameCommit.observed) observedCommitMaxMs=\(observedCommitMaxMS) slowApps=\(platform.latencySensitiveProcessCount) slowAppDetails=[\(platform.latencySensitiveProcessDescription)] axAppDetails=[\(platform.processLatencyDescription)] posWrites=\(platform.successfulPositionWriteCount) stalePos=\(platform.skippedStalePositionWriteCount) droppedFrames=\(platform.droppedPositionFrameCount) displayedRebases=\(displayedFrameRebaseCount) displayedDelta=\(displayedRebaseDelta) sizeWrites=\(platform.successfulSizeWriteCount) displayHz=\(displayHz) timerHz=\(timerHz) axPending=\(platform.hasPendingAnimatedFrameWrites) axFrameMs=\(axFrameMS) axFrameMaxMs=\(axFrameMaxMS) axSlowFrames=\(axFramePerformance.slowFrames) focusPending=\(platform.hasPendingFocusWrite) focusFast=\(focusPerformance.fastPaths) focusCancelled=\(focusPerformance.cancelled) focusRetries=\(focusPerformance.retries) focusMainMs=\(focusMainMS) focusRaiseMs=\(focusRaiseMS) focusActivateMs=\(focusActivateMS) animating=\(platform.hasPendingAnimatedFrameWrites) animationFrames=\(axFramePerformance.animationFrames) animationMs=\(coordinatorAnimationMS) commandMs=\(commandMS) frameMs=\(frameMS) focusMs=\(focusMS)"
      + " topologyObservers=\(platform.hasReliableWindowTopologyObservation) appWindowLists=\(snapshotPerformance.applicationWindowListReads)"
      + " appLifecycleObservers=\(platform.hasReliableApplicationLifecycleObservation) appInventoryInterval=\(Int(platform.recommendedApplicationInventoryRefreshInterval))"
      + " desktopObservers=\(platform.hasReliableDesktopObservation)"
      + " observerCoverage=\(observationCoverage.applicationObservers)/\(observationCoverage.applications):\(observationCoverage.topologyWindows)/\(observationCoverage.requiredTopologyWindows):\(observationCoverage.frameWindows)/\(observationCoverage.requiredFrameWindows)"
      + " windowMetadata=\(attributeReads.metadata)/\(attributeReads.metadataReuses)"
      + " windowIDs=private:\(platform.successfulPrivateWindowIDLookupCount)/fallback:\(platform.publicWindowIDLookupFallbackCount)/available:\(platform.privateWindowIDLookupStatus)"
      + " windowBounds=private:\(platform.successfulPrivateWindowBoundsLookupCount)/fallback:\(platform.privateWindowBoundsLookupFallbackCount)/available:\(platform.isPrivateWindowBoundsLookupAvailable)"
      + " screenCapture=\(platform.hasScreenCaptureAccess)"
      + " snapshotP50/P95=\(snapshotP50MS)/\(snapshotP95MS)"
      + " snapshotComponents=\(applicationInventoryP50MS)/\(applicationInventoryP95MS):\(applicationWindowListP50MS)/\(applicationWindowListP95MS)"
      + " focusFollowsMouse=\(config.input.focusFollowsMouse) mouseFollowsFocus=\(config.input.mouseFollowsFocus) pointerTransitions=\(pointerTransitionCount) pointerFocus=\(pointerFocusAppliedCount)/\(pointerFocusObservedCount) pointerIgnored=\(pointerFocusIgnoredCount) cursorWarps=\(cursorWarps.applied)/\(cursorWarps.skipped)/\(cursorWarps.failed)"
      + " commandLatency=started:\(commandLatency.started)/superseded:\(commandLatency.superseded)"
      + " inputPlanN/P50/P95/P99=\(latencyStatus(commandLatency.plan))"
      + " inputWriteN/P50/P95/P99=\(latencyStatus(commandLatency.firstWrite))"
      + " inputObservedN/P50/P95/P99=\(latencyStatus(commandLatency.firstObservation))"
      + " inputConvergedN/P50/P95/P99=\(latencyStatus(commandLatency.convergence))"
      + " inputFocusN/P50/P95/P99=\(latencyStatus(commandLatency.focus))"
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
    publishWorkspaceStateIfNeeded()
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
    let frequencyHz = min(max(frequencyHz, 1), 240)
    guard abs(timerFrequencyHz - frequencyHz) >= 0.5 else { return }
    replaceTimer(frequencyHz: frequencyHz)
  }

  func replaceTimer(frequencyHz: Double) {
    let intervalNanoseconds = max(Int(1_000_000_000 / frequencyHz), 1)
    let leewayNanoseconds = frequencyHz <= 10
      ? intervalNanoseconds / 10
      : max(intervalNanoseconds / 20_000, 250_000)
    if let timer {
      timer.schedule(
        deadline: .now(),
        repeating: .nanoseconds(intervalNanoseconds),
        leeway: .nanoseconds(leewayNanoseconds)
      )
      timerFrequencyHz = frequencyHz
      return
    }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(
      deadline: .now(),
      repeating: .nanoseconds(intervalNanoseconds),
      leeway: .nanoseconds(leewayNanoseconds)
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
        assignments.append(contentsOf: floatingAssignments(in: workspace))
      }
    }
    platform.apply(assignments)
  }

  func requestShutdown() {
    guard !shouldShutdown else { return }
    shouldShutdown = true
    shutdown()
  }

  func shutdown() -> Never {
    timer?.cancel()
    ipcSource?.cancel()
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
