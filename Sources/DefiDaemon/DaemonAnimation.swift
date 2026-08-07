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
            animation.velocity = 0
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
    if animationActivity == nil {
      currentAnimationFrameCount = 0
      maximumAnimationStepDurationMS = 0
      animationActivity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical],
        reason: "Defi frame animation"
      )
    }
    if !frameNotificationsSuspended {
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
    skipping skippedWindowIDs: Set<WindowID> = []
  ) -> Bool {
    guard !scrollAnimations.isEmpty else { return false }
    let duration = TimeInterval(config.animation.durationMS) / 1_000
    snapScrollOffsetsToTargets()
    applyCurrentLayout(
      asynchronousPositions: true,
      updateVisibility: true,
      positionTimeoutSeconds: 0.05,
      animationDuration: duration,
      skipping: skippedWindowIDs,
      positionsOnly: true,
      source: "command-animation"
    )
    needsDesktopSync = true
    return true
  }

  func dispatchManagedResizeAnimation(
    skipping skippedWindowIDs: Set<WindowID> = []
  ) -> Bool {
    let duration = TimeInterval(config.animation.durationMS) / 1_000
    guard config.animation.enabled, duration > 0 else { return false }
    snapScrollOffsetsToTargets()
    beginFrameAnimationActivity()
    applyCurrentLayout(
      asynchronousPositions: true,
      updateVisibility: true,
      positionTimeoutSeconds: 0.05,
      animationDuration: duration,
      animateSizeChanges: true,
      skipping: skippedWindowIDs,
      source: "command-resize-animation"
    )
    needsDesktopSync = true
    return true
  }

  func cancelAnimationForMouseGesture() {
    cancelDeferredSlowLane()
    needsDesktopSync = true
    guard mouseGestureAnimationCancellationIsNeeded(
      mouseReorderAnimationActive: mouseReorderAnimationActive,
      scrollAnimationActive: !scrollAnimations.isEmpty,
      animatedWritesPending: platform.hasPendingAnimatedFrameWrites
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
    if scrollAnimations.isEmpty,
      !platform.hasPendingAnimatedFrameWrites,
      let pendingAnimatedFocus,
      !deferredSlowWindowIDs.contains(pendingAnimatedFocus.windowID)
    {
      self.pendingAnimatedFocus = nil
      commitCommandFocus(
        pendingAnimatedFocus.windowID,
        cursorWarpInputTimestamp: pendingAnimatedFocus.cursorWarpInputTimestamp
      )
    }
  }

  func isSpeculativeRibbonNavigation(_ command: Command) -> Bool {
    if case .focusColumn = command {
      return true
    }
    return false
  }

  func scheduleSlowLaneDeferral(
    at commandStartedAt: TimeInterval
  ) -> Set<WindowID> {
    let candidates = platform.latencySensitiveWindowIDs
      .union(deferredSlowWindowIDs)
    guard !candidates.isEmpty else { return [] }
    deferredSlowWindowIDs = candidates
    slowLaneSettlementDeadline =
      commandStartedAt
      + speculativeNavigationSettlementDelay(
        animationDuration: TimeInterval(config.animation.durationMS) / 1_000
      )
    slowLaneDeferralCount += 1
    performanceLogger.debug(
      "slow lane deferred windows=\(candidates.count) deadline_ms=\((self.slowLaneSettlementDeadline! - commandStartedAt) * 1_000, format: .fixed(precision: 1))"
    )
    return candidates
  }

  func cancelDeferredSlowLane() {
    deferredSlowWindowIDs.removeAll(keepingCapacity: true)
    slowLaneSettlementDeadline = nil
  }

  func finishDeferredSlowLaneIfReady() {
    guard !deferredSlowWindowIDs.isEmpty,
      let deadline = slowLaneSettlementDeadline,
      ProcessInfo.processInfo.systemUptime >= deadline,
      scrollAnimations.isEmpty,
      !platform.hasPendingAnimatedFrameWrites
    else {
      return
    }
    let settledWindowIDs = deferredSlowWindowIDs
    deferredSlowWindowIDs.removeAll(keepingCapacity: true)
    slowLaneSettlementDeadline = nil
    slowLaneSettlementCount += 1
    applyCurrentLayout(
      asynchronousPositions: true,
      updateVisibility: true,
      positionTimeoutSeconds: 0.05,
      animationDuration: TimeInterval(config.animation.durationMS) / 1_000,
      skipping: Set(state.windows.keys).subtracting(settledWindowIDs),
      positionsOnly: true,
      source: "slow-lane-settlement"
    )
    needsDesktopSync = true
    performanceLogger.debug(
      "slow lane settled windows=\(settledWindowIDs.count)"
    )
  }

}
