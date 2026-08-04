import AppKit
import DefiConfig
import DefiCore
import DefiIPC
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation
import OSLog

private let displayLogger = Logger(
  subsystem: "com.quentin.defi",
  category: "Display"
)

@MainActor
extension Daemon {
  func synchronizeDesktop() {
    let snapshot = platform.snapshot(config: config)
    let tracesWindowCreation = platform.hasNewlyDiscoveredWindows
    if tracesWindowCreation {
      platform.recordPerformanceTrace("sync-snapshot-return")
    }
    let previousViewports = viewportsByMonitor
    let previousActiveMonitorID = activeMonitorID
    let previousActiveWorkspaceID = previousActiveMonitorID.flatMap { monitorID in
      state.monitors.first(where: { $0.id == monitorID })?.activeWorkspace
    }
    let previousSelectedWindowID = previousActiveMonitorID.flatMap {
      state.selectedWindowID(on: $0)
    }
    let previousFloatingMonitorIDs = Dictionary(
      uniqueKeysWithValues: floatingWindowFrames.keys.compactMap { windowID in
        state.monitorID(containing: windowID).map { (windowID, $0) }
      }
    )
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
      pendingWindowRemovalFocusGuard = nil
      cancelDeferredSlowLane()
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
    var nativelyActivatedWorkspace = false
    reconcileWindows(
      snapshot.windows,
      config: config,
      placementPreferences: placementPreferences,
      state: &state
    )
    if displayGeometryChanged {
      rebaseFloatingWindowFrames(
        previousViewports: previousViewports,
        nextViewports: viewportsByMonitor,
        previousMonitorIDs: previousFloatingMonitorIDs
      )
    }
    updateFloatingWindowFrames(
      from: snapshot.windows,
      externallyChangedFrames: snapshot.externallyChangedFrames,
      displayGeometryChanged: displayGeometryChanged
    )
    let newRemovalFocusGuard: WindowRemovalFocusGuard?
    if displayGeometryChanged {
      newRemovalFocusGuard = nil
    } else {
      newRemovalFocusGuard = windowRemovalFocusGuard(
        previousMonitorID: previousActiveMonitorID,
        previousWorkspaceID: previousActiveWorkspaceID,
        previousSelectedWindowID: previousSelectedWindowID,
        removedWindowIDs: snapshot.removedWindowIDs,
        userInputAfterWindowTopology: snapshot.userInputAfterWindowTopology,
        latestUserInputTimestamp: snapshot.latestUserInputTimestamp
      )
    }
    if let newRemovalFocusGuard {
      pendingWindowRemovalFocusGuard = newRemovalFocusGuard
    }
    var preservesWorkspaceAfterRemoval = false
    var guardedRemovalFocus: (windowID: WindowID, inputTimestamp: TimeInterval)?
    if let focusGuard = pendingWindowRemovalFocusGuard {
      switch windowRemovalFocusDecision(
        guard: focusGuard,
        nativeFocusedWindowID: snapshot.focusedWindowID,
        nativeFocusChanged: snapshot.nativeFocusChanged,
        latestUserInputTimestamp: snapshot.latestUserInputTimestamp,
        state: state
      ) {
      case .accept:
        pendingWindowRemovalFocusGuard = nil
      case .wait(let localFallback):
        if newRemovalFocusGuard != nil, let localFallback {
          guardedRemovalFocus = (localFallback, focusGuard.inputTimestamp)
        }
      case .preserve(let localFallback):
        preservesWorkspaceAfterRemoval = true
        if let localFallback {
          guardedRemovalFocus = (localFallback, focusGuard.inputTimestamp)
        }
        pendingWindowRemovalFocusGuard = nil
        preservedWindowRemovalFocusCount += 1
        platform.recordPerformanceTrace(
          "close-focus-preserved target=\(snapshot.focusedWindowID?.rawValue.description ?? "none") fallback=\(localFallback?.rawValue.description ?? "none")"
        )
      }
    }
    if let focusedWindowID = snapshot.focusedWindowID {
      let nativeFocusAccepted =
        snapshot.nativeFocusChanged
        && !preservesWorkspaceAfterRemoval
        && ProcessInfo.processInfo.systemUptime >= suppressNativeFocusUntil
      let selectionChanged = nativeFocusChangesSelection(
        focusedWindowID,
        activeMonitorID: activeMonitorID,
        state: state
      )
      if !preservesWorkspaceAfterRemoval
        && (activeMonitorID == nil || (nativeFocusAccepted && selectionChanged))
      {
        let activatedWorkspace = focusWindow(focusedWindowID, state: &state)
        nativelyActivatedWorkspace = nativeFocusAccepted && activatedWorkspace
        activeMonitorID = state.monitorID(containing: focusedWindowID)
        nativelyFocusedMonitorID = activeMonitorID
      } else if nativeFocusAccepted {
        ignoredRedundantNativeFocusCount += 1
      }
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

    let mouseResizeGestureActive =
      snapshot.leftMouseButtonDown || snapshot.mouseResizeGestureObserved
    if !displayGeometryChanged && mouseResizeGestureActive {
      if !snapshot.leftMouseButtonDown {
        activelyResizedWindowID = nil
      }
      for (windowID, frame) in snapshot.externallyChangedFrames {
        if learnTiledWindowWidth(
          windowID,
          actualFrame: frame,
          state: &state,
          viewports: viewportsByMonitor
        ) {
          activelyResizedWindowID = snapshot.leftMouseButtonDown ? windowID : nil
        }
      }
    } else {
      activelyResizedWindowID = nil
      learnPersistentWidthConstraints(targetMismatches)
    }
    synchronizeScrollOffsets(state: &state, viewports: viewportsByMonitor)
    if let nativelyFocusedMonitorID,
      snapshot.focusedWindowID.flatMap({ state.windows[$0]?.floating }) != true
    {
      alignFocusedColumnLeft(
        on: nativelyFocusedMonitorID,
        state: &state,
        viewports: viewportsByMonitor
      )
    }
    snapScrollOffsetsToTargets()
    if tracesWindowCreation {
      platform.recordPerformanceTrace("sync-before-layout")
    }
    applyCurrentLayout(
      asynchronousPositions: true,
      updateVisibility: true,
      positionTimeoutSeconds: 0.05,
      stagesVisibleBeforeParking: nativelyActivatedWorkspace,
      source: nativelyActivatedWorkspace
        ? "native-workspace"
        : "desktop-sync"
    )
    if let guardedRemovalFocus {
      platform.focus(
        guardedRemovalFocus.windowID,
        unlessUserInputAfter: guardedRemovalFocus.inputTimestamp
      )
    }
    persistPlacements()
    updateMenuBar()
  }

  func persistPlacements() {
    var updated = placementPreferences
    updated.recordPlacements(from: state)
    guard updated != placementPreferences else { return }
    do {
      try placementStore.save(updated)
      placementPreferences = updated
    } catch {
      log("placement persistence failed: \(error)")
    }
  }

  private func displayGeometryDescription(
    _ monitors: [MonitorSnapshot]
  ) -> String {
    monitors.map {
      "\($0.id.rawValue):\(Int($0.frame.width))x\(Int($0.frame.height))"
    }.joined(separator: ",")
  }

  func scheduleDisplayReconciliation() {
    displayConfigurationEventCount += 1
    cancelDeferredSlowLane()
    let now = ProcessInfo.processInfo.systemUptime
    pendingDisplaySyncDeadlines = [0.05, 0.2, 0.5, 1.0, 2.0].map {
      now + $0
    }
    needsDesktopSync = true
  }

  var viewportsByMonitor: [MonitorID: Rect] {
    Dictionary(uniqueKeysWithValues: latestMonitors.map { ($0.id, $0.frame) })
  }

  func rebaseActiveScrollOffsetToDisplayedFrames() {
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
      let viewport = monitorSnapshot.frame
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
            if platform.isWindowHidden(assignment.windowID)
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
      source: source
    )
    platform.updateWindowBorders(
      frames: borderAssignments,
      selectedWindowID: selectedWindowID,
      liveWindowID: activelyResizedWindowID,
      config: config.decorations.borders
    )
  }

