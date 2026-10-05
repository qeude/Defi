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

struct OverviewToggleRequest: Equatable, Sendable {
  let generation: UInt64
  let isOpen: Bool
  let ribbonPrototype: Bool
}

enum OverviewToggleDecision: Equatable, Sendable {
  case denied
  case requested(OverviewToggleRequest)
}

struct OverviewToggleSnapshot: Equatable, Sendable {
  let generation: UInt64
  let actualIsOpen: Bool
  let sessionGeneration: UInt64?
  let desiredIsOpen: Bool?
}

/// Synchronous bridge for navigation requests and main-actor presentation callbacks.
final class OverviewToggleState: @unchecked Sendable {
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var actualIsOpen = false
  private var sessionGeneration: UInt64?
  private var completedSelectionSession: UInt64?
  private var desiredIsOpen: Bool?
  private var applyingGeneration: UInt64?

  func toggle(
    ribbonPrototype: Bool,
    screenCaptureAccessGranted: Bool
  ) -> OverviewToggleDecision {
    lock.lock()
    defer { lock.unlock() }
    let targetIsOpen = !(desiredIsOpen ?? actualIsOpen)
    guard !targetIsOpen || !ribbonPrototype || screenCaptureAccessGranted else {
      return .denied
    }
    completedSelectionSession = nil
    generation &+= 1
    desiredIsOpen = targetIsOpen
    return .requested(
      OverviewToggleRequest(
        generation: generation,
        isOpen: targetIsOpen,
        ribbonPrototype: targetIsOpen && ribbonPrototype
      )
    )
  }

  func requestClose() -> OverviewToggleRequest {
    lock.lock()
    defer { lock.unlock() }
    completedSelectionSession = nil
    generation &+= 1
    desiredIsOpen = false
    return OverviewToggleRequest(
      generation: generation,
      isOpen: false,
      ribbonPrototype: false
    )
  }

  func isCurrent(_ request: OverviewToggleRequest) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return generation == request.generation
  }

  func beginApplying(_ request: OverviewToggleRequest) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard generation == request.generation else { return false }
    applyingGeneration = request.generation
    return true
  }

  func finishApplying(_ request: OverviewToggleRequest, actualIsOpen: Bool) {
    lock.lock()
    defer { lock.unlock() }
    guard applyingGeneration == request.generation else { return }
    applyingGeneration = nil
    self.actualIsOpen = actualIsOpen
    if generation == request.generation {
      desiredIsOpen = nil
    }
  }

  func recordControllerState(_ isOpen: Bool, sessionGeneration: UInt64? = nil) {
    lock.lock()
    defer { lock.unlock() }
    actualIsOpen = isOpen
    if isOpen { completedSelectionSession = nil }
    self.sessionGeneration = sessionGeneration
    guard let applyingGeneration else {
      generation &+= 1
      desiredIsOpen = nil
      return
    }
    guard generation == applyingGeneration, desiredIsOpen == isOpen else { return }
    desiredIsOpen = nil
  }

  func isCurrentSession(_ session: UInt64?) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return session != nil && session == sessionGeneration
      && actualIsOpen && desiredIsOpen != false
  }

  func completeSelectionExit(_ session: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    guard actualIsOpen, desiredIsOpen != false, sessionGeneration == session else { return }
    completedSelectionSession = session
  }

  func selectionWarpIsCurrent(_ session: UInt64?) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard let session else { return false }
    return completedSelectionSession == session
      || (actualIsOpen && desiredIsOpen != false && sessionGeneration == session)
  }

  func snapshot() -> OverviewToggleSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return OverviewToggleSnapshot(
      generation: generation,
      actualIsOpen: actualIsOpen,
      sessionGeneration: sessionGeneration,
      desiredIsOpen: desiredIsOpen
    )
  }
}

