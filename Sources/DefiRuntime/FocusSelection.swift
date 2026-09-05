import DefiModel
import Foundation

@discardableResult
public func focusWindow(
  _ windowID: WindowID,
  state: inout RuntimeState
) -> Bool {
  for monitorIndex in state.monitors.indices {
    for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
      if let floatingIndex = state.monitors[monitorIndex]
        .workspaces[workspaceIndex]
        .floatingWindows
        .firstIndex(of: windowID)
      {
        let activatedWorkspace =
          state.monitors[monitorIndex].activeWorkspace
          != state.monitors[monitorIndex].workspaces[workspaceIndex].id
        state.monitors[monitorIndex].workspaces[workspaceIndex].focusedFloatingWindow =
          floatingIndex
        state.monitors[monitorIndex].workspaces[workspaceIndex].focusedLayer = .floating
        state.monitors[monitorIndex].activeWorkspace =
          state.monitors[monitorIndex].workspaces[workspaceIndex].id
        state.maintainWorkspaceLifecycle()
        return activatedWorkspace
      }
      for columnIndex in state.monitors[monitorIndex].workspaces[workspaceIndex].columns.indices {
        if let windowIndex = state.monitors[monitorIndex]
          .workspaces[workspaceIndex]
          .columns[columnIndex]
          .windows
          .firstIndex(of: windowID)
        {
          let activatedWorkspace =
            state.monitors[monitorIndex].activeWorkspace
            != state.monitors[monitorIndex].workspaces[workspaceIndex].id
          state.monitors[monitorIndex].workspaces[workspaceIndex].focusedColumn = columnIndex
          state.monitors[monitorIndex].workspaces[workspaceIndex].focusedLayer = .tiled
          state.monitors[monitorIndex].activeWorkspace =
            state.monitors[monitorIndex].workspaces[workspaceIndex].id
          state.monitors[monitorIndex]
            .workspaces[workspaceIndex]
            .columns[columnIndex]
            .focusedWindow = windowIndex
          state.maintainWorkspaceLifecycle()
          return activatedWorkspace
        }
      }
    }
  }
  return false
}

public func nativeFocusChangesSelection(
  _ windowID: WindowID,
  activeMonitorID: MonitorID?,
  state: RuntimeState
) -> Bool {
  guard let focusedMonitorID = state.monitorID(containing: windowID) else {
    return false
  }
  return activeMonitorID != focusedMonitorID
    || state.selectedWindowID(on: focusedMonitorID) != windowID
}

/// Focuses a pointer target when its required horizontal movement is within
/// the configured fraction of the viewport. `nil` permits any movement, while
/// zero permits only targets that require no scrolling.
public func focusWindowFromPointer(
  _ windowID: WindowID,
  activeMonitorID: MonitorID?,
  state: inout RuntimeState,
  viewports: [MonitorID: Rect],
  maximumScrollAmount: Double? = nil,
  acceptsAlreadySelectedWindow: Bool = false
) -> MonitorID? {
  guard let monitorID = pointerFocusMonitor(
    windowID,
    activeMonitorID: activeMonitorID,
    state: state,
    viewports: viewports,
    maximumScrollAmount: maximumScrollAmount,
    acceptsAlreadySelectedWindow: acceptsAlreadySelectedWindow
  ) else {
    return nil
  }
  guard let viewport = viewports[monitorID] else { return nil }
  _ = focusWindow(windowID, state: &state)
  synchronizeScrollOffsets(
    state: &state,
    viewports: [monitorID: viewport]
  )
  return monitorID
}