  private func updateFloatingWindowFrames(
    from windows: [Window],
    externallyChangedFrames: [WindowID: Rect],
    displayGeometryChanged: Bool
  ) {
    let trackedFloatingIDs = Set(
      state.monitors.flatMap(\.workspaces).flatMap(\.floatingWindows)
    )
    floatingWindowFrames = floatingWindowFrames.filter {
      trackedFloatingIDs.contains($0.key)
    }
    for window in windows where trackedFloatingIDs.contains(window.id) {
      if displayGeometryChanged {
        if floatingWindowFrames[window.id] == nil,
          let monitorID = state.monitorID(containing: window.id),
          let viewport = viewportsByMonitor[monitorID]
        {
          floatingWindowFrames[window.id] = constrainedFloatingFrame(
            window.frame,
            to: viewport
          )
        }
        continue
      }
      if let externalFrame = externallyChangedFrames[window.id] {
        floatingWindowFrames[window.id] = externalFrame
        platform.acceptObservedFrame(externalFrame, for: window.id)
        continue
      }
      guard floatingWindowFrames[window.id] != nil else {
        floatingWindowFrames[window.id] = window.frame
        continue
      }
      guard !platform.isWindowHidden(window.id),
        !platform.hasPendingFrameTransition(window.id)
      else {
        continue
      }
      floatingWindowFrames[window.id] = window.frame
    }
  }

