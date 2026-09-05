import AppKit
import DefiConfig
import DefiCore
import DefiIPC
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation
import OSLog

struct AnimationDisplayTiming: Equatable {
  let refreshRateHz: Double
  let displayIDs: Set<UInt64>
}

func animationDisplayTiming(
  monitorIDs: Set<MonitorID>?,
  activeMonitorID: MonitorID?,
  fallbackMonitorID: MonitorID?,
  refreshRates: [MonitorID: Double]
) -> AnimationDisplayTiming {
  let selectedMonitorIDs = monitorIDs.flatMap { $0.isEmpty ? nil : $0 }
    ?? Set([activeMonitorID ?? fallbackMonitorID].compactMap { $0 })
  let selectedRefreshRates = selectedMonitorIDs.compactMap { refreshRates[$0] }
  return AnimationDisplayTiming(
    refreshRateHz: selectedRefreshRates.min() ?? 60,
    displayIDs: Set(selectedMonitorIDs.map(\.rawValue))
  )
}

func layoutWindowIDsOutsideSubmissionScope(
  _ plan: MonitorLayoutPlan,
  monitorID: MonitorID,
  restrictedTo monitorIDs: Set<MonitorID>?
) -> Set<WindowID> {
  monitorIDs?.contains(monitorID) == false
    ? Set(plan.assignments.map(\.windowID))
    : []
}

