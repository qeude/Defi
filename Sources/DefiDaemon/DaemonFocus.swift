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
    displacedPointerFocusRecovery = nil
    invalidatePointerFocusIntent()
    rearmPointerFocusTransition()
    needsDesktopSync = true
  }

  func handlePointerMotion(_ invocation: PointerMotionInvocation) {
    if pointerRawWindowTransitionRequiresRefresh(
      previousRawWindowID: lastRawPointerWindowID,
      currentRawWindowID: invocation.windowID
    ) {
      platform.invalidatePointerHitTestCache()
    }
    lastRawPointerWindowID = invocation.windowID
    guard pointerFocusIntentIsCurrent(
      pointerTimestamp: invocation.timestamp,
      latestUserInputTimestamp: platform.userInputTracker.latestEventTimestamp
    ) else {
      invalidatePointerFocusIntent()
      rearmPointerFocusTransition()
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
      let targetAccepted = pointerFocusMonitor(
        pointerWindowID,
        activeMonitorID: activeMonitorID,
        state: state,
        viewports: viewportsByMonitor,
        maximumScrollAmount:
          config.input.focusFollowsMouseMaxScrollAmount,
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
      invalidatePointerFocusIntent()
      rearmPointerFocusTransition()
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
      rearmPointerFocusTransition()
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
    let acceptedMonitorID = pointerFocusMonitor(
      windowID,
      activeMonitorID: activeMonitorID,
      state: state,
      viewports: viewportsByMonitor,
      maximumScrollAmount: config.input.focusFollowsMouseMaxScrollAmount,
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

    if let displaced = pendingAnimatedFocus.map({
      DisplacedPointerFocusRecovery.command($0, timestamp: timestamp)
    })
      ?? submittedCommandFocus.map({
        DisplacedPointerFocusRecovery.command($0, timestamp: timestamp)
      })
      ?? pendingWorkspaceFocus.map({
        DisplacedPointerFocusRecovery.workspace($0, timestamp: timestamp)
      })
    {
      displacedPointerFocusRecovery = displaced
    }
    pendingAnimatedFocus = nil
    invalidateSubmittedCommandFocus()
    invalidateSubmittedWorkspaceFocus()
    pendingWorkspaceFocus = nil
    submittedWorkspaceFocusGeneration = nil
    pendingWindowRemovalFocusGuard = nil
    let requestID = platform.focus(
      windowID,
      unlessUserInputAfter: timestamp,
      focusRecoveryFallbackWindowID: activeMonitorID.flatMap {
        state.selectedWindowID(on: $0)
      },
      completion: { [weak self] result in
        guard let self else { return }
        guard pointerFocusRequestIsCurrent(
          requestGeneration: generation,
          currentGeneration: self.pointerFocusGeneration,
          pointerTimestamp: timestamp,
          latestUserInputTimestamp:
            self.platform.userInputTracker.latestEventTimestamp
        ) else {
          guard self.submittedPointerFocusGeneration == generation else {
            self.pointerFocusIgnoredCount += 1
            return
          }
          self.submittedPointerFocusRequestID = nil
          self.submittedPointerFocusTimestamp = nil
          self.submittedPointerFocusGeneration = nil
          self.rearmPointerFocusTransition()
          self.pointerFocusIgnoredCount += 1
          return
        }
        self.submittedPointerFocusRequestID = nil
        self.submittedPointerFocusTimestamp = nil
        self.submittedPointerFocusGeneration = nil
        guard result == .completed || result == .completedWithoutMutation else {
          self.pointerFocusIgnoredCount += 1
          switch result {
          case .failed, .failedAfterMutation:
            self.retryPointerFocusIfCurrent(
              windowID,
              generation: generation,
              timestamp: timestamp,
              retryCount: retryCount,
              restoresDisplacedFocus: result == .failed
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
    )
    submittedPointerFocusRequestID = requestID
    submittedPointerFocusTimestamp = requestID == nil ? nil : timestamp
    submittedPointerFocusGeneration = requestID == nil ? nil : generation
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

    let logicalFocusWindowID = activeMonitorID.flatMap {
      state.selectedWindowID(on: $0)
    }
    guard
      let monitorID = focusWindowFromPointer(
        windowID,
        activeMonitorID: activeMonitorID,
        state: &state,
        viewports: viewportsByMonitor,
        maximumScrollAmount:
          config.input.focusFollowsMouseMaxScrollAmount,
        acceptsAlreadySelectedWindow: acceptsAlreadySelectedWindow
      )
    else {
      recoverPointerFocus(
        to: logicalFocusWindowID,
        unlessUserInputAfter: timestamp
      )
      return
    }

    displacedPointerFocusRecovery = nil
    activeMonitorID = monitorID
    pointerFocusAppliedCount += 1
    platform.commitWindowBorderSelection(windowID)
    startScrollAnimationsIfNeeded()
    _ = dispatchScrollAnimationIfNeeded()
    needsDesktopSync = true
    updateMenuBar()
  }

  private func retryPointerFocusIfCurrent(
    _ windowID: WindowID,
    generation: UInt64,
    timestamp: TimeInterval,
    retryCount: Int,
    restoresDisplacedFocus: Bool
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
      if restoresDisplacedFocus, intentCurrent {
        restoreDisplacedPointerFocus(at: timestamp)
      } else {
        displacedPointerFocusRecovery = nil
      }
      return
    }

    pendingPointerFocus = PendingPointerFocus(
      windowID: windowID,
      generation: generation,
      timestamp: timestamp,
      retryCount: nextRetryCount
    )
  }

  private func restoreDisplacedPointerFocus(at timestamp: TimeInterval) {
    guard let recovery = displacedPointerFocusRecovery else { return }
    displacedPointerFocusRecovery = nil

    switch recovery {
    case .command(let request, _):
      guard commandGeneration == request.commandGeneration,
        state.selectedWindowID(on: request.monitorID) == request.windowID
      else { return }
      let restored = PendingAnimatedFocus(
        windowID: request.windowID,
        previousSelectedWindowID: request.previousSelectedWindowID,
        monitorID: request.monitorID,
        sourceWorkspaceID: request.sourceWorkspaceID,
        commandGeneration: commandGeneration,
        focusInputTimestamp: timestamp,
        cursorWarpInputTimestamp: nil,
        retryCount: request.retryCount
      )
      guard focusIsReady(on: request.monitorID) else {
        pendingAnimatedFocus = restored
        return
      }
      commitCommandFocus(
        restored.windowID,
        previousSelectedWindowID: restored.previousSelectedWindowID,
        monitorID: restored.monitorID,
        sourceWorkspaceID: restored.sourceWorkspaceID,
        commandGeneration: restored.commandGeneration,
        focusInputTimestamp: restored.focusInputTimestamp,
        cursorWarpInputTimestamp: restored.cursorWarpInputTimestamp,
        retryCount: restored.retryCount
      )

    case .workspace(let request, _):
      guard commandGeneration == request.commandGeneration,
        state.monitors.first(where: { $0.id == request.monitorID })?.activeWorkspace
          == request.requestedWorkspaceID,
        state.selectedWindowID(on: request.monitorID) == request.requestedWindowID
      else { return }
      pendingWorkspaceFocus = PendingWorkspaceFocus(
        monitorID: request.monitorID,
        requestedWorkspaceID: request.requestedWorkspaceID,
        previousWorkspaceID: request.previousWorkspaceID,
        requestedWindowID: request.requestedWindowID,
        restoresPreviousWorkspaceOnCancellation:
          request.restoresPreviousWorkspaceOnCancellation,
        commandGeneration: commandGeneration,
        focusInputTimestamp: timestamp,
        cursorWarpInputTimestamp: nil,
        retryCount: request.retryCount
      )
      submittedWorkspaceFocusGeneration = nil
      if focusIsReady(on: request.monitorID) {
        finishPendingWorkspaceFocusIfReady()
      }
    }
  }

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
    if let recoveryRequestID = submittedPointerFocusRecoveryRequestID {
      _ = platform.cancelFocus(recoveryRequestID, recoveringTo: windowID)
      submittedPointerFocusRecoveryRequestID = nil
      submittedPointerFocusRecoveryGeneration = nil
    }
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

  private func recoverPointerFocus(
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
        self.submittedPointerFocusRecoveryGeneration = nil
      }
    )
    submittedPointerFocusRecoveryRequestID = recoveryID
    submittedPointerFocusRecoveryGeneration =
      recoveryID == nil ? nil : recoveryGeneration
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
