import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation

@MainActor
extension Daemon {
  private func cancellationKeepsRequestedWindow(
    _ windowID: WindowID,
    requestInputTimestamp: TimeInterval
  ) -> Bool {
    return cancelledFocusTargetsRequestedWindow(
      requestedWindowID: windowID,
      requestedWindowIsNativelyFocused:
        platform.isWindowNativelyFocused(windowID),
      cancellingFocusTargetWindowID: platform.userInputTracker
        .focusRecoveryTarget(after: requestInputTimestamp)?.windowID
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
      completion: { [weak self] result in
        guard let self else { return }
        let effect = self.focus.completeCommand(
          request,
          submission: submission,
          result: result,
          commandGeneration: self.commandGeneration,
          keepsRequestedWindow: self.cancellationKeepsRequestedWindow(
            request.windowID, requestInputTimestamp: request.focusInputTimestamp
          ),
          state: &self.state
        )
        guard effect != .stale else { return }
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
    persistPlacements()
    updateMenuBar()
    synchronizeScrollOffsets(state: &state, viewports: viewportsByMonitor)
    snapScrollOffsetsToTargets()
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
