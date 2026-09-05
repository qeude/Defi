import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

func applicationInventoryRefreshIsRequired(
  hasCompletedSnapshot: Bool,
  topologyRequiresFullSnapshot: Bool,
  forced: Bool
) -> Bool {
  !hasCompletedSnapshot || topologyRequiresFullSnapshot || forced
}

func durationPercentile(
  _ percentile: Double,
  sortedSamples sorted: [Double]
) -> Double {
  guard !sorted.isEmpty else { return 0 }
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

func retainedWindowRefreshProcessIDs(
  retainedWindowIDs: Set<WindowID>,
  processIDs: [WindowID: pid_t]
) -> Set<pid_t> {
  Set(retainedWindowIDs.compactMap { processIDs[$0] })
}

func windowHasExternalFrameChange(
  _ windowID: WindowID,
  pendingFrameWindowIDs: Set<WindowID>,
  matchesRecentInternalWrite: Bool = false
) -> Bool {
  pendingFrameWindowIDs.contains(windowID) && !matchesRecentInternalWrite
}

func windowIsMouseResizeGestureCandidate(
  _ windowID: WindowID,
  mouseGestureWindowID: WindowID?,
  mouseResizeGestureObserved: Bool
) -> Bool {
  mouseResizeGestureObserved
    && mouseGestureWindowID == windowID
}

func retainedFrameEventWindowIDs(
  observedFrameEventWindowIDs: Set<WindowID>,
  retainedWindowIDs: Set<WindowID>
) -> Set<WindowID> {
  observedFrameEventWindowIDs.intersection(retainedWindowIDs)
}
