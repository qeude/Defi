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
  func applyCurrentLayout(
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
    cursorWarpInputTimestampAfterCommit: TimeInterval? = nil,
    focusCompletionAfterCommit:
      (@MainActor @Sendable (NativeFocusResult) -> Void)? = nil,
    cursorWarpIsCurrentAfterCommit:
      (@MainActor @Sendable () -> Bool)? = nil,
    focusRequestIDAfterCommit:
      (@MainActor @Sendable (NativeFocusRequestID?) -> Void)? = nil,
    forceFloatingFrameWrites: Bool = false,
    source: String = "layout"
  ) {
    var assignments: [FrameAssignment] = []
    var borderAssignments: [FrameAssignment] = []
    var hiddenWindowIDs = Set<WindowID>()
    let allPhysicalMonitorFrames = latestMonitors.map(\.physicalFrame)
    for monitorIndex in state.monitors.indices {
      let monitor = state.monitors[monitorIndex]
      guard
        let monitorSnapshot = latestMonitors.first(where: { $0.id == monitor.id })
      else {
        continue
      }
      guard let viewport = viewportsByMonitor[monitor.id] else { continue }
      let physicalFrame = monitorSnapshot.physicalFrame
      let activeWorkspaceIndex =
        monitor.workspaces.firstIndex {
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
          borderAssignments.append(contentsOf: strip.frames)
          hiddenWindowIDs.formUnion(strip.parkedWindowIDs)

          for assignment in floatingAssignments(in: workspace) {
            borderAssignments.append(assignment)
            if forceFloatingFrameWrites
              || platform.isWindowHidden(assignment.windowID)
              || platform.hasPendingFrameTransition(assignment.windowID)
            {
              assignments.append(assignment)
            }
          }
        } else {
          hiddenWindowIDs.formUnion(sizedFrames.map(\.windowID))
          let floatingFrames = floatingAssignments(in: workspace)
          let parked = parkFramesInSafeCorner(
            sizedFrames + floatingFrames,
            ownerFrame: physicalFrame,
            parkingFrame: viewport,
            allMonitorFrames: allPhysicalMonitorFrames,
            preferredSide: workspaceIndex < activeWorkspaceIndex ? .left : .right
          )
          hiddenWindowIDs.formUnion(floatingFrames.map(\.windowID))
          assignments.append(contentsOf: parked.frames)
          borderAssignments.append(contentsOf: parked.frames)
        }
      }
    }
    let skipped = additionalSkippedWindowIDs.union(
      activelyResizedWindowID.map { Set([$0]) } ?? []
    )
    let platformAssignments =
      asynchronousPositions
      ? assignments.map(roundAnimatedPosition)
      : assignments
    let selectedWindowID = activeMonitorID.flatMap {
      state.selectedWindowID(on: $0)
    }
    let tracesWindowCreation = platform.hasNewlyDiscoveredWindows
    let borderStartedAt = ProcessInfo.processInfo.systemUptime
    platform.prepareWindowBorderSelection(selectedWindowID)
    platform.updateWindowBorders(
      frames: borderAssignments,
      selectedWindowID: selectedWindowID,
      liveWindowID: activelyResizedWindowID,
      config: config.decorations.borders
    )
    if tracesWindowCreation {
      let elapsedMS =
        (ProcessInfo.processInfo.systemUptime - borderStartedAt) * 1_000
      platform.recordPerformanceTrace(
        "initial-border-prepare ms=\(String(format: "%.2f", elapsedMS))"
      )
    }
    platform.apply(
      platformAssignments,
      hiddenWindowIDs: hiddenWindowIDs,
      skipping: skipped,
      asynchronousPositions: asynchronousPositions,
      asynchronousPositionTimeoutSeconds: positionTimeoutSeconds,
      animationDuration: animationDuration,
      animationRefreshRateHz: activeDisplayRefreshRate,
      animateSizeChanges: animateSizeChanges,
      positionsOnly: positionsOnly,
      updateVisibility: updateVisibility ?? !asynchronousPositions,
      stagesVisibleBeforeParking: stagesVisibleBeforeParking,
      focusWindowIDAfterCommit: focusWindowIDAfterCommit,
      focusInputTimestampAfterCommit: focusInputTimestampAfterCommit,
      cursorWarpInputTimestampAfterCommit:
        cursorWarpInputTimestampAfterCommit,
      focusCompletionAfterCommit: focusCompletionAfterCommit,
      cursorWarpIsCurrentAfterCommit: cursorWarpIsCurrentAfterCommit,
      focusRequestIDAfterCommit: focusRequestIDAfterCommit,
      source: source
    )
    platform.updateWindowBorders(
      frames: borderAssignments,
      selectedWindowID: selectedWindowID,
      liveWindowID: activelyResizedWindowID,
      config: config.decorations.borders
    )
  }
}
