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
    pendingWindowRemovalFocusGuard = nil
    platform.focus(
      windowID,
      unlessUserInputAfter: timestamp
    ) { [weak self] result in
      guard let self else { return }
      guard result == .completed else {
        self.pointerFocusIgnoredCount += 1
        switch result {
        case .failed, .failedAfterMutation:
          self.retryPointerFocusIfCurrent(
            windowID,
            timestamp: timestamp,
            retryCount: retryCount
          )
        case .cancelled, .cancelledAfterMutation:
          self.rearmPointerFocusTransition()
        case .completed:
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
    cursorWarpInputTimestamp: TimeInterval?
  ) {
    platform.focus(
      windowID,
      unlessUserInputAfter: cursorWarpInputTimestamp,
      cursorWarpUnlessPointerMovedAfter: cursorWarpInputTimestamp
    )
  }
}
