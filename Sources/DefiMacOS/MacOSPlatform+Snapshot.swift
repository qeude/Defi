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

extension SnapshotEngine {

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
    let observations = consumeObservations()
    let explicitlyDestroyedWindowIDs = observations.destroyedWindowIDs
    let tracesWindowTopology = observations.topologyPending
    let capturedTopologyRequiresFullSnapshot =
      observations.topologyRequiresFullSnapshot
    let topologyProcessIDs = observations.topologyProcessIDs
    let frameRequiresFullSnapshot = observations.frameRequiresFullSnapshot
    let frameProcessIDs = observations.frameProcessIDs
    let frameWindowIDs = observations.frameWindowIDs
    let retainedProcessIDs = retainedWindowRefreshProcessIDs(
      retainedWindowIDs: retainedWindowIDs,
      processIDs: processIDs
    )
    let topologyInputTimestamp = observations.topologyInputTimestamp
    let eventRequiresFullSnapshot =
      capturedTopologyRequiresFullSnapshot || frameRequiresFullSnapshot
    let platformInputs = onMain { platform in
      (
        frameCoverage: platform.eventMonitor?.processIDsWithoutReliableFrameCoverage ?? [],
        topologyCoverage: platform.processIDsWithoutReliableTopologyCoverage(),
        incompatible: platform.incompatibleObservationProcessIDs,
        monitors: platform.discoverMonitors()
      )
    }
    let uncoveredProcessIDs = platformInputs.frameCoverage.union(platformInputs.topologyCoverage)
    // Exhausted observer subscriptions use the watchdog instead of taxing every pass.
    let incompatiblePIDs = platformInputs.incompatible
    let fallbackNow = ProcessInfo.processInfo.systemUptime
    incompatibleFreshReadDeadlines =
      incompatibleFreshReadDeadlines
      .filter { $0.value > fallbackNow }
    var fallbackFreshReadProcessIDs = Set<pid_t>()
    for processID in uncoveredProcessIDs {
      if incompatiblePIDs.contains(processID) {
        if forceFullWindowRefresh
          || topologyProcessIDs.contains(processID)
          || frameProcessIDs.contains(processID)
          || incompatibleFreshReadDeadlines[processID] == nil
        {
          incompatibleFreshReadDeadlines[processID] =
            fallbackNow + reliableObservationWatchdogInterval
          fallbackFreshReadProcessIDs.insert(processID)
        }
      } else {
        fallbackFreshReadProcessIDs.insert(processID)
      }
    }
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
    let incrementalProcessIDs =
      forceFullWindowRefresh
      ? nil
      : incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: hasCompletedWindowSnapshot,
        eventPending: tracesWindowTopology,
        requiresFullSnapshot: capturedTopologyRequiresFullSnapshot,
        processIDs: observations.topologyProcessIDs,
        coalescedProcessIDs:
          frameProcessIDs
          .union(fallbackFreshReadProcessIDs)
          .union(deferredFreshReadProcessIDs)
          .union(retainedProcessIDs),
        coalescedEventRequiresFullSnapshot: frameRequiresFullSnapshot,
        allowsCoalescedProcessRefresh:
          observations.framePending || mouseResizeGesturePending
          || !fallbackFreshReadProcessIDs.isEmpty
          || !deferredFreshReadProcessIDs.isEmpty
          || !retainedProcessIDs.isEmpty,
        allowsCachedRefresh: true
      )
    var effectiveIncrementalProcessIDs = incrementalProcessIDs
    let chunkedFullActive =
      !applications.isEmpty
      && (forceFullWindowRefresh
        || chunkedFullRefreshRemainingProcessIDs?.isEmpty == false)
    if chunkedFullActive {
      // Full refreshes are the most expensive passes (every app re-read), so
      // they are spread over consecutive budgeted passes: served apps get
      // fresh window lists, deferred apps ride their cached windows until
      // their pass comes. Cacheless apps are always served immediately so a
      // fresh launch can never pop in late.
      let liveProcessIDs = Set(applications.keys)
      if chunkedFullRefreshRemainingProcessIDs == nil {
        chunkedFullRefreshRemainingProcessIDs = liveProcessIDs
      }
      chunkedFullRefreshRemainingProcessIDs?.formIntersection(liveProcessIDs)
      let remaining = chunkedFullRefreshRemainingProcessIDs ?? []
      let cachelessProcessIDs = remaining.subtracting(
        Set(lastApplicationWindowElements.keys)
      )
      let partition = budgetedFreshReadPartition(
        requestedProcessIDs: remaining,
        deferredProcessIDs: [],
        eventPendingProcessIDs: topologyProcessIDs.union(frameProcessIDs)
          .union(cachelessProcessIDs),
        predictedLatencyMS: { processID in
          frameCoordinator.predictedProcessLatency(processID: processID)
        },
        budgetMS: snapshotFreshReadBudgetMS,
        maximumDeferredAgeSeconds: 0.5,
        deferredSince: nil,
        now: ProcessInfo.processInfo.systemUptime
      )
      effectiveIncrementalProcessIDs = partition.allowedNow
      chunkedFullRefreshRemainingProcessIDs =
        partition.stillDeferred.isEmpty ? nil : partition.stillDeferred
      frameCoordinator.recordTrace(
        "fresh-read-budget kind=full allowed=\(partition.allowedNow.count) deferred=\(partition.stillDeferred.count)"
      )
    } else if let requested = incrementalProcessIDs {
      deferredFreshReadProcessIDs.formIntersection(
        Set(applications.keys)
      )
      let partition = budgetedFreshReadPartition(
        requestedProcessIDs: requested,
        deferredProcessIDs: deferredFreshReadProcessIDs,
        eventPendingProcessIDs: topologyProcessIDs.union(frameProcessIDs),
        predictedLatencyMS: { processID in
          frameCoordinator.predictedProcessLatency(processID: processID)
        },
        budgetMS: snapshotFreshReadBudgetMS,
        maximumDeferredAgeSeconds: 0.5,
        deferredSince: deferredFreshReadsStartedAt,
        now: ProcessInfo.processInfo.systemUptime
      )
      deferredFreshReadProcessIDs = partition.stillDeferred
      deferredFreshReadsStartedAt = partition.deferredSince
      effectiveIncrementalProcessIDs = partition.allowedNow
      if !partition.stillDeferred.isEmpty {
        frameCoordinator.recordTrace(
          "fresh-read-budget allowed=\(partition.allowedNow.count) deferred=\(partition.stillDeferred.count)"
        )
      }
    } else {
      deferredFreshReadProcessIDs.removeAll(keepingCapacity: true)
      deferredFreshReadsStartedAt = nil
    }
    let forceWindowListRefreshEffective =
      forceWindowListRefresh || chunkedFullActive
    let snapshotMode: String
    if effectiveIncrementalProcessIDs == nil {
      snapshotMode = "full"
      fullWindowSnapshotCount += 1
    } else if effectiveIncrementalProcessIDs?.isEmpty == true {
      snapshotMode = "cached"
      cachedWindowSnapshotCount += 1
    } else {
      snapshotMode = "incremental"
      incrementalWindowSnapshotCount += 1
    }
    let monitors = platformInputs.monitors
    lastMonitorFrames = monitors.map(\.frame)
    var hasResolvedCGWindows = false
    var cachedCGWindows: [CGWindowRecord]?
    let refreshesOnlyKnownFrames =
      !frameWindowIDs.isEmpty
      && frameWindowIDs.isSubset(of: Set(elements.keys))
      && effectiveIncrementalProcessIDs?.isSubset(of: frameProcessIDs) == true
      && !forceWindowListRefreshEffective
      && !forceApplicationInventoryRefresh
      && !tracesWindowTopology
      && !eventRequiresFullSnapshot
    func publicCGWindows() -> [CGWindowRecord]? {
      if hasResolvedCGWindows { return cachedCGWindows }
      let reusableCGWindows = lastCGWindowInventory
      if cgWindowInventoryCanBeReused(
        snapshotUsesCachedWindows: effectiveIncrementalProcessIDs?.isEmpty == true,
        snapshotRefreshesOnlyKnownFrames: refreshesOnlyKnownFrames,
        cachedInventoryAvailable: reusableCGWindows != nil
      ) {
        hasResolvedCGWindows = true
        cachedCGWindows = reusableCGWindows
        return cachedCGWindows
      }
      let copied: [CGWindowRecord]?
      let copyDurationMS: Double
      if preparedCGWindowInventoryAvailable {
        copied = preparedCGWindowInventory
        copyDurationMS = preparedCGWindowInventoryDurationMS
      } else {
        let copyStartedAt = ProcessInfo.processInfo.systemUptime
        copied = copyCGWindowsIfAvailable()
        copyDurationMS =
          (ProcessInfo.processInfo.systemUptime - copyStartedAt) * 1_000
      }
      preparedCGWindowInventory = nil
      preparedCGWindowInventoryAvailable = false
      snapshotCGWindowCopyCount += 1
      lastSnapshotCGWindowCopyDurationMS = copyDurationMS
      maximumSnapshotCGWindowCopyDurationMS = max(
        maximumSnapshotCGWindowCopyDurationMS,
        copyDurationMS
      )
      hasResolvedCGWindows = true
      cachedCGWindows = copied
      lastCGWindowInventory = copied
      cgWindowInventoryRetryAttempts =
        updatedWindowListReadRetryAttempts(
          previousAttempts: cgWindowInventoryRetryAttempts,
          readSucceeded: copied != nil
        )
      return copied
    }
    if cgWindowInventoryRetryIsRequired(
      attempts: cgWindowInventoryRetryAttempts,
      forceWindowListRefresh: forceWindowListRefresh
    ) {
      _ = publicCGWindows()
    }
    let preparedAXIsCurrent =
      preparedAXWindowAttributesAvailable
      && preparedAXWindowAttributesGeneration.map {
        preparedAXWindowAttributesAreCurrent(
          capturedGeneration: $0,
          currentGeneration: windowSnapshotObservationGeneration,
          capturedInputTimestamp: preparedAXWindowAttributesInputTimestamp ?? .nan,
          currentInputTimestamp: userInputTracker.latestEventTimestamp,
          capturedWindowIDs: preparedAXWindowAttributesWindowIDs,
          currentWindowIDs: Set(elements.keys),
          capturedProcessIDs: preparedAXWindowAttributesProcessIDs,
          currentProcessIDs: Set(applications.keys)
        )
      } ?? false
    let preparedWindowAttributes =
      preparedAXIsCurrent
      ? preparedAXWindowAttributes
      : [:]
    let preparedTransientOwners =
      preparedAXIsCurrent
      ? preparedTransientOwnerWindowIDs
      : [:]
    let preparedApplicationWindows =
      preparedAXIsCurrent
      ? preparedAXApplicationWindows
      : [:]
    preparedAXWindowAttributes.removeAll(keepingCapacity: true)
    preparedTransientOwnerWindowIDs.removeAll(keepingCapacity: true)
    preparedAXApplicationWindows.removeAll(keepingCapacity: true)
    preparedAXWindowAttributesAvailable = false
    let previousElements = elements
    let discovery = discoverSnapshotWindows(
      monitors: monitors,
      config: config,
      incrementalProcessIDs: effectiveIncrementalProcessIDs,
      forceWindowListRefresh: forceWindowListRefreshEffective,
      forceApplicationInventoryRefresh: forceApplicationInventoryRefresh,
      capturedTopologyRequiresFullSnapshot: capturedTopologyRequiresFullSnapshot,
      topologyProcessIDs: topologyProcessIDs,
      preparedWindowAttributes: preparedWindowAttributes,
      preparedTransientOwnerWindowIDs: preparedTransientOwners,
      preparedApplicationWindows: preparedApplicationWindows,
      explicitlyDestroyedWindowIDs: explicitlyDestroyedWindowIDs,
      publicCGWindows: publicCGWindows
    )
    preparedCGWindowInventory = nil
    preparedCGWindowInventoryAvailable = false
    var nextElements = discovery.nextElements
    var nextProcessIDs = discovery.nextProcessIDs
    let nextApplications = discovery.nextApplications
    let nextApplicationIDs = discovery.nextApplicationIDs
    let applicationWindows = discovery.applicationWindows
    let minimizedWindows = discovery.minimizedWindows
    let transientGeometryWindows = discovery.transientGeometryWindows
    let windows = discovery.windows
    let fullscreenCGWindows = publicCGWindows() ?? []
    let detectedNativeFullscreenProcessIDs = nativeFullscreenProcessIDs(
      cgWindows: fullscreenCGWindows,
      monitors: monitors
    )
    var detectedNativeFullscreenWindowIDs = nativeFullscreenWindowIDs(
      windows: windows,
      cgWindows: fullscreenCGWindows,
      monitors: monitors,
      lastFocusedWindowByProcess: lastFocusedWindowByProcess
    )
    nativeFullscreenProcessIDsByWindowID =
      retainedNativeFullscreenProcessIDsByWindowID(
        detectedWindowIDs: detectedNativeFullscreenWindowIDs,
        previous: nativeFullscreenProcessIDsByWindowID,
        observedProcessIDs: processIDs.merging(nextProcessIDs) { _, next in next },
        fullscreenProcessIDs: detectedNativeFullscreenProcessIDs,
        explicitlyRemovedWindowIDs: explicitlyDestroyedWindowIDs
      )
    detectedNativeFullscreenWindowIDs.formUnion(
      nativeFullscreenProcessIDsByWindowID.keys
    )
    let stabilizedNativeFullscreen = stabilizedNativeFullscreenWindowIDs(
      detectedWindowIDs: detectedNativeFullscreenWindowIDs,
      previousExitDeadlines: nativeFullscreenExitDeadlines,
      explicitlyRemovedWindowIDs: explicitlyDestroyedWindowIDs,
      now: snapshotStartedAt
    )
    nativeFullscreenExitDeadlines = stabilizedNativeFullscreen.exitDeadlines
    let nativeFullscreenWindowIDs = stabilizedNativeFullscreen.windowIDs
    let maskedWindowIDs = fullscreenMaskedWindowIDs(
      previousWindowIDs: Set(previousElements.keys),
      nativeFullscreenWindowIDs: nativeFullscreenWindowIDs,
      explicitlyRemovedWindowIDs: explicitlyDestroyedWindowIDs
    )
    nextElements.merge(previousElements.filter { maskedWindowIDs.contains($0.key) }) {
      current, _ in current
    }
    nextProcessIDs.merge(processIDs.filter { maskedWindowIDs.contains($0.key) }) {
      current, _ in current
    }
    let activeNativeFullscreenWindowIDs = activeNativeFullscreenWindowIDs(
      processIDsByWindowID: nativeFullscreenProcessIDsByWindowID,
      cgWindows: fullscreenCGWindows,
      monitors: monitors
    ).intersection(nativeFullscreenWindowIDs)
    let nextRetainedWindowIDs = discovery.nextRetainedWindowIDs
    let cachedSnapshotWindowIDs = discovery.cachedSnapshotWindowIDs
    let previouslyManagedApplicationWindows =
      discovery.previouslyManagedApplicationWindows
    let nextWindowIDs = Set(nextElements.keys)
    let freshObservationIDs = freshWindowObservationIDs(
      windows: windows,
      retainedWindowIDs: nextRetainedWindowIDs,
      cachedWindowIDs: cachedSnapshotWindowIDs
    )
    let windowIDReplacements = discovery.windowIDReplacements
    let removedWindowIDs = Set(previousElements.keys)
      .subtracting(nextWindowIDs)
      .subtracting(windowIDReplacements.keys)
    if windowIDReplacements.isEmpty == false {
      let replacements = windowIDReplacements.sorted {
        $0.key.rawValue < $1.key.rawValue
      }.map {
        "\($0.key.rawValue)->\($0.value.rawValue)"
      }.joined(separator: ",")
      frameCoordinator.recordTrace("window-identity-replaced [\(replacements)]")
    }
    newlyDiscoveredWindowIDs =
      hasCompletedWindowSnapshot
      ? nextWindowIDs.subtracting(previousElements.keys)
      : []
    if tracesWindowTopology
      || !newlyDiscoveredWindowIDs.isEmpty
      || !removedWindowIDs.isEmpty
    {
      onMain { $0.invalidatePointerHitTestCache() }
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
    onMain { $0.borderBoundsProvider.retainConstraints(for: nextWindowIDs) }
    lastSnapshotProcessIDs = Set(windows.lazy.compactMap(\.processID))
    lastApplicationWindowElements = applicationWindows
    minimizedWindowElementsByProcess =
      minimizedWindows.filter { nextApplications[$0.key] != nil }
    transientGeometryWindowElementsByProcess =
      transientGeometryWindows.filter { nextApplications[$0.key] != nil }
    retainedWindowIDs = nextRetainedWindowIDs
    let deferredFrameEventWindowIDs = retainedFrameEventWindowIDs(
      observedFrameEventWindowIDs: frameWindowIDs,
      retainedWindowIDs: nextRetainedWindowIDs
    )
    if !deferredFrameEventWindowIDs.isEmpty {
      recordFrameRefresh(
        windowIDs: deferredFrameEventWindowIDs,
        processIDs: Set(deferredFrameEventWindowIDs.compactMap { nextProcessIDs[$0] }),
        requiresFullSnapshot: false,
        invalidatesPreparedObservations: false
      )
    }
    retainedWindowDeadlines = retainedWindowDeadlines.filter {
      nextRetainedWindowIDs.contains($0.key)
    }
    enhancedUIByProcess = enhancedUIByProcess.filter { nextApplications[$0.key] != nil }
    multipleAttributeReadsSupportedByProcess =
      multipleAttributeReadsSupportedByProcess.filter {
        nextApplications[$0.key] != nil
      }
    let liveWindowElements = Set(
      applicationWindows.flatMap { processID, elements in
        elements.map { AXWindowElementIdentity(processID: processID, element: $0) }
      })
    failedBatchedWindowAttributeReadsByElement =
      failedBatchedWindowAttributeReadsByElement.filter {
        liveWindowElements.contains($0.key)
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
    windowListReadRetryAttemptsByProcess =
      windowListReadRetryAttemptsByProcess.filter {
        nextApplications[$0.key] != nil
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
      previouslyManagedWindows: previouslyManagedApplicationWindows,
      minimizedWindows: minimizedWindows
    )
    let observationInputs = AssumedThreadSafe(
      (
        apps: observedApplicationWindows,
        topo: topologyWindowsRequiredForObservation,
        frames: requiredFrameWindows,
        transient: transientGeometryWindows
      ))
    onMain {
      $0.eventMonitor?.refresh(
        applications: observationInputs.value.apps,
        requiredTopologyWindows: observationInputs.value.topo,
        requiredFrameWindows: observationInputs.value.frames,
        transientGeometryWindows: observationInputs.value.transient
      )
    }
    frameCoordinator.pruneRecentInternalFrameWrites(
      liveWindowIDs: Set(nextElements.keys),
      now: ProcessInfo.processInfo.systemUptime
    )
    frameCoordinator.pruneProcessLatencyState(
      liveProcessIDs: Set(nextApplications.keys)
    )
    targetFrames = targetFrames.filter { nextElements[$0.key] != nil }
    pendingFrameCorrections = pendingFrameCorrections.filter { nextElements[$0.key] != nil }
    latestObservedFrames = latestObservedFrames.filter {
      freshObservationIDs.contains($0.key)
        || cachedSnapshotWindowIDs.contains($0.key)
    }
    let now = ProcessInfo.processInfo.systemUptime
    // Expired expectations are dead bookkeeping. The per-window expiry below
    // only runs on fresh observations; applications that stop delivering
    // them would otherwise keep an expectation alive forever.
    frameCommitExpectations = frameCommitExpectations.filter {
      nextElements[$0.key] != nil && $0.value.deadline > now
    }
    initialFrameSettlementDeadlines = initialFrameSettlementDeadlines.filter {
      $0.value > now
    }
    lastHiddenWindowIDs = lastHiddenWindowIDs.filter { nextElements[$0] != nil }
    let leftMouseButtonDown = CGEventSource.buttonState(
      .combinedSessionState,
      button: .left
    )
    let mouseResizeGestureObserved = mouseResizeGesturePending
    let mouseFocusReleaseObserved = mouseFocusReleasePending
    let userInput = userInputTracker.snapshot
    let nativeFocusObservedAfterMouseRelease = nativeFocusFollowsRecentMouseRelease(
      eventGeneration: nativeFocusEventGeneration,
      releaseGeneration: mouseFocusReleaseEventGeneration,
      input: userInput,
      now: now
    )
    let mouseGestureWindowID =
      mouseResizeGestureObserved
      ? mouseGestureRefreshProcessID(
        latestFocusIntent: userInput.latestFocusIntent,
        focusedWindowID: lastNativeFocusedWindowID,
        processIDs: processIDs
      ).flatMap { processID in
        if let focusIntent = userInput.latestFocusIntent,
          case .mouse(let windowID) = focusIntent.source,
          let windowID,
          processIDs[windowID] == processID
        {
          return windowID
        }
        return lastNativeFocusedWindowID.flatMap {
          processIDs[$0] == processID ? $0 : nil
        }
      }
      : nil
    let externalResizeGestureActive =
      leftMouseButtonDown || mouseResizeGestureObserved
    var externallyChangedFrames: [WindowID: Rect] = [:]
    var targetMismatches: [FrameMismatch] = []
    var deferredMismatchCount = 0
    var settledCommitLatenciesMS: [Double] = []
    var commandObservations: [(CommandPerformanceContext, WindowID, Rect, Rect, Rect)] = []
    for window in windows
    where freshObservationIDs.contains(window.id)
      && !nativeFullscreenWindowIDs.contains(window.id)
    {
      latestObservedFrames[window.id] = window.frame
      if var expectation = frameCommitExpectations[window.id],
        let target = targetFrames[window.id]
      {
        if let command = expectation.command {
          commandObservations.append((
            command, window.id, expectation.from, window.frame, expectation.target
          ))
        }
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
      if windowHasExternalFrameChange(
        window.id,
        pendingFrameWindowIDs: frameWindowIDs,
        matchesRecentInternalWrite: frameWindowIDs.contains(window.id)
          && frameCoordinator.frameMatchesRecentInternalWrite(
            windowID: window.id,
            actual: window.frame,
            now: now
          )
      )
        || windowIsMouseResizeGestureCandidate(
          window.id,
          mouseGestureWindowID: mouseGestureWindowID,
          mouseResizeGestureObserved: mouseResizeGestureObserved
        )
      {
        externallyChangedFrames[window.id] = window.frame
      }
    }
    if !commandObservations.isEmpty {
      onMain { platform in
        for (command, windowID, from, actual, target) in commandObservations {
          platform.recordCommandObservation(
            command, windowID: windowID, from: from,
            actual: actual, target: target, at: now
          )
        }
      }
    }
    pendingFrameDebtWindowIDs = prunedFrameDebtWindowIDs(
      debtWindowIDs: pendingFrameDebtWindowIDs,
      liveWindowIDs: Set(nextElements.keys),
      targetFrames: targetFrames,
      observedFrames: latestObservedFrames
    )
    mouseResizeGesturePending = false
    mouseFocusReleasePending = false
    pendingFrameCorrections = frameCorrectionsPreservingDebt(
      existing: pendingFrameCorrections,
      observed: Dictionary(
        uniqueKeysWithValues: targetMismatches.map { ($0.windowID, $0.actual) }
      ),
      debtWindowIDs: pendingFrameDebtWindowIDs
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
    let frontmostProcessID = onMain {
      _ in NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    let activation = userInputTracker.pendingApplicationActivation(
      frontmostProcessID: frontmostProcessID
    )
    let focusedWindowID = focusedWindowID(
      in: windows,
      frontmostProcessID: frontmostProcessID,
      requiresConfirmedWindow: activation != nil
    )
    lastNativeFocusedWindowID = focusedWindowID
    verifiedNativeFocusedWindowID = focusedWindowID
    if let focusedWindowID,
      let processID = nextProcessIDs[focusedWindowID],
      !detectedNativeFullscreenProcessIDs.contains(processID)
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
    let currentActivation = userInputTracker.pendingApplicationActivation(
      frontmostProcessID: onMain { _ in
        NSWorkspace.shared.frontmostApplication?.processIdentifier
      }
    )
    var nativeFocusIsApplicationActivation = activation != nil
      && activation == currentActivation
      && focusedProcessID == activation?.processID
    let nativeFocusTargetMatched = nativeFocusEventMatchesTarget(
      eventPending: nativeFocusEventPending,
      eventProcessIDs: nativeFocusEventProcessIDs,
      hasUnknownEventProcess: nativeFocusEventHasUnknownProcess,
      focusedProcessID: focusedProcessID
    )
    var nativeFocusChanged = nativeFocusTargetMatched || nativeFocusIsApplicationActivation
    if nativeFocusChanged,
      let focusedWindowID,
      let suppression = internalFocusSuppressions[focusedWindowID]
    {
      if internalFocusSuppressionConsumesEvent(
        suppression,
        suppressedWindowID: focusedWindowID,
        latestFocusIntent: userInput.latestFocusIntent,
        applicationActivation: nativeFocusIsApplicationActivation
      ) {
        nativeFocusChanged = false
        nativeFocusIsApplicationActivation = false
        // Retire our own activation echo now; it must not reappear after suppression expires.
        if let activation {
          frameCoordinator.recordTrace("native-activation-retired reason=internal-focus-echo target=\(focusedWindowID.rawValue)")
          userInputTracker.consumeApplicationActivation(
            processID: activation.processID, at: activation.timestamp
          )
        }
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
      nativeFullscreenWindowIDs: nativeFullscreenWindowIDs,
      activeNativeFullscreenWindowIDs: activeNativeFullscreenWindowIDs,
      focusedWindowID: focusedWindowID,
      nativeFocusChanged: nativeFocusChanged,
      nativeFocusIsApplicationActivation: nativeFocusIsApplicationActivation,
      applicationActivationTimestamp: nativeFocusIsApplicationActivation ? activation?.timestamp : nil,
      removedWindowIDs: removedWindowIDs,
      windowIDReplacements: windowIDReplacements,
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
      nativeFocusObservedAfterMouseRelease:
        nativeFocusObservedAfterMouseRelease,
      mouseFocusIntentWindowID: mouseFocusIntentWindowID,
      mouseFocusIntentTimestamp: mouseFocusIntentTimestamp,
      keyboardFocusIntentTimestamp: keyboardFocusIntentTimestamp,
      targetMismatches: targetMismatches,
      frontmostProcessID: frontmostProcessID
    )
  }

}
