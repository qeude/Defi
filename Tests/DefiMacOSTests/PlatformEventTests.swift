import DefiRuntime
import AppKit
import ApplicationServices
import DefiModel
import Foundation
import Testing
import Synchronization

@testable import DefiMacOS

private final class TestAXElement: @unchecked Sendable {
  let value: AXUIElement

  init(_ value: AXUIElement) {
    self.value = value
  }
}

struct PlatformEventTests {
  @Test @NavigationActor
  func fullscreenRetiresQueuedFrameAndCursorCompletionsEvenWithIdleWriter() {
    let platform = MacOSPlatform()
    let frameGeneration = platform.frameSubmissionGeneration
    let warpGeneration = platform.cursorWarpGeneration.withLock { $0 }
    #expect(!platform.hasPendingFrameWrites)
    platform.updateNativeFullscreenWindowIDs([WindowID(rawValue: 42)])
    #expect(platform.frameSubmissionGeneration != frameGeneration)
    #expect(platform.cursorWarpGeneration.withLock { $0 } != warpGeneration)
    let nextWarpGeneration = platform.cursorWarpGeneration.withLock { $0 }
    platform.invalidateFocusRecovery()
    #expect(platform.cursorWarpGeneration.withLock { $0 } != nextWarpGeneration)
  }

