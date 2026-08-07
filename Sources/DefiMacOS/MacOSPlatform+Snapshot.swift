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
    let snapshotStartedAt = ProcessInfo.processInfo.systemUptime
    let tracesWindowTopology = windowTopologyEventPending
    let topologyInputTimestamp = pendingWindowTopologyInputTimestamp
    let incrementalProcessIDs = incrementalWindowRefreshProcessIDs(
      hasCompletedSnapshot: hasCompletedWindowSnapshot,
      eventPending: tracesWindowTopology,
      requiresFullSnapshot: windowTopologyRequiresFullSnapshot,
      processIDs: pendingWindowTopologyProcessIDs,
      coalescedProcessIDs: pendingFrameProcessIDs,
      coalescedEventRequiresFullSnapshot: pendingFrameRequiresFullSnapshot,
      allowsCoalescedProcessRefresh: mouseResizeGesturePending
    )
    windowTopologyEventPending = false
    pendingWindowTopologyProcessIDs.removeAll(keepingCapacity: true)
    windowTopologyRequiresFullSnapshot = false
    pendingWindowTopologyInputTimestamp = nil
    pendingFrameProcessIDs.removeAll(keepingCapacity: true)
    pendingFrameRequiresFullSnapshot = false
    let monitors = discoverMonitors()
    lastMonitorFrames = monitors.map(\.frame)
    let cgWindows = copyCGWindows()
    frontmostNormalWindowID = copyFrontmostNormalWindowID()
    let previousElements = elements
    let previousProcessIDs = processIDs
    let previousWindowsByProcess = Dictionary(
      grouping: lastSnapshotWindows,
      by: \.processID
    )
    var nextElements: [WindowID: AXUIElement] = [:]
    var nextProcessIDs: [WindowID: pid_t] = [:]
    var nextApplications: [pid_t: AXUIElement] = [:]
    var applicationWindows: [pid_t: [AXUIElement]] = [:]
    var windows: [Window] = []
    var retainedWindowIDs = Set<WindowID>()

    for application in NSWorkspace.shared.runningApplications
    where application.processIdentifier != ProcessInfo.processInfo.processIdentifier
      && !application.isTerminated
      && application.activationPolicy == .regular
    {
      let appID =
        application.bundleIdentifier
        ?? application.localizedName
        ?? "pid-\(application.processIdentifier)"
      let appElement = AXUIElementCreateApplication(application.processIdentifier)
      nextApplications[application.processIdentifier] = appElement
      if enhancedUIByProcess[application.processIdentifier] == nil {
        enhancedUIByProcess[application.processIdentifier] =
          value(
            appElement,
            attribute: "AXEnhancedUserInterface",
            as: Bool.self
          ) ?? false
      }
      if let incrementalProcessIDs,
        !incrementalProcessIDs.contains(application.processIdentifier),
        let cachedApplicationWindows =
          lastApplicationWindowElements[application.processIdentifier]
      {
        let cachedWindows =
          previousWindowsByProcess[application.processIdentifier] ?? []
        let cachedElements = cachedWindows.compactMap { window in
          previousElements[window.id].map { (window.id, $0) }
        }
        if cachedElements.count == cachedWindows.count {
          applicationWindows[application.processIdentifier] =
            cachedApplicationWindows
          windows.append(contentsOf: cachedWindows)
          for (windowID, element) in cachedElements {
            nextElements[windowID] = element
            nextProcessIDs[windowID] = application.processIdentifier
          }
          continue
        }
      }
      let appWindows = copyElements(appElement, attribute: kAXWindowsAttribute)
      if let appWindows {
        applicationWindows[application.processIdentifier] = appWindows
      } else if let cachedApplicationWindows =
        lastApplicationWindowElements[application.processIdentifier]
      {
        applicationWindows[application.processIdentifier] = cachedApplicationWindows
      }
      var usedCGWindowIDs = Set<CGWindowID>()
      var ignoredPreviousWindowIDs = Set<WindowID>()

      for element in appWindows ?? [] {
        let previousWindowID = previousElements.first { windowID, previousElement in
          previousProcessIDs[windowID] == application.processIdentifier
            && CFEqual(previousElement, element)
        }?.key
        let discovery = makeWindow(
          element: element,
          processID: application.processIdentifier,
          appID: appID,
          config: config,
          cgWindows: cgWindows,
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
          previousDisposition: previousDisposition
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
        nextProcessIDs[tracked.id] = application.processIdentifier
      }

      let previousWindows = previousWindowsByProcess[application.processIdentifier] ?? []
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
        processID: application.processIdentifier,
        previousWindows: previousWindows,
        discoveredWindowIDs: Set(nextElements.keys),
        ignoredWindowIDs: ignoredPreviousWindowIDs,
        cgWindows: cgWindows,
        cachedMinimizedState: cachedMinimizedState
      )
      retainedWindowIDs.formUnion(processRetainedWindowIDs)
      if !processRetainedWindowIDs.isEmpty {
        let retainedIDs = processRetainedWindowIDs.sorted {
          $0.rawValue < $1.rawValue
        }.map { String($0.rawValue) }.joined(separator: ",")
        frameCoordinator.recordTrace(
          "window-cache-retained pid=\(application.processIdentifier) windows=[\(retainedIDs)]"
        )
      }
      for previousWindow in previousWindows
      where processRetainedWindowIDs.contains(previousWindow.id) {
        guard let previousElement = previousElements[previousWindow.id] else {
          continue
        }
        windows.append(previousWindow)
        nextElements[previousWindow.id] = previousElement
        nextProcessIDs[previousWindow.id] = application.processIdentifier
        if applicationWindows[application.processIdentifier]?.contains(where: {
          CFEqual($0, previousElement)
        }) != true {
          applicationWindows[application.processIdentifier, default: []].append(previousElement)
        }
      }
    }

    let nextWindowIDs = Set(nextElements.keys)
    let freshObservationIDs = freshWindowObservationIDs(
      windows: windows,
      retainedWindowIDs: retainedWindowIDs
    )
    let removedWindowIDs = Set(previousElements.keys).subtracting(nextWindowIDs)
    newlyDiscoveredWindowIDs =
      hasCompletedWindowSnapshot
      ? nextWindowIDs.subtracting(previousElements.keys)
      : []
    if tracesWindowTopology || !newlyDiscoveredWindowIDs.isEmpty {
      let discoveredIDs = newlyDiscoveredWindowIDs.sorted {
        $0.rawValue < $1.rawValue
      }.map { String($0.rawValue) }.joined(separator: ",")
      let elapsedMS =
        (ProcessInfo.processInfo.systemUptime - snapshotStartedAt) * 1_000
      let mode = incrementalProcessIDs == nil ? "full" : "incremental"
      frameCoordinator.recordTrace(
        "window-snapshot mode=\(mode) ms=\(String(format: "%.2f", elapsedMS)) discovered=\(newlyDiscoveredWindowIDs.count)[\(discoveredIDs)] total=\(windows.count)"
      )
    }
    hasCompletedWindowSnapshot = true
    elements = nextElements
    processIDs = nextProcessIDs
    floatingWindowIDs = Set(windows.lazy.filter(\.floating).map(\.id))
    applications = nextApplications
    applicationWindowCounts = applicationWindows.mapValues(\.count)
    lastSnapshotWindows = windows
    lastApplicationWindowElements = applicationWindows
    enhancedUIByProcess = enhancedUIByProcess.filter { nextApplications[$0.key] != nil }
    eventMonitor?.refresh(applications: applicationWindows)
    targetFrames = targetFrames.filter { nextElements[$0.key] != nil }
    pendingFrameCorrections = pendingFrameCorrections.filter { nextElements[$0.key] != nil }
    latestObservedFrames = latestObservedFrames.filter {
      freshObservationIDs.contains($0.key)
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
    internalFocusDeadlines = internalFocusDeadlines.filter { $0.value >= now }
    let focusedProcessID = focusedWindowID.flatMap { nextProcessIDs[$0] }
    let nativeFocusTargetMatched = nativeFocusEventMatchesTarget(
      eventPending: nativeFocusEventPending,
      eventProcessIDs: nativeFocusEventProcessIDs,
      hasUnknownEventProcess: nativeFocusEventHasUnknownProcess,
      focusedProcessID: focusedProcessID
    )
    var nativeFocusChanged = nativeFocusTargetMatched
    if nativeFocusChanged,
      let focusedWindowID,
      internalFocusDeadlines.removeValue(forKey: focusedWindowID) != nil
    {
      nativeFocusChanged = false
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
    let userInput = userInputTracker.snapshot
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

func freshWindowObservationIDs(
  windows: [Window],
  retainedWindowIDs: Set<WindowID>
) -> Set<WindowID> {
  Set(windows.lazy.map(\.id)).subtracting(retainedWindowIDs)
}
