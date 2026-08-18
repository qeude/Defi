import AppKit
import DefiConfig
import DefiCore
import DefiIPC
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation
import OSLog

@MainActor
extension Daemon {
  func enqueueHotKey(_ invocation: HotKeyInvocation) {
    guard pendingHotKeyCommands.count < 64 else { return }
    pendingHotKeyCommands.append(invocation)
    processPendingHotKeys()
  }

  func processPendingHotKeys() {
    guard !processingHotKeyCommands else { return }
    processingHotKeyCommands = true
    defer { processingHotKeyCommands = false }
    for _ in 0..<min(pendingHotKeyCommands.count, 8) {
      let invocation = pendingHotKeyCommands.removeFirst()
      _ = handle(
        invocation.command,
        inputTimestamp: invocation.timestamp
      )
      processedHotKeyCount += 1
    }
  }

  func pollIPC() {
    do {
      for _ in 0..<16 {
        let handled = try server.poll { [weak self] command in
          self?.handle(command) ?? .failure("daemon unavailable")
        }
        if !handled { break }
      }
      if shouldShutdown {
        shutdown()
      }
    } catch {
      log("IPC error: \(error)")
    }
  }

  @discardableResult
  func handle(
    _ rawCommand: String,
    inputTimestamp: TimeInterval? = nil
  ) -> CommandResponse {
    if rawCommand == "status" {
      return .success(status())
    }
    if rawCommand == "trace" {
      return .success(platform.frameCoordinatorTrace)
    }
    if rawCommand == "restore" {
      restoreAllWindows()
      return .success("restored")
    }
    if rawCommand == "quit" {
      shouldShutdown = true
      return .success("stopping")
    }
    do {
      let commandStartedAt = ProcessInfo.processInfo.systemUptime
      let command = try parseCommand(rawCommand)
      var validationState = state
      try reduce(command, on: activeMonitorID, state: &validationState)
      let previouslySelectedWindowID = activeMonitorID.flatMap {
        state.selectedWindowID(on: $0)
      }
      commandGeneration &+= 1
      let currentCommandGeneration = commandGeneration
      platform.recordPerformanceTrace(
        "command-start cg=\(currentCommandGeneration) command=\(rawCommand)"
      )
      platform.userInputTracker.record(
        timestamp: inputTimestamp ?? commandStartedAt
      )
      displacedPointerFocusRecovery = nil
      invalidatePointerFocusIntent(recoveringTo: previouslySelectedWindowID)
      let focusInputTimestamp = commandFocusInputTimestamp(
        capturedInputTimestamp: inputTimestamp,
        commandHandledAt: commandStartedAt
      )
      let cursorWarpInputTimestamp = keyboardCursorWarpTimestamp(
        mouseFollowsFocus: config.input.mouseFollowsFocus,
        capturedInputTimestamp: inputTimestamp
      )
      mouseReorderAnimationActive = false
      latestCommandInputTimestamp = resolvedLatestCommandInputTimestamp(
        previousTimestamp: latestCommandInputTimestamp,
        capturedInputTimestamp: inputTimestamp,
        commandHandledAt: commandStartedAt
      )
      pendingWindowRemovalFocusGuard = nil
      let switchesWorkspace = command.activatesWorkspace
      let mutatesWorkspaceWindows = command.movesWindowBetweenWorkspaces
      let resizesManagedLayout = command.resizesManagedLayout
      let speculativeRibbonNavigation = isSpeculativeRibbonNavigation(command)
      if switchesWorkspace || mutatesWorkspaceWindows
        || resizesManagedLayout || speculativeRibbonNavigation
      {
        rearmPointerFocusTransition()
      }
      if switchesWorkspace || mutatesWorkspaceWindows || resizesManagedLayout
        || speculativeRibbonNavigation
      {
        preemptMouseGesture()
      }
      let animatedManagedResize =
        resizesManagedLayout
        && config.animation.enabled
        && config.animation.durationMS > 0
      let commandMonitorID = activeMonitorID ?? state.monitors.first?.id
      let previousWorkspaceID = commandMonitorID.flatMap { monitorID in
        state.monitors.first(where: { $0.id == monitorID })?.activeWorkspace
      }
      if !scrollAnimations.isEmpty || platform.hasPendingAnimatedFrameWrites {
        rebaseActiveScrollOffsetToDisplayedFrames()
      }
      if switchesWorkspace || mutatesWorkspaceWindows {
        refreshFloatingWindowFramesBeforeWorkspaceMutation()
      }
      if switchesWorkspace {
        suppressNativeFocusUntil = commandStartedAt + 0.25
        pendingAnimatedFocus = nil
        invalidateSubmittedCommandFocus()
        invalidateSubmittedWorkspaceFocus()
        pendingWorkspaceFocus = nil
      }
      try reduce(command, on: activeMonitorID, state: &state)
      if command.movesWindowBetweenWorkspaces,
        let movedWindowID = previouslySelectedWindowID,
        let movedWindow = state.windows[movedWindowID],
        movedWindow.floatingOrigin == .automatic
      {
        invalidatePlacementPreference(for: movedWindow)
      }
      if !switchesWorkspace,
        let submittedCommandFocus,
        let commandMonitorID,
        let selectedWindowID = state.selectedWindowID(on: commandMonitorID),
        !commandFocusIsPreserved(
          pendingWindowID: nil,
          submittedWindowID: submittedCommandFocus.windowID,
          selectedWindowID: selectedWindowID
        )
      {
        invalidateSubmittedCommandFocus()
      }
      synchronizeScrollOffsets(state: &state, viewports: viewportsByMonitor)
      if switchesWorkspace {
        snapScrollOffsetsToTargets()
      } else {
        startScrollAnimationsIfNeeded()
      }
      let dispatchedAnimation =
        animatedManagedResize
        ? dispatchManagedResizeAnimation()
        : dispatchScrollAnimationIfNeeded()
      let workspaceFocusRequest: PendingWorkspaceFocus?
      if switchesWorkspace,
        let commandMonitorID,
        let requestedWorkspaceID = state.monitors.first(where: {
          $0.id == commandMonitorID
        })?.activeWorkspace,
        let requestedWindowID = state.selectedWindowID(on: commandMonitorID)
      {
        let restoresPreviousWorkspaceOnCancellation: Bool
        if case .switchWorkspace = command {
          restoresPreviousWorkspaceOnCancellation = true
        } else {
          restoresPreviousWorkspaceOnCancellation = false
        }
        workspaceFocusRequest = PendingWorkspaceFocus(
          monitorID: commandMonitorID,
          requestedWorkspaceID: requestedWorkspaceID,
          previousWorkspaceID: previousWorkspaceID,
          requestedWindowID: requestedWindowID,
          restoresPreviousWorkspaceOnCancellation:
            restoresPreviousWorkspaceOnCancellation,
          commandGeneration: currentCommandGeneration,
          focusInputTimestamp: focusInputTimestamp,
          cursorWarpInputTimestamp: cursorWarpInputTimestamp
        )
      } else if let pending = pendingWorkspaceFocus,
        pendingWorkspaceFocusIsPreserved(
          pendingMonitorID: pending.monitorID,
          commandMonitorID: commandMonitorID,
          requestedWorkspaceID: pending.requestedWorkspaceID,
          activeWorkspaceID: state.monitors.first(where: {
            $0.id == pending.monitorID
          })?.activeWorkspace,
          requestedWindowID: pending.requestedWindowID,
          selectedWindowID: state.selectedWindowID(on: pending.monitorID)
        )
      {
        workspaceFocusRequest = PendingWorkspaceFocus(
          monitorID: pending.monitorID,
          requestedWorkspaceID: pending.requestedWorkspaceID,
          previousWorkspaceID: pending.previousWorkspaceID,
          requestedWindowID: pending.requestedWindowID,
          restoresPreviousWorkspaceOnCancellation:
            pending.restoresPreviousWorkspaceOnCancellation,
          commandGeneration: currentCommandGeneration,
          focusInputTimestamp: focusInputTimestamp,
          cursorWarpInputTimestamp: cursorWarpInputTimestamp
        )
      } else {
        workspaceFocusRequest = nil
      }
      invalidateSubmittedWorkspaceFocus()
      pendingWorkspaceFocus = workspaceFocusRequest
      if switchesWorkspace || !dispatchedAnimation {
        let focusWindowIDAfterCommit = workspaceFocusRequest?.requestedWindowID
        let focusCompletionAfterCommit: (@MainActor @Sendable (NativeFocusResult) -> Void)?
        let cursorWarpIsCurrentAfterCommit:
          (@MainActor @Sendable () -> Bool)?
        let focusRequestIDAfterCommit:
          (@MainActor @Sendable (NativeFocusRequestID?) -> Void)?
        if let workspaceFocusRequest {
          submittedWorkspaceFocusGeneration =
            workspaceFocusRequest.commandGeneration
          focusCompletionAfterCommit = { [weak self] result in
            self?.commitWorkspaceCommandFocus(
              result: result,
              request: workspaceFocusRequest
            )
          }
          cursorWarpIsCurrentAfterCommit = { [weak self] in
            guard let self else { return false }
            return self.pendingWorkspaceFocus?.commandGeneration
                == workspaceFocusRequest.commandGeneration
              && self.submittedWorkspaceFocusGeneration
                == workspaceFocusRequest.commandGeneration
          }
          focusRequestIDAfterCommit = { [weak self] requestID in
            guard let self,
              self.pendingWorkspaceFocus?.commandGeneration
                == workspaceFocusRequest.commandGeneration,
              self.submittedWorkspaceFocusGeneration
                == workspaceFocusRequest.commandGeneration
            else { return }
            self.submittedWorkspaceFocusRequestID = requestID
            self.submittedWorkspaceFocusRequestTimestamp =
              requestID == nil
                ? nil
                : workspaceFocusRequest.focusInputTimestamp
          }
        } else {
          focusCompletionAfterCommit = nil
          cursorWarpIsCurrentAfterCommit = nil
          focusRequestIDAfterCommit = nil
        }
        applyCurrentLayout(
          asynchronousPositions: true,
          updateVisibility: scrollAnimations.isEmpty,
          positionTimeoutSeconds: scrollAnimations.isEmpty ? 0.05 : 0.016,
          positionsOnly: speculativeRibbonNavigation,
          stagesVisibleBeforeParking: switchesWorkspace,
          focusWindowIDAfterCommit: focusWindowIDAfterCommit,
          focusInputTimestampAfterCommit:
            workspaceFocusRequest?.focusInputTimestamp,
          cursorWarpInputTimestampAfterCommit:
            workspaceFocusRequest?.cursorWarpInputTimestamp,
          focusCompletionAfterCommit: focusCompletionAfterCommit,
          cursorWarpIsCurrentAfterCommit:
            cursorWarpIsCurrentAfterCommit,
          focusRequestIDAfterCommit: focusRequestIDAfterCommit,
          source: switchesWorkspace ? "workspace-command" : "command"
        )
      }
      if !switchesWorkspace,
        let monitorID = activeMonitorID ?? state.monitors.first?.id,
        let sourceWorkspaceID = previousWorkspaceID,
        let selected = state.selectedWindowID(on: monitorID),
        commandShouldFocusWindow(
          command,
          previousSelectedWindowID: previouslySelectedWindowID,
          selectedWindowID: selected,
          selectedFloatingWindowID: state.selectedFloatingWindowID(on: monitorID)
        )
      {
        if focusIsReady(on: monitorID, targetWindowID: selected) {
          commitCommandFocus(
            selected,
            previousSelectedWindowID: previouslySelectedWindowID,
            monitorID: monitorID,
            sourceWorkspaceID: sourceWorkspaceID,
            commandGeneration: currentCommandGeneration,
            focusInputTimestamp: focusInputTimestamp,
            cursorWarpInputTimestamp: cursorWarpInputTimestamp
          )
        } else {
          pendingAnimatedFocus = PendingAnimatedFocus(
            windowID: selected,
            previousSelectedWindowID: previouslySelectedWindowID,
            monitorID: monitorID,
            sourceWorkspaceID: sourceWorkspaceID,
            commandGeneration: currentCommandGeneration,
            focusInputTimestamp: focusInputTimestamp,
            cursorWarpInputTimestamp: cursorWarpInputTimestamp
          )
        }
      } else if !switchesWorkspace,
        let monitorID = activeMonitorID ?? state.monitors.first?.id,
        let sourceWorkspaceID = pendingAnimatedFocus?.sourceWorkspaceID
          ?? submittedCommandFocus?.sourceWorkspaceID
          ?? previousWorkspaceID,
        let selected = state.selectedWindowID(on: monitorID),
        commandFocusIsPreserved(
          pendingWindowID: pendingAnimatedFocus?.windowID,
          submittedWindowID: submittedCommandFocus?.windowID,
          selectedWindowID: selected
        )
      {
        let previousCommandFocus = pendingAnimatedFocus
          ?? submittedCommandFocus
        pendingAnimatedFocus = PendingAnimatedFocus(
          windowID: selected,
          previousSelectedWindowID:
            previousCommandFocus?.previousSelectedWindowID,
          monitorID: monitorID,
          sourceWorkspaceID: sourceWorkspaceID,
          commandGeneration: currentCommandGeneration,
          focusInputTimestamp: focusInputTimestamp,
          cursorWarpInputTimestamp: cursorWarpInputTimestamp
        )
      }
      persistPlacements()
      updateMenuBar()
      lastCommandDurationMS =
        (ProcessInfo.processInfo.systemUptime - commandStartedAt) * 1_000
      performanceLogger.debug(
        "command applied command=\(rawCommand, privacy: .public) duration_ms=\(self.lastCommandDurationMS, format: .fixed(precision: 2)) animations=\(self.scrollAnimations.count)"
      )
      return .success()
    } catch {
      return .failure(String(describing: error))
    }
  }
}
