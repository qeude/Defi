import AppKit
import DefiConfig
import DefiCore
import DefiIPC
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation
import OSLog

func layoutWindowIDsOutsideSubmissionScope(
  _ plan: MonitorLayoutPlan,
  monitorID: MonitorID,
  restrictedTo monitorIDs: Set<MonitorID>?
) -> Set<WindowID> {
  monitorIDs?.contains(monitorID) == false
    ? Set(plan.assignments.map(\.windowID))
    : []
}

@NavigationActor
extension Daemon {
  func applyCurrentLayout(
    monitorIDs: Set<MonitorID>? = nil,
    asynchronousPositions: Bool = false,
    updateVisibility: Bool? = nil,
    positionTimeoutSeconds: Float = 0.016,
    animated: Bool = false,
    skipping additionalSkippedWindowIDs: Set<WindowID> = [],
    positionsOnly: Bool = false,
    stagesVisibleBeforeParking: Bool = false,
    postCommitFocus: PostCommitFocus = PostCommitFocus(),
    forceFloatingFrameWrites: Bool = false,
    forcingFloatingFrameWritesFor forcedFloatingWindowIDs: Set<WindowID> = [],
    workspaceTransition: WorkspaceVerticalTransition? = nil,
    commandPerformance: CommandPerformanceContext? = nil,
    source: String = "layout"
  ) {
    guard !restorationInFlight, !shouldShutdown else { return }
    let layoutStartedAt = ProcessInfo.processInfo.systemUptime
    var assignments: [FrameAssignment] = []
    var ribbonFrames: [FrameAssignment] = []
    var borderAssignments: [FrameAssignment] = []
    var nativeFullscreenPlaceholderAssignments: [FrameAssignment] = []
    var nativeFullscreenRibbonFrames: [FrameAssignment] = []
    var hiddenWindowIDs = Set<WindowID>()
    var outOfScopeWindowIDs = Set<WindowID>()
    var cachedMonitorIDs = Set<MonitorID>()
    let viewports = viewportsByMonitor
    let overviewParksWindows = overviewState.isOpen
      && overviewState.usesWorkspaceParking
    let liveMonitorIDs = Set(state.monitors.map(\.id))
    layoutPlansByMonitor = layoutPlansByMonitor.filter {
      liveMonitorIDs.contains($0.key)
    }
    for monitorIndex in state.monitors.indices {
      let monitor = state.monitors[monitorIndex]
      if let monitorIDs, !monitorIDs.contains(monitor.id),
        let cached = layoutPlansByMonitor[monitor.id]
      {
        assignments.append(contentsOf: cached.assignments)
        borderAssignments.append(contentsOf: cached.borderAssignments)
        nativeFullscreenPlaceholderAssignments.append(
          contentsOf: cached.nativeFullscreenPlaceholderAssignments
        )
        nativeFullscreenRibbonFrames.append(contentsOf: cached.nativeFullscreenRibbonFrames)
        hiddenWindowIDs.formUnion(cached.hiddenWindowIDs)
        outOfScopeWindowIDs.formUnion(cached.assignments.map(\.windowID))
        cachedMonitorIDs.insert(monitor.id)
        continue
      }
      guard
        let monitorSnapshot = latestMonitors.first(where: { $0.id == monitor.id })
      else {
        continue
      }
      guard let viewport = viewports[monitor.id] else { continue }
      let otherDisplays = latestMonitors.filter { $0.id != monitor.id }.map(\.physicalFrame)
      // Parking moves a window without resizing it, so its spot follows its real size;
      // the layout size would leave a lasting size mismatch, learnt as width rounding.
      let park = { [windows = state.windows] (assignment: FrameAssignment) -> Rect in
        var frame = assignment.frame
        if let size = windows[assignment.windowID]?.frame {
          frame.width = size.width
          frame.height = size.height
        }
        return parkedFrame(frame, display: monitorSnapshot.physicalFrame,
          visibleFrame: monitorSnapshot.frame, otherDisplays: otherDisplays)
      }
      var monitorAssignments: [FrameAssignment] = []
      var monitorBorderAssignments: [FrameAssignment] = []
      var monitorNativeFullscreenPlaceholderAssignments: [FrameAssignment] = []
      var monitorNativeFullscreenRibbonFrames: [FrameAssignment] = []
      var monitorHiddenWindowIDs = Set<WindowID>()
      for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
        let workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
        let workspaceWindows = workspace.columns
          .flatMap(\.windows)
          .compactMap { state.windows[$0] }
        let layout = computeLayout(
          workspace: workspace,
          viewport: viewport,
          windows: workspaceWindows,
          settings: state.layout,
          excludingWindowIDs: state.nativeFullscreenWindowIDs
        )
        let sizedFrames = layout.map(preserveIntrinsicSize)
        if workspace.id == monitor.activeWorkspace && !overviewParksWindows {
          ribbonFrames.append(contentsOf: sizedFrames)
          let strip = continuousStripFramesForActiveWorkspace(
            sizedFrames,
            viewport: scrollingViewport(
              workspace.columns, viewport: viewport, windowsByID: state.windows,
              settings: state.layout),
            pinned: pinnedWindowIDs(workspace.columns), park: park
          )
          monitorAssignments.append(contentsOf: strip.frames)
          monitorBorderAssignments.append(contentsOf: strip.frames)
          if workspaceTransition?.monitorID != monitor.id {
            monitorHiddenWindowIDs.formUnion(strip.parkedWindowIDs)
          }

          if !state.nativeFullscreenWindowIDs.isEmpty {
            let fullscreenLayout = computeLayout(
              workspace: workspace,
              viewport: viewport,
              windows: workspaceWindows,
              settings: state.layout
            )
            monitorNativeFullscreenRibbonFrames.append(contentsOf: fullscreenLayout.filter {
              state.nativeFullscreenWindowIDs.contains($0.windowID)
            })
            let fullscreenStrip = continuousStripFramesForActiveWorkspace(
              fullscreenLayout, viewport: viewport, park: park
            )
            monitorNativeFullscreenPlaceholderAssignments.append(
              contentsOf: fullscreenStrip.frames.filter {
                state.nativeFullscreenWindowIDs.contains($0.windowID)
                  && fullscreenStrip.visibilityByWindowID[$0.windowID] == .visible
              }
            )
          }

          for assignment in floatingAssignments(in: workspace) {
            monitorBorderAssignments.append(assignment)
            if forceFloatingFrameWrites
              || forcedFloatingWindowIDs.contains(assignment.windowID)
              || platform.isWindowHidden(assignment.windowID)
              || platform.hasPendingFrameTransition(assignment.windowID)
            {
              monitorAssignments.append(assignment)
            }
          }
        } else {
          monitorHiddenWindowIDs.formUnion(sizedFrames.map(\.windowID))
          let floatingFrames = floatingAssignments(in: workspace)
          let parked = (sizedFrames + floatingFrames).map {
            FrameAssignment(windowID: $0.windowID, frame: park($0))
          }
          monitorHiddenWindowIDs.formUnion(floatingFrames.map(\.windowID))
          monitorAssignments.append(contentsOf: parked)
          monitorBorderAssignments.append(contentsOf: parked)
        }
        let parkedScratchpad = floatingAssignments(for: workspace.scratchpadWindows ?? []).map {
          FrameAssignment(windowID: $0.windowID, frame: park($0))
        }
        monitorHiddenWindowIDs.formUnion(parkedScratchpad.map(\.windowID))
        monitorAssignments.append(contentsOf: parkedScratchpad)
        monitorBorderAssignments.append(contentsOf: parkedScratchpad)
      }
      let plan = MonitorLayoutPlan(
        assignments: monitorAssignments,
        borderAssignments: monitorBorderAssignments,
        nativeFullscreenPlaceholderAssignments:
          monitorNativeFullscreenPlaceholderAssignments,
        nativeFullscreenRibbonFrames: monitorNativeFullscreenRibbonFrames,
        hiddenWindowIDs: monitorHiddenWindowIDs
      )
      layoutPlansByMonitor[monitor.id] = plan
      assignments.append(contentsOf: plan.assignments)
      outOfScopeWindowIDs.formUnion(
        layoutWindowIDsOutsideSubmissionScope(
          plan,
          monitorID: monitor.id,
          restrictedTo: monitorIDs
        )
      )
      borderAssignments.append(contentsOf: plan.borderAssignments)
      nativeFullscreenPlaceholderAssignments.append(
        contentsOf: plan.nativeFullscreenPlaceholderAssignments
      )
      nativeFullscreenRibbonFrames.append(contentsOf: plan.nativeFullscreenRibbonFrames)
      hiddenWindowIDs.formUnion(plan.hiddenWindowIDs)
    }
    let skipped = additionalSkippedWindowIDs.union(outOfScopeWindowIDs)
      .union(state.nativeFullscreenWindowIDs)
      .union(activelyResizedWindowID.map { Set([$0]) } ?? [])
    let platformAssignments =
      asynchronousPositions
      ? assignments.map(roundAnimatedPosition)
      : assignments
    let selectedWindowID = activeMonitorID.flatMap {
      state.selectedWindowID(on: $0)
    }
    // macOS raises only the window it focuses; the rest of a scratchpad brought forward would stay
    // behind the strip.
    let shownScratchpad = state.scratchpadWindowIDs.filter { windowID in
      state.monitors.contains { monitor in
        monitor.workspaces.contains { $0.id == monitor.activeWorkspace && $0.floatingWindows.contains(windowID) }
      }
    }
    let raise = scratchpadRaise(shown: shownScratchpad, selected: selectedWindowID,
      raised: shownScratchpadWindowIDs)
    if !raise.order.isEmpty { platform.raiseWindows(raise.order) }
    shownScratchpadWindowIDs = raise.raised
    let tracesWindowCreation = platform.hasNewlyDiscoveredWindows
    let borderStartedAt = ProcessInfo.processInfo.systemUptime
    let layoutMS =
      (ProcessInfo.processInfo.systemUptime - layoutStartedAt) * 1_000
    platform.recordPerformanceTrace(
      "frame-submit source=\(source) cg=\(commandPerformance?.generation.description ?? "none") layoutMs=\(String(format: "%.2f", layoutMS))"
    )
    platform.stageWindowBorderSelection(selectedWindowID)
    // Without animations (or with Reduce Motion), the overlay and its pictures are not needed.
    platform.windowProxiesEnabled = animationsEnabled
    platform.windowProxySpring = config.animation
    platform.windowProxyDroppedWindowID =
      source == "mouse-drop-animation" ? proxyDroppedWindowID : nil
    proxyDroppedWindowID = nil
    // Incoming windows enter opposite to where the outgoing workspace leaves.
    // Consumed either way so the history stays current; with animations off (Reduce
    // Motion or `enabled = false`) the switch is immediate.
    let workspaceShifts = consumeWorkspaceSwitchShifts(source: source)
    let shifts = animationsEnabled
    platform.layoutFloatingWindowIDs = Set(state.windows.filter(\.value.floating).keys)
    platform.scratchpadWindowIDs = Set(state.scratchpadWindowIDs)
    platform.windowProxyMonitors = state.monitors.compactMap { monitor in
      viewports[monitor.id].map { viewport in
        WindowProxyMonitor(viewport: viewport,
          windowIDs: Set(monitor.workspaces.flatMap {
            $0.columns.flatMap(\.windows) + $0.floatingWindows + ($0.scratchpadWindows ?? [])
          }),
          workspaceShift: shifts ? workspaceShifts[monitor.id] : nil,
          laidOut: !cachedMonitorIDs.contains(monitor.id))
      }
    }
    platform.nativeFullscreenRibbonPlaceholders = Dictionary(
      nativeFullscreenRibbonFrames.compactMap { assignment in
        guard let window = state.windows[assignment.windowID],
          let monitorID = state.monitorID(containing: assignment.windowID)
        else { return nil }
        return (window.id, NativeFullscreenPlaceholder(windowID: window.id, monitorID: monitorID,
          appID: window.appID, title: window.title, frame: assignment.frame))
      }
    ) { first, _ in first }
    platform.pinnedWindowIDs = Set(state.monitors.flatMap { monitor in
      monitor.workspaces.filter { $0.id == monitor.activeWorkspace }.flatMap { pinnedWindowIDs($0.columns) }
    })
    platform.apply(
      platformAssignments,
      ribbonFrames: ribbonFrames,
      hiddenWindowIDs: hiddenWindowIDs,
      skipping: skipped,
      asynchronousPositionTimeoutSeconds: positionTimeoutSeconds,
      animated: animated,
      positionsOnly: positionsOnly,
      updateVisibility: updateVisibility ?? !asynchronousPositions,
      stagesVisibleBeforeParking: stagesVisibleBeforeParking,
      focusWindowIDAfterCommit: postCommitFocus.windowID,
      focusInputTimestampAfterCommit: postCommitFocus.inputTimestamp,
      cursorWarpWindowIDAfterCommit: postCommitFocus.cursorWarpWindowID,
      cursorWarpInputTimestampAfterCommit: postCommitFocus.cursorWarpInputTimestamp,
      focusCompletionAfterCommit: postCommitFocus.completion,
      cursorWarpIsCurrentAfterCommit: postCommitFocus.isCursorWarpCurrent,
      focusRequestIDAfterCommit: postCommitFocus.requestID,
      acceptedFrameHandler: { [weak self] acceptedFrames in
        guard let self else { return }
        for (windowID, frame) in acceptedFrames {
          if !positionsOnly,
            let requested = platformAssignments.first(where: { $0.windowID == windowID })?.frame
          {
            state.acceptTiledWindowFrame(frame, requested: requested, for: windowID, settled: false)
          } else {
            state.updateWindowFrame(frame, for: windowID)
          }
        }
      },
      commandPerformance: commandPerformance,
      source: source
    )
    if timerFrequencyHz == 0 { scheduleIdleTick() }
    let liveWindowID = activelyResizedWindowID
    let borderConfig = config.decorations.borders
    // A display showing a fullscreen Space draws no border or dim over it.
    let fullscreenHiddenWindowIDs = Set(borderAssignments.map(\.windowID)).subtracting(
      borderAssignmentsOutsideFullscreen(
        borderAssignments,
        fullscreenWindowIDs: platform.activeNativeFullscreenWindowIDs.subtracting(platform.returnedNativeFullscreenWindowIDs),
        monitorOf: state.monitorID(containing:)
      ).map(\.windowID))
    platform.enqueuePresentation {
      // Hidden in place, not dropped: panels ordered in again appear only after macOS's
      // Space slide back.
      $0.presentHideBordersOnFullscreenDisplays(fullscreenHiddenWindowIDs)
      $0.presentUpdateWindowBorders(
        frames: borderAssignments,
        selectedWindowID: selectedWindowID,
        liveWindowID: liveWindowID,
        config: borderConfig
      )
    }
    platform.updateNativeFullscreenPlaceholders(
      nativeFullscreenPlaceholderAssignments.compactMap { assignment in
        guard let window = state.windows[assignment.windowID],
          let monitorID = state.monitorID(containing: assignment.windowID)
        else { return nil }
        return NativeFullscreenPlaceholder(
          windowID: window.id,
          monitorID: monitorID,
          appID: window.appID,
          title: window.title,
          frame: assignment.frame
        )
      },
      selectedWindowID: selectedWindowID,
      stackingWindowID: assignments.first {
        !hiddenWindowIDs.contains($0.windowID)
      }?.windowID ?? assignments.first?.windowID,
      suppressedMonitorIDs: Set(platform.activeNativeFullscreenWindowIDs.compactMap {
        state.monitorID(containing: $0)
      })
    )
    if tracesWindowCreation {
      let elapsedMS =
        (ProcessInfo.processInfo.systemUptime - borderStartedAt) * 1_000
      platform.recordPerformanceTrace(
        "initial-border-prepare ms=\(String(format: "%.2f", elapsedMS))"
      )
    }
  }
}