@NavigationActor
extension Daemon {
  func toggleOverview(ribbonPrototype: Bool = false) -> CommandResponse {
    guard !state.monitors.isEmpty else {
      return .failure("overview unavailable before monitor discovery")
    }
    let decision = overviewToggleState.toggle(
      ribbonPrototype: ribbonPrototype,
      screenCaptureAccessGranted: !ribbonPrototype || CGPreflightScreenCaptureAccess()
    )
    guard case .requested(let request) = decision else {
      return .failure("ribbon prototype requires existing Screen Recording access")
    }
    applyOverviewToggle(request)
    guard request.isOpen && request.ribbonPrototype else { return .success() }
    return .success(
      "Requested visual ribbon prototype: Left/Right preview, Escape exits; native selection commit is disabled."
    )
  }

  func updateOverviewIfOpen() {
    presentOverview()
  }

  private func applyOverviewToggle(_ request: OverviewToggleRequest) {
    let snapshot = makeOverviewSnapshot(), config = config, layout = state.layout
    platform.experimentalSurfaceRibbonEnabled = config.animation.experimentalWindowRepresentations
    DispatchQueue.main.async { [self] in
      guard overviewToggleState.beginApplying(request) else { return }
      let controller = overviewController ?? makeOverviewController()
      overviewController = controller
      if request.isOpen {
        if controller.isOpen && controller.usesRibbonPrototype != request.ribbonPrototype {
          controller.close()
        }
        if controller.isOpen {
          controller.update(snapshot: snapshot, layout: layout,
            borders: config.decorations.borders, animation: config.animation,
            zoom: config.overview.zoom,
            windowCornerRadius: config.overview.windowCornerRadius,
            windowPreviewsEnabled: config.overview.windowPreviews,
            experimentalSurfaceTransitions: config.overview.experimentalSurfaceTransitions,
            experimentalRibbonRepresentations: config.animation.experimentalWindowRepresentations)
        } else {
          controller.toggle(snapshot: snapshot, layout: layout,
            borders: config.decorations.borders, animation: config.animation,
            zoom: config.overview.zoom,
            windowCornerRadius: config.overview.windowCornerRadius,
            windowPreviewsEnabled: config.overview.windowPreviews,
            experimentalSurfaceTransitions: config.overview.experimentalSurfaceTransitions,
            ribbonPrototype: request.ribbonPrototype)
        }
      } else {
        controller.close()
      }
      overviewToggleState.finishApplying(request, actualIsOpen: controller.isOpen)
      publishOverviewState()
    }
  }

  private func presentOverview() {
    let snapshot = makeOverviewSnapshot(), config = config, layout = state.layout
    platform.experimentalSurfaceRibbonEnabled = config.animation.experimentalWindowRepresentations
    DispatchQueue.main.async { [self] in
      let controller = overviewController ?? makeOverviewController()
      overviewController = controller
      if controller.isOpen {
        controller.update(snapshot: snapshot, layout: layout,
          borders: config.decorations.borders, animation: config.animation,
          zoom: config.overview.zoom,
          windowCornerRadius: config.overview.windowCornerRadius,
          windowPreviewsEnabled: config.overview.windowPreviews,
          experimentalSurfaceTransitions: config.overview.experimentalSurfaceTransitions,
          experimentalRibbonRepresentations: config.animation.experimentalWindowRepresentations)
      } else {
        controller.prepare(windowPreviewsEnabled: config.overview.windowPreviews,
          snapshot: snapshot, layout: layout, zoom: config.overview.zoom,
          experimentalSurfaceTransitions: config.overview.experimentalSurfaceTransitions,
          experimentalRibbonRepresentations: config.animation.experimentalWindowRepresentations,
          windowCornerRadius: config.overview.windowCornerRadius)
      }
      publishOverviewState()
    }
  }

  func closeOverview() {
    let request = overviewToggleState.requestClose()
    DispatchQueue.main.async { [self] in
      guard overviewToggleState.beginApplying(request) else { return }
      overviewController?.close()
      overviewToggleState.finishApplying(
        request,
        actualIsOpen: overviewController?.isOpen ?? false
      )
      publishOverviewState()
    }
  }

