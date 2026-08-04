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
    let incrementalProcessIDs = incrementalWindowRefreshProcessIDs(
      hasCompletedSnapshot: hasCompletedWindowSnapshot,
      eventPending: tracesWindowTopology,
      requiresFullSnapshot: windowTopologyRequiresFullSnapshot,
      processIDs: pendingWindowTopologyProcessIDs
    )
    windowTopologyEventPending = false
    pendingWindowTopologyProcessIDs.removeAll(keepingCapacity: true)
    windowTopologyRequiresFullSnapshot = false
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
      guard let appWindows = copyElements(appElement, attribute: kAXWindowsAttribute)
      else {
        continue
      }
      applicationWindows[application.processIdentifier] = appWindows
      var usedCGWindowIDs = Set<CGWindowID>()

      for element in appWindows {
        let previousWindowID = previousElements.first { windowID, previousElement in
          previousProcessIDs[windowID] == application.processIdentifier
            && CFEqual(previousElement, element)
        }?.key
        guard
          let (candidate, cgWindowID) = makeWindow(
            element: element,
            processID: application.processIdentifier,
            appID: appID,
            cgWindows: cgWindows,
            monitors: monitors,
            preferredWindowID: previousWindowID,
            excluding: usedCGWindowIDs
          )
        else {
          continue
        }
        let decision = config.decision(for: candidate)
        guard
          shouldManage(
            candidate,
            element: element,
            forceTiling: decision.forceTiling,
            wasPreviouslyManaged: previousWindowID != nil
          )
        else {
          continue
        }
        guard usedCGWindowIDs.insert(cgWindowID).inserted else {
          continue
        }
        windows.append(candidate)
        nextElements[candidate.id] = element
        nextProcessIDs[candidate.id] = application.processIdentifier
      }
    }

    let nextWindowIDs = Set(nextElements.keys)
    newlyDiscoveredWindowIDs = hasCompletedWindowSnapshot
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
    applications = nextApplications
    applicationWindowCounts = applicationWindows.mapValues(\.count)
    lastSnapshotWindows = windows
    lastApplicationWindowElements = applicationWindows
    enhancedUIByProcess = enhancedUIByProcess.filter { nextApplications[$0.key] != nil }
    eventMonitor?.refresh(applications: applicationWindows)
    targetFrames = targetFrames.filter { nextElements[$0.key] != nil }
    pendingFrameCorrections = pendingFrameCorrections.filter { nextElements[$0.key] != nil }
    latestObservedFrames = latestObservedFrames.filter { nextElements[$0.key] != nil }
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
    let externalResizeGestureActive =
      leftMouseButtonDown || mouseResizeGestureObserved
    var externallyChangedFrames: [WindowID: Rect] = [:]
    var targetMismatches: [FrameMismatch] = []
    var deferredMismatchCount = 0
    var settledCommitLatenciesMS: [Double] = []
    for window in windows {
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
        initialFrameSettlementDeadlines[window.id] = nil
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
    var nativeFocusChanged = nativeFocusEventPending
    if nativeFocusChanged,
      let focusedWindowID,
      internalFocusDeadlines.removeValue(forKey: focusedWindowID) != nil
    {
      nativeFocusChanged = false
    }
    if nativeFocusEventPending, focusedWindowID == nil, nativeFocusRetryCount > 0 {
      nativeFocusRetryCount -= 1
    } else {
      nativeFocusEventPending = false
      nativeFocusRetryCount = 0
    }
    if tracesWindowTopology || !newlyDiscoveredWindowIDs.isEmpty {
      let elapsedMS =
        (ProcessInfo.processInfo.systemUptime - snapshotStartedAt) * 1_000
      frameCoordinator.recordTrace(
        "window-snapshot-complete ms=\(String(format: "%.2f", elapsedMS))"
      )
    }
    return DesktopSnapshot(
      monitors: monitors,
      windows: windows,
      focusedWindowID: focusedWindowID,
      nativeFocusChanged: nativeFocusChanged,
      externallyChangedFrames: externallyChangedFrames,
      leftMouseButtonDown: leftMouseButtonDown,
      mouseResizeGestureObserved: mouseResizeGestureObserved,
      targetMismatchCount: targetMismatches.count,
      targetMismatches: targetMismatches
    )
  }

}
