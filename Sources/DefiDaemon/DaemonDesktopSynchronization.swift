import AppKit
import DefiConfig
import DefiCore
import DefiIPC
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation

typealias DesktopSnapshotRequest = (
  forceFullWindowRefresh: Bool,
  forceWindowListRefresh: Bool,
  forceApplicationInventoryRefresh: Bool,
  targetedWindowRetryRefresh: Bool,
  consumePeriodicWindowRefresh: Bool
)

func coalescedDesktopSnapshotRequest(
  _ request: DesktopSnapshotRequest,
  pending: DesktopSnapshotRequest?
) -> DesktopSnapshotRequest {
  (
    request.forceFullWindowRefresh || pending?.forceFullWindowRefresh == true,
    request.forceWindowListRefresh || pending?.forceWindowListRefresh == true,
    request.forceApplicationInventoryRefresh || pending?.forceApplicationInventoryRefresh == true,
    request.targetedWindowRetryRefresh || pending?.targetedWindowRetryRefresh == true,
    request.consumePeriodicWindowRefresh || pending?.consumePeriodicWindowRefresh == true
  )
}

func shouldCommitNativeFocusSelection(
  nativeFocusAccepted: Bool,
  selectionChanged: Bool
) -> Bool {
  nativeFocusAccepted && selectionChanged
}

func nativeFocusAnimationMonitorID(
  focusedMonitorID: MonitorID?, floating: Bool,
  overviewOpen: Bool, mouseGestureActive: Bool, displayGeometryChanged: Bool
) -> MonitorID? {
  guard !floating, !overviewOpen, !mouseGestureActive, !displayGeometryChanged else { return nil }
  return focusedMonitorID
}

func validatedNativeActivationTimestamp(
  snapshot: DesktopSnapshot,
  resolvedActivation: UserInputTracker.ApplicationActivation?,
  input: UserInputTracker.Snapshot
) -> TimeInterval? {
  guard let resolvedActivation,
    input.applicationActivation == resolvedActivation,
    snapshot.nativeFocusIsApplicationActivation,
    resolvedActivation.processID == snapshot.frontmostProcessID,
    resolvedActivation.timestamp == snapshot.applicationActivationTimestamp
  else { return nil }
  return resolvedActivation.timestamp
}

func activeMonitorIDAfterSnapshot(
  activeMonitorID: MonitorID?,
  acceptedNativeFocusMonitorID: MonitorID?,
  fallbackMonitorID: MonitorID?
) -> MonitorID? {
  acceptedNativeFocusMonitorID ?? activeMonitorID ?? fallbackMonitorID
}

func shouldCloseOverviewAfterNativeFocusChange(
  nativeFocusChanged: Bool,
  overviewOpenedAt: TimeInterval?,
  mouseFocusIntentTimestamp: TimeInterval?,
  keyboardFocusIntentTimestamp: TimeInterval?
) -> Bool {
  guard nativeFocusChanged else { return false }
  guard let overviewOpenedAt else { return true }
  return max(mouseFocusIntentTimestamp ?? 0, keyboardFocusIntentTimestamp ?? 0)
    > overviewOpenedAt
}

func desktopSnapshotWaitsForCommandAnimation(
  animationPending: Bool,
  latestCommandInputTimestamp: TimeInterval,
  latestNativeFocusAnimationInputTimestamp: TimeInterval = 0,
  mouseFocusIntentTimestamp: TimeInterval?,
  keyboardFocusIntentTimestamp: TimeInterval?,
  mouseGestureActive: Bool = false,
  applicationActivationTimestamp: TimeInterval? = nil
) -> Bool {
  guard animationPending, !mouseGestureActive else { return false }
  return max(
    mouseFocusIntentTimestamp ?? 0,
    keyboardFocusIntentTimestamp ?? 0,
    applicationActivationTimestamp ?? 0
  ) <= max(latestCommandInputTimestamp, latestNativeFocusAnimationInputTimestamp)
}

