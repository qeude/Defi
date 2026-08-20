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

  private func focusCompletionRequiresLogicalRollback(
    _ result: NativeFocusResult
  ) -> Bool {
    switch result {
    case .failedAfterMutation, .cancelledAfterInputMutation:
      true
    case .completed, .completedWithoutMutation, .frameSuperseded,
      .superseded, .supersededAfterMutation, .cancelled,
      .cancelledAfterMutation, .failed:
      false
    }
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
    submittedCommandFocus = request
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
        return self.submittedCommandFocus?.windowID == request.windowID
          && self.submittedCommandFocus?.commandGeneration
            == request.commandGeneration
      },
      completion: { [weak self] result in
        guard let self else { return }
        guard commandFocusCompletionIsCurrent(
          submittedWindowID: self.submittedCommandFocus?.windowID,
          submittedGeneration:
            self.submittedCommandFocus?.commandGeneration,
          completedWindowID: request.windowID,
          completedGeneration: request.commandGeneration
        ) else { return }
        self.platform.recordCommandFocus(
          CommandPerformanceContext(
            generation: request.commandGeneration,
            inputTimestamp: request.focusInputTimestamp
          ),
          result: result
        )
        self.submittedCommandFocus = nil
        self.submittedCommandFocusRequestID = nil
        self.submittedCommandFocusRequestTimestamp = nil
        self.submittedCommandFocusRecoveryGeneration = nil
        if result == .failed || result == .failedAfterMutation,
          let nextRetryCount = nextCommandFocusRetryCount(
            currentRetryCount: request.retryCount,
            maximumRetryCount: 1,
            requestGeneration: request.commandGeneration,
            currentGeneration: self.commandGeneration,
            requestedWindowID: request.windowID,
            selectedWindowID: self.state.selectedWindowID(on: request.monitorID)
          )
        {
          self.pendingAnimatedFocus = PendingAnimatedFocus(
            windowID: request.windowID,
            previousSelectedWindowID: request.previousSelectedWindowID,
            monitorID: request.monitorID,
            sourceWorkspaceID: request.sourceWorkspaceID,
            commandGeneration: request.commandGeneration,
            focusInputTimestamp: request.focusInputTimestamp,
            cursorWarpInputTimestamp: request.cursorWarpInputTimestamp,
            retryCount: nextRetryCount
          )
          return
        }
        guard !self.cancellationKeepsRequestedWindow(
          windowID,
          requestInputTimestamp: focusInputTimestamp
        ),
          let fallbackWindowID = commandFocusCancellationFallback(
            cancelledBeforeMutation:
              result == .cancelled || result == .failed,
            rollbackAfterMutation:
              self.focusCompletionRequiresLogicalRollback(result),
            requestGeneration: commandGeneration,
            currentGeneration: self.commandGeneration,
            requestedWindowID: windowID,
            selectedWindowID: self.state.selectedWindowID(on: monitorID),
            previousSelectedWindowID: previousSelectedWindowID,
            sourceWorkspaceID: sourceWorkspaceID,
            previousSelectedWindowWorkspaceID:
              previousSelectedWindowID.flatMap {
                self.state.location(containing: $0)?.workspaceID
              }
          ),
          self.state.location(containing: fallbackWindowID)?.monitorID == monitorID
        else {
          return
        }
        _ = focusWindow(fallbackWindowID, state: &self.state)
        self.activeMonitorID = self.state.monitorID(
          containing: fallbackWindowID
        )
        self.needsDesktopSync = true
        self.updateMenuBar()
      }
    )
    submittedCommandFocusRequestTimestamp =
      submittedCommandFocusRequestID == nil ? nil : focusInputTimestamp
    submittedCommandFocusRecoveryGeneration = nil
  }

  func commitWorkspaceCommandFocus(
    result: NativeFocusResult,
    request: PendingWorkspaceFocus
  ) {
    guard pendingWorkspaceFocus?.commandGeneration == request.commandGeneration
    else { return }
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
    if result == .frameSuperseded {
      submittedWorkspaceFocusGeneration = nil
      return
    }
    if result == .failed || result == .failedAfterMutation,
      let nextRetryCount = nextCommandFocusRetryCount(
        currentRetryCount: request.retryCount,
        maximumRetryCount: 1,
        requestGeneration: request.commandGeneration,
        currentGeneration: commandGeneration,
        requestedWindowID: request.requestedWindowID,
        selectedWindowID: state.selectedWindowID(on: request.monitorID)
      )
    {
      submittedWorkspaceFocusGeneration = nil
      pendingWorkspaceFocus = PendingWorkspaceFocus(
        monitorID: request.monitorID,
        requestedWorkspaceID: request.requestedWorkspaceID,
        previousWorkspaceID: request.previousWorkspaceID,
        requestedWindowID: request.requestedWindowID,
        restoresPreviousWorkspaceOnCancellation:
          request.restoresPreviousWorkspaceOnCancellation,
        commandGeneration: request.commandGeneration,
        focusInputTimestamp: request.focusInputTimestamp,
        cursorWarpInputTimestamp: request.cursorWarpInputTimestamp,
        retryCount: nextRetryCount
      )
      return
    }
    pendingWorkspaceFocus = nil
    submittedWorkspaceFocusGeneration = nil
    guard !cancellationKeepsRequestedWindow(
      request.requestedWindowID,
      requestInputTimestamp: request.focusInputTimestamp
    ) else { return }
    guard let monitor = state.monitors.first(where: { $0.id == request.monitorID }),
      let fallbackWorkspaceID = workspaceFocusCancellationFallback(
        cancelledBeforeMutation:
          result == .cancelled || result == .failed,
        rollbackAfterMutation:
          focusCompletionRequiresLogicalRollback(result),
        requestGeneration: request.commandGeneration,
        currentGeneration: self.commandGeneration,
        requestedWorkspaceID: request.requestedWorkspaceID,
        activeWorkspaceID: monitor.activeWorkspace,
        previousWorkspaceID: request.previousWorkspaceID,
        requestedWindowID: request.requestedWindowID,
        selectedWindowID: state.selectedWindowID(on: request.monitorID),
        restoresPreviousWorkspace:
          request.restoresPreviousWorkspaceOnCancellation
      )
    else {
      return
    }
    do {
      try reduce(
        .switchWorkspace(fallbackWorkspaceID),
        on: request.monitorID,
        state: &state
      )
    } catch {
      return
    }

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
