import AppKit
import DefiModel
import Testing

@testable import DefiMacOS

struct PlatformEventTests {
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
    #expect(keyboardTarget.windowID == nil)
    #expect(keyboardTarget.processID == 900)
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

    let result = frontmostBorderOccludingWindowID(
      in: [
        NormalWindowStackEntry(
          windowID: auxiliaryWindow,
          frame: Rect(x: 8, y: 40, width: 66, height: 20)
        ),
        NormalWindowStackEntry(
          windowID: focusedWindow,
          frame: Rect(x: 2, y: 34, width: 2_044, height: 1_354)
        ),
      ]
    )

    #expect(result == focusedWindow)
  }

  @Test
  func frontmostBorderOccluderKeepsDialogsAheadOfFocusedWindow() {
    let dialog = WindowID(rawValue: 1)
    let focusedWindow = WindowID(rawValue: 2)

    let result = frontmostBorderOccludingWindowID(
      in: [
        NormalWindowStackEntry(
          windowID: dialog,
          frame: Rect(x: 400, y: 300, width: 640, height: 480)
        ),
        NormalWindowStackEntry(
          windowID: focusedWindow,
          frame: Rect(x: 2, y: 34, width: 2_044, height: 1_354)
        ),
      ]
    )

    #expect(result == dialog)
  }
}
