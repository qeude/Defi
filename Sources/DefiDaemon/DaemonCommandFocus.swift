import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation

@NavigationActor
extension Daemon {
  private func cancellationKeepsRequestedWindow(
    _ windowID: WindowID,
    requestInputTimestamp: TimeInterval,
    commandCapturedAfterRequest: Bool = false
  ) -> Bool {
    return cancelledFocusTargetsRequestedWindow(
      requestedWindowID: windowID,
      requestedWindowIsNativelyFocused:
        platform.isWindowNativelyFocused(windowID),
      cancellingFocusTargetWindowID: platform.userInputTracker
        .focusRecoveryTarget(after: requestInputTimestamp)?.windowID,
      commandCapturedAfterRequest: commandCapturedAfterRequest
    )
  }

  func commitCommandFocus(
    _ windowID: WindowID,
    previousSelectedWindowID: WindowID?,
    monitorID: MonitorID,
    sourceWorkspaceID: WorkspaceID,
    commandGeneration: UInt64,
    focusInputTimestamp: TimeInterval,
    cursorWarpInputTimestamp: TimeInterval?,
    retryCount: Int = 0
  ) {
    invalidateSubmittedCommandFocus()
    let request = PendingAnimatedFocus(
      windowID: windowID,
      previousSelectedWindowID: previousSelectedWindowID,
      monitorID: monitorID,
      sourceWorkspaceID: sourceWorkspaceID,
      commandGeneration: commandGeneration,
      focusInputTimestamp: focusInputTimestamp,
      cursorWarpInputTimestamp: cursorWarpInputTimestamp,
      retryCount: retryCount
    )
    let submission = focus.submitCommand(request)
    let committedCursorWarpInputTimestamp =
      platform.cursorWarpFrameIsReady(for: windowID)
      ? cursorWarpInputTimestamp
      : nil
    submittedCommandFocusRequestID = platform.focus(
      windowID,
      unlessUserInputAfter: focusInputTimestamp,
      cursorWarpUnlessPointerMovedAfter: committedCursorWarpInputTimestamp,
      cursorWarpIsCurrent: { [weak self] in
        guard let self else { return false }
        return self.focus.commandCompletionIsCurrent(request, submission: submission)
      },
      allowsNativeFullscreen: true,
      // A failed command focus keeps the requested selection, so native focus must not
      // fall back to the window the command left (issue #210).
      restoresPreviousFocusOnFailure: false,
      completion: { [weak self] result in
        guard let self else { return }
        let newerCommandAt = max(
          self.latestCommandInputTimestamp,
          self.platform.userInputTracker.snapshot.latestCapturedCommandTimestamp
        )
        let supersededByCommand = newerCommandAt > request.focusInputTimestamp
        let effect = self.focus.completeCommand(
          request,
          submission: submission,
          result: result,
          commandGeneration: self.commandGeneration,
          keepsRequestedWindow: self.cancellationKeepsRequestedWindow(
            request.windowID, requestInputTimestamp: request.focusInputTimestamp,
            commandCapturedAfterRequest: supersededByCommand
          ),
          state: &self.state
        )
        guard effect != .stale else { return }
        if effect == .settled, self.focus.pendingAnimatedFocus == nil,
          self.state.selectedWindowID(on: request.monitorID) == request.windowID,
          !self.platform.isWindowNativelyFocused(request.windowID)
        {
          if supersededByCommand, result == .cancelled || result == .cancelledAfterInputMutation {
            // The next key press cancelled this focus before its command ran; if that
            // command takes no focus, native focus must still land on the kept selection.
            self.focus.queueCommand(commandFocusAfterNoOp(request, inputTimestamp: newerCommandAt))
          } else if result == .failed || result == .failedAfterMutation {
            self.platform.recordPerformanceTrace(
              "command-focus-exhausted cg=\(request.commandGeneration) window=\(request.windowID.rawValue) result=\(result)")
          }
        }
        self.platform.recordCommandFocus(
          CommandPerformanceContext(
            generation: request.commandGeneration,
            inputTimestamp: request.focusInputTimestamp
          ),
          result: result
        )
        self.submittedCommandFocusRequestID = nil
        self.submittedCommandFocusRequestTimestamp = nil
        self.submittedCommandFocusRecoveryGeneration = nil
        if case .selectionChanged(let monitorID) = effect {
          self.activeMonitorID = monitorID
          self.needsDesktopSync = true
          self.updateMenuBar()
        }
      }
    )
    submittedCommandFocusRequestTimestamp =
      submittedCommandFocusRequestID == nil ? nil : focusInputTimestamp
    submittedCommandFocusRecoveryGeneration = nil
  }

  func commitWorkspaceCommandFocus(
    result: NativeFocusResult,
    request: PendingWorkspaceFocus,
    submission: FocusSubmissionID
  ) {
    let effect = focus.completeWorkspace(
      request,
      submission: submission,
      result: result,
      commandGeneration: commandGeneration,
      keepsRequestedWindow: cancellationKeepsRequestedWindow(
        request.requestedWindowID, requestInputTimestamp: request.focusInputTimestamp
      ),
      state: &state
    )
    guard effect != .stale else { return }
    platform.recordCommandFocus(
      CommandPerformanceContext(
        generation: request.commandGeneration,
        inputTimestamp: request.focusInputTimestamp
      ),
      result: result
    )
    submittedWorkspaceFocusRequestID = nil
    submittedWorkspaceFocusRequestTimestamp = nil
    submittedWorkspaceFocusRecoveryGeneration = nil
    guard case .selectionChanged = effect else { return }
    activeMonitorID = request.monitorID
    updateMenuBar()
    synchronizeScrollOffsets(state: &state, viewports: viewportsByMonitor)
    snapScrollOffsetsToTargets()
    persistTopology()
    applyCurrentLayout(
      asynchronousPositions: true,
      updateVisibility: true,
      positionTimeoutSeconds: 0.05,
      stagesVisibleBeforeParking: true,
      source: "workspace-focus-cancel"
    )
    needsDesktopSync = true
  }
}
