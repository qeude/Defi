import DefiModel
import DefiRuntime

extension Daemon {
  /// Runs on the existing held-button tick, without a desktop snapshot or AX read.
  @discardableResult
  func advanceDragEdgeScrolling(pointer: (x: Double, y: Double), buttonDown: Bool,
    now: Double) -> Bool
  {
    guard buttonDown, var drag = dragEdgeScrolling else { return false }
    let monitorFrames = Dictionary(uniqueKeysWithValues: latestMonitors.map { ($0.id, $0.physicalFrame) })
    guard !mouseGesturePreempted,
      drag.isCurrent(generation: mouseGestureGeneration, state: state,
        viewports: viewportsByMonitor, monitorFrames: monitorFrames)
    else {
      preemptMouseGesture()
      return false
    }
    let changed = drag.advance(pointer: pointer, now: now, refreshRate: activeDisplayRefreshRate, state: &state)
    dragEdgeScrolling = drag
    mouseGestureScrollAnchor = drag.currentAnchor(state: state)
    presentMouseDropPreview(drag.windowID, pointer: pointer, force: changed)
    if changed, !platform.windowProxyCarrying {
      // Capture is optional. The existing diffed, asynchronous position lane
      // reveals columns directly when no proxy can carry the strip.
      applyCurrentLayout(monitorIDs: [drag.initialAnchor.monitorID], asynchronousPositions: true,
        updateVisibility: true, skipping: [drag.windowID], positionsOnly: true,
        source: "drag-edge-scroll")
    }
    return changed
  }

  func presentMouseDropPreview(_ windowID: WindowID, pointer: (x: Double, y: Double), force: Bool = false) {
    let monitorFrames = Dictionary(uniqueKeysWithValues: latestMonitors.map { ($0.id, $0.physicalFrame) })
    let target = mouseDropTarget(windowID, pointer: pointer, previous: proxyPreviewTarget,
      state: state, viewports: viewportsByMonitor, monitorFrames: monitorFrames)
    guard force || target != proxyPreviewTarget else { return }
    if target != proxyPreviewTarget {
      platform.recordPerformanceTrace(
        "mouse-drop-preview window=\(windowID.rawValue) target=\(target.map { "\($0)" } ?? "none")")
    }
    proxyPreviewTarget = target
    var preview = state
    if let target {
      applyMouseDrop(windowID, target, state: &preview, viewports: viewportsByMonitor, monitorFrames: monitorFrames)
    }
    // A hypothetical drop recomputes focus scrolling. While edge-scrolling, the
    // pointer addresses the current strip instead, including for an unchanged gap.
    if let drag = dragEdgeScrolling, drag.hasScrolled {
      restoreWorkspaceScroll(drag.currentAnchor(state: state), state: &preview)
    }
    platform.presentWindowProxyPreview(mouseDropPreviewFrames(in: preview, viewports: viewportsByMonitor),
      heldWindowID: windowID)
  }

  func cancelDragEdgeScrolling() {
    guard let drag = dragEdgeScrolling else { return }
    drag.cancel(state: &state)
    mouseGestureScrollAnchor = drag.initialAnchor
    dragEdgeScrolling = nil
    platform.endWindowProxyPreview()
  }
}
