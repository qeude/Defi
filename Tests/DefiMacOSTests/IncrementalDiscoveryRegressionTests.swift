import ApplicationServices
import DefiConfig
import DefiModel
import DefiRuntime
import Synchronization
import Testing
@testable import DefiMacOS

struct IncrementalDiscoveryRegressionTests {
  @MainActor private func fixture() -> (MacOSPlatform, DiscoveryReadFixture, Window, AXUIElement) {
    let platform = NavigationActor.shared.queue.sync { NavigationActor.assumeIsolated { MacOSPlatform() } }
    let engine = platform.snapshotEngine
    let reads = DiscoveryReadFixture()
    reads.revealsNewWindow = false
    reads.failsProcess = nil
    let element = AXUIElementCreateApplication(-61001)
    let window = Window(id: WindowID(rawValue: 4101), appID: "measurement", title: "known", frame: reads.frame,
      role: kAXWindowRole, subrole: kAXStandardWindowSubrole, processID: 41, floating: true, floatingOrigin: .configured)
    reads.windowLists = [41: [element]]
    reads.windowsByHash = [CFHash(element): window]
    engine.discoveryMeasurementAccess = reads.access()
    engine.applications = [41: AXUIElementCreateApplication(-41)]
    engine.applicationIDsByProcess = [41: "measurement"]
    engine.enhancedUIByProcess = [41: false]
    engine.hasCompletedWindowSnapshot = true
    engine.overviewPresentationActive = true
    engine.elements = [window.id: element]
    engine.processIDs = [window.id: 41]
    engine.lastApplicationWindowElements = [41: [element]]
    engine.lastSnapshotWindows = [window]
    engine.retainedWindowDeadlines = [window.id: 1]
    return (platform, reads, window, element)
  }

  @MainActor @Test(arguments: [false, true])
  func failedReadsAreDeliveredOnce(preparedFullRead: Bool) {
    let (platform, reads, window, _) = fixture()
    let engine = platform.snapshotEngine
    defer { withExtendedLifetime(platform) {} }
    reads.failsProcess = 41
    var access = reads.access()
    access.windowAttributes = { _, _ in
      reads.state.withLock { $0.attributeCalls += 1 }
      return AXWindowAttributes(minimized: nil, frame: nil, title: "", role: nil, subrole: nil)
    }
    engine.discoveryMeasurementAccess = access
    let prepared = preparedFullRead ? engine.prepareWindowAttributes(processIDs: [41])
      : (attributes: [:], owners: [:], applications: [:])
    let result = engine.discoverSnapshotWindows(monitors: [], config: Config(rules: [Rule(appID: "measurement", floating: true)]),
      incrementalProcessIDs: [41], forceWindowListRefresh: true, forceApplicationInventoryRefresh: false,
      capturedTopologyRequiresFullSnapshot: false, topologyProcessIDs: [], createdElements: [:],
      preparedWindowAttributes: prepared.attributes, preparedTransientOwnerWindowIDs: prepared.owners,
      preparedApplicationWindows: prepared.applications, explicitlyDestroyedWindowIDs: [],
      publicCGWindows: { [CGWindowRecord(id: 4101, processID: 41, layer: 0, title: window.title, frame: window.frame, isOnscreen: true)] })
    #expect(reads.state.withLock { $0.listCalls[41] } == 1)
    #expect(reads.state.withLock { $0.attributeCalls } == 1)
    #expect(result.windows.map(\.id) == [window.id])
    #expect(result.nextRetainedWindowIDs == [window.id])
    #expect(result.nextElements[window.id] != nil)
  }

