import DefiModel

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
  mouseFocusIntentWindowID: WindowID?,
  mouseFocusIntentTimestamp: Double?,
  focusedWindowID: WindowID?,
  nativeFocusChanged: Bool,
  mouseInteractionEnded: Bool
) -> DeferredMouseFocusIntent? {
  var intent = current
  if let timestamp = mouseFocusIntentTimestamp,
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
