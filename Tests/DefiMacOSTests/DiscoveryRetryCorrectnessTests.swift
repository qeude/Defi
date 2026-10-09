import ApplicationServices
import DefiConfig
import DefiModel
import DefiRuntime
import Synchronization
import Testing
@testable import DefiMacOS

extension DiscoveryRetryPerformanceTests {
  @MainActor
  private func retryPlatform(_ fixture: DiscoveryReadFixture, pids: Set<pid_t> = [41]) -> MacOSPlatform {
    let platform = NavigationActor.shared.queue.sync {
      NavigationActor.assumeIsolated { MacOSPlatform() }
    }
    let engine = platform.snapshotEngine
    engine.discoveryMeasurementAccess = fixture.access()
    engine.applications = Dictionary(uniqueKeysWithValues: pids.map { ($0, AXUIElementCreateApplication(-$0)) })
    engine.applicationIDsByProcess = Dictionary(uniqueKeysWithValues: pids.map { ($0, "app-\($0)") })
    engine.enhancedUIByProcess = Dictionary(uniqueKeysWithValues: pids.map { ($0, false) })
    engine.lastApplicationWindowElements = Dictionary(uniqueKeysWithValues: pids.map { ($0, []) })
    engine.hasCompletedWindowSnapshot = true
    return platform
  }

  @MainActor @discardableResult
  private func discoverRetry(_ engine: SnapshotEngine, fixture: DiscoveryReadFixture, now: Double,
    pids: Set<pid_t> = [41], global: Bool = false, shouldRead: (pid_t) -> Bool = { _ in true }
  ) -> SnapshotWindowDiscoveryResult {
    fixture.state.withLock { $0.now = now }
    let result = engine.discoverSnapshotWindows(monitors: [], config: Config(),
      incrementalProcessIDs: global ? nil : pids, forceWindowListRefresh: global,
      forceWindowListRefreshProcessIDs: pids, forceApplicationInventoryRefresh: false,
      capturedTopologyRequiresFullSnapshot: false, topologyProcessIDs: [], createdElements: [:],
      preparedWindowAttributes: [:], preparedTransientOwnerWindowIDs: [:], preparedApplicationWindows: [:],
      explicitlyDestroyedWindowIDs: [], shouldReadProcess: shouldRead, publicCGWindows: { [] })
    engine.elements = result.nextElements
    engine.processIDs = result.nextProcessIDs
    engine.lastSnapshotWindows = result.windows
    engine.lastApplicationWindowElements = result.applicationWindows
    engine.retainedWindowIDs = result.nextRetainedWindowIDs
    return result
  }

  @MainActor @Test
  func successfulEmptyListRetiresEligibleUnmatchedObligation() {
    let fixture = DiscoveryReadFixture()
    fixture.failsProcess = nil
    fixture.revealsNewWindow = false
    fixture.windowLists = [41: [fixture.newElement]]
    let platform = retryPlatform(fixture)
    defer { withExtendedLifetime(platform) {} }
    let engine = platform.snapshotEngine
    discoverRetry(engine, fixture: fixture, now: 0)
    #expect(engine.unmatchedWindowElementsByProcess[41]?.count == 1)
    #expect(engine.nextProcessWindowRetryAt(now: 0) == 0.1)
    fixture.windowLists = [41: []]
    discoverRetry(engine, fixture: fixture, now: 0.1)
    #expect(engine.unmatchedWindowElementsByProcess[41] == nil)
    #expect(engine.unmatchedWindowRetryAttemptsByProcess[41] == 1)
    #expect(engine.nextProcessWindowRetryAt(now: 0.1) == nil)
    #expect(engine.dueProcessWindowRetryIDs(now: 1).isEmpty)
    #expect(fixture.state.withLock { $0.listCalls[41] } == 2)
  }

