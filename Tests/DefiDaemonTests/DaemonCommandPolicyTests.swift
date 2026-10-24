import DefiConfig
import DefiCore
import DefiMacOS
import DefiModel
import DefiRuntime
import Testing

@testable import DefiDaemon

struct DaemonCommandPolicyTests {
  @Test func pendingNativeFocusDoesNotHoldBackNewlyAdmittedWindows() {
    let main = MonitorID(rawValue: 1), side = MonitorID(rawValue: 2)
    let old = WindowID(rawValue: 1), new = WindowID(rawValue: 2)
    let other = WindowID(rawValue: 3), floating = WindowID(rawValue: 4)
    let windows: [WindowID: MonitorID?] = [old: main, new: main, other: side, floating: nil]
    let managed: Set<WindowID> = [old, other, floating]
    #expect(nativeFocusPendingSkippedWindowIDs(
      nativeFocusWasPending: false, focusMonitorID: nil,
      windowMonitorIDs: windows, previouslyManagedWindowIDs: managed).isEmpty)
    #expect(nativeFocusPendingSkippedWindowIDs(
      nativeFocusWasPending: true, focusMonitorID: nil,
      windowMonitorIDs: windows, previouslyManagedWindowIDs: managed) == [old, other, floating])
    #expect(nativeFocusPendingSkippedWindowIDs(
      nativeFocusWasPending: true, focusMonitorID: main,
      windowMonitorIDs: windows, previouslyManagedWindowIDs: managed) == [other, floating])
  }

  @Test func completedOverviewSelectionAllowsWarpUntilSuperseded() {
    let state = OverviewToggleState()
    state.recordControllerState(true, sessionGeneration: 1)
    state.completeSelectionExit(1)
    state.recordControllerState(false, sessionGeneration: 2)
    #expect(state.selectionWarpIsCurrent(1))
    state.recordControllerState(true, sessionGeneration: 3)
    #expect(!state.selectionWarpIsCurrent(1))
    _ = state.requestClose()
    state.completeSelectionExit(3)
    state.recordControllerState(false, sessionGeneration: 4)
    #expect(!state.selectionWarpIsCurrent(3), "Cancellation cannot authorize a delayed warp")
  }

  @Test func overviewSessionCancellationInvalidatesAlreadyQueuedSelection() {
    let state = OverviewToggleState()
    state.recordControllerState(true, sessionGeneration: 1)
    #expect(state.isCurrentSession(1))
    _ = state.requestClose()
    #expect(!state.isCurrentSession(1), "Cancellation must take effect before actor work resumes")
    state.recordControllerState(false, sessionGeneration: 2)
    state.recordControllerState(true, sessionGeneration: 3)
    #expect(!state.isCurrentSession(1), "Reopening cannot revive an older selection")
    #expect(state.isCurrentSession(3))
  }

  // floating, overview open, mouse gesture, display geometry changed, activated workspace
  @Test(arguments: [(false, false, false, false, false), (true, false, false, false, false),
    (false, true, false, false, false), (false, false, true, false, false), (false, false, false, true, false),
    (false, false, false, false, true)])
  func changedNativeFocusAnimatesOnlyItsMonitorOutsideOtherInteractions(floating: Bool, overviewOpen: Bool,
    mouseGesture: Bool, displayChanged: Bool, activatedWorkspace: Bool) {
    let monitor = MonitorID(rawValue: 2)
    let blocked = floating || overviewOpen || mouseGesture || displayChanged || activatedWorkspace
    #expect(nativeFocusAnimationMonitorID(focusedMonitorID: monitor, floating: floating,
      activatedWorkspace: activatedWorkspace, overviewOpen: overviewOpen, mouseGestureActive: mouseGesture,
      displayGeometryChanged: displayChanged) == (blocked ? nil : monitor))
    #expect(nativeFocusAnimationMonitorID(focusedMonitorID: nil, floating: floating,
      activatedWorkspace: activatedWorkspace, overviewOpen: overviewOpen, mouseGestureActive: mouseGesture,
      displayGeometryChanged: displayChanged) == nil)
  }

  @Test
  func supersededSubmittedWorkspaceFocusRequiresNativeCancellation() {
    #expect(workspaceFocusNeedsNativeCancellation(
      requestGeneration: 10,
      submittedGeneration: 10,
      currentGeneration: 11
    ))
    #expect(!workspaceFocusNeedsNativeCancellation(
      requestGeneration: 10,
      submittedGeneration: nil,
      currentGeneration: 11
    ))
    #expect(!workspaceFocusNeedsNativeCancellation(
      requestGeneration: 10,
      submittedGeneration: 10,
      currentGeneration: 10
    ))
  }

  @Test
  func noOpRefreshesFocusInputWithoutChangingTheIntent() {
    let monitor = MonitorID(rawValue: 1)
    let sourceWorkspace = WorkspaceID(rawValue: "source")
    let targetWorkspace = WorkspaceID(rawValue: "target")
    let previousWindow = WindowID(rawValue: 1)
    let targetWindow = WindowID(rawValue: 2)
    let command = PendingAnimatedFocus(
      windowID: targetWindow,
      previousSelectedWindowID: previousWindow,
      monitorID: monitor,
      sourceWorkspaceID: sourceWorkspace,
      commandGeneration: 8,
      focusInputTimestamp: 10,
      cursorWarpInputTimestamp: 9,
      retryCount: 1
    )
    let workspace = PendingWorkspaceFocus(
      monitorID: monitor,
      requestedWorkspaceID: targetWorkspace,
      previousWorkspaceID: sourceWorkspace,
      requestedWindowID: targetWindow,
      restoresPreviousWorkspaceOnCancellation: true,
      commandGeneration: 8,
      focusInputTimestamp: 10,
      cursorWarpInputTimestamp: 9,
      retryCount: 1
    )

    let refreshedCommand = commandFocusAfterNoOp(command, inputTimestamp: 11)
    #expect(refreshedCommand.windowID == command.windowID)
    #expect(refreshedCommand.previousSelectedWindowID == command.previousSelectedWindowID)
    #expect(refreshedCommand.commandGeneration == command.commandGeneration)
    #expect(refreshedCommand.focusInputTimestamp == 11)
    #expect(refreshedCommand.cursorWarpInputTimestamp == command.cursorWarpInputTimestamp)
    #expect(refreshedCommand.retryCount == command.retryCount)

    let refreshedWorkspace = workspaceFocusAfterNoOp(workspace, inputTimestamp: 11)
    #expect(refreshedWorkspace.requestedWorkspaceID == workspace.requestedWorkspaceID)
    #expect(refreshedWorkspace.requestedWindowID == workspace.requestedWindowID)
    #expect(refreshedWorkspace.commandGeneration == workspace.commandGeneration)
    #expect(refreshedWorkspace.focusInputTimestamp == 11)
    #expect(refreshedWorkspace.restoresPreviousWorkspaceOnCancellation)
    #expect(refreshedWorkspace.retryCount == workspace.retryCount)
    #expect(focusInputNeedsRefresh(requestTimestamp: 10, newInputTimestamp: 11))
    #expect(!focusInputNeedsRefresh(requestTimestamp: 10, newInputTimestamp: 10))
    #expect(!focusInputNeedsRefresh(requestTimestamp: 10, newInputTimestamp: 9))
  }

  @Test
  func overviewToggleGateUsesActualAndPendingState() {
    let toggleState = OverviewToggleState()
    #expect(toggleState.snapshot() == OverviewToggleSnapshot(
      generation: 0,
      actualIsOpen: false,
      sessionGeneration: nil,
      desiredIsOpen: nil
    ))

    let openRequest = toggleState.toggle()
    #expect(openRequest.isOpen)
    #expect(toggleState.beginApplying(openRequest))
    toggleState.recordControllerState(true)
    toggleState.finishApplying(openRequest, actualIsOpen: true)

    #expect(!toggleState.toggle().isOpen)
  }

  @Test
  func overviewToggleGenerationRejectsOldProjectionAndEscapeCancelsPendingAck() {
    let toggleState = OverviewToggleState()
    let opening = toggleState.toggle()
    let closing = toggleState.toggle()
    #expect(opening.isOpen && !closing.isOpen)
    #expect(!toggleState.beginApplying(opening))
    #expect(toggleState.beginApplying(closing))
    toggleState.recordControllerState(false)
    toggleState.finishApplying(closing, actualIsOpen: false)
    #expect(toggleState.snapshot().actualIsOpen == false)
    #expect(toggleState.snapshot().desiredIsOpen == nil)

    let openingAgain = toggleState.toggle()
    #expect(openingAgain.isOpen)
    #expect(toggleState.beginApplying(openingAgain))
    toggleState.recordControllerState(true)
    toggleState.finishApplying(openingAgain, actualIsOpen: true)

    let inFlightClose = toggleState.toggle()
    #expect(!inFlightClose.isOpen)
    #expect(toggleState.beginApplying(inFlightClose))
    let latestOpen = toggleState.toggle()
    #expect(latestOpen.isOpen, "a pending close should be reversible by a newer toggle")
    toggleState.recordControllerState(false)
    toggleState.finishApplying(inFlightClose, actualIsOpen: false)
    #expect(toggleState.snapshot().desiredIsOpen == true)
    #expect(toggleState.beginApplying(latestOpen))
    toggleState.recordControllerState(true)
    toggleState.finishApplying(latestOpen, actualIsOpen: true)
    #expect(toggleState.snapshot().desiredIsOpen == nil)

    let pendingClose = toggleState.toggle()
    #expect(!pendingClose.isOpen)
    toggleState.recordControllerState(false)
    #expect(!toggleState.isCurrent(pendingClose))
    #expect(toggleState.snapshot().actualIsOpen == false)
    #expect(toggleState.snapshot().desiredIsOpen == nil)
  }

  @Test
  func rejectedOpenReconcilesToActualClosedState() {
    let toggleState = OverviewToggleState()
    let request = toggleState.toggle()
    #expect(toggleState.beginApplying(request))
    // The controller can reject an open, for example while asking for Screen Recording.
    toggleState.finishApplying(request, actualIsOpen: false)
    #expect(toggleState.snapshot().actualIsOpen == false)
    #expect(toggleState.snapshot().desiredIsOpen == nil)
  }

  @Test
  func asynchronousSizeClampIsAcceptedAfterRepeatedObservation() {
    let windowID = WindowID(rawValue: 1)
    let target = Rect(x: 2, y: 34, width: 1_122, height: 1_353)
    // Simulator's Device Hub snaps its size after the write readback, and may move.
    let snapped = FrameMismatch(
      windowID: windowID, actual: Rect(x: 340, y: 34, width: 403, height: 931), target: target
    )
    let resnapped = FrameMismatch(
      windowID: windowID, actual: Rect(x: 2, y: 34, width: 403.5, height: 931), target: target
    )
    let otherSize = FrameMismatch(
      windowID: windowID, actual: Rect(x: 2, y: 34, width: 460, height: 1_064), target: target
    )
    let positionOnly = FrameMismatch(
      windowID: windowID, actual: Rect(x: 40, y: 34, width: 1_122, height: 1_353), target: target
    )
    let retargeted = FrameMismatch(
      windowID: windowID, actual: snapped.actual,
      target: Rect(x: 2, y: 34, width: 1_000, height: 1_353)
    )

    #expect(!settledTiledSizeClamp(snapped, previous: nil))
    #expect(settledTiledSizeClamp(resnapped, previous: snapped))
    #expect(!settledTiledSizeClamp(snapped, previous: otherSize))
    #expect(!settledTiledSizeClamp(positionOnly, previous: positionOnly))
    #expect(!settledTiledSizeClamp(snapped, previous: retargeted))
    let acceptance = TiledSizeAcceptance(requested: target, accepted: snapped.actual)
    #expect(tiledSizeAcceptanceCoversTarget(acceptance, target: target))
    #expect(!tiledSizeAcceptanceCoversTarget(acceptance, target: retargeted.target))
    #expect(!tiledSizeAcceptanceCoversTarget(nil, target: target))
  }

  @Test
  func userHeldGestureWidthDoesNotAgeIntoConstraint() {
    let windowID = WindowID(rawValue: 1)
    let held = FrameMismatch(
      windowID: windowID,
      actual: Rect(x: 2, y: 34, width: 1_202, height: 1_353),
      target: Rect(x: 2, y: 34, width: 2_554, height: 1_353)
    )
    var duringGesture = updateWidthMismatchObservationState(
      previous: WidthMismatchObservationState(),
      current: [held],
      freshObservationIDs: [windowID],
      now: 10
    )
    duringGesture.forget(windowID)
    let afterRelease = updateWidthMismatchObservationState(
      previous: duringGesture,
      current: [held],
      freshObservationIDs: [windowID],
      now: 11
    )

    #expect(afterRelease.observedSince[windowID] == 11)
    #expect(!persistentWidthMismatch(
      held,
      previous: duringGesture.mismatchesByWindowID[windowID],
      observedSince: afterRelease.observedSince[windowID],
      now: 11
    ))
  }

  @Test
  func widthConstraintRequiresRepeatedSettledMismatch() {
    let windowID = WindowID(rawValue: 1)
    let target = Rect(x: 2, y: 34, width: 2_554, height: 1_353)
    let source = FrameMismatch(
      windowID: windowID,
      actual: Rect(x: 1_354, y: 34, width: 1_202, height: 1_353),
      target: target
    )
    let clamped = FrameMismatch(
      windowID: windowID,
      actual: Rect(x: 2, y: 34, width: 1_202, height: 1_353),
      target: target
    )
    let heightOnly = FrameMismatch(
      windowID: windowID,
      actual: Rect(x: 2, y: 34, width: target.width, height: 1_200),
      target: target
    )

    #expect(!settledWidthMismatch(clamped, previous: nil))
    #expect(!settledWidthMismatch(clamped, previous: source))
    #expect(settledWidthMismatch(clamped, previous: clamped))
    #expect(!settledWidthMismatch(source, previous: source))
    #expect(!settledWidthMismatch(heightOnly, previous: heightOnly))

    let changedWidth = FrameMismatch(
      windowID: windowID,
      actual: Rect(x: 2, y: 34, width: 1_204, height: 1_353),
      target: target
    )
    let changedTarget = FrameMismatch(
      windowID: windowID,
      actual: Rect(x: 2, y: 34, width: 1_202, height: 1_353),
      target: Rect(x: 2, y: 34, width: 2_552, height: 1_353)
    )
    #expect(!settledWidthMismatch(clamped, previous: changedWidth))
    #expect(!settledWidthMismatch(clamped, previous: changedTarget))

    let heightOnlyObservation = updateWidthMismatchObservationState(
      previous: WidthMismatchObservationState(),
      current: [heightOnly],
      freshObservationIDs: [windowID],
      now: 9
    )
    #expect(heightOnlyObservation.observedSince[windowID] == nil)
    let subpointWidthMismatch = FrameMismatch(
      windowID: windowID,
      actual: Rect(x: 2, y: 34, width: target.width - 1, height: 1_200),
      target: target
    )
    let subpointWidthObservation = updateWidthMismatchObservationState(
      previous: heightOnlyObservation,
      current: [subpointWidthMismatch],
      freshObservationIDs: [windowID],
      now: 9.1
    )
    #expect(subpointWidthObservation.observedSince[windowID] == nil)
    let gradualWidthMismatch = FrameMismatch(
      windowID: windowID,
      actual: Rect(x: 2, y: 34, width: target.width - 2, height: 1_200),
      target: target
    )
    let firstWidthMismatch = updateWidthMismatchObservationState(
      previous: subpointWidthObservation,
      current: [gradualWidthMismatch],
      freshObservationIDs: [windowID],
      now: 9.2
    )
    #expect(firstWidthMismatch.observedSince[windowID] == 9.2)

    let movingObservation = updateWidthMismatchObservationState(
      previous: WidthMismatchObservationState(),
      current: [source],
      freshObservationIDs: [windowID],
      now: 10
    )
    #expect(movingObservation.observedSince.isEmpty)

    let firstObservation = updateWidthMismatchObservationState(
      previous: WidthMismatchObservationState(),
      current: [clamped],
      freshObservationIDs: [windowID],
      now: 10
    )
    #expect(firstObservation.observedSince[windowID] == 10)
    let onePixelDrift = FrameMismatch(
      windowID: windowID,
      actual: Rect(x: 2, y: 34, width: 1_203, height: 1_353),
      target: target
    )
    let onePixelDriftObservation = updateWidthMismatchObservationState(
      previous: firstObservation,
      current: [onePixelDrift],
      freshObservationIDs: [windowID],
      now: 10.1
    )
    #expect(onePixelDriftObservation.observedSince[windowID] == 10)
    let twoPixelDriftObservation = updateWidthMismatchObservationState(
      previous: onePixelDriftObservation,
      current: [changedWidth],
      freshObservationIDs: [windowID],
      now: 10.2
    )
    #expect(twoPixelDriftObservation.observedSince[windowID] == 10.2)
    #expect(!persistentWidthMismatch(
      changedWidth,
      previous: onePixelDriftObservation.mismatchesByWindowID[windowID],
      observedSince: twoPixelDriftObservation.observedSince[windowID],
      now: 10.7
    ))

    let cachedObservation = updateWidthMismatchObservationState(
      previous: firstObservation,
      current: [],
      freshObservationIDs: [],
      now: 10.3
    )
    #expect(cachedObservation.mismatchesByWindowID[windowID] == clamped)
    #expect(cachedObservation.observedSince[windowID] == 10)
    #expect(!persistentWidthMismatch(
      clamped,
      previous: cachedObservation.mismatchesByWindowID[windowID],
      observedSince: cachedObservation.observedSince[windowID],
      now: 10.4
    ))

    let repeatedObservation = updateWidthMismatchObservationState(
      previous: cachedObservation,
      current: [clamped],
      freshObservationIDs: [windowID],
      now: 10.5
    )
    #expect(repeatedObservation.observedSince[windowID] == 10)
    #expect(persistentWidthMismatch(
      clamped,
      previous: cachedObservation.mismatchesByWindowID[windowID],
      observedSince: repeatedObservation.observedSince[windowID],
      now: 10.5
    ))

    let changedObservation = updateWidthMismatchObservationState(
      previous: repeatedObservation,
      current: [changedWidth],
      freshObservationIDs: [windowID],
      now: 10.6
    )
    #expect(changedObservation.observedSince[windowID] == 10.6)

    let clearedObservations = updateWidthMismatchObservationState(
      previous: changedObservation,
      current: [],
      freshObservationIDs: [windowID],
      now: 10.7
    )
    #expect(clearedObservations.mismatchesByWindowID.isEmpty)
    #expect(clearedObservations.observedSince.isEmpty)
  }

  @Test @NavigationActor
  func deferredIPCReplyReportsExecutionOrCancellation() {
    let executed = DeferredCommandReply()
    executed.deferResponse()
    executed.perform { .failure("invalid workspace") }
    #expect(executed.wasDeferred)
    #expect(executed.wait() == .failure("invalid workspace"))

    let cancelled = DeferredCommandReply()
    cancelled.deferResponse()
    cancelled.fail("desktop session inactive")
    var ran = false
    cancelled.perform { ran = true; return .success() }
    #expect(!ran)
    #expect(cancelled.wait() == .failure("desktop session inactive"))

    let timedOut = DeferredCommandReply()
    timedOut.deferResponse()
    #expect(!timedOut.wait(timeout: .now()).ok)
    timedOut.perform { ran = true; return .success() }
    #expect(!ran)

    let inFlight = DeferredCommandReply()
    inFlight.deferResponse()
    inFlight.perform {
      inFlight.fail("window geometry read timed out; command was not applied")
      return .success("applied")
    }
    #expect(inFlight.wait() == .success("applied"))
  }

  @Test
  func deferredSnapshotPreservesRefreshesAcrossOrdinaryAndForcedRequests() {
    let reload: DesktopSnapshotRequest = (true, true, true, false, false)
    let periodic: DesktopSnapshotRequest = (false, false, false, false, true)
    let pending = coalescedDesktopSnapshotRequest(periodic, pending: reload)
    let replay = coalescedDesktopSnapshotRequest((false, false, false, false, false), pending: pending)
    #expect(replay.forceFullWindowRefresh)
    #expect(replay.forceWindowListRefresh)
    #expect(replay.forceApplicationInventoryRefresh)
    #expect(!replay.targetedWindowRetryRefresh)
    #expect(replay.consumePeriodicWindowRefresh)
    let targeted = coalescedDesktopSnapshotRequest(
      (false, false, false, true, false), pending: periodic
    )
    #expect(targeted.targetedWindowRetryRefresh)
    let replayedTargeted = coalescedDesktopSnapshotRequest(
      (false, false, false, false, false), pending: targeted
    )
    #expect(replayedTargeted.targetedWindowRetryRefresh)
    let ordinary = coalescedDesktopSnapshotRequest((false, false, false, false, false), pending: nil)
    #expect(!ordinary.forceFullWindowRefresh && !ordinary.forceWindowListRefresh
      && !ordinary.forceApplicationInventoryRefresh && !ordinary.targetedWindowRetryRefresh
      && !ordinary.consumePeriodicWindowRefresh)
  }

  @Test(arguments: [0.0, -700.0])
  func shutdownUsesObservedDisplayOriginsForTiledAndFloatingWindows(restoredY: Double) {
    let monitorID = MonitorID(rawValue: 1), workspaceID = WorkspaceID(rawValue: "dev")
    let tiled = WindowID(rawValue: 1), floating = WindowID(rawValue: 2)
    var state = RuntimeState(config: Config(layout: LayoutConfig(gaps: 0)))
    state.monitors = [Monitor(id: monitorID, workspaces: [Workspace(
      id: workspaceID, columns: [Column(window: tiled, width: .fraction(0.8))],
      floatingWindows: [floating], scrollOffset: 0.6
    )], activeWorkspace: workspaceID)]
    let floatingFrame = Rect(x: 1_400, y: -570, width: 200, height: 200)
    let assignments = windowRestorationAssignments(
      state: state,
      monitors: [MonitorSnapshot(
        id: monitorID, frame: Rect(x: 1_000, y: -670, width: 1_000, height: 650),
        physicalFrame: Rect(x: 1_000, y: -700, width: 1_000, height: 700)
      )],
      restoredDisplayFrames: [monitorID: Rect(x: 1_000, y: restoredY, width: 1_000, height: 700)],
      floatingFrames: [floating: floatingFrame]
    )
    #expect(assignments.first { $0.windowID == tiled }?.frame
      == Rect(x: 1_004, y: restoredY + 34, width: 792, height: 642))
    #expect(assignments.first { $0.windowID == floating }?.frame
      == Rect(x: 1_400, y: restoredY + 130, width: 200, height: 200))
    #expect(state.monitors[0].workspaces[0].scrollOffset == 0.6)
  }

  @Test(arguments: [false, true])
  func nativeActivationIsRevalidatedAfterLookup(closeIntent: Bool) throws {
    let tracker = UserInputTracker()
    tracker.recordApplicationActivation(processID: 20, at: 10)
    let resolvedActivation = try #require(tracker.pendingApplicationActivation(
      frontmostProcessID: 20, at: 10.1
    ))
    let snapshot = DesktopSnapshot(
      monitors: [], windows: [], focusedWindowID: WindowID(rawValue: 1),
      nativeFocusChanged: true,
      nativeFocusIsApplicationActivation: true,
      applicationActivationTimestamp: 10,
      frontmostProcessID: 20
    )
    tracker.record(timestamp: 10.2) // Ordinary input preserves the activation.
    #expect(validatedNativeActivationTimestamp(
      snapshot: snapshot, resolvedActivation: resolvedActivation, input: tracker.snapshot
    ) == 10)

    tracker.record(
      timestamp: 11,
      focusIntent: closeIntent ? nil : .keyboard,
      closeIntent: closeIntent
    )
    #expect(validatedNativeActivationTimestamp(
      snapshot: snapshot, resolvedActivation: resolvedActivation, input: tracker.snapshot
    ) == nil)
  }

  @Test(arguments: [nil, 10.0] as [Double?])
  func staleNativeFocusChangesNeitherSelectionNorMonitorRouting(activationTimestamp: Double?) {
    let nativeFocusAccepted = nativeFocusMutationIsReady(nativeFocusChanged: true, mouseInteractionEnded: false,
      leftMouseButtonDown: false, mouseReleaseFocusIntentCurrent: false, keyboardFocusIntentCurrent: false,
      applicationActivationTimestamp: activationTimestamp, latestCommandInputTimestamp: 11)
    #expect(!shouldCommitNativeFocusSelection(nativeFocusAccepted: nativeFocusAccepted, selectionChanged: true))
    #expect(shouldCommitNativeFocusSelection(nativeFocusAccepted: true, selectionChanged: true))
    #expect(!shouldCommitNativeFocusSelection(nativeFocusAccepted: true, selectionChanged: false))
    let first = MonitorID(rawValue: 1), stale = MonitorID(rawValue: 2)
    let accepted = shouldCommitNativeFocusSelection(nativeFocusAccepted: nativeFocusAccepted, selectionChanged: true)
      ? stale : nil
    #expect(activeMonitorIDAfterSnapshot(activeMonitorID: nil, acceptedNativeFocusMonitorID: accepted,
      fallbackMonitorID: first) == first)
    #expect(activeMonitorIDAfterSnapshot(activeMonitorID: nil, acceptedNativeFocusMonitorID: stale,
      fallbackMonitorID: first) == stale)
  }

  @Test
  func inactiveDesktopNeverArmsRecurringTimer() {
    #expect(desktopTimerFrequency(requested: 240, sessionActive: false) == 0)
    #expect(desktopTimerFrequency(requested: 2, sessionActive: true) == 2)
  }

  @Test
  func stalledRepairsBackOffWhileFocusRemainsResponsive() {
    let stalled = followUpTimerFrequency(backoffSteps: 2, unchangedDuration: 3, focusPending: false)
    #expect(stalled < followUpTimerFrequency(backoffSteps: 0, unchangedDuration: 0, focusPending: false))
    #expect(stalled < followUpTimerFrequency(backoffSteps: 2, unchangedDuration: 3, focusPending: true))
  }

  @Test
  func idleWatchdogUsesEarliestDeadlineButFallbackAndFinalVerificationReadsStayPrompt() {
    func delay(now: Double, input: Double, _ deadlines: [(Double, Double)]) -> Double {
      idleDesktopRefreshDelay(now: now, latestInputAt: input, deadlinesAndIntervals: deadlines)
    }
    #expect(delay(now: 10, input: 0, [(40, 30), (25, 30)]) == 15)
    #expect(abs(delay(now: 10, input: 9.8, [(9, 30)]) - 0.8) < 1e-9)
    #expect(delay(now: 10, input: 10, [(9, 0.3), (40, 30)]) == 0.3)
    #expect(delay(now: 10, input: 10, [(40, 30), (10.5, 0.1)]) == 0.5)
    #expect(delay(now: 10.6, input: 10.6, [(40, 30), (10.5, 0.1)]) == 0.3)
    #expect(delay(now: 10.6, input: 10.6, [(40, 30), (.infinity, 0.1)]) == 29.4)
  }

  @Test(
    "Close fallback keeps the selected process",
    .bug("https://github.com/qeude/Defi/pull/49#discussion_r3925069182")
  )
  func closeFallbackKeepsSelectedProcess() {
    #expect(
      windowCloseTargetProcessID(
        eventTargetProcessID: nil,
        selectedProcessID: 42
      ) == 42
    )
  }

  @Test
  func closeTopologyRetriesAreLatestWins() {
    #expect(windowCloseRetryIsCurrent(intentTimestamp: 10, latestInputTimestamp: 10, latestCloseIntentTimestamp: 10))
    #expect(!windowCloseRetryIsCurrent(intentTimestamp: 10, latestInputTimestamp: 11, latestCloseIntentTimestamp: 10))
    #expect(!windowCloseRetryIsCurrent(intentTimestamp: 10, latestInputTimestamp: 11, latestCloseIntentTimestamp: 11))
  }

  @Test
  func verticalWorkspaceTransitionRejectsAOverlappingMonitorPath() {
    let owner = Rect(x: 0, y: 0, width: 1_000, height: 800)

    #expect(
      workspaceTransitionPathIsClear(
        ownerFrame: owner,
        otherMonitorFrames: [Rect(x: 1_000, y: 0, width: 1_000, height: 800)]
      )
    )
    #expect(
      !workspaceTransitionPathIsClear(
        ownerFrame: owner,
        otherMonitorFrames: [Rect(x: 0, y: 800, width: 1_000, height: 800)]
      )
    )
  }

  @Test
  func workspaceTransitionIntentUsesTheTargetMonitorOrder() throws {
    let monitorID = MonitorID(rawValue: 1)
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    )
    state.attachMonitor(monitorID)

    let intent = try #require(
      workspaceTransitionIntent(
        targetWorkspaceID: WorkspaceID(rawValue: "web"),
        state: state
      )
    )

    #expect(intent.monitorID == monitorID)
    #expect(intent.outgoingWorkspaceID == WorkspaceID(rawValue: "dev"))
    #expect(intent.incomingWorkspaceID == WorkspaceID(rawValue: "web"))
    #expect(intent.direction == 1)
  }

  @Test
  func overviewIgnoresParkingFocusWithoutNewFocusInput() {
    #expect(
      !shouldCloseOverviewAfterNativeFocusChange(
        nativeFocusChanged: true,
        overviewOpenedAt: 10,
        mouseFocusIntentTimestamp: 9,
        keyboardFocusIntentTimestamp: nil
      )
    )
    #expect(
      shouldCloseOverviewAfterNativeFocusChange(
        nativeFocusChanged: true,
        overviewOpenedAt: 10,
        mouseFocusIntentTimestamp: nil,
        keyboardFocusIntentTimestamp: 11
      )
    )
  }

  @Test
  func localCommandResubmitsMonitorsWithInFlightAnimation() {
    let animatedMonitor = MonitorID(rawValue: 1)
    let commandMonitor = MonitorID(rawValue: 2)

    #expect(
      commandLayoutMonitorIDs(
        affected: [commandMonitor],
        inFlightAnimations: [animatedMonitor]
      ) == [animatedMonitor, commandMonitor]
    )
  }

  @Test
  func inFlightAnimationDoesNotTurnACommandIntoANoOp() {
    #expect(
      !commandValidationIsNoOp(
        hasValidationState: false,
        rebasesPendingFrame: true,
        command: .focusColumn(.left)
      )
    )
    #expect(
      commandValidationIsNoOp(
        hasValidationState: false,
        rebasesPendingFrame: false,
        command: .focusColumn(.left)
      )
    )
  }

  @Test(arguments: [Command.switchWorkspace(WorkspaceID(rawValue: "dev-secondary")),
    .focusWorkspace(.named("dev-secondary"))])
  func alreadyVisibleWorkspaceStillFocusesItsOwningMonitor(command: Command) throws {
    let local = MonitorID(rawValue: 1), remote = MonitorID(rawValue: 2)
    let dev = WorkspaceID(rawValue: "dev"), secondary = WorkspaceID(rawValue: "dev-secondary")
    var state = RuntimeState(config: Config())
    state.monitors = [
      Monitor(id: local, workspaces: [Workspace(id: dev)], activeWorkspace: dev),
      Monitor(id: remote, workspaces: [Workspace(id: secondary)], activeWorkspace: secondary),
    ]
    state.maintainWorkspaceLifecycle()
    let validationState = try changedState(after: command, on: local, from: state)
    #expect(validationState == nil)
    let target = try #require(workspaceTargetID(for: command, on: local, state: state))
    let location = try #require(state.workspaceLocation(for: target))
    let destination = state.monitors[location.monitorIndex].id
    #expect(destination == remote)
    for (activeMonitor, nativeFocus) in [(local, nil), (remote, nil), (remote, true), (remote, false)] as [(MonitorID, Bool?)] {
      #expect(commandValidationIsNoOp(
        hasValidationState: validationState != nil,
        rebasesPendingFrame: false,
        command: command,
        workspaceFocusMonitorID: destination,
        activeMonitorID: activeMonitor,
        selectedWindowIsNativelyFocused: nativeFocus
      ) == (activeMonitor == remote && nativeFocus != false))
    }
  }

  @Test(arguments: [false, true])
  func impossibleWorkspaceMonitorMoveDoesNotStealFocus(trailing: Bool) throws {
    let local = MonitorID(rawValue: 1), remote = MonitorID(rawValue: 2)
    var state = RuntimeState(config: Config(workspaces: WorkspacesConfig(names: ["dev"])))
    state.attachMonitor(local)
    state.attachMonitor(remote)
    state.monitors[0].activeWorkspace = WorkspaceID(rawValue: "dev")
    let source = trailing ? remote : local
    let frames = [local: Rect(x: 0, y: 0, width: 1000, height: 700),
      remote: Rect(x: 1000, y: 0, width: 1000, height: 700)]
    #expect(spatialMonitor(from: source, toward: .left, frames: frames) == (trailing ? local : nil))
    let sourceMonitor = try #require(state.monitors.first { $0.id == source })
    #expect(sourceMonitor.workspaces.first { $0.id == sourceMonitor.activeWorkspace }?.kind
      == (trailing ? .trailing : .named))
    let command = Command.moveWorkspaceToMonitor(.left)
    let changed = try changedState(after: command, on: source, from: state, monitorFrames: frames)
    #expect(changed == nil)
    let target = try #require(workspaceTargetID(for: command, on: source, state: state))
    let location = try #require(state.workspaceLocation(for: target))
    #expect(commandValidationIsNoOp(
      hasValidationState: changed != nil,
      rebasesPendingFrame: false,
      command: command,
      workspaceFocusMonitorID: state.monitors[location.monitorIndex].id,
      activeMonitorID: trailing ? local : remote,
      selectedWindowIsNativelyFocused: false
    ))
  }

  @Test
  func workspaceMutationUsesTheCommandMonitorFloatingWindows() {
    let activeMonitor = MonitorID(rawValue: 1)
    let commandMonitor = MonitorID(rawValue: 2)
    let activeFloating = WindowID(rawValue: 10)
    let commandFloating = WindowID(rawValue: 20)
    let workspaceID = WorkspaceID(rawValue: "dev")
    let monitors = [
      Monitor(
        id: activeMonitor,
        workspaces: [Workspace(id: workspaceID, floatingWindows: [activeFloating])],
        activeWorkspace: workspaceID
      ),
      Monitor(
        id: commandMonitor,
        workspaces: [Workspace(id: workspaceID, floatingWindows: [commandFloating])],
        activeWorkspace: workspaceID
      ),
    ]

    #expect(
      floatingWindowIDsForWorkspaceMutation(
        monitors: monitors,
        monitorID: commandMonitor
      ) == [commandFloating]
    )
  }

  @Test
  func crossMonitorMoveRefreshesEveryPreviousMonitor() {
    let source = MonitorID(rawValue: 1)
    let destination = MonitorID(rawValue: 2)
    let previousTransientMonitor = MonitorID(rawValue: 3)
    let owner = WindowID(rawValue: 10)
    let transient = WindowID(rawValue: 11)

    #expect(
      affectedMonitorIDsForWindowMove(
        commandMonitorID: source,
        resultMonitorID: destination,
        previousWindowMonitorIDs: [
          owner: source,
          transient: previousTransientMonitor,
        ],
        nextWindowMonitorIDs: [
          owner: destination,
          transient: destination,
        ]
      ) == [source, destination, previousTransientMonitor]
    )
  }

  @Test
  func columnTransferTargetsTheTiledSelectionWhenFloatingIsFocused() {
    let tiledID = WindowID(rawValue: 10)
    let floatingID = WindowID(rawValue: 11)

    #expect(
      crossMonitorCommandWindowID(
        .moveColumnToMonitor(.right),
        selectedWindowID: floatingID,
        selectedTiledWindowID: tiledID
      ) == tiledID
    )
    #expect(
      crossMonitorCommandWindowID(
        .moveWindowToMonitor(.right),
        selectedWindowID: floatingID,
        selectedTiledWindowID: tiledID
      ) == floatingID
    )
  }

  @Test
  func crossMonitorMoveRebasesTheFreshlyObservedFloatingFrame() {
    let source = MonitorID(rawValue: 1)
    let destination = MonitorID(rawValue: 2)
    let windowID = WindowID(rawValue: 10)
    let freshFrame = Rect(x: 350, y: 80, width: 300, height: 200)

    #expect(
      rebasedFloatingWindowFrames(
        [windowID: freshFrame],
        previousViewports: [
          source: Rect(x: 0, y: 0, width: 1_000, height: 800)
        ],
        nextViewports: [
          destination: Rect(x: 1_000, y: 0, width: 2_000, height: 800)
        ],
        previousMonitorIDs: [windowID: source],
        nextMonitorIDs: [windowID: destination]
      )[windowID] == Rect(x: 1_850, y: 80, width: 300, height: 200)
    )
  }

  @Test
  func crossMonitorMoveForcesOnlyMovedFloatingFrameWrites() {
    let source = MonitorID(rawValue: 1)
    let destination = MonitorID(rawValue: 2)
    let floatingID = WindowID(rawValue: 10)
    let tiledID = WindowID(rawValue: 11)
    let stationaryFloatingID = WindowID(rawValue: 12)

    #expect(
      floatingWindowIDsMovedBetweenMonitors(
        previousWindowMonitorIDs: [
          floatingID: source,
          tiledID: source,
          stationaryFloatingID: source,
        ],
        nextWindowMonitorIDs: [
          floatingID: destination,
          tiledID: destination,
          stationaryFloatingID: source,
        ],
        windows: [
          floatingID: Window(
            id: floatingID,
            appID: "app",
            title: "Floating",
            frame: Rect(x: 0, y: 0, width: 300, height: 200),
            floating: true
          ),
          tiledID: Window(
            id: tiledID,
            appID: "app",
            title: "Tiled",
            frame: Rect(x: 0, y: 0, width: 600, height: 800)
          ),
          stationaryFloatingID: Window(
            id: stationaryFloatingID,
            appID: "app",
            title: "Stationary",
            frame: Rect(x: 0, y: 0, width: 300, height: 200),
            floating: true
          ),
        ]
      ) == [floatingID]
    )
  }
}