  @MainActor @Test func removedCachedWindowHasNoPreparedAttributeRead() {
    let (platform, reads, _, _) = fixture()
    let engine = platform.snapshotEngine
    defer { withExtendedLifetime(platform) {} }
    reads.windowLists = [41: []]
    let result = engine.discoverSnapshotWindows(monitors: [], config: Config(), incrementalProcessIDs: [41],
      forceWindowListRefresh: true, forceApplicationInventoryRefresh: false, capturedTopologyRequiresFullSnapshot: false,
      topologyProcessIDs: [], createdElements: [:], preparedWindowAttributes: [:], preparedTransientOwnerWindowIDs: [:],
      preparedApplicationWindows: [:], explicitlyDestroyedWindowIDs: [], publicCGWindows: { [] })
    #expect(reads.state.withLock { $0.listCalls[41] } == 1)
    #expect(reads.state.withLock { $0.attributeCalls } == 0)
    #expect(result.windows.isEmpty)
  }

  @MainActor @Test(arguments: [false, true])
  func invalidatedPreparedDeliveryIsDropped(inputChanged: Bool) {
    let (platform, reads, window, _) = fixture()
    let engine = platform.snapshotEngine
    defer { withExtendedLifetime(platform) {} }
    let touched = Mutex(false)
    var access = reads.access()
    let base = access.windowAttributes
    access.windowAttributes = { element, pid in
      let first = touched.withLock { flag in let previous = flag; flag = true; return !previous }
      if first {
        if inputChanged { engine.userInputTracker.recordCapturedCommand(at: 99) }
        else { engine.recordObservation(.frame, processID: pid, windowID: window.id) }
      }
      return base(element, pid)
    }
    engine.discoveryMeasurementAccess = access
    let prepared = engine.prepareIncrementalDiscoveryReads(processIDs: [41], listProcessIDs: [],
      windowListRefreshProcessIDs: [], frameRefreshWindowIDs: [window.id], explicitlyDestroyedWindowIDs: [],
      shouldReadProcess: { _ in true })
    #expect(prepared.attributes.isEmpty)
    #expect(reads.state.withLock { $0.attributeCalls } == 1)
  }
  @MainActor @Test func failedOwnerLookupDoesNotRepeatItsPreparedRead() {
    let (platform, reads, window, _) = fixture()
    let engine = platform.snapshotEngine
    defer { withExtendedLifetime(platform) {} }
    var access = reads.access()
    let base = access.windowAttributes
    access.windowAttributes = { element, pid in
      let attributes = base(element, pid)
      return AXWindowAttributes(minimized: attributes.minimized, frame: attributes.frame, title: attributes.title,
        role: attributes.role, subrole: attributes.subrole, modal: true)
    }
    engine.discoveryMeasurementAccess = access
    let result = engine.discoverSnapshotWindows(monitors: [], config: Config(rules: [Rule(appID: "measurement", floating: true)]),
      incrementalProcessIDs: [41], forceWindowListRefresh: false, forceApplicationInventoryRefresh: false,
      capturedTopologyRequiresFullSnapshot: false, topologyProcessIDs: [], createdElements: [:],
      preparedWindowAttributes: [:], preparedTransientOwnerWindowIDs: [:], preparedApplicationWindows: [:],
      explicitlyDestroyedWindowIDs: [], frameRefreshWindowIDs: [window.id],
      publicCGWindows: { [CGWindowRecord(id: 4101, processID: 41, layer: 0, title: window.title, frame: window.frame)] })
    #expect(result.windows.map(\.id) == [window.id])
    #expect(reads.state.withLock { $0.attributeCalls } == 1)
    #expect(reads.state.withLock { $0.relationshipCalls } == 1)
    #expect(engine.transientOwnerResolutionAttempts[window.id] == 1)
  }

