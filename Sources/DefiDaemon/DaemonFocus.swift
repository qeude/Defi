import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation

struct PendingPointerFocus {
  let windowID: WindowID
  let timestamp: TimeInterval
  let retryCount: Int

  init(
    windowID: WindowID,
    timestamp: TimeInterval,
    retryCount: Int = 0
  ) {
    self.windowID = windowID
    self.timestamp = timestamp
    self.retryCount = retryCount
  }
}

@MainActor
extension Daemon {
  func handlePointerMotion(_ invocation: PointerMotionInvocation) {
    guard pointerFocusIntentIsCurrent(
      pointerTimestamp: invocation.timestamp,
      latestUserInputTimestamp: platform.userInputTracker.latestEventTimestamp
    ) else {
      pointerFocusIgnoredCount += 1
      return
    }
    pointerFocusObservedCount += 1
    let pointerWindowID = invocation.windowID
      ?? platform.managedWindowID(
        at: invocation.location,
        retaining: lastPointerWindowID
    )
    guard lastPointerWindowID != pointerWindowID else { return }
    platform.userInputTracker.record(timestamp: invocation.timestamp)
    lastPointerWindowID = pointerWindowID

    guard config.input.focusFollowsMouse, let windowID = pointerWindowID else {
      pendingPointerFocus = nil
      pointerFocusIgnoredCount += 1
      return
    }
    guard pointerFocusIsReady(for: windowID) else {
      pendingPointerFocus = PendingPointerFocus(
        windowID: windowID,
        timestamp: invocation.timestamp
      )
      pointerFocusIgnoredCount += 1
      return
    }

    pendingPointerFocus = nil
    submitPointerFocus(windowID, timestamp: invocation.timestamp)
  }

  func finishPendingPointerFocusIfReady() {
    guard let pendingPointerFocus,
      pointerFocusIsReady(for: pendingPointerFocus.windowID)
    else { return }
    self.pendingPointerFocus = nil

    let windowUnderPointerID = platform.managedWindowIDUnderPointer(
      retaining: pendingPointerFocus.windowID
    )
    guard pointerFocusRetryIsCurrent(
      pendingWindowID: pendingPointerFocus.windowID,
      windowUnderPointerID: windowUnderPointerID,
      pointerTimestamp: pendingPointerFocus.timestamp,
      latestUserInputTimestamp: platform.userInputTracker.latestEventTimestamp
    ) else {
      lastPointerWindowID = windowUnderPointerID
      return
    }

    submitPointerFocus(
      pendingPointerFocus.windowID,
      timestamp: pendingPointerFocus.timestamp,
      retryCount: pendingPointerFocus.retryCount
    )
  }

  private func submitPointerFocus(
    _ windowID: WindowID,
    timestamp: TimeInterval,
    retryCount: Int = 0
  ) {
    let restoresNativeFocus = !platform.isWindowNativelyFocused(windowID)
    guard pointerFocusMonitorWithoutScrolling(
      windowID,
      activeMonitorID: activeMonitorID,
      state: state,
      viewports: viewportsByMonitor,
      acceptsAlreadySelectedWindow: restoresNativeFocus
    ) != nil else {
      pointerFocusIgnoredCount += 1
      return
    }

    pendingAnimatedFocus = nil
    pendingWorkspaceFocus = nil
    submittedWorkspaceFocusGeneration = nil
    pendingWindowRemovalFocusGuard = nil
    platform.focus(
      windowID,
      unlessUserInputAfter: timestamp
    ) { [weak self] result in
      guard let self else { return }
      guard result == .completed || result == .completedWithoutMutation else {
        self.pointerFocusIgnoredCount += 1
        switch result {
        case .failed, .failedAfterMutation:
          self.retryPointerFocusIfCurrent(
            windowID,
            timestamp: timestamp,
            retryCount: retryCount
          )
        case .superseded, .cancelled, .cancelledAfterMutation,
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
        timestamp: timestamp,
        acceptsAlreadySelectedWindow: restoresNativeFocus
      )
    }
  }

  private func commitCompletedPointerFocus(
    _ windowID: WindowID,
    timestamp: TimeInterval,
    acceptsAlreadySelectedWindow: Bool
  ) {
    guard pointerFocusIntentIsCurrent(
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
    timestamp: TimeInterval,
    retryCount: Int
  ) {
    let windowUnderPointerID = platform.managedWindowIDUnderPointer(
      retaining: windowID
    )
    let intentCurrent = pointerFocusRetryIsCurrent(
      pendingWindowID: windowID,
      windowUnderPointerID: windowUnderPointerID,
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
      rearmPointerFocusTransition()
      return
    }

    pendingPointerFocus = PendingPointerFocus(
      windowID: windowID,
      timestamp: timestamp,
      retryCount: nextRetryCount
    )
  }

  private func rearmPointerFocusTransition() {
    lastPointerWindowID = nil
    hotKeys?.resetPointerWindowTransition()
  }

  private func pointerFocusIsReady(for windowID: WindowID) -> Bool {
    guard let targetMonitorID = state.monitorID(containing: windowID) else {
      return false
    }
    return pointerFocusMonitorIsReady(
      targetMonitorID: targetMonitorID,
      scrollingMonitorIDs: Set(scrollAnimations.keys.map(\.monitorID)),
      animatedFrameMonitorIDs: Set(
        platform.pendingAnimatedFrameWindowIDs.compactMap {
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

  func commitCommandFocus(
    _ windowID: WindowID,
    previousSelectedWindowID: WindowID?,
    monitorID: MonitorID,
    sourceWorkspaceID: WorkspaceID,
    commandGeneration: UInt64,
    focusInputTimestamp: TimeInterval,
    cursorWarpInputTimestamp: TimeInterval?
  ) {
    platform.focus(
      windowID,
      unlessUserInputAfter: focusInputTimestamp,
      cursorWarpUnlessPointerMovedAfter: cursorWarpInputTimestamp
    ) { [weak self] result in
      guard let self,
        let fallbackWindowID = commandFocusCancellationFallback(
          cancelledBeforeMutation: result == .cancelled,
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
    pendingWorkspaceFocus = nil
    submittedWorkspaceFocusGeneration = nil
    guard let monitor = state.monitors.first(where: { $0.id == request.monitorID }),
      let fallbackWorkspaceID = workspaceFocusCancellationFallback(
        cancelledBeforeMutation: result == .cancelled,
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
