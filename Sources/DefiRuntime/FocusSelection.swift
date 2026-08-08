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

/// Focuses a pointer target only when doing so preserves every scroll offset.
/// This matches niri's `focus-follows-mouse max-scroll-amount="0%"` behavior
/// and prevents a moving strip from putting another window under the pointer.
public func focusWindowFromPointerWithoutScrolling(
  _ windowID: WindowID,
  activeMonitorID: MonitorID?,
  state: inout RuntimeState,
  viewports: [MonitorID: Rect],
  acceptsAlreadySelectedWindow: Bool = false
) -> MonitorID? {
  guard let monitorID = pointerFocusMonitorWithoutScrolling(
    windowID,
    activeMonitorID: activeMonitorID,
    state: state,
    viewports: viewports,
    acceptsAlreadySelectedWindow: acceptsAlreadySelectedWindow
  ) else {
    return nil
  }
  _ = focusWindow(windowID, state: &state)
  return monitorID
}

public func pointerFocusMonitorWithoutScrolling(
  _ windowID: WindowID,
  activeMonitorID: MonitorID?,
  state: RuntimeState,
  viewports: [MonitorID: Rect],
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

  for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
    let current = state.monitors[monitorIndex]
      .workspaces[workspaceIndex]
      .targetScrollOffset
    let candidate = preview.monitors[monitorIndex]
      .workspaces[workspaceIndex]
      .targetScrollOffset
    guard abs(current - candidate) <= 0.000_001 else {
      return nil
    }
  }

  return location.monitorID
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

public func commandFocusCancellationFallback(
  cancelledBeforeMutation: Bool,
  requestGeneration: UInt64,
  currentGeneration: UInt64,
  requestedWindowID: WindowID,
  selectedWindowID: WindowID?,
  previousSelectedWindowID: WindowID?,
  sourceWorkspaceID: WorkspaceID,
  previousSelectedWindowWorkspaceID: WorkspaceID?
) -> WindowID? {
  guard cancelledBeforeMutation,
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
    cancelledBeforeMutation,
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
  pointerTimestamp: TimeInterval,
  latestUserInputTimestamp: TimeInterval
) -> Bool {
  pendingWindowID == windowUnderPointerID
    && latestUserInputTimestamp <= pointerTimestamp
}

