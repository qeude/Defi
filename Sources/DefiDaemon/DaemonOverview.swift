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
        overviewOpenedAt = isOpen && parksWindows
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
      }
    )
  }

  private func makeOverviewSnapshot() -> OverviewSnapshot {
    OverviewSnapshot(
      monitors: logicalOverviewMonitors(),
      monitorFrames: Dictionary(
        uniqueKeysWithValues: latestMonitors.map { ($0.id, $0.frame) }
      ),
      windows: state.windows,
      floatingFrames: floatingWindowFrames,
      activeMonitorID: activeMonitorID,
      nativeFullscreenWindowIDs: state.nativeFullscreenWindowIDs
    )
  }

  private func logicalOverviewMonitors() -> [Monitor] {
    var monitors = state.monitors
    for monitorIndex in monitors.indices {
      for workspaceIndex in monitors[monitorIndex].workspaces.indices {
        for windowID in state.nativeFullscreenWindowIDs {
          removeWindow(
            windowID,
            from: &monitors[monitorIndex].workspaces[workspaceIndex],
            settings: state.layout
          )
        }
      }
    }

    for windowID in state.nativeFullscreenFloatingWindowIDs {
      guard let location = state.location(containing: windowID),
        let monitorIndex = monitors.firstIndex(where: { $0.id == location.monitorID }),
        let workspaceIndex = monitors[monitorIndex].workspaces.firstIndex(where: {
          $0.id == location.workspaceID
        })
      else { continue }
      monitors[monitorIndex].workspaces[workspaceIndex].floatingWindows.append(windowID)
    }

    let groupedPlacements = Dictionary(grouping: state.nativeFullscreenTiledPlacements) {
      _, placement in
      OverviewPlacementGroup(
        monitorID: placement.monitorID,
        workspaceID: placement.workspaceID,
        columnIndex: placement.columnIndex
      )
    }
    for (group, placements) in groupedPlacements.sorted(by: {
      $0.key.columnIndex < $1.key.columnIndex
    }) {
      guard let placement = placements.first?.value,
        let monitorIndex = monitors.firstIndex(where: { $0.id == group.monitorID }),
        let workspaceIndex = monitors[monitorIndex].workspaces.firstIndex(where: {
          $0.id == group.workspaceID
        })
      else { continue }
      let desiredWindowIDs = placement.column.windows.filter {
        state.windows[$0] != nil
      }
      guard !desiredWindowIDs.isEmpty else { continue }
      if let existingColumnIndex = monitors[monitorIndex].workspaces[workspaceIndex]
        .columns.firstIndex(where: { column in
          column.windows.contains(where: desiredWindowIDs.contains)
        })
      {
        monitors[monitorIndex].workspaces[workspaceIndex]
          .columns[existingColumnIndex].windows = desiredWindowIDs
        monitors[monitorIndex].workspaces[workspaceIndex]
          .columns[existingColumnIndex].width = placement.column.width
        monitors[monitorIndex].workspaces[workspaceIndex]
          .columns[existingColumnIndex].preMaximizedWidth =
            placement.column.preMaximizedWidth
      } else {
        let insertionIndex = min(
          max(group.columnIndex, 0),
          monitors[monitorIndex].workspaces[workspaceIndex].columns.count
        )
        monitors[monitorIndex].workspaces[workspaceIndex].columns.insert(
          Column(
            windows: desiredWindowIDs,
            focusedWindow: min(
              placement.windowIndex,
              desiredWindowIDs.count - 1
            ),
            width: placement.column.width,
            preMaximizedWidth: placement.column.preMaximizedWidth
          ),
          at: insertionIndex
        )
      }
    }
    for originalMonitor in state.monitors {
      guard let monitorIndex = monitors.firstIndex(where: {
        $0.id == originalMonitor.id
      }) else { continue }
      for originalWorkspace in originalMonitor.workspaces {
        guard let workspaceIndex = monitors[monitorIndex].workspaces.firstIndex(where: {
          $0.id == originalWorkspace.id
        }) else { continue }
        let selectedWindowID = overviewSelectedWindowID(in: originalWorkspace)
        monitors[monitorIndex].workspaces[workspaceIndex].scrollOffset =
          originalWorkspace.scrollOffset
        monitors[monitorIndex].workspaces[workspaceIndex].targetScrollOffset =
          originalWorkspace.targetScrollOffset
        if let selectedWindowID {
          selectOverviewWindow(
            selectedWindowID,
            in: &monitors[monitorIndex].workspaces[workspaceIndex]
          )
        }
      }
    }
    return monitors
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
      displacedPointerFocusRecovery = nil
      invalidatePointerFocusIntent(recoveringTo: previousSelectedWindowID)
      invalidateSubmittedWorkspaceFocus()
      pendingWorkspaceFocus = nil
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
        pendingAnimatedFocus = PendingAnimatedFocus(
          windowID: windowID,
          previousSelectedWindowID: previousSelectedWindowID,
          monitorID: focusedMonitorID,
          sourceWorkspaceID: workspaceID,
          commandGeneration: commandGeneration,
          focusInputTimestamp: inputTimestamp,
          cursorWarpInputTimestamp: config.input.mouseFollowsFocus
            ? inputTimestamp
            : nil
        )
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
      pendingAnimatedFocus = nil
      invalidateSubmittedCommandFocus()
      invalidateSubmittedWorkspaceFocus()
      pendingWorkspaceFocus = nil
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

private struct OverviewPlacementGroup: Hashable {
  let monitorID: MonitorID
  let workspaceID: WorkspaceID
  let columnIndex: Int
}

private func overviewSelectedWindowID(in workspace: Workspace) -> WindowID? {
  if workspace.focusedLayer == .floating,
    workspace.floatingWindows.indices.contains(workspace.focusedFloatingWindow)
  {
    return workspace.floatingWindows[workspace.focusedFloatingWindow]
  }
  guard workspace.columns.indices.contains(workspace.focusedColumn) else { return nil }
  let column = workspace.columns[workspace.focusedColumn]
  guard column.windows.indices.contains(column.focusedWindow) else { return nil }
  return column.windows[column.focusedWindow]
}

private func selectOverviewWindow(_ windowID: WindowID, in workspace: inout Workspace) {
  if let index = workspace.floatingWindows.firstIndex(of: windowID) {
    workspace.focusedLayer = .floating
    workspace.focusedFloatingWindow = index
    return
  }
  guard let columnIndex = workspace.columns.firstIndex(where: {
    $0.windows.contains(windowID)
  }),
    let windowIndex = workspace.columns[columnIndex].windows.firstIndex(of: windowID)
  else { return }
  workspace.focusedLayer = .tiled
  workspace.focusedColumn = columnIndex
  workspace.columns[columnIndex].focusedWindow = windowIndex
}
