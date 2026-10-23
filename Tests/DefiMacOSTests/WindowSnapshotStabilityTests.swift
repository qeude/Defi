import ApplicationServices
import DefiConfig
import DefiModel
import DefiRuntime
import Testing
import Synchronization

@testable import DefiMacOS

struct WindowSnapshotStabilityTests {
  @MainActor
  @Test(arguments: [(nil, Optional(kAXStandardWindowSubrole)), (Optional(kAXWindowRole), nil)])
  func missingRoleMetadataPreservesMaximizedColumn(metadata: (String?, String?)) throws {
    let platform = NavigationActor.shared.queue.sync {
      NavigationActor.assumeIsolated { MacOSPlatform() }
    }
    let engine = platform.snapshotEngine
    let window = makeWindow(id: 42)
    let element = AXUIElementCreateApplication(-1)
    engine.elements = [window.id: element]
    engine.processIDs = [window.id: processID]
    engine.applications = [processID: element]
    engine.applicationIDsByProcess = [processID: window.appID]
    engine.enhancedUIByProcess = [processID: false]
    engine.hasCompletedWindowSnapshot = true
    engine.lastSnapshotWindows = [window]
    engine.lastApplicationWindowElements = [processID: [element]]
    var config = Config()
    config.layout.defaultColumnWidth = 0.5
    var state = RuntimeState(config: config)
    let monitorID = MonitorID(rawValue: 1)
    state.attachMonitor(monitorID)
    reconcileWindows([window], config: config, state: &state)
    try reduce(.maximizeColumn, on: monitorID, state: &state)

    let result = engine.discoverSnapshotWindows(
      monitors: [], config: config, incrementalProcessIDs: [processID],
      forceWindowListRefresh: false, forceApplicationInventoryRefresh: false,
      capturedTopologyRequiresFullSnapshot: false, topologyProcessIDs: [], createdElements: [:],
      preparedWindowAttributes: [window.id: AXWindowAttributes(
        minimized: false, frame: frame, title: window.title,
        role: metadata.0, subrole: metadata.1
      )],
      preparedTransientOwnerWindowIDs: [:], preparedApplicationWindows: [:],
      explicitlyDestroyedWindowIDs: [], publicCGWindows: { [makeCGWindow(id: 42)] }
    )
    #expect(result.nextRetainedWindowIDs == [window.id])
    #expect(result.ignoredWindowReasonsByID[window.id] == nil)
    reconcileWindows(result.windows, config: config, state: &state)
    reconcileWindows([window], config: config, state: &state)
    #expect(state.monitors[0].workspaces[0].columns[0].width == .fraction(1))
    #expect(state.monitors[0].workspaces[0].columns[0].preMaximizedWidth == .fraction(0.5))
  }

