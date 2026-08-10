import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

func applicationInventoryRefreshInterval(
  reliableLifecycleObservation: Bool
) -> TimeInterval {
  reliableLifecycleObservation ? 5 : 0.3
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
  return reliableTopologyObservation ? 5 : 0.3
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

