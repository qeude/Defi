import AppKit
import DefiModel
import Testing

@testable import DefiMacOS

struct PlatformEventTests {
  @Test
  func physicalPointerTrackingIncludesDragEvents() {
    #expect(eventTracksPhysicalPointerMotion(.mouseMoved))
    #expect(eventTracksPhysicalPointerMotion(.leftMouseDragged))
    #expect(eventTracksPhysicalPointerMotion(.rightMouseDragged))
    #expect(eventTracksPhysicalPointerMotion(.otherMouseDragged))
    #expect(!eventTracksPhysicalPointerMotion(.scrollWheel))
    #expect(!eventTracksPhysicalPointerMotion(.keyDown))
  }

  @Test
  func generalInputTrackingIncludesEveryMouseButtonDown() {
    #expect(eventIsMouseButtonDown(.leftMouseDown))
    #expect(eventIsMouseButtonDown(.rightMouseDown))
    #expect(eventIsMouseButtonDown(.otherMouseDown))
    #expect(!eventIsMouseButtonDown(.leftMouseUp))
    #expect(!eventIsMouseButtonDown(.mouseMoved))
    #expect(!eventIsMouseButtonDown(.keyDown))
  }

  @Test
  func generalInputTrackingIncludesScrollWheel() {
    #expect(eventTracksGeneralUserInput(.keyDown))
    #expect(eventTracksGeneralUserInput(.flagsChanged))
    #expect(eventTracksGeneralUserInput(.leftMouseDown))
    #expect(eventTracksGeneralUserInput(.rightMouseDown))
    #expect(eventTracksGeneralUserInput(.otherMouseDown))
    #expect(eventTracksGeneralUserInput(.scrollWheel))
    #expect(!eventTracksGeneralUserInput(.mouseMoved))
    #expect(!eventTracksGeneralUserInput(.leftMouseUp))
  }

