import ApplicationServices
import DefiConfig
import DefiModel
import Testing

@testable import DefiMacOS

struct WindowSnapshotStabilityTests {
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

  private let processID: pid_t = 42
  private let frame = Rect(x: 4, y: 34, width: 1_200, height: 800)

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
      engine.retryUnmatchedWindows(processIDs: [41])
      #expect(engine.unmatchedWindowElementsByProcess[42]?.count == 1)
      #expect(engine.unmatchedWindowRetryAttemptsByProcess[42] == attempt - 1)
      cacheWindowElementForShortRetry(
        first, processID: 41, elementsByProcess: &engine.unmatchedWindowElementsByProcess,
        attemptsByProcess: &engine.unmatchedWindowRetryAttemptsByProcess
      )
      engine.retryUnmatchedWindows(processIDs: [42])
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

  @Test func frontmostProcessFallsBackOnlyToMatchingAccessibilityApplication() {
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
      CGWindowRecord(id: 1, processID: 42, layer: 0, title: "Device Hub", frame: frame),
      CGWindowRecord(id: 2, processID: 42, layer: 0, title: "", frame: frame),
      CGWindowRecord(id: 3, processID: 43, layer: 0, title: "Known", frame: frame),
      CGWindowRecord(id: 4, processID: 44, layer: 1, title: "Panel", frame: frame),
    ]

    #expect(
      missingApplicationProcessIDs(
        cgWindows: windows,
        knownProcessIDs: [43]
      ) == [42]
    )
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

  @Test func forcedWindowListRefreshAdvancesPendingCGInventoryRetry() {
    #expect(
      cgWindowInventoryRetryIsRequired(
        attempts: 0,
        forceWindowListRefresh: true
      )
    )
    #expect(
      cgWindowInventoryRetryIsRequired(
        attempts: nil,
        forceWindowListRefresh: true
      ) == false)
    #expect(
      cgWindowInventoryRetryIsRequired(
        attempts: 3,
        forceWindowListRefresh: true
      ) == false)
    #expect(
      cgWindowInventoryRetryIsRequired(
        attempts: 0,
        forceWindowListRefresh: false
      ) == false)
  }

  @Test func cachedAndKnownFrameSnapshotsReuseTheCGWindowInventory() {
    #expect(
      cgWindowInventoryCanBeReused(
        snapshotUsesCachedWindows: true,
        snapshotRefreshesOnlyKnownFrames: false,
        cachedInventoryAvailable: true
      )
    )
    #expect(
      cgWindowInventoryCanBeReused(
        snapshotUsesCachedWindows: false,
        snapshotRefreshesOnlyKnownFrames: true,
        cachedInventoryAvailable: true
      )
    )
    #expect(
      cgWindowInventoryCanBeReused(
        snapshotUsesCachedWindows: false,
        snapshotRefreshesOnlyKnownFrames: false,
        cachedInventoryAvailable: true
      ) == false)
    #expect(
      cgWindowInventoryCanBeReused(
        snapshotUsesCachedWindows: true,
        snapshotRefreshesOnlyKnownFrames: true,
        cachedInventoryAvailable: false
      ) == false)
  }

  @Test func snapshotDurationPercentilesAreBoundedAndDeterministic() {
    let samples = [1.0, 2.0, 3.0, 4.0, 5.0]

    #expect(durationPercentile(0.5, sortedSamples: samples) == 3)
    #expect(durationPercentile(0.95, sortedSamples: samples) == 5)
    #expect(durationPercentile(-1, sortedSamples: samples) == 1)
    #expect(durationPercentile(2, sortedSamples: samples) == 5)
    #expect(durationPercentile(0.5, sortedSamples: []) == 0)
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

  @Test func existingCGWindowSurvivesTransientAccessibilityOmission() {
    let window = makeWindow(id: 42)

    #expect(
      cachedWindowIDsToRetain(
        processID: processID,
        previousWindows: [window],
        discoveredWindowIDs: [],
        ignoredWindowIDs: [],
        cgWindows: [makeCGWindow(id: 42)],
        cachedWindowState: { _ in (.cannotComplete, nil) }
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
        cachedWindowState: { _ in (.cannotComplete, nil) }
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
        cachedWindowState: { _ in (.success, true) }
      ).isEmpty
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

  @Test func applicationAccessibilityFailureDoesNotProbeCachedWindows() {
    let window = makeWindow(id: 42)

    #expect(
      cachedWindowIDsToRetain(
        processID: processID,
        previousWindows: [window],
        discoveredWindowIDs: [],
        ignoredWindowIDs: [],
        cgWindows: [makeCGWindow(id: 42)],
        cachedWindowState: nil
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
        cachedWindowState: { _ in (.cannotComplete, nil) }
      ).isEmpty
    )
    #expect(
      cachedWindowIDsToRetain(
        processID: processID,
        previousWindows: [window],
        discoveredWindowIDs: [],
        ignoredWindowIDs: [window.id],
        cgWindows: cgWindows,
        cachedWindowState: { _ in (.cannotComplete, nil) }
      ).isEmpty
    )
    #expect(
      cachedWindowIDsToRetain(
        processID: processID,
        previousWindows: [window],
        discoveredWindowIDs: [],
        ignoredWindowIDs: [],
        cgWindows: [],
        cachedWindowState: { _ in (.cannotComplete, nil) }
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
