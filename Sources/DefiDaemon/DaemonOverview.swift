import CoreGraphics
import DefiCore
import DefiIPC
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation

func overviewRibbonPrototypeRequested(in rawCommand: String) -> Bool {
  let tokens = rawCommand.split(whereSeparator: \.isWhitespace)
  return tokens.first == "toggle-overview"
    && tokens.dropFirst().contains("--ribbon-prototype")
}

@NavigationActor
extension Daemon {
  func toggleOverview(ribbonPrototype: Bool = false) -> CommandResponse {
    guard !state.monitors.isEmpty else {
      return .failure("overview unavailable before monitor discovery")
    }
    guard !ribbonPrototype || overviewState.isOpen || CGPreflightScreenCaptureAccess() else {
      return .failure("ribbon prototype requires existing Screen Recording access")
    }
    presentOverview(toggling: true, ribbonPrototype: ribbonPrototype)
    guard ribbonPrototype else { return .success() }
    return .success(
      "Requested visual ribbon prototype: Left/Right preview, Escape exits; native selection commit is disabled."
    )
  }

  func updateOverviewIfOpen() {
    presentOverview(toggling: false)
  }

  private func presentOverview(toggling: Bool, ribbonPrototype: Bool = false) {
    let snapshot = makeOverviewSnapshot(), config = config, layout = state.layout
    DispatchQueue.main.async { [self] in
      let controller = overviewController ?? makeOverviewController()
      overviewController = controller
      if toggling {
        controller.toggle(snapshot: snapshot, layout: layout, borders: config.decorations.borders,
          animation: config.animation, zoom: config.overview.zoom,
          windowCornerRadius: config.overview.windowCornerRadius,
          windowPreviewsEnabled: config.overview.windowPreviews,
          ribbonPrototype: ribbonPrototype)
      } else if controller.isOpen {
        controller.update(snapshot: snapshot, layout: layout, borders: config.decorations.borders,
          animation: config.animation, zoom: config.overview.zoom,
          windowCornerRadius: config.overview.windowCornerRadius,
          windowPreviewsEnabled: config.overview.windowPreviews)
      } else {
        controller.prepare(windowPreviewsEnabled: config.overview.windowPreviews)
      }
      publishOverviewState()
    }
  }

  func closeOverview() {
    DispatchQueue.main.async { [self] in
      overviewController?.close()
      publishOverviewState()
    }
  }

  @MainActor private func makeOverviewController() -> OverviewController {
    OverviewController(
      focusWindow: { [weak self] windowID, appID, monitorID, workspaceID in
        NavigationActor.enqueue {
          self?.focusFromOverview(windowID: windowID, appID: appID,
            monitorID: monitorID, workspaceID: workspaceID)
        }
      },
      focusWorkspace: { [weak self] monitorID, workspaceID in
        NavigationActor.enqueue { self?.focusWorkspaceFromOverview(monitorID: monitorID, workspaceID: workspaceID) }
      },
      drop: { [weak self] windowID, appID, sourceMonitorID, sourceWorkspaceID, target in
        NavigationActor.enqueue {
          self?.dropFromOverview(windowID: windowID, appID: appID,
            sourceMonitorID: sourceMonitorID, sourceWorkspaceID: sourceWorkspaceID, target: target)
        }
      },
      activateMonitor: { [weak self] monitorID in
        NavigationActor.enqueue {
          guard self?.state.monitors.contains(where: { $0.id == monitorID }) == true else { return }
          self?.activeMonitorID = monitorID
        }
      },
      openStateChanged: { [weak self] isOpen in
        guard let self else { return }
        overviewInputMode(isOpen)
        publishOverviewState()
        let parksWindows = overviewController?.usesWorkspaceParking == true
        let timestamp = ProcessInfo.processInfo.systemUptime
        NavigationActor.enqueue { [self] in
          overviewState.isOpen = isOpen
          overviewState.usesWorkspaceParking = parksWindows
          overviewOpenedAt = isOpen ? timestamp : nil
          platform.setWindowBordersSuppressed(isOpen)
          if parksWindows {
            applyCurrentLayout(asynchronousPositions: true, updateVisibility: true,
              positionTimeoutSeconds: 0.05, stagesVisibleBeforeParking: !isOpen,
              source: isOpen ? "overview-park" : "overview-restore")
          }
        }
      },
      presentationChanged: { [weak self] in self?.publishOverviewState() },
      commitScrollOffsets: { [weak self] offsets in
        NavigationActor.enqueue { [weak self] in
          guard let self else { return }
          let changedMonitorIDs = applyOverviewScrollOffsets(offsets, state: &state)
          guard !changedMonitorIDs.isEmpty else { return }
          persistTopology()
          guard !overviewState.usesWorkspaceParking else { return }
          applyCurrentLayout(monitorIDs: changedMonitorIDs, asynchronousPositions: true,
            updateVisibility: false, positionTimeoutSeconds: 0.05, source: "overview-scroll-commit")
        }
      }
    )
  }

  @MainActor func publishOverviewState() {
    guard let controller = overviewController else { return }
    let projection = OverviewPresentationState(
      isOpen: controller.isOpen, usesWorkspaceParking: controller.usesWorkspaceParking,
      panelCount: controller.panelCount, retainedPanelCount: controller.retainedPanelCount,
      permission: controller.previewPermissionState.rawValue,
      captures: controller.inFlightPreviewCount, previews: controller.previewCacheCount,
      memoryBytes: controller.rememberedPreviewMemoryBytes, failures: controller.previewFailureCount,
      firstPreviewMs: controller.firstPreviewMs, lastPreviewMs: controller.lastPreviewMs,
      receivedPreviews: controller.receivedPreviewCount
    )
    NavigationActor.enqueue { [self] in overviewState = projection }
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
      focus.queueCommand(nil)
      invalidateSubmittedCommandFocus()
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
      persistTopology()
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
      focus.queueCommand(nil)
      invalidateSubmittedCommandFocus()
      invalidateSubmittedWorkspaceFocus()
      focus.queueWorkspace(nil)
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
      persistTopology()
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
      persistTopology()
      updateMenuBar()
      updateOverviewIfOpen()
      needsDesktopSync = true
    } catch {
      platform.recordPerformanceTrace("overview-drop-rejected error=\(error)")
      updateOverviewIfOpen()
    }
  }
}

struct OverviewPresentationState: Sendable {
  var isOpen = false
  var usesWorkspaceParking = false
  var panelCount = 0
  var retainedPanelCount = 0
  var permission: String?
  var captures = 0
  var previews = 0
  var memoryBytes = 0
  var failures = 0
  var firstPreviewMs: Double?
  var lastPreviewMs: Double?
  var receivedPreviews = 0
}
