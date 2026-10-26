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
  subsystem: "com.qeude.defi",
  category: "Display"
)

let widthMismatchStabilityDuration: TimeInterval = 0.5

func settledWidthMismatch(_ current: FrameMismatch, previous: FrameMismatch?) -> Bool {
  guard let previous, previous.windowID == current.windowID,
    previous.target == current.target,
    abs(current.actual.width - current.target.width) >= 2,
    abs(previous.actual.width - current.actual.width) <= 1
  else { return false }
  return [previous.actual, current.actual].allSatisfy { frame in
    abs(frame.x - current.target.x) <= 1
      && abs(frame.y - current.target.y) <= 1
  }
}

/// Two reported mismatches of one size for an unchanged target: the app clamps its
/// tiled size itself, possibly after the write readback (Simulator's Device Hub).
/// An acceptance only answers the request it was learned for; a changed target replaces it.
func tiledSizeAcceptanceCoversTarget(_ acceptance: TiledSizeAcceptance?, target: Rect) -> Bool {
  guard let acceptance else { return false }
  return abs(acceptance.requested.width - target.width) < 1
    && abs(acceptance.requested.height - target.height) < 1
}

func settledTiledSizeClamp(_ current: FrameMismatch, previous: FrameMismatch?) -> Bool {
  guard let previous, previous.windowID == current.windowID,
    previous.target == current.target,
    abs(current.actual.width - current.target.width) >= 1
      || abs(current.actual.height - current.target.height) >= 1
  else { return false }
  return abs(previous.actual.width - current.actual.width) <= 1
    && abs(previous.actual.height - current.actual.height) <= 1
}

struct WidthMismatchObservationState {
  var mismatchesByWindowID: [WindowID: FrameMismatch] = [:]
  var observedSince: [WindowID: TimeInterval] = [:]

  mutating func forget(_ windowID: WindowID) {
    mismatchesByWindowID[windowID] = nil
    observedSince[windowID] = nil
  }
}

func updateWidthMismatchObservationState(
  previous: WidthMismatchObservationState,
  current: [FrameMismatch],
  freshObservationIDs: Set<WindowID>,
  removedWindowIDs: Set<WindowID> = [],
  now: TimeInterval
) -> WidthMismatchObservationState {
  var next = previous
  for windowID in freshObservationIDs.union(removedWindowIDs) {
    next.mismatchesByWindowID[windowID] = nil
    next.observedSince[windowID] = nil
  }

  for mismatch in current where freshObservationIDs.contains(mismatch.windowID) {
    let windowID = mismatch.windowID
    let previousMismatch = previous.mismatchesByWindowID[windowID]
    let isSameMismatch = settledWidthMismatch(
      mismatch,
      previous: previousMismatch
    )
    let continuesObservation =
      isSameMismatch && previous.observedSince[windowID] != nil
    next.mismatchesByWindowID[windowID] =
      continuesObservation ? previousMismatch : mismatch
    guard abs(mismatch.actual.width - mismatch.target.width) >= 2,
      abs(mismatch.actual.x - mismatch.target.x) <= 1,
      abs(mismatch.actual.y - mismatch.target.y) <= 1
    else { continue }
    next.observedSince[windowID] = continuesObservation
      ? previous.observedSince[windowID]
      : now
  }
  return next
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

@NavigationActor
extension Daemon {
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
    topologySaveQueue.asyncAfter(
      deadline: .now() + Self.topologySaveDebounce,
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

  static let topologySaveDebounce: TimeInterval = 0.5

  func flushPendingTopologyWrite() {
    guard topologySaveWorkItem != nil else { return }
    topologySaveWorkItem?.cancel()
    topologySaveWorkItem = nil
    do {
      try topologySaveQueue.sync {
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

  func rebaseActiveScrollOffsetToDisplayedFrames(on requestedMonitorID: MonitorID? = nil) {
    guard
      let monitorID = requestedMonitorID ?? activeMonitorID,
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
        maximumAbsoluteDelta: viewport.width,
        logicalScale: stripViewport(viewport, settings: state.layout).width
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

  func acceptSettledTiledSizeClamps(_ mismatches: [FrameMismatch]) {
    // Commit reads in between see the clamp as deferred, so compare against the last
    // reported mismatch rather than the previous snapshot's.
    for mismatch in mismatches {
      let previous = lastTiledSizeMismatches.updateValue(mismatch, forKey: mismatch.windowID)
      guard !tiledSizeAcceptanceCoversTarget(
        state.windows[mismatch.windowID]?.tiledSizeAcceptance, target: mismatch.target),
        settledTiledSizeClamp(mismatch, previous: previous)
      else { continue }
      state.acceptTiledWindowFrame(
        mismatch.actual, requested: mismatch.target, for: mismatch.windowID, settled: true)
    }
    lastTiledSizeMismatches = lastTiledSizeMismatches.filter { state.windows[$0.key] != nil }
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
        // A few points off is the app snapping (absorbed by a neighbour), not a bound.
        abs(mismatch.actual.width - mismatch.target.width) > tiledWidthRoundingLimit,
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
