import AppKit
import DefiConfig
import DefiCore
import DefiIPC
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation
import OSLog

let displayLogger = Logger(
  subsystem: "com.quentin.defi",
  category: "Display"
)

func flushPlacementStore(
  _ store: PlacementStore,
  preferences: PlacementPreferences,
  on queue: DispatchQueue
) throws {
  try queue.sync {
    try store.save(preferences)
  }
}

@MainActor
extension Daemon {
  func invalidatePlacementPreference(for window: Window) {
    placementPreferences.invalidatePreference(for: window)
    placementPreferencesDirty = true
  }

  func persistPlacements() {
    persistTopology()
    var updated = placementPreferences
    updated.recordPlacements(from: state)
    guard placementPreferencesDirty || updated != placementPreferences else { return }
    placementPreferences = updated
    placementPreferencesDirty = false
    schedulePlacementStoreWrite(updated)
  }

  func persistTopology() {
    let topology = state.topology
    guard topology != lastPersistedTopology else { return }
    lastPersistedTopology = topology
    topologySaveWorkItem?.cancel()
    let sessionID = topologySessionID
    let operation: @Sendable () -> Void = { [weak self] in
      self?.writeTopologyStore(topology, sessionID: sessionID)
    }
    let item = DispatchWorkItem(block: operation)
    topologySaveWorkItem = item
    placementSaveQueue.asyncAfter(
      deadline: .now() + Self.placementSaveDebounce,
      execute: item
    )
  }

  nonisolated private func writeTopologyStore(
    _ topology: WorkspaceTopology,
    sessionID: String
  ) {
    do {
      try topologyStore.save(topology, sessionID: sessionID)
    } catch {
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          self?.lastPersistedTopology = nil
          self?.log("workspace topology persistence failed: \(error)")
        }
      }
    }
  }

  static let placementSaveDebounce: TimeInterval = 0.5

  func schedulePlacementStoreWrite(_ preferences: PlacementPreferences) {
    placementSaveWorkItem?.cancel()
    let operation: @Sendable () -> Void = { [weak self] in
      self?.writePlacementStore(preferences)
    }
    let item = DispatchWorkItem(block: operation)
    placementSaveWorkItem = item
    placementSaveQueue.asyncAfter(
      deadline: .now() + Self.placementSaveDebounce,
      execute: item
    )
  }

  nonisolated private func writePlacementStore(_ preferences: PlacementPreferences) {
    do {
      try placementStore.save(preferences)
    } catch {
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.placementPreferencesDirty = true
          self.log("placement persistence failed: \(error)")
        }
      }
    }
  }

  func flushPendingPlacementWrite() {
    guard placementSaveWorkItem != nil else { return }
    placementSaveWorkItem?.cancel()
    placementSaveWorkItem = nil
    do {
      try flushPlacementStore(
        placementStore,
        preferences: placementPreferences,
        on: placementSaveQueue
      )
    } catch {
      log("placement persistence failed: \(error)")
    }
  }

  func flushPendingTopologyWrite() {
    guard topologySaveWorkItem != nil else { return }
    topologySaveWorkItem?.cancel()
    topologySaveWorkItem = nil
    do {
      try placementSaveQueue.sync {
        try topologyStore.save(state.topology, sessionID: topologySessionID)
      }
    } catch {
      log("workspace topology persistence failed: \(error)")
    }
  }

  func consumeDeferredMouseFocusIntent() {
    if let timestamp = deferredMouseFocusIntent?.timestamp {
      consumedMouseFocusIntentTimestamp = max(
        consumedMouseFocusIntentTimestamp,
        timestamp
      )
    }
    deferredMouseFocusIntent = nil
  }

  func displayGeometryDescription(
    _ monitors: [MonitorSnapshot]
  ) -> String {
    monitors.map {
      "\($0.id.rawValue):\(Int($0.frame.width))x\(Int($0.frame.height))"
    }.joined(separator: ",")
  }

  func scheduleDisplayReconciliation() {
    overviewController?.close()
    displayConfigurationEventCount += 1
    let now = ProcessInfo.processInfo.systemUptime
    pendingDisplaySyncDeadlines = [0.05, 0.2, 0.5, 1.0, 2.0].map {
      now + $0
    }
    needsDesktopSync = true
    setTimerFrequency(60)
    scheduleTick()
  }

  var viewportsByMonitor: [MonitorID: Rect] {
    Dictionary(
      uniqueKeysWithValues: latestMonitors.map { monitor in
        (
          monitor.id,
          viewportByApplyingReservedEdges(
            monitor.frame,
            edges: effectiveReservedEdges(for: monitor.id)
          )
        )
      }
    )
  }

  func rebaseActiveScrollOffsetToDisplayedFrames() {
    guard
      let monitorID = activeMonitorID,
      let monitorIndex = state.monitors.firstIndex(where: { $0.id == monitorID }),
      let viewport = viewportsByMonitor[monitorID],
      let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
        where: { $0.id == state.monitors[monitorIndex].activeWorkspace }
      )
    else {
      return
    }
    let workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
    let windows = workspace.columns
      .flatMap(\.windows)
      .compactMap { state.windows[$0] }
    let assignments = computeLayout(
      workspace: workspace,
      viewport: viewport,
      windows: windows,
      settings: state.layout,
      excludingWindowIDs: state.nativeFullscreenWindowIDs
    ).frames.map(preserveIntrinsicSize)
    let deltas = assignments.compactMap { assignment -> Double? in
      guard horizontalIntersection(assignment.frame, viewport) > 0.5,
        let completed = platform.completedPosition(for: assignment.windowID)
      else {
        return nil
      }
      return assignment.frame.x - Double(completed.x)
    }
    guard
      let rebase = rebaseScalarToDisplayedFrames(
        logicalValue: workspace.scrollOffset,
        expectedMinusDisplayedDeltas: deltas,
        maximumAbsoluteDelta: viewport.width
      )
    else {
      return
    }
    state.monitors[monitorIndex].workspaces[workspaceIndex].scrollOffset =
      rebase.value
    let key = ScrollAnimationKey(
      monitorID: monitorID,
      workspaceID: workspace.id
    )
    if var animation = scrollAnimations[key] {
      animation.lastStepAt = ProcessInfo.processInfo.systemUptime
      scrollAnimations[key] = animation
    }
    displayedFrameRebaseCount += 1
    lastDisplayedFrameRebaseDelta = rebase.delta
  }

  func learnPersistentWidthConstraints(_ mismatches: [FrameMismatch]) {
    let mismatchedIDs = Set(mismatches.map(\.windowID))
    persistentWidthDriftCounts = persistentWidthDriftCounts.filter {
      mismatchedIDs.contains($0.key)
    }
    for mismatch in mismatches {
      guard abs(mismatch.actual.width - mismatch.target.width) >= 2,
        state.windows[mismatch.windowID]?.intrinsicSize != true,
        !state.pendingNativeFullscreenWidthResetWindowIDs.contains(mismatch.windowID),
        !platform.isInitialFrameSettlementActive(for: mismatch.windowID)
      else {
        continue
      }
      let count = persistentWidthDriftCounts[mismatch.windowID, default: 0] + 1
      persistentWidthDriftCounts[mismatch.windowID] = count
      if count >= 3,
        learnTiledWindowMinimumWidth(
          mismatch.windowID,
          actualFrame: mismatch.actual,
          state: &state,
          viewports: viewportsByMonitor
        )
      {
        persistentWidthDriftCounts[mismatch.windowID] = 0
      }
    }
  }

}