  @MainActor private func makeOverviewController() -> OverviewController {
    OverviewController(
      focusWindow: { [weak self] windowID, appID, monitorID, workspaceID in
        let overviewGeneration = self?.overviewController?.sessionGeneration
        let offsets = self?.overviewController?.scrollOffsets ?? [:]
        NavigationActor.enqueue {
          self?.focusFromOverview(windowID: windowID, appID: appID,
            monitorID: monitorID, workspaceID: workspaceID, overviewGeneration: overviewGeneration, offsets: offsets)
        }
      },
      focusWorkspace: { [weak self] monitorID, workspaceID in
        let overviewGeneration = self?.overviewController?.sessionGeneration
        let offsets = self?.overviewController?.scrollOffsets ?? [:]
        NavigationActor.enqueue {
          self?.focusWorkspaceFromOverview(monitorID: monitorID, workspaceID: workspaceID,
            overviewGeneration: overviewGeneration, offsets: offsets)
        }
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
        overviewToggleState.recordControllerState(isOpen,
          sessionGeneration: overviewController?.sessionGeneration)
        overviewInputMode(isOpen)
        publishOverviewState()
        let parksWindows = overviewController?.usesWorkspaceParking == true
        let timestamp = ProcessInfo.processInfo.systemUptime
        NavigationActor.enqueue { [self] in
          overviewExitPreparationActive = false
          overviewState.isOpen = isOpen
          if isOpen {
            overviewEditedMonitorIDs.removeAll()
            overviewFloatingFrameWriteIDs.removeAll()
          }
          overviewState.usesWorkspaceParking = parksWindows
          overviewOpenedAt = isOpen ? timestamp : nil
          platform.setOverviewPresentationActive(isOpen)
          if parksWindows || (!isOpen && !overviewEditedMonitorIDs.isEmpty) {
            applyCurrentLayout(monitorIDs: parksWindows ? nil : overviewEditedMonitorIDs,
              asynchronousPositions: true, updateVisibility: true,
              positionTimeoutSeconds: 0.05, stagesVisibleBeforeParking: !isOpen,
              forcingFloatingFrameWritesFor: overviewFloatingFrameWriteIDs,
              source: isOpen ? "overview-park" : "overview-restore")
          }
          if !isOpen {
            overviewEditedMonitorIDs.removeAll()
            overviewFloatingFrameWriteIDs.removeAll()
          }
        }
      },
      presentationChanged: { [weak self] in self?.publishOverviewState() },
      idlePreparationRequested: { [weak self] in
        NavigationActor.enqueue { [weak self] in self?.updateOverviewIfOpen() }
      },
      waitsForNativeSelectionCommit: true,
      layoutCommand: { [weak self] command, windowID, appID, monitorID, workspaceID, generation in
        NavigationActor.enqueue { [weak self] in
          guard let self, overviewToggleState.isCurrentSession(generation) else { return }
          _ = editLayoutFromOverview(command, intent: OverviewWindowIntent(
            windowID: windowID, expectedAppID: appID,
            sourceMonitorID: monitorID, sourceWorkspaceID: workspaceID))
        }
      },
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

  func editLayoutFromOverview(_ command: Command, intent: OverviewWindowIntent) -> CommandResponse {
    guard overviewState.isOpen, !overviewExitPreparationActive else {
      return .failure("overview is closed or committing selection")
    }
    do {
      let floatingUpdates = try applyOverviewLayoutCommand(command, intent: intent,
        viewports: viewportsByMonitor, state: &state)
      overviewEditedMonitorIDs.insert(intent.sourceMonitorID)
      floatingWindowFrames.merge(floatingUpdates) { _, new in new }
      overviewFloatingFrameWriteIDs.formUnion(floatingUpdates.keys)
      platform.recordPerformanceTrace("overview-layout window=\(intent.windowID.rawValue) command=\(command)")
      commandGeneration &+= 1
      synchronizeScrollOffsets(state: &state, viewports: viewportsByMonitor)
      snapScrollOffsetsToTargets()
      persistTopology()
      updateOverviewIfOpen()
      return .success()
    } catch {
      platform.recordPerformanceTrace("overview-layout-rejected error=\(error)")
      updateOverviewIfOpen()
      return .failure(String(describing: error))
    }
  }

  @MainActor func publishOverviewState() {
    guard let controller = overviewController else { return }
    var projection = OverviewPresentationState(
      isOpen: controller.isOpen, usesWorkspaceParking: controller.usesWorkspaceParking,
      panelCount: controller.panelCount, retainedPanelCount: controller.retainedPanelCount,
      permission: controller.previewPermissionState.rawValue,
      captures: controller.inFlightPreviewCount, previews: controller.previewCacheCount,
      memoryBytes: controller.rememberedPreviewMemoryBytes, failures: controller.previewFailureCount,
      firstPreviewMs: controller.firstPreviewMs, lastPreviewMs: controller.lastPreviewMs,
      receivedPreviews: controller.receivedPreviewCount
    )
    projection.renderPerformance = controller.renderPerformance
    projection.sessionGeneration = controller.sessionGeneration
    projection.surfaceCapture = controller.surfaceCaptureState
    projection.surfaceStreams = controller.surfaceStreamCount
    projection.surfacePoolBytes = controller.surfaceEstimatedPoolBytes
    projection.surfaceTransitions = controller.surfaceTransitionCount
    projection.surfaceFallbacks = controller.surfaceFallbackCount
    projection.previewClosings = controller.previewClosingCount
    projection.surfaceAcquireMs = controller.surfaceAcquireMs
    projection.openingTransitionHistory = controller.openingTransitionHistory
    projection.ribbonSurfaceTransitions = controller.ribbonSurfaceTransitions
    projection.ribbonSurfaceFallbacks = controller.ribbonSurfaceFallbacks
    projection.ribbonSurfaceFallbackReason = controller.ribbonSurfaceFallbackReason
    projection.ribbonSurfacePresenting = controller.ribbonSurfacePresenting
    NavigationActor.enqueue { [self] in
      overviewState = projection
      if overviewExitPreparationActive { overviewState.usesWorkspaceParking = false }
    }
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
    workspaceID: WorkspaceID,
    overviewGeneration: UInt64?,
    offsets: [MonitorID: [WorkspaceID: Double]]
  ) {
    guard overviewToggleState.isCurrentSession(overviewGeneration) else { return }
    overviewEditedMonitorIDs.formUnion(applyOverviewScrollOffsets(offsets, state: &state))
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
      if overviewState.isOpen {
        prepareOverviewExit(on: focusedMonitorID, selectedWindowID: windowID,
          inputTimestamp: inputTimestamp, overviewGeneration: overviewGeneration)
        return
      }
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
      finishOverviewExit(overviewGeneration: overviewGeneration)
    }
  }

  private func focusWorkspaceFromOverview(
    monitorID: MonitorID,
    workspaceID: WorkspaceID,
    overviewGeneration: UInt64?,
    offsets: [MonitorID: [WorkspaceID: Double]]
  ) {
    guard overviewToggleState.isCurrentSession(overviewGeneration) else { return }
    overviewEditedMonitorIDs.formUnion(applyOverviewScrollOffsets(offsets, state: &state))
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
      prepareOverviewExit(on: monitorID, selectedWindowID: selectedWindowID,
        inputTimestamp: inputTimestamp, overviewGeneration: overviewGeneration)
    } catch {
      platform.recordPerformanceTrace("overview-workspace-rejected error=\(error)")
      updateOverviewIfOpen()
      finishOverviewExit(overviewGeneration: overviewGeneration)
    }
  }

