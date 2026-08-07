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
    guard
      let monitorID = focusWindowFromPointerWithoutScrolling(
        windowID,
        activeMonitorID: activeMonitorID,
        state: &state,
        viewports: viewportsByMonitor
      )
    else {
      pointerFocusIgnoredCount += 1
      return
    }

    pendingAnimatedFocus = nil
    pendingWindowRemovalFocusGuard = nil
    activeMonitorID = monitorID
    platform.focus(
      windowID,
      unlessUserInputAfter: invocation.timestamp
    )
    pointerFocusAppliedCount += 1
    needsDesktopSync = true
    updateMenuBar()
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

    guard
      let monitorID = focusWindowFromPointerWithoutScrolling(
        pendingPointerFocus.windowID,
        activeMonitorID: activeMonitorID,
        state: &state,
        viewports: viewportsByMonitor
      )
    else {
      return
    }

    pendingAnimatedFocus = nil
    pendingWindowRemovalFocusGuard = nil
    activeMonitorID = monitorID
    platform.focus(
      pendingPointerFocus.windowID,
      unlessUserInputAfter: pendingPointerFocus.timestamp
    )
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
    platform.focus(windowID)
    if let cursorWarpInputTimestamp {
      platform.warpCursor(
        to: windowID,
        unlessPointerMovedAfter: cursorWarpInputTimestamp
      )
    }
  }
}
