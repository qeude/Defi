import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation

@MainActor
extension Daemon {
  func requeueDisplacedPointerFocusAfterDisplayChange(
    _ recovery: DisplacedPointerFocusRecovery
  ) {
    switch recovery {
    case .command(let request, let timestamp):
      guard let monitorID = state.reboundFocusMonitorID(
        for: request.windowID
      ) else { return }
      pendingAnimatedFocus = PendingAnimatedFocus(
        windowID: request.windowID,
        previousSelectedWindowID: request.previousSelectedWindowID,
        monitorID: monitorID,
        sourceWorkspaceID: request.sourceWorkspaceID,
        commandGeneration: request.commandGeneration,
        focusInputTimestamp: pointerDisplacedFocusInputTimestamp(
          commandInputTimestamp: request.focusInputTimestamp,
          pointerInputTimestamp: timestamp
        ),
        cursorWarpInputTimestamp: nil,
        retryCount: request.retryCount
      )
    case .workspace(let request, let timestamp):
      guard let monitorID = state.reboundFocusMonitorID(
        for: request.requestedWindowID,
        requestedWorkspaceID: request.requestedWorkspaceID
      ) else { return }
      pendingWorkspaceFocus = PendingWorkspaceFocus(
        monitorID: monitorID,
        requestedWorkspaceID: request.requestedWorkspaceID,
        previousWorkspaceID: request.previousWorkspaceID,
        requestedWindowID: request.requestedWindowID,
        restoresPreviousWorkspaceOnCancellation:
          request.restoresPreviousWorkspaceOnCancellation,
        commandGeneration: request.commandGeneration,
        focusInputTimestamp: pointerDisplacedFocusInputTimestamp(
          commandInputTimestamp: request.focusInputTimestamp,
          pointerInputTimestamp: timestamp
        ),
        cursorWarpInputTimestamp: nil,
        retryCount: request.retryCount
      )
      submittedWorkspaceFocusGeneration = nil
    }
  }

  func requeuePreservedFocusAfterMonitorRetention(
    command: PendingAnimatedFocus?,
    workspace: PendingWorkspaceFocus?,
    displaced: DisplacedPointerFocusRecovery?
  ) {
    if let displaced {
      requeueDisplacedPointerFocusAfterDisplayChange(displaced)
      return
    }
    if let command,
      let monitorID = state.reboundFocusMonitorID(for: command.windowID)
    {
      pendingAnimatedFocus = PendingAnimatedFocus(
        windowID: command.windowID,
        previousSelectedWindowID: command.previousSelectedWindowID,
        monitorID: monitorID,
        sourceWorkspaceID: command.sourceWorkspaceID,
        commandGeneration: command.commandGeneration,
        focusInputTimestamp: command.focusInputTimestamp,
        cursorWarpInputTimestamp: command.cursorWarpInputTimestamp,
        retryCount: command.retryCount
      )
    }
    if let workspace,
      let monitorID = state.reboundFocusMonitorID(
        for: workspace.requestedWindowID,
        requestedWorkspaceID: workspace.requestedWorkspaceID
      )
    {
      pendingWorkspaceFocus = PendingWorkspaceFocus(
        monitorID: monitorID,
        requestedWorkspaceID: workspace.requestedWorkspaceID,
        previousWorkspaceID: workspace.previousWorkspaceID,
        requestedWindowID: workspace.requestedWindowID,
        restoresPreviousWorkspaceOnCancellation:
          workspace.restoresPreviousWorkspaceOnCancellation,
        commandGeneration: workspace.commandGeneration,
        focusInputTimestamp: workspace.focusInputTimestamp,
        cursorWarpInputTimestamp: workspace.cursorWarpInputTimestamp,
        retryCount: workspace.retryCount
      )
      submittedWorkspaceFocusGeneration = nil
    }
  }

  func rearmPointerFocusTransition() {
    lastPointerWindowID = nil
    lastRawPointerWindowID = nil
    hotKeys?.resetPointerWindowTransition()
  }

  func invalidateSubmittedCommandFocus(
    recoveringTo windowID: WindowID? = nil
  ) {
    guard let requestID = submittedCommandFocusRequestID else {
      submittedCommandFocusRequestTimestamp = nil
      submittedCommandFocusRecoveryGeneration = nil
      submittedCommandFocus = nil
      return
    }
    let timestamp = submittedCommandFocus?.focusInputTimestamp
      ?? submittedCommandFocusRequestTimestamp
    let cancelled = platform.cancelFocus(requestID, recoveringTo: windowID)
    if !cancelled, let windowID, let timestamp {
      nextCommandFocusRecoveryGeneration &+= 1
      let recoveryGeneration = nextCommandFocusRecoveryGeneration
      let recoveryID = platform.focus(
        windowID,
        unlessUserInputAfter: timestamp,
        completion: { [weak self] _ in
          guard let self,
            self.submittedCommandFocusRecoveryGeneration
              == recoveryGeneration
          else { return }
          self.submittedCommandFocusRequestID = nil
          self.submittedCommandFocusRequestTimestamp = nil
          self.submittedCommandFocusRecoveryGeneration = nil
        }
      )
      submittedCommandFocusRequestID = recoveryID
      submittedCommandFocusRequestTimestamp =
        recoveryID == nil ? nil : timestamp
      submittedCommandFocusRecoveryGeneration =
        recoveryID == nil ? nil : recoveryGeneration
    } else {
      submittedCommandFocusRequestID = nil
      submittedCommandFocusRequestTimestamp = nil
      submittedCommandFocusRecoveryGeneration = nil
    }
    submittedCommandFocus = nil
  }

