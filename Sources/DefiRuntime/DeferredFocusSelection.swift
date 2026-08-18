import DefiModel
import Foundation

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
  mouseInteractionEnded: Bool,
  nativeFocusTargetIsNew: Bool = false,
  nativeFocusEventAfterMouseRelease: Bool = false
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
  let interactionEnded = intent.mouseInteractionEnded || mouseInteractionEnded
  if nativeFocusChanged, let focusedWindowID {
    let canRebindToNativeFocus = intent.windowID == nil
      || intent.windowID == focusedWindowID
      || (interactionEnded
        && (nativeFocusTargetIsNew || nativeFocusEventAfterMouseRelease))
    if canRebindToNativeFocus {
      intent.windowID = focusedWindowID
      intent.focusObserved = true
    }
  }
  intent.mouseInteractionEnded = interactionEnded
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

public struct GuardedWindowRemovalFocusAction: Equatable, Sendable {
  public let windowID: WindowID
  public let monitorID: MonitorID
  public let inputTimestamp: Double

  public init(
    windowID: WindowID,
    monitorID: MonitorID,
    inputTimestamp: Double
  ) {
    self.windowID = windowID
    self.monitorID = monitorID
    self.inputTimestamp = inputTimestamp
  }
}

public func guardedWindowRemovalFocusAction(
  decision: WindowRemovalFocusDecision,
  focusGuard: WindowRemovalFocusGuard,
  newlyCreated: Bool
) -> GuardedWindowRemovalFocusAction? {
  let localFallback: WindowID?
  switch decision {
  case .accept:
    return nil
  case .wait(let fallback):
    guard newlyCreated else { return nil }
    localFallback = fallback
  case .preserve(let fallback):
    localFallback = fallback
  }
  guard let localFallback else { return nil }
  return GuardedWindowRemovalFocusAction(
    windowID: localFallback,
    monitorID: focusGuard.monitorID,
    inputTimestamp: focusGuard.inputTimestamp
  )
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
