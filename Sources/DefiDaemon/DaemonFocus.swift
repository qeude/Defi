import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation

struct PendingPointerFocus {
  let windowID: WindowID
  let generation: UInt64
  let timestamp: TimeInterval
  let retryCount: Int

  init(
    windowID: WindowID,
    generation: UInt64,
    timestamp: TimeInterval,
    retryCount: Int = 0
  ) {
    self.windowID = windowID
    self.generation = generation
    self.timestamp = timestamp
    self.retryCount = retryCount
  }
}

@MainActor
extension Daemon {
  func handleEventTapReenabled(at timestamp: TimeInterval) {
    platform.invalidateInputAfterEventTapReenabled(at: timestamp)
    invalidatePointerFocusIntent()
    rearmPointerFocusTransition()
  }

  func handlePointerMotion(_ invocation: PointerMotionInvocation) {
    guard pointerFocusIntentIsCurrent(
      pointerTimestamp: invocation.timestamp,
      latestUserInputTimestamp: platform.userInputTracker.latestEventTimestamp
    ) else {
      pointerFocusIgnoredCount += 1
      return
    }
    pointerFocusObservedCount += 1
    let pointerWindowID = normalizedPointerWindowID(
      rawWindowID: invocation.windowID,
      hitTestedWindowID: platform.managedWindowID(
        at: invocation.location,
        retaining: lastPointerWindowID
      )
    )
    guard lastPointerWindowID != pointerWindowID else { return }
    lastPointerWindowID = pointerWindowID
    let logicalFocusWindowID = activeMonitorID.flatMap {
      state.selectedWindowID(on: $0)
    }
    let recoveryWindowID: WindowID?
    if !config.input.focusFollowsMouse {
      recoveryWindowID = logicalFocusWindowID
    } else if let pointerWindowID,
      state.monitorID(containing: pointerWindowID) != nil,
      pointerFocusIsReady(for: pointerWindowID)
    {
      let restoresNativeFocus = !platform.isWindowNativelyFocused(
        pointerWindowID
      )
      let targetAccepted = pointerFocusMonitorWithoutScrolling(
        pointerWindowID,
        activeMonitorID: activeMonitorID,
        state: state,
        viewports: viewportsByMonitor,
        acceptsAlreadySelectedWindow: restoresNativeFocus
      ) != nil
      recoveryWindowID = pointerFocusRecoveryWindowID(
        pointerWindowIsManaged: true,
        pointerWindowIsReady: true,
        targetAccepted: targetAccepted,
        logicalFocusWindowID: logicalFocusWindowID
      )
    } else {
      recoveryWindowID = pointerFocusRecoveryWindowID(
        pointerWindowIsManaged: pointerWindowID.flatMap {
          state.monitorID(containing: $0)
        } != nil,
        pointerWindowIsReady: pointerWindowID.map(pointerFocusIsReady) ?? false,
        targetAccepted: false,
        logicalFocusWindowID: logicalFocusWindowID
      )
    }
    invalidatePointerFocusIntent(recoveringTo: recoveryWindowID)
    let pointerGeneration = pointerFocusGeneration

    guard config.input.focusFollowsMouse, let windowID = pointerWindowID else {
      pointerFocusIgnoredCount += 1
      return
    }
    guard pointerFocusIsReady(for: windowID) else {
      pendingPointerFocus = PendingPointerFocus(
        windowID: windowID,
        generation: pointerGeneration,
        timestamp: invocation.timestamp
      )
      pointerFocusIgnoredCount += 1
      return
    }

    pendingPointerFocus = nil
    submitPointerFocus(
      windowID,
      generation: pointerGeneration,
      timestamp: invocation.timestamp
    )
  }

  func finishPendingPointerFocusIfReady() {
    guard let pendingPointerFocus else { return }
    guard pointerFocusRequestIsCurrent(
      requestGeneration: pendingPointerFocus.generation,
      currentGeneration: pointerFocusGeneration,
      pointerTimestamp: pendingPointerFocus.timestamp,
      latestUserInputTimestamp: platform.userInputTracker.latestEventTimestamp
    ) else {
      self.pendingPointerFocus = nil
      return
    }
    guard pointerFocusIsReady(for: pendingPointerFocus.windowID) else {
      return
    }
    self.pendingPointerFocus = nil

    let windowUnderPointerID = platform.managedWindowIDUnderPointer(
      retaining: pendingPointerFocus.windowID
    )
    guard pointerFocusRetryIsCurrent(
      pendingWindowID: pendingPointerFocus.windowID,
      windowUnderPointerID: windowUnderPointerID,
      requestGeneration: pendingPointerFocus.generation,
      currentGeneration: pointerFocusGeneration,
      pointerTimestamp: pendingPointerFocus.timestamp,
      latestUserInputTimestamp: platform.userInputTracker.latestEventTimestamp
    ) else {
      lastPointerWindowID = windowUnderPointerID
      return
    }

    submitPointerFocus(
      pendingPointerFocus.windowID,
      generation: pendingPointerFocus.generation,
      timestamp: pendingPointerFocus.timestamp,
      retryCount: pendingPointerFocus.retryCount
    )
  }

