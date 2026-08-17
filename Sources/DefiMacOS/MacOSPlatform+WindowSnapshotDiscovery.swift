import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

private let snapshotAccessibilityTimeoutSeconds: Float = 0.05

struct SnapshotWindowDiscoveryResult {
  let nextElements: [WindowID: AXUIElement]
  let nextProcessIDs: [WindowID: pid_t]
  let nextApplications: [pid_t: AXUIElement]
  let nextApplicationIDs: [pid_t: String]
  let applicationWindows: [pid_t: [AXUIElement]]
  let minimizedWindows: [pid_t: [AXUIElement]]
  let transientGeometryWindows: [pid_t: [AXUIElement]]
  let windows: [Window]
  let nextRetainedWindowIDs: Set<WindowID>
  let cachedSnapshotWindowIDs: Set<WindowID>
  let previouslyManagedApplicationWindows: [pid_t: [AXUIElement]]
}

@MainActor
extension MacOSPlatform {
  func discoverSnapshotWindows(
    monitors: [MonitorSnapshot],
    config: Config,
    incrementalProcessIDs: Set<pid_t>?,
    forceWindowListRefresh: Bool,
    forceApplicationInventoryRefresh: Bool,
    capturedTopologyRequiresFullSnapshot: Bool,
    topologyProcessIDs: Set<pid_t>,
    preparedWindowAttributes: [WindowID: AXWindowAttributes],
    preparedApplicationWindows: [pid_t: PreparedAXApplicationWindows],
    publicCGWindows: () -> [CGWindowRecord]?
  ) -> SnapshotWindowDiscoveryResult {
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
      var minimizedWindows = minimizedWindowElementsByProcess
      var transientGeometryWindows = transientGeometryWindowElementsByProcess
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
        topologyRequiresFullSnapshot: capturedTopologyRequiresFullSnapshot,
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
        minimizedWindows[processID] = []
        transientGeometryWindows[processID] = []
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
          let observedEnhancedUI = AXMessagingTimeoutAccess.shared
            .withTimeout(
              snapshotAccessibilityTimeoutSeconds,
              elements: [appElement]
            ) {
              value(
                appElement,
                attribute: "AXEnhancedUserInterface",
                as: Bool.self
              )
            }
          enhancedUIByProcess[processID] = observedEnhancedUI
        }
        let cachedApplicationWindows = lastApplicationWindowElements[processID]
        let refreshesWindowList = applicationWindowListRefreshIsRequired(
          hasCachedWindows: cachedApplicationWindows != nil,
          refreshesAllWindowLists:
            refreshesApplicationInventory
            || capturedTopologyRequiresFullSnapshot
            || forceWindowListRefresh,
          topologyProcessWasInvalidated: topologyProcessIDs.contains(processID)
        )
        let appWindows: [AXUIElement]?
        if refreshesWindowList {
          applicationWindowListReadCount += 1
          let windowListStartedAt = ProcessInfo.processInfo.systemUptime
          let preparedWindows = preparedApplicationWindows[processID]
          let copiedWindows = preparedWindows?.elements
            ?? AXMessagingTimeoutAccess.shared.withTimeout(
              snapshotAccessibilityTimeoutSeconds,
              elements: [appElement]
            ) {
              applicationWindowsAfterPreparingTopologyObservation(
                prepareObservation: {
                  eventMonitor?.prepareForWindowDiscovery(
                    processID: processID,
                    application: appElement
                  )
                },
                copyWindows: {
                  copyElements(
                    appElement,
                    attribute: kAXWindowsAttribute
                  )
                }
              )
            }
          recordDurationSample(
            preparedWindows?.durationMS
              ?? (ProcessInfo.processInfo.systemUptime - windowListStartedAt) * 1_000,
            in: &applicationWindowListDurationSamplesMS
          )
          windowListReadRetryAttemptsByProcess[processID] =
            updatedWindowListReadRetryAttempts(
              previousAttempts: windowListReadRetryAttemptsByProcess[processID],
              readSucceeded: copiedWindows != nil
            )
          appWindows = copiedWindows ?? cachedApplicationWindows
        } else {
          appWindows = cachedApplicationWindows
        }
        if let appWindows {
          applicationWindows[processID] = appWindows
        }
        var usedCGWindowIDs = Set<CGWindowID>()
        var ignoredPreviousWindowIDs = Set(
          explicitlyDestroyedWindowIDs.filter {
            previousProcessIDs[$0] == processID
          }
        )
  