public func pointerFocusMonitor(
  _ windowID: WindowID,
  activeMonitorID: MonitorID?,
  state: RuntimeState,
  viewports: [MonitorID: Rect],
  maximumScrollAmount: Double? = nil,
  acceptsAlreadySelectedWindow: Bool = false
) -> MonitorID? {
  guard modalAllowsPointerFocus(windowID, state: state) else { return nil }
  let changesSelection = nativeFocusChangesSelection(
    windowID,
    activeMonitorID: activeMonitorID,
    state: state
  )
  guard (changesSelection || acceptsAlreadySelectedWindow),
    let location = state.location(containing: windowID),
    let monitorIndex = state.monitors.firstIndex(where: {
      $0.id == location.monitorID
    }),
    state.monitors[monitorIndex].activeWorkspace == location.workspaceID,
    let viewport = viewports[location.monitorID]
  else {
    return nil
  }

  guard changesSelection else {
    return location.monitorID
  }

  var preview = state
  _ = focusWindow(windowID, state: &preview)
  synchronizeScrollOffsets(
    state: &preview,
    viewports: [location.monitorID: viewport]
  )

  guard let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
    where: { $0.id == location.workspaceID }
  ) else {
    return nil
  }
  let current = state.monitors[monitorIndex]
    .workspaces[workspaceIndex]
    .targetScrollOffset
  let candidate = preview.monitors[monitorIndex]
    .workspaces[workspaceIndex]
    .targetScrollOffset
  // targetScrollOffset is already normalized to viewport widths.
  let scrollAmount = abs(current - candidate)
  if let maximumScrollAmount,
    scrollAmount > maximumScrollAmount + 0.000_001
  {
    return nil
  }

  return location.monitorID
}

public func modalAllowsPointerFocus(
  _ windowID: WindowID,
  state: RuntimeState
) -> Bool {
  guard let target = state.windows[windowID],
    let location = state.location(containing: windowID),
    let workspace = state.monitors.first(where: { $0.id == location.monitorID })?
      .workspaces.first(where: { $0.id == location.workspaceID })
  else { return true }
  let workspaceWindowIDs = workspace.columns.flatMap(\.windows)
    + workspace.floatingWindows
  var ancestry = Set<WindowID>()
  var candidate: WindowID? = windowID
  while let current = candidate, ancestry.insert(current).inserted {
    candidate = state.windows[current]?.transientOwnerID
  }
  let ownerlessModalIDs = Set(state.windows.values.lazy.filter { modal in
    modal.appID == target.appID
      && (target.processID.map { modal.processID == $0 } ?? true)
      && modal.isModal
      && modal.transientOwnerID == nil
  }.map(\.id))
  if ownerlessModalIDs.isEmpty == false {
    return ancestry.isDisjoint(with: ownerlessModalIDs) == false
  }
  let modalIDs = Set(workspaceWindowIDs.filter { candidateID in
    state.windows[candidateID]?.appID == target.appID
      && (target.processID.map {
        state.windows[candidateID]?.processID == $0
      } ?? true)
      && state.windows[candidateID]?.isModal == true
  })
  guard !modalIDs.isEmpty else { return true }
  if ancestry.isDisjoint(with: modalIDs) == false {
    return true
  }
  return modalIDs.allSatisfy { modalID in
    guard let ownerID = state.windows[modalID]?.transientOwnerID else {
      return false
    }
    return ancestry.contains(ownerID) == false
  }
}

public func pointerFocusRecoveryWindowID(
  pointerWindowIsManaged: Bool,
  pointerWindowIsReady: Bool,
  targetAccepted: Bool,
  logicalFocusWindowID: WindowID?
) -> WindowID? {
  guard pointerWindowIsManaged else { return logicalFocusWindowID }
  // A managed target that is not ready still cancels an in-flight pointer
  // request. Keep the logical target available so a mutated native focus can
  // be reconciled while the new target waits for its frame work to settle.
  guard pointerWindowIsReady else { return logicalFocusWindowID }
  return targetAccepted ? nil : logicalFocusWindowID
}

public func pointerFocusRecoveryTargetAfterCancellation(
  cancellationSucceeded: Bool,
  logicalFocusWindowID: WindowID?
) -> WindowID? {
  cancellationSucceeded ? nil : logicalFocusWindowID
}

public func keyboardCursorWarpTimestamp(
  mouseFollowsFocus: Bool,
  capturedInputTimestamp: TimeInterval?
) -> TimeInterval? {
  guard mouseFollowsFocus else { return nil }
  return capturedInputTimestamp
}

public func nativeFocusCursorWarpTimestamp(
  mouseFollowsFocus: Bool,
  nativeFocusAccepted: Bool,
  keyboardFocusIntentCurrent: Bool,
  keyboardFocusIntentTimestamp: TimeInterval?
) -> TimeInterval? {
  guard mouseFollowsFocus,
    nativeFocusAccepted,
    keyboardFocusIntentCurrent,
    let keyboardFocusIntentTimestamp
  else {
    return nil
  }
  return keyboardFocusIntentTimestamp
}