  private func submitPointerFocus(
    _ windowID: WindowID,
    generation: UInt64,
    timestamp: TimeInterval,
    retryCount: Int = 0
  ) {
    let restoresNativeFocus = !platform.isWindowNativelyFocused(windowID)
    let acceptedMonitorID = pointerFocusMonitorWithoutScrolling(
      windowID,
      activeMonitorID: activeMonitorID,
      state: state,
      viewports: viewportsByMonitor,
      acceptsAlreadySelectedWindow: restoresNativeFocus
    )
    guard let focusGuardTimestamp = pointerFocusGuardTimestamp(
      pointerTimestamp: timestamp,
      targetAccepted: acceptedMonitorID != nil
    ) else {
      pointerFocusIgnoredCount += 1
      return
    }
    platform.userInputTracker.record(timestamp: focusGuardTimestamp)

    pendingAnimatedFocus = nil
    submittedCommandFocus = nil
    pendingWorkspaceFocus = nil
    submittedWorkspaceFocusGeneration = nil
    pendingWindowRemovalFocusGuard = nil
    submittedPointerFocusRequestID = platform.focus(
      windowID,
      unlessUserInputAfter: timestamp,
      focusRecoveryFallbackWindowID: activeMonitorID.flatMap {
        state.selectedWindowID(on: $0)
      }
    ) { [weak self] result in
      guard let self else { return }
      guard pointerFocusRequestIsCurrent(
        requestGeneration: generation,
        currentGeneration: self.pointerFocusGeneration,
        pointerTimestamp: timestamp,
        latestUserInputTimestamp:
          self.platform.userInputTracker.latestEventTimestamp
      ) else {
        self.pointerFocusIgnoredCount += 1
        return
      }
      self.submittedPointerFocusRequestID = nil
      guard result == .completed || result == .completedWithoutMutation else {
        self.pointerFocusIgnoredCount += 1
        switch result {
        case .failed, .failedAfterMutation:
          self.retryPointerFocusIfCurrent(
            windowID,
            generation: generation,
            timestamp: timestamp,
            retryCount: retryCount
          )
        case .frameSuperseded, .superseded, .supersededAfterMutation,
          .cancelled,
          .cancelledAfterMutation,
          .cancelledAfterInputMutation:
          if cancelledPointerFocusShouldRearm(
            pointerTimestamp: timestamp,
            latestUserInputTimestamp:
              self.platform.userInputTracker.latestEventTimestamp
          ) {
            self.rearmPointerFocusTransition()
          }
        case .completed, .completedWithoutMutation:
          break
        }
        return
      }
      self.commitCompletedPointerFocus(
        windowID,
        generation: generation,
        timestamp: timestamp,
        acceptsAlreadySelectedWindow: restoresNativeFocus
      )
    }
  }

  private func commitCompletedPointerFocus(
    _ windowID: WindowID,
    generation: UInt64,
    timestamp: TimeInterval,
    acceptsAlreadySelectedWindow: Bool
  ) {
    guard pointerFocusRequestIsCurrent(
      requestGeneration: generation,
      currentGeneration: pointerFocusGeneration,
      pointerTimestamp: timestamp,
      latestUserInputTimestamp: platform.userInputTracker.latestEventTimestamp
    ) else {
      return
    }

    guard
      let monitorID = focusWindowFromPointerWithoutScrolling(
        windowID,
        activeMonitorID: activeMonitorID,
        state: &state,
        viewports: viewportsByMonitor,
        acceptsAlreadySelectedWindow: acceptsAlreadySelectedWindow
      )
    else {
      return
    }

    activeMonitorID = monitorID
    pointerFocusAppliedCount += 1
    needsDesktopSync = true
    updateMenuBar()
  }

  private func retryPointerFocusIfCurrent(
    _ windowID: WindowID,
    generation: UInt64,
    timestamp: TimeInterval,
    retryCount: Int
  ) {
    let windowUnderPointerID = platform.managedWindowIDUnderPointer(
      retaining: windowID
    )
    let intentCurrent = pointerFocusRetryIsCurrent(
      pendingWindowID: windowID,
      windowUnderPointerID: windowUnderPointerID,
      requestGeneration: generation,
      currentGeneration: pointerFocusGeneration,
      pointerTimestamp: timestamp,
      latestUserInputTimestamp: platform.userInputTracker.latestEventTimestamp
    )
    guard
      let nextRetryCount = nextPointerFocusRetryCount(
        currentRetryCount: retryCount,
        maximumRetryCount: 1,
        intentCurrent: intentCurrent
      )
    else {
      needsDesktopSync = true
      return
    }

    pendingPointerFocus = PendingPointerFocus(
      windowID: windowID,
      generation: generation,
      timestamp: timestamp,
      retryCount: nextRetryCount
    )
  }

  private func rearmPointerFocusTransition() {
    lastPointerWindowID = nil
    hotKeys?.resetPointerWindowTransition()
  }

  func invalidatePointerFocusIntent(recoveringTo windowID: WindowID? = nil) {
    pointerFocusGeneration &+= 1
    pendingPointerFocus = nil
    if let submittedPointerFocusRequestID {
      platform.cancelFocus(
        submittedPointerFocusRequestID,
        recoveringTo: windowID
      )
      self.submittedPointerFocusRequestID = nil
    }
  }

  private func pointerFocusIsReady(for windowID: WindowID) -> Bool {
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
      ),
      deferredSlowMonitorIDs: Set(
        deferredSlowWindowIDs.compactMap {
          state.monitorID(containing: $0)
        }
      )
    )
  }

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
    platform.focus(
      windowID,
      unlessUserInputAfter: focusInputTimestamp,
      cursorWarpUnlessPointerMovedAfter: committedCursorWarpInputTimestamp
    ) { [weak self] result in
      guard let self else { return }
      guard commandFocusCompletionIsCurrent(
        submittedWindowID: self.submittedCommandFocus?.windowID,
        submittedGeneration:
          self.submittedCommandFocus?.commandGeneration,
        completedWindowID: request.windowID,
        completedGeneration: request.commandGeneration
      ) else { return }
      self.submittedCommandFocus = nil
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
  }

  func commitWorkspaceCommandFocus(
    result: NativeFocusResult,
    request: PendingWorkspaceFocus
  ) {
    guard pendingWorkspaceFocus?.commandGeneration == request.commandGeneration
    else { return }
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
