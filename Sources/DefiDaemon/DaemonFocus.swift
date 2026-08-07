import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation

struct PendingPointerFocus {
  let windowID: WindowID
  let timestamp: TimeInterval
}

@MainActor
extension Daemon {
  func handlePointerMotion(_ invocation: PointerMotionInvocation) {
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
    guard pointerFocusIsReady else {
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
    guard pointerFocusIsReady, let pendingPointerFocus else { return }
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
      timestamp: pendingPointerFocus.timestamp
    )
  }

  private func submitPointerFocus(
    _ windowID: WindowID,
    timestamp: TimeInterval
  ) {
    guard pointerFocusMonitorWithoutScrolling(
      windowID,
      activeMonitorID: activeMonitorID,
      state: state,
      viewports: viewportsByMonitor
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
        return
      }
      self.commitCompletedPointerFocus(windowID, timestamp: timestamp)
    }
  }

  private func commitCompletedPointerFocus(
    _ windowID: WindowID,
    timestamp: TimeInterval
  ) {
    let windowUnderPointerID = platform.managedWindowIDUnderPointer(
      retaining: windowID
    )
    guard pointerFocusRetryIsCurrent(
      pendingWindowID: windowID,
      windowUnderPointerID: windowUnderPointerID,
      pointerTimestamp: timestamp,
      latestUserInputTimestamp: platform.userInputTracker.latestEventTimestamp
    ) else {
      lastPointerWindowID = windowUnderPointerID
      return
    }

    guard
      let monitorID = focusWindowFromPointerWithoutScrolling(
        windowID,
        activeMonitorID: activeMonitorID,
        state: &state,
        viewports: viewportsByMonitor
      )
    else {
      return
    }

    activeMonitorID = monitorID
    pointerFocusAppliedCount += 1
    needsDesktopSync = true
    updateMenuBar()
  }

  private var pointerFocusIsReady: Bool {
    scrollAnimations.isEmpty
      && !platform.hasPendingAnimatedFrameWrites
      && deferredSlowWindowIDs.isEmpty
  }

  func commitCommandFocus(
    _ windowID: WindowID,
    cursorWarpInputTimestamp: TimeInterval?
  ) {
    platform.focus(
      windowID,
      cursorWarpUnlessPointerMovedAfter: cursorWarpInputTimestamp
    )
  }
}
