import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

private let snapshotAccessibilityTimeoutSeconds: Float = 0.05
private let maximumTransientOwnerResolutionAttempts = 8

func transientOwnerResolutionRetryDelay(afterAttempt attempt: Int) -> TimeInterval {
  guard attempt >= 2 else { return 0 }
  return min(pow(2, Double(attempt - 2)), 5)
}

func transientOwnerResolutionRetryDeadline(
  afterAttempt attempt: Int,
  now: TimeInterval
) -> TimeInterval? {
  guard attempt < maximumTransientOwnerResolutionAttempts else { return nil }
  return now + transientOwnerResolutionRetryDelay(afterAttempt: attempt)
}

func transientOwnerResolutionShouldClearCachedOwner(afterAttempt attempt: Int) -> Bool {
  attempt >= maximumTransientOwnerResolutionAttempts
}

func transientOwnerResolutionIsDue(
  ownerKnown: Bool,
  attempts: Int,
  retryAfter: TimeInterval?,
  now: TimeInterval
) -> Bool {
  guard
    retryAfter != nil
      || (ownerKnown == false
        && attempts < maximumTransientOwnerResolutionAttempts)
  else { return false }
  return (retryAfter ?? 0) <= now
}

func transientOwnerResolutionRefreshInterval(
  retryAfter: [TimeInterval],
  now: TimeInterval
) -> TimeInterval? {
  retryAfter.min().map { max($0 - now, 0) }
}

func transientOwnerWindowIDsToRevalidate(
  candidateIDs: Set<WindowID>,
  processIDs: [WindowID: pid_t],
  topologyProcessIDs: Set<pid_t>
) -> Set<WindowID> {
  candidateIDs.filter {
    processIDs[$0].map(topologyProcessIDs.contains) == true
  }
}

func transientOwnerResolutionCandidateIDs(
  windows: [Window],
  relationshipChildIDs: Set<WindowID>
) -> Set<WindowID> {
  Set(windows.compactMap { window in
    window.isModal
      || window.floatingOrigin == .automatic
      || window.forceTiling
      || relationshipChildIDs.contains(window.id)
      ? window.id
      : nil
  })
}

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
  let windowIDReplacements: [WindowID: WindowID]
  let ignoredWindowCandidates: [pid_t: [IgnoredWindowCandidate]]
  let ignoredWindowReasonsByID: [WindowID: String]
  let ignoredProcessReasonsByProcess: [pid_t: String]
  let minimizedWindowIDs: Set<WindowID>
  let unresolvedOutcomesByProcess: [pid_t: Set<String>]
  let refreshedProcessIDs: Set<pid_t>

  func unresolvedOutcome(for processID: pid_t) -> String {
    let observations = unresolvedOutcomesByProcess[processID, default: []].sorted()
    guard !observations.isEmpty else { return "AX-no-window-match" }
    return "AX-no-window-match;process-observations=" + observations.joined(separator: "|")
  }
}