        for element in appWindows ?? [] {
          let previousWindowID = previousElements.first { windowID, previousElement in
            previousProcessIDs[windowID] == processID
              && CFEqual(previousElement, element)
          }?.key
          if previousWindowID.map(explicitlyDestroyedWindowIDs.contains) == true {
            continue
          }
          if previousWindowID == nil,
            unmatchedWindowElementsByProcess[processID]?.contains(where: {
              CFEqual($0, element)
            }) == true
          {
            continue
          }
          let discovery = AXMessagingTimeoutAccess.shared.withTimeout(
            snapshotAccessibilityTimeoutSeconds,
            elements: [element]
          ) {
            makeWindow(
              element: element,
              processID: processID,
              appID: appID,
              config: config,
              publicCGWindows: publicCGWindows,
              monitors: monitors,
              preferredWindowID: previousWindowID,
              excluding: usedCGWindowIDs,
              preparedAttributes: previousWindowID.flatMap {
                preparedWindowAttributes[$0]
              }
            )
          }
          let candidate: Window
          let cgWindowID: CGWindowID
          let decision: RuleDecision
          switch discovery {
          case .unavailable:
            if previousWindowID == nil {
              cacheWindowElementForShortRetry(
                element,
                processID: processID,
                elementsByProcess: &unmatchedWindowElementsByProcess,
                attemptsByProcess: &unmatchedWindowRetryAttemptsByProcess
              )
            }
            continue
          case .ignored:
            minimizedWindows[processID, default: []].append(element)
            if let previousWindowID {
              ignoredPreviousWindowIDs.insert(previousWindowID)
            }
            continue
          case .transientGeometry:
            transientGeometryWindows[processID, default: []].append(element)
            if let previousWindowID {
              ignoredPreviousWindowIDs.insert(previousWindowID)
            }
            continue
          case .unmatched:
            if let previousWindowID {
              ignoredPreviousWindowIDs.insert(previousWindowID)
            } else {
              cacheWindowElementForShortRetry(
                element,
                processID: processID,
                elementsByProcess: &unmatchedWindowElementsByProcess,
                attemptsByProcess: &unmatchedWindowRetryAttemptsByProcess
              )
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
          let disposition = AXMessagingTimeoutAccess.shared.withTimeout(
            snapshotAccessibilityTimeoutSeconds,
            elements: [element]
          ) {
            windowDisposition(
              candidate,
              element: element,
              configuredFloating: decision.floating,
              forceTiling: decision.forceTiling,
              previousDisposition: previousDisposition,
              reuseCachedCapabilities:
                previousWindowID.flatMap {
                  windowManagementCapabilities[$0]
                } != nil,
              preparedModalState: previousWindowID.flatMap {
                preparedWindowAttributes[$0]?.modal
              }
            )
          }
          switch disposition {
          case .unavailable:
            cacheWindowElementForShortRetry(
              element,
              processID: processID,
              elementsByProcess: &unmatchedWindowElementsByProcess,
              attemptsByProcess: &unmatchedWindowRetryAttemptsByProcess
            )
            continue
          case .ignored:
            if let previousWindowID {
              ignoredPreviousWindowIDs.insert(previousWindowID)
            }
            continue
          case .tiled, .floating:
            break
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
            return AXMessagingTimeoutAccess.shared.withTimeout(
              snapshotAccessibilityTimeoutSeconds,
              elements: [element]
            ) {
              self.value(
                element,
                attribute: kAXMinimizedAttribute,
                as: Bool.self
              )
            }
          }
        }
        let retainableWindowIDs = cachedWindowIDsToRetain(
          processID: processID,
          previousWindows: previousWindows,
          discoveredWindowIDs: discoveredWindowIDs,
          ignoredWindowIDs: ignoredPreviousWindowIDs,
          cgWindows: needsCachedWindowValidation ? publicCGWindows() : [],
          cachedMinimizedState: cachedMinimizedState
        )
        let retention = retainedWindowIDsWithinGracePeriod(
          retainableWindowIDs,
          previousDeadlines: retainedWindowDeadlines,
          now: ProcessInfo.processInfo.systemUptime
        )
        let processRetainedWindowIDs = retention.windowIDs
        for windowID in previousWindows.map(\.id) {
          retainedWindowDeadlines[windowID] = retention.deadlines[windowID]
        }
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
    return SnapshotWindowDiscoveryResult(
      nextElements: nextElements,
      nextProcessIDs: nextProcessIDs,
      nextApplications: nextApplications,
      nextApplicationIDs: nextApplicationIDs,
      applicationWindows: applicationWindows,
      minimizedWindows: minimizedWindows,
      transientGeometryWindows: transientGeometryWindows,
      windows: windows,
      nextRetainedWindowIDs: nextRetainedWindowIDs,
      cachedSnapshotWindowIDs: cachedSnapshotWindowIDs,
      previouslyManagedApplicationWindows:
        previouslyManagedApplicationWindows
    )
  }
}
