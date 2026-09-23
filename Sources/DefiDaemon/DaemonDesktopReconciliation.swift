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

let widthMismatchStabilityDuration: TimeInterval = 0.5

func settledWidthMismatch(_ current: FrameMismatch, previous: FrameMismatch?) -> Bool {
  guard let previous, previous.windowID == current.windowID,
    previous.target == current.target,
    abs(previous.actual.width - current.actual.width) <= 1
  else { return false }
  return [previous.actual, current.actual].allSatisfy { frame in
    abs(frame.x - current.target.x) <= 1
      && abs(frame.y - current.target.y) <= 1
  }
}

func widthMismatchObservationTimes(
  current: [FrameMismatch],
  previous: [FrameMismatch],
  previousObservationTimes: [WindowID: TimeInterval],
  now: TimeInterval
) -> [WindowID: TimeInterval] {
  let previousByWindowID = Dictionary(
    uniqueKeysWithValues: previous.map { ($0.windowID, $0) }
  )
  var observationTimes: [WindowID: TimeInterval] = [:]
  for mismatch in current
  where abs(mismatch.actual.x - mismatch.target.x) <= 1
    && abs(mismatch.actual.y - mismatch.target.y) <= 1
  {
    let isSameMismatch = settledWidthMismatch(
      mismatch,
      previous: previousByWindowID[mismatch.windowID]
    )
    observationTimes[mismatch.windowID] = isSameMismatch
      ? previousObservationTimes[mismatch.windowID] ?? now
      : now
  }
  return observationTimes
}

func persistentWidthMismatch(
  _ current: FrameMismatch,
  previous: FrameMismatch?,
  observedSince: TimeInterval?,
  now: TimeInterval
) -> Bool {
  guard settledWidthMismatch(current, previous: previous),
    let observedSince
  else { return false }
  return now - observedSince >= widthMismatchStabilityDuration
}

func flushPlacementStore(
  _ store: PlacementStore,
  preferences: PlacementPreferences,
  on queue: DispatchQueue
) throws {
  try queue.sync {
    try store.save(preferences)
  }
}

@NavigationActor
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
      NavigationActor.enqueue { [weak self] in
        NavigationActor.assumeIsolated {
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
      NavigationActor.enqueue { [weak self] in
        NavigationActor.assumeIsolated {
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

  func invalidateDisplayArrangement() {
    displayPointerRouter.invalidate()
    displayReconciliationPending = true
    displayReconciliationGeneration &+= 1
    DispatchQueue.main.async { [self] in displayArrangement.invalidate() }
  }

  func reconcileDisplays() {
    guard !displayReconciliationInFlight else { return }
    displayReconciliationInFlight = true
    let generation = displayReconciliationGeneration
    let session = desktopSessionGeneration
    platform.invalidateFrameStateForDisplayChange()
    DispatchQueue.main.async { [self] in
      let changed = displayArrangement.reconcile()
      let deskFrames = displayArrangement.deskFrames
      let status = displayArrangement.status
      let pending = displayArrangement.needsReconciliation
      NavigationActor.enqueue { [self] in
        displayReconciliationInFlight = false
        guard desktopSessionActive, desktopSessionGeneration == session else { return }
        displayDeskFrames = deskFrames
        displayArrangementStatus = status
        if displayReconciliationGeneration == generation {
          displayReconciliationPending = pending
        }
        if changed {
          scheduleDisplayReconciliation()
        } else {
          needsDesktopSync = true
          scheduleTick()
        }
      }
    }
  }

  func scheduleDisplayReconciliation() {
    invalidateDisplayArrangement()
    closeOverview()
    handleCheatsheetInput(.dismiss)
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
    ).map(preserveIntrinsicSize)
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

  func learnPersistentWidthConstraints(
    _ mismatches: [FrameMismatch],
    previous: [FrameMismatch],
    observedSince: [WindowID: TimeInterval],
    now: TimeInterval
  ) {
    let previousByWindowID = Dictionary(
      uniqueKeysWithValues: previous.map { ($0.windowID, $0) }
    )
    for mismatch in mismatches {
      guard abs(mismatch.actual.width - mismatch.target.width) >= 2,
        persistentWidthMismatch(
          mismatch,
          previous: previousByWindowID[mismatch.windowID],
          observedSince: observedSince[mismatch.windowID],
          now: now
        ),
        state.windows[mismatch.windowID]?.intrinsicSize != true,
        state.windows[mismatch.windowID]?.minimumTiledWidth == nil,
        state.windows[mismatch.windowID]?.maximumTiledWidth == nil,
        !state.pendingNativeFullscreenWidthResetWindowIDs.contains(mismatch.windowID),
        !platform.isInitialFrameSettlementActive(for: mismatch.windowID)
      else {
        continue
      }
      _ = learnTiledWindowWidthConstraint(
        mismatch.windowID,
        actualFrame: mismatch.actual,
        state: &state,
        viewports: viewportsByMonitor
      )
    }
  }
}
