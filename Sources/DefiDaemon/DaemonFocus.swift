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
        rawWindowID: invocation.windowID,
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
      guard focusIsReady(on: request.monitorID, targetWindowID: restored.windowID) else {
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
      if focusIsReady(
        on: request.monitorID,
        targetWindowID: request.requestedWindowID
      ) {
        finishPendingWorkspaceFocusIfReady()
      }
    }
  }

}
