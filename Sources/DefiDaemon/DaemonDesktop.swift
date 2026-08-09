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
    let previousObservedWindowFrames = state.windows.mapValues(\.frame)
    let previousMouseGestureWindowFrames = previousObservedWindowFrames.merging(
      mouseGestureDisplayedOriginFrames
    ) { _, displayedFrame in
      displayedFrame
    }
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
    let mouseGestureEnded =
      snapshot.mouseResizeGestureObserved && !snapshot.leftMouseButtonDown
    let mouseInteractionEnded =
      mouseGestureEnded || snapshot.mouseFocusReleaseObserved
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
      let preservedCommandFocus = pendingAnimatedFocus ?? submittedCommandFocus
      let preservedWorkspaceFocus = pendingWorkspaceFocus
      pendingAnimatedFocus = nil
      submittedCommandFocus = nil
      pendingWorkspaceFocus = nil
      submittedWorkspaceFocusGeneration = nil
      platform.invalidateFrameStateForDisplayChange()
      platform.invalidateFocusStateForDisplayChange()
      scrollAnimations.removeAll(keepingCapacity: true)
      pendingAnimatedFocus = preservedCommandFocus
      pendingWorkspaceFocus = preservedWorkspaceFocus
      submittedWorkspaceFocusGeneration = nil
      pendingWindowRemovalFocusGuard = nil
      consumeDeferredMouseFocusIntent()
      cancelDeferredSlowLane()
      persistentWidthDriftCounts.removeAll(keepingCapacity: true)
      finishMouseGestureTracking()
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
    deferredMouseFocusIntent = updatedDeferredMouseFocusIntent(
      current: deferredMouseFocusIntent,
      consumedMouseFocusIntentTimestamp: consumedMouseFocusIntentTimestamp,
      mouseFocusIntentWindowID: snapshot.mouseFocusIntentWindowID.flatMap {
        state.windows[$0] == nil ? nil : $0
      },
      mouseFocusIntentTimestamp: snapshot.mouseFocusIntentTimestamp,
      focusedWindowID: snapshot.focusedWindowID,
      nativeFocusChanged: snapshot.nativeFocusChanged,
      mouseInteractionEnded: mouseInteractionEnded
    )
    if displayGeometryChanged {
      rebaseFloatingWindowFrames(
        previousViewports: previousViewports,
        nextViewports: viewportsByMonitor,
        previousMonitorIDs: previousFloatingMonitorIDs
      )
    }
    if mouseGestureSettlement?.generation != mouseGestureGeneration {
      mouseGestureSettlement = nil
    }
    let postReleaseMouseGestureActive = mouseGestureSettlement != nil
    let mouseResizeGestureActive =
      !mouseGesturePreempted
      && (snapshot.leftMouseButtonDown
        || snapshot.mouseResizeGestureObserved
        || postReleaseMouseGestureActive)
    let reassignedFloatingMonitorIDs = updateFloatingWindowFrames(
      from: snapshot.windows,
      externallyChangedFrames: snapshot.externallyChangedFrames,
      displayGeometryChanged: displayGeometryChanged,
      mouseResizeGestureActive: mouseResizeGestureActive
    )
    let reassignedMonitorID =
      snapshot.focusedWindowID.flatMap {
        reassignedFloatingMonitorIDs[$0]
      }
      ?? previousSelectedWindowID.flatMap {
        reassignedFloatingMonitorIDs[$0]
      }
    if let reassignedMonitorID {
      activeMonitorID = reassignedMonitorID
      nativelyFocusedMonitorID = reassignedMonitorID
    }
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
      let keyboardFocusIntentCurrent = keyboardFocusIntentIsCurrent(
        keyboardFocusIntentTimestamp: snapshot.keyboardFocusIntentTimestamp,
        latestCommandInputTimestamp: latestCommandInputTimestamp
      )
      let mouseReleaseFocusIntentCurrent = mouseReleaseFocusIntentIsCurrent(
        focusedWindowID: focusedWindowID,
        mouseFocusIntentWindowID: deferredMouseFocusIntent?.windowID,
        mouseFocusIntentTimestamp: deferredMouseFocusIntent?.timestamp,
        latestCommandInputTimestamp: latestCommandInputTimestamp,
        nativeFocusChanged: deferredMouseFocusIntent?.focusObserved == true
      )
      let deferredMouseFocusPending = deferredMouseFocusIntent != nil
      let deferredMouseFocusReady =
        deferredMouseFocusIntent?.mouseInteractionEnded == true
        && (deferredMouseFocusIntent?.focusObserved == true
          || deferredMouseFocusIntent?.windowID == focusedWindowID)
      let nativeFocusAccepted =
        nativeFocusMutationIsReady(
          nativeFocusChanged: snapshot.nativeFocusChanged,
          mouseInteractionEnded: mouseInteractionEnded,
          leftMouseButtonDown: snapshot.leftMouseButtonDown,
          deferredMouseFocusPending: deferredMouseFocusPending,
          deferredMouseFocusReady: deferredMouseFocusReady,
          mouseReleaseFocusIntentCurrent: mouseReleaseFocusIntentCurrent,
          keyboardFocusIntentCurrent: keyboardFocusIntentCurrent
        )
        && !preservesWorkspaceAfterRemoval
        && (keyboardFocusIntentCurrent
          || ProcessInfo.processInfo.systemUptime >= suppressNativeFocusUntil)
      let selectionChanged = nativeFocusChangesSelection(
        focusedWindowID,
        activeMonitorID: activeMonitorID,
        state: state
      )
      if nativeFocusAccepted {
        submittedCommandFocus = nil
        pendingWorkspaceFocus = nil
        submittedWorkspaceFocusGeneration = nil
      }
      if snapshot.leftMouseButtonDown && snapshot.nativeFocusChanged
        && selectionChanged && !nativeFocusAccepted
      {
        platform.recordPerformanceTrace(
          "mouse-focus-deferred window=\(focusedWindowID.rawValue)"
        )
      }
      if !preservesWorkspaceAfterRemoval
        && (!snapshot.leftMouseButtonDown || nativeFocusAccepted)
        && (activeMonitorID == nil || (nativeFocusAccepted && selectionChanged))
      {
        let activatedWorkspace = focusWindow(focusedWindowID, state: &state)
        nativelyActivatedWorkspace = nativeFocusAccepted && activatedWorkspace
        activeMonitorID = state.monitorID(containing: focusedWindowID)
        nativelyFocusedMonitorID = activeMonitorID
        if mouseInteractionEnded {
          platform.recordPerformanceTrace(
            "mouse-focus-committed window=\(focusedWindowID.rawValue)"
          )
        }
      } else if nativeFocusAccepted {
        ignoredRedundantNativeFocusCount += 1
      }
      if nativeFocusAccepted && deferredMouseFocusReady {
        consumeDeferredMouseFocusIntent()
      } else if deferredMouseFocusPending
        && snapshot.nativeFocusChanged
        && !snapshot.leftMouseButtonDown
        && !keyboardFocusIntentCurrent
        && !mouseReleaseFocusIntentCurrent
      {
        consumeDeferredMouseFocusIntent()
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

    var mouseReordered = false
    if !displayGeometryChanged && mouseResizeGestureActive {
      let mouseGestureCandidateWindowIDs = [
        activelyResizedWindowID,
        snapshot.mouseFocusIntentWindowID,
        snapshot.focusedWindowID,
      ].compactMap { $0 }
      let translatedWindowID = mouseTranslatedTiledWindowID(
        candidateWindowIDs: mouseGestureCandidateWindowIDs,
        externallyChangedFrames: snapshot.externallyChangedFrames,
        state: state,
        viewports: viewportsByMonitor
      )
      let gestureWindowID = mouseGestureTiledWindowID(
        translatedWindowID: translatedWindowID,
        activeWindowID: activelyResizedWindowID,
        mouseFocusIntentWindowID: snapshot.mouseFocusIntentWindowID,
        focusedWindowID: snapshot.focusedWindowID,
        state: state
      )
      mouseGestureScrollAnchor = resolvedMouseGestureScrollAnchor(
        current: mouseGestureScrollAnchor,
        gestureWindowID: gestureWindowID,
        mouseGestureActive: mouseResizeGestureActive,
        state: state
      )
      let actualFrame = gestureWindowID.flatMap { windowID in
        snapshot.windows.first(where: { $0.id == windowID })?.frame
      }
      mouseGestureInitialFrame = resolvedMouseGestureInitialFrame(
        currentInitialFrame: mouseGestureInitialFrame,
        gestureWindowID: gestureWindowID,
        activeWindowID: activelyResizedWindowID,
        translatedWindowID: translatedWindowID,
        leftMouseButtonDown: snapshot.leftMouseButtonDown,
        previousObservedFrames: previousMouseGestureWindowFrames,
        actualFrame: actualFrame
      )
      if snapshot.leftMouseButtonDown {
        activelyResizedWindowID = gestureWindowID
        if let gestureWindowID,
          let actualFrame,
          let mouseGestureInitialFrame,
          mouseFrameWasTranslated(
            from: mouseGestureInitialFrame,
            to: actualFrame
          ),
          reorderTiledWindowAfterMouseDrag(
            gestureWindowID,
            actualFrame: actualFrame,
            initialFrame: mouseGestureInitialFrame,
            state: &state,
            viewports: viewportsByMonitor
          )
        {
          mouseReordered = true
          platform.recordPerformanceTrace(
            "mouse-reorder-live window=\(gestureWindowID.rawValue)"
          )
        }
      } else {
        if let gestureWindowID,
          let actualFrame,
          let mouseGestureInitialFrame,
          mouseFrameWasTranslated(
            from: mouseGestureInitialFrame,
            to: actualFrame
          ),
          reorderTiledWindowAfterCompletedMouseDrag(
            gestureWindowID,
            actualFrame: actualFrame,
            initialFrame: mouseGestureInitialFrame,
            state: &state,
            viewports: viewportsByMonitor
          )
        {
          mouseReordered = true
          platform.recordPerformanceTrace(
            "mouse-reorder window=\(gestureWindowID.rawValue)"
          )
        }
        if mouseGestureEnded,
          let gestureWindowID,
          let mouseGestureInitialFrame,
          let actualFrame
        {
          let now = ProcessInfo.processInfo.systemUptime
          mouseGestureSettlement = MouseGestureSettlement(
            generation: mouseGestureGeneration,
            windowID: gestureWindowID,
            initialFrame: mouseGestureInitialFrame,
            releasedFrame: actualFrame,
            now: now,
            maximumDuration: mouseGestureSettlementMaximumDuration(
              latencySensitive: platform.latencySensitiveWindowIDs.contains(
                gestureWindowID
              )
            )
          )
          activelyResizedWindowID = gestureWindowID
        } else if let settlement = mouseGestureSettlement,
          settlement.generation == mouseGestureGeneration,
          settlement.windowID == gestureWindowID,
          let actualFrame
        {
          let update = advanceMouseGestureSettlement(
            settlement,
            actualFrame: actualFrame,
            now: ProcessInfo.processInfo.systemUptime,
            animationPending: platform.hasPendingAnimatedFrameWrites
          )
          mouseGestureSettlement = update.settlement
          if update.shouldFinish {
            finishMouseGestureTracking(preservingScrollAnchor: true)
          }
        } else {
          finishMouseGestureTracking()
        }
      }
      if !mouseReordered,
        let gestureWindowID,
        let widthLearningFrame = mouseGestureWidthLearningFrame(
          externallyChangedFrame: snapshot.externallyChangedFrames[
            gestureWindowID
          ],
          actualFrame: actualFrame,
          postReleaseSettlementActive: postReleaseMouseGestureActive
        )
      {
        _ = learnTiledWindowWidth(
          gestureWindowID,
          actualFrame: widthLearningFrame,
          state: &state,
          viewports: viewportsByMonitor
        )
      }
    } else {
      finishMouseGestureTracking()
      learnPersistentWidthConstraints(targetMismatches)
    }
    synchronizeScrollOffsets(state: &state, viewports: viewportsByMonitor)
    let preservesMouseViewport = mouseGestureScrollAnchor != nil
    if let mouseGestureScrollAnchor {
      restoreWorkspaceScroll(mouseGestureScrollAnchor, state: &state)
    }
    if !preservesMouseViewport, let nativelyFocusedMonitorID,
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
    let animatesMouseReorder =
      mouseReordered
      && snapshot.leftMouseButtonDown
      && config.animation.enabled
      && config.animation.durationMS > 0
    if animatesMouseReorder {
      mouseReorderAnimationActive = true
      beginFrameAnimationActivity()
    }
    applyCurrentLayout(
      asynchronousPositions: true,
      updateVisibility: true,
      positionTimeoutSeconds: 0.05,
      animationDuration: animatesMouseReorder
        ? TimeInterval(config.animation.durationMS) / 1_000
        : 0,
      positionsOnly: animatesMouseReorder,
      stagesVisibleBeforeParking: nativelyActivatedWorkspace,
      forceFloatingFrameWrites: displayGeometryChanged,
      source: nativelyActivatedWorkspace
        ? "native-workspace"
        : (animatesMouseReorder ? "mouse-reorder-animation" : "desktop-sync")
    )
    if let guardedRemovalFocus {
      platform.focus(
        guardedRemovalFocus.windowID,
        unlessUserInputAfter: guardedRemovalFocus.inputTimestamp
      )
    }
    persistPlacements()
    updateMenuBar()
    if !snapshot.leftMouseButtonDown && mouseGestureSettlement == nil {
      mouseGestureScrollAnchor = nil
    }
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

  private func consumeDeferredMouseFocusIntent() {
    if let timestamp = deferredMouseFocusIntent?.timestamp {
      consumedMouseFocusIntentTimestamp = max(
        consumedMouseFocusIntentTimestamp,
        timestamp
      )
    }
    deferredMouseFocusIntent = nil
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
    focusInputTimestampAfterCommit: TimeInterval? = nil,
    cursorWarpInputTimestampAfterCommit: TimeInterval? = nil,
    focusCompletionAfterCommit:
      (@MainActor @Sendable (NativeFocusResult) -> Void)? = nil,
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
    displayGeometryChanged: Bool,
    mouseResizeGestureActive: Bool
  ) -> [WindowID: MonitorID] {
    var reassignedMonitorIDs: [WindowID: MonitorID] = [:]
    let trackedFloatingIDs = Set(
      state.monitors.flatMap(\.workspaces).flatMap(\.floatingWindows)
    )
    floatingWindowFrames = floatingWindowFrames.filter {
      trackedFloatingIDs.contains($0.key)
    }
    for window in windows where trackedFloatingIDs.contains(window.id) {
      if !displayGeometryChanged,
        mouseResizeGestureActive,
        !platform.isWindowHidden(window.id),
        let targetMonitorID = window.monitorID,
        moveFloatingWindow(window.id, to: targetMonitorID, state: &state)
      {
        reassignedMonitorIDs[window.id] = targetMonitorID
      }
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
    return reassignedMonitorIDs
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

  func refreshFloatingWindowFramesBeforeWorkspaceMutation() {
    guard
      let monitorID = activeMonitorID ?? state.monitors.first?.id,
      let monitor = state.monitors.first(where: { $0.id == monitorID }),
      let workspace = monitor.workspaces.first(where: {
        $0.id == monitor.activeWorkspace
      })
    else {
      return
    }
    for (windowID, frame) in platform.userAdjustedFrames(
      for: Set(workspace.floatingWindows)
    ) {
      floatingWindowFrames[windowID] = frame
      platform.acceptObservedFrame(frame, for: windowID)
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
