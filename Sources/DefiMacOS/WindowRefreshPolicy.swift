import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

let reliableObservationWatchdogInterval: TimeInterval = 30

func applicationInventoryRefreshInterval(
  reliableLifecycleObservation: Bool
) -> TimeInterval {
  reliableLifecycleObservation ? reliableObservationWatchdogInterval : 0.3
}

public func desktopSnapshotRefreshInterval(
  reliableDesktopObservation: Bool
) -> TimeInterval {
  reliableDesktopObservation ? reliableObservationWatchdogInterval : 0.3
}

public func boundedSnapshotRefreshDeadline(
  current: TimeInterval,
  now: TimeInterval,
  interval: TimeInterval,
  reset: Bool
) -> TimeInterval {
  let candidate = now + interval
  return reset ? candidate : min(current, candidate)
}

func windowListRefreshInterval(
  hasPendingShortRetry: Bool,
  reliableTopologyObservation: Bool
) -> TimeInterval {
  if hasPendingShortRetry { return 0.1 }
  return reliableTopologyObservation ? reliableObservationWatchdogInterval : 0.3
}

public func observationWatchdogRefreshIsReady(
  due: Bool,
  interval: TimeInterval,
  userInputIdleDuration: TimeInterval
) -> Bool {
  due && (interval < 1 || userInputIdleDuration >= 1)
}

func unmatchedWindowRetryIsPending(
  attempts: Int,
  maximumAttempts: Int = 3
) -> Bool {
  attempts < maximumAttempts
}

func updatedWindowListReadRetryAttempts(
  previousAttempts: Int?,
  readSucceeded: Bool,
  maximumAttempts: Int = 3
) -> Int? {
  guard !readSucceeded else { return nil }
  guard let previousAttempts else { return 0 }
  guard previousAttempts < maximumAttempts else { return maximumAttempts }
  return previousAttempts + 1
}

func cgWindowInventoryRetryIsRequired(
  attempts: Int?,
  forceWindowListRefresh: Bool
) -> Bool {
  guard forceWindowListRefresh, let attempts else { return false }
  return unmatchedWindowRetryIsPending(attempts: attempts)
}

func cgWindowInventoryCanBeReused(
  snapshotUsesCachedWindows: Bool,
  snapshotRefreshesOnlyKnownFrames: Bool,
  cachedInventoryAvailable: Bool
) -> Bool {
  cachedInventoryAvailable
    && (snapshotUsesCachedWindows || snapshotRefreshesOnlyKnownFrames)
}

func applicationWindowsAfterPreparingTopologyObservation(
  prepareObservation: () -> Void,
  copyWindows: () -> [AXUIElement]?
) -> [AXUIElement]? {
  prepareObservation()
  return copyWindows()
}

func cacheWindowElementForShortRetry(
  _ element: AXUIElement,
  processID: pid_t,
  elementsByProcess: inout [pid_t: [AXUIElement]],
  attemptsByProcess: inout [pid_t: Int]
) {
  if elementsByProcess[processID]?.contains(where: {
    CFEqual($0, element)
  }) != true {
    elementsByProcess[processID, default: []].append(element)
  }
  if attemptsByProcess[processID] == nil {
    attemptsByProcess[processID] = 0
  }
}

/// Per-pass budget for fresh AX window-list reads, in milliseconds. Passes
/// stay short enough that pending commands interleave between them on the
/// main run loop instead of queueing behind one monolithic snapshot.
public let snapshotFreshReadBudgetMS = 12.0

/// Splits the processes needing fresh reads into those served this pass and
/// those deferred to a later pass, cheapest-first by predicted latency.
///
/// - Processes with pending topology/frame events always go now: freshness
///   wins over budget.
/// - At least one candidate is always served so deferred work makes progress
///   even when a single expensive process exceeds the whole budget.
/// - If deferred processes age past `maximumDeferredAgeSeconds`, everything
///   is served at once and the deferral timestamp clears.
func budgetedFreshReadPartition(
  requestedProcessIDs: Set<pid_t>,
  deferredProcessIDs: Set<pid_t>,
  eventPendingProcessIDs: Set<pid_t>,
  predictedLatencyMS: (pid_t) -> Double,
  budgetMS: Double,
  maximumDeferredAgeSeconds: TimeInterval,
  deferredSince: TimeInterval?,
  now: TimeInterval
) -> (
  allowedNow: Set<pid_t>,
  stillDeferred: Set<pid_t>,
  deferredSince: TimeInterval?
) {
  let pending = requestedProcessIDs.union(deferredProcessIDs)
  guard !pending.isEmpty else { return ([], [], nil) }
  if let deferredSince,
    now - deferredSince >= maximumDeferredAgeSeconds
  {
    return (pending, [], nil)
  }
  var allowed = pending.intersection(eventPendingProcessIDs)
  var used = 0.0
  var stillDeferred = Set<pid_t>()
  let candidates = pending.subtracting(eventPendingProcessIDs).sorted {
    (predictedLatencyMS($0), $0)
      < (predictedLatencyMS($1), $1)
  }
  for processID in candidates {
    let cost = predictedLatencyMS(processID)
    if used == 0 || used + cost <= budgetMS {
      allowed.insert(processID)
      used += cost
    } else {
      stillDeferred.insert(processID)
    }
  }
  let nextDeferredSince =
    stillDeferred.isEmpty ? nil : (deferredSince ?? now)
  return (allowed, stillDeferred, nextDeferredSince)
}
