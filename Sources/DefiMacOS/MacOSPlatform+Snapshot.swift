import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

private let frameCommitLogger = Logger(
  subsystem: "com.quentin.defi",
  category: "FrameCommit"
)

@MainActor
extension MacOSPlatform {

  public func accessibilityTrusted(prompt: Bool) -> Bool {
    let options =
      [
        "AXTrustedCheckOptionPrompt": prompt
      ] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  public func snapshot(config: Config) -> DesktopSnapshot {
    snapshot(
      config: config,
      forceFullWindowRefresh: true,
      forceWindowListRefresh: true,
      forceApplicationInventoryRefresh: true
    )
  }

  public func snapshot(
    config: Config,
    forceFullWindowRefresh: Bool,
    forceWindowListRefresh: Bool = false,
    forceApplicationInventoryRefresh: Bool = false
  ) -> DesktopSnapshot {
    let snapshotStartedAt = ProcessInfo.processInfo.systemUptime
    let tracesWindowTopology = windowTopologyEventPending
    let topologyRequiresFullSnapshot = windowTopologyRequiresFullSnapshot
    let topologyProcessIDs = pendingWindowTopologyProcessIDs
    let frameRequiresFullSnapshot = pendingFrameRequiresFullSnapshot
    let frameProcessIDs = pendingFrameProcessIDs
    let topologyInputTimestamp = pendingWindowTopologyInputTimestamp
    let eventRequiresFullSnapshot =
      topologyRequiresFullSnapshot || frameRequiresFullSnapshot
    let retriesAllUnmatchedWindows = unmatchedWindowCacheRequiresFullRetry(
      eventRequiresFullSnapshot:
        eventRequiresFullSnapshot,
      forceFullWindowRefresh: forceFullWindowRefresh,
      forceWindowListRefresh: forceWindowListRefresh
    )
    if eventRequiresFullSnapshot {
      unmatchedWindowElementsByProcess.removeAll(keepingCapacity: true)
      unmatchedWindowRetryAttemptsByProcess.removeAll(keepingCapacity: true)
    } else {
      for processID in topologyProcessIDs.union(frameProcessIDs) {
        unmatchedWindowElementsByProcess[processID] = nil
        unmatchedWindowRetryAttemptsByProcess[processID] = nil
      }
      if retriesAllUnmatchedWindows {
        for processID in unmatchedWindowElementsByProcess.keys {
          unmatchedWindowRetryAttemptsByProcess[processID, default: 0] += 1
        }
        unmatchedWindowElementsByProcess.removeAll(keepingCapacity: true)
      }
    }
    let incrementalProcessIDs = forceFullWindowRefresh
      ? nil
      : incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: hasCompletedWindowSnapshot,
        eventPending: tracesWindowTopology,
        requiresFullSnapshot: topologyRequiresFullSnapshot,
        processIDs: pendingWindowTopologyProcessIDs,
        coalescedProcessIDs: frameProcessIDs,
        coalescedEventRequiresFullSnapshot: frameRequiresFullSnapshot,
        allowsCoalescedProcessRefresh:
          frameEventPending || mouseResizeGesturePending,
        allowsCachedRefresh: true
      )
    let snapshotMode: String
    if incrementalProcessIDs == nil {
      snapshotMode = "full"
      fullWindowSnapshotCount += 1
    } else if incrementalProcessIDs?.isEmpty == true {
      snapshotMode = "cached"
      cachedWindowSnapshotCount += 1
    } else {
      snapshotMode = "incremental"
      incrementalWindowSnapshotCount += 1
    }
    windowTopologyEventPending = false
    pendingWindowTopologyProcessIDs.removeAll(keepingCapacity: true)
    windowTopologyRequiresFullSnapshot = false
    pendingWindowTopologyInputTimestamp = nil
    pendingFrameProcessIDs.removeAll(keepingCapacity: true)
    pendingFrameRequiresFullSnapshot = false
    let monitors = discoverMonitors()
    lastMonitorFrames = monitors.map(\.frame)
    var cachedCGWindows: [CGWindowRecord]?
    func publicCGWindows() -> [CGWindowRecord] {
      if let cachedCGWindows { return cachedCGWindows }
      let copyStartedAt = ProcessInfo.processInfo.systemUptime
      let copied = copyCGWindows()
      let copyDurationMS =
        (ProcessInfo.processInfo.systemUptime - copyStartedAt) * 1_000
      snapshotCGWindowCopyCount += 1
      lastSnapshotCGWindowCopyDurationMS = copyDurationMS
      maximumSnapshotCGWindowCopyDurationMS = max(
        maximumSnapshotCGWindowCopyDurationMS,
        copyDurationMS
      )
      cachedCGWindows = copied
      return copied
    }
    let previousElements = elements
    let previousProcessIDs = processIDs
    let previousApplications = applications
    let previousApplicationIDs = applicationIDsByProcess
    var previouslyManagedApplicationWindows: [pid_t: [AXUIElement]] = [:]
    for (windowID, element) in previousElements {
      if let processID = previousProcessIDs[windowID] {
        previouslyManagedApplicationWindows[processID, default: []].append(element)
      }
    }
    let previousWindowsByProcess = Dictionary(
      grouping: lastSnapshotWindows,
      by: \.processID
    )
    var nextElements: [WindowID: AXUIElement] = [:]
    var nextProcessIDs: [WindowID: pid_t] = [:]
    var nextApplications: [pid_t: AXUIElement] = [:]
    var nextApplicationIDs: [pid_t: String] = [:]
    var applicationWindows: [pid_t: [AXUIElement]] = [:]
    var windows: [Window] = []
    var nextRetainedWindowIDs = Set<WindowID>()
    var cachedSnapshotWindowIDs = Set<WindowID>()

    var processIDsToRefresh = incrementalProcessIDs
    if var requestedProcessIDs = processIDsToRefresh {
      for (processID, cachedApplication) in previousApplications {
        guard !requestedProcessIDs.contains(processID) else {
          continue
        }
        let cachedWindows = previousWindowsByProcess[processID] ?? []
        let cachedElements = cachedWindows.compactMap { window in
          previousElements[window.id].map { (window.id, $0) }
        }
        guard let cachedApplicationWindows =
            lastApplicationWindowElements[processID],
          cachedElements.count == cachedWindows.count
        else {
          requestedProcessIDs.insert(processID)
          continue
        }
        nextApplications[processID] = cachedApplication
        if let appID = previousApplicationIDs[processID] {
          nextApplicationIDs[processID] = appID
        }
        applicationWindows[processID] = cachedApplicationWindows
        windows.append(contentsOf: cachedWindows)
        nextRetainedWindowIDs.formUnion(
          retainedWindowIDsForCachedWindows(
            cachedWindows,
            previousRetainedWindowIDs: retainedWindowIDs
          )
        )
        cachedSnapshotWindowIDs.formUnion(cachedWindows.lazy.map(\.id))
        for (windowID, element) in cachedElements {
          nextElements[windowID] = element
          nextProcessIDs[windowID] = processID
        }
      }
      processIDsToRefresh = requestedProcessIDs
    }

    let refreshesApplicationInventory = applicationInventoryRefreshIsRequired(
      hasCompletedSnapshot: hasCompletedWindowSnapshot,
      topologyRequiresFullSnapshot: topologyRequiresFullSnapshot,
      forced: forceApplicationInventoryRefresh
    )
    let runningApplications: [(processID: pid_t, application: NSRunningApplication?)]
    if refreshesApplicationInventory {
      applicationInventorySnapshotCount += 1
      let inventoryStartedAt = ProcessInfo.processInfo.systemUptime
      runningApplications = NSWorkspace.shared.runningApplications.map {
        ($0.processIdentifier, $0)
      }
      recordDurationSample(
        (ProcessInfo.processInfo.systemUptime - inventoryStartedAt) * 1_000,
        in: &applicationInventoryDurationSamplesMS
      )
    } else if let processIDsToRefresh {
      runningApplications = processIDsToRefresh.sorted().map {
        ($0, previousApplications[$0] == nil
          ? NSRunningApplication(processIdentifier: $0)
          : nil)
      }
    } else {
      runningApplications = previousApplications.keys.sorted().map { ($0, nil) }
    }
    let ownProcessID = ProcessInfo.processInfo.processIdentifier
    for runningApplication in runningApplications {
      let processID = runningApplication.processID
      guard processID != ownProcessID else { continue }
      let appID: String
      if let application = runningApplication.application {
        guard !application.isTerminated,
          application.activationPolicy == .regular
        else {
          continue
        }
        appID =
          application.bundleIdentifier
          ?? application.localizedName
          ?? "pid-\(processID)"
      } else if let cachedAppID = previousApplicationIDs[processID] {
        appID = cachedAppID
      } else {
        continue
      }
      let appElement = previousApplications[processID]
        ?? AXUIElementCreateApplication(processID)
      nextApplications[processID] = appElement
      nextApplicationIDs[processID] = appID
      if enhancedUIByProcess[processID] == nil {
        enhancedUIByProcess[processID] =
          value(
            appElement,
            attribute: "AXEnhancedUserInterface",
            as: Bool.self
          ) ?? false
      }
      let cachedApplicationWindows = lastApplicationWindowElements[processID]
      let refreshesWindowList = applicationWindowListRefreshIsRequired(
        hasCachedWindows: cachedApplicationWindows != nil,
        refreshesAllWindowLists:
          refreshesApplicationInventory
          || topologyRequiresFullSnapshot
          || forceWindowListRefresh,
        topologyProcessWasInvalidated: topologyProcessIDs.contains(processID)
      )
      let appWindows: [AXUIElement]?
      if refreshesWindowList {
        applicationWindowListReadCount += 1
        let windowListStartedAt = ProcessInfo.processInfo.systemUptime
        let copiedWindows = copyElements(
          appElement,
          attribute: kAXWindowsAttribute
        )
        recordDurationSample(
          (ProcessInfo.processInfo.systemUptime - windowListStartedAt) * 1_000,
          in: &applicationWindowListDurationSamplesMS
        )
        appWindows = copiedWindows ?? cachedApplicationWindows
      } else {
        appWindows = cachedApplicationWindows
      }
      if let appWindows {
        applicationWindows[processID] = appWindows
      }
      var usedCGWindowIDs = Set<CGWindowID>()
      var ignoredPreviousWindowIDs = Set<WindowID>()

      for element in appWindows ?? [] {
        let previousWindowID = previousElements.first { windowID, previousElement in
          previousProcessIDs[windowID] == processID
            && CFEqual(previousElement, element)
        }?.key
        if previousWindowID == nil,
          unmatchedWindowElementsByProcess[processID]?.contains(where: {
            CFEqual($0, element)
          }) == true
        {
          continue
        }
        let discovery = makeWindow(
          element: element,
          processID: processID,
          appID: appID,
          config: config,
          publicCGWindows: publicCGWindows,
          monitors: monitors,
          preferredWindowID: previousWindowID,
          excluding: usedCGWindowIDs
        )
        let candidate: Window
        let cgWindowID: CGWindowID
        let decision: RuleDecision
        switch discovery {
        case .unavailable:
          continue
        case .ignored:
          if let previousWindowID {
            ignoredPreviousWindowIDs.insert(previousWindowID)
          }
          continue
        case .unmatched:
          if let previousWindowID {
            ignoredPreviousWindowIDs.insert(previousWindowID)
          } else {
            if unmatchedWindowElementsByProcess[processID]?.contains(where: {
              CFEqual($0, element)
            }) != true {
              unmatchedWindowElementsByProcess[processID, default: []]
                .append(element)
            }
            if unmatchedWindowRetryAttemptsByProcess[processID] == nil {
              unmatchedWindowRetryAttemptsByProcess[processID] = 0
            }
          }
          continue
        case .discovered(let discovered, let discoveredCGWindowID, let ruleDecision):
          candidate = discovered
          cgWindowID = discoveredCGWindowID
          decision = ruleDecision
        }
        let previousDisposition = previousWindowID.map {
          floatingWindowIDs.contains($0) ? WindowDisposition.floating : .tiled
        }
        let disposition = windowDisposition(
          candidate,
          element: element,
          configuredFloating: decision.floating,
          forceTiling: decision.forceTiling,
          previousDisposition: previousDisposition,
          reuseCachedCapabilities: !refreshesWindowList
        )
        guard disposition != .ignored else {
          if let previousWindowID {
            ignoredPreviousWindowIDs.insert(previousWindowID)
          }
          continue
        }
        guard usedCGWindowIDs.insert(cgWindowID).inserted else {
          continue
        }
        var tracked = candidate
        tracked.floating = disposition == .floating
        tracked.floatingOrigin = floatingOrigin(
          for: disposition,
          configuredFloating: decision.floating
        )
        windows.append(tracked)
        nextElements[tracked.id] = element
        nextProcessIDs[tracked.id] = processID
      }

      let previousWindows = previousWindowsByProcess[processID] ?? []
      let discoveredWindowIDs = Set(nextElements.keys)
      let needsCachedWindowValidation = previousWindows.contains {
        !discoveredWindowIDs.contains($0.id)
          && !ignoredPreviousWindowIDs.contains($0.id)
      }
      let cachedMinimizedState: ((WindowID) -> Bool?)?
      if appWindows == nil {
        cachedMinimizedState = nil
      } else {
        cachedMinimizedState = { windowID in
          guard let element = previousElements[windowID] else { return nil }
          return self.value(element, attribute: kAXMinimizedAttribute, as: Bool.self)
        }
      }
      let processRetainedWindowIDs = cachedWindowIDsToRetain(
        processID: processID,
        previousWindows: previousWindows,
        discoveredWindowIDs: discoveredWindowIDs,
        ignoredWindowIDs: ignoredPreviousWindowIDs,
        cgWindows: needsCachedWindowValidation ? publicCGWindows() : [],
        cachedMinimizedState: cachedMinimizedState
      )
      nextRetainedWindowIDs.formUnion(processRetainedWindowIDs)
      if !processRetainedWindowIDs.isEmpty {
        let retainedIDs = processRetainedWindowIDs.sorted {
          $0.rawValue < $1.rawValue
        }.map { String($0.rawValue) }.joined(separator: ",")
        frameCoordinator.recordTrace(
          "window-cache-retained pid=\(processID) windows=[\(retainedIDs)]"
        )
      }
      for previousWindow in previousWindows
      where processRetainedWindowIDs.contains(previousWindow.id) {
        guard let previousElement = previousElements[previousWindow.id] else {
          continue
        }
        windows.append(previousWindow)
        nextElements[previousWindow.id] = previousElement
        nextProcessIDs[previousWindow.id] = processID
        if applicationWindows[processID]?.contains(where: {
          CFEqual($0, previousElement)
        }) != true {
          applicationWindows[processID, default: []].append(previousElement)
        }
      }
    }

    let nextWindowIDs = Set(nextElements.keys)
    let freshObservationIDs = freshWindowObservationIDs(
      windows: windows,
      retainedWindowIDs: nextRetainedWindowIDs,
      cachedWindowIDs: cachedSnapshotWindowIDs
    )
    let removedWindowIDs = Set(previousElements.keys).subtracting(nextWindowIDs)
    newlyDiscoveredWindowIDs =
      hasCompletedWindowSnapshot
      ? nextWindowIDs.subtracting(previousElements.keys)
      : []
    if tracesWindowTopology
      || !newlyDiscoveredWindowIDs.isEmpty
      || !removedWindowIDs.isEmpty
    {
      invalidatePointerHitTestCache()
    }
    if tracesWindowTopology || !newlyDiscoveredWindowIDs.isEmpty {
      let discoveredIDs = newlyDiscoveredWindowIDs.sorted {
        $0.rawValue < $1.rawValue
      }.map { String($0.rawValue) }.joined(separator: ",")
      let elapsedMS =
        (ProcessInfo.processInfo.systemUptime - snapshotStartedAt) * 1_000
      frameCoordinator.recordTrace(
        "window-snapshot mode=\(snapshotMode) ms=\(String(format: "%.2f", elapsedMS)) discovered=\(newlyDiscoveredWindowIDs.count)[\(discoveredIDs)] total=\(windows.count)"
      )
    }
    hasCompletedWindowSnapshot = true
    elements = nextElements
    processIDs = nextProcessIDs
    floatingWindowIDs = Set(windows.lazy.filter(\.floating).map(\.id))
    windowManagementCapabilities = windowManagementCapabilities.filter {
      nextElements[$0.key] != nil
    }
    applications = nextApplications
    applicationIDsByProcess = nextApplicationIDs
    applicationWindowCounts = applicationWindows.mapValues(\.count)
    lastSnapshotWindows = windows
    lastSnapshotWindowIDs = Set(windows.lazy.map(\.id))
    lastSnapshotProcessIDs = Set(windows.lazy.compactMap(\.processID))
    lastApplicationWindowElements = applicationWindows
    retainedWindowIDs = nextRetainedWindowIDs
    enhancedUIByProcess = enhancedUIByProcess.filter { nextApplications[$0.key] != nil }
    multipleAttributeReadsSupportedByProcess =
      multipleAttributeReadsSupportedByProcess.filter {
        nextApplications[$0.key] != nil
      }
    unmatchedWindowElementsByProcess =
      unmatchedWindowElementsByProcess.filter {
        nextApplications[$0.key] != nil
      }
    unmatchedWindowRetryAttemptsByProcess =
      unmatchedWindowRetryAttemptsByProcess.filter {
        nextApplications[$0.key] != nil
          && unmatchedWindowElementsByProcess[$0.key]?.isEmpty == false
      }
    let observedApplicationWindows = Dictionary(
      uniqueKeysWithValues: nextApplications.keys.map {
        ($0, applicationWindows[$0] ?? [])
      }
    )
    var requiredFrameWindows = Dictionary(
      uniqueKeysWithValues: nextApplications.keys.map { ($0, [AXUIElement]()) }
    )
    for (windowID, element) in nextElements {
      if let processID = nextProcessIDs[windowID] {
        requiredFrameWindows[processID, default: []].append(element)
      }
    }
    let topologyWindowsRequiredForObservation = requiredTopologyWindows(
      applicationWindows: observedApplicationWindows,
      managedWindows: requiredFrameWindows,
      previouslyManagedWindows: previouslyManagedApplicationWindows
    )
    eventMonitor?.refresh(
      applications: observedApplicationWindows,
      requiredTopologyWindows: topologyWindowsRequiredForObservation,
      requiredFrameWindows: requiredFrameWindows
    )
    targetFrames = targetFrames.filter { nextElements[$0.key] != nil }
    pendingFrameCorrections = pendingFrameCorrections.filter { nextElements[$0.key] != nil }
    latestObservedFrames = latestObservedFrames.filter {
      freshObservationIDs.contains($0.key)
        || cachedSnapshotWindowIDs.contains($0.key)
    }
    frameCommitExpectations = frameCommitExpectations.filter {
      nextElements[$0.key] != nil
    }
    let now = ProcessInfo.processInfo.systemUptime
    initialFrameSettlementDeadlines = initialFrameSettlementDeadlines.filter {
      nextElements[$0.key] != nil && $0.value > now
    }
    lastHiddenWindowIDs = lastHiddenWindowIDs.filter { nextElements[$0] != nil }
    let leftMouseButtonDown = CGEventSource.buttonState(
      .combinedSessionState,
      button: .left
    )
    let mouseResizeGestureObserved = mouseResizeGesturePending
    let mouseFocusReleaseObserved = mouseFocusReleasePending
    let externalResizeGestureActive =
      leftMouseButtonDown || mouseResizeGestureObserved
    var externallyChangedFrames: [WindowID: Rect] = [:]
    var targetMismatches: [FrameMismatch] = []
    var deferredMismatchCount = 0
    var settledCommitLatenciesMS: [Double] = []
    for window in windows where freshObservationIDs.contains(window.id) {
      latestObservedFrames[window.id] = window.frame
      if var expectation = frameCommitExpectations[window.id],
        let target = targetFrames[window.id]
      {
        if now >= expectation.deadline {
          frameCommitExpectations[window.id] = nil
        } else if approximatelyEqual(window.frame, target) {
          let firstObservation = expectation.observedAt == nil
          if firstObservation {
            expectation.observedAt = now
            frameCommitExpectations[window.id] = expectation
          }
          let latencyMS = max(now - expectation.issuedAt, 0) * 1_000
          if firstObservation {
            settledCommitLatenciesMS.append(latencyMS)
            observedFrameCommitCount += 1
            maximumObservedFrameCommitLatencyMS = max(
              maximumObservedFrameCommitLatencyMS,
              latencyMS
            )
          }
        } else if !frameIsOnExpectedCommitPath(
          actual: window.frame,
          currentTarget: target,
          expectation: expectation,
          now: now,
          leftMouseButtonDown: externalResizeGestureActive
        ) {
          frameCommitExpectations[window.id] = nil
        }
      }
      guard let target = targetFrames[window.id],
        !approximatelyEqual(window.frame, target)
      else {
        continue
      }
      guard targetIntersectsAnyMonitor(target, monitors: monitors) else {
        continue
      }
      if let expectation = frameCommitExpectations[window.id],
        frameIsOnExpectedCommitPath(
          actual: window.frame,
          currentTarget: target,
          expectation: expectation,
          now: now,
          leftMouseButtonDown: externalResizeGestureActive
        )
      {
        deferredMismatchCount += 1
        deferredFrameCommitMismatchCount += 1
        continue
      }
      targetMismatches.append(
        FrameMismatch(windowID: window.id, actual: window.frame, target: target)
      )
      if externalResizeGestureActive && frameEventPending {
        externallyChangedFrames[window.id] = window.frame
      }
    }
    pendingFrameDebtWindowIDs = prunedFrameDebtWindowIDs(
      debtWindowIDs: pendingFrameDebtWindowIDs,
      liveWindowIDs: Set(nextElements.keys),
      targetFrames: targetFrames,
      observedFrames: latestObservedFrames
    )
    frameEventPending = false
    mouseResizeGesturePending = false
    mouseFocusReleasePending = false
    pendingFrameCorrections = Dictionary(
      uniqueKeysWithValues: targetMismatches.map { ($0.windowID, $0.actual) }
    )
    let maximumSettledLatencyMS = settledCommitLatenciesMS.max() ?? 0
    frameCoordinator.recordCommitObservation(
      deferred: deferredMismatchCount,
      settled: settledCommitLatenciesMS.count,
      maximumLatencyMS: maximumSettledLatencyMS
    )
    if deferredMismatchCount > 0 || !settledCommitLatenciesMS.isEmpty {
      frameCommitLogger.debug(
        "frame commit observed settled=\(settledCommitLatenciesMS.count) deferred=\(deferredMismatchCount) max_latency_ms=\(maximumSettledLatencyMS, format: .fixed(precision: 2))"
      )
    }
    let focusedWindowID = focusedWindowID(in: windows)
    lastNativeFocusedWindowID = focusedWindowID
    if let focusedWindowID,
      let processID = nextProcessIDs[focusedWindowID]
    {
      lastFocusedWindowByProcess[processID] = focusedWindowID
    }
    lastFocusedWindowByProcess = lastFocusedWindowByProcess.filter {
      nextProcessIDs[$0.value] == $0.key
    }
    internalFocusSuppressions = internalFocusSuppressions.filter {
      $0.value.deadline >= now
    }
    let focusedProcessID = focusedWindowID.flatMap { nextProcessIDs[$0] }
    let nativeFocusTargetMatched = nativeFocusEventMatchesTarget(
      eventPending: nativeFocusEventPending,
      eventProcessIDs: nativeFocusEventProcessIDs,
      hasUnknownEventProcess: nativeFocusEventHasUnknownProcess,
      focusedProcessID: focusedProcessID
    )
    let userInput = userInputTracker.snapshot
    var nativeFocusChanged = nativeFocusTargetMatched
    if nativeFocusChanged,
      let focusedWindowID,
      let suppression = internalFocusSuppressions[focusedWindowID]
    {
      if internalFocusSuppressionConsumesEvent(
        suppression,
        suppressedWindowID: focusedWindowID,
        latestFocusIntent: userInput.latestFocusIntent
      ) {
        nativeFocusChanged = false
      } else {
        internalFocusSuppressions.removeValue(forKey: focusedWindowID)
      }
    }
    if !nativeFocusEventShouldRemainPending(
      eventPending: nativeFocusEventPending,
      targetMatched: nativeFocusTargetMatched
    ) {
      nativeFocusEventPending = false
      nativeFocusEventProcessIDs.removeAll(keepingCapacity: true)
      nativeFocusEventHasUnknownProcess = false
    }
    if nativeFocusChanged {
      userInputTracker.recordObservedFocus(
        windowID: focusedWindowID,
        processID: focusedProcessID
          ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
      )
    }
    if tracesWindowTopology || !newlyDiscoveredWindowIDs.isEmpty {
      let elapsedMS =
        (ProcessInfo.processInfo.systemUptime - snapshotStartedAt) * 1_000
      frameCoordinator.recordTrace(
        "window-snapshot-complete ms=\(String(format: "%.2f", elapsedMS))"
      )
    }
    let snapshotDurationMS =
      (ProcessInfo.processInfo.systemUptime - snapshotStartedAt) * 1_000
    lastWindowSnapshotDurationMS = snapshotDurationMS
    maximumWindowSnapshotDurationMS = max(
      maximumWindowSnapshotDurationMS,
      snapshotDurationMS
    )
    recordDurationSample(
      snapshotDurationMS,
      in: &windowSnapshotDurationSamplesMS
    )
    let mouseFocusIntentWindowID: WindowID?
    let mouseFocusIntentTimestamp: TimeInterval?
    let keyboardFocusIntentTimestamp: TimeInterval?
    if let focusIntent = userInput.latestFocusIntent,
      case .mouse(let windowID) = focusIntent.source
    {
      mouseFocusIntentWindowID = windowID
      mouseFocusIntentTimestamp = focusIntent.timestamp
      keyboardFocusIntentTimestamp = nil
    } else if let focusIntent = userInput.latestFocusIntent,
      case .keyboard = focusIntent.source
    {
      mouseFocusIntentWindowID = nil
      mouseFocusIntentTimestamp = nil
      keyboardFocusIntentTimestamp = focusIntent.timestamp
    } else {
      mouseFocusIntentWindowID = nil
      mouseFocusIntentTimestamp = nil
      keyboardFocusIntentTimestamp = nil
    }
    return DesktopSnapshot(
      monitors: monitors,
      windows: windows,
      focusedWindowID: focusedWindowID,
      nativeFocusChanged: nativeFocusChanged,
      removedWindowIDs: removedWindowIDs,
      latestUserInputTimestamp: userInput.latestEventTimestamp,
      userInputAfterWindowTopology: userInputOccurredAfterWindowTopology(
        topologyInputTimestamp: topologyInputTimestamp,
        latestInputTimestamp: userInput.latestEventTimestamp,
        latestFocusIntent: userInput.latestFocusIntent,
        latestCloseIntentTimestamp: userInput.latestCloseIntent,
        removedWindowIDs: removedWindowIDs
      ),
      externallyChangedFrames: externallyChangedFrames,
      leftMouseButtonDown: leftMouseButtonDown,
      mouseResizeGestureObserved: mouseResizeGestureObserved,
      mouseFocusReleaseObserved: mouseFocusReleaseObserved,
      mouseFocusIntentWindowID: mouseFocusIntentWindowID,
      mouseFocusIntentTimestamp: mouseFocusIntentTimestamp,
      keyboardFocusIntentTimestamp: keyboardFocusIntentTimestamp,
      targetMismatchCount: targetMismatches.count,
      targetMismatches: targetMismatches
    )
  }

}