  private func prepareOverviewExit(
    on monitorID: MonitorID, selectedWindowID: WindowID?, inputTimestamp: TimeInterval,
    overviewGeneration: UInt64?
  ) {
    // The overview covers these writes. Prepare final native geometry once,
    // rather than animating or parking real windows on every overview arrow.
    let restoresAllMonitors = overviewState.usesWorkspaceParking
    let affectedMonitorIDs = overviewEditedMonitorIDs.union([monitorID])
    overviewExitPreparationActive = true
    overviewState.usesWorkspaceParking = false
    scrollAnimations = scrollAnimations.filter { !restoresAllMonitors && !affectedMonitorIDs.contains($0.key.monitorID) }
    for index in state.monitors.indices where restoresAllMonitors || affectedMonitorIDs.contains(state.monitors[index].id) {
      for workspaceIndex in state.monitors[index].workspaces.indices {
        state.monitors[index].workspaces[workspaceIndex].scrollOffset =
          state.monitors[index].workspaces[workspaceIndex].targetScrollOffset
      }
    }
    let generation = commandGeneration
    applyCurrentLayout(monitorIDs: restoresAllMonitors ? nil : affectedMonitorIDs, asynchronousPositions: true,
      updateVisibility: true, positionTimeoutSeconds: 0.05,
      stagesVisibleBeforeParking: true, focusWindowIDAfterCommit: selectedWindowID,
      focusInputTimestampAfterCommit: selectedWindowID == nil ? nil : inputTimestamp,
      cursorWarpWindowIDAfterCommit: config.input.mouseFollowsFocus ? selectedWindowID : nil,
      cursorWarpInputTimestampAfterCommit: config.input.mouseFollowsFocus ? inputTimestamp : nil,
      cursorWarpIsCurrentAfterCommit: { [weak self] in
        guard let self else { return false }
        return overviewToggleState.selectionWarpIsCurrent(overviewGeneration)
          && commandGeneration == generation && state.selectedWindowID(on: monitorID) == selectedWindowID
      },
      forcingFloatingFrameWritesFor: overviewFloatingFrameWriteIDs,
      source: "overview-exit-prepare")
    persistTopology()
    updateMenuBar()
    updateOverviewIfOpen()
    let windowIDs = Set(state.monitors.filter { restoresAllMonitors || affectedMonitorIDs.contains($0.id) }.flatMap {
      $0.workspaces.flatMap { $0.columns.flatMap(\.windows) + $0.floatingWindows }
    })
    Task { @NavigationActor [weak self] in
      for attempt in 0..<150 {
        guard let self, overviewToggleState.isCurrentSession(overviewGeneration) else { return }
        if commandGeneration != generation {
          finishOverviewExit(overviewGeneration: overviewGeneration)
          return
        }
        let ready = platform.overviewExitFramesReady(windowIDs: windowIDs)
        if ready || attempt == 149 {
          if !ready { platform.recordPerformanceTrace("overview-exit-prepare-timeout") }
          finishOverviewExit(overviewGeneration: overviewGeneration, nativeFramesReady: ready)
          return
        }
        try? await Task.sleep(for: .milliseconds(10))
      }
    }
  }

  private func finishOverviewExit(overviewGeneration: UInt64?, nativeFramesReady: Bool = false) {
    DispatchQueue.main.async { [weak self] in
      if nativeFramesReady, let overviewGeneration,
        self?.overviewController?.sessionGeneration == overviewGeneration {
        self?.overviewToggleState.completeSelectionExit(overviewGeneration)
      }
      self?.overviewController?.selectionCommitCompleted(sessionGeneration: overviewGeneration, nativeFramesReady: nativeFramesReady)
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
  var sessionGeneration: UInt64 = 0
  var renderPerformance = "none"
  var surfaceCapture = "disabled"
  var surfaceStreams = 0
  var surfacePoolBytes = 0
  var surfaceTransitions = 0
  var surfaceFallbacks = 0
  var previewClosings = 0
  var surfaceAcquireMs: Double = 0
  var openingTransitionHistory = "none"
  var ribbonSurfaceTransitions = 0
  var ribbonSurfaceFallbacks = 0
  var ribbonSurfaceFallbackReason = "none"
  var ribbonSurfacePresenting = false
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
