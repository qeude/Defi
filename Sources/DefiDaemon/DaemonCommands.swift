import AppKit
import DefiConfig
import DefiCore
import DefiIPC
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation
import OSLog

@MainActor
extension Daemon {
  func enqueueHotKey(_ invocation: HotKeyInvocation) {
    guard pendingHotKeyCommands.count < 64 else { return }
    pendingHotKeyCommands.append(invocation)
    processPendingHotKeys()
  }

  func processPendingHotKeys() {
    guard !processingHotKeyCommands else { return }
    processingHotKeyCommands = true
    defer { processingHotKeyCommands = false }
    for _ in 0..<min(pendingHotKeyCommands.count, 8) {
      let invocation = pendingHotKeyCommands.removeFirst()
      _ = handle(
        invocation.command,
        inputTimestamp: invocation.timestamp
      )
      processedHotKeyCount += 1
    }
  }

  func pollIPC() {
    do {
      for _ in 0..<16 {
        let handled = try server.poll { [weak self] command in
          self?.handle(command) ?? .failure("daemon unavailable")
        }
        if !handled { break }
      }
      if shouldShutdown {
        shutdown()
      }
    } catch {
      log("IPC error: \(error)")
    }
  }

  @discardableResult
  func handle(
    _ rawCommand: String,
    inputTimestamp: TimeInterval? = nil
  ) -> CommandResponse {
    if rawCommand == "status" {
      return .success(status())
    }
    if rawCommand == "trace" {
      return .success(platform.frameCoordinatorTrace)
    }
    if rawCommand == "restore" {
      restoreAllWindows()
      return .success("restored")
    }
    if rawCommand == "quit" {
      shouldShutdown = true
      return .success("stopping")
    }
    do {
      let commandStartedAt = ProcessInfo.processInfo.systemUptime
      let command = try parseCommand(rawCommand)
      platform.userInputTracker.record(
        timestamp: inputTimestamp ?? commandStartedAt
      )
      pendingPointerFocus = nil
      let cursorWarpInputTimestamp = keyboardCursorWarpTimestamp(
        mouseFollowsFocus: config.input.mouseFollowsFocus,
        capturedInputTimestamp: inputTimestamp
      )
      mouseReorderAnimationActive = false
      latestCommandInputTimestamp = resolvedLatestCommandInputTimestamp(
        previousTimestamp: latestCommandInputTimestamp,
        capturedInputTimestamp: inputTimestamp,
        commandHandledAt: commandStartedAt
      )
      pendingWindowRemovalFocusGuard = nil
      let switchesWorkspace = command.activatesWorkspace
      let mutatesWorkspaceWindows = command.movesWindowBetweenWorkspaces
      let resizesManagedLayout = command.resizesManagedLayout
      let speculativeRibbonNavigation = isSpeculativeRibbonNavigation(command)
      if switchesWorkspace || mutatesWorkspaceWindows || resizesManagedLayout
        || speculativeRibbonNavigation
      {
        preemptMouseGesture()
      }
      let animatedManagedResize =
        resizesManagedLayout
        && config.animation.enabled
        && config.animation.durationMS > 0
      if !speculativeRibbonNavigation {
        cancelDeferredSlowLane()
      }
      let previouslySelectedWindowID =
        activeMonitorID.flatMap { state.selectedWindowID(on: $0) }
      if !scrollAnimations.isEmpty || platform.hasPendingAnimatedFrameWrites {
        rebaseActiveScrollOffsetToDisplayedFrames()
      }
      if switchesWorkspace || mutatesWorkspaceWindows {
        refreshFloatingWindowFramesBeforeWorkspaceMutation()
      }
      if switchesWorkspace {
        suppressNativeFocusUntil = commandStartedAt + 0.25
        pendingAnimatedFocus = nil
      }
      try reduce(command, on: activeMonitorID, state: &state)
      persistPlacements()
      updateMenuBar()
      synchronizeScrollOffsets(state: &state, viewports: viewportsByMonitor)
      if switchesWorkspace {
        snapScrollOffsetsToTargets()
      } else {
        startScrollAnimationsIfNeeded()
      }
      let deferredWindowIDs: Set<WindowID>
      if speculativeRibbonNavigation, !scrollAnimations.isEmpty {
        deferredWindowIDs = scheduleSlowLaneDeferral(
          at: commandStartedAt
        )
      } else {
        deferredWindowIDs = []
      }
      let dispatchedAnimation =
        animatedManagedResize
        ? dispatchManagedResizeAnimation(skipping: deferredWindowIDs)
        : dispatchScrollAnimationIfNeeded(skipping: deferredWindowIDs)
      if switchesWorkspace || !dispatchedAnimation {
        let focusWindowIDAfterCommit =
          switchesWorkspace
          ? (activeMonitorID ?? state.monitors.first?.id).flatMap {
            state.selectedWindowID(on: $0)
          }
          : nil
        applyCurrentLayout(
          asynchronousPositions: true,
          updateVisibility: scrollAnimations.isEmpty,
          positionTimeoutSeconds: scrollAnimations.isEmpty ? 0.05 : 0.016,
          skipping: deferredWindowIDs,
          positionsOnly: speculativeRibbonNavigation,
          stagesVisibleBeforeParking: switchesWorkspace,
          focusWindowIDAfterCommit: focusWindowIDAfterCommit,
          cursorWarpInputTimestampAfterCommit: switchesWorkspace
            ? cursorWarpInputTimestamp
            : nil,
          source: switchesWorkspace ? "workspace-command" : "command"
        )
      }
      if !switchesWorkspace,
        let monitorID = activeMonitorID ?? state.monitors.first?.id,
        let selected = state.selectedWindowID(on: monitorID),
        commandShouldFocusWindow(
          command,
          previousSelectedWindowID: previouslySelectedWindowID,
          selectedWindowID: selected,
          selectedFloatingWindowID: state.selectedFloatingWindowID(on: monitorID)
        )
      {
        if scrollAnimations.isEmpty,
          !platform.hasPendingAnimatedFrameWrites,
          !deferredSlowWindowIDs.contains(selected)
        {
          commitCommandFocus(
            selected,
            cursorWarpInputTimestamp: cursorWarpInputTimestamp
          )
        } else {
          pendingAnimatedFocus = PendingAnimatedFocus(
            windowID: selected,
            cursorWarpInputTimestamp: cursorWarpInputTimestamp
          )
        }
      } else if !switchesWorkspace,
        let monitorID = activeMonitorID ?? state.monitors.first?.id,
        let selected = state.selectedWindowID(on: monitorID),
        pendingCommandFocusIsPreserved(
          pendingWindowID: pendingAnimatedFocus?.windowID,
          selectedWindowID: selected
        )
      {
        pendingAnimatedFocus = PendingAnimatedFocus(
          windowID: selected,
          cursorWarpInputTimestamp: cursorWarpInputTimestamp
        )
      }
      lastCommandDurationMS =
        (ProcessInfo.processInfo.systemUptime - commandStartedAt) * 1_000
      performanceLogger.debug(
        "command applied command=\(rawCommand, privacy: .public) duration_ms=\(self.lastCommandDurationMS, format: .fixed(precision: 2)) animations=\(self.scrollAnimations.count)"
      )
      return .success()
    } catch {
      return .failure(String(describing: error))
    }
  }
}