extension SnapshotEngine {
  func discoverSnapshotWindows(
    monitors: [MonitorSnapshot],
    config: Config,
    incrementalProcessIDs: Set<pid_t>?,
    forceWindowListRefresh: Bool,
    forceWindowListRefreshProcessIDs: Set<pid_t> = [],
    forceApplicationInventoryRefresh: Bool,
    capturedTopologyRequiresFullSnapshot: Bool,
    topologyProcessIDs: Set<pid_t>,
    createdElements: [pid_t: [AXUIElement]],
    preparedWindowAttributes: [WindowID: AXWindowAttributes],
    preparedTransientOwnerWindowIDs: [WindowID: WindowID],
    preparedApplicationWindows: [pid_t: PreparedAXApplicationWindows],
    explicitlyDestroyedWindowIDs: Set<WindowID>,
    frameRefreshWindowIDs: Set<WindowID>? = nil,
    shouldReadProcess: (pid_t) -> Bool = { _ in true },
    publicCGWindows: () -> [CGWindowRecord]?
  ) -> SnapshotWindowDiscoveryResult {
      let previousElements = elements
      let previousProcessIDs = processIDs
      let previousApplications = applications
      let previousApplicationIDs = applicationIDsByProcess
      var previouslyManagedApplicationWindows: [pid_t: [AXUIElement]] = [:]
      var previousWindowIDsByProcessAndElementHash: [pid_t: [UInt: [WindowID]]] = [:]
      for (windowID, element) in previousElements {
        guard let processID = previousProcessIDs[windowID] else { continue }
        previouslyManagedApplicationWindows[processID, default: []].append(element)
        previousWindowIDsByProcessAndElementHash[processID, default: [:]][
          CFHash(element), default: []
        ].append(windowID)
      }
      let previousWindowsByProcess = Dictionary(
        grouping: lastSnapshotWindows,
        by: \.processID
      )
      let previousWindowsByID = Dictionary(
        lastSnapshotWindows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
      )
      var nextElements: [WindowID: AXUIElement] = [:]
      var nextProcessIDs: [WindowID: pid_t] = [:]
      var nextApplications: [pid_t: AXUIElement] = [:]
      var nextApplicationIDs: [pid_t: String] = [:]
      var applicationWindows: [pid_t: [AXUIElement]] = [:]
      var minimizedWindows = minimizedWindowElementsByProcess
      var transientGeometryWindows = transientGeometryWindowElementsByProcess
      var windows: [Window] = []
      var ignoredWindowCandidates: [pid_t: [IgnoredWindowCandidate]] = [:]
      var ignoredWindowReasonsByID: [WindowID: String] = [:]
      var ignoredProcessReasonsByProcess: [pid_t: String] = [:]
      var unresolvedOutcomesByProcess: [pid_t: Set<String>] = [:]
      var refreshedProcessIDs = Set<pid_t>()
      var nextNativeWindowTabGroups: [WindowID: NativeWindowTabGroup] = [:]
      var nextRetainedWindowIDs = Set<WindowID>()
      var cachedSnapshotWindowIDs = Set<WindowID>()
  
      var deferredReadProcessIDs = Set<pid_t>()
      func reuseCachedProcess(_ processID: pid_t) -> Bool {
        guard let cachedApplication = previousApplications[processID] else { return false }
        let cachedWindows = previousWindowsByProcess[processID] ?? []
        let cachedElements = cachedWindows.compactMap { window in
          previousElements[window.id].map { (window.id, $0) }
        }
        let cachedApplicationWindows = lastApplicationWindowElements[processID]
        guard cachedElements.count == cachedWindows.count,
          cachedApplicationWindows != nil || cachedWindows.isEmpty,
          explicitlyDestroyedWindowIDs.isDisjoint(with: cachedWindows.map(\.id))
        else { return false }
        nextApplications[processID] = cachedApplication
        if let appID = previousApplicationIDs[processID] {
          nextApplicationIDs[processID] = appID
        }
        applicationWindows[processID] = cachedApplicationWindows
        windows.append(contentsOf: cachedWindows)
        nextRetainedWindowIDs.formUnion(retainedWindowIDsForCachedWindows(
          cachedWindows, previousRetainedWindowIDs: retainedWindowIDs
        ))
        cachedSnapshotWindowIDs.formUnion(cachedWindows.lazy.map(\.id))
        for (windowID, element) in cachedElements {
          nextElements[windowID] = element
          nextProcessIDs[windowID] = processID
          nextNativeWindowTabGroups[windowID] = nativeWindowTabGroupsByWindowID[windowID]
        }
        return true
      }
      var processIDsToRefresh = incrementalProcessIDs
      if var requestedProcessIDs = processIDsToRefresh {
        for processID in previousApplications.keys where !requestedProcessIDs.contains(processID) {
          if !reuseCachedProcess(processID) {
            requestedProcessIDs.insert(processID)
          } else if !shouldReadProcess(processID) {
            deferredReadProcessIDs.insert(processID)
          }
        }
        processIDsToRefresh = requestedProcessIDs
      }

      let refreshesApplicationInventory = applicationInventoryRefreshIsRequired(
        hasCompletedSnapshot: hasCompletedWindowSnapshot,
        topologyRequiresFullSnapshot: capturedTopologyRequiresFullSnapshot,
        forced: forceApplicationInventoryRefresh
      )
      let observedCGWindows = publicCGWindows() ?? []
      let inventoryStartedAt = ProcessInfo.processInfo.systemUptime
      let workspaceApplications = refreshesApplicationInventory
        ? NSWorkspace.shared.runningApplications : []
      var fallbackApplicationIDs: [pid_t: String] = [:]
      if refreshesApplicationInventory {
        applicationInventorySnapshotCount += 1
      }
      let baseApplications: [(processID: pid_t, application: NSRunningApplication?)]
      if refreshesApplicationInventory {
        baseApplications = workspaceApplications.map {
          ($0.processIdentifier, $0)
        }
      } else if let processIDsToRefresh {
        baseApplications = processIDsToRefresh.sorted().map {
          ($0, previousApplications[$0] == nil
            ? NSRunningApplication(processIdentifier: $0)
            : nil)
        }
      } else {
        baseApplications = previousApplications.keys.sorted().map { ($0, nil) }
      }
      let knownProcessIDs = refreshesApplicationInventory
        ? Set(workspaceApplications.map(\.processIdentifier))
        : Set(previousApplications.keys)
      let missingProcessIDs = missingApplicationProcessIDs(
        cgWindows: observedCGWindows,
        knownProcessIDs: knownProcessIDs,
        previouslyManagedProcessIDs: Set(previouslyManagedApplicationWindows.keys)
      )
      for processID in missingProcessIDs
      where refreshesApplicationInventory || (processIDsToRefresh?.contains(processID) ?? true) {
        let processApplication = workspaceApplications.first(where: {
          $0.processIdentifier == processID
        }) ?? NSRunningApplication(processIdentifier: processID)
        let bundleID = processApplication == nil ? appBundleIdentifier(processID: processID) : nil
        guard missingApplicationFallbackIsEligible(
          isTerminated: processApplication?.isTerminated ?? false,
          isRegularApplication: processApplication.map {
            $0.activationPolicy == .regular
          },
          hasValidatedBundle: bundleID != nil
        ) else {
          ignoredProcessReasonsByProcess[processID] = processApplication == nil
            ? "application-identity-unverified"
            : processApplication?.isTerminated == true
              ? "terminated-application" : "non-regular-application"
          continue
        }
        let ownerName = observedCGWindows.first(where: {
          $0.processID == processID && $0.layer == 0
        })?.ownerName
        fallbackApplicationIDs[processID] = fallbackApplicationIdentity(
          bundleIdentifier: bundleID ?? processApplication?.bundleIdentifier,
          ownerName: processApplication?.localizedName ?? ownerName,
          processID: processID
        )
      }
      if refreshesApplicationInventory {
        recordDurationSample(
          (ProcessInfo.processInfo.systemUptime - inventoryStartedAt) * 1_000,
          in: &applicationInventoryDurationSamplesMS
        )
      }
      let baseProcessIDs = Set(baseApplications.map(\.processID))
      let runningApplications = baseApplications + fallbackApplicationIDs.keys
        .filter { !baseProcessIDs.contains($0) }.sorted().map { ($0, nil) }
      let ownProcessID = ProcessInfo.processInfo.processIdentifier
      for runningApplication in runningApplications {
        let processID = runningApplication.processID
        guard processID > 0, processID != ownProcessID else { continue }
        if !shouldReadProcess(processID), reuseCachedProcess(processID) {
          deferredReadProcessIDs.insert(processID)
          continue
        }
        minimizedWindows[processID] = []
        transientGeometryWindows[processID] = []
        let appID: String
        if let application = runningApplication.application {
          guard !application.isTerminated,
            application.activationPolicy == .regular
          else {
            ignoredProcessReasonsByProcess[processID] = "non-regular-application"
            continue
          }
          appID =
            application.bundleIdentifier
            ?? application.localizedName
            ?? "pid-\(processID)"
        } else if let fallbackAppID = fallbackApplicationIDs[processID] {
          appID = fallbackAppID
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
            || forceWindowListRefresh
            || forceWindowListRefreshProcessIDs.contains(processID),
          topologyProcessWasInvalidated: topologyProcessIDs.contains(processID)
            || retainedWindowIDs.contains { previousProcessIDs[$0] == processID }
        )
        var appWindows: [AXUIElement]?
        let created = createdElements[processID] ?? []
        if !created.isEmpty, let cachedApplicationWindows,
          !forceWindowListRefresh,
          !forceWindowListRefreshProcessIDs.contains(processID),
          !refreshesApplicationInventory
        {
          // AXWindows can lag AXWindowCreated. Place the reported window now;
          // the existing 50 ms topology retry reconciles the complete list.
          appWindows = cachedApplicationWindows
        } else if refreshesWindowList {
          refreshedProcessIDs.insert(processID)
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
                  let preparedAppElement = AssumedThreadSafe(appElement)
onMain { $0.eventMonitor?.prepareForWindowDiscovery(
                    processID: processID,
                    application: preparedAppElement.value
                  ) }
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
          if copiedWindows == nil {
            // A session transition can invalidate an existing AX connection.
            // Renew it for the already scheduled retry, without an extra read.
            nextApplications[processID] = AXUIElementCreateApplication(processID)
          }
          appWindows = copiedWindows ?? cachedApplicationWindows
        } else {
          appWindows = cachedApplicationWindows
        }
        if !created.isEmpty {
          appWindows = windowCandidatesIncludingCreatedElements(appWindows ?? [], created: created)
        }
        if appWindows == nil {
          unresolvedOutcomesByProcess[processID] = ["AX-window-list-unavailable"]
        } else if appWindows?.isEmpty == true {
          unresolvedOutcomesByProcess[processID] = ["AX-window-list-empty"]
        }
        if let appWindows {
          applicationWindows[processID] = appWindows
        }
        var usedCGWindowIDs = Set<CGWindowID>()
        var unresolvedWindowIDs = Set<WindowID>()
        var ignoredPreviousWindowIDs = Set(
          explicitlyDestroyedWindowIDs.filter {
            previousProcessIDs[$0] == processID
          }
        )
  
        let orderedWindowCandidates = (appWindows ?? []).enumerated().map {
          index, element in
          let previousWindowID = previousWindowIDsByProcessAndElementHash[processID]?[
            CFHash(element)
          ]?.first { CFEqual(previousElements[$0], element) }
          return (
            index: index,
            element: element,
            previousWindowID: previousWindowID
          )
        }.sorted { lhs, rhs in
          windowDiscoveryCandidateComesFirst(
            lhsPreviousWindowID: lhs.previousWindowID,
            lhsIndex: lhs.index,
            rhsPreviousWindowID: rhs.previousWindowID,
            rhsIndex: rhs.index
          )
        }
        for candidate in orderedWindowCandidates {
          let element = candidate.element
          let previousWindowID = candidate.previousWindowID
          if previousWindowID.map(explicitlyDestroyedWindowIDs.contains) == true {
            continue
          }
          // A targeted frame observation cannot make a sibling's cached
          // geometry fresh. Topology and watchdog passes still read the process.
          if !refreshesWindowList, let frameRefreshWindowIDs, let previousWindowID,
            !frameRefreshWindowIDs.contains(previousWindowID),
            let cached = previousWindowsByID[previousWindowID],
            let nativeID = CGWindowID(exactly: previousWindowID.rawValue)
          {
            guard usedCGWindowIDs.insert(nativeID).inserted else { continue }
            windows.append(cached)
            nextElements[previousWindowID] = element
            nextProcessIDs[previousWindowID] = processID
            nextNativeWindowTabGroups[previousWindowID] = nativeWindowTabGroupsByWindowID[previousWindowID]
            cachedSnapshotWindowIDs.insert(previousWindowID)
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
            unresolvedOutcomesByProcess[processID, default: []].insert("AX-window-attributes-unavailable")
            if let previousWindowID {
              unresolvedWindowIDs.insert(previousWindowID)
            } else {
              cacheWindowElementForShortRetry(
                element,
                processID: processID,
                elementsByProcess: &unmatchedWindowElementsByProcess,
                attemptsByProcess: &unmatchedWindowRetryAttemptsByProcess
              )
            }
            continue
          case .ignored(let reason, let title):
            ignoredWindowCandidates[processID, default: []].append(
              IgnoredWindowCandidate(title: title, reason: reason)
            )
            if reason == "AX-minimized" {
              minimizedWindows[processID, default: []].append(element)
            } else {
              transientGeometryWindows[processID, default: []].append(element)
            }
            if let previousWindowID {
              ignoredPreviousWindowIDs.insert(previousWindowID)
              ignoredWindowReasonsByID[previousWindowID] = reason
            }
            continue
          case .transientGeometry:
            unresolvedOutcomesByProcess[processID, default: []].insert("AX-frame-unavailable")
            transientGeometryWindows[processID, default: []].append(element)
            continue
          case .unmatched:
            unresolvedOutcomesByProcess[processID, default: []].insert("AX-candidate-unmatched")
            if let previousWindowID {
              unresolvedWindowIDs.insert(previousWindowID)
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
              reuseCachedCapabilities: !refreshesWindowList,
              preparedModalState: previousWindowID.flatMap {
                preparedWindowAttributes[$0]?.modal
              }
            )
          }
          switch disposition {
          case .unavailable:
            unresolvedOutcomesByProcess[processID, default: []].insert("AX-management-metadata-unavailable")
            if let previousWindowID {
              unresolvedWindowIDs.insert(previousWindowID)
            } else {
              cacheWindowElementForShortRetry(
                element,
                processID: processID,
                elementsByProcess: &unmatchedWindowElementsByProcess,
                attemptsByProcess: &unmatchedWindowRetryAttemptsByProcess
              )
            }
            continue
          case .ignored:
            ignoredWindowReasonsByID[candidate.id] = windowExclusionReason(
              appID: candidate.appID, role: candidate.role, subrole: candidate.subrole
            )
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
          tracked.forceTiling = decision.forceTiling
          tracked.floatingOrigin = floatingOrigin(
            for: disposition,
            configuredFloating: decision.floating
          )
          var nativeTabGroup: NativeWindowTabGroup?
          if refreshesWindowList || previousWindowID == nil {
            // ponytail: native tab groups are small; index physical IDs if this scan grows.
            let belongsToKnownNativeTabGroup =
              nativeWindowTabGroupsByWindowID[tracked.id] != nil
              || nativeWindowTabGroupsByWindowID.values.contains {
                $0.backingWindowIDs.contains(tracked.id)
              }
            nativeTabGroup = AXMessagingTimeoutAccess.shared.withTimeout(
              snapshotAccessibilityTimeoutSeconds,
              elements: [element]
            ) {
              self.nativeWindowTabGroup(
                in: element,
                windowFrame: tracked.frame,
                allowsTransientFrameMismatch:
                  belongsToKnownNativeTabGroup
              )
            }
          } else {
            nativeTabGroup = previousWindowID.flatMap {
              nativeWindowTabGroupsByWindowID[$0]
            }
          }
          if let detectedGroup = nativeTabGroup {
            nativeTabGroup = nativeWindowTabGroupRebindingKnownMembers(
              detectedGroup,
              representativeID: tracked.id,
              processID: processID,
              previousGroupsByRepresentativeID:
                nativeWindowTabGroupsByWindowID,
              previousProcessIDs: previousProcessIDs
            )
          }
          windows.append(tracked)
          nextElements[tracked.id] = element
          nextProcessIDs[tracked.id] = processID
          nextNativeWindowTabGroups[tracked.id] = nativeTabGroup
        }

        let previousWindows = previousWindowsByProcess[processID] ?? []
        let discoveredWindowIDs = Set(nextElements.keys)
        let needsCachedWindowValidation = previousWindows.contains {
          !discoveredWindowIDs.contains($0.id)
            && !ignoredPreviousWindowIDs.contains($0.id)
        }
        let cachedWindowState: ((WindowID) -> (error: AXError, minimized: Bool?))?
        if appWindows == nil {
          cachedWindowState = nil
        } else {
          cachedWindowState = { windowID in
            guard let element = previousElements[windowID] else { return (.invalidUIElement, nil) }
            return AXMessagingTimeoutAccess.shared.withTimeout(
              snapshotAccessibilityTimeoutSeconds,
              elements: [element]
            ) {
              var minimized: CFTypeRef?
              let error = AXUIElementCopyAttributeValue(
                element, kAXMinimizedAttribute as CFString, &minimized
              )
              return (error, minimized as? Bool)
            }
          }
        }
        let retentionCGWindows = needsCachedWindowValidation ? publicCGWindows() : []
        let retainableWindowIDs = cachedWindowIDsToRetain(
          processID: processID,
          previousWindows: previousWindows,
          discoveredWindowIDs: discoveredWindowIDs,
          ignoredWindowIDs: ignoredPreviousWindowIDs,
          unresolvedWindowIDs: unresolvedWindowIDs,
          cgWindows: retentionCGWindows,
          previousElements: previousElements,
          discoveredElements: nextElements,
          cachedWindowState: cachedWindowState
        )
        let confirmedWindowIDs = Set((retentionCGWindows ?? []).filter { record in
          guard record.processID == processID else { return false }
          if record.isOnscreen || appWindows == nil { return true }
          let windowID = WindowID(rawValue: UInt64(record.id))
          return previousElements[windowID].map { previous in
            appWindows?.contains(where: { CFEqual($0, previous) }) == true
          } ?? false
        }.map { WindowID(rawValue: UInt64($0.id)) })
        let retention = retainedWindowIDsWithinGracePeriod(
          retainableWindowIDs,
          // WindowServer can retain closed, ordered-out surfaces. A successful AX
          // inventory omitting a hidden window must eventually retire its column.
          // Keep visible windows and failed AX inventories recoverable after wake.
          previousDeadlines: retainedWindowDeadlines.filter {
            !confirmedWindowIDs.contains($0.key)
          },
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
          nextNativeWindowTabGroups[previousWindow.id] =
            nativeWindowTabGroupsByWindowID[previousWindow.id]
          if applicationWindows[processID]?.contains(where: {
            CFEqual($0, previousElement)
          }) != true {
            applicationWindows[processID, default: []].append(previousElement)
          }
        }

        let processNativeTabGroups = nextNativeWindowTabGroups.filter {
          nextProcessIDs[$0.key] == processID
        }
        let newlyObservedProcessWindowIDs = Set(
          windows.lazy.filter { $0.processID == processID }.map(\.id)
        ).subtracting(previousElements.keys)
        let additionalBackingWindowIDsByRepresentative:
          [WindowID: Set<WindowID>] = Dictionary(
            uniqueKeysWithValues: processNativeTabGroups.compactMap {
              representativeID, group in
              guard let previousGroup =
                  nativeWindowTabGroupsByWindowID[representativeID],
                group.tabTitles.count == previousGroup.tabTitles.count + 1
              else { return nil }
              return (representativeID, newlyObservedProcessWindowIDs)
            }
          )
        let nativeTabBackingIDsByRepresentative =
          nativeTabBackingWindowIDsByRepresentative(
            windows: windows.filter { $0.processID == processID },
            groupsByRepresentativeID: processNativeTabGroups,
            retainedWindowIDs: processRetainedWindowIDs,
            additionalBackingWindowIDsByRepresentative:
              additionalBackingWindowIDsByRepresentative
          )
        let nativeTabBackingIDs = Set(
          nativeTabBackingIDsByRepresentative.values.flatMap { $0 }
        )
        if nativeTabBackingIDs.isEmpty == false {
          for (representativeID, backingWindowIDs) in
            nativeTabBackingIDsByRepresentative
          {
            nextNativeWindowTabGroups[representativeID]?.backingWindowIDs =
              backingWindowIDs
          }
          windows.removeAll { nativeTabBackingIDs.contains($0.id) }
          for windowID in nativeTabBackingIDs {
            nextElements[windowID] = nil
            nextProcessIDs[windowID] = nil
            nextNativeWindowTabGroups[windowID] = nil
          }
          let representativeIDs = nativeTabBackingIDsByRepresentative.keys.sorted {
            $0.rawValue < $1.rawValue
          }.map { String($0.rawValue) }.joined(separator: ",")
          let backingIDs = nativeTabBackingIDs.sorted {
            $0.rawValue < $1.rawValue
          }.map { String($0.rawValue) }.joined(separator: ",")
          frameCoordinator.recordTrace(
            "native-tabs pid=\(processID) representatives=[\(representativeIDs)] backing=[\(backingIDs)]"
          )
        }
      }
    resolveTransientOwners(
      windows: &windows,
      elements: nextElements,
      processIDs: nextProcessIDs,
      preparedOwnerWindowIDs: preparedTransientOwnerWindowIDs,
      deferredProcessIDs: deferredReadProcessIDs,
      topologyProcessIDs:
        capturedTopologyRequiresFullSnapshot
        ? Set(nextProcessIDs.values)
        : topologyProcessIDs
    )
    let liveNativeWindowTabGroups = nextNativeWindowTabGroups.filter {
      nextElements[$0.key] != nil
    }
    let windowIDReplacements = nativeWindowTabRepresentativeReplacements(
      previousWindowIDs: Set(previousElements.keys),
      nextWindowIDs: Set(nextElements.keys),
      groupsByRepresentativeID: liveNativeWindowTabGroups
    )
    nativeWindowTabGroupsByWindowID = liveNativeWindowTabGroups
    let titleMatchedIgnoredReasons = uniquelyMatchedCGWindowReasons(
      records: publicCGWindows() ?? [], candidatesByProcess: ignoredWindowCandidates
    )
    var allIgnoredReasons = titleMatchedIgnoredReasons
    allIgnoredReasons.merge(ignoredWindowReasonsByID) { _, exact in exact }
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
        previouslyManagedApplicationWindows,
      windowIDReplacements: windowIDReplacements,
      ignoredWindowCandidates: ignoredWindowCandidates,
      ignoredWindowReasonsByID: allIgnoredReasons,
      ignoredProcessReasonsByProcess: ignoredProcessReasonsByProcess,
      minimizedWindowIDs: Set(allIgnoredReasons.compactMap {
        $0.value == "AX-minimized" ? $0.key : nil
      }),
      unresolvedOutcomesByProcess: unresolvedOutcomesByProcess,
      refreshedProcessIDs: refreshedProcessIDs
    )
  }

