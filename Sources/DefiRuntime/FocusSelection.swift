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
/// zero matches niri's `max-scroll-amount="0%"` behavior.
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

public func commandFocusCompletionIsCurrent(
  submittedWindowID: WindowID?,
  submittedGeneration: UInt64?,
  completedWindowID: WindowID,
  completedGeneration: UInt64
) -> Bool {
  submittedWindowID == completedWindowID
    && submittedGeneration == completedGeneration
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

/// Returns whether focus can proceed for one target window.
///
/// Frame debt from sibling windows must not block focus. A slow or delayed
/// Accessibility response elsewhere on the monitor cannot make keyboard
/// focus unresponsive for the selected window.
public func focusTargetIsReady(
  targetMonitorID: MonitorID,
  targetWindowID: WindowID,
  scrollingMonitorIDs: Set<MonitorID>,
  pendingFrameWindowIDs: Set<WindowID>,
  deferredSlowWindowIDs: Set<WindowID>
) -> Bool {
  !scrollingMonitorIDs.contains(targetMonitorID)
    && !pendingFrameWindowIDs.contains(targetWindowID)
    && !deferredSlowWindowIDs.contains(targetWindowID)
}

public func nativeFocusMutationIsReady(
  nativeFocusChanged: Bool,
  mouseInteractionEnded: Bool,
  leftMouseButtonDown: Bool,
  deferredMouseFocusPending: Bool? = nil,
  deferredMouseFocusReady: Bool? = nil,
  mouseReleaseFocusIntentCurrent: Bool,
  keyboardFocusIntentCurrent: Bool
) -> Bool {
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
  return nativeFocusChanged
}