  @Test @NavigationActor
  func navigationSupersedesOlderFocusRecoveryButKeepsCompletedEchoSuppression() {
    let platform = MacOSPlatform()
    let window = WindowID(rawValue: 7)
    platform.internalFocusSuppressions[window] = InternalFocusSuppression(
      requestID: 1,
      deadline: ProcessInfo.processInfo.systemUptime + 2,
      maximumInputTimestamp: 0,
      completedAt: ProcessInfo.processInfo.systemUptime
    )
    let olderRequestGeneration = platform.focusRecoveryIntentGeneration
    platform.supersedeFocusRecovery()
    #expect(!focusRecoveryIntentIsCurrent(
      requestGeneration: olderRequestGeneration,
      currentGeneration: platform.focusRecoveryIntentGeneration
    ))
    #expect(platform.internalFocusSuppressions[window] != nil)
  }

  @Test @MainActor
  func delayedTapPresentationDoesNotInvalidateNewerInput() async {
    let platform = await MacOSPlatform()
    await platform.invalidateInputAfterEventTapReenabled(at: 10)
    platform.userInputTracker.record(timestamp: 11, focusIntent: .keyboard)
    platform.pointerMotionTracker.record(timestamp: 11)
    platform.presentInvalidateInputAfterEventTapReenabled(at: 10)
    #expect(platform.userInputTracker.latestEventTimestamp == 11)
    #expect(platform.pointerMotionTracker.latestTimestamp == 11)
  }

  @Test
  func activationOnlyQueriesFrontmostForLiveIntentAndRejectsSupersededReads() {
    let tracker = UserInputTracker()
    var queries = 0
    func frontmost() -> pid_t? {
      queries += 1
      return 20
    }
    #expect(tracker.pendingApplicationActivation(frontmostProcessID: frontmost(), at: 10) == nil)
    #expect(queries == 0)
    tracker.recordApplicationActivation(processID: 20, at: 10)
    #expect(tracker.pendingApplicationActivation(frontmostProcessID: frontmost(), at: 13) == nil)
    #expect(queries == 0)
    tracker.recordApplicationActivation(processID: 20, at: 14)
    #expect(tracker.pendingApplicationActivation(frontmostProcessID: frontmost(), at: 15)?.processID == 20)
    #expect(queries == 1)
    func supersededFrontmost() -> pid_t? {
      tracker.recordApplicationActivation(processID: 30, at: 15.5)
      return 20
    }
    #expect(tracker.pendingApplicationActivation(frontmostProcessID: supersededFrontmost(), at: 15) == nil)
    #expect(tracker.pendingApplicationActivation(frontmostProcessID: 30, at: 16)?.processID == 30)
  }

  @Test(arguments: [0.0, 2.1, 60.0])
  func applicationActivationResolvesOnceFrontmostCatchesUpWhateverTheClickAge(clickAge: TimeInterval) {
    let tracker = UserInputTracker()
    tracker.record(timestamp: 100 - clickAge, focusIntent: .mouse(windowID: WindowID(rawValue: 1)))
    tracker.consumeFocusIntent(at: 100 - clickAge)
    tracker.recordApplicationActivation(processID: 20, at: 100)
    #expect(tracker.snapshot.activatedProcessID == 20)
    #expect(tracker.pendingApplicationActivation(frontmostProcessID: 42, at: 100.1) == nil)
    #expect(tracker.pendingApplicationActivation(frontmostProcessID: 20, at: 100.2)?.processID == 20)
  }

  @Test(arguments: [9.0, 10.0, 10.1])
  func capturedCommandDuringActivationLookupRevalidatesResult(commandTimestamp: TimeInterval) {
    let tracker = UserInputTracker()
    tracker.recordApplicationActivation(processID: 20, at: 10)
    func frontmost() -> pid_t? {
      tracker.recordCapturedCommand(at: commandTimestamp)
      return 20
    }
    let activation = tracker.pendingApplicationActivation(
      frontmostProcessID: frontmost(), at: 10.2
    )
    #expect(activation?.processID == (commandTimestamp < 10 ? 20 : nil))
    #expect((tracker.snapshot.applicationActivation != nil) == (commandTimestamp < 10))
  }

  @Test
  func delayedActivationIgnoresPointerActivityButNotNewFocusIntent() {
    let tracker = UserInputTracker()
    tracker.record(timestamp: 10.1)
    #expect(delayedApplicationActivationIsCurrent(startedAt: 10, input: tracker.snapshot))
    tracker.record(timestamp: 10.2, focusIntent: .mouse(windowID: nil))
    #expect(!delayedApplicationActivationIsCurrent(startedAt: 10, input: tracker.snapshot))
    let closingTracker = UserInputTracker()
    closingTracker.record(timestamp: 10.1, closeIntent: true)
    #expect(!delayedApplicationActivationIsCurrent(
      startedAt: 10, input: closingTracker.snapshot
    ))
  }

  @Test(arguments: [9.0, 10.0, 10.1])
  func delayedActivationRejectsNewerCapturedCommand(commandTimestamp: TimeInterval) {
    let tracker = UserInputTracker()
    tracker.recordCapturedCommand(at: commandTimestamp)
    tracker.record(timestamp: 10.2)
    #expect(delayedApplicationActivationIsCurrent(
      startedAt: 10, input: tracker.snapshot
    ) == (commandTimestamp <= 10))
  }

  @Test @NavigationActor
  func sessionChangeDiscardsCachedAXConnectionsBeforeNextDiscovery() {
    let platform = MacOSPlatform()
    let engine = platform.snapshotEngine
    let stale = AXUIElementCreateApplication(42)
    engine.applications = [42: stale]
    engine.lastApplicationWindowElements = [42: [stale]]
    engine.unmatchedWindowElementsByProcess = [42: [stale]]
    engine.windowListReadRetryAttemptsByProcess = [42: 3]
    engine.hasCompletedWindowSnapshot = true
    engine.elements = [WindowID(rawValue: 1): stale]
    engine.recordObservation(.windowCreated, processID: 42, createdElement: stale)
    platform.invalidateStateForDesktopSessionChange()
    // A snapshot already running during suspension may still publish its caches.
    engine.lastApplicationWindowElements = [42: [stale]]
    let observations = engine.consumeObservations()
    #expect(observations.createdElements.isEmpty)
    #expect(engine.applications.isEmpty)
    #expect(engine.lastApplicationWindowElements.isEmpty)
    #expect(engine.unmatchedWindowElementsByProcess.isEmpty)
    #expect(engine.windowListReadRetryAttemptsByProcess.isEmpty)
    #expect(!engine.hasCompletedWindowSnapshot)
    #expect(engine.elements[WindowID(rawValue: 1)] != nil)
    engine.applications = [42: AXUIElementCreateApplication(42)]
    _ = engine.consumeObservations()
    #expect(engine.applications[42] != nil)
  }

  @Test(arguments: [false, true], [false, true])
  func delayedInternalActivationCannotBorrowNewerInput(keyboard: Bool, inFlight: Bool) throws {
    let tracker = UserInputTracker()
    let oldTarget = WindowID(rawValue: 2)
    let request = InternalFocusSuppression(
      requestID: 1, deadline: 30, maximumInputTimestamp: 10
    )
    tracker.record(timestamp: 11, focusIntent: keyboard ? .keyboard : .mouse(windowID: WindowID(rawValue: 3)))
    let suppression = try #require(inFlight ? request : internalFocusSuppressionAfterCompletion(
      request, requestID: 1, result: .completed, at: 11.5
    ))
    tracker.recordApplicationActivation(processID: 20, at: 12)
    #expect(tracker.pendingApplicationActivation(frontmostProcessID: 20, at: 12.1)?.processID == 20)
    #expect(internalFocusSuppressionConsumesEvent(
      suppression, suppressedWindowID: oldTarget,
      latestFocusIntent: tracker.snapshot.latestFocusIntent,
      applicationActivation: true
    ))
  }

  @Test(arguments: [10.5, 11.0, 12.0])
  func keyboardActivationAfterCompletedFocusIsNotConsumed(inputTimestamp: TimeInterval) throws {
    let tracker = UserInputTracker()
    tracker.record(timestamp: 10, focusIntent: .keyboard)
    let completed = try #require(internalFocusSuppressionAfterCompletion(
      InternalFocusSuppression(requestID: 1, deadline: 30, maximumInputTimestamp: 10),
      requestID: 1,
      result: .completed,
      at: 11
    ))
    tracker.record(timestamp: inputTimestamp, focusIntent: .keyboard)
    tracker.recordApplicationActivation(processID: 20, at: 13)
    #expect(tracker.pendingApplicationActivation(frontmostProcessID: 20, at: 13.1)?.processID == 20)
    #expect(internalFocusSuppressionConsumesEvent(
      completed,
      suppressedWindowID: WindowID(rawValue: 2),
      latestFocusIntent: tracker.snapshot.latestFocusIntent,
      applicationActivation: true
    ) == (inputTimestamp <= 11))
  }

  @Test
  func applicationActivationResolutionIsBoundedAndLatestWins() {
    let tracker = UserInputTracker()
    tracker.recordApplicationActivation(processID: 20, at: 10)
    tracker.record(timestamp: 10.1) // Typing does not invalidate native activation.
    #expect(tracker.pendingApplicationActivation(frontmostProcessID: 20, at: 11)?.processID == 20)
    #expect(tracker.snapshot.latestCapturedCommandTimestamp == 0)
    tracker.recordApplicationActivation(processID: 30, at: 11)
    tracker.consumeApplicationActivation(processID: 20, at: 10)
    #expect(tracker.pendingApplicationActivation(frontmostProcessID: 30, at: 11.1)?.processID == 30)
    tracker.recordApplicationActivation(processID: 30, at: 11.2)
    tracker.consumeApplicationActivation(processID: 30, at: 11)
    #expect(tracker.snapshot.applicationActivation?.timestamp == 11.2)
    tracker.consumeApplicationActivation(processID: 30, at: 11.2)
    #expect(tracker.snapshot.activatedProcessID == nil)
    tracker.recordApplicationActivation(processID: 30, at: 12)
    #expect(tracker.pendingApplicationActivation(frontmostProcessID: 30, at: 14.1) == nil)
    tracker.recordApplicationActivation(processID: 30, at: 15)
    #expect(tracker.pendingApplicationActivation(frontmostProcessID: 20, at: 15.1) == nil)
    tracker.recordApplicationActivation(processID: 30, at: 16)
    tracker.record(timestamp: 16.1, focusIntent: .keyboard)
    #expect(tracker.snapshot.activatedProcessID == nil)
    tracker.recordApplicationActivation(processID: 30, at: 16)
    #expect(tracker.snapshot.activatedProcessID == nil)
    tracker.recordApplicationActivation(processID: 30, at: 17)
    tracker.invalidate(at: 17.1)
    #expect(tracker.snapshot.activatedProcessID == nil)
  }

  @Test
  func capturedCommandTimestampIgnoresOrdinaryInput() {
    let tracker = UserInputTracker()
    tracker.recordApplicationActivation(processID: 20, at: 10)
    tracker.record(timestamp: 10.1)
    #expect(tracker.snapshot.latestCapturedCommandTimestamp == 0)
    #expect(nativeFocusMutationIsReady(
      nativeFocusChanged: true,
      mouseInteractionEnded: false,
      leftMouseButtonDown: false,
      mouseReleaseFocusIntentCurrent: false,
      keyboardFocusIntentCurrent: false,
      applicationActivationTimestamp: 10,
      latestCommandInputTimestamp: tracker.snapshot.latestCapturedCommandTimestamp
    ))

    tracker.recordCapturedCommand(at: 10.2)
    let latestCommandInputTimestamp = tracker.snapshot.latestCapturedCommandTimestamp
    #expect(latestCommandInputTimestamp == 10.2)
    let keyboardFocusIntentCurrent = keyboardFocusIntentIsCurrent(
      keyboardFocusIntentTimestamp: 10,
      latestCommandInputTimestamp: latestCommandInputTimestamp
    )
    #expect(!nativeFocusMutationIsReady(
      nativeFocusChanged: true,
      mouseInteractionEnded: false,
      leftMouseButtonDown: false,
      mouseReleaseFocusIntentCurrent: false,
      keyboardFocusIntentCurrent: keyboardFocusIntentCurrent,
      applicationActivationTimestamp: 10,
      latestCommandInputTimestamp: latestCommandInputTimestamp
    ))
  }

  @Test(arguments: [nil, 13.0] as [TimeInterval?])
  func onlyDirectClickOnSuppressedTargetOverridesItsActivationEcho(completedAt: TimeInterval?) {
    let tracker = UserInputTracker()
    let suppression = InternalFocusSuppression(
      requestID: 1, deadline: 30, maximumInputTimestamp: 10, completedAt: completedAt
    )
    tracker.record(timestamp: 11, focusIntent: .mouse(windowID: WindowID(rawValue: 1)))
    #expect(internalFocusSuppressionConsumesEvent(
      suppression, suppressedWindowID: WindowID(rawValue: 2),
      latestFocusIntent: tracker.snapshot.latestFocusIntent,
      applicationActivation: true
    ))
    #expect(internalFocusSuppressionConsumesEvent(
      suppression, suppressedWindowID: WindowID(rawValue: 2),
      latestFocusIntent: tracker.snapshot.latestFocusIntent
    ))
    tracker.record(timestamp: 12, focusIntent: .mouse(windowID: WindowID(rawValue: 2)))
    #expect(internalFocusSuppressionConsumesEvent(
      suppression, suppressedWindowID: WindowID(rawValue: 2),
      latestFocusIntent: tracker.snapshot.latestFocusIntent,
      applicationActivation: true
    ) == false)
    tracker.consumeFocusIntent(at: 12)
    #expect(internalFocusSuppressionConsumesEvent(
      suppression, suppressedWindowID: WindowID(rawValue: 2),
      latestFocusIntent: tracker.snapshot.latestFocusIntent,
      applicationActivation: true
    ))
  }

  @Test
  func desktopSessionOnlyReactivatesAfterEveryWakeSignal() {
    var normalizer = DesktopSessionEventNormalizer()

    #expect(normalizer.consume(.sessionDidResignActive) == .becameInactive)
    #expect(normalizer.consume(.screensDidSleep) == nil)
    #expect(normalizer.consume(.screensDidWake) == nil)
    #expect(normalizer.consume(.sessionDidBecomeActive) == .becameActive)
    #expect(normalizer.consume(.sessionDidBecomeActive) == nil)
  }

  @Test
  func systemWakeDoesNotReactivateBeforeSleepingScreensWake() {
    var normalizer = DesktopSessionEventNormalizer()

    #expect(normalizer.consume(.willSleep) == .becameInactive)
    #expect(normalizer.consume(.screensDidSleep) == nil)
    #expect(normalizer.consume(.didWake) == nil)
    #expect(normalizer.consume(.screensDidWake) == .becameActive)
  }

  @Test @MainActor
  func workspaceSessionNotificationsUseTheNormalizedSequence() {
    var changes: [DesktopSessionActivityChange] = []
    let monitor = PlatformEventMonitor(
      handler: { _, _ in },
      desktopSessionHandler: { changes.append($0) },
      desktopSessionStateProvider: { .active }
    )
    monitor.start()
    defer { monitor.stop() }

    let center = NSWorkspace.shared.notificationCenter
    center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
    center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
    center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

    #expect(changes == [.becameInactive, .becameActive])
  }

  @Test @MainActor
  func inactiveStartupPausesUntilTheMissingWakeSignalArrives() {
    var changes: [DesktopSessionActivityChange] = []
    let monitor = PlatformEventMonitor(
      handler: { _, _ in },
      desktopSessionHandler: { changes.append($0) },
      desktopSessionStateProvider: {
        DesktopSessionState(
          systemAwake: true,
          screensAwake: false,
          sessionActive: true
        )
      }
    )
    monitor.start()
    defer { monitor.stop() }

    #expect(changes == [.becameInactive])

    NSWorkspace.shared.notificationCenter.post(
      name: NSWorkspace.screensDidWakeNotification,
      object: nil
    )

    #expect(changes == [.becameInactive, .becameActive])
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
  func unresolvedTransientOwnershipBacksOffThenReturnsToIdleAndClearsItsOwner() {
    #expect((1...8).map { transientOwnerResolutionRetryDeadline(afterAttempt: $0, now: 10) }
      == [10, 11, 12, 14, 15, 15, 15, nil])
    #expect((1...8).map { transientOwnerResolutionShouldClearCachedOwner(afterAttempt: $0) }
      == [false, false, false, false, false, false, false, true])
    func due(known: Bool, attempts: Int = 1, retryAfter: TimeInterval? = 12, now: TimeInterval) -> Bool {
      transientOwnerResolutionIsDue(ownerKnown: known, attempts: attempts, retryAfter: retryAfter, now: now)
    }
    #expect([due(known: false, now: 11), due(known: false, now: 12), due(known: true, now: 11),
      due(known: true, now: 12), due(known: false, attempts: 8, retryAfter: nil, now: 10)]
      == [false, true, false, true, false])
    #expect(transientOwnerResolutionRefreshInterval(retryAfter: [14, 12], now: 10) == 2)
    #expect(transientOwnerResolutionRefreshInterval(retryAfter: [9], now: 10) == 0)
    #expect(transientOwnerResolutionRefreshInterval(retryAfter: [], now: 10) == nil)
  }

  @Test @NavigationActor
  func transientOwnerRetrySchedulesTheWindowListRefresh() {
    let platform = MacOSPlatform()
    platform.presentationStatus.topologyReliable = true
    let now = ProcessInfo.processInfo.systemUptime
    platform.transientOwnerResolutionRetryAfter[WindowID(rawValue: 42)] = now + 5

    #expect(platform.hasPendingTransientOwnerResolution)
    #expect(platform.recommendedWindowListRefreshInterval > 4)
    #expect(platform.recommendedWindowListRefreshInterval <= 5)
  }

  @Test
  func applicationLifecycleRetriesTopologyAfterDelayedWindowCreation() {
    #expect(!applicationLifecycleRefreshDelays(for: .application).isEmpty)
    #expect(applicationLifecycleRefreshDelays(for: .applicationTerminated)
      == applicationLifecycleRefreshDelays(for: .application))
    #expect(applicationLifecycleRefreshDelays(for: .focus).isEmpty)
    #expect(applicationLifecycleRetryInvalidation(for: .application, processID: 7, knownWindowCount: nil) == .process(7))
    #expect(applicationLifecycleRetryInvalidation(for: .application, processID: 7, knownWindowCount: 0) == .process(7))
    #expect(applicationLifecycleRetryInvalidation(for: .application, processID: 7, knownWindowCount: 1) == .full)
    #expect(applicationLifecycleRetryInvalidation(for: .application, processID: nil, knownWindowCount: nil) == .full)
    #expect(applicationLifecycleRetryInvalidation(for: .applicationTerminated, processID: 7, knownWindowCount: nil) == .full)
    #expect(!windowTopologyRefreshDelays(for: .windowCreated).isEmpty)
    #expect(windowTopologyRefreshDelays(for: .windows).isEmpty)
    #expect(windowTopologyRefreshDelays(for: .focus).isEmpty)
  }

  @Test @NavigationActor
  func targetedTopologyRefreshPreservesItsInputTimestamp() {
    let platform = MacOSPlatform()

    platform.requestWindowTopologyRefresh(processID: 101, inputTimestamp: 12)
    platform.requestWindowTopologyRefresh(processID: 101, inputTimestamp: 10)

    #expect(platform.hasPendingWindowTopologyEvent)
    #expect(platform.snapshotEngine.pendingObservations.topologyProcessIDs == [101])
    #expect(platform.snapshotEngine.pendingObservations.topologyInputTimestamp == 12)
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
  func timeoutResetDoesNotSerializeUnrelatedElementsOrEraseANewTimeout() {
    let first = TestAXElement(AXUIElementCreateApplication(-100))
    let second = TestAXElement(AXUIElementCreateApplication(-101))
    let resetStarted = DispatchSemaphore(value: 0)
    let releaseReset = DispatchSemaphore(value: 0)
    let unrelatedFinished = DispatchSemaphore(value: 0)
    let sameElementStarted = DispatchSemaphore(value: 0)
    let sameElementEntered = DispatchSemaphore(value: 0)
    let group = DispatchGroup()
    let transitions = Mutex<[Float]>([])
    defer { releaseReset.signal() }
    let access = AXMessagingTimeoutAccess(timeoutSetter: { element, timeout in
      guard CFEqual(element, first.value) else { return }
      if timeout == 0, transitions.withLock({ $0.count == 1 }) {
        resetStarted.signal()
        releaseReset.wait()
      }
      transitions.withLock { $0.append(timeout) }
    })
    group.enter()
    Thread.detachNewThread {
      access.withTimeout(0.05, elements: [first.value]) {}
      group.leave()
    }
    #expect(resetStarted.wait(timeout: .now() + 3) == .success)
    group.enter()
    Thread.detachNewThread {
      access.withTimeout(0.016, elements: [second.value]) { unrelatedFinished.signal() }
      group.leave()
    }
    group.enter()
    Thread.detachNewThread {
      sameElementStarted.signal()
      access.withTimeout(0.016, elements: [first.value]) { sameElementEntered.signal() }
      group.leave()
    }
    #expect(unrelatedFinished.wait(timeout: .now() + 3) == .success)
    #expect(sameElementStarted.wait(timeout: .now() + 3) == .success)
    #expect(sameElementEntered.wait(timeout: .now() + 0.1) == .timedOut)
    releaseReset.signal()
    #expect(group.wait(timeout: .now() + 3) == .success)
    #expect(transitions.withLock { $0 } == [0.05, 0, 0.016, 0])
  }

  @Test
  func focusRecoveryIntentAndLookupAreLatestWins() {
    #expect(focusRecoveryIntentIsCurrent(requestGeneration: 8, currentGeneration: 8))
    #expect(!focusRecoveryIntentIsCurrent(requestGeneration: 8, currentGeneration: 9))
    #expect(focusRecoveryResolutionIsCurrent(requestGeneration: 4, currentGeneration: 4))
    #expect(!focusRecoveryResolutionIsCurrent(requestGeneration: 3, currentGeneration: 4))
  }

  // event -> physical pointer motion, mouse button down, general user input
  @Test(arguments: [
    (.mouseMoved, true, false, false), (.leftMouseDragged, true, false, false),
    (.rightMouseDragged, true, false, false), (.otherMouseDragged, true, false, false),
    (.leftMouseDown, false, true, true), (.rightMouseDown, false, true, true), (.otherMouseDown, false, true, true),
    (.leftMouseUp, false, false, false), (.scrollWheel, false, false, true), (.keyDown, false, false, true),
    (.flagsChanged, false, false, true),
  ] as [(CGEventType, Bool, Bool, Bool)])
  func inputTrackingClassifiesEvents(type: CGEventType, pointerMotion: Bool, buttonDown: Bool, general: Bool) {
    #expect(eventTracksPhysicalPointerMotion(type) == pointerMotion)
    #expect(eventIsMouseButtonDown(type) == buttonDown)
    #expect(eventTracksGeneralUserInput(type) == general)
  }

  @Test
  func foregroundRaiseRetriesOnceAndStopsWhenStale() {
    var current = true
    var timeouts: [Float] = []
    let recovered = performForegroundRaise(
      isCurrent: { current },
      attempt: { timeout in
        timeouts.append(timeout)
        return timeouts.count == 1 ? .cannotComplete : .success
      }
    )
    #expect(recovered.succeeded)
    #expect(recovered.retried)
    #expect(recovered.cancelled == false)
    #expect(timeouts == [0.016, 0.05])

    timeouts = []
    let stale = performForegroundRaise(
      isCurrent: { current },
      attempt: { timeout in
        timeouts.append(timeout)
        current = false
        return .cannotComplete
      }
    )
    #expect(stale.cancelled)
    #expect(stale.retried == false)
    #expect(timeouts == [0.016])
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
  func failedActivationDoesNotReportAnUnappliedMutation() {
    #expect(
      focusMutationStateAfterActivation(
        priorMutationApplied: false,
        activationSucceeded: false
      ) == false)
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
      focusRequestCanBeCancelled(
        requestGeneration: 4,
        latestGeneration: 5,
        pendingGeneration: nil,
        activeGeneration: 5
      ) == false)
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
  func inputAndPointerTimestampsStayMonotonicAcrossDuplicateDelivery() {
    let tracker = UserInputTracker()
    for timestamp in [12.0, 8, 12] { tracker.record(timestamp: timestamp) }
    #expect(tracker.latestEventTimestamp == 12)
    #expect(!userInputOccurredAfterWindowTopology(topologyInputTimestamp: 12,
      latestInputTimestamp: tracker.latestEventTimestamp))
    tracker.record(timestamp: 13)
    #expect(userInputOccurredAfterWindowTopology(topologyInputTimestamp: 12,
      latestInputTimestamp: tracker.latestEventTimestamp))
    let pointer = PointerMotionTracker()
    pointer.record(timestamp: 12)
    pointer.record(timestamp: 10)
    #expect(pointer.latestTimestamp == 12)
  }

  struct TopologyInputEvent: Sendable {
    let timestamp: Double
    var focusIntent: UserInputTracker.FocusIntentSource?
    var closeIntent = false

    static func close(_ timestamp: Double) -> Self {
      Self(timestamp: timestamp, closeIntent: true)
    }

    static func keyboard(_ timestamp: Double) -> Self {
      Self(timestamp: timestamp, focusIntent: .keyboard)
    }

    static func mouse(_ timestamp: Double, window: WindowID?) -> Self {
      Self(timestamp: timestamp, focusIntent: .mouse(windowID: window))
    }

    static func input(_ timestamp: Double) -> Self {
      Self(timestamp: timestamp)
    }
  }

  struct TopologyInputCase: CustomTestStringConvertible, Sendable {
    let name: String
    let events: [TopologyInputEvent]
    var topologyAfterEventCount: Int?
    var removedWindowIDs: Set<WindowID> = []
    let inputOccurredAfterTopology: Bool

    var testDescription: String { name }
  }

  static let topologyInputCases = [
    TopologyInputCase(
      name: "command-tab after close wins before topology notification",
      events: [.close(20), .keyboard(21)],
      inputOccurredAfterTopology: true
    ),
    TopologyInputCase(
      name: "command-tab between two closes still wins first removal reconciliation",
      events: [.close(20), .keyboard(21), .close(22)],
      topologyAfterEventCount: 1,
      inputOccurredAfterTopology: true
    ),
    TopologyInputCase(
      name: "mouse click after close wins before topology notification",
      events: [.close(20), .mouse(21, window: WindowID(rawValue: 30))],
      removedWindowIDs: [WindowID(rawValue: 10)],
      inputOccurredAfterTopology: true
    ),
    TopologyInputCase(
      name: "unresolved background click after close wins before topology notification",
      events: [.close(20), .mouse(21, window: nil)],
      removedWindowIDs: [WindowID(rawValue: 10)],
      inputOccurredAfterTopology: true
    ),
    TopologyInputCase(
      name: "close button click does not masquerade as focus intent",
      events: [.mouse(20, window: WindowID(rawValue: 10))],
      removedWindowIDs: [WindowID(rawValue: 10)],
      inputOccurredAfterTopology: false
    ),
    TopologyInputCase(
      name: "input after removed window click cancels removal focus recovery",
      events: [.mouse(20, window: WindowID(rawValue: 10)), .input(21)],
      topologyAfterEventCount: 1,
      removedWindowIDs: [WindowID(rawValue: 10)],
      inputOccurredAfterTopology: true
    ),
    TopologyInputCase(
      name: "close intent does not masquerade as explicit focus",
      events: [.keyboard(19), .close(20)],
      inputOccurredAfterTopology: false
    ),
    TopologyInputCase(
      name: "consecutive close intents remain one removal transaction",
      events: [.close(20), .close(21)],
      topologyAfterEventCount: 1,
      removedWindowIDs: [WindowID(rawValue: 10), WindowID(rawValue: 11)],
      inputOccurredAfterTopology: false
    ),
    TopologyInputCase(
      name: "consecutive close button clicks on removed windows remain one transaction",
      events: [
        .mouse(20, window: WindowID(rawValue: 10)),
        .mouse(21, window: WindowID(rawValue: 11)),
      ],
      topologyAfterEventCount: 1,
      removedWindowIDs: [WindowID(rawValue: 10), WindowID(rawValue: 11)],
      inputOccurredAfterTopology: false
    ),
  ]

  @Test(arguments: topologyInputCases)
  func userInputAfterWindowTopologyDistinguishesRemovalIntents(_ scenario: TopologyInputCase) {
    let tracker = UserInputTracker()
    var topologyInputTimestamp: Double?
    for (index, event) in scenario.events.enumerated() {
      tracker.record(
        timestamp: event.timestamp,
        focusIntent: event.focusIntent,
        closeIntent: event.closeIntent
      )
      if index + 1 == scenario.topologyAfterEventCount {
        topologyInputTimestamp = tracker.latestEventTimestamp
      }
    }
    let input = tracker.snapshot

    #expect(
      userInputOccurredAfterWindowTopology(
        topologyInputTimestamp: topologyInputTimestamp ?? input.latestEventTimestamp,
        latestInputTimestamp: input.latestEventTimestamp,
        latestFocusIntent: input.latestFocusIntent,
        latestCloseIntentTimestamp: input.latestCloseIntent,
        removedWindowIDs: scenario.removedWindowIDs
      ) == scenario.inputOccurredAfterTopology
    )
  }

  @Test
  func newFocusPreservesCompletedSuppressionUntilItsDelayedEventArrives() {
    let windowID = WindowID(rawValue: 1)
    let completed = InternalFocusSuppression(
      requestID: 7,
      deadline: 20,
      maximumInputTimestamp: 10,
      completedAt: 11
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

  @Test(
    arguments: [
      (Set<pid_t>([42]), false, pid_t?(42), true),
      ([42], false, 7, false),
      ([-1], false, -1, false),
      ([], true, nil, false),
      ([], true, 7, true),
    ] as [(Set<pid_t>, Bool, pid_t?, Bool)]
  )
  func nativeFocusEventRequiresMatchingFocusedProcess(
    eventProcessIDs: Set<pid_t>,
    hasUnknownEventProcess: Bool,
    focusedProcessID: pid_t?,
    matches: Bool
  ) {
    #expect(
      nativeFocusEventMatchesTarget(
        eventPending: true,
        eventProcessIDs: eventProcessIDs,
        hasUnknownEventProcess: hasUnknownEventProcess,
        focusedProcessID: focusedProcessID
      ) == matches
    )
  }

  @Test
  func unresolvedNativeFocusEventRemainsPendingUntilTargetMatchesOrExpires() {
    func remains(
      pending: Bool = true, matched: Bool = false, age: TimeInterval, frontmost: Bool
    ) -> Bool {
      nativeFocusEventShouldRemainPending(
        eventPending: pending, targetMatched: matched,
        eventAge: age, sourceIsFrontmost: frontmost
      )
    }
    #expect(remains(age: 0.1, frontmost: true))
    #expect(remains(age: 1.9, frontmost: true))
    #expect(remains(matched: true, age: 0.1, frontmost: true) == false)
    #expect(remains(pending: false, age: 0.1, frontmost: true) == false)
    #expect(remains(age: 2, frontmost: true) == false, "Bounded like an application activation")
    #expect(remains(age: 0.1, frontmost: false), "Frontmost update may lag the focus event")
    #expect(remains(age: 0.25, frontmost: false) == false, "Background app focus never resolves")
  }

  struct RecoveryTarget: Equatable, Sendable {
    let timestamp: Double
    let windowID: UInt64?
    let processID: pid_t?
  }

  struct FocusRecoveryCase: CustomTestStringConvertible, Sendable {
    let name: String
    // timestamp, focus intent, close intent
    let inputs: [(Double, UserInputTracker.FocusIntentSource?, Bool)]
    var observed: [(UInt64?, pid_t)] = []
    var after: Double = 10
    var excluding: (UInt64?, pid_t?) = (nil, nil)
    var fallback: (UInt64?, pid_t?) = (nil, nil)
    let target: RecoveryTarget?

    var testDescription: String { name }
  }

  static let mouse42 = UserInputTracker.FocusIntentSource.mouse(windowID: WindowID(rawValue: 42))
  static let focusRecoveryCases = [
    FocusRecoveryCase(name: "a click names its window", inputs: [(11, mouse42, false)],
      target: RecoveryTarget(timestamp: 11, windowID: 42, processID: nil)),
    FocusRecoveryCase(name: "a later keyboard intent uses the observed process",
      inputs: [(11, mouse42, false), (12, .keyboard, false)], observed: [(nil, 900)], after: 11,
      target: RecoveryTarget(timestamp: 12, windowID: nil, processID: 900)),
    FocusRecoveryCase(name: "ordinary input after the intent advances the timestamp",
      inputs: [(11, mouse42, false), (12, .keyboard, false), (13, nil, false)], observed: [(nil, 900)], after: 11,
      target: RecoveryTarget(timestamp: 13, windowID: nil, processID: 900)),
    FocusRecoveryCase(name: "a click without a window uses the observed process",
      inputs: [(11, .mouse(windowID: nil), false)], observed: [(nil, 900)],
      target: RecoveryTarget(timestamp: 11, windowID: nil, processID: 900)),
    FocusRecoveryCase(name: "observed focus beats the clicked system surface", inputs: [(11, mouse42, false)],
      observed: [(99, 900)], target: RecoveryTarget(timestamp: 11, windowID: 99, processID: 900)),
    FocusRecoveryCase(name: "an invalid process never becomes observed focus", inputs: [(11, .keyboard, false)],
      observed: [(nil, -1)], target: nil),
    FocusRecoveryCase(name: "a guarded fallback observation is excluded", inputs: [(12, .keyboard, false)],
      observed: [(50, 400), (40, 400)], after: 11, excluding: (40, 400),
      target: RecoveryTarget(timestamp: 12, windowID: 50, processID: 400)),
    FocusRecoveryCase(name: "a pid-only fallback observation is excluded", inputs: [(12, .keyboard, false)],
      observed: [(50, 500), (nil, 400)], after: 11, excluding: (40, 400),
      target: RecoveryTarget(timestamp: 12, windowID: 50, processID: 500)),
    FocusRecoveryCase(name: "ordinary input recovers to the fallback", inputs: [(12, nil, false)],
      excluding: (50, 500), fallback: (42, 400), target: RecoveryTarget(timestamp: 12, windowID: 42, processID: 400)),
    FocusRecoveryCase(name: "an unresolved explicit focus does not fall back", inputs: [(12, .keyboard, false)],
      fallback: (42, 400), target: nil),
    FocusRecoveryCase(name: "the fallback cannot be the excluded target", inputs: [(12, nil, false)],
      excluding: (42, nil), fallback: (42, 400), target: nil),
    FocusRecoveryCase(name: "a close intent never falls back", inputs: [(12, nil, true)], fallback: (42, 400),
      target: nil),
  ]

  @Test(arguments: focusRecoveryCases)
  func focusRecoveryTargetFollowsIntentObservationAndFallback(_ scenario: FocusRecoveryCase) {
    let tracker = UserInputTracker()
    for (timestamp, intent, close) in scenario.inputs {
      tracker.record(timestamp: timestamp, focusIntent: intent, closeIntent: close)
    }
    for (windowID, processID) in scenario.observed {
      tracker.recordObservedFocus(windowID: windowID.map(WindowID.init(rawValue:)), processID: processID)
    }
    let target = tracker.focusRecoveryTarget(after: scenario.after,
      excludingWindowID: scenario.excluding.0.map(WindowID.init(rawValue:)), excludingProcessID: scenario.excluding.1,
      fallbackWindowID: scenario.fallback.0.map(WindowID.init(rawValue:)), fallbackProcessID: scenario.fallback.1)
    #expect(target.map { RecoveryTarget(timestamp: $0.timestamp, windowID: $0.windowID?.rawValue,
      processID: $0.processID) } == scenario.target)
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
    #expect(eventTracksGeneralUserInput(.scrollWheel, scrollMomentumPhase: 1) == false)
    #expect(eventTracksGeneralUserInput(.scrollWheel, scrollMomentumPhase: 2) == false)
  }

  @Test
  func pointerWindowTransitionsDeduplicateUntilReset() {
    var state = PointerWindowTransitionState()
    let changes = [42, 42, 0, 0, 42].map { state.changed(to: $0) }
    #expect(changes == [true, false, true, false, true])
    state.reset()
    let rearmed = state.changed(to: 42)
    #expect(rearmed, "A reset re-arms the transition inside the same window")
  }

  @Test
  func pointerMotionDeliveryIsRefreshBoundedWithATrailingDelivery() {
    func delay(at timestamp: TimeInterval, last: TimeInterval?) -> TimeInterval {
      pointerMotionDeliveryDelay(rawWindowID: 0, eventTimestamp: timestamp, lastDeliveryTimestamp: last,
        maximumFrequencyHz: 100)
    }
    #expect(delay(at: 12, last: nil) == 0)
    #expect(abs(delay(at: 12.001, last: 12) - 0.009) < 1e-9)
    #expect(delay(at: 12.02, last: 12) == 0)
    #expect(pointerMotionDeliveryPlan(rawWindowChanged: false, refreshDelay: 0.007, deliveryScheduled: false)
      == PointerMotionDeliveryPlan(shouldSchedule: true, delay: 0.007))
    #expect(pointerMotionDeliveryPlan(rawWindowChanged: false, refreshDelay: 0.007, deliveryScheduled: true)
      == PointerMotionDeliveryPlan(shouldSchedule: false, delay: 0.007))
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
  func reliableObservationWatchdogsWaitForIdleButFallbacksStayImmediate() {
    #expect(applicationInventoryRefreshInterval(reliableLifecycleObservation: true)
      > applicationInventoryRefreshInterval(reliableLifecycleObservation: false))
    #expect(desktopSnapshotRefreshInterval(reliableDesktopObservation: true)
      > desktopSnapshotRefreshInterval(reliableDesktopObservation: false))
    #expect(!observationWatchdogRefreshIsReady(due: true, interval: 30, userInputIdleDuration: 0.5))
    #expect(observationWatchdogRefreshIsReady(due: true, interval: 30, userInputIdleDuration: 1))
    #expect(observationWatchdogRefreshIsReady(due: true, interval: 0.3, userInputIdleDuration: 0))
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
  func windowDiscoveryGetsThreeShortRetriesThenClearsOnSuccess() {
    #expect((0...3).map { unmatchedWindowRetryIsPending(attempts: $0) } == [true, true, true, false])
    var attempts: Int? = nil
    var history: [Int?] = []
    for _ in 0..<5 {
      attempts = updatedWindowListReadRetryAttempts(previousAttempts: attempts, readSucceeded: false)
      history.append(attempts)
    }
    #expect(history == [0, 1, 2, 3, 3])
    #expect(updatedWindowListReadRetryAttempts(previousAttempts: 3, readSucceeded: true) == nil)
    #expect(windowListRefreshInterval(hasPendingShortRetry: true, reliableTopologyObservation: true)
      < windowListRefreshInterval(hasPendingShortRetry: false, reliableTopologyObservation: false))
    #expect(windowListRefreshInterval(hasPendingShortRetry: false, reliableTopologyObservation: false)
      < windowListRefreshInterval(hasPendingShortRetry: false, reliableTopologyObservation: true))
  }

  enum ShortRetryTrigger: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case failedWindowListRead
    case failedCGWindowInventory
    case retainedWindow
    case none

    var testDescription: String { rawValue }
  }

  @Test(arguments: ShortRetryTrigger.allCases) @NavigationActor
  func pendingWindowDiscoverySchedulesShortRetry(_ trigger: ShortRetryTrigger) {
    let platform = MacOSPlatform()
    switch trigger {
    case .failedWindowListRead:
      platform.windowListReadRetryAttemptsByProcess[101] = 0
    case .failedCGWindowInventory:
      platform.cgWindowInventoryRetryAttempts = 0
    case .retainedWindow:
      platform.retainedWindowIDs = [WindowID(rawValue: 42)]
    case .none:
      break
    }

    let interval = platform.recommendedWindowListRefreshInterval
    #expect(interval == (trigger == .none ? 0.3 : 0.1))
  }

  @Test
  func partialNotificationBatchRollsBackSuccessfulRegistrations() {
    var removed: [String] = []

    let registered = registerNotificationBatch(
      notifications: ["moved", "resized"],
      add: { $0 == "moved" ? .success : .cannotComplete },
      remove: { removed.append($0) }
    )

    #expect(registered == .cannotComplete)
    #expect(removed == ["moved"])
  }

  @Test(arguments: [AXError.cannotComplete, .invalidUIElement]) @MainActor
  func windowObservationRecoversAfterTransientFailures(error: AXError) {
    let pid = ProcessInfo.processInfo.processIdentifier
    let watchdog = reliableObservationWatchdogInterval
    let window = AXUIElementCreateApplication(pid)
    var time: TimeInterval = 0
    var unavailable = true
    var frameAttempts = 0
    let monitor = PlatformEventMonitor(
      handler: { _, _ in }, now: { time },
      addNotification: { _, _, notification, _ in
        if notification as String == kAXMovedNotification {
          frameAttempts += 1
          if unavailable { return error }
        }
        return .success
      },
      removeNotification: { _, _, _ in .success }
    )
    defer { monitor.stop() }
    for _ in 0..<notificationObservationMaxAttempts {
      monitor.refresh(applications: [pid: [window]])
    }
    #expect(frameAttempts == notificationObservationMaxAttempts)
    #expect(monitor.hasReliableFrameCoverage() == false)
    #expect(monitor.observationCoverage.topologyWindows == 1)
    time = watchdog - 1
    monitor.refresh(applications: [pid: [window]])
    #expect(frameAttempts == notificationObservationMaxAttempts)
    time = watchdog
    monitor.refresh(applications: [pid: [window]])
    #expect(frameAttempts == notificationObservationMaxAttempts + 1)
    unavailable = false
    time = watchdog + 1
    for _ in 0..<10 { monitor.refresh(applications: [pid: [window]]) }
    #expect(frameAttempts == notificationObservationMaxAttempts + 1)
    time = 2 * watchdog
    monitor.refresh(applications: [pid: [window]])
    #expect(monitor.hasReliableFrameCoverage())
    #expect(frameAttempts == notificationObservationMaxAttempts + 2)
    #expect(monitor.incompatibleNotificationProcessIDs.isEmpty)
  }

  @Test @MainActor
  func unsupportedWindowObservationDoesNotDisableItsSiblingOrKeepRetrying() {
    let pid = ProcessInfo.processInfo.processIdentifier
    let unsupported = AXUIElementCreateApplication(-1)
    let sibling = AXUIElementCreateApplication(pid)
    var time: TimeInterval = 0
    var attempts = 0
    let monitor = PlatformEventMonitor(
      handler: { _, _ in }, now: { time },
      addNotification: { _, element, notification, _ in
        if CFEqual(element, unsupported), notification as String == kAXMovedNotification {
          attempts += 1
          return .notificationUnsupported
        }
        return .success
      },
      removeNotification: { _, _, _ in .success }
    )
    defer { monitor.stop() }
    for _ in 0..<notificationObservationMaxAttempts {
      monitor.refresh(applications: [pid: [unsupported, sibling]])
    }
    time = 300
    monitor.refresh(applications: [pid: [unsupported, sibling]])
    #expect(attempts == notificationObservationMaxAttempts)
    #expect(monitor.observationCoverage.frameWindows == 1)
    #expect(monitor.observationCoverage.topologyWindows == 2)
    #expect(monitor.notificationObservationErrors(kind: .frame, processID: pid)
      == [AXError.notificationUnsupported.rawValue])
    monitor.refresh(applications: [pid: [sibling]])
    #expect(monitor.hasReliableFrameCoverage())
    #expect(monitor.incompatibleNotificationProcessIDs.isEmpty)
    #expect(monitor.notificationObservationFailureCountsValue.isEmpty)
  }

  @Test @MainActor
  func applicationObservationAlsoRecoversAfterBackoff() {
    let pid = ProcessInfo.processInfo.processIdentifier
    let watchdog = reliableObservationWatchdogInterval
    let application = AXUIElementCreateApplication(pid)
    var time: TimeInterval = 0
    var attempts = 0
    let monitor = PlatformEventMonitor(
      handler: { _, _ in }, now: { time },
      addNotification: { _, _, notification, _ in
        if notification as String == kAXFocusedWindowChangedNotification {
          attempts += 1
          if time < watchdog { return .cannotComplete }
        }
        return .success
      },
      removeNotification: { _, _, _ in .success }
    )
    defer { monitor.stop() }
    for _ in 0..<10 {
      monitor.prepareForWindowDiscovery(processID: pid, application: application)
      monitor.refresh(applications: [pid: []])
    }
    #expect(attempts == notificationObservationMaxAttempts)
    #expect(monitor.observationCoverage.applicationObservers == 0)
    time = watchdog
    monitor.refresh(applications: [pid: []])
    #expect(monitor.observationCoverage.applicationObservers == 1)
    #expect(monitor.notificationObservationFailureCountsValue.isEmpty)
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

    let required =
      requiredTopologyWindows(
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

  @Test(arguments: [true, false]) @NavigationActor
  func frameRefreshTargetsTheOwningProcessOrFallsBackToAFullSnapshot(known: Bool) {
    let platform = MacOSPlatform()
    let windowID = WindowID(rawValue: 42)
    if known { platform.processIDs[windowID] = 101 }
    platform.requestFrameRefresh(for: windowID)
    let pending = platform.snapshotEngine.pendingObservations
    #expect(pending.framePending)
    #expect(pending.frameProcessIDs == (known ? [101] : []))
    #expect(pending.frameWindowIDs == [windowID])
    #expect(pending.frameRequiresFullSnapshot == !known)
    #expect(!pending.frameIncludesUnscopedRefresh)
  }

  @Test(arguments: [false, true]) @MainActor
  func resumingFrameNotificationsForcesFreshProcessReads(unknownScope: Bool) async {
    let platform = await MacOSPlatform()
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
    platform.presentSetFrameNotificationsEnabled(false)
    let revisions = platform.snapshotEngine.preparedWindowReadRevisions
    eventMonitor.recordSuppressedFrameNotification(processID: 202)
    if unknownScope { eventMonitor.recordSuppressedFrameNotification(processID: nil) }

    platform.presentSetFrameNotificationsEnabled(true)

    #expect(platform.snapshotEngine.pendingObservations.framePending)
    #expect(platform.snapshotEngine.pendingObservations.frameProcessIDs == [101, 202])
    #expect(platform.snapshotEngine.pendingObservations.frameRequiresFullSnapshot == unknownScope)
    #expect(platform.snapshotEngine.pendingObservations.frameWindowIDs == [windowID])
    #expect(platform.snapshotEngine.preparedWindowReadRevisions.invalidatedProcessIDs(
      since: revisions, candidates: [101, 202, 303]
    ) == (unknownScope ? [101, 202, 303] : [101, 202]))
  }

  @Test
  func unscopedFrameEventCannotBeNarrowedByALaterWindowEvent() {
    let engine = SnapshotEngine(frameCoordinator: AXFrameCoordinator(), userInputTracker: UserInputTracker())
    engine.recordObservation(.frame, processID: 101)
    engine.recordObservation(.frame, processID: 101, windowID: WindowID(rawValue: 42))
    #expect(engine.consumeObservations().frameIncludesUnscopedRefresh)
    #expect(!engine.pendingObservations.frameIncludesUnscopedRefresh)
  }

  @Test(
    arguments: [
      (PlatformEventKind.applicationTerminated, pid_t(42), WindowSnapshotInvalidation.full),
      (.applicationTerminated, nil, .full),
      (.windows, 7, .process(7)),
      (.windows, nil, .full),
      (.application, 7, .process(7)),
      (.application, nil, .full),
      (.focus, 7, .process(7)),
      (.focus, nil, .full),
    ] as [(PlatformEventKind, pid_t?, WindowSnapshotInvalidation)]
  )
  func windowTopologyUsesPIDButGeneralApplicationEventsStayGlobal(
    kind: PlatformEventKind,
    processID: pid_t?,
    expected: WindowSnapshotInvalidation
  ) {
    #expect(windowSnapshotInvalidation(for: kind, processID: processID) == expected)
  }

  @Test
  func mouseGestureSynchronizesOnlyWhileDraggingAndEndsOnRelease() {
    typealias Actions = MouseGestureEventNormalizer.Actions
    var click = MouseGestureEventNormalizer()
    let press = click.actions(for: .leftMouseDown)
    #expect(press == Actions(refreshBorderStacking: true, startsGesture: true))
    let clickUp = click.actions(for: .leftMouseUp)
    #expect(!clickUp.needsGestureSynchronization)
    #expect(clickUp.endsFocusInteraction)
    #expect(!platformEventCancelsMouseAnimation(.mouseRelease))
    #expect(platformEventCancelsMouseAnimation(.mouse))

    var drag = MouseGestureEventNormalizer()
    _ = drag.actions(for: .leftMouseDown)
    let synchronizes = [drag.actions(for: .leftMouseDragged), drag.actions(for: .leftMouseDragged),
      drag.actions(for: .leftMouseUp)].map(\.needsGestureSynchronization)
    #expect(synchronizes == [true, true, true])
    let secondRelease = drag.actions(for: .leftMouseUp)
    #expect(secondRelease == Actions(), "A second release is ignored")
    let next = drag.actions(for: .leftMouseDown)
    #expect(next.startsGesture)
    #expect(!next.needsGestureSynchronization, "The next press starts a fresh gesture")

    #expect([NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp]
      .map(eventStartsMouseFocusInteraction) == [true, true, true, false, false, false])
  }

  @Test
  func mouseInteractionEndsOnlyWhenEveryHeldButtonIsReleasedOrReset() {
    var held = MouseGestureEventNormalizer()
    _ = held.actions(for: .leftMouseDown)
    _ = held.actions(for: .rightMouseDown, buttonNumber: 1)
    let releases = [held.actions(for: .otherMouseUp, buttonNumber: 2), held.actions(for: .leftMouseUp),
      held.actions(for: .rightMouseUp, buttonNumber: 1)]
    #expect(releases[0] == MouseGestureEventNormalizer.Actions(), "An unrelated button is ignored")
    #expect(releases.map(\.endsFocusInteraction) == [false, false, true])

    var reset = MouseGestureEventNormalizer()
    _ = reset.actions(for: .leftMouseDown)
    let resets = [reset.reset(), reset.reset()]
    #expect(resets == [true, false], "Only a held gesture requests a synthetic release")
    let release = reset.actions(for: .leftMouseUp)
    #expect(release == MouseGestureEventNormalizer.Actions())
  }

  @Test
  func mouseGestureRefreshesTheClickedThenFocusedProcess() {
    let clicked = WindowID(rawValue: 10), focused = WindowID(rawValue: 20)
    let intent = UserInputTracker.FocusIntent(timestamp: 1, source: .mouse(windowID: clicked))
    #expect(mouseGestureRefreshProcessID(latestFocusIntent: intent, focusedWindowID: focused,
      processIDs: [clicked: 100, focused: 200]) == 100)
    #expect(mouseGestureRefreshProcessID(latestFocusIntent: intent, focusedWindowID: focused,
      processIDs: [focused: 200]) == 200)
    #expect(mouseGestureRefreshProcessID(latestFocusIntent: nil, focusedWindowID: focused, processIDs: [:]) == nil)
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

  struct BorderOccluderCase: CustomTestStringConvertible, Sendable {
    let name: String
    // Windows above the focused window (id 9), front to back.
    let above: [WindowStackEntry]
    var focused = WindowStackEntry(windowID: WindowID(rawValue: 9), processID: 8, layer: normal,
      frame: Rect(x: 514, y: 34, width: 2_042, height: 1_354))
    var monitors: [Rect] = [Rect(x: 0, y: 0, width: 2_560, height: 1_440)]
    var known: Set<WindowID> = []
    let frontmost: Bool
    var upperBound: UInt64? = nil

    var testDescription: String { name }
  }

  static let normal = NSWindow.Level.normal.rawValue
  static let floating = NSWindow.Level.floating.rawValue

  static func entry(_ id: UInt64, _ processID: pid_t, _ layer: Int, _ frame: Rect) -> WindowStackEntry {
    WindowStackEntry(windowID: WindowID(rawValue: id), processID: processID, layer: layer, frame: frame)
  }

  static let borderOccluderCases = [
    BorderOccluderCase(name: "a tiny auxiliary window does not occlude",
      above: [entry(1, 7, normal, Rect(x: 520, y: 40, width: 66, height: 20))], frontmost: true),
    BorderOccluderCase(name: "a dialog stays ahead of the focused window",
      above: [entry(1, 7, normal, Rect(x: 900, y: 400, width: 640, height: 480))], frontmost: false),
    BorderOccluderCase(name: "a same-app sibling above without overlap does not occlude",
      above: [entry(1, 8, normal, Rect(x: 2, y: 34, width: 500, height: 1_354))],
      focused: entry(9, 8, normal, Rect(x: 514, y: 34, width: 900, height: 1_354)), known: [WindowID(rawValue: 1)],
      frontmost: true),
    BorderOccluderCase(name: "a floating picture in picture bounds the border",
      above: [entry(1, 7, floating, Rect(x: 1_400, y: 700, width: 420, height: 390))], frontmost: true, upperBound: 1),
    BorderOccluderCase(name: "the backmost floating window bounds the border; Defi's own surfaces are ignored",
      above: [entry(1, 7, floating, Rect(x: 600, y: 200, width: 400, height: 300)),
        entry(2, 8, floating, Rect(x: 900, y: 600, width: 400, height: 300)),
        entry(3, 99, floating, Rect(x: 514, y: 34, width: 20, height: 1_354))], frontmost: true, upperBound: 2),
    BorderOccluderCase(name: "a higher-level system window needs no floating bound",
      above: [entry(1, 7, NSWindow.Level.statusBar.rawValue, Rect(x: 0, y: 0, width: 2_560, height: 30))],
      frontmost: true),
    BorderOccluderCase(name: "an offscreen auxiliary window cannot demote a picture in picture bound",
      above: [entry(1, 7, floating, Rect(x: 1_819, y: 981, width: 418, height: 390)),
        entry(2, 8, normal, Rect(x: 4_283, y: 469, width: 360, height: 287))], frontmost: true, upperBound: 1),
    BorderOccluderCase(name: "an untracked same-process auxiliary window cannot demote a picture in picture bound",
      above: [entry(1, 8, floating, Rect(x: 357, y: 730, width: 418, height: 390)),
        entry(2, 8, normal, Rect(x: 2_200, y: 469, width: 360, height: 287))], frontmost: true, upperBound: 1),
    BorderOccluderCase(name: "a tracked same-process dialog stays above the border",
      above: [entry(1, 8, normal, Rect(x: 900, y: 400, width: 640, height: 480))],
      known: [WindowID(rawValue: 1), WindowID(rawValue: 9)], frontmost: false),
    BorderOccluderCase(name: "a window on another monitor cannot demote the border",
      above: [entry(1, 7, normal, Rect(x: 2_600, y: 40, width: 1_800, height: 1_000))],
      monitors: [Rect(x: 0, y: 0, width: 2_560, height: 1_440), Rect(x: 2_560, y: 0, width: 1_920, height: 1_080)],
      frontmost: true),
  ]

  @Test(arguments: borderOccluderCases)
  func borderStackingFindsTheOccludersThatMatter(_ scenario: BorderOccluderCase) {
    let result = windowBorderStacking(targetWindowID: scenario.focused.windowID, ownProcessID: 99,
      floatingLevel: Self.floating, entries: scenario.above + [scenario.focused], monitorFrames: scenario.monitors,
      knownWindowIDs: scenario.known)
    #expect(result.activeWindowIsFrontmost == scenario.frontmost)
    #expect(result.upperBoundWindowID == scenario.upperBound.map(WindowID.init(rawValue:)))
    #expect(result.upperBoundLevel == (scenario.upperBound == nil ? nil : Self.floating))
  }

}
