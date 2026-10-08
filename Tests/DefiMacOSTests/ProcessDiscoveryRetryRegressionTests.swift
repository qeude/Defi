import ApplicationServices
import DefiConfig
import DefiModel
import DefiRuntime
import Testing
@testable import DefiMacOS

struct ProcessDiscoveryRetryRegressionTests {
  @Test func deadlinesPreserveEarliestAndRemoveTerminatedProcesses() {
    let engine = SnapshotEngine(frameCoordinator: AXFrameCoordinator(), userInputTracker: UserInputTracker())
    engine.applications = [41: AXUIElementCreateApplication(-41), 42: AXUIElementCreateApplication(-42)]
    engine.windowListReadRetryAttemptsByProcess = [41: 0, 42: 0]
    #expect(engine.nextProcessWindowRetryAt(now: 0) == 0.1)
    engine.recordWindowListRetryResult(processID: 41, succeeded: false, now: 0.05)
    engine.recordProcessWindowRetryRead(processID: 41, now: 0.05, retained: [])
    #expect(engine.windowListReadRetryAttemptsByProcess[41] == 0)
    #expect(engine.nextProcessWindowRetryAt(now: 0.05) == 0.1)
    engine.applications = [42: AXUIElementCreateApplication(-42)]
    #expect(engine.dueProcessWindowRetryIDs(now: 0.1) == [42])
    #expect(engine.processWindowRetryDeadlines[41] == nil)
    engine.recordWindowListRetryResult(processID: 42, succeeded: false, now: 0.1)
    #expect(engine.windowListReadRetryAttemptsByProcess[42] == 1)
    engine.recordWindowListRetryResult(processID: 42, succeeded: true, now: 0.1)
    engine.recordProcessWindowRetryRead(processID: 42, now: 0.1, retained: [])
    #expect(engine.nextProcessWindowRetryAt(now: 0.1) == nil)
  }

  @MainActor @Test func deferredReadsDoNotConsumeRetriesAndExhaustionKeepsBindings() {
    let platform = NavigationActor.shared.queue.sync { NavigationActor.assumeIsolated { MacOSPlatform() } }
    let engine = platform.snapshotEngine
    let fixture = DiscoveryReadFixture()
    engine.discoveryMeasurementAccess = fixture.access()
    engine.applications = [41: AXUIElementCreateApplication(-41)]
    engine.applicationIDsByProcess = [41: "measurement"]
    engine.enhancedUIByProcess = [41: false]
    engine.lastApplicationWindowElements = [41: []]
    engine.hasCompletedWindowSnapshot = true
    engine.windowListReadRetryAttemptsByProcess = [41: 0]
    _ = engine.nextProcessWindowRetryAt(now: 0)
    fixture.state.withLock { $0.now = 0.1 }
    let deferred = engine.discoverSnapshotWindows(monitors: [], config: Config(), incrementalProcessIDs: [41],
      forceWindowListRefresh: false, forceWindowListRefreshProcessIDs: [41], forceApplicationInventoryRefresh: false,
      capturedTopologyRequiresFullSnapshot: false, topologyProcessIDs: [], createdElements: [:],
      preparedWindowAttributes: [:], preparedTransientOwnerWindowIDs: [:], preparedApplicationWindows: [:],
      explicitlyDestroyedWindowIDs: [], shouldReadProcess: { _ in false }, publicCGWindows: { [] })
    #expect(deferred.nextApplications[41] != nil)
    #expect(fixture.state.withLock { $0.listCalls[41] ?? 0 } == 0)
    #expect(engine.windowListReadRetryAttemptsByProcess[41] == 0)
    for index in 1...3 {
      let now = Double(index) / 10
      fixture.state.withLock { $0.now = now }
      #expect(engine.dueProcessWindowRetryIDs(now: now) == [41])
      _ = engine.discoverSnapshotWindows(monitors: [], config: Config(), incrementalProcessIDs: [41],
        forceWindowListRefresh: false, forceWindowListRefreshProcessIDs: [41], forceApplicationInventoryRefresh: false,
        capturedTopologyRequiresFullSnapshot: false, topologyProcessIDs: [], createdElements: [:],
        preparedWindowAttributes: [:], preparedTransientOwnerWindowIDs: [:], preparedApplicationWindows: [:],
        explicitlyDestroyedWindowIDs: [], publicCGWindows: { [] })
    }
    #expect(engine.windowListReadRetryAttemptsByProcess[41] == 3)
    #expect(engine.nextProcessWindowRetryAt(now: 0.3) == nil)
    #expect(engine.applications[41] != nil)
    #expect(fixture.state.withLock { $0.listCalls[41] } == 3)
  }

  @Test func retainedDeadlineIsIndependentOfExhaustedListRetry() {
    let engine = SnapshotEngine(frameCoordinator: AXFrameCoordinator(), userInputTracker: UserInputTracker())
    let id = WindowID(rawValue: 4101)
    let element = AXUIElementCreateApplication(-41)
    engine.applications = [41: element]
    engine.elements = [id: element]
    engine.processIDs = [id: 41]
    engine.retainedWindowIDs = [id]
    engine.retainedWindowDeadlines = [id: 0.05]
    engine.windowListReadRetryAttemptsByProcess = [41: 3]
    #expect(engine.nextProcessWindowRetryAt(now: 0) == 0.05)
    #expect(engine.dueProcessWindowRetryIDs(now: 0.05) == [41])
    #expect(engine.elements[id] != nil)
    engine.applications = [:]
    #expect(engine.nextProcessWindowRetryAt(now: 0.05) == nil)
  }
}