public func pointerFocusIntentIsCurrent(
  pointerTimestamp: TimeInterval,
  latestUserInputTimestamp: TimeInterval
) -> Bool {
  latestUserInputTimestamp <= pointerTimestamp
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

public func pendingCommandFocusIsPreserved(
  pendingWindowID: WindowID?,
  selectedWindowID: WindowID
) -> Bool {
  pendingWindowID == selectedWindowID
}

public func nextPointerFocusRetryCount(
  currentRetryCount: Int,
  maximumRetryCount: Int,
  intentCurrent: Bool
) -> Int? {
  guard intentCurrent, currentRetryCount < maximumRetryCount else { return nil }
  return currentRetryCount + 1
}

public func pointerFocusMonitorIsReady(
  targetMonitorID: MonitorID,
  scrollingMonitorIDs: Set<MonitorID>,
  animatedFrameMonitorIDs: Set<MonitorID>,
  deferredSlowMonitorIDs: Set<MonitorID>
) -> Bool {
  !scrollingMonitorIDs.contains(targetMonitorID)
    && !animatedFrameMonitorIDs.contains(targetMonitorID)
    && !deferredSlowMonitorIDs.contains(targetMonitorID)
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

public struct DeferredMouseFocusIntent: Equatable, Sendable {
  public var timestamp: Double
  public var windowID: WindowID?
  public var focusObserved: Bool
  public var mouseInteractionEnded: Bool

  public init(
    timestamp: Double,
    windowID: WindowID?,
    focusObserved: Bool = false,
    mouseInteractionEnded: Bool = false
  ) {
    self.timestamp = timestamp
    self.windowID = windowID
    self.focusObserved = focusObserved
    self.mouseInteractionEnded = mouseInteractionEnded
  }
}

public func updatedDeferredMouseFocusIntent(
  current: DeferredMouseFocusIntent?,
  consumedMouseFocusIntentTimestamp: Double = 0,
  mouseFocusIntentWindowID: WindowID?,
  mouseFocusIntentTimestamp: Double?,
  focusedWindowID: WindowID?,
  nativeFocusChanged: Bool,
  mouseInteractionEnded: Bool
) -> DeferredMouseFocusIntent? {
  var intent = current.flatMap {
    $0.timestamp > consumedMouseFocusIntentTimestamp ? $0 : nil
  }
  if let timestamp = mouseFocusIntentTimestamp,
    timestamp > consumedMouseFocusIntentTimestamp,
    intent.map({ timestamp > $0.timestamp }) ?? true
  {
    intent = DeferredMouseFocusIntent(
      timestamp: timestamp,
      windowID: mouseFocusIntentWindowID
    )
  }
  guard var intent else { return nil }
  if nativeFocusChanged, let focusedWindowID {
    if intent.windowID == nil {
      intent.windowID = focusedWindowID
    }
    intent.focusObserved = intent.windowID == focusedWindowID
  }
  intent.mouseInteractionEnded =
    intent.mouseInteractionEnded || mouseInteractionEnded
  return intent
}

public func mouseReleaseFocusIntentIsCurrent(
  focusedWindowID: WindowID,
  mouseFocusIntentWindowID: WindowID?,
  mouseFocusIntentTimestamp: Double?,
  latestCommandInputTimestamp: Double,
  nativeFocusChanged: Bool
) -> Bool {
  guard let mouseFocusIntentTimestamp,
    mouseFocusIntentTimestamp > latestCommandInputTimestamp
  else {
    return false
  }
  return mouseFocusIntentWindowID == focusedWindowID
    || (mouseFocusIntentWindowID == nil && nativeFocusChanged)
}

public func keyboardFocusIntentIsCurrent(
  keyboardFocusIntentTimestamp: Double?,
  latestCommandInputTimestamp: Double
) -> Bool {
  guard let keyboardFocusIntentTimestamp else { return false }
  return keyboardFocusIntentTimestamp > latestCommandInputTimestamp
}

public func resolvedLatestCommandInputTimestamp(
  previousTimestamp: Double,
  capturedInputTimestamp: Double?,
  commandHandledAt: Double
) -> Double {
  max(previousTimestamp, capturedInputTimestamp ?? commandHandledAt)
}

public struct WindowRemovalFocusGuard: Equatable, Sendable {
  public let monitorID: MonitorID
  public let workspaceID: WorkspaceID
  public let inputTimestamp: Double

  public init(
    monitorID: MonitorID,
    workspaceID: WorkspaceID,
    inputTimestamp: Double
  ) {
    self.monitorID = monitorID
    self.workspaceID = workspaceID
    self.inputTimestamp = inputTimestamp
  }
}

public enum WindowRemovalFocusDecision: Equatable, Sendable {
  case accept
  case wait(localFallback: WindowID?)
  case preserve(localFallback: WindowID?)
}

public func windowRemovalFocusGuard(
  previousMonitorID: MonitorID?,
  previousWorkspaceID: WorkspaceID?,
  previousSelectedWindowID: WindowID?,
  removedWindowIDs: Set<WindowID>,
  userInputAfterWindowTopology: Bool,
  latestUserInputTimestamp: Double
) -> WindowRemovalFocusGuard? {
  guard let previousMonitorID,
    let previousWorkspaceID,
    let previousSelectedWindowID,
    removedWindowIDs.contains(previousSelectedWindowID),
    !userInputAfterWindowTopology
  else {
    return nil
  }
  return WindowRemovalFocusGuard(
    monitorID: previousMonitorID,
    workspaceID: previousWorkspaceID,
    inputTimestamp: latestUserInputTimestamp
  )
}

public func windowRemovalFocusDecision(
  guard focusGuard: WindowRemovalFocusGuard,
  nativeFocusedWindowID: WindowID?,
  nativeFocusChanged: Bool,
  latestUserInputTimestamp: Double,
  state: RuntimeState
) -> WindowRemovalFocusDecision {
  guard latestUserInputTimestamp <= focusGuard.inputTimestamp,
    let monitor = state.monitors.first(where: { $0.id == focusGuard.monitorID }),
    monitor.activeWorkspace == focusGuard.workspaceID
  else {
    return .accept
  }
  let localFallback = state.selectedWindowID(on: focusGuard.monitorID)
  guard nativeFocusChanged, let nativeFocusedWindowID else {
    return .wait(localFallback: localFallback)
  }
  guard let location = state.location(containing: nativeFocusedWindowID),
    location.monitorID == focusGuard.monitorID,
    location.workspaceID == focusGuard.workspaceID
  else {
    return .preserve(localFallback: localFallback)
  }
  return .accept
}
