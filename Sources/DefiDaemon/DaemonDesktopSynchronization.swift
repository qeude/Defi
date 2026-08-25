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
    forceApplicationInventoryRefresh: Bool = false,
    consumePeriodicWindowRefresh: Bool = false
  ) {
    let nativeFocusWasPending = platform.hasPendingNativeFocusEvent
    if desktopSnapshotInFlight {
      supersededDesktopSnapshotRequest = (
        forceFullWindowRefresh,
        forceWindowListRefresh,
        forceApplicationInventoryRefresh,
        consumePeriodicWindowRefresh
      )
      return
    }
    desktopSnapshotInFlight = true
    platform.beginSnapshot(
      config: config,
      forceFullWindowRefresh: forceFullWindowRefresh,
      forceWindowListRefresh: forceWindowListRefresh,
      forceApplicationInventoryRefresh: forceApplicationInventoryRefresh
    ) { [weak self] snapshot in
      self?.applyDesktopSnapshot(
        snapshot,
        nativeFocusWasPending: nativeFocusWasPending,
        forceFullWindowRefresh: forceFullWindowRefresh,
        forceWindowListRefresh: forceWindowListRefresh,
        forceApplicationInventoryRefresh: forceApplicationInventoryRefresh,
        consumePeriodicWindowRefresh: consumePeriodicWindowRefresh
      )
    }
  }

  private func applyDesktopSnapshot(
    _ snapshot: DesktopSnapshot,
    nativeFocusWasPending: Bool,
    forceFullWindowRefresh: Bool,
    forceWindowListRefresh: Bool,
    forceApplicationInventoryRefresh: Bool,
    consumePeriodicWindowRefresh: Bool
  ) {
    defer {
      desktopSnapshotInFlight = false
      if let pending = supersededDesktopSnapshotRequest {
        supersededDesktopSnapshotRequest = nil
        synchronizeDesktop(
          forceFullWindowRefresh: pending.forceFullWindowRefresh,
          forceWindowListRefresh: pending.forceWindowListRefresh,
          forceApplicationInventoryRefresh: pending.forceApplicationInventoryRefresh,
          consumePeriodicWindowRefresh: pending.consumePeriodicWindowRefresh
        )
      }
    }
    let snapshotCompletedAt = ProcessInfo.processInfo.systemUptime
    nextPeriodicWindowRefreshAt = boundedSnapshotRefreshDeadline(
      current: nextPeriodicWindowRefreshAt,
      now: snapshotCompletedAt,
      interval: desktopSnapshotRefreshInterval(
        reliableDesktopObservation: platform.hasReliableDesktopObservation
      ),
      reset: forceFullWindowRefresh || consumePeriodicWindowRefresh
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
    }.map { snapshot.windowIDReplacements[$0] ?? $0 }
    let mouseGestureEnded =
      snapshot.mouseResizeGestureObserved && !snapshot.leftMouseButtonDown
    let mouseInteractionEnded =
      mouseGestureEnded || snapshot.mouseFocusReleaseObserved
    let previousFloatingMonitorIDs: [WindowID: MonitorID] = Dictionary(
      uniqueKeysWithValues: state.windows.keys.compactMap { windowID in
        guard state.windows[windowID]?.floating == true else { return nil }
        return state.monitorID(containing: windowID).map {
          (windowID, $0)
        }
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
    var nativeCursorWarpWindowID: WindowID?
    var nativeCursorWarpInputTimestamp: TimeInterval?
    var nativeFocusFrameMonitorID: MonitorID?
    let previouslyManagedWindowIDs = Set(state.windows.keys.map {
      snapshot.windowIDReplacements[$0] ?? $0
    })
    let enteringNativeFullscreenWindowIDs = snapshot.nativeFullscreenWindowIDs
      .subtracting(state.nativeFullscreenWindowIDs)
    platform.updateNativeFullscreenWindowIDs(
      snapshot.nativeFullscreenWindowIDs,
      activeWindowIDs: snapshot.activeNativeFullscreenWindowIDs
    )
    if pendingAnimatedFocus.map({
      enteringNativeFullscreenWindowIDs.contains($0.windowID)
    }) == true {
      pendingAnimatedFocus = nil
    }
    if submittedCommandFocus.map({
      enteringNativeFullscreenWindowIDs.contains($0.windowID)
    }) == true {
      invalidateSubmittedCommandFocus()
    }
    let relocatedTransientIDs = reconcileWindows(
      snapshot.windows,
      config: config,
      placementPreferences: placementPreferences,
      windowIDReplacements: snapshot.windowIDReplacements,
      externallyChangedWindowIDs: Set(snapshot.externallyChangedFrames.keys),
      nativeFullscreenWindowIDs: snapshot.nativeFullscreenWindowIDs,
      viewports: viewportsByMonitor,
      nativeFocusedWindowID: snapshot.focusedWindowID,
      frontmostProcessID: snapshot.frontmostProcessID,
      state: &state
    )
    let relocatedFloatingWindowIDs =
      displayGeometryChanged
      ? []
      : floatingWindowIDsMovedBetweenMonitors(
        previousWindowMonitorIDs: previousFloatingMonitorIDs,
        nextWindowMonitorIDs: Dictionary(
          uniqueKeysWithValues: previousFloatingMonitorIDs.keys.compactMap { windowID in
            state.monitorID(containing: windowID).map { (windowID, $0) }
          }
        ),
        windows: state.windows
      ).intersection(relocatedTransientIDs)
    if let previousSelectedWindowID,
      let reboundMonitorID = state.reboundFocusMonitorID(for: previousSelectedWindowID),
      reboundMonitorID != previousActiveMonitorID
    {
      activeMonitorID = reboundMonitorID
      nativelyFocusedMonitorID = reboundMonitorID
    }
    deferredMouseFocusIntent = updatedDeferredMouseFocusIntent(
      current: deferredMouseFocusIntent,
      consumedMouseFocusIntentTimestamp: consumedMouseFocusIntentTimestamp,
      mouseFocusIntentWindowID: snapshot.mouseFocusIntentWindowID.flatMap {
        state.windows[$0] == nil ? nil : $0
      },
      mouseFocusIntentTimestamp: snapshot.mouseFocusIntentTimestamp,
      focusedWindowID: snapshot.focusedWindowID,
      nativeFocusChanged: snapshot.nativeFocusChanged,
      mouseInteractionEnded: mouseInteractionEnded,
      nativeFocusTargetIsNew: snapshot.focusedWindowID.map {
        !previouslyManagedWindowIDs.contains($0)
      } ?? false,
      nativeFocusEventAfterMouseRelease:
        snapshot.nativeFocusObservedAfterMouseRelease
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
    var mouseResizeGestureActive =
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
    if !relocatedFloatingWindowIDs.isEmpty {
      rebaseFloatingWindowFrames(
        previousViewports: previousViewports,
        nextViewports: viewportsByMonitor,
        previousMonitorIDs: previousFloatingMonitorIDs,
        windowIDs: relocatedFloatingWindowIDs
      )
    }
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
    var guardedRemovalFocus: GuardedWindowRemovalFocusAction?
    if let focusGuard = pendingWindowRemovalFocusGuard {
      let decision = windowRemovalFocusDecision(
        guard: focusGuard,
        nativeFocusedWindowID: snapshot.focusedWindowID,
        nativeFocusChanged: snapshot.nativeFocusChanged,
        latestUserInputTimestamp: snapshot.latestUserInputTimestamp,
        state: state
      )
      guardedRemovalFocus = guardedWindowRemovalFocusAction(
        decision: decision,
        focusGuard: focusGuard,
        newlyCreated: newRemovalFocusGuard != nil
      )
      if let guardedRemovalFocus {
        nativelyFocusedMonitorID = guardedRemovalFocus.monitorID
        platform.recordPerformanceTrace(
          "close-focus-reveal window=\(guardedRemovalFocus.windowID.rawValue) monitor=\(guardedRemovalFocus.monitorID.rawValue)"
        )
      }
      switch decision {
      case .accept:
        pendingWindowRemovalFocusGuard = nil
      case .wait:
        break
      case .preserve(let localFallback):
        preservesWorkspaceAfterRemoval = true
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
          keyboardFocusIntentCurrent: keyboardFocusIntentCurrent,
          nativeFocusSuppressed:
            ProcessInfo.processInfo.systemUptime < suppressNativeFocusUntil
        )
        && !preservesWorkspaceAfterRemoval
      let selectionChanged = nativeFocusChangesSelection(
        focusedWindowID,
        activeMonitorID: activeMonitorID,
        state: state
      )
      nativeCursorWarpInputTimestamp = nativeFocusCursorWarpTimestamp(
        mouseFollowsFocus: config.input.mouseFollowsFocus,
        nativeFocusAccepted: nativeFocusAccepted,
        keyboardFocusIntentCurrent: keyboardFocusIntentCurrent,
        keyboardFocusIntentTimestamp: snapshot.keyboardFocusIntentTimestamp
      )
      if nativeCursorWarpInputTimestamp != nil {
        nativeCursorWarpWindowID = focusedWindowID
      }
      if nativeFocusAccepted {
        nativeFocusFrameMonitorID = state.monitorID(containing: focusedWindowID)
        if let keyboardFocusIntentTimestamp = snapshot.keyboardFocusIntentTimestamp {
          platform.userInputTracker.consumeFocusIntent(
            at: keyboardFocusIntentTimestamp
          )
        }
        platform.invalidateFocusRecovery(recoveringTo: focusedWindowID)
        invalidateSubmittedCommandFocus(recoveringTo: focusedWindowID)
        invalidateSubmittedWorkspaceFocus(recoveringTo: focusedWindowID)
        invalidatePointerFocusIntent(recoveringTo: focusedWindowID)
        rearmPointerFocusTransition()
        pendingAnimatedFocus = nil
        pendingWorkspaceFocus = nil
        submittedWorkspaceFocusGeneration = nil
      }
      if keyboardFocusPreemptsMouseGesture(
        nativeFocusAccepted: nativeFocusAccepted,
        keyboardFocusIntentCurrent: keyboardFocusIntentCurrent,
        leftMouseButtonDown: snapshot.leftMouseButtonDown,
        postReleaseSettlementActive: postReleaseMouseGestureActive
      ) {
        preemptMouseGesture()
        mouseResizeGestureActive = false
        platform.recordPerformanceTrace(
          "mouse-gesture-preempted-by-keyboard-focus window=\(focusedWindowID.rawValue)"
        )
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
    let focusedWindowIDForAlignment =
      guardedRemovalFocus?.windowID ?? snapshot.focusedWindowID
    if !preservesMouseViewport, let nativelyFocusedMonitorID,
      focusedWindowIDForAlignment.flatMap({ state.windows[$0]?.floating }) != true
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
    let nativeFocusSkippedWindowIDs: Set<WindowID>
    if nativeFocusWasPending {
      if let nativeFocusFrameMonitorID {
        nativeFocusSkippedWindowIDs = Set(
          state.windows.keys.filter {
            state.monitorID(containing: $0) != nativeFocusFrameMonitorID
          }
        )
      } else {
        nativeFocusSkippedWindowIDs = Set(state.windows.keys)
      }
    } else {
      nativeFocusSkippedWindowIDs = []
    }
    let nativeCursorWarpIsCurrentAfterCommit:
      (@MainActor @Sendable () -> Bool)?
    if let nativeCursorWarpWindowID {
      nativeCursorWarpIsCurrentAfterCommit = { [weak self] in
        guard let self,
          let monitorID = self.state.monitorID(
            containing: nativeCursorWarpWindowID
          ),
          !self.platform.hasPendingNativeFocusEvent
        else { return false }
        return self.state.selectedWindowID(on: monitorID)
          == nativeCursorWarpWindowID
      }
    } else {
      nativeCursorWarpIsCurrentAfterCommit = nil
    }
    applyCurrentLayout(
      asynchronousPositions: true,
      updateVisibility: true,
      positionTimeoutSeconds: 0.05,
      animationDuration: animatesMouseReorder
        ? TimeInterval(config.animation.durationMS) / 1_000
        : 0,
      skipping: nativeFocusSkippedWindowIDs,
      positionsOnly: animatesMouseReorder,
      stagesVisibleBeforeParking: nativelyActivatedWorkspace,
      cursorWarpWindowIDAfterCommit: nativeCursorWarpWindowID,
      cursorWarpInputTimestampAfterCommit: nativeCursorWarpInputTimestamp,
      cursorWarpIsCurrentAfterCommit:
        nativeCursorWarpIsCurrentAfterCommit,
      forceFloatingFrameWrites: displayGeometryChanged,
      forcingFloatingFrameWritesFor: relocatedFloatingWindowIDs,
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
