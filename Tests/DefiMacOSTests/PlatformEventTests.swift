import AppKit
import ApplicationServices
import DefiModel
import Foundation
import Testing

@testable import DefiMacOS

private final class TestAXElement: @unchecked Sendable {
  let value: AXUIElement

  init(_ value: AXUIElement) {
    self.value = value
  }
}

struct PlatformEventTests {
  @Test
  func animationDisplayBarrierKeepsEveryRequestedAvailableDisplay() {
    #expect(
      resolvedAnimationDisplayIDs(
        requested: [1, 2],
        available: [1, 2, 3]
      ) == [1, 2]
    )
    #expect(
      resolvedAnimationDisplayIDs(
        requested: [9],
        available: [3]
      ) == [3]
    )
  }

  @Test
  func preparedAXRelationshipsResolveTransientOwners() {
    let ownerID = WindowID(rawValue: 1)
    let parentChildID = WindowID(rawValue: 2)
    let sheetChildID = WindowID(rawValue: 3)
    let owner = AXUIElementCreateApplication(101)
    let parentChild = AXUIElementCreateApplication(102)
    let sheetChild = AXUIElementCreateApplication(103)

    #expect(
      transientOwnerWindowIDsFromPreparedRelationships(
        elements: [
          ownerID: owner,
          parentChildID: parentChild,
          sheetChildID: sheetChild,
        ],
        parents: [parentChildID: owner],
        sheets: [ownerID: [sheetChild]]
      ) == [parentChildID: ownerID, sheetChildID: ownerID]
    )
  }

  @Test
  func forceTiledWindowIsAnOwnerCandidateWithoutPreparedRelationship() {
    let childID = WindowID(rawValue: 1)
    let unrelatedID = WindowID(rawValue: 2)
    let child = Window(
      id: childID,
      appID: "app",
      title: "Panel",
      frame: Rect(x: 0, y: 0, width: 500, height: 700),
      forceTiling: true
    )
    let unrelated = Window(
      id: unrelatedID,
      appID: "app",
      title: "Window",
      frame: Rect(x: 0, y: 0, width: 500, height: 700)
    )

    #expect(
      transientOwnerResolutionCandidateIDs(
        windows: [child, unrelated],
        relationshipChildIDs: []
      ) == [childID]
    )
  }

  @Test
  func topologyEventsRevalidateTransientOwnersFromAffectedProcesses() {
    let affectedChild = WindowID(rawValue: 1)
    let unaffectedChild = WindowID(rawValue: 2)

    #expect(
      transientOwnerWindowIDsToRevalidate(
        candidateIDs: [affectedChild, unaffectedChild],
        processIDs: [affectedChild: 100, unaffectedChild: 200],
        topologyProcessIDs: [100]
      ) == [affectedChild]
    )
  }

  @Test
  func unresolvedTransientOwnershipKeepsRetryingWithBoundedBackoff() {
    #expect(transientOwnerResolutionRetryDelay(afterAttempt: 1) == 0)
    #expect(transientOwnerResolutionRetryDelay(afterAttempt: 2) == 1)
    #expect(transientOwnerResolutionRetryDelay(afterAttempt: 3) == 2)
    #expect(transientOwnerResolutionRetryDelay(afterAttempt: 8) == 5)
    #expect(
      transientOwnerResolutionIsDue(
        ownerKnown: false,
        attempts: 1,
        retryAfter: 12,
        now: 11
      ) == false
    )
    #expect(
      transientOwnerResolutionIsDue(
        ownerKnown: false,
        attempts: 1,
        retryAfter: 12,
        now: 12
      )
    )
    #expect(
      transientOwnerResolutionIsDue(
        ownerKnown: true,
        attempts: 1,
        retryAfter: 12,
        now: 11
      ) == false
    )
    #expect(
      transientOwnerResolutionIsDue(
        ownerKnown: true,
        attempts: 1,
        retryAfter: 12,
        now: 12
      )
    )
  }

  @Test
  func unresolvedTransientOwnershipEventuallyReturnsToIdleCadence() {
    #expect(
      transientOwnerResolutionRetryDeadline(afterAttempt: 7, now: 10) == 15
    )
    #expect(
      transientOwnerResolutionRetryDeadline(afterAttempt: 8, now: 10) == nil
    )
    #expect(
      transientOwnerResolutionIsDue(
        ownerKnown: false,
        attempts: 8,
        retryAfter: nil,
        now: 10
      ) == false
    )
  }

  @Test
  func repeatedNegativeTransientOwnerResolutionEventuallyClearsCachedOwner() {
    #expect(transientOwnerResolutionShouldClearCachedOwner(afterAttempt: 7) == false)
    #expect(transientOwnerResolutionShouldClearCachedOwner(afterAttempt: 8))
  }

  @Test
  func transientOwnerRetryClampsWindowRefreshToItsDeadline() {
    #expect(
      transientOwnerResolutionRefreshInterval(
        retryAfter: [14, 12],
        now: 10
      ) == 2
    )
    #expect(
      transientOwnerResolutionRefreshInterval(
        retryAfter: [9],
        now: 10
      ) == 0
    )
    #expect(
      transientOwnerResolutionRefreshInterval(
        retryAfter: [],
        now: 10
      ) == nil
    )
  }

  @Test @MainActor
  func transientOwnerRetrySchedulesTheWindowListRefresh() {
    let platform = MacOSPlatform()
    platform.eventMonitor = PlatformEventMonitor(handler: { _, _ in })
    let now = ProcessInfo.processInfo.systemUptime
    platform.transientOwnerResolutionRetryAfter[WindowID(rawValue: 42)] = now + 5

    #expect(platform.hasPendingTransientOwnerResolution)
    #expect(platform.recommendedWindowListRefreshInterval > 4)
    #expect(platform.recommendedWindowListRefreshInterval <= 5)
  }

  @Test
  func applicationLifecycleRetriesTopologyAfterDelayedWindowCreation() {
    #expect(
      applicationLifecycleRefreshDelays(for: .application)
        == [50, 150, 350, 700, 1_200, 2_000, 3_500, 5_500, 8_000, 12_000]
    )
    #expect(
      applicationLifecycleRefreshDelays(for: .applicationTerminated)
        == [50, 150, 350, 700, 1_200, 2_000, 3_500, 5_500, 8_000, 12_000]
    )
    #expect(applicationLifecycleRefreshDelays(for: .focus).isEmpty)
  }

  @Test
  func contendedAXTimeoutAccessDoesNotWaitForTheOwner() throws {
    let element = TestAXElement(AXUIElementCreateSystemWide())
    let secondary = TestAXElement(
      AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
    )
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      _ = AXMessagingTimeoutAccess.shared.withTimeout(
        0.05,
        elements: [element.value]
      ) {
        entered.signal()
        release.wait()
        return true
      }
    }
    DispatchQueue.global(qos: .userInitiated).asyncAfter(
      deadline: .now() + 0.15
    ) {
      release.signal()
    }
    #expect(entered.wait(timeout: .now() + 1) == .success)
    let startedAt = ProcessInfo.processInfo.systemUptime
    _ = AXMessagingTimeoutAccess.shared.withTimeout(
      0.05,
      elements: [element.value, secondary.value]
    ) {
      true
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
    #expect(elapsed < 0.1)
  }

  @Test
  func staleFocusRecoveryCannotOverrideNewFocusIntent() {
    #expect(
      focusRecoveryIntentIsCurrent(
        requestGeneration: 8,
        currentGeneration: 8
      )
    )
    #expect(
      !focusRecoveryIntentIsCurrent(
        requestGeneration: 8,
        currentGeneration: 9
      )
    )
  }

  @Test
  func auxiliaryFocusRecoveryLookupIsLatestWins() {
    #expect(
      focusRecoveryResolutionIsCurrent(
        requestGeneration: 4,
        currentGeneration: 4
      )
    )
    #expect(
      !focusRecoveryResolutionIsCurrent(
        requestGeneration: 3,
        currentGeneration: 4
      )
    )
  }

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
      ) == .superseded
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
  func nativeFocusFastPathRequiresKeyboardFocus() {
    var consultedApplication = false
    #expect(
      targetWindowFocusIsConfirmed(true) {
        consultedApplication = true
        return false
      }
    )
    #expect(consultedApplication == false)
    #expect(
      targetWindowFocusIsConfirmed(false) { true }
    )
    #expect(
      targetWindowFocusIsConfirmed(nil) { false } == false
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
      ) == .supersededAfterMutation
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
      result: .supersededAfterMutation,
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

    let failedReplacement = transferredNativeFocusRecovery(
      carried: originalRecovery,
      request: nil,
      result: .failedAfterMutation,
      generationCurrent: true
    )
    #expect(failedReplacement.carried == nil)
    #expect(failedReplacement.recovery == originalRecovery)
  }

  @Test
  func failedMutationRecoveryUsesFallbackWithoutNewerInput() throws {
    let original = NativeFocusRecoveryRequest(
      timestamp: 10,
      excludingWindowID: WindowID(rawValue: 2),
      excludingProcessID: 20,
      fallback: NativeFocusRecoveryFallback(
        windowID: WindowID(rawValue: 1),
        processID: 10
      )
    )
    let request = try #require(
      nativeFocusRecoveryRequestForCompletion(
        original,
        result: .failedAfterMutation,
        explicitFallback: nil
      )
    )

    #expect(request.fallback == original.fallback)
    #expect(request.fallbackOnlyIfNoNewerInput)
    #expect(
      transferredNativeFocusRecovery(
        carried: nil,
        request: request,
        result: .failedAfterMutation,
        generationCurrent: true
      ).recovery == request
    )
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
  func failedActivationDoesNotReportAnUnappliedMutation() {
    #expect(
      !focusMutationStateAfterActivation(
        priorMutationApplied: false,
        activationSucceeded: false
      )
    )
    #expect(
      focusMutationStateAfterActivation(
        priorMutationApplied: true,
        activationSucceeded: false
      )
    )
    #expect(
      focusMutationStateAfterActivation(
        priorMutationApplied: false,
        activationSucceeded: true
      )
    )
  }

  @Test
  func pointerCancellationCannotCancelANewerFocusRequest() {
    #expect(
      focusRequestCanBeCancelled(
        requestGeneration: 4,
        latestGeneration: 4,
        pendingGeneration: nil,
        activeGeneration: 4
      )
    )
    #expect(
      focusRequestCanBeCancelled(
        requestGeneration: 4,
        latestGeneration: 4,
        pendingGeneration: 4,
        activeGeneration: nil
      )
    )
    #expect(
      !focusRequestCanBeCancelled(
        requestGeneration: 4,
        latestGeneration: 5,
        pendingGeneration: nil,
        activeGeneration: 5
      )
    )
  }

  @Test
  func abandonedFocusClearsOnlyItsOwnUnmutatedSuppression() {
    let current = InternalFocusSuppression(
      requestID: 7,
      deadline: 20,
      maximumInputTimestamp: 10
    )

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
        requestID: 7,
        result: .failed
      ) == current
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
        result: .supersededAfterMutation
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
      ) == current
    )
  }

  @Test
  func supersededSuppressionConsumesOnlyThroughReplacementInput() {
    let original = InternalFocusSuppression(
      requestID: 7,
      deadline: 20,
      maximumInputTimestamp: 10
    )
    let extended = extendingInternalFocusSuppression(
      original,
      through: 12,
      deadline: 22
    )

    #expect(extended.maximumInputTimestamp == 12)
    #expect(extended.deadline == 22)
    #expect(
      internalFocusSuppressionConsumesEvent(
        extended,
        suppressedWindowID: WindowID(rawValue: 2),
        latestFocusIntent: .init(
          timestamp: 12,
          source: .mouse(windowID: WindowID(rawValue: 3))
        )
      ) == true
    )
    #expect(
      internalFocusSuppressionConsumesEvent(
        extended,
        suppressedWindowID: WindowID(rawValue: 2),
        latestFocusIntent: .init(
          timestamp: 13,
          source: .mouse(windowID: WindowID(rawValue: 2))
        )
      ) == false
    )
    #expect(
      internalFocusSuppressionConsumesEvent(
        extended,
        suppressedWindowID: WindowID(rawValue: 2),
        latestFocusIntent: nil
      ) == true
    )
    #expect(
      internalFocusSuppressionConsumesEvent(
        extended,
        suppressedWindowID: WindowID(rawValue: 2),
        latestFocusIntent: .init(timestamp: 13, source: .keyboard)
      ) == false
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
  func commandTabBetweenTwoClosesStillWinsFirstRemovalReconciliation() {
    let tracker = UserInputTracker()
    tracker.record(timestamp: 20, closeIntent: true)
    let topologyInputTimestamp = tracker.latestEventTimestamp
    tracker.record(timestamp: 21, focusIntent: .keyboard)
    tracker.record(timestamp: 22, closeIntent: true)
    let input = tracker.snapshot

    #expect(
      userInputOccurredAfterWindowTopology(
        topologyInputTimestamp: topologyInputTimestamp,
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
  func unresolvedBackgroundClickAfterCloseWinsBeforeTopologyNotification() {
    let tracker = UserInputTracker()
    tracker.record(timestamp: 20, closeIntent: true)
    tracker.record(timestamp: 21, focusIntent: .mouse(windowID: nil))
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
  func newFocusPreservesCompletedSuppressionUntilItsDelayedEventArrives() {
    let windowID = WindowID(rawValue: 1)
    let completed = InternalFocusSuppression(
      requestID: 7,
      deadline: 20,
      maximumInputTimestamp: 10,
      isInFlight: false
    )

    #expect(
      focusSuppressionsAfterRecoveryInvalidation(
        [windowID: completed],
        now: 12,
        preservingCompleted: true
      )[windowID] == completed
    )
    #expect(
      focusSuppressionsAfterRecoveryInvalidation(
        [windowID: completed],
        now: 12,
        preservingCompleted: false
      ).isEmpty
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
  func inputAfterRemovedWindowClickCancelsRemovalFocusRecovery() {
    let tracker = UserInputTracker()
    let closingWindowID = WindowID(rawValue: 10)
    tracker.record(
      timestamp: 20,
      focusIntent: .mouse(windowID: closingWindowID)
    )
    let topologyInputTimestamp = tracker.latestEventTimestamp
    tracker.record(timestamp: 21)
    let input = tracker.snapshot

    #expect(
      userInputOccurredAfterWindowTopology(
        topologyInputTimestamp: topologyInputTimestamp,
        latestInputTimestamp: input.latestEventTimestamp,
        latestFocusIntent: input.latestFocusIntent,
        latestCloseIntentTimestamp: input.latestCloseIntent,
        removedWindowIDs: [closingWindowID]
      )
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
  func consecutiveCloseIntentsRemainOneRemovalTransaction() {
    let tracker = UserInputTracker()
    tracker.record(timestamp: 20, closeIntent: true)
    let topologyInputTimestamp = tracker.latestEventTimestamp
    tracker.record(timestamp: 21, closeIntent: true)
    let input = tracker.snapshot

    #expect(
      userInputOccurredAfterWindowTopology(
        topologyInputTimestamp: topologyInputTimestamp,
        latestInputTimestamp: input.latestEventTimestamp,
        latestFocusIntent: input.latestFocusIntent,
        latestCloseIntentTimestamp: input.latestCloseIntent,
        removedWindowIDs: [WindowID(rawValue: 10), WindowID(rawValue: 11)]
      ) == false
    )
  }

  @Test
  func consecutiveCloseButtonClicksOnRemovedWindowsRemainOneTransaction() {
    let tracker = UserInputTracker()
    let firstWindowID = WindowID(rawValue: 10)
    let secondWindowID = WindowID(rawValue: 11)
    tracker.record(
      timestamp: 20,
      focusIntent: .mouse(windowID: firstWindowID)
    )
    let topologyInputTimestamp = tracker.latestEventTimestamp
    tracker.record(
      timestamp: 21,
      focusIntent: .mouse(windowID: secondWindowID)
    )
    let input = tracker.snapshot

    #expect(
      userInputOccurredAfterWindowTopology(
        topologyInputTimestamp: topologyInputTimestamp,
        latestInputTimestamp: input.latestEventTimestamp,
        latestFocusIntent: input.latestFocusIntent,
        latestCloseIntentTimestamp: input.latestCloseIntent,
        removedWindowIDs: [firstWindowID, secondWindowID]
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
  func explicitCancellationFallbackRequiresNoNewerInput() {
    let request = NativeFocusRecoveryRequest(
      timestamp: 10,
      excludingWindowID: WindowID(rawValue: 2),
      excludingProcessID: 20,
      fallback: NativeFocusRecoveryFallback(
        windowID: WindowID(rawValue: 1),
        processID: 10
      ),
      fallbackOnlyIfNoNewerInput: true
    )

    #expect(
      nativeFocusRecoveryFallbackTarget(
        request,
        latestEventTimestamp: 10
      )?.windowID == WindowID(rawValue: 1)
    )
    #expect(
      nativeFocusRecoveryFallbackTarget(
        request,
        latestEventTimestamp: 11
      ) == nil
    )
  }

  @Test
  func eventTapReenableInvalidatesGuardedInput() {
    let tracker = UserInputTracker()
    tracker.record(timestamp: 10, focusIntent: .keyboard)
    tracker.invalidate(at: 10)

    #expect(tracker.latestEventTimestamp > 10)
    #expect(tracker.snapshot.latestFocusIntent == nil)
    #expect(tracker.focusRecoveryTarget(after: 10) == nil)

    let pointerTracker = PointerMotionTracker()
    pointerTracker.record(timestamp: 10)
    pointerTracker.invalidate(at: 10)
    #expect(pointerTracker.latestTimestamp > 10)
  }

  @Test
  func acceptedKeyboardFocusConsumesItsIntent() {
    let tracker = UserInputTracker()
    tracker.record(timestamp: 21, focusIntent: .keyboard)

    tracker.consumeFocusIntent(at: 21)

    #expect(tracker.snapshot.latestFocusIntent == nil)
    #expect(tracker.latestEventTimestamp == 21)
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
  func mouseFocusRecoveryPrefersObservedTargetOverSystemSurface() throws {
    let tracker = UserInputTracker()
    tracker.record(
      timestamp: 11,
      focusIntent: .mouse(windowID: WindowID(rawValue: 42))
    )
    tracker.recordObservedFocus(
      windowID: WindowID(rawValue: 99),
      processID: 900
    )

    let target = try #require(tracker.focusRecoveryTarget(after: 10))
    #expect(target.windowID == WindowID(rawValue: 99))
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
  func primaryMouseButtonDownCreatesFocusIntent() {
    let windowID = WindowID(rawValue: 42)

    #expect(
      mouseFocusIntent(eventType: .leftMouseDown, rawWindowID: 42)
        == .mouse(windowID: windowID)
    )
    #expect(mouseFocusIntent(eventType: .rightMouseDown, rawWindowID: 42) == nil)
    #expect(mouseFocusIntent(eventType: .otherMouseDown, rawWindowID: 42) == nil)
    #expect(mouseFocusIntent(eventType: .scrollWheel, rawWindowID: 42) == nil)
  }

  @Test
  func momentumScrollDoesNotSupersedeKeyboardFocus() {
    #expect(eventTracksGeneralUserInput(.scrollWheel, scrollMomentumPhase: 0))
    #expect(!eventTracksGeneralUserInput(.scrollWheel, scrollMomentumPhase: 1))
    #expect(!eventTracksGeneralUserInput(.scrollWheel, scrollMomentumPhase: 2))
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
      ) > 0.007
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
  func throttledPointerMotionStillHasTrailingDelivery() {
    #expect(
      pointerMotionDeliveryPlan(
        rawWindowChanged: false,
        refreshDelay: 0.007,
        deliveryScheduled: false
      ) == PointerMotionDeliveryPlan(
        shouldSchedule: true,
        delay: 0.007
      )
    )
    #expect(
      pointerMotionDeliveryPlan(
        rawWindowChanged: false,
        refreshDelay: 0.007,
        deliveryScheduled: true
      ) == PointerMotionDeliveryPlan(
        shouldSchedule: false,
        delay: 0.007
      )
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
  func applicationInventoryWatchdogPreservesPollingFallback() {
    #expect(
      applicationInventoryRefreshInterval(
        reliableLifecycleObservation: true
      ) == 30
    )
    #expect(
      applicationInventoryRefreshInterval(
        reliableLifecycleObservation: false
      ) == 0.3
    )
  }

  @Test
  func reliableObservationWatchdogsWaitForIdleButFallbacksStayImmediate() {
    #expect(
      desktopSnapshotRefreshInterval(reliableDesktopObservation: true) == 30
    )
    #expect(
      desktopSnapshotRefreshInterval(reliableDesktopObservation: false) == 0.3
    )
    #expect(
      observationWatchdogRefreshIsReady(
        due: true,
        interval: 30,
        userInputIdleDuration: 0.5
      ) == false
    )
    #expect(
      observationWatchdogRefreshIsReady(
        due: true,
        interval: 30,
        userInputIdleDuration: 1
      )
    )
    #expect(
      observationWatchdogRefreshIsReady(
        due: true,
        interval: 0.3,
        userInputIdleDuration: 0
      )
    )
  }

  @Test
  func unreliableCoverageImmediatelyClampsSnapshotWatchdogs() {
    #expect(
      boundedSnapshotRefreshDeadline(
        current: 15,
        now: 10,
        interval: 0.3,
        reset: false
      ) == 10.3
    )
    #expect(
      boundedSnapshotRefreshDeadline(
        current: 10.1,
        now: 10,
        interval: 0.3,
        reset: false
      ) == 10.1
    )
    #expect(
      boundedSnapshotRefreshDeadline(
        current: 10.1,
        now: 10,
        interval: 5,
        reset: true
      ) == 15
    )
    #expect(
      boundedSnapshotRefreshDeadline(
        current: 9.9,
        now: 10,
        interval: 0.3,
        reset: true
      ) == 10.3
    )
  }

  @Test
  func unmatchedWindowsGetThreeShortRetriesThenUseWatchdog() {
    #expect(unmatchedWindowRetryIsPending(attempts: 0))
    #expect(unmatchedWindowRetryIsPending(attempts: 2))
    #expect(unmatchedWindowRetryIsPending(attempts: 3) == false)
    #expect(
      windowListRefreshInterval(
        hasPendingShortRetry: true,
        reliableTopologyObservation: true
      ) == 0.1
    )
    #expect(
      windowListRefreshInterval(
        hasPendingShortRetry: false,
        reliableTopologyObservation: true
      ) == 30
    )
    #expect(
      windowListRefreshInterval(
        hasPendingShortRetry: false,
        reliableTopologyObservation: false
      ) == 0.3
    )
  }

  @Test
  func failedWindowListReadsGetThreeShortRetriesThenClearOnSuccess() {
    let initialFailure = updatedWindowListReadRetryAttempts(
      previousAttempts: nil,
      readSucceeded: false
    )
    let firstRetryFailure = updatedWindowListReadRetryAttempts(
      previousAttempts: initialFailure,
      readSucceeded: false
    )
    let secondRetryFailure = updatedWindowListReadRetryAttempts(
      previousAttempts: firstRetryFailure,
      readSucceeded: false
    )
    let thirdRetryFailure = updatedWindowListReadRetryAttempts(
      previousAttempts: secondRetryFailure,
      readSucceeded: false
    )

    #expect(initialFailure == 0)
    #expect(firstRetryFailure == 1)
    #expect(secondRetryFailure == 2)
    #expect(thirdRetryFailure == 3)
    #expect(
      updatedWindowListReadRetryAttempts(
        previousAttempts: thirdRetryFailure,
        readSucceeded: false
      ) == 3
    )
    #expect(
      updatedWindowListReadRetryAttempts(
        previousAttempts: thirdRetryFailure,
        readSucceeded: true
      ) == nil
    )
  }

  @Test @MainActor
  func failedWindowListReadSchedulesShortRetry() {
    let platform = MacOSPlatform()
    platform.windowListReadRetryAttemptsByProcess[101] = 0

    #expect(platform.recommendedWindowListRefreshInterval == 0.1)
  }

  @Test @MainActor
  func failedCGWindowInventorySchedulesShortRetry() {
    let platform = MacOSPlatform()
    platform.cgWindowInventoryRetryAttempts = 0

    #expect(platform.recommendedWindowListRefreshInterval == 0.1)
  }

  @Test @MainActor
  func retainedWindowSchedulesShortRetryBeforeGraceExpires() {
    let platform = MacOSPlatform()
    platform.retainedWindowIDs = [WindowID(rawValue: 42)]

    #expect(platform.recommendedWindowListRefreshInterval == 0.1)
  }

  @Test
  func partialNotificationBatchRollsBackSuccessfulRegistrations() {
    var removed: [String] = []

    let registered = registerNotificationBatch(
      notifications: ["moved", "resized"],
      add: { $0 == "moved" ? .success : .cannotComplete },
      remove: { removed.append($0) }
    )

    #expect(registered == false)
    #expect(removed == ["moved"])
  }

  @Test
  func failedNotificationObservationIsQuarantinedUntilProcessTerminates() {
    let failedProcessID: pid_t = 101
    let quarantined = updatedNotificationObservationFailures(
      [],
      activeProcessIDs: [failedProcessID],
      failedProcessID: failedProcessID
    )

    #expect(quarantined == [failedProcessID])
    #expect(
      updatedNotificationObservationFailures(
        quarantined,
        activeProcessIDs: [failedProcessID]
      ) == [failedProcessID]
    )
    #expect(
      updatedNotificationObservationFailures(
        quarantined,
        activeProcessIDs: []
      ).isEmpty
    )
  }

  @Test
  func applicationObserverIsPreparedBeforeInitialWindowDiscovery() {
    var actions: [String] = []

    let windows = applicationWindowsAfterPreparingTopologyObservation(
      prepareObservation: { actions.append("observe") },
      copyWindows: {
        actions.append("copy")
        return []
      }
    )

    #expect(actions == ["observe", "copy"])
    #expect(windows?.isEmpty == true)
  }

  @Test
  func topologyCoverageIncludesFirstSeenMinimizedWindows() {
    let current = AXUIElementCreateApplication(101)
    let minimized = AXUIElementCreateApplication(202)
    let firstSeenMinimized = AXUIElementCreateApplication(303)
    let unmanagedAuxiliary = AXUIElementCreateApplication(404)

    let required = requiredTopologyWindows(
      applicationWindows: [
        7: [current, minimized, firstSeenMinimized, unmanagedAuxiliary]
      ],
      managedWindows: [7: [current]],
      previouslyManagedWindows: [7: [current, minimized]],
      minimizedWindows: [7: [minimized, firstSeenMinimized]]
    )[7] ?? []

    #expect(required.count == 3)
    #expect(required.contains(where: { CFEqual($0, current) }))
    #expect(required.contains(where: { CFEqual($0, minimized) }))
    #expect(required.contains(where: { CFEqual($0, firstSeenMinimized) }))
    #expect(
      required.contains(where: { CFEqual($0, unmanagedAuxiliary) }) == false
    )
  }

  @Test
  func topologyCoverageRetainsUnobservedWindowUntilResolvedOrRemoved() {
    let current = AXUIElementCreateApplication(101)
    let minimized = AXUIElementCreateApplication(202)

    let unresolved = topologyWindowsRequiringCoverage(
      requested: [current],
      previouslyRequired: [current, minimized],
      observed: [current],
      applicationWindows: [current, minimized]
    )
    #expect(unresolved.count == 2)
    #expect(unresolved.contains(where: { CFEqual($0, minimized) }))

    let resolved = topologyWindowsRequiringCoverage(
      requested: [current],
      previouslyRequired: unresolved,
      observed: [current, minimized],
      applicationWindows: [current, minimized]
    )
    #expect(resolved.count == 1)
    #expect(resolved.contains(where: { CFEqual($0, current) }))

    let removed = topologyWindowsRequiringCoverage(
      requested: [current],
      previouslyRequired: unresolved,
      observed: [current],
      applicationWindows: [current]
    )
    #expect(removed.count == 1)
    #expect(removed.contains(where: { CFEqual($0, current) }))
  }

  @Test
  func frameCoverageIncludesFirstSeenTransientGeometry() {
    let current = AXUIElementCreateApplication(101)
    let transient = AXUIElementCreateApplication(202)
    let neverManaged = AXUIElementCreateApplication(303)

    let required = frameWindowsRequiringCoverage(
      requested: [current],
      transientGeometry: [transient, neverManaged],
      applicationWindows: [current, transient, neverManaged]
    )
    #expect(required.count == 3)
    #expect(required.contains(where: { CFEqual($0, current) }))
    #expect(required.contains(where: { CFEqual($0, transient) }))
    #expect(required.contains(where: { CFEqual($0, neverManaged) }))

    let noLongerTransient = frameWindowsRequiringCoverage(
      requested: [current],
      transientGeometry: [],
      applicationWindows: [current, transient, neverManaged]
    )
    #expect(noLongerTransient.count == 1)
    #expect(noLongerTransient.contains(where: { CFEqual($0, current) }))
  }

  @Test @MainActor
  func explicitWindowFrameRefreshTargetsOwningProcess() {
    let platform = MacOSPlatform()
    let windowID = WindowID(rawValue: 42)
    platform.processIDs[windowID] = 101

    platform.requestFrameRefresh(for: windowID)

    #expect(platform.frameEventPending)
    #expect(platform.pendingFrameProcessIDs == [101])
    #expect(platform.observedFrameEventWindowIDs == [windowID])
    #expect(!platform.pendingFrameRequiresFullSnapshot)
  }

  @Test @MainActor
  func unknownWindowFrameRefreshFallsBackToFullSnapshot() {
    let platform = MacOSPlatform()

    platform.requestFrameRefresh(for: WindowID(rawValue: 42))

    #expect(platform.frameEventPending)
    #expect(platform.pendingFrameProcessIDs.isEmpty)
    #expect(platform.observedFrameEventWindowIDs == [WindowID(rawValue: 42)])
    #expect(platform.pendingFrameRequiresFullSnapshot)
  }

  @Test @MainActor
  func resumingFrameNotificationsForcesFreshProcessReads() {
    let platform = MacOSPlatform()
    let eventMonitor = PlatformEventMonitor(handler: { _, _ in })
    platform.eventMonitor = eventMonitor
    platform.lastSnapshotProcessIDs = [101, 202]
    let windowID = WindowID(rawValue: 42)
    platform.processIDs[windowID] = 101
    platform.frameCommitExpectations[windowID] = FrameCommitExpectation(
      from: Rect(x: 0, y: 0, width: 100, height: 100),
      target: Rect(x: 100, y: 0, width: 100, height: 100),
      issuedAt: 1,
      deadline: 2,
      observedAt: nil
    )
    platform.setFrameNotificationsEnabled(false)
    eventMonitor.recordSuppressedFrameNotification(processID: 202)
    eventMonitor.recordSuppressedFrameNotification(processID: nil)

    platform.setFrameNotificationsEnabled(true)

    #expect(platform.frameEventPending)
    #expect(platform.pendingFrameProcessIDs == [101, 202])
    #expect(platform.pendingFrameRequiresFullSnapshot)
    #expect(platform.observedFrameEventWindowIDs == [windowID])
  }

  @Test
  func terminatedApplicationForcesInventoryRefreshEvenWithPID() {
    #expect(
      windowSnapshotInvalidation(
        for: .applicationTerminated,
        processID: 42
      ) == .full
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
    #expect(mouseUp.synchronization == nil)
    #expect(eventEndsMouseFocusInteraction(.leftMouseUp))
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
    #expect(eventEndsMouseFocusInteraction(.leftMouseUp))
    #expect(secondMouseUp == MouseGestureEventNormalizer.Actions())
  }

  @Test
  func mouseReleaseWaitsForEveryHeldButton() {
    var normalizer = MouseGestureEventNormalizer()
    _ = normalizer.actions(for: .leftMouseDown)
    _ = normalizer.actions(for: .rightMouseDown, buttonNumber: 1)

    let leftUp = normalizer.actions(for: .leftMouseUp)
    #expect(!leftUp.endsFocusInteraction)

    let rightUp = normalizer.actions(for: .rightMouseUp, buttonNumber: 1)
    #expect(rightUp.endsFocusInteraction)
  }

  @Test
  func mouseReleaseMustMatchInitiatingButton() {
    var normalizer = MouseGestureEventNormalizer()
    _ = normalizer.actions(for: .leftMouseDown)

    let unrelatedRelease = normalizer.actions(
      for: .otherMouseUp,
      buttonNumber: 2
    )
    #expect(unrelatedRelease == MouseGestureEventNormalizer.Actions())
    #expect(
      normalizer.actions(for: .leftMouseUp).endsFocusInteraction
    )
  }

  @Test
  func everyMouseButtonReleaseEndsFocusInteraction() {
    #expect(eventEndsMouseFocusInteraction(.leftMouseUp))
    #expect(eventEndsMouseFocusInteraction(.rightMouseUp))
    #expect(eventEndsMouseFocusInteraction(.otherMouseUp))
    #expect(!eventEndsMouseFocusInteraction(.leftMouseDown))
    #expect(!eventEndsMouseFocusInteraction(.rightMouseDown))
    #expect(!eventEndsMouseFocusInteraction(.otherMouseDown))
  }

  @Test
  func everyMouseButtonDownStartsFocusInteraction() {
    #expect(eventStartsMouseFocusInteraction(.leftMouseDown))
    #expect(eventStartsMouseFocusInteraction(.rightMouseDown))
    #expect(eventStartsMouseFocusInteraction(.otherMouseDown))
    #expect(!eventStartsMouseFocusInteraction(.leftMouseUp))
    #expect(!eventStartsMouseFocusInteraction(.rightMouseUp))
    #expect(!eventStartsMouseFocusInteraction(.otherMouseUp))
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
  func resettingHeldMouseGestureRequestsSyntheticRelease() {
    var normalizer = MouseGestureEventNormalizer()
    _ = normalizer.actions(for: .leftMouseDown)

    let resetHeldButtons = normalizer.reset()
    let resetEmptyGesture = normalizer.reset()
    #expect(resetHeldButtons)
    #expect(!resetEmptyGesture)
    #expect(
      normalizer.actions(for: .leftMouseUp)
        == MouseGestureEventNormalizer.Actions()
    )
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
  func borderRevealRequiresCurrentFocusAndExactStacking() {
    let windowID = WindowID(rawValue: 1)
    let stacking = WindowBorderStacking(
      targetWindowID: windowID,
      activeWindowIsFrontmost: true,
      upperBoundWindowID: nil,
      upperBoundLevel: nil
    )

    #expect(
      windowBorderStackingIsReadyForReveal(
        stacking,
        selectedWindowID: windowID,
        activeWindowID: windowID,
        nativeFocusedWindowID: windowID
      )
    )
    #expect(
      windowBorderStackingIsReadyForReveal(
        .inactive(for: windowID),
        selectedWindowID: windowID,
        activeWindowID: windowID,
        nativeFocusedWindowID: windowID
      )
    )
    #expect(
      windowBorderStackingIsReadyForReveal(
        stacking,
        selectedWindowID: windowID,
        activeWindowID: WindowID(rawValue: 2),
        nativeFocusedWindowID: windowID
      ) == false
    )
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
