import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation

@MainActor
extension Daemon {
  func rebindFocusRequests(using replacements: [WindowID: WindowID]) {
    let recovery = focus.rebind(
      using: replacements,
      workspaceWritePending: submittedWorkspaceFocusRequestID != nil
    )
    if let windowID = recovery.command {
      invalidateSubmittedCommandFocus(recoveringTo: windowID)
    }
    if let windowID = recovery.workspace {
      invalidateSubmittedWorkspaceFocus(recoveringTo: windowID)
    }
  }

  func rearmPointerFocusTransition() {
    focus.rearmPointer()
    lastRawPointerWindowID = nil
    hotKeys?.resetPointerWindowTransition()
  }

  func invalidateSubmittedCommandFocus(
    recoveringTo windowID: WindowID? = nil
  ) {
    let timestamp =
      submittedCommandFocus?.focusInputTimestamp
      ?? submittedCommandFocusRequestTimestamp
    focus.cancelSubmittedCommand()
    guard let requestID = submittedCommandFocusRequestID else {
      submittedCommandFocusRequestTimestamp = nil
      submittedCommandFocusRecoveryGeneration = nil
      return
    }
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
  }

  func invalidateSubmittedWorkspaceFocus(
    recoveringTo windowID: WindowID? = nil
  ) {
    let timestamp =
      pendingWorkspaceFocus?.focusInputTimestamp
      ?? submittedWorkspaceFocusRequestTimestamp
    focus.cancelSubmittedWorkspace()
    guard let requestID = submittedWorkspaceFocusRequestID else {
      submittedWorkspaceFocusRequestTimestamp = nil
      submittedWorkspaceFocusRecoveryGeneration = nil
      return
    }
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
  }

  func invalidatePointerFocusIntent(recoveringTo windowID: WindowID? = nil) {
    focus.invalidatePointer()
    cancelSubmittedPointerFocus(recoveringTo: windowID)
  }

  func cancelSubmittedPointerFocus(recoveringTo windowID: WindowID? = nil) {
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
      ), let timestamp {
        recoverPointerFocus(
          to: recoveryWindowID,
          unlessUserInputAfter: timestamp
        )
      }
      self.submittedPointerFocusRequestID = nil
      self.submittedPointerFocusTimestamp = nil
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
