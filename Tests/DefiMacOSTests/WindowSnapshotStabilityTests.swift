import ApplicationServices
import DefiModel
import Testing

@testable import DefiMacOS

struct WindowSnapshotStabilityTests {
  private let processID: pid_t = 42
  private let frame = Rect(x: 4, y: 34, width: 1_200, height: 800)

  @Test func destroyedWindowsArrivingDuringSnapshotRemainPending() {
    let engine = SnapshotEngine(
      frameCoordinator: AXFrameCoordinator(),
      userInputTracker: UserInputTracker()
    )
    let consumed = WindowID(rawValue: 1)
    let arrivedDuringSnapshot = WindowID(rawValue: 2)

    engine.recordExplicitlyDestroyedWindow(consumed)
    #expect(engine.consumeExplicitlyDestroyedWindows() == [consumed])
    engine.recordExplicitlyDestroyedWindow(arrivedDuringSnapshot)

    #expect(engine.explicitlyDestroyedWindowIDs == [arrivedDuringSnapshot])
  }

  @Test func staleCGWindowInventoryIsRejected() {
    #expect(
      preparedCGWindowInventoryIsCurrent(
        capturedGeneration: 4,
        currentGeneration: 4
      )
    )
    #expect(
      !preparedCGWindowInventoryIsCurrent(
        capturedGeneration: 4,
        currentGeneration: 5
      )
    )
  }

  @Test func preparedAttributesAreRejectedAfterInputOrObservationChanges() {
    let windowIDs: Set<WindowID> = [WindowID(rawValue: 1)]
    #expect(
      preparedAXWindowAttributesAreCurrent(
        capturedGeneration: 4,
        currentGeneration: 4,
        capturedInputTimestamp: 10,
        currentInputTimestamp: 10,
        capturedWindowIDs: windowIDs,
        currentWindowIDs: windowIDs,
        capturedProcessIDs: [42],
        currentProcessIDs: [42]
      )
    )
    #expect(
      !preparedAXWindowAttributesAreCurrent(
        capturedGeneration: 4,
        currentGeneration: 5,
        capturedInputTimestamp: 10,
        currentInputTimestamp: 10,
        capturedWindowIDs: windowIDs,
        currentWindowIDs: windowIDs,
        capturedProcessIDs: [42],
        currentProcessIDs: [42]
      )
    )
    #expect(
      !preparedAXWindowAttributesAreCurrent(
        capturedGeneration: 4,
        currentGeneration: 4,
        capturedInputTimestamp: 10,
        currentInputTimestamp: 11,
        capturedWindowIDs: windowIDs,
        currentWindowIDs: windowIDs,
        capturedProcessIDs: [42],
        currentProcessIDs: [42]
      )
    )
  }

  @Test func applicationInventoryUsesEventsAndBoundedWatchdog() {
    #expect(
      applicationInventoryRefreshIsRequired(
        hasCompletedSnapshot: false,
        topologyRequiresFullSnapshot: false,
        forced: false
      )
    )
    #expect(
      applicationInventoryRefreshIsRequired(
        hasCompletedSnapshot: true,
        topologyRequiresFullSnapshot: true,
        forced: false
      )
    )
    #expect(
      applicationInventoryRefreshIsRequired(
        hasCompletedSnapshot: true,
        topologyRequiresFullSnapshot: false,
        forced: true
      )
    )
    #expect(
      !applicationInventoryRefreshIsRequired(
        hasCompletedSnapshot: true,
        topologyRequiresFullSnapshot: false,
        forced: false
      )
    )
  }

  @Test func windowListUsesCacheUntilTopologyOrWatchdogInvalidation() {
    #expect(
      applicationWindowListRefreshIsRequired(
        hasCachedWindows: false,
        refreshesAllWindowLists: false,
        topologyProcessWasInvalidated: false
      )
    )
    #expect(
      applicationWindowListRefreshIsRequired(
        hasCachedWindows: true,
        refreshesAllWindowLists: true,
        topologyProcessWasInvalidated: false
      )
    )
    #expect(
      applicationWindowListRefreshIsRequired(
        hasCachedWindows: true,
        refreshesAllWindowLists: false,
        topologyProcessWasInvalidated: true
      )
    )
    #expect(
      !applicationWindowListRefreshIsRequired(
        hasCachedWindows: true,
        refreshesAllWindowLists: false,
        topologyProcessWasInvalidated: false
      )
    )
  }

  @Test func windowListWatchdogRetriesPreviouslyUnmatchedWindows() {
    #expect(
      unmatchedWindowCacheRequiresFullRetry(
        eventRequiresFullSnapshot: false,
        forceFullWindowRefresh: false,
        forceWindowListRefresh: true
      )
    )
    #expect(
      unmatchedWindowCacheRequiresFullRetry(
        eventRequiresFullSnapshot: true,
        forceFullWindowRefresh: false,
        forceWindowListRefresh: false
      )
    )
    #expect(
      unmatchedWindowCacheRequiresFullRetry(
        eventRequiresFullSnapshot: false,
        forceFullWindowRefresh: true,
        forceWindowListRefresh: false
      )
    )
    #expect(
      !unmatchedWindowCacheRequiresFullRetry(
        eventRequiresFullSnapshot: false,
        forceFullWindowRefresh: false,
        forceWindowListRefresh: false
      )
    )
  }

  @Test func unavailableNewWindowUsesDeduplicatedShortRetry() {
    let element = AXUIElementCreateApplication(processID)
    var elementsByProcess: [pid_t: [AXUIElement]] = [:]
    var attemptsByProcess: [pid_t: Int] = [:]

    cacheWindowElementForShortRetry(
      element,
      processID: processID,
      elementsByProcess: &elementsByProcess,
      attemptsByProcess: &attemptsByProcess
    )
    cacheWindowElementForShortRetry(
      element,
      processID: processID,
      elementsByProcess: &elementsByProcess,
      attemptsByProcess: &attemptsByProcess
    )

    #expect(elementsByProcess[processID]?.count == 1)
    #expect(attemptsByProcess[processID] == 0)
    #expect(
      unmatchedWindowRetryIsPending(
        attempts: attemptsByProcess[processID] ?? 3
      )
    )
  }

  @Test func forcedWindowListRefreshAdvancesPendingCGInventoryRetry() {
    #expect(
      cgWindowInventoryRetryIsRequired(
        attempts: 0,
        forceWindowListRefresh: true
      )
    )
    #expect(
      !cgWindowInventoryRetryIsRequired(
        attempts: nil,
        forceWindowListRefresh: true
      )
    )
    #expect(
      !cgWindowInventoryRetryIsRequired(
        attempts: 3,
        forceWindowListRefresh: true
      )
    )
    #expect(
      !cgWindowInventoryRetryIsRequired(
        attempts: 0,
        forceWindowListRefresh: false
      )
    )
  }

  @Test func snapshotDurationPercentilesAreBoundedAndDeterministic() {
    let samples = [1.0, 5.0, 2.0, 4.0, 3.0]

    #expect(durationPercentile(0.5, samples: samples) == 3)
    #expect(durationPercentile(0.95, samples: samples) == 5)
    #expect(durationPercentile(-1, samples: samples) == 1)
    #expect(durationPercentile(2, samples: samples) == 5)
    #expect(durationPercentile(0.5, samples: []) == 0)
  }

  @Test func transientGeometryFailureRemainsUnavailable() {
    #expect(
      windowGeometryDiscovery(minimized: false, frame: { nil }) == .unavailable
    )
  }

  @Test func minimizedAndAuxiliarySizedWindowsRemainIgnored() {
    #expect(
      windowGeometryDiscovery(minimized: true, frame: { frame }) == .ignored
    )
    #expect(
      windowGeometryDiscovery(
        minimized: false,
        frame: { Rect(x: 0, y: 0, width: 79, height: 60) }
      ) == .ignored
    )
  }

  @Test func minimizedWindowDoesNotReadGeometry() {
    var geometryReadCount = 0

    let discovery = windowGeometryDiscovery(minimized: true) {
      geometryReadCount += 1
      return frame
    }

    #expect(discovery == .ignored)
    #expect(geometryReadCount == 0)
  }

  @Test func minimizedFallbackWindowSkipsRemainingAttributeReads() {
    var remainingReadCount = 0
    func recordRead<Value>(_ value: Value) -> Value {
      remainingReadCount += 1
      return value
    }

    let attributes = fallbackWindowAttributes(
      minimized: { true },
      frame: { recordRead(frame) },
      title: { recordRead("Window") },
      role: { recordRead(kAXWindowRole) },
      subrole: { recordRead(kAXStandardWindowSubrole) },
      modal: { recordRead(true) }
    )

    #expect(attributes.minimized == true)
    #expect(attributes.frame == nil)
    #expect(attributes.title.isEmpty)
    #expect(attributes.role == nil)
    #expect(attributes.subrole == nil)
    #expect(remainingReadCount == 0)
  }

  @Test func fallbackWindowAttributesPreservesModalState() {
    let attributes = fallbackWindowAttributes(
      minimized: { false },
      frame: { frame },
      title: { "Sheet" },
      role: { kAXWindowRole },
      subrole: { kAXStandardWindowSubrole },
      modal: { true }
    )

    #expect(attributes.modal == true)
  }

  @Test func usableWindowGeometryRemainsDiscoverable() {
    #expect(
      windowGeometryDiscovery(minimized: false, frame: { frame }) == .usable(frame)
    )
  }

  @Test func existingCGWindowSurvivesTransientAccessibilityOmission() {
    let window = makeWindow(id: 42)

    #expect(
      cachedWindowIDsToRetain(
        processID: processID,
        previousWindows: [window],
        discoveredWindowIDs: [],
        ignoredWindowIDs: [],
        cgWindows: [makeCGWindow(id: 42)],
        cachedMinimizedState: { _ in nil }
      ) == [window.id]
    )
  }

  @Test func unavailableCGInventoryPreservesCachedWindow() {
    let window = makeWindow(id: 42)

    #expect(
      cachedWindowIDsToRetain(
        processID: processID,
        previousWindows: [window],
        discoveredWindowIDs: [],
        ignoredWindowIDs: [],
        cgWindows: nil,
        cachedMinimizedState: { _ in nil }
      ) == [window.id]
    )
  }

  @Test func retainedWindowDoesNotProvideFreshFrameObservation() {
    let retainedWindow = makeWindow(id: 42)
    let observedWindow = makeWindow(id: 43)

    #expect(
      freshWindowObservationIDs(
        windows: [retainedWindow, observedWindow],
        retainedWindowIDs: [retainedWindow.id]
      ) == [observedWindow.id]
    )
  }

  @Test func cachedWindowDoesNotProvideFreshFrameObservation() {
    let cachedWindow = makeWindow(id: 42)
    let observedWindow = makeWindow(id: 43)

    #expect(
      freshWindowObservationIDs(
        windows: [cachedWindow, observedWindow],
        retainedWindowIDs: [],
        cachedWindowIDs: [cachedWindow.id]
      ) == [observedWindow.id]
    )
  }

  @Test func incrementalSnapshotCarriesOnlyLiveRetainedWindowStatus() {
    let retainedWindow = makeWindow(id: 42)
    let observedWindow = makeWindow(id: 43)
    let closedRetainedWindowID = WindowID(rawValue: 44)

    let carriedRetainedWindowIDs = retainedWindowIDsForCachedWindows(
      [retainedWindow, observedWindow],
      previousRetainedWindowIDs: [retainedWindow.id, closedRetainedWindowID]
    )

    #expect(carriedRetainedWindowIDs == [retainedWindow.id])
    #expect(
      freshWindowObservationIDs(
        windows: [retainedWindow, observedWindow],
        retainedWindowIDs: carriedRetainedWindowIDs
      ) == [observedWindow.id]
    )
  }

  @Test func retainedWindowSchedulesImmediateProcessRefresh() {
    let retainedWindowID = WindowID(rawValue: 42)
    let unrelatedWindowID = WindowID(rawValue: 43)
    let retryProcessIDs = retainedWindowRefreshProcessIDs(
      retainedWindowIDs: [retainedWindowID],
      processIDs: [
        retainedWindowID: 101,
        unrelatedWindowID: 202,
      ]
    )

    #expect(retryProcessIDs == [101])
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: false,
        requiresFullSnapshot: false,
        processIDs: [],
        coalescedProcessIDs: retryProcessIDs,
        allowsCoalescedProcessRefresh: true,
        allowsCachedRefresh: true
      ) == [101]
    )
  }

  @Test func externalFrameChangeTargetsOnlyEmittingWindow() {
    let emittedWindowID = WindowID(rawValue: 42)
    let siblingWindowID = WindowID(rawValue: 43)

    #expect(
      windowHasExternalFrameChange(
        emittedWindowID,
        pendingFrameWindowIDs: [emittedWindowID]
      )
    )
    #expect(
      windowHasExternalFrameChange(
        siblingWindowID,
        pendingFrameWindowIDs: [emittedWindowID]
      ) == false
    )
    #expect(
      windowHasExternalFrameChange(
        emittedWindowID,
        pendingFrameWindowIDs: [emittedWindowID],
        matchesRecentInternalWrite: true
      ) == false
    )
  }

  @Test func mouseResizeAlwaysAdoptsTheGestureWindow() {
    let resizedWindowID = WindowID(rawValue: 42)
    let siblingWindowID = WindowID(rawValue: 43)

    #expect(
      windowIsMouseResizeGestureCandidate(
        resizedWindowID,
        mouseGestureWindowID: resizedWindowID,
        mouseResizeGestureObserved: true
      )
    )
    #expect(
      windowIsMouseResizeGestureCandidate(
        siblingWindowID,
        mouseGestureWindowID: resizedWindowID,
        mouseResizeGestureObserved: true
      ) == false
    )
    #expect(
      windowIsMouseResizeGestureCandidate(
        resizedWindowID,
        mouseGestureWindowID: resizedWindowID,
        mouseResizeGestureObserved: false
      ) == false
    )
  }

  @Test func frameEventRemainsPendingOnlyForRetainedWindow() {
    let retained = WindowID(rawValue: 42)
    let observed = WindowID(rawValue: 43)

    #expect(
      retainedFrameEventWindowIDs(
        observedFrameEventWindowIDs: [retained, observed],
        retainedWindowIDs: [retained]
      ) == Set([retained])
    )
  }

  @Test func minimizedCachedWindowDoesNotSurviveAccessibilityOmission() {
    let window = makeWindow(id: 42)

    #expect(
      cachedWindowIDsToRetain(
        processID: processID,
        previousWindows: [window],
        discoveredWindowIDs: [],
        ignoredWindowIDs: [],
        cgWindows: [makeCGWindow(id: 42)],
        cachedMinimizedState: { _ in true }
      ).isEmpty
    )
  }

  @Test func applicationAccessibilityFailureDoesNotProbeCachedWindows() {
    let window = makeWindow(id: 42)

    #expect(
      cachedWindowIDsToRetain(
        processID: processID,
        previousWindows: [window],
        discoveredWindowIDs: [],
        ignoredWindowIDs: [],
        cgWindows: [makeCGWindow(id: 42)],
        cachedMinimizedState: nil
      ) == [window.id]
    )
  }

  @Test func rediscoveredIgnoredAndClosedWindowsDoNotUseCache() {
    let window = makeWindow(id: 42)
    let cgWindows = [makeCGWindow(id: 42)]

    #expect(
      cachedWindowIDsToRetain(
        processID: processID,
        previousWindows: [window],
        discoveredWindowIDs: [window.id],
        ignoredWindowIDs: [],
        cgWindows: cgWindows,
        cachedMinimizedState: { _ in nil }
      ).isEmpty
    )
    #expect(
      cachedWindowIDsToRetain(
        processID: processID,
        previousWindows: [window],
        discoveredWindowIDs: [],
        ignoredWindowIDs: [window.id],
        cgWindows: cgWindows,
        cachedMinimizedState: { _ in nil }
      ).isEmpty
    )
    #expect(
      cachedWindowIDsToRetain(
        processID: processID,
        previousWindows: [window],
        discoveredWindowIDs: [],
        ignoredWindowIDs: [],
        cgWindows: [],
        cachedMinimizedState: { _ in nil }
      ).isEmpty
    )
  }

  private func makeWindow(id: UInt64) -> Window {
    Window(
      id: WindowID(rawValue: id),
      appID: "com.example.app",
      title: "Window",
      frame: frame,
      processID: processID,
      monitorID: MonitorID(rawValue: 1)
    )
  }

  private func makeCGWindow(id: CGWindowID) -> CGWindowRecord {
    CGWindowRecord(
      id: id,
      processID: processID,
      layer: 0,
      title: "Window",
      frame: frame
    )
  }
}
