import DefiCore
import DefiIPC
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation

@MainActor
extension Daemon {
  func toggleOverview() -> CommandResponse {
    guard !state.monitors.isEmpty else {
      return .failure("overview unavailable before monitor discovery")
    }
    let controller = overviewController ?? makeOverviewController()
    overviewController = controller
    controller.toggle(
      snapshot: makeOverviewSnapshot(),
      layout: state.layout,
      borders: config.decorations.borders,
      animation: config.animation,
      zoom: config.overview.zoom,
      windowCornerRadius: config.overview.windowCornerRadius,
      windowPreviewsEnabled: config.overview.windowPreviews
    )
    return .success()
  }

  func updateOverviewIfOpen() {
    guard overviewController?.isOpen == true else { return }
    overviewController?.update(
      snapshot: makeOverviewSnapshot(),
      layout: state.layout,
      borders: config.decorations.borders,
      animation: config.animation,
      zoom: config.overview.zoom,
      windowCornerRadius: config.overview.windowCornerRadius,
      windowPreviewsEnabled: config.overview.windowPreviews
    )
  }

  private func makeOverviewController() -> OverviewController {
    OverviewController(
      focusWindow: { [weak self] windowID, appID, monitorID, workspaceID in
        self?.focusFromOverview(
          windowID: windowID,
          appID: appID,
          monitorID: monitorID,
          workspaceID: workspaceID
        )
      },
      focusWorkspace: { [weak self] monitorID, workspaceID in
        self?.focusWorkspaceFromOverview(
          monitorID: monitorID,
          workspaceID: workspaceID
        )
      },
      drop: {
        [weak self] windowID, appID, sourceMonitorID, sourceWorkspaceID, target in
        self?.dropFromOverview(
          windowID: windowID,
          appID: appID,
          sourceMonitorID: sourceMonitorID,
          sourceWorkspaceID: sourceWorkspaceID,
          target: target
        )
      },
      activateMonitor: { [weak self] monitorID in
        guard self?.state.monitors.contains(where: { $0.id == monitorID }) == true
        else { return }
        self?.activeMonitorID = monitorID
      },
      openStateChanged: { [weak self] isOpen in
        guard let self else { return }
        let parksWindows = overviewController?.usesWorkspaceParking == true
        overviewOpenedAt =
          isOpen && parksWindows
          ? ProcessInfo.processInfo.systemUptime
          : nil
        hotKeys?.setOverviewModeEnabled(isOpen)
        platform.setWindowBordersSuppressed(isOpen)
        if parksWindows {
          applyCurrentLayout(
            asynchronousPositions: true,
            updateVisibility: true,
            positionTimeoutSeconds: 0.05,
            stagesVisibleBeforeParking: !isOpen,
            source: isOpen ? "overview-park" : "overview-restore"
          )
        }
      },
      commitScrollOffsets: { [weak self] offsets in
        guard let self else { return }
        let changedMonitorIDs = applyOverviewScrollOffsets(offsets, state: &state)
        guard !changedMonitorIDs.isEmpty else { return }
        persistPlacements()
        guard overviewController?.usesWorkspaceParking != true else { return }
        applyCurrentLayout(
          monitorIDs: changedMonitorIDs,
          asynchronousPositions: true,
          updateVisibility: false,
          positionTimeoutSeconds: 0.05,
          source: "overview-scroll-commit"
        )
      }
    )
  }

  private func makeOverviewSnapshot() -> OverviewSnapshot {
    OverviewSnapshot(
      monitors: logicalOverviewMonitors(state: state),
      monitorFrames: Dictionary(
        uniqueKeysWithValues: latestMonitors.map { ($0.id, $0.frame) }
      ),
      windows: state.windows,
      floatingFrames: floatingWindowFrames,
      activeMonitorID: activeMonitorID,
      nativeFullscreenWindowIDs: state.nativeFullscreenWindowIDs
    )
  }