func applicationInventoryRefreshIsRequired(
  hasCompletedSnapshot: Bool,
  topologyRequiresFullSnapshot: Bool,
  forced: Bool
) -> Bool {
  !hasCompletedSnapshot || topologyRequiresFullSnapshot || forced
}

func durationPercentile(
  _ percentile: Double,
  samples: [Double]
) -> Double {
  guard !samples.isEmpty else { return 0 }
  let sorted = samples.sorted()
  let boundedPercentile = min(max(percentile, 0), 1)
  let index = Int(
    (Double(sorted.count - 1) * boundedPercentile).rounded(.up)
  )
  return sorted[index]
}

func recordDurationSample(
  _ durationMS: Double,
  in samples: inout [Double],
  limit: Int = 120
) {
  samples.append(durationMS)
  if samples.count > limit {
    samples.removeFirst(samples.count - limit)
  }
}

func applicationWindowListRefreshIsRequired(
  hasCachedWindows: Bool,
  refreshesAllWindowLists: Bool,
  topologyProcessWasInvalidated: Bool
) -> Bool {
  !hasCachedWindows
    || refreshesAllWindowLists
    || topologyProcessWasInvalidated
}

func unmatchedWindowCacheRequiresFullRetry(
  eventRequiresFullSnapshot: Bool,
  forceFullWindowRefresh: Bool,
  forceWindowListRefresh: Bool
) -> Bool {
  eventRequiresFullSnapshot
    || forceFullWindowRefresh
    || forceWindowListRefresh
}

func freshWindowObservationIDs(
  windows: [Window],
  retainedWindowIDs: Set<WindowID>,
  cachedWindowIDs: Set<WindowID> = []
) -> Set<WindowID> {
  Set(windows.lazy.map(\.id))
    .subtracting(retainedWindowIDs)
    .subtracting(cachedWindowIDs)
}

func retainedWindowIDsForCachedWindows(
  _ windows: [Window],
  previousRetainedWindowIDs: Set<WindowID>
) -> Set<WindowID> {
  previousRetainedWindowIDs.intersection(windows.lazy.map(\.id))
}
