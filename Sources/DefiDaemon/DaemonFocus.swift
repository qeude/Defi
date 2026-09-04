import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation

@MainActor
extension Daemon {
  func handleEventTapReenabled(at timestamp: TimeInterval) {
    platform.invalidateInputAfterEventTapReenabled(at: timestamp)
    focus.discardDisplacedFocus()
    invalidatePointerFocusIntent()
    rearmPointerFocusTransition()
    needsDesktopSync = true
    scheduleTick()
  }

  func handlePointerMotion(_ invocation: PointerMotionInvocation) {
    defer {
      if pendingPointerFocus != nil { scheduleTick() }
    }
    if pointerRawWindowTransitionRequiresRefresh(
      previousRawWindowID: lastRawPointerWindowID,
      currentRawWindowID: invocation.windowID
    ) {
      platform.invalidatePointerHitTestCache()
    }
    lastRawPointerWindowID = invocation.windowID
    guard
      pointerFocusIntentIsCurrent(
        pointerTimestamp: invocation.timestamp,
        latestUserInputTimestamp: platform.userInputTracker.latestEventTimestamp
      )
    else {
      invalidatePointerFocusIntent()
      rearmPointerFocusTransition()
      pointerFocusIgnoredCount += 1
      return
    }
    let pointerWindowID = normalizedPointerWindowID(
      rawWindowID: invocation.windowID,
      hitTestedWindowID: platform.managedWindowID(
        at: invocation.location,
        rawWindowID: invocation.windowID,
        retaining: lastPointerWindowID
      )
    )
    guard lastPointerWindowID != pointerWindowID else {
      pointerFocusObservedCount += 1
      return
    }
    let ready = pointerWindowID.map(pointerFocusIsReady) ?? false
    let restoresNativeFocus =
      config.input.focusFollowsMouse && ready
      && pointerWindowID.map { !platform.isWindowNativelyFocused($0) } == true
    let effect = focus.observePointer(
      windowID: pointerWindowID,
      timestamp: invocation.timestamp,
      latestInputTimestamp: platform.userInputTracker.latestEventTimestamp,
      ready: ready,
      restoresNativeFocus: restoresNativeFocus,
      activeMonitorID: activeMonitorID,
      viewports: viewportsByMonitor,
      input: config.input,
      state: state
    )
    switch effect {
    case .stale:
      cancelSubmittedPointerFocus()
      rearmPointerFocusTransition()
      pointerFocusIgnoredCount += 1
    case .redundant:
      pointerFocusObservedCount += 1
    case .changed(let recovery, let request):
      pointerFocusObservedCount += 1
      cancelSubmittedPointerFocus(recoveringTo: recovery)
      if let request {
        submitPointerFocus(
          request.windowID, generation: request.generation,
          timestamp: request.timestamp, retryCount: request.retryCount
        )
      } else {
        pointerFocusIgnoredCount += 1
      }
    }
  }

  func finishPendingPointerFocusIfReady() {
    guard let pendingPointerFocus else { return }
    let ready = pointerFocusIsReady(for: pendingPointerFocus.windowID)
    let windowUnderPointerID =
      ready
      ? platform.managedWindowIDUnderPointer(retaining: pendingPointerFocus.windowID)
      : nil
    switch focus.resumePointer(
      latestInputTimestamp: platform.userInputTracker.latestEventTimestamp,
      ready: ready,
      windowUnderPointerID: windowUnderPointerID
    ) {
    case .waiting:
      return
    case .stale:
      cancelSubmittedPointerFocus()
      rearmPointerFocusTransition()
    case .ready(let request):
      submitPointerFocus(
        request.windowID, generation: request.generation,
        timestamp: request.timestamp, retryCount: request.retryCount
      )
    }
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
    guard
      let focusGuardTimestamp = pointerFocusGuardTimestamp(
        pointerTimestamp: timestamp,
        targetAccepted: acceptedMonitorID != nil
      )
    else {
      pointerFocusIgnoredCount += 1
      return
    }
    platform.userInputTracker.record(timestamp: focusGuardTimestamp)

    let request = PendingPointerFocus(
      windowID: windowID, generation: generation, timestamp: timestamp, retryCount: retryCount
    )
    let submission = focus.submitPointer(request)
    invalidateSubmittedCommandFocus()
    invalidateSubmittedWorkspaceFocus()
    pendingWindowRemovalFocusGuard = nil
    let requestID = platform.focus(
      windowID,
      unlessUserInputAfter: timestamp,
      focusRecoveryFallbackWindowID: activeMonitorID.flatMap {
        state.selectedWindowID(on: $0)
      },
      completion: { [weak self] result in
        guard let self else { return }
        let windowUnderPointerID =
          result == .failed || result == .failedAfterMutation
          ? self.platform.managedWindowIDUnderPointer(retaining: windowID)
          : nil
        let effect = self.focus.completePointer(
          request,
          submission: submission,
          result: result,
          latestInputTimestamp: self.platform.userInputTracker.latestEventTimestamp,
          windowUnderPointerID: windowUnderPointerID,
          commandGeneration: self.commandGeneration,
          activeMonitorID: self.activeMonitorID,
          viewports: self.viewportsByMonitor,
          maximumScrollAmount: self.config.input.focusFollowsMouseMaxScrollAmount,
          acceptsAlreadySelectedWindow: restoresNativeFocus,
          state: &self.state
        )
        guard effect != .stale else {
          self.pointerFocusIgnoredCount += 1
          return
        }
        self.submittedPointerFocusRequestID = nil
        self.submittedPointerFocusTimestamp = nil
        switch effect {
        case .stale:
          break
        case .ignored(let rearm):
          self.pointerFocusIgnoredCount += 1
          if rearm { self.rearmPointerFocusTransition() }
        case .recover(let previousSelection):
          self.recoverPointerFocus(to: previousSelection, unlessUserInputAfter: timestamp)
        case .selectionChanged(let monitorID):
          self.activeMonitorID = monitorID
          self.pointerFocusAppliedCount += 1
          self.platform.commitWindowBorderSelection(windowID)
          self.startScrollAnimationsIfNeeded()
          _ = self.dispatchScrollAnimationIfNeeded()
          self.needsDesktopSync = true
          self.updateMenuBar()
        case .resumeDisplaced:
          self.pointerFocusIgnoredCount += 1
          self.needsDesktopSync = true
          self.finishPendingAnimatedFocusIfReady()
          self.finishPendingWorkspaceFocusIfReady()
        case .refresh:
          self.pointerFocusIgnoredCount += 1
          self.needsDesktopSync = true
        }
      }
    )
    submittedPointerFocusRequestID = requestID
    submittedPointerFocusTimestamp = requestID == nil ? nil : timestamp
  }

}