public func commandFocusInputTimestamp(
  capturedInputTimestamp: TimeInterval?,
  commandHandledAt: TimeInterval
) -> TimeInterval {
  capturedInputTimestamp ?? commandHandledAt
}

/// Keeps a focus request requeued after display reconciliation behind the
/// pointer input that displaced it.
public func pointerDisplacedFocusInputTimestamp(
  commandInputTimestamp: TimeInterval,
  pointerInputTimestamp: TimeInterval
) -> TimeInterval {
  max(commandInputTimestamp, pointerInputTimestamp)
}

public func commandFocusCancellationFallback(
  cancelledBeforeMutation: Bool,
  rollbackAfterMutation: Bool = false,
  requestGeneration: UInt64,
  currentGeneration: UInt64,
  requestedWindowID: WindowID,
  selectedWindowID: WindowID?,
  previousSelectedWindowID: WindowID?,
  sourceWorkspaceID: WorkspaceID,
  previousSelectedWindowWorkspaceID: WorkspaceID?
) -> WindowID? {
  guard (cancelledBeforeMutation || rollbackAfterMutation),
    requestGeneration == currentGeneration,
    selectedWindowID == requestedWindowID,
    let previousSelectedWindowID,
    previousSelectedWindowID != requestedWindowID,
    previousSelectedWindowWorkspaceID == sourceWorkspaceID
  else {
    return nil
  }
  return previousSelectedWindowID
}

public func cancelledFocusTargetsRequestedWindow(
  requestedWindowID: WindowID,
  requestedWindowIsNativelyFocused: Bool,
  cancellingFocusTargetWindowID: WindowID?
) -> Bool {
  requestedWindowIsNativelyFocused
    || cancellingFocusTargetWindowID == requestedWindowID
}

public func workspaceFocusCancellationFallback(
  cancelledBeforeMutation: Bool,
  rollbackAfterMutation: Bool = false,
  requestGeneration: UInt64,
  currentGeneration: UInt64,
  requestedWorkspaceID: WorkspaceID,
  activeWorkspaceID: WorkspaceID,
  previousWorkspaceID: WorkspaceID?,
  requestedWindowID: WindowID,
  selectedWindowID: WindowID?,
  restoresPreviousWorkspace: Bool = true
) -> WorkspaceID? {
  guard restoresPreviousWorkspace,
    (cancelledBeforeMutation || rollbackAfterMutation),
    requestGeneration == currentGeneration,
    activeWorkspaceID == requestedWorkspaceID,
    selectedWindowID == requestedWindowID,
    let previousWorkspaceID,
    previousWorkspaceID != requestedWorkspaceID
  else {
    return nil
  }
  return previousWorkspaceID
}

public func pendingWorkspaceFocusIsPreserved(
  pendingMonitorID: MonitorID,
  commandMonitorID: MonitorID?,
  requestedWorkspaceID: WorkspaceID,
  activeWorkspaceID: WorkspaceID?,
  requestedWindowID: WindowID,
  selectedWindowID: WindowID?
) -> Bool {
  commandMonitorID == pendingMonitorID
    && activeWorkspaceID == requestedWorkspaceID
    && selectedWindowID == requestedWindowID
}

public func pointerFocusRetryIsCurrent(
  pendingWindowID: WindowID,
  windowUnderPointerID: WindowID?,
  requestGeneration: UInt64,
  currentGeneration: UInt64,
  pointerTimestamp: TimeInterval,
  latestUserInputTimestamp: TimeInterval
) -> Bool {
  pendingWindowID == windowUnderPointerID
    && requestGeneration == currentGeneration
    && latestUserInputTimestamp <= pointerTimestamp
}

public func pointerFocusIntentIsCurrent(
  pointerTimestamp: TimeInterval,
  latestUserInputTimestamp: TimeInterval
) -> Bool {
  latestUserInputTimestamp <= pointerTimestamp
}

public func pointerFocusRequestIsCurrent(
  requestGeneration: UInt64,
  currentGeneration: UInt64,
  pointerTimestamp: TimeInterval,
  latestUserInputTimestamp: TimeInterval
) -> Bool {
  requestGeneration == currentGeneration
    && pointerFocusIntentIsCurrent(
      pointerTimestamp: pointerTimestamp,
      latestUserInputTimestamp: latestUserInputTimestamp
    )
}

public func pointerFocusGuardTimestamp(
  pointerTimestamp: TimeInterval,
  targetAccepted: Bool
) -> TimeInterval? {
  targetAccepted ? pointerTimestamp : nil
}