  private func resolveTransientOwners(
    windows: inout [Window],
    elements: [WindowID: AXUIElement],
    processIDs: [WindowID: pid_t],
    preparedOwnerWindowIDs: [WindowID: WindowID],
    deferredProcessIDs: Set<pid_t>,
    topologyProcessIDs: Set<pid_t>
  ) {
    let liveWindowIDs = Set(elements.keys)
    transientOwnerWindowIDs = transientOwnerWindowIDs.filter {
      liveWindowIDs.contains($0.key) && liveWindowIDs.contains($0.value)
    }
    transientOwnerResolutionAttempts = transientOwnerResolutionAttempts.filter {
      liveWindowIDs.contains($0.key)
    }
    transientOwnerResolutionRetryAfter = transientOwnerResolutionRetryAfter.filter {
      liveWindowIDs.contains($0.key)
    }
    let candidateIDs = transientOwnerResolutionCandidateIDs(
      windows: windows,
      relationshipChildIDs: Set(preparedOwnerWindowIDs.keys)
        .union(transientOwnerWindowIDs.keys)
    )
    let livePreparedOwnerWindowIDs = preparedOwnerWindowIDs.filter {
      candidateIDs.contains($0.key) && liveWindowIDs.contains($0.value)
    }
    transientOwnerWindowIDs.merge(livePreparedOwnerWindowIDs) { _, prepared in prepared }
    transientOwnerResolutionAttempts = transientOwnerResolutionAttempts.filter {
      candidateIDs.contains($0.key)
    }
    transientOwnerResolutionRetryAfter = transientOwnerResolutionRetryAfter.filter {
      candidateIDs.contains($0.key)
    }
    let revalidatedCandidateIDs = transientOwnerWindowIDsToRevalidate(
      candidateIDs: candidateIDs,
      processIDs: processIDs,
      topologyProcessIDs: topologyProcessIDs
    )
    let now = ProcessInfo.processInfo.systemUptime
    let ownerLookupCandidateIDs = revalidatedCandidateIDs.union(
      candidateIDs.filter {
        transientOwnerResolutionIsDue(
          ownerKnown: transientOwnerWindowIDs[$0] != nil,
          attempts: transientOwnerResolutionAttempts[$0, default: 0],
          retryAfter: transientOwnerResolutionRetryAfter[$0],
          now: now
        )
      }
    )
    .filter { processIDs[$0].map { !deferredProcessIDs.contains($0) } ?? true }
    var resolvedCandidateIDs = ownerLookupCandidateIDs.intersection(
      livePreparedOwnerWindowIDs.keys
    )
    for childID in ownerLookupCandidateIDs where !resolvedCandidateIDs.contains(childID) {
      guard let child = elements[childID] else { continue }
      let parent = AXMessagingTimeoutAccess.shared.withTimeout(
        snapshotAccessibilityTimeoutSeconds,
        elements: [child]
      ) {
        guard
          let value = self.copyAttribute(child, name: kAXParentAttribute),
          CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil as AXUIElement? }
        return (value as! AXUIElement)
      }
      if let parent,
        let ownerID = elements.first(where: {
          $0.key != childID && CFEqual($0.value, parent)
        })?.key
      {
        transientOwnerWindowIDs[childID] = ownerID
        resolvedCandidateIDs.insert(childID)
      }
    }
    for childID in ownerLookupCandidateIDs {
      guard resolvedCandidateIDs.contains(childID) == false else {
        transientOwnerResolutionAttempts[childID] = nil
        transientOwnerResolutionRetryAfter[childID] = nil
        continue
      }
      let attempt = transientOwnerResolutionAttempts[childID, default: 0] + 1
      transientOwnerResolutionAttempts[childID] = attempt
      if transientOwnerResolutionShouldClearCachedOwner(afterAttempt: attempt) {
        transientOwnerWindowIDs[childID] = nil
      }
      transientOwnerResolutionRetryAfter[childID] =
        transientOwnerResolutionRetryDeadline(afterAttempt: attempt, now: now)
    }
    for index in windows.indices {
      windows[index].transientOwnerID = transientOwnerWindowIDs[windows[index].id]
    }
  }
}