  private func rebaseFloatingWindowFrames(
    previousViewports: [MonitorID: Rect],
    nextViewports: [MonitorID: Rect],
    previousMonitorIDs: [WindowID: MonitorID]
  ) {
    for (windowID, frame) in floatingWindowFrames {
      guard let previousMonitorID = previousMonitorIDs[windowID],
        let previousViewport = previousViewports[previousMonitorID],
        let nextMonitorID = state.monitorID(containing: windowID),
        let nextViewport = nextViewports[nextMonitorID]
      else {
        floatingWindowFrames[windowID] = nil
        continue
      }
      floatingWindowFrames[windowID] = rebasedFloatingFrame(
        frame,
        from: previousViewport,
        to: nextViewport
      )
    }
  }

  func floatingAssignments(in workspace: Workspace) -> [FrameAssignment] {
    workspace.floatingWindows.compactMap { windowID in
      guard let frame = floatingFrame(for: windowID) else { return nil }
      return FrameAssignment(windowID: windowID, frame: frame)
    }
  }

  private func floatingFrame(for windowID: WindowID) -> Rect? {
    if let frame = floatingWindowFrames[windowID] {
      return frame
    }
    guard let frame = state.windows[windowID]?.frame else { return nil }
    floatingWindowFrames[windowID] = frame
    return frame
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

}

private func rebasedFloatingFrame(
  _ frame: Rect,
  from previousViewport: Rect,
  to nextViewport: Rect
) -> Rect {
  let previousHorizontalRange = max(previousViewport.width - frame.width, 1)
  let previousVerticalRange = max(previousViewport.height - frame.height, 1)
  let horizontalProgress = min(
    max((frame.x - previousViewport.x) / previousHorizontalRange, 0),
    1
  )
  let verticalProgress = min(
    max((frame.y - previousViewport.y) / previousVerticalRange, 0),
    1
  )
  let nextHorizontalRange = max(nextViewport.width - frame.width, 0)
  let nextVerticalRange = max(nextViewport.height - frame.height, 0)
  return Rect(
    x: nextViewport.x + horizontalProgress * nextHorizontalRange,
    y: nextViewport.y + verticalProgress * nextVerticalRange,
    width: min(frame.width, nextViewport.width),
    height: min(frame.height, nextViewport.height)
  )
}

private func constrainedFloatingFrame(_ frame: Rect, to viewport: Rect) -> Rect {
  let width = min(frame.width, viewport.width)
  let height = min(frame.height, viewport.height)
  return Rect(
    x: min(max(frame.x, viewport.x), viewport.x + viewport.width - width),
    y: min(max(frame.y, viewport.y), viewport.y + viewport.height - height),
    width: width,
    height: height
  )
}
