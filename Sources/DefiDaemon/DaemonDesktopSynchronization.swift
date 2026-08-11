import AppKit
import DefiConfig
import DefiCore
import DefiIPC
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation

@MainActor
extension Daemon {
  func synchronizeDesktop(
    forceFullWindowRefresh: Bool = false,
    forceWindowListRefresh: Bool = false,
    forceApplicationInventoryRefresh: Bool = false
  ) {
    let snapshot = platform.snapshot(
      config: config,
      forceFullWindowRefresh: forceFullWindowRefresh,
      forceWindowListRefresh: forceWindowListRefresh,
      forceApplicationInventoryRefresh: forceApplicationInventoryRefresh
    )
    let snapshotCompletedAt = ProcessInfo.processInfo.systemUptime
    nextPeriodicWindowRefreshAt = boundedSnapshotRefreshDeadline(
      current: nextPeriodicWindowRefreshAt,
      now: snapshotCompletedAt,
      interval: platform.hasReliableDesktopObservation ? 5 : 0.3,
      reset: forceFullWindowRefresh
    )
    nextWindowListRefreshAt = boundedSnapshotRefreshDeadline(
      current: nextWindowListRefreshAt,
      now: snapshotCompletedAt,
      interval: platform.recommendedWindowListRefreshInterval,
      reset: forceWindowListRefresh
    )
    let applicationInventoryInterval =
      platform.recommendedApplicationInventoryRefreshInterval
    if forceApplicationInventoryRefresh {
      nextApplicationInventoryRefreshAt =
        snapshotCompletedAt + applicationInventoryInterval
    } else {
      nextApplicationInventoryRefreshAt = min(
        nextApplicationInventoryRefreshAt,
        snapshotCompletedAt + applicationInventoryInterval
      )
    }
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
    var preservedCommandFocus: PendingAnimatedFocus?
    var preservedWorkspaceFocus: PendingWorkspaceFocus?
    var preservedDisplacedFocus: DisplacedPointerFocusRecovery?
    if displayGeometryChanged {
      let previous = displayGeometryDescription(latestMonitors)
      let next = displayGeometryDescription(snapshot.monitors)
      displayLogger.info(
        "geometry changed previous=\(previous, privacy: .public) next=\(next, privacy: .public)"
      )
      preservedCommandFocus = pendingAnimatedFocus ?? submittedCommandFocus
      preservedWorkspaceFocus = pendingWorkspaceFocus
      preservedDisplacedFocus = displacedPointerFocusRecovery
      let preservedLogicalFocusWindowID = activeMonitorID.flatMap {
        state.selectedWindowID(on: $0)
      }
      pendingAnimatedFocus = nil
      invalidateSubmittedCommandFocus()
      invalidateSubmittedWorkspaceFocus()
      pendingWorkspaceFocus = nil
      submittedWorkspaceFocusGeneration = nil
      displacedPointerFocusRecovery = nil
      platform.invalidateFrameStateForDisplayChange()
      platform.invalidateFocusStateForDisplayChange()
      invalidatePointerFocusIntent(recoveringTo: preservedLogicalFocusWindowID)
      rearmPointerFocusTransition()
      scrollAnimations.removeAll(keepingCapacity: true)
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
    if displayGeometryChanged {
      requeuePreservedFocusAfterMonitorRetention(
        command: preservedCommandFocus,
        workspace: preservedWorkspaceFocus,
        displaced: preservedDisplacedFocus
      )
    }
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
        platform.invalidateFocusRecovery(recoveringTo: focusedWindowID)
        invalidateSubmittedCommandFocus(recoveringTo: focusedWindowID)
        invalidateSubmittedWorkspaceFocus(recoveringTo: focusedWindowID)
        invalidatePointerFocusIntent(recoveringTo: focusedWindowID)
        rearmPointerFocusTransition()
        pendingAnimatedFocus = nil
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

}