  @Test(arguments: [PlatformEventKind.windows, .focus, .frame, .mouseRelease])
  func preparedReadsSurviveAnUnrelatedProcessObservation(kind: PlatformEventKind) {
    let engine = SnapshotEngine(frameCoordinator: AXFrameCoordinator(), userInputTracker: UserInputTracker())
    let captured = engine.preparedWindowReadRevisions
    let inventoryGeneration = engine.windowSnapshotObservationGeneration
    engine.recordObservation(kind, processID: 42)
    #expect(engine.windowSnapshotObservationGeneration != inventoryGeneration)
    #expect(engine.preparedWindowReadRevisions.invalidatedProcessIDs(
      since: captured, candidates: [42, 43]
    ) == [42])
    engine.invalidateWindowSnapshot()
    #expect(engine.preparedWindowReadRevisions.invalidatedProcessIDs(
      since: captured, candidates: [42, 43]
    ) == [42, 43])
  }

  @Test(arguments: [false, true])
  func preparedFrameRefreshInvalidationKeepsItsScope(full: Bool) {
    let engine = SnapshotEngine(frameCoordinator: AXFrameCoordinator(), userInputTracker: UserInputTracker())
    let captured = engine.preparedWindowReadRevisions
    engine.recordFrameRefresh(windowIDs: [], processIDs: [42], requiresFullSnapshot: full)
    #expect(engine.preparedWindowReadRevisions.invalidatedProcessIDs(
      since: captured, candidates: [42, 43]
    ) == (full ? [42, 43] : [42]))
    let afterScopedRefresh = engine.preparedWindowReadRevisions
    engine.recordObservation(.frame, processID: nil)
    #expect(engine.preparedWindowReadRevisions.invalidatedProcessIDs(
      since: afterScopedRefresh, candidates: [42, 43]
    ).isEmpty)
  }

  @Test(arguments: [PlatformEventKind.frame, .mouse, .mouseRelease])
  func unscopedMotionObservationsPreservePreparedReads(kind: PlatformEventKind) {
    let engine = SnapshotEngine(frameCoordinator: AXFrameCoordinator(), userInputTracker: UserInputTracker())
    let captured = engine.preparedWindowReadRevisions
    let inventoryGeneration = engine.windowSnapshotObservationGeneration

    engine.recordObservation(kind, processID: nil)

    #expect(engine.windowSnapshotObservationGeneration != inventoryGeneration)
    #expect(engine.preparedWindowReadRevisions.invalidatedProcessIDs(
      since: captured, candidates: [42, 43]
    ).isEmpty)
  }

  @Test
  func unknownWindowAndAccessibilityResetInvalidateAllPreparedReads() {
    let engine = SnapshotEngine(frameCoordinator: AXFrameCoordinator(), userInputTracker: UserInputTracker())
    var captured = engine.preparedWindowReadRevisions
    engine.recordFrameRefresh(
      windowIDs: [WindowID(rawValue: 99)], processIDs: [42], requiresFullSnapshot: false
    )
    #expect(engine.preparedWindowReadRevisions.invalidatedProcessIDs(
      since: captured, candidates: [42, 43]
    ) == [42, 43])
    captured = engine.preparedWindowReadRevisions
    engine.invalidateAccessibilitySession()
    #expect(engine.preparedWindowReadRevisions.invalidatedProcessIDs(
      since: captured, candidates: [42, 43]
    ) == [42, 43])
  }

  @Test
  func retentionRepairYieldsToMotionOnlyWithinItsExistingGraceDeadline() {
    let first = WindowID(rawValue: 1), expiring = WindowID(rawValue: 2)
    let unknown = WindowID(rawValue: 3), sibling = WindowID(rawValue: 4)
    let ids: Set<WindowID> = [first, expiring, unknown, sibling]
    let processes: [WindowID: pid_t] = [first: 101, expiring: 102, unknown: 103, sibling: 101]
    let deadlines: [WindowID: TimeInterval] = [first: 11, expiring: 10.5, sibling: 11]
    var urgent = retainedWindowRefreshProcessIDs(
      retainedWindowIDs: ids, processIDs: processes, deadlines: deadlines, deferringUntil: 10.5
    )
    #expect(urgent == [102, 103])
    let partition = budgetedFreshReadPartition(
      requestedProcessIDs: [101, 102, 103], deferredProcessIDs: [],
      eventPendingProcessIDs: urgent, predictedLatencyMS: { _ in 50 }, budgetMS: 12,
      defersBackgroundReads: true, maximumDeferredAgeSeconds: 0.5, deferredSince: nil, now: 10
    )
    #expect(partition.allowedNow == [102, 103])
    #expect(partition.stillDeferred == [101])
    urgent.formUnion([101]) // A native focus, close, or resize always takes priority.
    let event = budgetedFreshReadPartition(
      requestedProcessIDs: [], deferredProcessIDs: partition.stillDeferred,
      eventPendingProcessIDs: urgent, predictedLatencyMS: { _ in 50 }, budgetMS: 12,
      defersBackgroundReads: true, maximumDeferredAgeSeconds: 0.5,
      deferredSince: partition.deferredSince, now: 10.1
    )
    #expect(event.allowedNow == [101, 102, 103])
    #expect(retainedWindowRefreshProcessIDs(
      retainedWindowIDs: ids, processIDs: processes, deadlines: deadlines
    ) == [101, 102, 103])
    #expect(retainedWindowRefreshProcessIDs(
      retainedWindowIDs: ids, processIDs: processes,
      deadlines: deadlines.merging([sibling: 10.4]) { _, new in new }, deferringUntil: 10.5
    ) == [101, 102, 103])
  }

  @Test(arguments: [2, 4])
  func preparedReadsOverlapIndependentProcessesAndRecheckQueuedAdmission(limit: Int) {
    let state = Mutex((active: 0, maximum: 0, started: Set<pid_t>(), permitsNewReads: true))
    let release = DispatchSemaphore(value: 0)
    let jobs = (1...(limit + 2)).map {
      PreparedAXProcessRead(processID: pid_t($0), windows: [], application: nil)
    }
    let results = collectPreparedAXProcessReads(
      jobs, maximumConcurrent: limit,
      shouldStart: { _ in state.withLock { $0.permitsNewReads } },
      read: { job in
        let reachedLimit = state.withLock {
          $0.active += 1
          $0.maximum = max($0.maximum, $0.active)
          $0.started.insert(job.processID)
          return $0.active == limit
        }
        if reachedLimit { for _ in 0..<limit { release.signal() } }
        #expect(release.wait(timeout: .now() + 3) == .success)
        state.withLock { $0.active -= 1; $0.permitsNewReads = false }
        return PreparedAXProcessReadResult(processID: job.processID, windows: [], application: nil)
      }
    )
    #expect(state.withLock { $0.maximum } == limit)
    #expect(state.withLock { $0.started } == Set((1...limit).map { pid_t($0) }))
    #expect(results.map(\.processID) == (1...limit).map { pid_t($0) })
  }

  @Test
  func cachedDiscoveryOnlyDefersAnExplicitlyRequestedProcess() {
    let engine = SnapshotEngine(frameCoordinator: AXFrameCoordinator(), userInputTracker: UserInputTracker())
    let requested = makeWindow(id: 42)
    var omitted = makeWindow(id: 43)
    omitted.processID = 43
    let requestedElement = AXUIElementCreateApplication(-1)
    let omittedElement = AXUIElementCreateApplication(-2)
    engine.elements = [requested.id: requestedElement, omitted.id: omittedElement]
    engine.processIDs = [requested.id: 42, omitted.id: 43]
    engine.applications = [42: requestedElement, 43: omittedElement]
    engine.applicationIDsByProcess = [42: requested.appID, 43: omitted.appID]
    engine.enhancedUIByProcess = [42: false, 43: false]
    engine.multipleAttributeReadsSupportedByProcess = [42: false, 43: false]
    engine.hasCompletedWindowSnapshot = true
    engine.lastSnapshotWindows = [requested, omitted]
    engine.lastApplicationWindowElements = [42: [requestedElement], 43: [omittedElement]]
    var visited: [pid_t] = []
    let result = engine.discoverSnapshotWindows(
      monitors: [], config: Config(), incrementalProcessIDs: [42],
      forceWindowListRefresh: false, forceApplicationInventoryRefresh: false,
      capturedTopologyRequiresFullSnapshot: false, topologyProcessIDs: [], createdElements: [:],
      preparedWindowAttributes: [:], preparedTransientOwnerWindowIDs: [:],
      preparedApplicationWindows: [:], explicitlyDestroyedWindowIDs: [],
      shouldReadProcess: { pid in
        visited.append(pid)
        return false
      },
      publicCGWindows: { [requested, omitted].map {
        CGWindowRecord(id: CGWindowID($0.id.rawValue), processID: $0.processID!, layer: 0,
                       title: $0.title, frame: $0.frame, isOnscreen: true)
      } }
    )

    #expect(visited == [42])
    #expect(result.cachedSnapshotWindowIDs == [requested.id, omitted.id])
    #expect(result.windows.contains(requested))
    #expect(result.windows.contains(omitted))
    #expect(result.applicationWindows[43] == [omittedElement])
    let expired = budgetedFreshReadPartition(
      requestedProcessIDs: [], deferredProcessIDs: [42], eventPendingProcessIDs: [],
      predictedLatencyMS: { _ in 100 }, budgetMS: 1, defersBackgroundReads: true,
      maximumDeferredAgeSeconds: 0.5, deferredSince: 10, now: 10.5
    )
    #expect(expired.allowedNow == [42])
  }

  @Test(arguments: [false, true], [false, true])
  func targetedFrameRefreshDoesNotReadUnaffectedSiblings(targeted: Bool, refreshList: Bool) {
    let engine = SnapshotEngine(frameCoordinator: AXFrameCoordinator(), userInputTracker: UserInputTracker())
    let first = makeWindow(id: 42), second = makeWindow(id: 43)
    // Invalid handles count real discovery attempts without touching user windows.
    let firstElement = AXUIElementCreateApplication(-1), secondElement = AXUIElementCreateApplication(-2)
    engine.elements = [first.id: firstElement, second.id: secondElement]
    engine.processIDs = [first.id: processID, second.id: processID]
    engine.applications = [processID: firstElement]
    engine.applicationIDsByProcess = [processID: first.appID]
    engine.enhancedUIByProcess = [processID: false]
    engine.multipleAttributeReadsSupportedByProcess = [processID: false]
    engine.hasCompletedWindowSnapshot = true
    // A native transition can leave duplicate observations in the previous cache.
    engine.lastSnapshotWindows = [first, second, second]
    engine.lastApplicationWindowElements = [processID: [firstElement, secondElement]]
    let result = engine.discoverSnapshotWindows(
      monitors: [], config: Config(), incrementalProcessIDs: [processID],
      forceWindowListRefresh: refreshList, forceApplicationInventoryRefresh: false,
      capturedTopologyRequiresFullSnapshot: false, topologyProcessIDs: [], createdElements: [:],
      preparedWindowAttributes: [:], preparedTransientOwnerWindowIDs: [:],
      preparedApplicationWindows: [processID: PreparedAXApplicationWindows(
        elements: [firstElement, secondElement], durationMS: 0
      )], explicitlyDestroyedWindowIDs: [], frameRefreshWindowIDs: targeted ? [first.id] : nil,
      publicCGWindows: { [first, second].map {
        CGWindowRecord(id: CGWindowID($0.id.rawValue), processID: processID, layer: 0,
                       title: $0.title, frame: $0.frame, isOnscreen: true)
      } }
    )
    let reusesSibling = targeted && !refreshList
    #expect(engine.fallbackWindowAttributeReadCount == (reusesSibling ? 1 : 2))
    #expect(result.cachedSnapshotWindowIDs == (reusesSibling ? [second.id] : []))
    #expect(result.nextElements[second.id] != nil)
    #expect(result.windows.first { $0.id == second.id } == second)
  }

  @Test("An unresolved window is kept only until discovery or WindowServer settles it", .bug(id: 89))
  func unresolvedWindowIsKeptOnlyUntilDiscoveryOrWindowServerSettlesIt() {
    let window = makeWindow(id: 42)
    func retained(discovered: Set<WindowID> = [], cg: [CGWindowRecord]?,
      state: ((WindowID) -> (error: AXError, minimized: Bool?))?) -> Set<WindowID> {
      cachedWindowIDsToRetain(processID: processID, previousWindows: [window], discoveredWindowIDs: discovered,
        ignoredWindowIDs: [], unresolvedWindowIDs: [window.id], cgWindows: cg, cachedWindowState: state)
    }
    func record(process: pid_t, onscreen: Bool) -> CGWindowRecord {
      CGWindowRecord(id: 42, processID: process, layer: 0, title: window.title, frame: window.frame,
        isOnscreen: onscreen)
    }
    #expect(retained(cg: nil, state: nil) == [window.id])
    #expect(retained(discovered: [window.id], cg: nil, state: nil).isEmpty, "a newly discovered window wins")
    #expect(retained(cg: nil, state: { _ in (.invalidUIElement, nil) }) == [window.id],
      "an invalid AX read without CG inventory keeps it")
    #expect(retained(cg: [record(process: processID, onscreen: false)], state: { _ in (.invalidUIElement, nil) })
      .isEmpty, "a confirmed closure is not revived")
    #expect(retained(cg: [record(process: processID + 1, onscreen: true)], state: { _ in (.cannotComplete, nil) })
      .isEmpty, "WindowServer reassigned its ID to another process")
  }

  @Test func createdWindowBypassesLaggingApplicationWindowList() {
    let engine = SnapshotEngine(frameCoordinator: AXFrameCoordinator(), userInputTracker: UserInputTracker())
    let processID: pid_t = 42
    let created = AXUIElementCreateApplication(-2)
    engine.applications = [processID: AXUIElementCreateApplication(-1)]
    engine.applicationIDsByProcess = [processID: "test"]
    engine.enhancedUIByProcess = [processID: false]
    engine.lastApplicationWindowElements = [processID: []]
    engine.hasCompletedWindowSnapshot = true
    engine.recordObservation(.windowCreated, processID: processID, createdElement: created)
    let observations = engine.consumeObservations()
    engine.recordObservation(.windowCreated, processID: processID, createdElement: created)
    let result = engine.discoverSnapshotWindows(
      monitors: [], config: Config(), incrementalProcessIDs: [processID],
      forceWindowListRefresh: false, forceApplicationInventoryRefresh: false,
      capturedTopologyRequiresFullSnapshot: false, topologyProcessIDs: observations.topologyProcessIDs,
      createdElements: observations.createdElements, preparedWindowAttributes: [:],
      preparedTransientOwnerWindowIDs: [:], preparedApplicationWindows: [:],
      explicitlyDestroyedWindowIDs: [], publicCGWindows: { [] }
    )
    #expect(engine.applicationWindowListReadCount == 0)
    #expect(result.applicationWindows[processID] == [created])
    #expect(engine.consumeObservations().createdElements[processID] == [created])
    #expect(windowCandidatesIncludingCreatedElements([created], created: [created, created]) == [created])
  }

  @Test(arguments: 0...3, [false, true])
  func cachelessUnrequestedApplicationDoesNotTriggerAnotherWindowListRead(attempts: Int, fullRefresh: Bool) {
    let platform = NavigationActor.shared.queue.sync {
      NavigationActor.assumeIsolated { MacOSPlatform() }
    }
    let engine = platform.snapshotEngine
    engine.applications = [processID: AXUIElementCreateApplication(-1)]
    engine.applicationIDsByProcess = [processID: "com.example"]
    engine.enhancedUIByProcess = [processID: false]
    engine.windowListReadRetryAttemptsByProcess = [processID: attempts]
    engine.hasCompletedWindowSnapshot = true

    func discover(
      processIDs: Set<pid_t>?, forceReadProcessIDs: Set<pid_t> = [], forceFullRead: Bool = false
    ) -> SnapshotWindowDiscoveryResult {
      engine.discoverSnapshotWindows(
        monitors: [], config: Config(), incrementalProcessIDs: processIDs,
        forceWindowListRefresh: forceFullRead,
        forceWindowListRefreshProcessIDs: forceReadProcessIDs,
        forceApplicationInventoryRefresh: false,
        capturedTopologyRequiresFullSnapshot: false, topologyProcessIDs: [],
        createdElements: [:], preparedWindowAttributes: [:],
        preparedTransientOwnerWindowIDs: [:], preparedApplicationWindows: [:],
        explicitlyDestroyedWindowIDs: [], publicCGWindows: { [] }
      )
    }

    let partialSnapshot = discover(processIDs: [99])

    #expect(engine.applicationWindowListReadCount == 0)
    #expect(partialSnapshot.nextApplications[processID] != nil)
    #expect(engine.windowListReadRetryAttemptsByProcess[processID] == attempts)

    engine.applications = partialSnapshot.nextApplications
    engine.applicationIDsByProcess = partialSnapshot.nextApplicationIDs
    engine.lastApplicationWindowElements = partialSnapshot.applicationWindows
    _ = discover(
      processIDs: fullRefresh ? nil : [processID],
      forceReadProcessIDs: fullRefresh ? [] : [processID], forceFullRead: fullRefresh
    )
    #expect(engine.applicationWindowListReadCount == 1)
    #expect(engine.windowListReadRetryAttemptsByProcess[processID] == min(attempts + 1, 3))
  }

  private let processID: pid_t = 42
  private let frame = Rect(x: 4, y: 34, width: 1_200, height: 800)

  @Test func mouseReleaseRefreshesFramesWithoutADragNotification() {
    let engine = SnapshotEngine(frameCoordinator: AXFrameCoordinator(), userInputTracker: UserInputTracker())
    engine.recordObservation(.mouseRelease, processID: processID)
    let observations = engine.consumeObservations()

    #expect(observations.framePending)
    #expect(observations.frameProcessIDs == [processID])
    #expect(!observations.frameRequiresFullSnapshot)
    #expect(!observations.topologyPending)
  }

  @Test func unknownFocusSourceRequestsFullInventoryUntilConsumed() {
    let engine = SnapshotEngine(frameCoordinator: AXFrameCoordinator(), userInputTracker: UserInputTracker())
    engine.recordObservation(.focus, processID: nil)
    engine.recordObservation(.focus, processID: processID)
    #expect(engine.pendingObservations.topologyRequiresFullSnapshot)
    #expect(engine.consumeObservations().topologyRequiresFullSnapshot)
    #expect(!engine.pendingObservations.topologyRequiresFullSnapshot)
  }

  @Test func emptyApplicationInventoryDrainsPendingFullRefreshChunks() {
    let engine = SnapshotEngine(frameCoordinator: AXFrameCoordinator(), userInputTracker: UserInputTracker())
    let application = AXUIElementCreateApplication(processID)
    engine.applications = [processID: application]
    engine.chunkedFullRefreshRemainingProcessIDs = [processID]

    engine.applications = [processID: application]
    #expect(engine.chunkedFullRefreshRemainingProcessIDs == [processID])

    engine.applications = [:]
    #expect(engine.chunkedFullRefreshRemainingProcessIDs == nil)
    #expect(engine.chunkedFullRefreshRemainingProcessIDs?.isEmpty != false)

    engine.applications = [processID: application]
    #expect(engine.chunkedFullRefreshRemainingProcessIDs == nil)
  }

  @Test func deferredUnmatchedWindowsExhaustRetriesAcrossFullSnapshotChunks() {
    let engine = SnapshotEngine(frameCoordinator: AXFrameCoordinator(), userInputTracker: UserInputTracker())
    let first = AXUIElementCreateApplication(41)
    let deferred = AXUIElementCreateApplication(42)
    engine.unmatchedWindowElementsByProcess = [41: [first], 42: [deferred]]
    engine.unmatchedWindowRetryAttemptsByProcess = [41: 0, 42: 0]
    for attempt in 1...3 {
      engine.consumeUnmatchedWindowRetries(processIDs: [41])
      #expect(engine.unmatchedWindowElementsByProcess[42]?.count == 1)
      #expect(engine.unmatchedWindowRetryAttemptsByProcess[42] == attempt - 1)
      cacheWindowElementForShortRetry(
        first, processID: 41, elementsByProcess: &engine.unmatchedWindowElementsByProcess,
        attemptsByProcess: &engine.unmatchedWindowRetryAttemptsByProcess
      )
      engine.consumeUnmatchedWindowRetries(processIDs: [42])
      cacheWindowElementForShortRetry(
        deferred, processID: 42, elementsByProcess: &engine.unmatchedWindowElementsByProcess,
        attemptsByProcess: &engine.unmatchedWindowRetryAttemptsByProcess
      )
      #expect(engine.unmatchedWindowRetryAttemptsByProcess[42] == attempt)
    }
    #expect(!unmatchedWindowRetryIsPending(attempts: engine.unmatchedWindowRetryAttemptsByProcess[42] ?? 0))
  }

  @Test func snapshotPreparationDoesNotVisitDeferredApplications() {
    let engine = SnapshotEngine(frameCoordinator: AXFrameCoordinator(), userInputTracker: UserInputTracker())
    // No host is attached: visiting a deferred application's observer would fail.
    let element = AXUIElementCreateApplication(processID)
    engine.applications = [processID: element]
    engine.elements = [WindowID(rawValue: 1): element]
    engine.processIDs = [WindowID(rawValue: 1): processID]
    let prepared = engine.prepareWindowAttributes(processIDs: [])
    #expect(prepared.attributes.isEmpty)
    #expect(prepared.owners.isEmpty)
    #expect(prepared.applications.isEmpty)
  }

  @Test func borderInventoryRejectsEventsDuringCaptureAndExpiredSnapshots() {
    let engine = SnapshotEngine(frameCoordinator: AXFrameCoordinator(), userInputTracker: UserInputTracker())
    let inventory = CGWindowInventory(records: [], generation: 0, capturedAt: 10)
    engine.publishCGWindowInventory(inventory)
    #expect(engine.borderStackingInventory(now: 10.01) != nil)
    #expect(engine.borderStackingInventory(now: 10.1) == nil)
    #expect(engine.borderStackingInventory(now: 9) == nil)
    engine.recordObservation(.focus, processID: processID)
    // Even a result published after an intervening event must remain invalid.
    engine.publishCGWindowInventory(inventory)
    #expect(engine.borderStackingInventory(now: 10.01) == nil)
  }

  @Test func borderInventoryPreservesVisibleOrderAndRequiresMatchingTarget() {
    let target = WindowID(rawValue: 3)
    let inventory = [
      CGWindowRecord(id: 1, processID: 7, layer: 0, title: "", frame: frame),
      CGWindowRecord(id: 2, processID: 7, layer: 0, title: "", frame: frame, isOnscreen: false),
      CGWindowRecord(id: 3, processID: processID, layer: 0, title: "", frame: frame),
      CGWindowRecord(id: 4, processID: 7, layer: 0, title: "", frame: frame),
    ]
    let entries = windowBorderStackEntries(
      inventory: inventory, targetWindowID: target, targetProcessID: processID, targetFrame: frame
    )
    #expect(entries?.map(\.windowID.rawValue) == [1, 3])
    for id in [2, 5] {
      #expect(windowBorderStackEntries(
        inventory: inventory, targetWindowID: WindowID(rawValue: UInt64(id)),
        targetProcessID: 7, targetFrame: frame
      ) == nil)
    }
    #expect(windowBorderStackEntries(
      inventory: inventory, targetWindowID: target, targetProcessID: 99, targetFrame: frame
    ) == nil)
    #expect(windowBorderStackEntries(
      inventory: inventory, targetWindowID: target, targetProcessID: processID, targetFrame: nil
    ) == nil)
  }

  @Test func frontmostProcessFallbackRequiresMatchingIdentity() {
    #expect(resolvedFrontmostProcessID(
      appKitProcessID: 42, appKitBundleID: "com.example.one",
      accessibilityProcessID: 99, accessibilityBundleID: "com.example.two"
    ) == 42)
    #expect(resolvedFrontmostProcessID(
      appKitProcessID: -1, appKitBundleID: "com.apple.dt.Devices",
      accessibilityProcessID: 7395, accessibilityBundleID: "com.apple.dt.Devices"
    ) == 7395)
    #expect(resolvedFrontmostProcessID(
      appKitProcessID: -1, appKitBundleID: "com.apple.dt.Devices",
      accessibilityProcessID: 99, accessibilityBundleID: "com.apple.dt.Xcode"
    ) == nil)
    #expect(resolvedFrontmostProcessID(
      appKitProcessID: -1, appKitBundleID: "com.apple.dt.Devices",
      accessibilityProcessID: nil, accessibilityBundleID: nil,
      coreGraphicsProcessID: 7395, coreGraphicsBundleID: "com.apple.dt.Devices"
    ) == 7395)
    #expect(resolvedFrontmostProcessID(
      appKitProcessID: 42, appKitBundleID: "com.example.previous",
      expectedBundleID: "com.apple.dt.Devices",
      accessibilityProcessID: nil, accessibilityBundleID: nil,
      coreGraphicsProcessID: 7395, coreGraphicsBundleID: "com.apple.dt.Devices"
    ) == 7395)
    #expect(resolvedFrontmostProcessID(
      appKitProcessID: nil, appKitBundleID: nil,
      expectedBundleID: "com.apple.dt.Devices",
      accessibilityProcessID: nil, accessibilityBundleID: nil,
      coreGraphicsProcessID: 7395, coreGraphicsBundleID: "com.apple.dt.Devices"
    ) == 7395)
    #expect(resolvedFrontmostProcessID(
      appKitProcessID: -1, appKitBundleID: nil,
      accessibilityProcessID: 7395, accessibilityBundleID: "com.apple.dt.Devices",
      coreGraphicsProcessID: 7395, coreGraphicsBundleID: "com.apple.dt.Devices"
    ) == 7395)
    #expect(resolvedFrontmostProcessID(
      appKitProcessID: -1, appKitBundleID: nil,
      accessibilityProcessID: 7395, accessibilityBundleID: "com.apple.dt.Devices",
      coreGraphicsProcessID: 42, coreGraphicsBundleID: "com.example.previous"
    ) == nil)
  }

  @Test func destroyedWindowsArrivingDuringSnapshotRemainPending() {
    let engine = SnapshotEngine(
      frameCoordinator: AXFrameCoordinator(),
      userInputTracker: UserInputTracker()
    )
    let consumed = WindowID(rawValue: 1)
    let arrivedDuringSnapshot = WindowID(rawValue: 2)

    engine.recordObservation(.windows, processID: 42, windowID: consumed)
    #expect(engine.consumeObservations().destroyedWindowIDs == [consumed])
    engine.recordObservation(.windows, processID: 42, windowID: arrivedDuringSnapshot)

    #expect(engine.pendingObservations.destroyedWindowIDs == [arrivedDuringSnapshot])
  }

  @Test func incompleteWindowReadKeepsMembershipUntilConfirmedDestroy() {
    let engine = SnapshotEngine(
      frameCoordinator: AXFrameCoordinator(),
      userInputTracker: UserInputTracker()
    )
    let window = makeWindow(id: 42)
    let element = AXUIElementCreateApplication(processID)
    engine.elements = [window.id: element]
    engine.processIDs = [window.id: processID]
    engine.applications = [processID: AXUIElementCreateApplication(processID)]
    engine.applicationIDsByProcess = [processID: window.appID]
    engine.enhancedUIByProcess = [processID: false]
    engine.lastSnapshotWindows = [window]
    engine.lastApplicationWindowElements = [processID: [element]]
    engine.hasCompletedWindowSnapshot = true
    engine.retainedWindowDeadlines = [window.id: ProcessInfo.processInfo.systemUptime + 60]

    var preparedFrame: Rect?
    var deliveredDestroyDuringSnapshot = false
    func discover(destroyedWindowIDs: Set<WindowID>) -> SnapshotWindowDiscoveryResult {
      engine.discoverSnapshotWindows(
        monitors: [],
        config: Config(),
        incrementalProcessIDs: [processID],
        forceWindowListRefresh: true,
        forceApplicationInventoryRefresh: false,
        capturedTopologyRequiresFullSnapshot: false,
        topologyProcessIDs: [processID],
        createdElements: [:],
        preparedWindowAttributes: [window.id: AXWindowAttributes(
          minimized: nil,
          frame: preparedFrame,
          title: window.title,
          role: kAXWindowRole,
          subrole: kAXStandardWindowSubrole
        )],
        preparedTransientOwnerWindowIDs: [:],
        preparedApplicationWindows: [processID: PreparedAXApplicationWindows(
          elements: [element],
          durationMS: 0
        )],
        explicitlyDestroyedWindowIDs: destroyedWindowIDs,
        publicCGWindows: {
          if preparedFrame != nil && !deliveredDestroyDuringSnapshot {
            deliveredDestroyDuringSnapshot = true
            engine.recordObservation(.windows, processID: processID, windowID: window.id)
          }
          return []
        }
      )
    }

    let incomplete = discover(destroyedWindowIDs: [])
    #expect(incomplete.windows.map(\.id) == [window.id])
    engine.elements = incomplete.nextElements
    engine.processIDs = incomplete.nextProcessIDs
    engine.lastSnapshotWindows = incomplete.windows
    engine.lastApplicationWindowElements = incomplete.applicationWindows

    preparedFrame = frame
    let unmatched = discover(destroyedWindowIDs: [])
    #expect(unmatched.windows.map(\.id) == [window.id])
    engine.elements = unmatched.nextElements
    engine.processIDs = unmatched.nextProcessIDs
    engine.lastSnapshotWindows = unmatched.windows
    engine.lastApplicationWindowElements = unmatched.applicationWindows

    let confirmedDestroy = engine.consumeObservations()
    #expect(confirmedDestroy.destroyedWindowIDs == [window.id])
    let closed = discover(destroyedWindowIDs: confirmedDestroy.destroyedWindowIDs)
    #expect(closed.windows.isEmpty)
  }

  @Test func snapshotCompletionPreservesNewObservationsAndRetainedFrames() {
    let engine = SnapshotEngine(
      frameCoordinator: AXFrameCoordinator(),
      userInputTracker: UserInputTracker()
    )
    let retained = WindowID(rawValue: 1)
    engine.recordObservation(.frame, processID: 42, windowID: retained)
    let first = engine.consumeObservations()
    #expect(first.frameWindowIDs == [retained])
    #expect(first.frameProcessIDs == [42])
    #expect(engine.pendingObservations == SnapshotObservations())

    let generation = engine.windowSnapshotObservationGeneration
    engine.recordObservation(.frame, processID: 99)
    engine.recordObservation(.frame, processID: nil)
    engine.recordObservation(.windows, processID: 99, inputTimestamp: 20)
    engine.recordObservation(.windows, processID: 42, inputTimestamp: 10)
    engine.recordFrameRefresh(
      windowIDs: first.frameWindowIDs,
      processIDs: first.frameProcessIDs,
      requiresFullSnapshot: false,
      invalidatesPreparedObservations: false
    )

    let next = engine.consumeObservations()
    #expect(next.framePending)
    #expect(next.frameWindowIDs == [retained])
    #expect(next.frameProcessIDs == [42, 99])
    #expect(next.frameRequiresFullSnapshot)
    #expect(next.topologyPending)
    #expect(next.topologyProcessIDs == [42, 99])
    #expect(next.topologyInputTimestamp == 20)
    #expect(engine.windowSnapshotObservationGeneration > generation)
    #expect(engine.consumeObservations() == SnapshotObservations())
  }

  @Test func normalizedWindowObservationsKeepTheirRefreshScope() {
    let engine = SnapshotEngine(
      frameCoordinator: AXFrameCoordinator(),
      userInputTracker: UserInputTracker()
    )
    let windowID = WindowID(rawValue: 1)
    for processID: pid_t? in [42, nil] {
      engine.recordObservation(.frame, processID: processID, windowID: windowID)
      let frame = engine.consumeObservations()
      #expect(frame.frameWindowIDs == [windowID])
      #expect(frame.frameProcessIDs == Set(processID.map { [$0] } ?? []))
      #expect(frame.frameRequiresFullSnapshot == (processID == nil))

      engine.recordObservation(.windows, processID: processID, windowID: windowID)
      let destroyed = engine.consumeObservations()
      #expect(destroyed.destroyedWindowIDs == [windowID])
      #expect(destroyed.topologyPending)
      #expect(destroyed.topologyRequiresFullSnapshot == (processID == nil))
    }
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
      applicationInventoryRefreshIsRequired(
        hasCompletedSnapshot: true,
        topologyRequiresFullSnapshot: false,
        forced: false
      ) == false)
  }

  @Test func visibleWindowProcessMissingFromWorkspaceInventoryIsDiscovered() {
    let windows = [
      CGWindowRecord(id: 1, processID: 42, ownerName: "Device Hub", layer: 0,
        title: "Devices", frame: frame),
      CGWindowRecord(id: 2, processID: 42, layer: 0, title: "", frame: frame),
      CGWindowRecord(id: 3, processID: 43, layer: 0, title: "Known", frame: frame),
      CGWindowRecord(id: 4, processID: 44, layer: 1, title: "Panel", frame: frame),
      CGWindowRecord(id: 5, processID: 45, layer: 0, title: "Hidden", frame: frame,
        isOnscreen: false),
      CGWindowRecord(id: 6, processID: 46, layer: 0, title: "Parked", frame: frame,
        isOnscreen: false),
    ]

    let missingProcessIDs = missingApplicationProcessIDs(
      cgWindows: windows,
      knownProcessIDs: [43],
      previouslyManagedProcessIDs: [46]
    )
    #expect(missingProcessIDs == [42, 46])
    #expect(missingApplicationFallbackIsEligible(
      isTerminated: false, isRegularApplication: nil, hasValidatedBundle: true
    ))
    #expect(!missingApplicationFallbackIsEligible(
      isTerminated: false, isRegularApplication: nil, hasValidatedBundle: false
    ))
    #expect(!missingApplicationFallbackIsEligible(
      isTerminated: false, isRegularApplication: false, hasValidatedBundle: true
    ))
    #expect(fallbackApplicationIdentity(
      bundleIdentifier: "com.apple.dt.Devices",
      ownerName: windows[0].ownerName,
      processID: missingProcessIDs[0]
    ) == "com.apple.dt.Devices")
  }

  @Test func missingAppKitApplicationUsesItsExecutableBundle() throws {
    let appURL = FileManager.default.temporaryDirectory
      .appending(path: "DefiCGFallback-\(UUID().uuidString).app")
    defer { try? FileManager.default.removeItem(at: appURL) }
    let contents = appURL.appending(path: "Contents")
    let executable = contents.appending(path: "MacOS/DeviceHub")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let info: [String: Any] = [
      "CFBundleIdentifier": "com.apple.dt.Devices",
      "CFBundlePackageType": "APPL",
      "CFBundleExecutable": "DeviceHub",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: contents.appending(path: "Info.plist"))
    try Data().write(to: executable)

    #expect(appBundleIdentifier(executablePath: executable.path) == "com.apple.dt.Devices")
    #expect(appBundleIdentifier(executablePath: "/usr/bin/open") == nil)
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
      applicationWindowListRefreshIsRequired(
        hasCachedWindows: true,
        refreshesAllWindowLists: false,
        topologyProcessWasInvalidated: false
      ) == false)
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
      unmatchedWindowCacheRequiresFullRetry(
        eventRequiresFullSnapshot: false,
        forceFullWindowRefresh: false,
        forceWindowListRefresh: false
      ) == false)
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

  @Test func unresolvedCGWindowRetriesRecoverExhaustAndFollowIdentity() {
    let original = CGWindowDiscoveryIdentity(
      windowID: WindowID(rawValue: 90), processID: 42,
      ownerName: "Device Hub", title: "Devices"
    )
    var tracker = CGWindowDiscoveryRetryTracker()
    tracker.observe(
      observed: [original], unresolved: [original: "AX-candidate-unmatched"], now: 10
    )
    #expect(tracker.dueProcessIDs(now: 10.099).isEmpty)
    #expect(tracker.dueProcessIDs(now: 10.1) == [42])

    tracker.completeRetries(
      processIDs: [42], now: 10.1,
      unresolved: [original: "AX-window-list-empty"]
    )
    #expect(tracker.entries[original]?.attempts == 1)
    #expect(tracker.dueProcessIDs(now: 10.299).isEmpty)
    #expect(tracker.dueProcessIDs(now: 10.3) == [42])

    tracker.completeRetries(
      processIDs: [42], now: 10.3,
      unresolved: [original: "AX-window-list-empty"]
    )
    tracker.completeRetries(
      processIDs: [42], now: 10.71,
      unresolved: [original: "AX-window-list-empty"]
    )
    #expect(tracker.entries[original]?.attempts == 3)
    #expect(tracker.entries[original]?.nextRetryAt == nil)
    #expect(tracker.dueProcessIDs(now: 100).isEmpty)
    let retitled = CGWindowDiscoveryIdentity(
      windowID: original.windowID, processID: original.processID,
      ownerName: original.ownerName, title: "Devices — refreshed"
    )
    tracker.observe(
      observed: [retitled], unresolved: [retitled: "AX-window-list-empty"], now: 50
    )
    #expect(tracker.entries[retitled]?.attempts == 3)

    tracker.observe(observed: [], unresolved: [:], now: 100)
    #expect(tracker.entries.isEmpty)

    tracker.observe(
      observed: [original], unresolved: [original: "AX-candidate-unmatched"], now: 100
    )
    #expect(tracker.entries[original]?.attempts == 0)
    #expect(tracker.entries[original]?.firstObservedAt == 100)

    let reused = CGWindowDiscoveryIdentity(
      windowID: original.windowID, processID: 43,
      ownerName: "Device Hub", title: "Devices"
    )
    tracker.observe(observed: [reused], unresolved: [reused: "AX-window-list-empty"], now: 101)
    #expect(tracker.entries[original] == nil)
    #expect(tracker.entries[reused]?.attempts == 0)

    tracker.observe(observed: [reused], unresolved: [:], now: 102)
    #expect(tracker.entries.isEmpty)

    tracker.observe(observed: [reused], unresolved: [reused: "AX-no-window-match"], now: 110)
    for now in [110.1, 110.3, 110.71] {
      tracker.completeRetries(processIDs: [43], now: now, unresolved: nil)
    }
    #expect(tracker.entries[reused]?.attempts == 3, "An unavailable CG inventory still spends due retries")
    #expect(tracker.entries[reused]?.lastOutcome == "CG-inventory-unavailable")
    #expect(tracker.refreshInterval(now: 111) == nil)
  }

  @Test func cgWindowDiscoveryScopeAndIdentityFallbackStayConservative() {
    let records = [
      CGWindowRecord(id: 1, processID: 42, ownerName: "Device Hub", layer: 0,
        title: "Devices", frame: frame),
      CGWindowRecord(id: 2, processID: 43, layer: 0, title: "Hidden", frame: frame,
        isOnscreen: false),
      CGWindowRecord(id: 3, processID: 44, layer: 1, title: "Panel", frame: frame),
      CGWindowRecord(id: 4, processID: 45, layer: 0, title: "Defi", frame: frame),
      CGWindowRecord(id: 5, processID: 0, layer: 0, title: "Unknown", frame: frame),
    ]

    #expect(
      relevantCGWindowDiscoveryRecords(
        records, ownProcessID: 45, previouslyManagedProcessIDs: [43]
      ).map(\.id) == [1, 2]
    )
    #expect(fallbackApplicationIdentity(
      bundleIdentifier: "com.apple.dt.Devices", ownerName: "Device Hub", processID: 42
    ) == "com.apple.dt.Devices")
    #expect(fallbackApplicationIdentity(
      bundleIdentifier: nil, ownerName: "Device Hub", processID: 42
    ) == "Device Hub")
    #expect(fallbackApplicationIdentity(
      bundleIdentifier: nil, ownerName: "", processID: 42
    ) == "pid-42")
  }

  @Test func cgWindowDiscoveryExplainsRepresentedAndExcludedSurfaces() {
    let tiledID = WindowID(rawValue: 1)
    let floatingID = WindowID(rawValue: 2)
    let modalID = WindowID(rawValue: 3)
    let ignoredID = WindowID(rawValue: 4)
    let minimizedID = WindowID(rawValue: 5)
    let unresolvedID = WindowID(rawValue: 6)
    func record(_ id: WindowID, frame surfaceFrame: Rect? = nil) -> CGWindowRecord {
      CGWindowRecord(
        id: CGWindowID(id.rawValue), processID: 42, ownerName: "Example",
        layer: 0, title: "Window", frame: surfaceFrame ?? frame
      )
    }
    let windows = [
      Window(id: tiledID, appID: "com.example", title: "Tiled", frame: frame, processID: 42),
      Window(id: floatingID, appID: "com.example", title: "Floating", frame: frame,
        processID: 42, floating: true),
      Window(id: modalID, appID: "com.example", title: "Dialog", frame: frame,
        processID: 42, isModal: true),
    ]
    let processIDs: [WindowID: pid_t] = [
      tiledID: 42, floatingID: 42, modalID: 42,
    ]
    func classification(
      _ windowID: WindowID,
      nativeFullscreen: Set<WindowID> = [],
      nativeFullscreenProcesses: Set<pid_t> = [],
      minimized: Set<WindowID> = [],
      ignoredReasons: [WindowID: String] = [:]
    ) -> (String, String?) {
      cgWindowDiscoveryClassification(
        record: record(windowID), windows: windows,
        processIDsByWindowID: processIDs, appIdentity: "com.example",
        ignoredProcessReason: nil,
        nativeFullscreenWindowIDs: nativeFullscreen,
        nativeFullscreenProcessIDs: nativeFullscreenProcesses,
        monitors: [MonitorSnapshot(id: MonitorID(rawValue: 1), frame: frame)],
        transientWindowIDs: [], minimizedWindowIDs: minimized,
        ignoredReasonsByWindowID: ignoredReasons
      )
    }

    #expect(classification(tiledID).0 == "tiled")
    #expect(classification(floatingID).0 == "floating")
    #expect(classification(modalID).0 == "transient")
    #expect(classification(tiledID, nativeFullscreen: [tiledID]).0 == "native-fullscreen")
    #expect(
      cgWindowDiscoveryClassification(
        record: record(unresolvedID, frame: frame), windows: [],
        processIDsByWindowID: [:], appIdentity: "com.example",
        ignoredProcessReason: nil, nativeFullscreenWindowIDs: [],
        nativeFullscreenProcessIDs: [42],
        monitors: [MonitorSnapshot(id: MonitorID(rawValue: 1), frame: frame)],
        transientWindowIDs: [], minimizedWindowIDs: [], ignoredReasonsByWindowID: [:]
      ).classification == "native-fullscreen"
    )
    #expect(classification(minimizedID, minimized: [minimizedID]).0 == "minimized")
    #expect(classification(ignoredID, ignoredReasons: [ignoredID: "unsupported-role:AXMenu"]) ==
      ("ignored", "unsupported-role:AXMenu"))
    #expect(classification(
      ignoredID, ignoredReasons: [ignoredID: "frame-below-80x60"]
    ) == ("transient", "frame-below-80x60"))
    #expect(classification(unresolvedID).0 == "unresolved")
  }

  @Test func partialDiscoveryRetainsUnchangedWindowExclusions() {
    let ignoredIdentity = CGWindowDiscoveryIdentity(
      windowID: WindowID(rawValue: 20), processID: 42,
      ownerName: "Example", title: "Unsupported"
    )
    let minimizedIdentity = CGWindowDiscoveryIdentity(
      windowID: WindowID(rawValue: 21), processID: 42,
      ownerName: "Example", title: "Minimized"
    )
    let refreshedIdentity = CGWindowDiscoveryIdentity(
      windowID: WindowID(rawValue: 22), processID: 43,
      ownerName: "Example", title: "Changed"
    )
    let previous = [
      CGWindowDiscoveryDiagnostic(
        identity: ignoredIdentity, appIdentity: "com.example",
        classification: "ignored", reason: "unsupported-role:AXMenu", retry: nil
      ),
      CGWindowDiscoveryDiagnostic(
        identity: minimizedIdentity, appIdentity: "com.example",
        classification: "minimized", reason: nil, retry: nil
      ),
      CGWindowDiscoveryDiagnostic(
        identity: refreshedIdentity, appIdentity: "com.example",
        classification: "ignored", reason: "application-policy", retry: nil
      ),
    ]

    let exclusions = retainedCGWindowDiscoveryExclusions(
      previous, observed: [ignoredIdentity, minimizedIdentity, refreshedIdentity],
      refreshedProcessIDs: [43]
    )

    #expect(exclusions.reasonsByWindowID[ignoredIdentity.windowID] == "unsupported-role:AXMenu")
    #expect(exclusions.minimizedWindowIDs == [minimizedIdentity.windowID])
    #expect(exclusions.reasonsByWindowID[refreshedIdentity.windowID] == nil)
    let replacement = CGWindowDiscoveryIdentity(
      windowID: ignoredIdentity.windowID, processID: ignoredIdentity.processID,
      ownerName: ignoredIdentity.ownerName, title: "Replacement"
    )
    let invalidated = retainedCGWindowDiscoveryExclusions(
      previous, observed: [replacement, minimizedIdentity], refreshedProcessIDs: [],
      destroyedWindowIDs: [minimizedIdentity.windowID]
    )
    #expect(invalidated.reasonsByWindowID.isEmpty)
    #expect(invalidated.minimizedWindowIDs.isEmpty)
  }

  @Test func cgInventoryIsReusedForCachedOrKnownFrameSnapshotsAndRetriedOnForcedRefresh() {
    #expect(cgWindowInventoryRetryIsRequired(attempts: 0, forceWindowListRefresh: true))
    #expect(!cgWindowInventoryRetryIsRequired(attempts: nil, forceWindowListRefresh: true))
    #expect(!cgWindowInventoryRetryIsRequired(attempts: 3, forceWindowListRefresh: true))
    #expect(!cgWindowInventoryRetryIsRequired(attempts: 0, forceWindowListRefresh: false))
    func reused(cached: Bool, knownFrames: Bool, available: Bool = true) -> Bool {
      cgWindowInventoryCanBeReused(snapshotUsesCachedWindows: cached, snapshotRefreshesOnlyKnownFrames: knownFrames,
        cachedInventoryAvailable: available)
    }
    #expect([reused(cached: true, knownFrames: false), reused(cached: false, knownFrames: true),
      reused(cached: false, knownFrames: false), reused(cached: true, knownFrames: true, available: false)]
      == [true, true, false, false])
  }

  @Test func geometryDiscoveryIgnoresMinimizedAndTinyWindowsAndKeepsFailuresUnavailable() {
    var reads = 0
    #expect(windowGeometryDiscovery(minimized: true) { reads += 1; return frame } == .ignored)
    #expect(reads == 0, "A minimized window does not read its geometry")
    #expect(windowGeometryDiscovery(minimized: false) { Rect(x: 0, y: 0, width: 79, height: 60) } == .ignored)
    #expect(windowGeometryDiscovery(minimized: false) { nil } == .unavailable)
    #expect(windowGeometryDiscovery(minimized: false) { frame } == .usable(frame))
  }

  @Test func fallbackAttributesStopAtMinimizedAndKeepModalState() {
    var reads = 0
    func read<Value>(_ value: Value) -> Value { reads += 1; return value }
    let minimized = fallbackWindowAttributes(minimized: { true }, frame: { read(frame) }, title: { read("Window") },
      role: { read(kAXWindowRole) }, subrole: { read(kAXStandardWindowSubrole) }, modal: { read(true) })
    #expect(minimized.minimized == true)
    #expect(minimized.frame == nil)
    #expect(minimized.title.isEmpty)
    #expect(minimized.role == nil)
    #expect(minimized.subrole == nil)
    #expect(reads == 0)
    let sheet = fallbackWindowAttributes(minimized: { false }, frame: { frame }, title: { "Sheet" },
      role: { kAXWindowRole }, subrole: { kAXStandardWindowSubrole }, modal: { true })
    #expect(sheet.modal == true)
    #expect(sheet.title == "Sheet")
  }

  @Test(arguments: [true, false], ["", "Duplicate"])
  func ignoredKnownWindowDoesNotRequireUniqueTitle(minimized: Bool, title: String) {
    let engine = SnapshotEngine(frameCoordinator: AXFrameCoordinator(), userInputTracker: UserInputTracker())
    let window = makeWindow(id: 42)
    let element = AXUIElementCreateApplication(-1)
    engine.elements = [window.id: element]
    engine.processIDs = [window.id: processID]
    engine.applications = [processID: element]
    engine.applicationIDsByProcess = [processID: window.appID]
    engine.enhancedUIByProcess = [processID: false]
    engine.hasCompletedWindowSnapshot = true
    engine.lastSnapshotWindows = [window]
    engine.lastApplicationWindowElements = [processID: [element]]
    let result = engine.discoverSnapshotWindows(
      monitors: [], config: Config(), incrementalProcessIDs: [processID],
      forceWindowListRefresh: false, forceApplicationInventoryRefresh: false,
      capturedTopologyRequiresFullSnapshot: false, topologyProcessIDs: [], createdElements: [:],
      preparedWindowAttributes: [window.id: AXWindowAttributes(
        minimized: minimized, frame: Rect(x: 0, y: 0, width: 1, height: 1),
        title: title, role: nil, subrole: nil
      )],
      preparedTransientOwnerWindowIDs: [:], preparedApplicationWindows: [:],
      explicitlyDestroyedWindowIDs: [], publicCGWindows: {
        [42, 43].map { CGWindowRecord(id: $0, processID: processID, layer: 0, title: title, frame: frame) }
      }
    )
    #expect(result.ignoredWindowReasonsByID[window.id] == (minimized ? "AX-minimized" : "frame-below-80x60"))
    #expect(result.minimizedWindowIDs == (minimized ? [window.id] : []))
    #expect(result.unresolvedOutcomesByProcess[processID] == nil)
    #expect(result.unresolvedOutcome(for: processID) == "AX-no-window-match")
  }

  @Test(arguments: [false, true])
  func unresolvedDiagnosticsKeepAllProcessObservations(reverseOrder: Bool) {
    let engine = SnapshotEngine(frameCoordinator: AXFrameCoordinator(), userInputTracker: UserInputTracker())
    let first = makeWindow(id: 42), second = makeWindow(id: 43)
    let unavailable = AXUIElementCreateApplication(-1), unmatched = AXUIElementCreateApplication(-2)
    engine.elements = [first.id: unavailable, second.id: unmatched]
    engine.processIDs = [first.id: processID, second.id: processID]
    engine.applications = [processID: unavailable]
    engine.applicationIDsByProcess = [processID: first.appID]
    engine.enhancedUIByProcess = [processID: false]
    engine.hasCompletedWindowSnapshot = true
    engine.lastSnapshotWindows = [first, second]
    engine.lastApplicationWindowElements = [processID: reverseOrder ? [unmatched, unavailable] : [unavailable, unmatched]]
    let result = engine.discoverSnapshotWindows(
      monitors: [], config: Config(), incrementalProcessIDs: [processID],
      forceWindowListRefresh: false, forceApplicationInventoryRefresh: false,
      capturedTopologyRequiresFullSnapshot: false, topologyProcessIDs: [], createdElements: [:],
      preparedWindowAttributes: [
        first.id: AXWindowAttributes(minimized: nil, frame: nil, title: "", role: nil, subrole: nil),
        second.id: AXWindowAttributes(minimized: false, frame: frame, title: "", role: nil, subrole: nil),
      ],
      preparedTransientOwnerWindowIDs: [:], preparedApplicationWindows: [:],
      explicitlyDestroyedWindowIDs: [], publicCGWindows: { [] }
    )
    #expect(result.unresolvedOutcomesByProcess[processID] == ["AX-window-attributes-unavailable", "AX-candidate-unmatched"])
    #expect(result.unresolvedOutcome(for: processID)
      == "AX-no-window-match;process-observations=AX-candidate-unmatched|AX-window-attributes-unavailable")
  }

  @Test(arguments: [false, true])
  func missingApplicationFallbackRespectsRequestedProcesses(requested: Bool) {
    let engine = SnapshotEngine(frameCoordinator: AXFrameCoordinator(), userInputTracker: UserInputTracker())
    engine.hasCompletedWindowSnapshot = true
    let missingPID = pid_t.max
    let result = engine.discoverSnapshotWindows(
      monitors: [], config: Config(), incrementalProcessIDs: requested ? [missingPID] : [],
      forceWindowListRefresh: false, forceApplicationInventoryRefresh: false,
      capturedTopologyRequiresFullSnapshot: false, topologyProcessIDs: [], createdElements: [:],
      preparedWindowAttributes: [:], preparedTransientOwnerWindowIDs: [:], preparedApplicationWindows: [:],
      explicitlyDestroyedWindowIDs: [], publicCGWindows: {
        [CGWindowRecord(id: 42, processID: missingPID, layer: 0, title: "Window", frame: frame)]
      }
    )
    #expect(result.ignoredProcessReasonsByProcess[missingPID] == (requested ? "application-identity-unverified" : nil))
  }

  @Test(arguments: [true, false])
  func sessionRecoveryRetainsVisibleWindowsButExpiresHiddenOmissions(isOnscreen: Bool) {
    let engine = SnapshotEngine(
      frameCoordinator: AXFrameCoordinator(),
      userInputTracker: UserInputTracker()
    )
    let window = makeWindow(id: 42)
    let stale = AXUIElementCreateApplication(-1)
    engine.elements = [window.id: stale]
    engine.processIDs = [window.id: processID]
    engine.applications = [processID: stale]
    engine.applicationIDsByProcess = [processID: window.appID]
    engine.enhancedUIByProcess = [processID: false]
    engine.hasCompletedWindowSnapshot = true
    engine.lastSnapshotWindows = [window]
    engine.lastApplicationWindowElements = [processID: [stale]]
    engine.retainedWindowIDs = [window.id]
    engine.retainedWindowDeadlines = [window.id: 0]

    // AX still omits the window after wake, but WindowServer confirms it exists.
    let result = engine.discoverSnapshotWindows(
      monitors: [],
      config: Config(),
      incrementalProcessIDs: [processID],
      forceWindowListRefresh: false,
      forceApplicationInventoryRefresh: false,
      capturedTopologyRequiresFullSnapshot: false,
      topologyProcessIDs: [],
      createdElements: [:],
      preparedWindowAttributes: [window.id: AXWindowAttributes(
        minimized: nil, frame: nil, title: "", role: nil, subrole: nil
      )],
      preparedTransientOwnerWindowIDs: [:],
      preparedApplicationWindows: [processID: PreparedAXApplicationWindows(
        elements: [], durationMS: 0
      )],
      explicitlyDestroyedWindowIDs: [],
      publicCGWindows: { [CGWindowRecord(
        id: 42, processID: processID, layer: 0, title: "Window",
        frame: frame, isOnscreen: isOnscreen
      )] }
    )

    #expect(engine.applicationWindowListReadCount == 1)
    #expect(result.windows.map(\.id) == (isOnscreen ? [window.id] : []))
    #expect(result.nextRetainedWindowIDs == (isOnscreen ? [window.id] : []))
  }

  @Test func reusedAccessibilityElementCannotRetainTwoWindowIdentities() {
    let old = makeWindow(id: 42), replacement = makeWindow(id: 43)
    let staleElement = AXUIElementCreateApplication(processID)
    let refreshedElement = AXUIElementCreateApplication(processID)
    #expect(CFEqual(staleElement, refreshedElement))
    let retained = cachedWindowIDsToRetain(
      processID: processID,
      previousWindows: [old, replacement],
      discoveredWindowIDs: [replacement.id],
      ignoredWindowIDs: [],
      cgWindows: [makeCGWindow(id: 42), makeCGWindow(id: 43)],
      previousElements: [old.id: staleElement, replacement.id: refreshedElement],
      discoveredElements: [replacement.id: refreshedElement],
      cachedWindowState: { _ in (.success, false) }
    )
    #expect(retained.isEmpty)
  }

  @Test func cachedWindowsSurviveOnlyUnconfirmedAccessibilityOmissions() {
    let window = makeWindow(id: 42)
    func retained(discovered: Set<WindowID> = [], ignored: Set<WindowID> = [], cg: [CGWindowRecord]? = nil,
      state: ((WindowID) -> (error: AXError, minimized: Bool?))?) -> Set<WindowID> {
      cachedWindowIDsToRetain(processID: processID, previousWindows: [window], discoveredWindowIDs: discovered,
        ignoredWindowIDs: ignored, cgWindows: cg, cachedWindowState: state)
    }
    let listed = [makeCGWindow(id: 42)]
    #expect(retained(state: { _ in (.cannotComplete, nil) }) == [window.id], "no CG inventory")
    #expect(retained(cg: listed, state: nil) == [window.id], "the application's AX connection failed")
    #expect(retained(cg: listed, state: { _ in (.success, true) }).isEmpty, "minimized")
    #expect(retained(discovered: [window.id], cg: listed, state: { _ in (.cannotComplete, nil) }).isEmpty)
    #expect(retained(ignored: [window.id], cg: listed, state: { _ in (.cannotComplete, nil) }).isEmpty)
    #expect(retained(cg: [], state: { _ in (.cannotComplete, nil) }).isEmpty, "closed")
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

  @Test(arguments: [AXError.invalidUIElement, .cannotComplete, .success], [true, false])
  func invalidHiddenCachedWindowIsRemovedWithoutGrace(error: AXError, isOnscreen: Bool) {
    let window = makeWindow(id: 42)
    let retained = cachedWindowIDsToRetain(
      processID: processID, previousWindows: [window], discoveredWindowIDs: [],
      ignoredWindowIDs: [], cgWindows: [CGWindowRecord(
        id: 42, processID: processID, layer: 0, title: "Window",
        frame: frame, isOnscreen: isOnscreen
      )],
      cachedWindowState: { _ in (error, nil) }
    )
    #expect(retained.isEmpty == (error == .invalidUIElement && !isOnscreen))
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