  @MainActor @Test func nonBatchedPreparationKeepsRelationshipsOnly() {
    let (platform, reads, window, _) = fixture()
    let engine = platform.snapshotEngine
    defer { withExtendedLifetime(platform) {} }
    engine.multipleAttributeReadsSupportedByProcess = [41: false]
    let prepared = engine.prepareWindowAttributes(processIDs: [41])
    #expect(prepared.attributes.isEmpty)
    #expect(reads.state.withLock { $0.attributeCalls } == 0)
    #expect(reads.state.withLock { $0.relationshipCalls } == 1)
    #expect(reads.state.withLock { $0.listCalls[41] } == 1)
    let result = engine.discoverSnapshotWindows(monitors: [], config: Config(rules: [Rule(appID: "measurement", floating: true)]),
      incrementalProcessIDs: [41], forceWindowListRefresh: true, forceApplicationInventoryRefresh: false,
      capturedTopologyRequiresFullSnapshot: false, topologyProcessIDs: [], createdElements: [:],
      preparedWindowAttributes: prepared.attributes, preparedTransientOwnerWindowIDs: prepared.owners,
      preparedApplicationWindows: prepared.applications, explicitlyDestroyedWindowIDs: [],
      publicCGWindows: { [CGWindowRecord(id: 4101, processID: 41, layer: 0, title: window.title, frame: window.frame)] })
    #expect(result.windows.map(\.id) == [window.id])
    #expect(reads.state.withLock { $0.attributeCalls } == 1)
    #expect(reads.state.withLock { $0.relationshipCalls } == 1)
    #expect(reads.state.withLock { $0.listCalls[41] } == 1)
  }

  @MainActor @Test(arguments: [false, true])
  func deferredNonBatchedProcessPerformsNoReads(fullPreparation: Bool) {
    let (platform, reads, window, _) = fixture()
    let engine = platform.snapshotEngine
    defer { withExtendedLifetime(platform) {} }
    engine.multipleAttributeReadsSupportedByProcess = [41: false]
    var admissions = 0
    let eligible: (pid_t) -> Bool = { _ in admissions += 1; return false }
    if fullPreparation { _ = engine.prepareWindowAttributes(processIDs: [41], shouldReadProcess: eligible) }
    else {
      let result = engine.discoverSnapshotWindows(monitors: [], config: Config(), incrementalProcessIDs: [41],
        forceWindowListRefresh: true, forceApplicationInventoryRefresh: false,
        capturedTopologyRequiresFullSnapshot: false, topologyProcessIDs: [], createdElements: [:],
        preparedWindowAttributes: [:], preparedTransientOwnerWindowIDs: [:], preparedApplicationWindows: [:],
        explicitlyDestroyedWindowIDs: [], shouldReadProcess: eligible, publicCGWindows: { [] })
      #expect(result.windows.map(\.id) == [window.id])
    }
    #expect(admissions == 1)
    #expect(reads.state.withLock { $0.attributeCalls } == 0)
    #expect(reads.state.withLock { $0.relationshipCalls } == 0)
    #expect(reads.state.withLock { $0.listCalls.values.reduce(0, +) } == 0)
  }

  @MainActor @Test func plannerWithoutInjectedAXDelayIsMeasuredSeparately() {
    let (platform, reads, first, element) = fixture()
    let engine = platform.snapshotEngine
    defer { withExtendedLifetime(platform) {} }
    for index in 2...4 {
      let id = WindowID(rawValue: 4100 + UInt64(index))
      let siblingElement = AXUIElementCreateApplication(-61000 - Int32(index))
      var sibling = first
      sibling = Window(id: id, appID: first.appID, title: "sibling-\(index)",
        frame: Rect(x: Double(index * 410), y: 20, width: 400, height: 300),
        role: first.role, subrole: first.subrole, processID: 41, floating: true, floatingOrigin: .configured)
      engine.elements[id] = siblingElement
      engine.processIDs[id] = 41
      engine.lastSnapshotWindows.append(sibling)
      engine.lastApplicationWindowElements[41, default: []].append(siblingElement)
      reads.windowsByHash[CFHash(siblingElement)] = sibling
    }
    let bindings: [pid_t: [UInt: [WindowID]]] = [41: Dictionary(uniqueKeysWithValues: engine.elements.map { (CFHash($0.value), [$0.key]) })]
    var direct: [Double] = []
    var planned: [Double] = []
    for _ in 0..<300 {
      var start = ProcessInfo.processInfo.systemUptime
      _ = engine.windowAttributes(element, processID: 41)
      direct.append((ProcessInfo.processInfo.systemUptime - start) * 1_000_000)
      start = ProcessInfo.processInfo.systemUptime
      let batch = engine.prepareIncrementalDiscoveryReads(processIDs: [41], listProcessIDs: [],
        windowListRefreshProcessIDs: [], existingWindowIDsByProcessAndElementHash: bindings, frameRefreshWindowIDs: [first.id], explicitlyDestroyedWindowIDs: [],
        shouldReadProcess: { _ in true })
      planned.append((ProcessInfo.processInfo.systemUptime - start) * 1_000_000)
      #expect(batch.attributes.count == 1)
    }
    direct.sort(); planned.sort()
    #expect(reads.state.withLock { $0.attributeCalls } == 600)
    #expect(reads.state.withLock { $0.listCalls.values.reduce(0, +) } == 0)
    #expect(reads.state.withLock { $0.relationshipCalls } == 0)
    emitDiscoveryPerformance("planner-without-injected-delay", operations: 600,
      output: ["attribute_reads": 600, "correct_plans": 300, "list_reads": 0, "relationship_reads": 0],
      metrics: ["direct_hook_median_us": direct[150], "planner_collector_median_us": planned[150],
        "planner_collector_min_us": planned[0], "planner_collector_max_us": planned[299],
        "planner_collector_p05_us": planned[15], "planner_collector_p95_us": planned[285]])
  }