  @MainActor @Test
  func unmatchedRetryPreservesEligibilityExhaustionAndWatchdog() {
    let fixture = DiscoveryReadFixture()
    fixture.failsProcess = nil
    fixture.revealsNewWindow = false
    fixture.windowLists = [41: [fixture.newElement], 42: [AXUIElementCreateApplication(-42002)]]
    let platform = retryPlatform(fixture, pids: [41, 42])
    defer { withExtendedLifetime(platform) {} }
    let engine = platform.snapshotEngine
    discoverRetry(engine, fixture: fixture, now: 0, pids: [41, 42])
    discoverRetry(engine, fixture: fixture, now: 0.05)
    #expect(engine.unmatchedWindowRetryAttemptsByProcess[41] == 0)
    #expect(fixture.state.withLock { $0.attributeCalls } == 2)
    discoverRetry(engine, fixture: fixture, now: 0.1, shouldRead: { _ in false })
    #expect(engine.unmatchedWindowRetryAttemptsByProcess[41] == 0)
    discoverRetry(engine, fixture: fixture, now: 0.1)
    #expect(engine.unmatchedWindowRetryAttemptsByProcess[41] == 1)
    #expect(engine.unmatchedWindowRetryAttemptsByProcess[42] == 0)
    #expect(engine.processWindowRetryDeadlines[42] == 0.1)
    discoverRetry(engine, fixture: fixture, now: 0.2)
    discoverRetry(engine, fixture: fixture, now: 0.3)
    #expect(engine.unmatchedWindowRetryAttemptsByProcess[41] == 3)
    #expect(!engine.dueProcessWindowRetryIDs(now: 1).contains(41))
    let before = fixture.state.withLock { $0.attributeCalls }
    discoverRetry(engine, fixture: fixture, now: 5, pids: [], global: true)
    #expect(fixture.state.withLock { $0.attributeCalls } == before + 2)
    #expect(engine.unmatchedWindowRetryAttemptsByProcess[41] == 3)
    #expect(!engine.dueProcessWindowRetryIDs(now: 5).contains(41))
  }

  @MainActor @Test
  func concurrentQueriesPreserveRecordedDeadlineAndEligibleAttempts() async {
    let fixture = DiscoveryReadFixture()
    fixture.revealsNewWindow = false
    let platform = retryPlatform(fixture)
    defer { withExtendedLifetime(platform) {} }
    let engine = platform.snapshotEngine
    discoverRetry(engine, fixture: fixture, now: 0)
    #expect(engine.windowListReadRetryAttemptsByProcess[41] == 0)
    #expect(engine.nextProcessWindowRetryAt(now: 0) == 0.1)
    #expect(engine.nextProcessWindowRetryAt(now: 0.05) == 0.1)
    let queryNow = Mutex(0.1)
    let running = Mutex(true)
    let group = DispatchGroup()
    for _ in 0..<4 {
      group.enter()
      DispatchQueue.global().async {
        while running.withLock({ $0 }) {
          let now = queryNow.withLock { $0 }
          _ = engine.nextProcessWindowRetryAt(now: now)
          _ = engine.dueProcessWindowRetryIDs(now: now)
        }
        group.leave()
      }
    }
    var rolledBack = 0
    var consumedEarly = 0
    for index in 1...500 {
      let now = Double(index)
      queryNow.withLock { $0 = now }
      engine.windowListReadRetryAttemptsByProcess = [41: 0]
      engine.processWindowRetryDeadlines = [41: now]
      discoverRetry(engine, fixture: fixture, now: now)
      for _ in 0..<10 { _ = engine.nextProcessWindowRetryAt(now: now) }
      if engine.processWindowRetryDeadlines[41] != now + 0.1 { rolledBack += 1 }
      discoverRetry(engine, fixture: fixture, now: now + 0.05)
      if engine.windowListReadRetryAttemptsByProcess[41] != 1 { consumedEarly += 1 }
      await Task.yield()
    }
    running.withLock { $0 = false }
    await withCheckedContinuation { continuation in
      group.notify(queue: .main) { continuation.resume() }
    }
    #expect(rolledBack == 0)
    #expect(consumedEarly == 0)
    #expect(engine.windowListReadRetryAttemptsByProcess[41] == 1)
    #expect(engine.processWindowRetryDeadlines[41] == 500.1)
    #expect(fixture.state.withLock { $0.listCalls[41] } == 1001)
  }
  @MainActor @Test
  func unpublishedProcessDeadlineSurvivesQueriesAndApplicationPublication() {
    let fixture = DiscoveryReadFixture()
    fixture.failsProcess = 42
    fixture.revealsNewWindow = false
    let platform = retryPlatform(fixture)
    defer { withExtendedLifetime(platform) {} }
    let engine = platform.snapshotEngine
    engine.applicationIDsByProcess[42] = "app-42"
    engine.enhancedUIByProcess[42] = false
    let reads = fixture.access()
    engine.discoveryMeasurementAccess = DiscoveryMeasurementAccess(
      now: reads.now,
      applicationWindows: { element, pid in
        fixture.state.withLock { $0.now = max($0.now, 10.2) }
        return reads.applicationWindows(element, pid)
      }, windowAttributes: reads.windowAttributes, relationships: reads.relationships)
    #expect(engine.applications[42] == nil)
    let result = discoverRetry(engine, fixture: fixture, now: 10, pids: [42])
    #expect(result.nextApplications[42] != nil)
    #expect(engine.applications[42] == nil)
    #expect(engine.windowListReadRetryAttemptsByProcess[42] == 0)
    #expect(abs((engine.processWindowRetryDeadlines[42] ?? -1) - 10.3) < 0.000001)
    #expect(abs((engine.nextProcessWindowRetryAt(now: 10.21) ?? -1) - 10.3) < 0.000001)
    #expect(engine.dueProcessWindowRetryIDs(now: 10.21).isEmpty)
    engine.applications = result.nextApplications
    engine.applicationIDsByProcess = result.nextApplicationIDs
    engine.synchronizeProcessWindowRetryDeadlines(now: 10)
    #expect(abs((engine.processWindowRetryDeadlines[42] ?? -1) - 10.3) < 0.000001)
    discoverRetry(engine, fixture: fixture, now: 10.22, pids: [42])
    #expect(engine.windowListReadRetryAttemptsByProcess[42] == 0)
    #expect(abs((engine.processWindowRetryDeadlines[42] ?? -1) - 10.3) < 0.000001)
    #expect(fixture.state.withLock { $0.listCalls[42] } == 2)
  }