  func invalidateSubmittedWorkspaceFocus(
    recoveringTo windowID: WindowID? = nil
  ) {
    guard let requestID = submittedWorkspaceFocusRequestID else {
      submittedWorkspaceFocusRequestTimestamp = nil
      submittedWorkspaceFocusGeneration = nil
      submittedWorkspaceFocusRecoveryGeneration = nil
      return
    }
    let timestamp = pendingWorkspaceFocus?.focusInputTimestamp
      ?? submittedWorkspaceFocusRequestTimestamp
    let cancelled = platform.cancelFocus(requestID, recoveringTo: windowID)
    if !cancelled, let windowID, let timestamp {
      nextWorkspaceFocusRecoveryGeneration &+= 1
      let recoveryGeneration = nextWorkspaceFocusRecoveryGeneration
      let recoveryID = platform.focus(
        windowID,
        unlessUserInputAfter: timestamp,
        completion: { [weak self] _ in
          guard let self,
            self.submittedWorkspaceFocusRecoveryGeneration
              == recoveryGeneration
          else { return }
          self.submittedWorkspaceFocusRequestID = nil
          self.submittedWorkspaceFocusRequestTimestamp = nil
          self.submittedWorkspaceFocusRecoveryGeneration = nil
        }
      )
      submittedWorkspaceFocusRequestID = recoveryID
      submittedWorkspaceFocusRequestTimestamp =
        recoveryID == nil ? nil : timestamp
      submittedWorkspaceFocusRecoveryGeneration =
        recoveryID == nil ? nil : recoveryGeneration
    } else {
      submittedWorkspaceFocusRequestID = nil
      submittedWorkspaceFocusRequestTimestamp = nil
      submittedWorkspaceFocusRecoveryGeneration = nil
    }
    submittedWorkspaceFocusGeneration = nil
  }

  func invalidatePointerFocusIntent(recoveringTo windowID: WindowID? = nil) {
    pointerFocusGeneration &+= 1
    pendingPointerFocus = nil
    invalidateSubmittedPointerFocusRecovery(recoveringTo: windowID)
    if let submittedPointerFocusRequestID {
      let timestamp = submittedPointerFocusTimestamp
      let cancelled = platform.cancelFocus(
        submittedPointerFocusRequestID,
        recoveringTo: windowID
      )
      if let recoveryWindowID = pointerFocusRecoveryTargetAfterCancellation(
        cancellationSucceeded: cancelled,
        logicalFocusWindowID: windowID
      ), let timestamp
      {
        recoverPointerFocus(
          to: recoveryWindowID,
          unlessUserInputAfter: timestamp
        )
      }
      self.submittedPointerFocusRequestID = nil
      self.submittedPointerFocusTimestamp = nil
      self.submittedPointerFocusGeneration = nil
    }
  }

  func recoverPointerFocus(
    to windowID: WindowID?,
    unlessUserInputAfter timestamp: TimeInterval
  ) {
    guard let windowID else { return }
    nextPointerFocusRecoveryGeneration &+= 1
    let recoveryGeneration = nextPointerFocusRecoveryGeneration
    let recoveryID = platform.focus(
      windowID,
      unlessUserInputAfter: timestamp,
      completion: { [weak self] _ in
        guard let self,
          self.submittedPointerFocusRecoveryGeneration == recoveryGeneration
        else { return }
        self.submittedPointerFocusRecoveryRequestID = nil
        self.submittedPointerFocusRecoveryTimestamp = nil
        self.submittedPointerFocusRecoveryGeneration = nil
      }
    )
    submittedPointerFocusRecoveryRequestID = recoveryID
    submittedPointerFocusRecoveryTimestamp =
      recoveryID == nil ? nil : timestamp
    submittedPointerFocusRecoveryGeneration =
      recoveryID == nil ? nil : recoveryGeneration
  }

  private func invalidateSubmittedPointerFocusRecovery(
    recoveringTo windowID: WindowID?
  ) {
    guard let recoveryRequestID = submittedPointerFocusRecoveryRequestID else {
      submittedPointerFocusRecoveryTimestamp = nil
      submittedPointerFocusRecoveryGeneration = nil
      return
    }
    let timestamp = submittedPointerFocusRecoveryTimestamp
    let recoveryGeneration = submittedPointerFocusRecoveryGeneration
    let cancelled = platform.cancelFocus(
      recoveryRequestID,
      recoveringTo: windowID
    )
    if !cancelled, let windowID, let timestamp {
      recoverPointerFocus(
        to: windowID,
        unlessUserInputAfter: timestamp
      )
    }
    guard submittedPointerFocusRecoveryGeneration == recoveryGeneration else {
      return
    }
    submittedPointerFocusRecoveryRequestID = nil
    submittedPointerFocusRecoveryTimestamp = nil
    submittedPointerFocusRecoveryGeneration = nil
  }

  func pointerFocusIsReady(for windowID: WindowID) -> Bool {
    guard let targetMonitorID = state.monitorID(containing: windowID) else {
      return false
    }
    return focusMonitorIsReady(
      targetMonitorID: targetMonitorID,
      scrollingMonitorIDs: Set(scrollAnimations.keys.map(\.monitorID)),
      pendingFrameMonitorIDs: Set(
        platform.pendingFrameWindowIDs.compactMap {
          state.monitorID(containing: $0)
        }
      )
    )
  }

}
