import DefiConfig
import DefiCore
import DefiMacOS
import DefiModel
import DefiRuntime
import Testing

@testable import DefiDaemon

struct DaemonCommandPolicyTests {
  @Test(arguments: [20.0, 21.0])
  func nativeFocusAnimationSurvivesItsOwnSnapshotButYieldsToNewerInput(timestamp: Double) {
    #expect(desktopSnapshotWaitsForCommandAnimation(animationPending: true,
      latestCommandInputTimestamp: 10, latestNativeFocusAnimationInputTimestamp: 20,
      mouseFocusIntentTimestamp: timestamp, keyboardFocusIntentTimestamp: nil) == (timestamp == 20))
  }

  @Test func changedNativeFocusAnimatesOnlyItsMonitor() {
    let monitor = MonitorID(rawValue: 2)
    #expect(nativeFocusAnimationMonitorID(focusedMonitorID: monitor, floating: false,
      overviewOpen: false, mouseGestureActive: false, displayGeometryChanged: false) == monitor)
    #expect(nativeFocusAnimationMonitorID(focusedMonitorID: nil, floating: false,
      overviewOpen: false, mouseGestureActive: false, displayGeometryChanged: false) == nil)
  }

  @Test(arguments: [(true, false, false, false), (false, true, false, false),
    (false, false, true, false), (false, false, false, true)])
  func nativeFocusDoesNotAnimateDuringOtherInteractions(blockers: (Bool, Bool, Bool, Bool)) {
    #expect(nativeFocusAnimationMonitorID(focusedMonitorID: MonitorID(rawValue: 2),
      floating: blockers.0, overviewOpen: blockers.1, mouseGestureActive: blockers.2,
      displayGeometryChanged: blockers.3) == nil)
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
  func ribbonPrototypeFlagAcceptsWhitespaceAndAdditionalTokens() {
    #expect(overviewRibbonPrototypeRequested(in: "  toggle-overview\t--ribbon-prototype  "))
    #expect(overviewRibbonPrototypeRequested(in: "toggle-overview --monitor 1 --ribbon-prototype"))
    #expect(!overviewRibbonPrototypeRequested(in: "toggle-overview"))
    #expect(!overviewRibbonPrototypeRequested(in: "focus-column --ribbon-prototype"))
  }

  @Test
  func overviewToggleGateUsesActualAndPendingState() {
    let toggleState = OverviewToggleState()
    #expect(toggleState.toggle(
      ribbonPrototype: true,
      screenCaptureAccessGranted: false
    ) == .denied)
    #expect(toggleState.snapshot() == OverviewToggleSnapshot(
      generation: 0,
      actualIsOpen: false,
      desiredIsOpen: nil
    ))

    guard case .requested(let openRequest) = toggleState.toggle(
      ribbonPrototype: false,
      screenCaptureAccessGranted: false
    ) else {
      Issue.record("ordinary overview should open without Screen Recording access")
      return
    }
    #expect(toggleState.beginApplying(openRequest))
    toggleState.recordControllerState(true)
    toggleState.finishApplying(openRequest, actualIsOpen: true)

    guard case .requested(let closeRequest) = toggleState.toggle(
      ribbonPrototype: true,
      screenCaptureAccessGranted: false
    ) else {
      Issue.record("a denied prototype request must still be able to close an open overview")
      return
    }
    #expect(!closeRequest.isOpen)
  }

  @Test
  func overviewToggleGenerationRejectsOldProjectionAndEscapeCancelsPendingAck() {
    let toggleState = OverviewToggleState()
    guard case .requested(let opening) = toggleState.toggle(
      ribbonPrototype: false,
      screenCaptureAccessGranted: true
    ), case .requested(let closing) = toggleState.toggle(
      ribbonPrototype: false,
      screenCaptureAccessGranted: true
    ) else {
      Issue.record("rapid toggles should produce desired open and then closed states")
      return
    }
    #expect(!toggleState.beginApplying(opening))
    #expect(toggleState.beginApplying(closing))
    toggleState.recordControllerState(false)
    toggleState.finishApplying(closing, actualIsOpen: false)
    #expect(toggleState.snapshot().actualIsOpen == false)
    #expect(toggleState.snapshot().desiredIsOpen == nil)

    guard case .requested(let openingAgain) = toggleState.toggle(
      ribbonPrototype: false,
      screenCaptureAccessGranted: true
    ) else {
      Issue.record("closed overview should accept a new open request")
      return
    }
    #expect(toggleState.beginApplying(openingAgain))
    toggleState.recordControllerState(true)
    toggleState.finishApplying(openingAgain, actualIsOpen: true)

    guard case .requested(let inFlightClose) = toggleState.toggle(
      ribbonPrototype: false,
      screenCaptureAccessGranted: true
    ) else {
      Issue.record("open overview should accept a close request")
      return
    }
    #expect(toggleState.beginApplying(inFlightClose))
    guard case .requested(let latestOpen) = toggleState.toggle(
      ribbonPrototype: false,
      screenCaptureAccessGranted: true
    ) else {
      Issue.record("a pending close should be reversible by a newer toggle")
      return
    }
    toggleState.recordControllerState(false)
    toggleState.finishApplying(inFlightClose, actualIsOpen: false)
    #expect(toggleState.snapshot().desiredIsOpen == true)
    #expect(toggleState.beginApplying(latestOpen))
    toggleState.recordControllerState(true)
    toggleState.finishApplying(latestOpen, actualIsOpen: true)
    #expect(toggleState.snapshot().desiredIsOpen == nil)

    guard case .requested(let pendingClose) = toggleState.toggle(
      ribbonPrototype: false,
      screenCaptureAccessGranted: false
    ) else {
      Issue.record("open overview should accept a close request without Screen Recording access")
      return
    }
    toggleState.recordControllerState(false)
    #expect(!toggleState.isCurrent(pendingClose))
    #expect(toggleState.snapshot().actualIsOpen == false)
    #expect(toggleState.snapshot().desiredIsOpen == nil)
  }

  @Test
  func rejectedPrototypeOpenReconcilesToActualClosedState() {
    let toggleState = OverviewToggleState()
    guard case .requested(let request) = toggleState.toggle(
      ribbonPrototype: true,
      screenCaptureAccessGranted: true
    ) else {
      Issue.record("granted permission should authorize the prototype request")
      return
    }
    #expect(toggleState.beginApplying(request))
    // The controller can reject if permission is revoked after the daemon preflight.
    toggleState.finishApplying(request, actualIsOpen: false)
    #expect(toggleState.snapshot().actualIsOpen == false)
    #expect(toggleState.snapshot().desiredIsOpen == nil)
  }

  @Test
  func outgoingTransitionParkingIsReservedForLaterMonitorLayouts() throws {
    let outgoingMonitor = Rect(x: -1_200, y: 400, width: 800, height: 600)
    let laterMonitor = Rect(x: 0, y: 0, width: 800, height: 600)
    let deltaY = -600.0
    var shiftedLaterMonitor = laterMonitor
    shiftedLaterMonitor.y -= deltaY
    let strip = continuousStripFramesForActiveWorkspace(
      [
        FrameAssignment(
          windowID: WindowID(rawValue: 1),
          frame: Rect(x: -100, y: 400, width: 300, height: 600)
        )
      ],
      viewport: outgoingMonitor,
      ownerFrame: outgoingMonitor,
      allMonitorFrames: [outgoingMonitor, shiftedLaterMonitor]
    )
    let reservations = parkedFrameReservations(in: strip, translatedBy: deltaY)
    let outgoingFrame = try #require(reservations.first)
    let laterPlacement = resolveParkingPlacement(
      for: Rect(x: 0, y: 0, width: 300, height: 600),
      ownerFrame: laterMonitor,
      allMonitorFrames: [outgoingMonitor, laterMonitor],
      reservedParkingFrames: reservations,
      preferredSide: .left
    )
    let overlapWidth = max(
      min(laterPlacement.frame.x + laterPlacement.frame.width,
          outgoingFrame.x + outgoingFrame.width)
        - max(laterPlacement.frame.x, outgoingFrame.x),
      0
    )
    let overlapHeight = max(
      min(laterPlacement.frame.y + laterPlacement.frame.height,
          outgoingFrame.y + outgoingFrame.height)
        - max(laterPlacement.frame.y, outgoingFrame.y),
      0
    )

    #expect(outgoingFrame == Rect(x: -401, y: -200, width: 300, height: 600))
    #expect(overlapWidth * overlapHeight == 0)
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

  @Test(arguments: [9.0, 11.0])
  func externalActivationOnlyPreemptsOlderCommandAnimation(timestamp: Double) {
    #expect(desktopSnapshotWaitsForCommandAnimation(
      animationPending: true,
      latestCommandInputTimestamp: 10,
      mouseFocusIntentTimestamp: nil,
      keyboardFocusIntentTimestamp: nil,
      applicationActivationTimestamp: timestamp
    ) == (timestamp < 10))
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
  func staleNativeFocusCannotChangeSelectionBeforeMonitorSelection(activationTimestamp: Double?) {
    let nativeFocusAccepted = nativeFocusMutationIsReady(
      nativeFocusChanged: true,
      mouseInteractionEnded: false,
      leftMouseButtonDown: false,
      mouseReleaseFocusIntentCurrent: false,
      keyboardFocusIntentCurrent: false,
      applicationActivationTimestamp: activationTimestamp,
      latestCommandInputTimestamp: 11
    )
    #expect(!shouldCommitNativeFocusSelection(
      nativeFocusAccepted: nativeFocusAccepted,
      selectionChanged: true
    ))
    #expect(shouldCommitNativeFocusSelection(
      nativeFocusAccepted: true,
      selectionChanged: true
    ))
    #expect(!shouldCommitNativeFocusSelection(
      nativeFocusAccepted: true,
      selectionChanged: false
    ))
  }

  @Test(arguments: [nil, 10.0] as [Double?])
  func staleFocusOnSecondMonitorKeepsDefaultMonitorRouting(activationTimestamp: Double?) {
    let firstMonitor = MonitorID(rawValue: 1)
    let staleMonitor = MonitorID(rawValue: 2)
    let nativeFocusAccepted = nativeFocusMutationIsReady(
      nativeFocusChanged: true,
      mouseInteractionEnded: false,
      leftMouseButtonDown: false,
      mouseReleaseFocusIntentCurrent: false,
      keyboardFocusIntentCurrent: false,
      applicationActivationTimestamp: activationTimestamp,
      latestCommandInputTimestamp: 11
    )
    let acceptedMonitor = shouldCommitNativeFocusSelection(
      nativeFocusAccepted: nativeFocusAccepted,
      selectionChanged: true
    ) ? staleMonitor : nil

    #expect(activeMonitorIDAfterSnapshot(
      activeMonitorID: nil,
      acceptedNativeFocusMonitorID: acceptedMonitor,
      fallbackMonitorID: firstMonitor
    ) == firstMonitor)
    #expect(activeMonitorIDAfterSnapshot(
      activeMonitorID: nil,
      acceptedNativeFocusMonitorID: staleMonitor,
      fallbackMonitorID: firstMonitor
    ) == staleMonitor)
  }

  @Test
  func inactiveDesktopNeverArmsRecurringTimer() {
    #expect(desktopTimerFrequency(requested: 240, sessionActive: false) == 0)
    #expect(desktopTimerFrequency(requested: 2, sessionActive: true) == 2)
    #expect(desktopTimerFrequency(requested: 0, sessionActive: true) == 1)
    #expect(desktopTimerFrequency(requested: 500, sessionActive: true) == 240)
  }

  @Test
  func stalledRepairsBackOffWhileFocusRemainsResponsive() {
    #expect(followUpTimerFrequency(backoffSteps: 2, unchangedDuration: 3, focusPending: false) == 2)
    #expect(followUpTimerFrequency(backoffSteps: 2, unchangedDuration: 3, focusPending: true) == 15)
    #expect(followUpTimerFrequency(backoffSteps: 0, unchangedDuration: 0, focusPending: false) == 60)
  }

  @Test
  func idleWatchdogUsesEarliestDeadlineWithoutDelayingFallbackReads() {
    #expect(idleDesktopRefreshDelay(
      now: 10, latestInputAt: 0,
      deadlinesAndIntervals: [(40, 30), (25, 30)]
    ) == 15)
    #expect(idleDesktopRefreshDelay(
      now: 10, latestInputAt: 9.8,
      deadlinesAndIntervals: [(9, 30)]
    ) > 0.79)
    #expect(idleDesktopRefreshDelay(
      now: 10, latestInputAt: 10,
      deadlinesAndIntervals: [(9, 0.3), (40, 30)]
    ) == 0.3)
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
  func closeTopologyRetriesAreBoundedAndLatestWins() {
    #expect(windowCloseRefreshDelays == [50, 150, 350, 700, 1_200, 2_000])
    #expect(
      windowCloseRetryIsCurrent(
        intentTimestamp: 10,
        latestInputTimestamp: 10,
        latestCloseIntentTimestamp: 10
      )
    )
    #expect(
      windowCloseRetryIsCurrent(
        intentTimestamp: 10,
        latestInputTimestamp: 11,
        latestCloseIntentTimestamp: 10
      ) == false
    )
    #expect(
      windowCloseRetryIsCurrent(
        intentTimestamp: 10,
        latestInputTimestamp: 11,
        latestCloseIntentTimestamp: 11
      ) == false
    )
  }

  @Test
  func backgroundSnapshotWaitsForTheCurrentCommandAnimation() {
    #expect(
      desktopSnapshotWaitsForCommandAnimation(
        animationPending: true,
        latestCommandInputTimestamp: 10,
        mouseFocusIntentTimestamp: nil,
        keyboardFocusIntentTimestamp: nil
      ))
    #expect(
      desktopSnapshotWaitsForCommandAnimation(
        animationPending: true,
        latestCommandInputTimestamp: 10,
        mouseFocusIntentTimestamp: 11,
        keyboardFocusIntentTimestamp: nil
      ) == false)
  }

  @Test
  func verticalWorkspaceTransitionUsesAPerceivableMinimumDuration() {
    #expect(workspaceVerticalTransitionDuration(configuredDurationMS: 0) == 0)
    #expect(workspaceVerticalTransitionDuration(configuredDurationMS: 35) == 0.18)
    #expect(workspaceVerticalTransitionDuration(configuredDurationMS: 250) == 0.25)
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
  func verticalWorkspaceTransitionRejectsAnUncoveredDisplayMargin() {
    let physicalFrame = Rect(x: 0, y: 0, width: 1_512, height: 982)

    #expect(
      workspaceVerticalTransitionCanAnimateWithoutReservedAreaLeak(
        viewport: physicalFrame,
        physicalFrame: physicalFrame
      )
    )
    #expect(
      workspaceVerticalTransitionCanAnimateWithoutReservedAreaLeak(
        viewport: Rect(x: 0, y: 33, width: 1_512, height: 900),
        physicalFrame: physicalFrame
      ) == false
    )
  }

  @Test
  func verticalWorkspaceRibbonClearsThePhysicalMonitor() {
    let physicalFrame = Rect(x: 0, y: 0, width: 1_512, height: 982)
    let windowFrame = Rect(x: 4, y: 37, width: 1_204, height: 900)

    #expect(
      windowFrame.y
        + workspaceVerticalRibbonOffset(
          relativePosition: 1,
          physicalFrame: physicalFrame
        ) >= physicalFrame.y + physicalFrame.height
    )
    #expect(
      windowFrame.y + windowFrame.height
        + workspaceVerticalRibbonOffset(
          relativePosition: -1,
          physicalFrame: physicalFrame
        ) <= physicalFrame.y
    )
  }

  @Test
  func inactiveWorkspaceOnlyJoinsTheRibbonWhileLeaving() {
    let monitorID = MonitorID(rawValue: 1)
    let outgoingWorkspaceID = WorkspaceID(rawValue: "dev")
    let transition = WorkspaceVerticalTransition(
      monitorID: monitorID,
      outgoingWorkspaceID: outgoingWorkspaceID,
      direction: 1
    )
    let physicalFrame = Rect(x: 0, y: 0, width: 1_512, height: 982)

    #expect(
      outgoingWorkspaceVerticalRibbonOffset(
        workspaceID: outgoingWorkspaceID,
        monitorID: monitorID,
        transition: transition,
        physicalFrame: physicalFrame
      ) == -982
    )
    #expect(
      outgoingWorkspaceVerticalRibbonOffset(
        workspaceID: WorkspaceID(rawValue: "web"),
        monitorID: monitorID,
        transition: transition,
        physicalFrame: physicalFrame
      ) == nil
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
  func localLayoutSubmissionSkipsCachedMonitorAssignments() {
    let included = MonitorID(rawValue: 1)
    let excluded = MonitorID(rawValue: 2)
    let assignment = FrameAssignment(
      windowID: WindowID(rawValue: 10),
      frame: Rect(x: 0, y: 0, width: 800, height: 600)
    )
    let plan = MonitorLayoutPlan(
      assignments: [assignment],
      borderAssignments: [assignment],
      nativeFullscreenPlaceholderAssignments: [],
      hiddenWindowIDs: []
    )

    #expect(
      layoutWindowIDsOutsideSubmissionScope(
        plan,
        monitorID: included,
        restrictedTo: [included]
      ).isEmpty
    )
    #expect(
      layoutWindowIDsOutsideSubmissionScope(
        plan,
        monitorID: excluded,
        restrictedTo: [included]
      ) == [assignment.windowID]
    )
  }

  @Test
  func staticFrameOrDeferredFocusKeepsCommandFollowUpResponsive() {
    #expect(
      commandFollowUpIsPending(
        frameWrites: true,
        animatedFocus: false,
        workspaceFocus: false
      )
    )
    #expect(
      commandFollowUpIsPending(
        frameWrites: false,
        animatedFocus: true,
        workspaceFocus: false
      )
    )
    #expect(
      commandFollowUpIsPending(
        frameWrites: false,
        animatedFocus: false,
        workspaceFocus: false
      ) == false)
  }

  @Test
  func crossMonitorAnimationWaitsForEveryDisplayAtTheSlowestCadence() {
    let source = MonitorID(rawValue: 1)
    let destination = MonitorID(rawValue: 2)

    let timing = animationDisplayTiming(
      monitorIDs: [source, destination],
      activeMonitorID: destination,
      fallbackMonitorID: source,
      refreshRates: [source: 60, destination: 120]
    )

    #expect(timing.refreshRateHz == 60)
    #expect(timing.displayIDs == [1, 2])
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