  private func focusFromOverview(
    windowID: WindowID,
    appID: String,
    monitorID: MonitorID,
    workspaceID: WorkspaceID
  ) {
    let previousSelectedWindowID = activeMonitorID.flatMap {
      state.selectedWindowID(on: $0)
    }
    let inputTimestamp = ProcessInfo.processInfo.systemUptime
    do {
      let focusedMonitorID = try focusOverviewWindow(
        OverviewWindowIntent(
          windowID: windowID,
          expectedAppID: appID,
          sourceMonitorID: monitorID,
          sourceWorkspaceID: workspaceID
        ),
        state: &state
      )
      activeMonitorID = focusedMonitorID
      commandGeneration &+= 1
      latestCommandInputTimestamp = inputTimestamp
      platform.userInputTracker.record(timestamp: inputTimestamp)
      pendingWindowRemovalFocusGuard = nil
      focus.discardDisplacedFocus()
      invalidatePointerFocusIntent(recoveringTo: previousSelectedWindowID)
      invalidateSubmittedWorkspaceFocus()
      focus.queueWorkspace(nil)
      synchronizeScrollOffsets(state: &state, viewports: viewportsByMonitor)
      startScrollAnimationsIfNeeded()
      let animated = dispatchScrollAnimationIfNeeded(
        monitorIDs: [focusedMonitorID]
      )
      if !animated {
        applyCurrentLayout(
          monitorIDs: [focusedMonitorID],
          asynchronousPositions: true,
          updateVisibility: true,
          positionTimeoutSeconds: 0.05,
          stagesVisibleBeforeParking: true,
          source: "overview-focus"
        )
      }
      if focusIsReady(on: focusedMonitorID, targetWindowID: windowID) {
        commitCommandFocus(
          windowID,
          previousSelectedWindowID: previousSelectedWindowID,
          monitorID: focusedMonitorID,
          sourceWorkspaceID: workspaceID,
          commandGeneration: commandGeneration,
          focusInputTimestamp: inputTimestamp,
          cursorWarpInputTimestamp: config.input.mouseFollowsFocus
            ? inputTimestamp
            : nil
        )
      } else {
        focus.queueCommand(
          PendingAnimatedFocus(
            windowID: windowID,
            previousSelectedWindowID: previousSelectedWindowID,
            monitorID: focusedMonitorID,
            sourceWorkspaceID: workspaceID,
            commandGeneration: commandGeneration,
            focusInputTimestamp: inputTimestamp,
            cursorWarpInputTimestamp: config.input.mouseFollowsFocus
              ? inputTimestamp
              : nil
          ))
      }
      persistPlacements()
      updateMenuBar()
      updateOverviewIfOpen()
    } catch {
      platform.recordPerformanceTrace("overview-focus-rejected error=\(error)")
      updateOverviewIfOpen()
    }
  }

  private func focusWorkspaceFromOverview(
    monitorID: MonitorID,
    workspaceID: WorkspaceID
  ) {
    let inputTimestamp = ProcessInfo.processInfo.systemUptime
    do {
      let selectedWindowID = try focusOverviewWorkspace(
        monitorID: monitorID,
        workspaceID: workspaceID,
        state: &state
      )
      activeMonitorID = monitorID
      commandGeneration &+= 1
      latestCommandInputTimestamp = inputTimestamp
      platform.userInputTracker.record(timestamp: inputTimestamp)
      synchronizeScrollOffsets(state: &state, viewports: viewportsByMonitor)
      snapScrollOffsetsToTargets()
      applyCurrentLayout(
        monitorIDs: [monitorID],
        asynchronousPositions: true,
        updateVisibility: true,
        positionTimeoutSeconds: 0.05,
        stagesVisibleBeforeParking: true,
        focusWindowIDAfterCommit: selectedWindowID,
        focusInputTimestampAfterCommit: selectedWindowID == nil
          ? nil
          : inputTimestamp,
        source: "overview-workspace"
      )
      persistPlacements()
      updateMenuBar()
      updateOverviewIfOpen()
    } catch {
      platform.recordPerformanceTrace("overview-workspace-rejected error=\(error)")
    }
  }

  private func dropFromOverview(
    windowID: WindowID,
    appID: String,
    sourceMonitorID: MonitorID,
    sourceWorkspaceID: WorkspaceID,
    target: OverviewDropTarget
  ) {
    let inputTimestamp = ProcessInfo.processInfo.systemUptime
    do {
      let result = try applyOverviewDrop(
        OverviewWindowIntent(
          windowID: windowID,
          expectedAppID: appID,
          sourceMonitorID: sourceMonitorID,
          sourceWorkspaceID: sourceWorkspaceID
        ),
        target: target,
        viewports: viewportsByMonitor,
        floatingFrames: floatingWindowFrames,
        state: &state
      )
      commandGeneration &+= 1
      latestCommandInputTimestamp = inputTimestamp
      activeMonitorID = result.monitorID
      for (windowID, frame) in result.floatingFrameUpdates {
        floatingWindowFrames[windowID] = frame
      }
      focus.queueCommand(nil)
      invalidateSubmittedCommandFocus()
      invalidateSubmittedWorkspaceFocus()
      focus.queueWorkspace(nil)
      preemptMouseGesture()
      synchronizeScrollOffsets(state: &state, viewports: viewportsByMonitor)
      snapScrollOffsetsToTargets()
      let affectedMonitorIDs: Set<MonitorID> = [sourceMonitorID, result.monitorID]
      applyCurrentLayout(
        monitorIDs: affectedMonitorIDs,
        asynchronousPositions: true,
        updateVisibility: true,
        positionTimeoutSeconds: 0.05,
        stagesVisibleBeforeParking: true,
        focusWindowIDAfterCommit: result.focusedWindowID,
        focusInputTimestampAfterCommit: inputTimestamp,
        forcingFloatingFrameWritesFor: Set(result.floatingFrameUpdates.keys),
        source: "overview-drop"
      )
      persistPlacements()
      updateMenuBar()
      updateOverviewIfOpen()
      needsDesktopSync = true
    } catch {
      platform.recordPerformanceTrace("overview-drop-rejected error=\(error)")
      updateOverviewIfOpen()
    }
  }
}