public func cancelledPointerFocusShouldRearm(
  pointerTimestamp: TimeInterval,
  latestUserInputTimestamp: TimeInterval
) -> Bool {
  pointerFocusIntentIsCurrent(
    pointerTimestamp: pointerTimestamp,
    latestUserInputTimestamp: latestUserInputTimestamp
  )
}

public func commandFocusIsPreserved(
  pendingWindowID: WindowID?,
  submittedWindowID: WindowID?,
  selectedWindowID: WindowID
) -> Bool {
  (pendingWindowID ?? submittedWindowID) == selectedWindowID
}

public func nextPointerFocusRetryCount(
  currentRetryCount: Int,
  maximumRetryCount: Int,
  intentCurrent: Bool
) -> Int? {
  guard intentCurrent, currentRetryCount < maximumRetryCount else { return nil }
  return currentRetryCount + 1
}

public func nextCommandFocusRetryCount(
  currentRetryCount: Int,
  maximumRetryCount: Int,
  requestGeneration: UInt64,
  currentGeneration: UInt64,
  requestedWindowID: WindowID,
  selectedWindowID: WindowID?
) -> Int? {
  guard requestGeneration == currentGeneration,
    requestedWindowID == selectedWindowID,
    currentRetryCount < maximumRetryCount
  else {
    return nil
  }
  return currentRetryCount + 1
}

/// Pointer focus waits until all geometry writes on target monitor settle.
///
/// Hit-test geometry can become stale while any sibling is moving, and no new
/// pointer event is guaranteed after that sibling moves under the cursor.
public func focusMonitorIsReady(
  targetMonitorID: MonitorID,
  scrollingMonitorIDs: Set<MonitorID>,
  pendingFrameMonitorIDs: Set<MonitorID>
) -> Bool {
  !scrollingMonitorIDs.contains(targetMonitorID)
    && !pendingFrameMonitorIDs.contains(targetMonitorID)
}

/// Keyboard focus can proceed when target window is ready.
///
/// Frame debt from sibling windows must not block focus. A slow or delayed
/// Accessibility response elsewhere on the monitor cannot make keyboard
/// focus unresponsive for the selected window.
public func focusTargetIsReady(
  targetMonitorID: MonitorID,
  targetWindowID: WindowID,
  scrollingMonitorIDs: Set<MonitorID>,
  pendingFrameWindowIDs: Set<WindowID>
) -> Bool {
  !scrollingMonitorIDs.contains(targetMonitorID)
    && !pendingFrameWindowIDs.contains(targetWindowID)
}

public func nativeFocusMutationIsReady(
  nativeFocusChanged: Bool,
  mouseInteractionEnded: Bool,
  leftMouseButtonDown: Bool,
  deferredMouseFocusPending: Bool? = nil,
  deferredMouseFocusReady: Bool? = nil,
  mouseReleaseFocusIntentCurrent: Bool,
  keyboardFocusIntentCurrent: Bool,
  nativeFocusSuppressed: Bool = false,
  applicationActivationTimestamp: Double? = nil,
  latestCommandInputTimestamp: Double = 0
) -> Bool {
  if nativeFocusChanged,
    let applicationActivationTimestamp,
    applicationActivationTimestamp > latestCommandInputTimestamp,
    !leftMouseButtonDown
  {
    return true
  }
  if nativeFocusSuppressed
    && !mouseReleaseFocusIntentCurrent
    && !keyboardFocusIntentCurrent
  {
    return false
  }
  if leftMouseButtonDown {
    return nativeFocusChanged && keyboardFocusIntentCurrent
  }
  if keyboardFocusIntentCurrent && nativeFocusChanged {
    return true
  }
  if deferredMouseFocusPending ?? mouseInteractionEnded {
    return (deferredMouseFocusReady ?? mouseInteractionEnded)
      && mouseReleaseFocusIntentCurrent
  }
  return false
}

public func keyboardFocusPreemptsMouseGesture(
  nativeFocusAccepted: Bool,
  keyboardFocusIntentCurrent: Bool,
  leftMouseButtonDown: Bool,
  postReleaseSettlementActive: Bool
) -> Bool {
  nativeFocusAccepted && keyboardFocusIntentCurrent
    && (leftMouseButtonDown || postReleaseSettlementActive)
}