  @Test
  func nativeFocusResultRequiresCurrentSuccessfulRequest() {
    #expect(
      resolvedNativeFocusResult(
        mutationApplied: false,
        generationCurrent: true,
        inputCurrent: true,
        cancelled: false,
        focusSucceeded: true
      ) == .completedWithoutMutation
    )
    #expect(
      resolvedNativeFocusResult(
        mutationApplied: false,
        generationCurrent: true,
        inputCurrent: true,
        cancelled: false,
        focusSucceeded: false
      ) == .failed
    )
    #expect(
      resolvedNativeFocusResult(
        mutationApplied: false,
        generationCurrent: false,
        inputCurrent: true,
        cancelled: true,
        focusSucceeded: true
      ) == .cancelled
    )
  }

  @Test
  func focusedExplicitTargetSkipsNoOpNativeWrite() {
    #expect(
      specificWindowFocusWriteIsRequired(
        requested: true,
        validatesCurrentFocus: false,
        targetIsFocused: true
      ) == false
    )
    #expect(
      specificWindowFocusWriteIsRequired(
        requested: true,
        validatesCurrentFocus: false,
        targetIsFocused: false
      )
    )
  }

  @Test
  func staleGuardedFocusReportsMutationForRecovery() {
    #expect(
      resolvedNativeFocusResult(
        mutationApplied: true,
        generationCurrent: true,
        inputCurrent: false,
        cancelled: true,
        focusSucceeded: true
      ) == .cancelledAfterInputMutation
    )
    #expect(
      resolvedNativeFocusResult(
        mutationApplied: true,
        generationCurrent: false,
        inputCurrent: false,
        cancelled: true,
        focusSucceeded: true
      ) == .cancelledAfterMutation
    )
  }

  @Test
  func supersededMutationTransfersRecoveryToUnmutatedReplacement() throws {
    let originalRecovery = NativeFocusRecoveryRequest(
      timestamp: 10,
      excludingWindowID: WindowID(rawValue: 2),
      excludingProcessID: 20,
      fallback: NativeFocusRecoveryFallback(
        windowID: WindowID(rawValue: 1),
        processID: 10
      )
    )
    let transferred = transferredNativeFocusRecovery(
      carried: nil,
      request: originalRecovery,
      result: .cancelledAfterMutation,
      generationCurrent: false
    )
    #expect(transferred.carried == originalRecovery)
    #expect(transferred.recovery == nil)

    let replacement = transferredNativeFocusRecovery(
      carried: transferred.carried,
      request: NativeFocusRecoveryRequest(
        timestamp: 11,
        excludingWindowID: WindowID(rawValue: 3),
        excludingProcessID: 30,
        fallback: nil
      ),
      result: .cancelled,
      generationCurrent: true
    )
    #expect(replacement.carried == nil)
    #expect(replacement.recovery == originalRecovery)
  }

  @Test
  func failedFocusPreservesWhetherMutationWasApplied() {
    #expect(
      resolvedNativeFocusResult(
        mutationApplied: false,
        generationCurrent: true,
        inputCurrent: true,
        cancelled: false,
        focusSucceeded: false
      ) == .failed
    )
    #expect(
      resolvedNativeFocusResult(
        mutationApplied: true,
        generationCurrent: true,
        inputCurrent: true,
        cancelled: false,
        focusSucceeded: false
      ) == .failedAfterMutation
    )
  }

  @Test
  func abandonedFocusClearsOnlyItsOwnUnmutatedSuppression() {
    let current = InternalFocusSuppression(requestID: 7, deadline: 20)

    #expect(
      internalFocusSuppressionAfterCompletion(
        current,
        requestID: 7,
        result: .completedWithoutMutation
      ) == nil
    )
    #expect(
      internalFocusSuppressionAfterCompletion(
        current,
        requestID: 7,
        result: .cancelled
      ) == nil
    )
    #expect(
      internalFocusSuppressionAfterCompletion(
        current,
        requestID: 6,
        result: .cancelled
      ) == current
    )
    #expect(
      internalFocusSuppressionAfterCompletion(
        current,
        requestID: 7,
        result: .cancelledAfterMutation
      ) == current
    )
    #expect(
      internalFocusSuppressionAfterCompletion(
        current,
        requestID: 7,
        result: .cancelledAfterInputMutation
      ) == current
    )
    #expect(
      internalFocusSuppressionAfterCompletion(
        current,
        requestID: 7,
        result: .failedAfterMutation
      ) == nil
    )
  }

  @Test
  func userInputTrackingStaysMonotonicAcrossDuplicateDelivery() {
    let tracker = UserInputTracker()
    tracker.record(timestamp: 12)
    tracker.record(timestamp: 8)
    tracker.record(timestamp: 12)

    #expect(tracker.latestEventTimestamp == 12)
    #expect(
      userInputOccurredAfterWindowTopology(
        topologyInputTimestamp: 12,
        latestInputTimestamp: tracker.latestEventTimestamp
      ) == false
    )

    tracker.record(timestamp: 13)
    #expect(
      userInputOccurredAfterWindowTopology(
        topologyInputTimestamp: 12,
        latestInputTimestamp: tracker.latestEventTimestamp
      )
    )
  }

  @Test
  func commandTabAfterCloseWinsBeforeTopologyNotification() {
    let tracker = UserInputTracker()
    tracker.record(timestamp: 20, closeIntent: true)
    tracker.record(timestamp: 21, focusIntent: .keyboard)
    let input = tracker.snapshot

    #expect(
      userInputOccurredAfterWindowTopology(
        topologyInputTimestamp: input.latestEventTimestamp,
        latestInputTimestamp: input.latestEventTimestamp,
        latestFocusIntent: input.latestFocusIntent,
        latestCloseIntentTimestamp: input.latestCloseIntent
      )
    )
  }

  @Test
  func mouseClickAfterCloseWinsBeforeTopologyNotification() {
    let tracker = UserInputTracker()
    let clickedWindowID = WindowID(rawValue: 30)
    tracker.record(timestamp: 20, closeIntent: true)
    tracker.record(
      timestamp: 21,
      focusIntent: .mouse(windowID: clickedWindowID)
    )
    let input = tracker.snapshot

    #expect(
      userInputOccurredAfterWindowTopology(
        topologyInputTimestamp: input.latestEventTimestamp,
        latestInputTimestamp: input.latestEventTimestamp,
        latestFocusIntent: input.latestFocusIntent,
        latestCloseIntentTimestamp: input.latestCloseIntent,
        removedWindowIDs: [WindowID(rawValue: 10)]
      )
    )
  }

  @Test
  func closeButtonClickDoesNotMasqueradeAsFocusIntent() {
    let tracker = UserInputTracker()
    let closingWindowID = WindowID(rawValue: 10)
    tracker.record(
      timestamp: 20,
      focusIntent: .mouse(windowID: closingWindowID)
    )
    let input = tracker.snapshot

    #expect(
      userInputOccurredAfterWindowTopology(
        topologyInputTimestamp: input.latestEventTimestamp,
        latestInputTimestamp: input.latestEventTimestamp,
        latestFocusIntent: input.latestFocusIntent,
        latestCloseIntentTimestamp: input.latestCloseIntent,
        removedWindowIDs: [closingWindowID]
      ) == false
    )
  }

  @Test
  func closeIntentDoesNotMasqueradeAsExplicitFocus() {
    let tracker = UserInputTracker()
    tracker.record(timestamp: 19, focusIntent: .keyboard)
    tracker.record(timestamp: 20, closeIntent: true)
    let input = tracker.snapshot

    #expect(
      userInputOccurredAfterWindowTopology(
        topologyInputTimestamp: input.latestEventTimestamp,
        latestInputTimestamp: input.latestEventTimestamp,
        latestFocusIntent: input.latestFocusIntent,
        latestCloseIntentTimestamp: input.latestCloseIntent
      ) == false
    )
  }

  @Test
  func guardedFocusCancelsOnlyForNewerInput() {
    #expect(
      guardedFocusIsCurrent(
        latestInputTimestamp: 10,
        maximumInputTimestamp: 10
      )
    )
    #expect(
      guardedFocusIsCurrent(
        latestInputTimestamp: 11,
        maximumInputTimestamp: 10
      ) == false
    )
  }

  @Test
  func guardedFocusMutationRecoversOnlyFromNewerInput() {
    #expect(
      guardedFocusMutationNeedsRecovery(
        mutationApplied: true,
        generationCurrent: true,
        inputCurrent: false
      )
    )
    #expect(
      guardedFocusMutationNeedsRecovery(
        mutationApplied: false,
        generationCurrent: true,
        inputCurrent: false
      ) == false
    )
    #expect(
      guardedFocusMutationNeedsRecovery(
        mutationApplied: true,
        generationCurrent: false,
        inputCurrent: false
      ) == false
    )
  }

  @Test
  func nativeFocusEventRequiresMatchingFocusedProcess() {
    #expect(
      nativeFocusEventMatchesTarget(
        eventPending: true,
        eventProcessIDs: [42],
        hasUnknownEventProcess: false,
        focusedProcessID: 42
      )
    )
    #expect(
      nativeFocusEventMatchesTarget(
        eventPending: true,
        eventProcessIDs: [42],
        hasUnknownEventProcess: false,
        focusedProcessID: 7
      ) == false
    )
  }

  @Test
  func unresolvedNativeFocusEventRemainsPendingUntilTargetMatches() {
    #expect(
      nativeFocusEventShouldRemainPending(
        eventPending: true,
        targetMatched: false
      )
    )
    #expect(
      nativeFocusEventShouldRemainPending(
        eventPending: true,
        targetMatched: true
      ) == false
    )
    #expect(
      nativeFocusEventShouldRemainPending(
        eventPending: false,
        targetMatched: false
      ) == false
    )
  }

  @Test
  func unknownNativeFocusSourceAllowsResolvedTarget() {
    #expect(
      nativeFocusEventMatchesTarget(
        eventPending: true,
        eventProcessIDs: [],
        hasUnknownEventProcess: true,
        focusedProcessID: nil
      ) == false
    )
    #expect(
      nativeFocusEventMatchesTarget(
        eventPending: true,
        eventProcessIDs: [],
        hasUnknownEventProcess: true,
        focusedProcessID: 7
      )
    )
  }

  @Test
  func focusRecoveryUsesLatestExplicitTarget() throws {
    let tracker = UserInputTracker()
    let clickedWindowID = WindowID(rawValue: 42)
    tracker.record(
      timestamp: 11,
      focusIntent: .mouse(windowID: clickedWindowID)
    )

    let mouseTarget = try #require(
      tracker.focusRecoveryTarget(after: 10)
    )
    #expect(mouseTarget.windowID == clickedWindowID)
    #expect(mouseTarget.timestamp == 11)

    tracker.record(timestamp: 12, focusIntent: .keyboard)
    tracker.recordObservedFocus(windowID: nil, processID: 900)
    let keyboardTarget = try #require(
      tracker.focusRecoveryTarget(after: 11)
    )
    #expect(keyboardTarget.timestamp == 12)
    #expect(keyboardTarget.windowID == nil)
    #expect(keyboardTarget.processID == 900)

    tracker.record(timestamp: 13)
    #expect(
      tracker.focusRecoveryTarget(after: 11)?.timestamp == 13
    )
  }

  @Test
  func mouseFocusRecoveryUsesObservedTargetWithoutEventWindowID() throws {
    let tracker = UserInputTracker()
    tracker.record(timestamp: 11, focusIntent: .mouse(windowID: nil))
    tracker.recordObservedFocus(windowID: nil, processID: 900)

    let target = try #require(tracker.focusRecoveryTarget(after: 10))
    #expect(target.timestamp == 11)
    #expect(target.windowID == nil)
    #expect(target.processID == 900)
  }

  @Test
  func ordinaryInputRecoversCapturedNativeFocus() throws {
    let tracker = UserInputTracker()
    let fallbackWindowID = WindowID(rawValue: 42)
    tracker.record(timestamp: 12)

    let target = try #require(
      tracker.focusRecoveryTarget(
        after: 10,
        excludingWindowID: WindowID(rawValue: 50),
        excludingProcessID: 500,
        fallbackWindowID: fallbackWindowID,
        fallbackProcessID: 400
      )
    )
    #expect(target.timestamp == 12)
    #expect(target.windowID == fallbackWindowID)
    #expect(target.processID == 400)
  }

  @Test
  func unresolvedExplicitFocusDoesNotFallBack() {
    let tracker = UserInputTracker()
    tracker.record(timestamp: 12, focusIntent: .keyboard)

    #expect(
      tracker.focusRecoveryTarget(
        after: 10,
        fallbackWindowID: WindowID(rawValue: 42),
        fallbackProcessID: 400
      ) == nil
    )
  }

  @Test
  func fallbackRecoveryRejectsTargetAndCloseIntent() {
    let requestedWindowID = WindowID(rawValue: 42)
    let tracker = UserInputTracker()
    tracker.record(timestamp: 12)

    #expect(
      tracker.focusRecoveryTarget(
        after: 10,
        excludingWindowID: requestedWindowID,
        fallbackWindowID: requestedWindowID,
        fallbackProcessID: 400
      ) == nil
    )

    let closingTracker = UserInputTracker()
    closingTracker.record(timestamp: 12, closeIntent: true)
    #expect(
      closingTracker.focusRecoveryTarget(
        after: 10,
        fallbackWindowID: requestedWindowID,
        fallbackProcessID: 400
      ) == nil
    )
  }

  @Test
  func focusRecoveryExcludesGuardedFallbackObservations() throws {
    let tracker = UserInputTracker()
    let fallbackWindowID = WindowID(rawValue: 40)
    let intendedWindowID = WindowID(rawValue: 50)
    tracker.record(timestamp: 12, focusIntent: .keyboard)
    tracker.recordObservedFocus(windowID: intendedWindowID, processID: 400)
    tracker.recordObservedFocus(windowID: fallbackWindowID, processID: 400)

    let target = try #require(
      tracker.focusRecoveryTarget(
        after: 11,
        excludingWindowID: fallbackWindowID,
        excludingProcessID: 400
      )
    )
    #expect(target.windowID == intendedWindowID)
    #expect(target.processID == 400)
  }

  @Test
  func focusRecoveryExcludesPidOnlyFallbackObservation() {
    let tracker = UserInputTracker()
    tracker.record(timestamp: 12, focusIntent: .keyboard)
    tracker.recordObservedFocus(windowID: WindowID(rawValue: 50), processID: 500)
    tracker.recordObservedFocus(windowID: nil, processID: 400)

    let target = tracker.focusRecoveryTarget(
      after: 11,
      excludingWindowID: WindowID(rawValue: 40),
      excludingProcessID: 400
    )
    #expect(target?.windowID == WindowID(rawValue: 50))
    #expect(target?.processID == 500)
  }

  @Test
  func globalMouseFallbackRetainsTargetWindowIdentity() {
    #expect(
      mouseFocusIntentWindowID(rawWindowID: 42)
        == WindowID(rawValue: 42)
    )
    #expect(mouseFocusIntentWindowID(rawWindowID: 0) == nil)
  }

  @Test
  func pointerMotionTimestampStaysMonotonic() {
    let tracker = PointerMotionTracker()

    tracker.record(timestamp: 12)
    tracker.record(timestamp: 10)

    #expect(tracker.latestTimestamp == 12)
  }

  @Test
  func pointerWindowTransitionsDeduplicateSameWindow() {
    var state = PointerWindowTransitionState()

    let entersWindow = state.changed(to: 42)
    let staysInWindow = state.changed(to: 42)
    let leavesWindow = state.changed(to: 0)
    let staysOutside = state.changed(to: 0)
    let reentersWindow = state.changed(to: 42)

    #expect(entersWindow)
    #expect(staysInWindow == false)
    #expect(leavesWindow)
    #expect(staysOutside == false)
    #expect(reentersWindow)
  }

  @Test
  func pointerWindowTransitionCanBeRearmedInsideSameWindow() {
    var state = PointerWindowTransitionState()

    let entersWindow = state.changed(to: 42)
    let staysInWindow = state.changed(to: 42)
    state.reset()
    let retriesInsideWindow = state.changed(to: 42)

    #expect(entersWindow)
    #expect(staysInWindow == false)
    #expect(retriesInsideWindow)
  }

  @Test
  func unresolvedPointerMotionDeliveryIsRefreshBounded() {
    #expect(
      pointerMotionDeliveryDelay(
        rawWindowID: 0,
        eventTimestamp: 12,
        lastDeliveryTimestamp: nil
      ) == 0
    )
    #expect(
      pointerMotionDeliveryDelay(
        rawWindowID: 42,
        eventTimestamp: 12.001,
        lastDeliveryTimestamp: 12
      ) == 0
    )
    #expect(
      pointerMotionDeliveryDelay(
        rawWindowID: 0,
        eventTimestamp: 12.001,
        lastDeliveryTimestamp: 12
      ) > 0.007
    )
    #expect(
      pointerMotionDeliveryDelay(
        rawWindowID: 0,
        eventTimestamp: 12.01,
        lastDeliveryTimestamp: 12
      ) == 0
    )
  }

  @Test
  func laterWindowTopologyEventRefreshesInputTimestamp() {
    #expect(
      updatedWindowTopologyInputTimestamp(
        for: .windows,
        latestInputTimestamp: 20,
        previousTimestamp: 10
      ) == 20
    )
    #expect(
      updatedWindowTopologyInputTimestamp(
        for: .focus,
        latestInputTimestamp: 30,
        previousTimestamp: 20
      ) == 20
    )
  }

  @Test
  func nativeFocusEventInvalidatesCachedFocusedWindow() {
    let windowID = WindowID(rawValue: 42)

    #expect(
      nativeFocusedWindowIDAfterEvent(
        .focus,
        cachedWindowID: windowID
      ) == nil
    )
    #expect(
      nativeFocusedWindowIDAfterEvent(
        .frame,
        cachedWindowID: windowID
      ) == windowID
    )
  }

  @Test
  func terminatedApplicationWithPIDInvalidatesOnlyItsSnapshot() {
    #expect(
      windowSnapshotInvalidation(
        for: .applicationTerminated,
        processID: 42
      ) == .process(42)
    )
  }

  @Test
  func terminatedApplicationWithoutPIDFallsBackToFullSnapshot() {
    #expect(
      windowSnapshotInvalidation(
        for: .applicationTerminated,
        processID: nil
      ) == .full
    )
  }

  @Test
  func windowTopologyUsesPIDButGeneralApplicationEventsStayGlobal() {
    #expect(
      windowSnapshotInvalidation(for: .windows, processID: 7)
        == .process(7)
    )
    #expect(
      windowSnapshotInvalidation(for: .windows, processID: nil) == .full
    )
    #expect(
      windowSnapshotInvalidation(for: .application, processID: 7) == .full
    )
    #expect(
      windowSnapshotInvalidation(for: .focus, processID: 7) == .none
    )
  }

  @Test
  func simpleClickSynchronizesDesktopOnRelease() {
    var normalizer = MouseGestureEventNormalizer()
    let mouseDown = normalizer.actions(
      for: .leftMouseDown
    )
    let mouseUp = normalizer.actions(for: .leftMouseUp)

    #expect(
      mouseDown
        == MouseGestureEventNormalizer.Actions(
          refreshBorderStacking: true,
          startsGesture: true
        )
    )
    #expect(mouseUp.synchronization == .clickRelease)
    #expect(platformEventCancelsMouseAnimation(.mouseRelease) == false)
    #expect(platformEventCancelsMouseAnimation(.mouse))
  }

  @Test
  func draggedGestureKeepsSynchronizingUntilMouseUp() {
    var normalizer = MouseGestureEventNormalizer()
    let mouseDown = normalizer.actions(
      for: .leftMouseDown
    )
    let firstMouseDragged = normalizer.actions(
      for: .leftMouseDragged
    )
    let secondMouseDragged = normalizer.actions(
      for: .leftMouseDragged
    )
    let firstMouseUp = normalizer.actions(
      for: .leftMouseUp
    )
    let secondMouseUp = normalizer.actions(
      for: .leftMouseUp
    )

    #expect(mouseDown.refreshBorderStacking)
    #expect(mouseDown.synchronization == nil)
    #expect(firstMouseDragged.synchronization == .gesture)
    #expect(secondMouseDragged.synchronization == .gesture)
    #expect(firstMouseUp.synchronization == .gesture)
    #expect(secondMouseUp == MouseGestureEventNormalizer.Actions())
  }

  @Test
  func coalescedNextMouseDownStartsFreshGesture() {
    var normalizer = MouseGestureEventNormalizer()
    _ = normalizer.actions(for: .leftMouseDown)
    _ = normalizer.actions(for: .leftMouseDragged)
    _ = normalizer.actions(for: .leftMouseUp)

    let nextMouseDown = normalizer.actions(for: .leftMouseDown)

    #expect(nextMouseDown.startsGesture)
    #expect(nextMouseDown.synchronization == nil)
  }

  @Test
  func mouseGestureRefreshesClickedWindowProcess() {
    let clickedWindowID = WindowID(rawValue: 10)
    let focusedWindowID = WindowID(rawValue: 20)

    #expect(
      mouseGestureRefreshProcessID(
        latestFocusIntent: .init(
          timestamp: 1,
          source: .mouse(windowID: clickedWindowID)
        ),
        focusedWindowID: focusedWindowID,
        processIDs: [clickedWindowID: 100, focusedWindowID: 200]
      ) == 100
    )
  }

  @Test
  func mouseGestureFallsBackToFocusedProcessWhenClickIsUnknown() {
    let focusedWindowID = WindowID(rawValue: 20)

    #expect(
      mouseGestureRefreshProcessID(
        latestFocusIntent: .init(
          timestamp: 1,
          source: .mouse(windowID: WindowID(rawValue: 10))
        ),
        focusedWindowID: focusedWindowID,
        processIDs: [focusedWindowID: 200]
      ) == 200
    )
  }

  @Test
  func mouseGestureRequiresFullRefreshWithoutKnownProcess() {
    #expect(
      mouseGestureRefreshProcessID(
        latestFocusIntent: nil,
        focusedWindowID: WindowID(rawValue: 20),
        processIDs: [:]
      ) == nil
    )
  }

  @Test
  func borderStackingRefreshIsLatestSelectionWins() throws {
    var state = WindowBorderStackingRefreshState()
    let firstWindow = WindowID(rawValue: 1)
    let secondWindow = WindowID(rawValue: 2)
    let firstRequest = state.request(for: firstWindow)
    let first = try #require(firstRequest)
    let secondRequest = state.request(for: secondWindow)
    let second = try #require(secondRequest)

    #expect(state.shouldApply(first, activeWindowID: firstWindow) == false)
    #expect(state.shouldApply(second, activeWindowID: firstWindow) == false)
    #expect(state.shouldApply(second, activeWindowID: secondWindow))
  }

  @Test
  func frontmostBorderOccluderIgnoresTinyAuxiliaryWindows() {
    let auxiliaryWindow = WindowID(rawValue: 1)
    let focusedWindow = WindowID(rawValue: 2)

    let result = windowBorderStacking(
      targetWindowID: focusedWindow,
      ownProcessID: 99,
      floatingLevel: NSWindow.Level.floating.rawValue,
      entries: [
        WindowStackEntry(
          windowID: auxiliaryWindow,
          processID: 7,
          layer: NSWindow.Level.normal.rawValue,
          frame: Rect(x: 8, y: 40, width: 66, height: 20)
        ),
        WindowStackEntry(
          windowID: focusedWindow,
          processID: 8,
          layer: NSWindow.Level.normal.rawValue,
          frame: Rect(x: 2, y: 34, width: 2_044, height: 1_354)
        ),
      ]
    )

    #expect(result.activeWindowIsFrontmost)
    #expect(result.upperBoundWindowID == nil)
  }

  @Test
  func frontmostBorderOccluderKeepsDialogsAheadOfFocusedWindow() {
    let dialog = WindowID(rawValue: 1)
    let focusedWindow = WindowID(rawValue: 2)

    let result = windowBorderStacking(
      targetWindowID: focusedWindow,
      ownProcessID: 99,
      floatingLevel: NSWindow.Level.floating.rawValue,
      entries: [
        WindowStackEntry(
          windowID: dialog,
          processID: 7,
          layer: NSWindow.Level.normal.rawValue,
          frame: Rect(x: 400, y: 300, width: 640, height: 480)
        ),
        WindowStackEntry(
          windowID: focusedWindow,
          processID: 8,
          layer: NSWindow.Level.normal.rawValue,
          frame: Rect(x: 2, y: 34, width: 2_044, height: 1_354)
        ),
      ]
    )

    #expect(result.activeWindowIsFrontmost == false)
    #expect(result.upperBoundWindowID == nil)
  }

  @Test
  func floatingPictureInPictureBoundsFrontmostBorder() {
    let pictureInPicture = WindowID(rawValue: 1)
    let focusedWindow = WindowID(rawValue: 2)

    let result = windowBorderStacking(
      targetWindowID: focusedWindow,
      ownProcessID: 99,
      floatingLevel: NSWindow.Level.floating.rawValue,
      entries: [
        WindowStackEntry(
          windowID: pictureInPicture,
          processID: 7,
          layer: NSWindow.Level.floating.rawValue,
          frame: Rect(x: 1_400, y: 700, width: 420, height: 390)
        ),
        WindowStackEntry(
          windowID: focusedWindow,
          processID: 7,
          layer: NSWindow.Level.normal.rawValue,
          frame: Rect(x: 2, y: 34, width: 2_044, height: 1_354)
        ),
      ]
    )

    #expect(result.activeWindowIsFrontmost)
    #expect(result.upperBoundWindowID == pictureInPicture)
    #expect(result.upperBoundLevel == NSWindow.Level.floating.rawValue)
  }

  @Test
  func backmostFloatingOccluderBoundsBorderBelowEveryFloatingWindow() {
    let frontPictureInPicture = WindowID(rawValue: 1)
    let backPictureInPicture = WindowID(rawValue: 2)
    let ownBorderSurface = WindowID(rawValue: 3)
    let focusedWindow = WindowID(rawValue: 4)

    let result = windowBorderStacking(
      targetWindowID: focusedWindow,
      ownProcessID: 99,
      floatingLevel: NSWindow.Level.floating.rawValue,
      entries: [
        WindowStackEntry(
          windowID: frontPictureInPicture,
          processID: 7,
          layer: NSWindow.Level.floating.rawValue,
          frame: Rect(x: 200, y: 200, width: 400, height: 300)
        ),
        WindowStackEntry(
          windowID: backPictureInPicture,
          processID: 8,
          layer: NSWindow.Level.floating.rawValue,
          frame: Rect(x: 900, y: 600, width: 400, height: 300)
        ),
        WindowStackEntry(
          windowID: ownBorderSurface,
          processID: 99,
          layer: NSWindow.Level.floating.rawValue,
          frame: Rect(x: 2, y: 34, width: 20, height: 1_354)
        ),
        WindowStackEntry(
          windowID: focusedWindow,
          processID: 7,
          layer: NSWindow.Level.normal.rawValue,
          frame: Rect(x: 2, y: 34, width: 2_044, height: 1_354)
        ),
      ]
    )

    #expect(result.activeWindowIsFrontmost)
    #expect(result.upperBoundWindowID == backPictureInPicture)
  }

  @Test
  func higherLevelWindowNeedsNoExplicitFloatingUpperBound() {
    let systemWindow = WindowID(rawValue: 1)
    let focusedWindow = WindowID(rawValue: 2)

    let result = windowBorderStacking(
      targetWindowID: focusedWindow,
      ownProcessID: 99,
      floatingLevel: NSWindow.Level.floating.rawValue,
      entries: [
        WindowStackEntry(
          windowID: systemWindow,
          processID: 7,
          layer: NSWindow.Level.statusBar.rawValue,
          frame: Rect(x: 0, y: 0, width: 2_560, height: 30)
        ),
        WindowStackEntry(
          windowID: focusedWindow,
          processID: 8,
          layer: NSWindow.Level.normal.rawValue,
          frame: Rect(x: 2, y: 34, width: 2_044, height: 1_354)
        ),
      ]
    )

    #expect(result.activeWindowIsFrontmost)
    #expect(result.upperBoundWindowID == nil)
  }

  @Test
  func offscreenAuxiliaryWindowCannotDemotePictureInPictureBorder() {
    let pictureInPicture = WindowID(rawValue: 1)
    let parkedAuxiliaryWindow = WindowID(rawValue: 2)
    let focusedWindow = WindowID(rawValue: 3)
    let monitor = Rect(x: 0, y: 0, width: 2_560, height: 1_440)

    let result = windowBorderStacking(
      targetWindowID: focusedWindow,
      ownProcessID: 99,
      floatingLevel: NSWindow.Level.floating.rawValue,
      entries: [
        WindowStackEntry(
          windowID: pictureInPicture,
          processID: 7,
          layer: NSWindow.Level.floating.rawValue,
          frame: Rect(x: 1_819, y: 981, width: 418, height: 390)
        ),
        WindowStackEntry(
          windowID: parkedAuxiliaryWindow,
          processID: 8,
          layer: NSWindow.Level.normal.rawValue,
          frame: Rect(x: 4_283, y: 469, width: 360, height: 287)
        ),
        WindowStackEntry(
          windowID: focusedWindow,
          processID: 8,
          layer: NSWindow.Level.normal.rawValue,
          frame: Rect(x: 514, y: 34, width: 2_042, height: 1_354)
        ),
      ],
      monitorFrames: [monitor]
    )

    #expect(result.activeWindowIsFrontmost)
    #expect(result.upperBoundWindowID == pictureInPicture)
    #expect(result.upperBoundLevel == NSWindow.Level.floating.rawValue)
  }

  @Test
  func untrackedSameProcessAuxiliaryCannotDemotePictureInPictureBorder() {
    let pictureInPicture = WindowID(rawValue: 1)
    let auxiliaryWindow = WindowID(rawValue: 2)
    let focusedWindow = WindowID(rawValue: 3)
    let monitor = Rect(x: 0, y: 0, width: 2_560, height: 1_440)

    let result = windowBorderStacking(
      targetWindowID: focusedWindow,
      ownProcessID: 99,
      floatingLevel: NSWindow.Level.floating.rawValue,
      entries: [
        WindowStackEntry(
          windowID: pictureInPicture,
          processID: 8,
          layer: NSWindow.Level.floating.rawValue,
          frame: Rect(x: 357, y: 730, width: 418, height: 390)
        ),
        WindowStackEntry(
          windowID: auxiliaryWindow,
          processID: 8,
          layer: NSWindow.Level.normal.rawValue,
          frame: Rect(x: 2_200, y: 469, width: 360, height: 287)
        ),
        WindowStackEntry(
          windowID: focusedWindow,
          processID: 8,
          layer: NSWindow.Level.normal.rawValue,
          frame: Rect(x: 514, y: 34, width: 2_042, height: 1_354)
        ),
      ],
      monitorFrames: [monitor]
    )

    #expect(result.activeWindowIsFrontmost)
    #expect(result.upperBoundWindowID == pictureInPicture)
    #expect(result.upperBoundLevel == NSWindow.Level.floating.rawValue)
  }

  @Test
  func trackedSameProcessDialogStaysAboveSelectedWindowBorder() {
    let dialog = WindowID(rawValue: 1)
    let focusedWindow = WindowID(rawValue: 2)
    let monitor = Rect(x: 0, y: 0, width: 2_560, height: 1_440)

    let result = windowBorderStacking(
      targetWindowID: focusedWindow,
      ownProcessID: 99,
      floatingLevel: NSWindow.Level.floating.rawValue,
      entries: [
        WindowStackEntry(
          windowID: dialog,
          processID: 8,
          layer: NSWindow.Level.normal.rawValue,
          frame: Rect(x: 900, y: 400, width: 640, height: 480)
        ),
        WindowStackEntry(
          windowID: focusedWindow,
          processID: 8,
          layer: NSWindow.Level.normal.rawValue,
          frame: Rect(x: 514, y: 34, width: 2_042, height: 1_354)
        ),
      ],
      monitorFrames: [monitor],
      knownWindowIDs: [dialog, focusedWindow]
    )

    #expect(result.activeWindowIsFrontmost == false)
    #expect(result.upperBoundWindowID == nil)
  }

  @Test
  func normalWindowOnAnotherMonitorCannotDemoteBorder() {
    let otherMonitorWindow = WindowID(rawValue: 1)
    let focusedWindow = WindowID(rawValue: 2)
    let firstMonitor = Rect(x: 0, y: 0, width: 2_560, height: 1_440)
    let secondMonitor = Rect(x: 2_560, y: 0, width: 1_920, height: 1_080)

    let result = windowBorderStacking(
      targetWindowID: focusedWindow,
      ownProcessID: 99,
      floatingLevel: NSWindow.Level.floating.rawValue,
      entries: [
        WindowStackEntry(
          windowID: otherMonitorWindow,
          processID: 7,
          layer: NSWindow.Level.normal.rawValue,
          frame: Rect(x: 2_600, y: 40, width: 1_800, height: 1_000)
        ),
        WindowStackEntry(
          windowID: focusedWindow,
          processID: 8,
          layer: NSWindow.Level.normal.rawValue,
          frame: Rect(x: 514, y: 34, width: 2_042, height: 1_354)
        ),
      ],
      monitorFrames: [firstMonitor, secondMonitor]
    )

    #expect(result.activeWindowIsFrontmost)
    #expect(result.upperBoundWindowID == nil)
  }
}