@NavigationActor
extension Daemon {
  func synchronizeDesktop(
    forceFullWindowRefresh: Bool = false,
    forceWindowListRefresh: Bool = false,
    forceApplicationInventoryRefresh: Bool = false,
    targetedWindowRetryRefresh: Bool = false,
    consumePeriodicWindowRefresh: Bool = false
  ) {
    guard windowManagementStarted, desktopSessionActive,
      !shouldShutdown, !restorationInFlight else { return }
    let (forceFullWindowRefresh, forceWindowListRefresh,
      forceApplicationInventoryRefresh, targetedWindowRetryRefresh,
      consumePeriodicWindowRefresh) = coalescedDesktopSnapshotRequest(
        (forceFullWindowRefresh, forceWindowListRefresh,
          forceApplicationInventoryRefresh, targetedWindowRetryRefresh,
          consumePeriodicWindowRefresh),
        pending: supersededDesktopSnapshotRequest
      )
    // Both an in-flight snapshot and display reconciliation can defer this request.
    supersededDesktopSnapshotRequest = (
      forceFullWindowRefresh, forceWindowListRefresh,
      forceApplicationInventoryRefresh, targetedWindowRetryRefresh,
      consumePeriodicWindowRefresh
    )
    let sessionGeneration = desktopSessionGeneration
    let requestedConfigGeneration = configGeneration
    let nativeFocusWasPending = platform.hasPendingNativeFocusEvent
    if desktopSnapshotInFlight {
      return
    }
    if hotKeys?.isEnabled == true, displayReconciliationPending {
      reconcileDisplays()
      return
    }
    supersededDesktopSnapshotRequest = nil
    desktopSnapshotInFlight = true
    platform.beginSnapshot(
      config: config,
      forceFullWindowRefresh: forceFullWindowRefresh,
      forceWindowListRefresh: forceWindowListRefresh,
      forceApplicationInventoryRefresh: forceApplicationInventoryRefresh
    ) { [weak self] snapshot in
      guard let self else { return }
      guard !shouldShutdown, !restorationInFlight, desktopSessionActive,
        desktopSessionGeneration == sessionGeneration,
        configGeneration == requestedConfigGeneration
      else {
        desktopSnapshotInFlight = false
        supersededDesktopSnapshotRequest = nil
        if desktopSessionActive {
          synchronizeDesktop(
            forceFullWindowRefresh: true,
            forceWindowListRefresh: true,
            forceApplicationInventoryRefresh: true
          )
        }
        return
      }
      applyDesktopSnapshot(
        snapshot,
        nativeFocusWasPending: nativeFocusWasPending,
        forceFullWindowRefresh: forceFullWindowRefresh,
        forceWindowListRefresh: forceWindowListRefresh,
        forceApplicationInventoryRefresh: forceApplicationInventoryRefresh,
        targetedWindowRetryRefresh: targetedWindowRetryRefresh,
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
    targetedWindowRetryRefresh: Bool,
    consumePeriodicWindowRefresh: Bool
  ) {
    defer {
      desktopSnapshotInFlight = false
      // Recompute the idle deadline without recursively requesting another snapshot.
      if timerFrequencyHz == 0 { scheduleIdleTick() }
      if let pending = supersededDesktopSnapshotRequest {
        supersededDesktopSnapshotRequest = nil
        synchronizeDesktop(
          forceFullWindowRefresh: pending.forceFullWindowRefresh,
          forceWindowListRefresh: pending.forceWindowListRefresh,
          forceApplicationInventoryRefresh: pending.forceApplicationInventoryRefresh,
          targetedWindowRetryRefresh: pending.targetedWindowRetryRefresh,
          consumePeriodicWindowRefresh: pending.consumePeriodicWindowRefresh
        )
      } else if platform.hasDeferredFreshWindowReads
        || platform.hasChunkedFullRefreshPending
      {
        // Continue when the preceding chunk completes, never by spinning ticks
        // that can only supersede a snapshot still waiting on Accessibility.
        needsDesktopSync = true
        scheduleTick()
      }
    }
    let snapshotCompletedAt = ProcessInfo.processInfo.systemUptime
    if shouldCloseOverviewAfterNativeFocusChange(
      nativeFocusChanged: snapshot.nativeFocusChanged,
      overviewOpenedAt: overviewOpenedAt,
      mouseFocusIntentTimestamp: snapshot.mouseFocusIntentTimestamp,
      keyboardFocusIntentTimestamp: snapshot.keyboardFocusIntentTimestamp
    ) {
      closeOverview()
    }
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
      reset: forceWindowListRefresh || targetedWindowRetryRefresh
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
      focus.queueCommand(nil)
      invalidateSubmittedCommandFocus()
      invalidateSubmittedWorkspaceFocus()
      focus.queueWorkspace(nil)
      focus.cancelSubmittedWorkspace()
      focus.discardDisplacedFocus()
      platform.invalidateFrameStateForDisplayChange()
      platform.invalidateFocusStateForDisplayChange()
      invalidatePointerFocusIntent(recoveringTo: preservedLogicalFocusWindowID)
      rearmPointerFocusTransition()
      scrollAnimations.removeAll(keepingCapacity: true)
      focus.cancelSubmittedWorkspace()
      pendingWindowRemovalFocusGuard = nil
      consumeDeferredMouseFocusIntent()
      finishMouseGestureTracking()
    }
    latestMonitors = snapshot.monitors
    let previousMismatchObservationState =
      displayGeometryChanged
      ? WidthMismatchObservationState()
      : targetMismatchObservationState
    let previousTargetMismatches = Array(
      previousMismatchObservationState.mismatchesByWindowID.values
    )
    targetMismatches = displayGeometryChanged ? [] : snapshot.targetMismatches
    targetMismatchObservationState = updateWidthMismatchObservationState(
      previous: previousMismatchObservationState,
      current: targetMismatches,
      freshObservationIDs: snapshot.freshFrameObservationIDs,
      removedWindowIDs: snapshot.removedWindowIDs.union(
        snapshot.windowIDReplacements.keys
      ),
      now: snapshotCompletedAt
    )
    state.retainMonitors(
      snapshot.monitors.map(\.id),
      previousViewports: previousViewports,
      nextViewports: viewportsByMonitor,
      stableIDs: Dictionary(uniqueKeysWithValues: snapshot.monitors.compactMap { monitor in
        monitor.stableID.map { (monitor.id, $0) }
      })
    )
    if displayGeometryChanged {
      focus.requeuePreservedFocusAfterMonitorRetention(
        command: preservedCommandFocus,
        workspace: preservedWorkspaceFocus,
        displaced: preservedDisplacedFocus,
        state: state
      )
    }
    var nativelyFocusedMonitorID: MonitorID?
    var nativelyActivatedWorkspace = false
    var nativeCursorWarpWindowID: WindowID?
    var nativeCursorWarpInputTimestamp: TimeInterval?
    var nativeFocusFrameMonitorID: MonitorID?
    let previouslyManagedWindowIDs = Set(
      state.windows.keys.map {
        snapshot.windowIDReplacements[$0] ?? $0
      })
    let enteringNativeFullscreenWindowIDs = snapshot.nativeFullscreenWindowIDs
      .subtracting(state.nativeFullscreenWindowIDs)
    platform.updateNativeFullscreenWindowIDs(
      snapshot.nativeFullscreenWindowIDs,
      activeWindowIDs: snapshot.activeNativeFullscreenWindowIDs
    )
    rebindFocusRequests(using: snapshot.windowIDReplacements)
    if pendingAnimatedFocus.map({
      enteringNativeFullscreenWindowIDs.contains($0.windowID)
    }) == true {
      focus.queueCommand(nil)
    }
    if submittedCommandFocus.map({
      enteringNativeFullscreenWindowIDs.contains($0.windowID)
    }) == true {
      invalidateSubmittedCommandFocus()
    }
    let relocatedTransientIDs = reconcileWindows(
      snapshot.windows,
      config: config,
      windowIDReplacements: snapshot.windowIDReplacements,
      externallyChangedWindowIDs: Set(snapshot.externallyChangedFrames.keys),
      nativeFullscreenWindowIDs: snapshot.nativeFullscreenWindowIDs,
      explicitlyRemovedWindowIDs: snapshot.explicitlyDestroyedWindowIDs,
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
    var acceptedNativeFocusMonitorID: MonitorID?
    if let focusedWindowID = snapshot.focusedWindowID {
      let currentActivation = platform.userInputTracker.pendingApplicationActivation(
        frontmostProcessID: platform.frontmostProcessID
      )
      // Revalidate the resolved activation and commands against one coherent input snapshot.
      let liveInput = platform.userInputTracker.snapshot
      let latestFocusIntentTimestamp = max(
        latestCommandInputTimestamp,
        liveInput.latestCapturedCommandTimestamp
      )
      let keyboardFocusIntentCurrent = keyboardFocusIntentIsCurrent(
        keyboardFocusIntentTimestamp: snapshot.keyboardFocusIntentTimestamp,
        latestCommandInputTimestamp: latestFocusIntentTimestamp
      )
      let mouseReleaseFocusIntentCurrent = mouseReleaseFocusIntentIsCurrent(
        focusedWindowID: focusedWindowID,
        mouseFocusIntentWindowID: deferredMouseFocusIntent?.windowID,
        mouseFocusIntentTimestamp: deferredMouseFocusIntent?.timestamp,
        latestCommandInputTimestamp: latestFocusIntentTimestamp,
        nativeFocusChanged: deferredMouseFocusIntent?.focusObserved == true
      )
      let deferredMouseFocusPending = deferredMouseFocusIntent != nil
      let deferredMouseFocusReady =
        deferredMouseFocusIntent?.mouseInteractionEnded == true
        && (deferredMouseFocusIntent?.focusObserved == true
          || deferredMouseFocusIntent?.windowID == focusedWindowID)
      let activationTimestamp = validatedNativeActivationTimestamp(
        snapshot: snapshot,
        resolvedActivation: currentActivation,
        input: liveInput
      )
      let latestUserInputTimestamp = liveInput.latestEventTimestamp
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
            ProcessInfo.processInfo.systemUptime < suppressNativeFocusUntil,
          applicationActivationTimestamp: activationTimestamp,
          latestCommandInputTimestamp: latestFocusIntentTimestamp
        )
        && !preservesWorkspaceAfterRemoval
      let selectionChanged = nativeFocusChangesSelection(
        focusedWindowID,
        activeMonitorID: activeMonitorID,
        state: state
      )
      if snapshot.nativeFocusChanged && selectionChanged {
        platform.recordPerformanceTrace(
          "native-focus target=\(focusedWindowID.rawValue) activation=\(snapshot.nativeFocusIsApplicationActivation) activationTS=\(activationTimestamp.map { String($0) } ?? "none") accepted=\(nativeFocusAccepted) inputTS=\(latestUserInputTimestamp) commandTS=\(latestCommandInputTimestamp) mouseDown=\(snapshot.leftMouseButtonDown) mouseIntent=\(mouseReleaseFocusIntentCurrent) keyboardIntent=\(keyboardFocusIntentCurrent)"
        )
      }
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
        if let activationTimestamp, let processID = snapshot.frontmostProcessID {
          platform.userInputTracker.consumeApplicationActivation(
            processID: processID, at: activationTimestamp
          )
        }
        focus.interrupt()
        nativeFocusFrameMonitorID = state.monitorID(containing: focusedWindowID)
        if let keyboardFocusIntentTimestamp = snapshot.keyboardFocusIntentTimestamp {
          platform.userInputTracker.consumeFocusIntent(
            at: keyboardFocusIntentTimestamp
          )
        }
        platform.invalidateFocusRecovery(recoveringTo: focusedWindowID)
        invalidateSubmittedCommandFocus(recoveringTo: focusedWindowID)
        invalidateSubmittedWorkspaceFocus(recoveringTo: focusedWindowID)
        cancelSubmittedPointerFocus(recoveringTo: focusedWindowID)
        rearmPointerFocusTransition()
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
        && shouldCommitNativeFocusSelection(
          nativeFocusAccepted: nativeFocusAccepted,
          selectionChanged: selectionChanged
        )
      {
        let activatedWorkspace = focusWindow(focusedWindowID, state: &state)
        nativelyActivatedWorkspace = nativeFocusAccepted && activatedWorkspace
        acceptedNativeFocusMonitorID = state.monitorID(containing: focusedWindowID)
        nativelyFocusedMonitorID = acceptedNativeFocusMonitorID
        if mouseInteractionEnded {
          platform.recordPerformanceTrace(
            "mouse-focus-committed window=\(focusedWindowID.rawValue)"
          )
        }
      } else if nativeFocusAccepted {
        ignoredRedundantNativeFocusCount += 1
      }
      if nativeFocusAccepted && deferredMouseFocusReady {
        if focusedWindowID != snapshot.mouseFocusIntentWindowID,
          let timestamp = deferredMouseFocusIntent?.timestamp
        {
          platform.userInputTracker.consumeFocusIntent(at: timestamp)
        }
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
    activeMonitorID = activeMonitorIDAfterSnapshot(
      activeMonitorID: activeMonitorID,
      acceptedNativeFocusMonitorID: acceptedNativeFocusMonitorID,
      fallbackMonitorID: state.monitors.first?.id
    )

    var mouseReordered = false
    if !displayGeometryChanged && mouseResizeGestureActive {
      let physicalMonitorFrames = Dictionary(uniqueKeysWithValues: latestMonitors.map {
        ($0.id, $0.physicalFrame)
      })
      let mouseGestureCandidateWindowIDs = [
        activelyResizedWindowID,
        snapshot.mouseFocusIntentWindowID,
        snapshot.focusedWindowID,
      ].compactMap { $0 }
      let translatedWindowID = mouseTranslatedTiledWindowID(
        candidateWindowIDs: mouseGestureCandidateWindowIDs,
        externallyChangedFrames: snapshot.externallyChangedFrames,
        state: state,
        viewports: viewportsByMonitor,
        monitorFrames: physicalMonitorFrames
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
          reorderTiledWindowAfterCompletedMouseDrag(
            gestureWindowID,
            actualFrame: actualFrame,
            initialFrame: mouseGestureInitialFrame,
            state: &state,
            viewports: viewportsByMonitor,
            monitorFrames: physicalMonitorFrames
          )
        {
          mouseReordered = true
          if let destination = state.monitorID(containing: gestureWindowID),
            destination != mouseGestureScrollAnchor?.monitorID
          {
            mouseGestureScrollAnchor = nil
            activeMonitorID = destination
            nativelyFocusedMonitorID = destination
            if nativeFocusFrameMonitorID != nil { nativeFocusFrameMonitorID = destination }
          }
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
      learnPersistentWidthConstraints(
        targetMismatches,
        previous: previousTargetMismatches,
        observedSince: targetMismatchObservationState.observedSince,
        now: snapshotCompletedAt
      )
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
    if tracesWindowCreation {
      platform.recordPerformanceTrace("sync-before-layout")
    }
    let animatesMouseReorder =
      mouseReordered
      && snapshot.leftMouseButtonDown
      && animationsEnabled
      && config.animation.durationMS > 0
    let nativeAnimationMonitorID = nativeFocusAnimationMonitorID(
      focusedMonitorID: nativelyFocusedMonitorID,
      floating: focusedWindowIDForAlignment.flatMap { state.windows[$0]?.floating } == true,
      overviewOpen: overviewState.isOpen,
      mouseGestureActive: mouseResizeGestureActive,
      displayGeometryChanged: displayGeometryChanged
    )
    let nativeFocusRequiresMovement = nativeAnimationMonitorID.flatMap { id in
      state.monitors.first { $0.id == id }
    }.flatMap { monitor in
      monitor.workspaces.first { $0.id == monitor.activeWorkspace }
    }.map { abs($0.scrollOffset - $0.targetScrollOffset) >= 0.000_1 } == true
    let animatesNativeFocus = nativeAnimationMonitorID != nil
      && (nativeFocusRequiresMovement || nativelyActivatedWorkspace)
      && animationsEnabled && config.animation.durationMS > 0
    let animatesFocusOrReorder = animatesNativeFocus || animatesMouseReorder
    snapScrollOffsetsToTargets()
    if animatesMouseReorder { mouseReorderAnimationActive = true }
    if animatesFocusOrReorder { beginFrameAnimationActivity() }
    let nativeFocusSkippedWindowIDs: Set<WindowID>
    if nativeFocusWasPending {
      if let nativeFocusFrameMonitorID {
        let locations = state.windowLocationMap()
        nativeFocusSkippedWindowIDs = Set(
          state.windows.keys.filter {
            locations[$0]?.monitorID != nativeFocusFrameMonitorID
          }
        )
      } else {
        nativeFocusSkippedWindowIDs = Set(state.windows.keys)
      }
    } else {
      nativeFocusSkippedWindowIDs = []
    }
    let nativeCursorWarpIsCurrentAfterCommit: (@NavigationActor @Sendable () -> Bool)?
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
    if !animatesNativeFocus, desktopSnapshotWaitsForCommandAnimation(
      animationPending: platform.hasPendingAnimatedFrameWrites,
      latestCommandInputTimestamp: latestCommandInputTimestamp,
      latestNativeFocusAnimationInputTimestamp: latestNativeFocusAnimationInputTimestamp,
      mouseFocusIntentTimestamp: snapshot.mouseFocusIntentTimestamp,
      keyboardFocusIntentTimestamp: snapshot.keyboardFocusIntentTimestamp,
      mouseGestureActive: mouseResizeGestureActive,
      applicationActivationTimestamp: nativeFocusFrameMonitorID != nil
        ? snapshot.applicationActivationTimestamp : nil
    ) {
      needsDesktopSync = true
    } else {
      if animatesNativeFocus {
        latestNativeFocusAnimationInputTimestamp = max(
          snapshot.latestUserInputTimestamp,
          snapshot.mouseFocusIntentTimestamp ?? 0,
          snapshot.keyboardFocusIntentTimestamp ?? 0,
          snapshot.applicationActivationTimestamp ?? 0
        )
      }
      applyCurrentLayout(
        monitorIDs: animatesNativeFocus ? nativeAnimationMonitorID.map { [$0] } : nil,
        asynchronousPositions: true,
        updateVisibility: true,
        positionTimeoutSeconds: 0.05,
        animationDuration: animatesFocusOrReorder
          ? TimeInterval(config.animation.durationMS) / 1_000
          : 0,
        skipping: nativeFocusSkippedWindowIDs,
        positionsOnly: animatesMouseReorder || (animatesNativeFocus && !nativelyActivatedWorkspace),
        stagesVisibleBeforeParking: nativelyActivatedWorkspace,
        cursorWarpWindowIDAfterCommit: nativeCursorWarpWindowID,
        cursorWarpInputTimestampAfterCommit: nativeCursorWarpInputTimestamp,
        cursorWarpIsCurrentAfterCommit:
          nativeCursorWarpIsCurrentAfterCommit,
        forceFloatingFrameWrites: displayGeometryChanged,
        forcingFloatingFrameWritesFor: relocatedFloatingWindowIDs,
        source: animatesNativeFocus
          ? "native-focus-animation"
          : (nativelyActivatedWorkspace ? "native-workspace"
            : (animatesMouseReorder ? "mouse-reorder-animation" : "desktop-sync"))
      )
    }
    if let guardedRemovalFocus {
      platform.focus(
        guardedRemovalFocus.windowID,
        unlessUserInputAfter: guardedRemovalFocus.inputTimestamp
      )
    }
    persistTopology()
    updateMenuBar()
    updateOverviewIfOpen()
    if !snapshot.leftMouseButtonDown && mouseGestureSettlement == nil {
      mouseGestureScrollAnchor = nil
    }
  }

}
