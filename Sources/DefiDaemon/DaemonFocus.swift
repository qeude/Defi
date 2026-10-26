import CoreGraphics
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation

@NavigationActor
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
    guard !shouldShutdown, !restorationInFlight else { return }
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
        latestUserInputTimestamp: platform.userInputTracker.latestEventTimestamp,
        latestPointerMotionTimestamp: platform.pointerMotionTracker.latestTimestamp
      )
    else {
      invalidatePointerFocusIntent()
      rearmPointerFocusTransition()
      pointerFocusIgnoredCount += 1
      return
    }
    pointerHitTestTask?.cancel()
    let generation = commandGeneration
    let session = desktopSessionGeneration
    let previousWindowID = lastPointerWindowID
    let delayMS = config.input.focusFollowsMouseDelayMS
    pointerHitTestTask = Task { [weak self] in
      // Each motion cancels the previous task, so focus waits for the pointer to rest.
      guard await pointerFocusRestDelayElapsed(milliseconds: delayMS), let self else { return }
      let hit = await platform.managedWindowID(
        at: invocation.location, rawWindowID: invocation.windowID, retaining: previousWindowID
      )
      guard !Task.isCancelled, desktopSessionActive, !shouldShutdown, !restorationInFlight,
        desktopSessionGeneration == session, commandGeneration == generation,
        pointerFocusIntentIsCurrent(pointerTimestamp: invocation.timestamp,
          latestUserInputTimestamp: platform.userInputTracker.latestEventTimestamp,
          latestPointerMotionTimestamp: platform.pointerMotionTracker.latestTimestamp)
      else { return }
      applyPointerMotion(invocation, pointerWindowID: normalizedPointerWindowID(
        rawWindowID: invocation.windowID, hitTestedWindowID: hit
      ))
    }
  }

  private func applyPointerMotion(_ invocation: PointerMotionInvocation, pointerWindowID: WindowID?) {
    defer { if pendingPointerFocus != nil { scheduleTick() } }
    // Left unrecorded, so the window under the pointer focuses on the next motion
    // once the popup closes.
    if config.input.focusFollowsMouse, platform.nativeFocusIsAppPopup {
      pointerFocusIgnoredCount += 1
      return
    }
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

  /// A click on another window moves the ribbon at the press, as the keyboard does, instead
  /// of after the button's release, macOS's activation and a read of the app's windows.
  /// macOS focuses the window itself; its focus event then finds it already selected.
  /// shortcut: a press macOS never turns into focus (a first-mouse drag out of a background
  /// window) leaves the selection ahead of native focus until the next focus change; give it
  /// back after the release if that proves common.
  func focusClickedWindow(_ windowID: WindowID) {
    selectNativeTarget(windowID, trace: "click-focus",
      inputAt: platform.userInputTracker.snapshot.latestFocusIntent?.timestamp)
  }

  /// Command-Tab or the Dock brought this window's app forward. Defi's own focus work
  /// activates apps too: after it focused this app lately, or a newer command, the usual
  /// path decides.
  func focusActivatedWindow(_ windowID: WindowID, activatedAt timestamp: TimeInterval) {
    let input = platform.userInputTracker.snapshot
    guard input.applicationActivation?.timestamp == timestamp,
      timestamp > max(latestCommandInputTimestamp, input.latestCapturedCommandTimestamp),
      let processID = state.windows[windowID]?.processID,
      !platform.internalFocusIsRecent(processID: processID),
      !CGEventSource.buttonState(.combinedSessionState, button: .left)
    else { return }
    selectNativeTarget(windowID, trace: "activation-focus", inputAt: timestamp)
  }

  /// Selects a window the user chose natively and moves the ribbon to it on the keyboard's
  /// path. Only a window on an active workspace: a workspace switch keeps the usual path.
  private func selectNativeTarget(_ windowID: WindowID, trace: String, inputAt: TimeInterval?) {
    guard !shouldShutdown, !restorationInFlight, !overviewState.isOpen,
      !platform.nativeFocusIsAppPopup,
      let monitorID = focusWindowFromPointer(
        windowID, activeMonitorID: activeMonitorID, state: &state, viewports: viewportsByMonitor)
    else { return }
    focus.interrupt()
    platform.invalidateFocusRecovery(recoveringTo: windowID)
    invalidateSubmittedCommandFocus(recoveringTo: windowID)
    invalidateSubmittedWorkspaceFocus(recoveringTo: windowID)
    cancelSubmittedPointerFocus(recoveringTo: windowID)
    activeMonitorID = monitorID
    platform.recordPerformanceTrace("\(trace) window=\(windowID.rawValue) inputAgeMs=\(inputAt.map { String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - $0) * 1_000) } ?? "none")")
    platform.commitWindowBorderSelection(windowID)
    startScrollAnimationsIfNeeded()
    _ = dispatchScrollAnimationIfNeeded()
    needsDesktopSync = true
    updateMenuBar()
  }

  func finishPendingPointerFocusIfReady() {
    guard let pendingPointerFocus, pointerResumeTask == nil,
      pointerFocusIsReady(for: pendingPointerFocus.windowID) else { return }
    pointerResumeTask = Task { [weak self] in
      guard let self else { return }
      defer { if !Task.isCancelled { pointerResumeTask = nil } }
      let hit = await platform.managedWindowIDUnderPointer(retaining: pendingPointerFocus.windowID)
      guard !Task.isCancelled, desktopSessionActive, !shouldShutdown, !restorationInFlight,
        pointerFocusIntentIsCurrent(pointerTimestamp: pendingPointerFocus.timestamp,
          latestUserInputTimestamp: platform.userInputTracker.latestEventTimestamp,
          latestPointerMotionTimestamp: platform.pointerMotionTracker.latestTimestamp),
        self.pendingPointerFocus == pendingPointerFocus else { return }
      resumePointerFocus(windowUnderPointerID: hit)
    }
  }

  private func resumePointerFocus(windowUnderPointerID: WindowID?) {
    guard let pendingPointerFocus else { return }
    let ready = pointerFocusIsReady(for: pendingPointerFocus.windowID)
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
        Task { [weak self] in
          guard let self else { return }
          let windowUnderPointerID: WindowID?
          if result == .failed || result == .failedAfterMutation {
            windowUnderPointerID = await self.platform.managedWindowIDUnderPointer(retaining: windowID)
          } else {
            windowUnderPointerID = nil
          }
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
      }
    )
    submittedPointerFocusRequestID = requestID
    submittedPointerFocusTimestamp = requestID == nil ? nil : timestamp
  }

}