  @MainActor @Test
  func applicationPublicationRetiresAbsentProcessRetryObligations() {
    let fixture = DiscoveryReadFixture()
    fixture.failsProcess = 42
    fixture.revealsNewWindow = false
    fixture.windowLists = [43: [fixture.newElement]]
    let platform = retryPlatform(fixture)
    defer { withExtendedLifetime(platform) {} }
    let engine = platform.snapshotEngine
    engine.applicationIDsByProcess.merge([42: "app-42", 43: "app-43"]) { _, new in new }
    engine.enhancedUIByProcess.merge([42: false, 43: false]) { _, new in new }
    let result = discoverRetry(engine, fixture: fixture, now: 20, pids: [42, 43])
    #expect(Set(result.nextApplications.keys) == [41, 42, 43])
    #expect(engine.windowListReadRetryAttemptsByProcess[42] == 0)
    #expect(engine.unmatchedWindowElementsByProcess[43]?.count == 1)
    #expect(abs((engine.nextProcessWindowRetryAt(now: 20.05) ?? -1) - 20.1) < 0.000001)
    #expect(engine.dueProcessWindowRetryIDs(now: 20.1) == [42, 43])
    let retiredWindow = WindowID(rawValue: 42001)
    engine.processIDs[retiredWindow] = 42
    engine.retainedWindowIDs = [retiredWindow]
    engine.retainedWindowDeadlines[retiredWindow] = 20.15
    engine.applications = result.nextApplications.filter { $0.key == 41 }
    #expect(engine.windowListReadRetryAttemptsByProcess[42] == nil)
    #expect(engine.unmatchedWindowElementsByProcess[43] == nil)
    #expect(engine.unmatchedWindowRetryAttemptsByProcess[43] == nil)
    #expect(engine.nextProcessWindowRetryAt(now: 20.2) == nil)
    #expect(engine.dueProcessWindowRetryIDs(now: 25).isEmpty)
    #expect(engine.processWindowRetryDeadlines.isEmpty)
    #expect(fixture.state.withLock { $0.listCalls } == [42: 1, 43: 1])
  }

}