  @MainActor @Test func singleProcessSnapshotPreservesUnobservedCachedGeometry() {
    let (platform, reads, window, _) = fixture()
    let engine = platform.snapshotEngine
    defer { withExtendedLifetime(platform) {} }
    let siblingElement = AXUIElementCreateApplication(-61002)
    let sibling = Window(id: WindowID(rawValue: 4102), appID: "measurement", title: "sibling",
      frame: Rect(x: 500, y: 20, width: 400, height: 300), role: kAXWindowRole,
      subrole: kAXStandardWindowSubrole, processID: 41, floating: true, floatingOrigin: .configured)
    engine.elements[sibling.id] = siblingElement
    engine.processIDs[sibling.id] = 41
    engine.lastApplicationWindowElements[41, default: []].append(siblingElement)
    engine.lastSnapshotWindows.append(sibling)
    let cg = [CGWindowRecord(id: 4101, processID: 41, layer: 0, title: "known",
      frame: Rect(x: 10, y: 20, width: 400, height: 300), isOnscreen: true),
      CGWindowRecord(id: 4102, processID: 41, layer: 0, title: "sibling",
        frame: Rect(x: 500, y: 20, width: 400, height: 300), isOnscreen: true)]
    var access = reads.access()
    access.snapshotCGWindows = { cg }
    access.nativeFocus = { _ in nil }
    engine.discoveryMeasurementAccess = access
    engine.publishCGWindowInventory(CGWindowInventory(records: cg, generation: 0,
      capturedAt: ProcessInfo.processInfo.systemUptime))
    engine.recordObservation(.frame, processID: 41, windowID: window.id)
    let snapshot = engine.snapshot(config: Config(rules: [Rule(appID: "measurement", floating: true)]),
      forceFullWindowRefresh: false, forceWindowListRefresh: false, forceApplicationInventoryRefresh: false)
    let observed = snapshot.windows.sorted { $0.id.rawValue < $1.id.rawValue }
    #expect(observed.map { $0.id.rawValue } == [4101, 4102])
    #expect(observed.map(\.frame) == [Rect(x: 10, y: 20, width: 400, height: 300),
      Rect(x: 500, y: 20, width: 400, height: 300)])
    #expect(observed.map(\.title) == ["known", "sibling"])
    #expect(observed.map { $0.processID } == [41, 41])
    #expect(observed.allSatisfy { $0.floating && $0.floatingOrigin == .configured })
    #expect(reads.state.withLock { $0.attributeCalls } == 1)
    #expect(reads.state.withLock { $0.listCalls.values.reduce(0, +) } == 0)
    #expect(reads.state.withLock { $0.relationshipCalls } == 0)
  }

}
