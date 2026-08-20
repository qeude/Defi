import AppKit
import DefiConfig
import DefiCore
import DefiIPC
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation
import OSLog

struct ScrollAnimationKey: Hashable {
  let monitorID: MonitorID
  let workspaceID: WorkspaceID
}

struct ScrollAnimation {
  var target: Double
  var velocity: Double
  var lastStepAt: TimeInterval
  var startedAt: TimeInterval
}

@MainActor
extension Daemon {
  func startScrollAnimationsIfNeeded() {
    let duration = TimeInterval(config.animation.durationMS) / 1_000
    let now = ProcessInfo.processInfo.systemUptime
    for monitorIndex in state.monitors.indices {
      let activeWorkspace = state.monitors[monitorIndex].activeWorkspace
      for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
        let key = ScrollAnimationKey(
          monitorID: state.monitors[monitorIndex].id,
          workspaceID: state.monitors[monitorIndex].workspaces[workspaceIndex].id
        )
        let current = state.monitors[monitorIndex].workspaces[workspaceIndex].scrollOffset
        let target = state.monitors[monitorIndex].workspaces[workspaceIndex].targetScrollOffset
        guard state.monitors[monitorIndex].workspaces[workspaceIndex].id == activeWorkspace,
          config.animation.enabled,
          duration > 0,
          abs(current - target) >= 0.000_1
        else {
          state.monitors[monitorIndex].workspaces[workspaceIndex].scrollOffset = target
          scrollAnimations[key] = nil
          continue
        }
        if var animation = scrollAnimations[key] {
          if animation.target != target {
            animation.target = target
            animation.lastStepAt = now
            animation.startedAt = now
            scrollAnimations[key] = animation
          }
        } else {
          scrollAnimations[key] = ScrollAnimation(
            target: target,
            velocity: 0,
            lastStepAt: now,
            startedAt: now
          )
        }
      }
    }
    if !scrollAnimations.isEmpty {
      beginFrameAnimationActivity()
    }
  }

  func beginFrameAnimationActivity() {
    if !frameNotificationsSuspended {
      currentAnimationFrameCount = 0
      maximumAnimationStepDurationMS = 0
      platform.setFrameNotificationsEnabled(false)
      frameNotificationsSuspended = true
    }
    setTimerFrequency(min(activeDisplayRefreshRate, 120))
  }

  func snapScrollOffsetsToTargets() {
    scrollAnimations.removeAll()
    for monitorIndex in state.monitors.indices {
      for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
        state.monitors[monitorIndex].workspaces[workspaceIndex].scrollOffset =
          state.monitors[monitorIndex].workspaces[workspaceIndex].targetScrollOffset
      }
    }
  }

  func dispatchScrollAnimationIfNeeded(
    monitorIDs: Set<MonitorID>? = nil,
    skipping skippedWindowIDs: Set<WindowID> = [],
    forcingFloatingFrameWritesFor forcedFloatingWindowIDs: Set<WindowID> = [],
    commandPerformance: CommandPerformanceContext? = nil
  ) -> Bool {
    guard !scrollAnimations.isEmpty else { return false }
    let duration = TimeInterval(config.animation.durationMS) / 1_000
    snapScrollOffsetsToTargets()
    applyCurrentLayout(
      monitorIDs: monitorIDs,
      asynchronousPositions: true,
      updateVisibility: true,
      positionTimeoutSeconds: 0.05,
      animationDuration: duration,
      skipping: skippedWindowIDs,
      positionsOnly: true,
      forcingFloatingFrameWritesFor: forcedFloatingWindowIDs,
      commandPerformance: commandPerformance,
      source: "command-animation"
    )
    needsDesktopSync = true
    return true
  }

  func dispatchManagedResizeAnimation(
    monitorIDs: Set<MonitorID>? = nil,
    skipping skippedWindowIDs: Set<WindowID> = [],
    forcingFloatingFrameWritesFor forcedFloatingWindowIDs: Set<WindowID> = [],
    commandPerformance: CommandPerformanceContext? = nil
  ) -> Bool {
    let duration = TimeInterval(config.animation.durationMS) / 1_000
    guard config.animation.enabled, duration > 0 else { return false }
    snapScrollOffsetsToTargets()
    beginFrameAnimationActivity()
    applyCurrentLayout(
      monitorIDs: monitorIDs,
      asynchronousPositions: true,
      updateVisibility: true,
      positionTimeoutSeconds: 0.05,
      animationDuration: duration,
      animateSizeChanges: true,
      skipping: skippedWindowIDs,
      forcingFloatingFrameWritesFor: forcedFloatingWindowIDs,
      commandPerformance: commandPerformance,
      source: "command-resize-animation"
    )
    needsDesktopSync = true
    return true
  }

  func cancelAnimationForMouseGesture() {
    needsDesktopSync = true
    guard mouseGestureAnimationCancellationIsNeeded(
      mouseReorderAnimationActive: mouseReorderAnimationActive,
      scrollAnimationActive: !scrollAnimations.isEmpty,
      animatedWritesPending:
        platform.hasPendingAnimatedFrameWrites
        || platform.hasPendingDeferredParkingWrites
    ) else {
      return
    }
    rebaseActiveScrollOffsetToDisplayedFrames()
    if activelyResizedWindowID == nil {
      mouseGestureDisplayedOriginFrames = Dictionary(
        uniqueKeysWithValues: state.windows.map { windowID, window in
          let displayedPosition = platform.completedPosition(for: windowID)
          let displayedSize = platform.completedSize(for: windowID)
          return (
            windowID,
            resolvedMouseGestureOriginFrame(
              observedFrame: window.frame,
              displayedX: displayedPosition.map { Double($0.x) },
              displayedY: displayedPosition.map { Double($0.y) },
              displayedWidth: displayedSize.map { Double($0.width) },
              displayedHeight: displayedSize.map { Double($0.height) }
            )
          )
        }
      )
    }
    scrollAnimations.removeAll(keepingCapacity: true)
    pendingAnimatedFocus = nil
    invalidateSubmittedCommandFocus()
    invalidateSubmittedWorkspaceFocus()
    pendingWorkspaceFocus = nil
    submittedWorkspaceFocusGeneration = nil
    platform.cancelPendingFrameWrites()
  }

  func beginMouseGesture() {
    mouseGestureGeneration &+= 1
    mouseGestureSettlement = nil
    mouseGesturePreempted = false
    mouseReorderAnimationActive = false
    activelyResizedWindowID = nil
    mouseGestureInitialFrame = nil
    mouseGestureScrollAnchor = nil
    mouseGestureDisplayedOriginFrames.removeAll(keepingCapacity: true)
  }

  func preemptMouseGesture() {
    mouseGestureGeneration &+= 1
    mouseGesturePreempted = true
    finishMouseGestureTracking()
  }

  func finishMouseGestureTracking(
    preservingScrollAnchor: Bool = false
  ) {
    mouseGestureSettlement = nil
    activelyResizedWindowID = nil
    mouseGestureInitialFrame = nil
    if !preservingScrollAnchor {
      mouseGestureScrollAnchor = nil
    }
    mouseGestureDisplayedOriginFrames.removeAll(keepingCapacity: true)
  }

  func finishPendingAnimatedFocusIfReady() {
    if let pendingAnimatedFocus,
      focusIsReady(
        on: pendingAnimatedFocus.monitorID,
        targetWindowID: pendingAnimatedFocus.windowID
      )
    {
      self.pendingAnimatedFocus = nil
      commitCommandFocus(
        pendingAnimatedFocus.windowID,
        previousSelectedWindowID:
          pendingAnimatedFocus.previousSelectedWindowID,
        monitorID: pendingAnimatedFocus.monitorID,
        sourceWorkspaceID: pendingAnimatedFocus.sourceWorkspaceID,
        commandGeneration: pendingAnimatedFocus.commandGeneration,
        focusInputTimestamp: pendingAnimatedFocus.focusInputTimestamp,
        cursorWarpInputTimestamp: pendingAnimatedFocus.cursorWarpInputTimestamp,
        retryCount: pendingAnimatedFocus.retryCount
      )
    }
  }

  func finishPendingWorkspaceFocusIfReady() {
    guard let request = pendingWorkspaceFocus,
      submittedWorkspaceFocusGeneration != request.commandGeneration,
      focusIsReady(
        on: request.monitorID,
        targetWindowID: request.requestedWindowID
      )
    else { return }

    submittedWorkspaceFocusGeneration = request.commandGeneration
    submittedWorkspaceFocusRecoveryGeneration = nil
    submittedWorkspaceFocusRequestID = platform.focus(
      request.requestedWindowID,
      unlessUserInputAfter: request.focusInputTimestamp,
      cursorWarpUnlessPointerMovedAfter: request.cursorWarpInputTimestamp,
      cursorWarpIsCurrent: { [weak self] in
        guard let self else { return false }
        return self.pendingWorkspaceFocus?.commandGeneration
            == request.commandGeneration
          && self.submittedWorkspaceFocusGeneration
            == request.commandGeneration
      },
      completion: { [weak self] result in
        self?.commitWorkspaceCommandFocus(result: result, request: request)
      }
    )
    submittedWorkspaceFocusRequestTimestamp =
      submittedWorkspaceFocusRequestID == nil
        ? nil
        : request.focusInputTimestamp
  }

  func focusIsReady(
    on monitorID: MonitorID,
    targetWindowID: WindowID
  ) -> Bool {
    focusTargetIsReady(
      targetMonitorID: monitorID,
      targetWindowID: targetWindowID,
      scrollingMonitorIDs: Set(scrollAnimations.keys.map(\.monitorID)),
      pendingFrameWindowIDs: platform.pendingFrameWindowIDs
    )
  }

  func isSpeculativeRibbonNavigation(_ command: Command) -> Bool {
    if case .focusColumn = command {
      return true
    }
    return false
  }

}