extension Daemon {
  /// Vertical travel when a monitor's active workspace changed since the last layout,
  /// whichever path switched it (command, Dock, Command-Tab, focus): the overlay then
  /// always moves workspaces vertically, in their stacking order.
  func consumeWorkspaceSwitchShifts(source: String) -> [MonitorID: Double] {
    var shifts: [MonitorID: Double] = [:]
    for monitor in state.monitors {
      let previous = proxyActiveWorkspaces[monitor.id]
      proxyActiveWorkspaces[monitor.id] = monitor.activeWorkspace
      // The stack as it was: the workspace left may since have been removed.
      let order = proxyWorkspaceOrders.updateValue(monitor.workspaces.map(\.id), forKey: monitor.id)
        ?? monitor.workspaces.map(\.id)
      guard !source.hasPrefix("overview"), let previous,
        let height = latestMonitors.first(where: { $0.id == monitor.id })?.physicalFrame.height
      else { continue }
      shifts[monitor.id] = workspaceSwitchShift(from: previous, to: monitor.activeWorkspace,
        order: order, height: height)
    }
    return shifts
  }
}

/// Vertical travel of a switch within one monitor's workspace stack, as it was before
/// the switch; nil when the active workspace did not change.
func workspaceSwitchShift(from previous: WorkspaceID, to active: WorkspaceID,
  order: [WorkspaceID], height: Double) -> Double? {
  guard previous != active else { return nil }
  let from = order.firstIndex(of: previous) ?? order.count
  // A workspace created since joins the end of the stack.
  let to = order.firstIndex(of: active) ?? order.count
  // Niri's stack: moving down slides the content up.
  return (to > from ? -1 : 1) * height
}

/// Leaves out windows on a display that shows a native fullscreen Space.
func borderAssignmentsOutsideFullscreen(
  _ assignments: [FrameAssignment], fullscreenWindowIDs: Set<WindowID>, monitorOf: (WindowID) -> MonitorID?
) -> [FrameAssignment] {
  let fullscreenMonitorIDs = Set(fullscreenWindowIDs.compactMap(monitorOf))
  guard !fullscreenMonitorIDs.isEmpty else { return assignments }
  return assignments.filter { monitorOf($0.windowID).map { !fullscreenMonitorIDs.contains($0) } ?? true }
}

/// Raises a shown scratchpad once as it comes forward with the focus, the focused window last.
/// Raised again while another window has the focus, its windows swapped places at every layout.
func scratchpadRaise(shown: [WindowID], selected: WindowID?, raised: Set<WindowID>)
  -> (order: [WindowID], raised: Set<WindowID>)
{
  guard let selected, shown.contains(selected) else { return ([], []) }
  let focused = Set(shown)
  return (focused.isSubset(of: raised) ? [] : shown.filter { $0 != selected } + [selected], focused)
}
