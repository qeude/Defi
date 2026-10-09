import ApplicationServices
import DefiConfig
import DefiModel
import DefiRuntime
import Synchronization
import Testing
@testable import DefiMacOS

final class DiscoveryReadFixture: Sendable {
  struct State: Sendable {
    var now = 0.0
    var listCalls: [pid_t: Int] = [:]
    var attributeCalls = 0
    var relationshipCalls = 0
    var active = 0
    var maximumActive = 0
    var delay = 0.0
    var windowLists = AssumedThreadSafe<[pid_t: [AXUIElement]]>([:])
    var windowsByHash: [UInt: Window] = [:]
    var failsProcess: pid_t? = 41
    var revealsNewWindow = true
  }
  let state = Mutex(State())
  private let newElementBox = AssumedThreadSafe(AXUIElementCreateApplication(-42001))
  var newElement: AXUIElement { newElementBox.value }
  let frame = Rect(x: 10, y: 20, width: 400, height: 300)
  var windowLists: [pid_t: [AXUIElement]] {
    get { state.withLock { $0.windowLists }.value }
    set {
      let lists = AssumedThreadSafe(newValue)
      state.withLock { $0.windowLists = lists }
    }
  }
  var windowsByHash: [UInt: Window] {
    get { state.withLock { $0.windowsByHash } }
    set { state.withLock { $0.windowsByHash = newValue } }
  }
  var failsProcess: pid_t? {
    get { state.withLock { $0.failsProcess } }
    set { state.withLock { $0.failsProcess = newValue } }
  }
  var revealsNewWindow: Bool {
    get { state.withLock { $0.revealsNewWindow } }
    set { state.withLock { $0.revealsNewWindow = newValue } }
  }

  func access() -> DiscoveryMeasurementAccess {
    DiscoveryMeasurementAccess(now: { self.state.withLock { $0.now } }, applicationWindows: { _, pid in
      self.state.withLock { state in
        state.listCalls[pid, default: 0] += 1
        if pid == state.failsProcess { return nil }
        if state.revealsNewWindow, pid == 42, state.now >= 0.24 {
          return [self.newElement]
        }
        return state.windowLists.value[pid] ?? []
      }
    }, windowAttributes: { element, pid in
      let delay = self.state.withLock {
        $0.attributeCalls += 1
        $0.active += 1
        $0.maximumActive = max($0.maximumActive, $0.active)
        return $0.delay
      }
      if delay > 0 { Thread.sleep(forTimeInterval: delay) }
      self.state.withLock { $0.active -= 1 }
      let window = self.windowsByHash[CFHash(element)]
      return AXWindowAttributes(minimized: false, frame: window?.frame ?? self.frame,
        title: window?.title ?? "new", role: kAXWindowRole, subrole: kAXStandardWindowSubrole, modal: false)
    }, relationships: { _ in
      self.state.withLock { $0.relationshipCalls += 1 }
      return (nil, [])
    })
  }
}

struct DiscoveryRetryPerformanceTests {
  @MainActor @Test
  func knownProcessRetriesPerformance() {
    let start = ProcessInfo.processInfo.systemUptime
    let platform = NavigationActor.shared.queue.sync {
      NavigationActor.assumeIsolated { MacOSPlatform() }
    }
    let engine = platform.snapshotEngine
    let fixture = DiscoveryReadFixture()
    engine.discoveryMeasurementAccess = fixture.access()
    let pids = Set((41...49).map { pid_t($0) })
    engine.applications = Dictionary(uniqueKeysWithValues: pids.map { ($0, AXUIElementCreateApplication(-$0)) })
    engine.applicationIDsByProcess = Dictionary(uniqueKeysWithValues: pids.map { ($0, "app-\($0)") })
    engine.enhancedUIByProcess = Dictionary(uniqueKeysWithValues: pids.map { ($0, false) })
    engine.lastApplicationWindowElements = Dictionary(uniqueKeysWithValues: pids.map { ($0, []) })
    engine.hasCompletedWindowSnapshot = true
    engine.windowListReadRetryAttemptsByProcess = [41: 0]
    NavigationActor.shared.queue.sync {
      NavigationActor.assumeIsolated { platform.presentationStatus.topologyReliable = true }
    }
    var nextGlobal = 0.25
    var discoveryAt: Double? = nil
    var globalPasses = 0
    var passes = 0
    let config = Config(rules: [Rule(appID: "app-42", floating: true)])
    for index in 0...35 {
      let now = Double(index) / 100
      fixture.state.withLock { $0.now = now }
      let decision = NavigationActor.shared.queue.sync {
        NavigationActor.assumeIsolated {
          let interval = platform.recommendedGlobalWindowListRefreshInterval
          let retry = platform.nextWindowDiscoveryRetryAt
          nextGlobal = boundedSnapshotRefreshDeadline(current: nextGlobal, now: now,
            interval: interval, reset: false)
          let due = platform.dueWindowDiscoveryRetryProcessIDs(now: now)
          return (windowDiscoveryRefreshRequest(now: now, globalDeadline: nextGlobal, interval: interval,
            retryDeadline: retry, userInputIdleDuration: 2, dueProcessIDs: due), due)
        }
      }
      guard decision.0.due else { continue }
      passes += 1
      if decision.0.global { globalPasses += 1 }
      let cg = now >= 0.24 ? [CGWindowRecord(id: 42001, processID: 42, layer: 0,
        title: "new", frame: fixture.frame, isOnscreen: true)] : []
      let result = engine.discoverSnapshotWindows(monitors: [], config: config,
        incrementalProcessIDs: decision.0.global ? nil : decision.1,
        forceWindowListRefresh: decision.0.global,
        forceWindowListRefreshProcessIDs: decision.1,
        forceApplicationInventoryRefresh: false, capturedTopologyRequiresFullSnapshot: false,
        topologyProcessIDs: [], createdElements: [:], preparedWindowAttributes: [:],
        preparedTransientOwnerWindowIDs: [:], preparedApplicationWindows: [:],
        explicitlyDestroyedWindowIDs: [], publicCGWindows: { cg })
      engine.elements = result.nextElements
      engine.processIDs = result.nextProcessIDs
      engine.lastSnapshotWindows = result.windows
      engine.lastApplicationWindowElements = result.applicationWindows
      engine.retainedWindowIDs = result.nextRetainedWindowIDs
      if result.windows.contains(where: { $0.id.rawValue == 42001 }), discoveryAt == nil {
        discoveryAt = now
      }
      NavigationActor.shared.queue.sync {
        NavigationActor.assumeIsolated {
          nextGlobal = windowDiscoveryGlobalDeadline(current: nextGlobal, now: now,
            interval: platform.recommendedGlobalWindowListRefreshInterval,
            globalRefresh: decision.0.global, targetedRefresh: decision.0.targeted)
        }
      }
    }
    #expect(discoveryAt != nil)
    #expect(engine.windowListReadRetryAttemptsByProcess[41] == 3)
    let state = fixture.state.withLock { $0 }
    emitDiscoveryPerformance("known-process-retries", operations: 36,
      output: ["new_window": discoveryAt == nil ? 0 : 1, "attempts": engine.windowListReadRetryAttemptsByProcess[41] ?? -1],
      metrics: ["healthy_list_reads": Double(state.listCalls.filter { $0.key != 41 }.values.reduce(0, +)),
                "failed_list_reads": Double(state.listCalls[41] ?? 0),
                "global_passes": Double(globalPasses), "passes": Double(passes),
                "discovery_at_ms": (discoveryAt ?? 0) * 1000,
                "elapsed_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000])
  }
}