@MainActor
extension Daemon {
  func applyCurrentLayout(
    monitorIDs: Set<MonitorID>? = nil,
    asynchronousPositions: Bool = false,
    updateVisibility: Bool? = nil,
    positionTimeoutSeconds: Float = 0.016,
    animationDuration: TimeInterval = 0,
    animateSizeChanges: Bool = false,
    skipping additionalSkippedWindowIDs: Set<WindowID> = [],
    positionsOnly: Bool = false,
    stagesVisibleBeforeParking: Bool = false,
    focusWindowIDAfterCommit: WindowID? = nil,
    focusInputTimestampAfterCommit: TimeInterval? = nil,
    cursorWarpWindowIDAfterCommit: WindowID? = nil,
    cursorWarpInputTimestampAfterCommit: TimeInterval? = nil,
    focusCompletionAfterCommit:
      (@MainActor @Sendable (NativeFocusResult) -> Void)? = nil,
    cursorWarpIsCurrentAfterCommit:
      (@MainActor @Sendable () -> Bool)? = nil,
    focusRequestIDAfterCommit:
      (@MainActor @Sendable (NativeFocusRequestID?) -> Void)? = nil,
    forceFloatingFrameWrites: Bool = false,
    forcingFloatingFrameWritesFor forcedFloatingWindowIDs: Set<WindowID> = [],
    workspaceTransition: WorkspaceVerticalTransition? = nil,
    commandPerformance: CommandPerformanceContext? = nil,
    source: String = "layout"
  ) {
    let layoutStartedAt = ProcessInfo.processInfo.systemUptime
    var assignments: [FrameAssignment] = []
    var borderAssignments: [FrameAssignment] = []
    var nativeFullscreenPlaceholderAssignments: [FrameAssignment] = []
    var hiddenWindowIDs = Set<WindowID>()
    var outOfScopeWindowIDs = Set<WindowID>()
    let allPhysicalMonitorFrames = latestMonitors.map(\.physicalFrame)
    let viewports = viewportsByMonitor
    let overviewParksWindows = overviewController?.isOpen == true
      && overviewController?.usesWorkspaceParking == true
    let liveMonitorIDs = Set(state.monitors.map(\.id))
    layoutPlansByMonitor = layoutPlansByMonitor.filter {
      liveMonitorIDs.contains($0.key)
    }
    for monitorIndex in state.monitors.indices {
      let monitor = state.monitors[monitorIndex]
      if let monitorIDs, !monitorIDs.contains(monitor.id),
        let cached = layoutPlansByMonitor[monitor.id]
      {
        assignments.append(contentsOf: cached.assignments)
        borderAssignments.append(contentsOf: cached.borderAssignments)
        nativeFullscreenPlaceholderAssignments.append(
          contentsOf: cached.nativeFullscreenPlaceholderAssignments
        )
        hiddenWindowIDs.formUnion(cached.hiddenWindowIDs)
        outOfScopeWindowIDs.formUnion(cached.assignments.map(\.windowID))
        continue
      }
      guard
        let monitorSnapshot = latestMonitors.first(where: { $0.id == monitor.id })
      else {
        continue
      }
      guard let viewport = viewports[monitor.id] else { continue }
      let physicalFrame = monitorSnapshot.physicalFrame
      let activeWorkspaceIndex =
        monitor.workspaces.firstIndex {
          $0.id == monitor.activeWorkspace
        } ?? 0
      var monitorAssignments: [FrameAssignment] = []
      var monitorBorderAssignments: [FrameAssignment] = []
      var monitorNativeFullscreenPlaceholderAssignments: [FrameAssignment] = []
      var monitorHiddenWindowIDs = Set<WindowID>()
      for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
        let workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
        let workspaceWindows = workspace.columns
          .flatMap(\.windows)
          .compactMap { state.windows[$0] }
        let layout = computeLayout(
          workspace: workspace,
          viewport: viewport,
          windows: workspaceWindows,
          settings: state.layout,
          excludingWindowIDs: state.nativeFullscreenWindowIDs
        )
        let sizedFrames = layout.map(preserveIntrinsicSize)
        if workspace.id == monitor.activeWorkspace && !overviewParksWindows {
          let strip = continuousStripFramesForActiveWorkspace(
            sizedFrames,
            viewport: viewport,
            ownerFrame: physicalFrame,
            parkingFrame: viewport,
            allMonitorFrames: allPhysicalMonitorFrames
          )
          monitorAssignments.append(contentsOf: strip.frames)
          monitorBorderAssignments.append(contentsOf: strip.frames)
          if workspaceTransition?.monitorID != monitor.id {
            monitorHiddenWindowIDs.formUnion(strip.parkedWindowIDs)
          }

          if !state.nativeFullscreenWindowIDs.isEmpty {
            let fullscreenStrip = continuousStripFramesForActiveWorkspace(
              computeLayout(
                workspace: workspace,
                viewport: viewport,
                windows: workspaceWindows,
                settings: state.layout
              ),
              viewport: viewport,
              ownerFrame: physicalFrame,
              parkingFrame: viewport,
              allMonitorFrames: allPhysicalMonitorFrames
            )
            monitorNativeFullscreenPlaceholderAssignments.append(
              contentsOf: fullscreenStrip.frames.filter {
                state.nativeFullscreenWindowIDs.contains($0.windowID)
                  && fullscreenStrip.visibilityByWindowID[$0.windowID] == .visible
              }
            )
          }

          for assignment in floatingAssignments(in: workspace) {
            monitorBorderAssignments.append(assignment)
            if forceFloatingFrameWrites
              || forcedFloatingWindowIDs.contains(assignment.windowID)
              || platform.isWindowHidden(assignment.windowID)
              || platform.hasPendingFrameTransition(assignment.windowID)
            {
              monitorAssignments.append(assignment)
            }
          }
        } else if !overviewParksWindows,
          let deltaY = outgoingWorkspaceVerticalRibbonOffset(
            workspaceID: workspace.id,
            monitorID: monitor.id,
            transition: workspaceTransition,
            physicalFrame: physicalFrame
          )
        {
          let strip = continuousStripFramesForActiveWorkspace(
            sizedFrames,
            viewport: viewport,
            ownerFrame: physicalFrame,
            parkingFrame: viewport,
            allMonitorFrames: allPhysicalMonitorFrames
          )
          let leaving = (strip.frames + floatingAssignments(in: workspace)).map {
            translatedAssignment($0, deltaY: deltaY)
          }
          monitorAssignments.append(contentsOf: leaving)
          monitorBorderAssignments.append(contentsOf: leaving)
        } else {
          monitorHiddenWindowIDs.formUnion(sizedFrames.map(\.windowID))
          let floatingFrames = floatingAssignments(in: workspace)
          let parked = parkFramesInSafeCorner(
            sizedFrames + floatingFrames,
            ownerFrame: physicalFrame,
            parkingFrame: viewport,
            allMonitorFrames: allPhysicalMonitorFrames,
            preferredSide: workspaceIndex < activeWorkspaceIndex ? .left : .right
          )
          monitorHiddenWindowIDs.formUnion(floatingFrames.map(\.windowID))
          monitorAssignments.append(contentsOf: parked)
          monitorBorderAssignments.append(contentsOf: parked)
        }
      }
      let plan = MonitorLayoutPlan(
        assignments: monitorAssignments,
        borderAssignments: monitorBorderAssignments,
        nativeFullscreenPlaceholderAssignments:
          monitorNativeFullscreenPlaceholderAssignments,
        hiddenWindowIDs: monitorHiddenWindowIDs
      )
      layoutPlansByMonitor[monitor.id] = plan
      assignments.append(contentsOf: plan.assignments)
      outOfScopeWindowIDs.formUnion(
        layoutWindowIDsOutsideSubmissionScope(
          plan,
          monitorID: monitor.id,
          restrictedTo: monitorIDs
        )
      )
      borderAssignments.append(contentsOf: plan.borderAssignments)
      nativeFullscreenPlaceholderAssignments.append(
        contentsOf: plan.nativeFullscreenPlaceholderAssignments
      )
      hiddenWindowIDs.formUnion(plan.hiddenWindowIDs)
    }
    let skipped = additionalSkippedWindowIDs.union(outOfScopeWindowIDs)
      .union(state.nativeFullscreenWindowIDs)
      .union(activelyResizedWindowID.map { Set([$0]) } ?? [])
    let platformAssignments =
      asynchronousPositions
      ? assignments.map(roundAnimatedPosition)
      : assignments
    let animationTiming = animationDisplayTiming(
      monitorIDs: monitorIDs,
      activeMonitorID: activeMonitorID,
      fallbackMonitorID: latestMonitors.first?.id,
      refreshRates: Dictionary(
        uniqueKeysWithValues: latestMonitors.map { ($0.id, $0.refreshRateHz) }
      )
    )
    let selectedWindowID = activeMonitorID.flatMap {
      state.selectedWindowID(on: $0)
    }
    let tracesWindowCreation = platform.hasNewlyDiscoveredWindows
    let borderStartedAt = ProcessInfo.processInfo.systemUptime
    let layoutMS =
      (ProcessInfo.processInfo.systemUptime - layoutStartedAt) * 1_000
    platform.recordPerformanceTrace(
      "frame-submit source=\(source) cg=\(commandPerformance?.generation.description ?? "none") layoutMs=\(String(format: "%.2f", layoutMS))"
    )
    platform.stageWindowBorderSelection(selectedWindowID)
    platform.apply(
      platformAssignments,
      hiddenWindowIDs: hiddenWindowIDs,
      skipping: skipped,
      asynchronousPositions: asynchronousPositions,
      asynchronousPositionTimeoutSeconds: positionTimeoutSeconds,
      animationDuration: animationDuration,
      animationRefreshRateHz: animationTiming.refreshRateHz,
      animationDisplayIDs: animationTiming.displayIDs,
      animateSizeChanges: animateSizeChanges,
      positionsOnly: positionsOnly,
      updateVisibility: updateVisibility ?? !asynchronousPositions,
      stagesVisibleBeforeParking: stagesVisibleBeforeParking,
      focusWindowIDAfterCommit: focusWindowIDAfterCommit,
      focusInputTimestampAfterCommit: focusInputTimestampAfterCommit,
      cursorWarpWindowIDAfterCommit: cursorWarpWindowIDAfterCommit,
      cursorWarpInputTimestampAfterCommit:
        cursorWarpInputTimestampAfterCommit,
      focusCompletionAfterCommit: focusCompletionAfterCommit,
      cursorWarpIsCurrentAfterCommit: cursorWarpIsCurrentAfterCommit,
      focusRequestIDAfterCommit: focusRequestIDAfterCommit,
      acceptedFrameHandler: { [weak self] acceptedFrames in
        guard let self else { return }
        for (windowID, frame) in acceptedFrames {
          state.updateWindowFrame(frame, for: windowID)
        }
      },
      commandPerformance: commandPerformance,
      source: source
    )
    platform.updateWindowBorders(
      frames: borderAssignments,
      selectedWindowID: selectedWindowID,
      liveWindowID: activelyResizedWindowID,
      config: config.decorations.borders
    )
    platform.updateNativeFullscreenPlaceholders(
      nativeFullscreenPlaceholderAssignments.compactMap { assignment in
        guard let window = state.windows[assignment.windowID],
          let monitorID = state.monitorID(containing: assignment.windowID)
        else { return nil }
        return NativeFullscreenPlaceholder(
          windowID: window.id,
          monitorID: monitorID,
          appID: window.appID,
          title: window.title,
          frame: assignment.frame
        )
      },
      selectedWindowID: selectedWindowID,
      stackingWindowID: assignments.first {
        !hiddenWindowIDs.contains($0.windowID)
      }?.windowID ?? assignments.first?.windowID
    )
    if tracesWindowCreation {
      let elapsedMS =
        (ProcessInfo.processInfo.systemUptime - borderStartedAt) * 1_000
      platform.recordPerformanceTrace(
        "initial-border-prepare ms=\(String(format: "%.2f", elapsedMS))"
      )
    }
  }

  private func translatedAssignment(
    _ assignment: FrameAssignment,
    deltaY: Double
  ) -> FrameAssignment {
    var frame = assignment.frame
    frame.y += deltaY
    return FrameAssignment(windowID: assignment.windowID, frame: frame)
  }
}
