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

func workspaceTransitionPathIsClear(
  ownerFrame: Rect,
  otherMonitorFrames: [Rect]
) -> Bool {
  let envelope = Rect(
    x: ownerFrame.x,
    y: ownerFrame.y - ownerFrame.height,
    width: ownerFrame.width,
    height: ownerFrame.height * 3
  )
  return otherMonitorFrames.allSatisfy { other in
    envelope.x + envelope.width <= other.x
      || other.x + other.width <= envelope.x
      || envelope.y + envelope.height <= other.y
      || other.y + other.height <= envelope.y
  }
}

func workspaceVerticalTransitionDuration(
  configuredDurationMS: Int
) -> TimeInterval {
  guard configuredDurationMS > 0 else { return 0 }
  return max(TimeInterval(configuredDurationMS) / 1_000, 0.18)
}

func workspaceVerticalTransitionCanAnimateWithoutReservedAreaLeak(
  viewport: Rect,
  physicalFrame: Rect
) -> Bool {
  viewport.y - physicalFrame.y <= 0.5
    && physicalFrame.y + physicalFrame.height
      - (viewport.y + viewport.height) <= 0.5
}

func workspaceVerticalRibbonOffset(
  relativePosition: Int,
  physicalFrame: Rect
) -> Double {
  Double(relativePosition) * physicalFrame.height
}

func outgoingWorkspaceVerticalRibbonOffset(
  workspaceID: WorkspaceID,
  monitorID: MonitorID,
  transition: WorkspaceVerticalTransition?,
  physicalFrame: Rect
) -> Double? {
  guard transition?.monitorID == monitorID,
    transition?.outgoingWorkspaceID == workspaceID
  else { return nil }
  return workspaceVerticalRibbonOffset(
    relativePosition: -(transition?.direction ?? 0),
    physicalFrame: physicalFrame
  )
}

@MainActor
extension Daemon {
  var animationsEnabled: Bool {
    config.animation.enabled
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  func safeWorkspaceVerticalTransition(
    _ intent: WorkspaceTransitionIntent
  ) -> WorkspaceVerticalTransition? {
    let duration = workspaceVerticalTransitionDuration(
      configuredDurationMS: config.animation.durationMS
    )
    guard animationsEnabled, duration > 0,
      pendingDisplaySyncDeadlines.isEmpty,
      latestMonitors.count == state.monitors.count,
      let monitor = state.monitors.first(where: { $0.id == intent.monitorID }),
      let outgoing = monitor.workspaces.first(where: {
        $0.id == intent.outgoingWorkspaceID
      }),
      let incoming = monitor.workspaces.first(where: {
        $0.id == intent.incomingWorkspaceID
      }),
      let ownerFrame = latestMonitors.first(where: {
        $0.id == intent.monitorID
      })?.physicalFrame,
      let viewport = viewportsByMonitor[intent.monitorID],
      workspaceVerticalTransitionCanAnimateWithoutReservedAreaLeak(
        viewport: viewport,
        physicalFrame: ownerFrame
      )
    else { return nil }
    let outgoingWindowIDs = Set(
      outgoing.columns.flatMap(\.windows) + outgoing.floatingWindows
    )
    let participantWindowIDs = outgoingWindowIDs.union(
      incoming.columns.flatMap(\.windows) + incoming.floatingWindows
    )
    guard !outgoingWindowIDs.isEmpty,
      participantWindowIDs.isSubset(of: platform.frameWritableWindowIDs),
      platform.positionsCanAnimateTogether(
        windowIDs: participantWindowIDs,
        animationDuration: duration,
        refreshRateHz: activeDisplayRefreshRate
      ),
      participantWindowIDs.isDisjoint(with: state.nativeFullscreenWindowIDs),
      workspaceTransitionPathIsClear(
        ownerFrame: ownerFrame,
        otherMonitorFrames: latestMonitors.compactMap {
          $0.id == intent.monitorID ? nil : $0.physicalFrame
        }
      )
    else { return nil }
    return WorkspaceVerticalTransition(
      monitorID: intent.monitorID,
      outgoingWorkspaceID: intent.outgoingWorkspaceID,
      direction: intent.direction
    )
  }

  func dispatchWorkspaceVerticalTransition(
    _ transition: WorkspaceVerticalTransition,
    affectedMonitorIDs: Set<MonitorID>,
    focusWindowIDAfterCommit: WindowID?,
    focusInputTimestampAfterCommit: TimeInterval?,
    cursorWarpInputTimestampAfterCommit: TimeInterval?,
    focusCompletionAfterCommit:
      (@MainActor @Sendable (NativeFocusResult) -> Void)?,
    cursorWarpIsCurrentAfterCommit: (@MainActor @Sendable () -> Bool)?,
    focusRequestIDAfterCommit:
      (@MainActor @Sendable (NativeFocusRequestID?) -> Void)?,
    commandPerformance: CommandPerformanceContext
  ) {
    let duration = workspaceVerticalTransitionDuration(
      configuredDurationMS: config.animation.durationMS
    )
    beginFrameAnimationActivity()
    applyCurrentLayout(
      monitorIDs: affectedMonitorIDs,
      asynchronousPositions: true,
      updateVisibility: true,
      positionTimeoutSeconds: 0.05,
      animationDuration: duration,
      positionsOnly: true,
      focusWindowIDAfterCommit: focusWindowIDAfterCommit,
      focusInputTimestampAfterCommit: focusInputTimestampAfterCommit,
      cursorWarpInputTimestampAfterCommit: cursorWarpInputTimestampAfterCommit,
      focusCompletionAfterCommit: focusCompletionAfterCommit,
      cursorWarpIsCurrentAfterCommit: cursorWarpIsCurrentAfterCommit,
      focusRequestIDAfterCommit: focusRequestIDAfterCommit,
      workspaceTransition: transition,
      commandPerformance: commandPerformance,
      source: "workspace-transition"
    )
    needsDesktopSync = true
  }

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
          animationsEnabled,
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
    guard animationsEnabled, duration > 0 else { return false }
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
    guard
      mouseGestureAnimationCancellationIsNeeded(
        mouseReorderAnimationActive: mouseReorderAnimationActive,
        scrollAnimationActive: !scrollAnimations.isEmpty,
        animatedWritesPending:
          platform.hasPendingAnimatedFrameWrites
          || platform.hasPendingDeferredParkingWrites
      )
    else {
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
    focus.queueCommand(nil)
    invalidateSubmittedCommandFocus()
    invalidateSubmittedWorkspaceFocus()
    focus.queueWorkspace(nil)
    focus.cancelSubmittedWorkspace()
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
      self.focus.queueCommand(nil)
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

    let submission = focus.submitWorkspace(request)
    submittedWorkspaceFocusRecoveryGeneration = nil
    submittedWorkspaceFocusRequestID = platform.focus(
      request.requestedWindowID,
      unlessUserInputAfter: request.focusInputTimestamp,
      cursorWarpUnlessPointerMovedAfter: request.cursorWarpInputTimestamp,
      cursorWarpIsCurrent: { [weak self] in
        guard let self else { return false }
        return self.focus.workspaceCompletionIsCurrent(request, submission: submission)
      },
      allowsNativeFullscreen: true,
      completion: { [weak self] result in
        self?.commitWorkspaceCommandFocus(result: result, request: request, submission: submission)
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
