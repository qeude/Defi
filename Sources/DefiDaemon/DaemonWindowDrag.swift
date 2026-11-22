import CoreGraphics
import DefiCore
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation

/// A window pressed with the drag modifier: a left drag moves it, a right drag resizes it,
/// as Niri's Mod+drag. The app never sees the press. A tiled window moves on the overlay
/// and lands once on release; a floating one follows the pointer.
struct WindowDrag {
  let button: WindowDragButton
  let windowID: WindowID
  let start: CGPoint
  let floating: Bool
  /// Where the window was laid out (or floated) when pressed.
  let frame: Rect
  let edges: WindowResizeEdges
  /// The strip as it stood, to keep it still after a drop that stays in view.
  let anchor: WorkspaceScrollAnchor?
  /// Past a click's jitter.
  var started = false
  /// The layout a resize shows, applied on release.
  var resized: RuntimeState?

  func travel(to location: CGPoint) -> (dx: Double, dy: Double) {
    (Double(location.x - start.x), Double(location.y - start.y))
  }
}

/// Farther than a click's jitter, as for a title-bar drag.
private let windowDragThreshold = 6.0

@NavigationActor
extension Daemon {
  func handleWindowDrag(_ action: WindowDragAction) {
    guard desktopSessionActive, !shouldShutdown, !restorationInFlight else {
      cancelWindowDrag()
      return
    }
    switch action {
    case .began(let button, let windowID, let location, _):
      beginWindowDrag(button, windowID: windowID, at: location)
    case .moved(let location):
      moveWindowDrag(to: location)
    case .ended(let location, let timestamp):
      endWindowDrag(at: location, timestamp: timestamp)
    case .cancelled:
      cancelWindowDrag()
    }
  }

  /// The windows a modifier drag may take, for the event tap.
  func publishWindowDragTargets() {
    let targets = Set(state.windows.keys).subtracting(state.nativeFullscreenWindowIDs)
    guard targets != publishedWindowDragTargets else { return }
    publishedWindowDragTargets = targets
    hotKeys?.setWindowDragTargets(targets)
  }

  private func beginWindowDrag(_ button: WindowDragButton, windowID: WindowID, at location: CGPoint) {
    cancelWindowDrag()
    guard !overviewState.isOpen, let window = state.windows[windowID],
      !state.nativeFullscreenWindowIDs.contains(windowID),
      let frame = window.floating
        ? floatingWindowFrames[windowID] ?? window.frame
        : mouseDropPreviewFrames(in: state, viewports: viewportsByMonitor)[windowID]
    else { return }
    cancelScrollPan()
    // The title-bar drag reads native frames; this gesture moves none until release.
    preemptMouseGesture()
    invalidatePointerFocusIntent()
    windowDrag = WindowDrag(button: button, windowID: windowID, start: location,
      floating: window.floating, frame: frame,
      edges: WindowResizeEdges(pointer: (Double(location.x), Double(location.y)), frame: frame),
      anchor: workspaceScrollAnchor(containing: windowID, state: state))
    platform.recordPerformanceTrace("window-drag-began window=\(windowID.rawValue) button=\(button)")
  }

  private func moveWindowDrag(to location: CGPoint) {
    guard var drag = windowDrag, state.windows[drag.windowID] != nil, !overviewState.isOpen else {
      cancelWindowDrag()
      return
    }
    let (dx, dy) = drag.travel(to: location)
    if !drag.started {
      guard hypot(dx, dy) > windowDragThreshold else { return }
      drag.started = true
    }
    let pointer = (Double(location.x), Double(location.y))
    switch (drag.button, drag.floating) {
    case (_, true):
      let frame = drag.button == .left
        ? Rect(x: drag.frame.x + dx, y: drag.frame.y + dy, width: drag.frame.width, height: drag.frame.height)
        : windowResizedFrame(drag.frame, edges: drag.edges, dx: dx, dy: dy)
      windowDrag = drag
      placeFloatingWindow(drag.windowID, at: frame)
    case (.left, false):
      windowDrag = drag
      if !platform.windowProxyCarrying {
        platform.carryWindowProxy(drag.windowID, stretches: false)
        if platform.windowProxyCarrying, dragEdgeScroll?.windowID != drag.windowID {
          dragEdgeScroll = DragEdgeScroll(windowID: drag.windowID, state: state,
            viewports: viewportsByMonitor, monitorFrames: physicalMonitorFrames)
        }
      }
      presentMouseDropPreview(drag.windowID, pointer: pointer)
    case (.right, false):
      let resized = tiledWindowResized(drag.windowID, from: drag.frame, edges: drag.edges, dx: dx, dy: dy,
        state: state, viewports: viewportsByMonitor)
      drag.resized = resized
      windowDrag = drag
      platform.presentWindowProxyResize(mouseDropPreviewFrames(in: resized, viewports: viewportsByMonitor),
        heldWindowID: drag.windowID)
    }
  }

  private func endWindowDrag(at location: CGPoint, timestamp: TimeInterval) {
    guard let drag = windowDrag, state.windows[drag.windowID] != nil else {
      cancelWindowDrag()
      return
    }
    windowDrag = nil
    platform.recordPerformanceTrace(
      "window-drag-ended window=\(drag.windowID.rawValue) button=\(drag.button) started=\(drag.started)")
    // A press without a drag is a click: it focuses, as Niri does.
    guard drag.started else {
      handle("focus-window-id \(drag.windowID.rawValue)", inputTimestamp: timestamp)
      return
    }
    if drag.floating {
      focusWindow(drag.windowID, state: &state)
      commitWindowDrag(drag.windowID, timestamp: timestamp, animated: false)
      return
    }
    if drag.button == .right {
      platform.endWindowProxyDrag()
      if let resized = drag.resized { state = resized }
      focusWindow(drag.windowID, state: &state)
      commitWindowDrag(drag.windowID, timestamp: timestamp, animated: animationsEnabled)
      return
    }
    // The drop lands where the release is, even if no drag event reported it.
    presentMouseDropPreview(drag.windowID, pointer: (Double(location.x), Double(location.y)))
    let target = proxyPreviewTarget
    let edgeScroll = dragEdgeScroll.flatMap {
      $0.isCurrent(state: state, viewports: viewportsByMonitor, monitorFrames: physicalMonitorFrames) ? $0 : nil
    }
    proxyPreviewTarget = nil
    dragEdgeScroll = nil
    presentedEdgeScrollOffset = nil
    platform.endWindowProxyPreview()
    platform.endWindowProxyDrag()
    var dropState = edgeScroll?.applied(to: state) ?? state
    let dropped = target.map {
      applyMouseDrop(drag.windowID, $0, state: &dropState, viewports: viewportsByMonitor,
        monitorFrames: physicalMonitorFrames)
    } ?? false
    if dropped { state = dropState }
    if let target { platform.recordPerformanceTrace("mouse-drop window=\(drag.windowID.rawValue) target=\(target)") }
    focusWindow(drag.windowID, state: &state)
    if let destination = state.monitorID(containing: drag.windowID) { activeMonitorID = destination }
    synchronizeScrollOffsets(state: &state, viewports: viewportsByMonitor)
    // The strip moves only when the dropped window would otherwise sit partly off screen.
    if edgeScroll?.scrolled != true, let anchor = drag.anchor,
      windowStaysInView(drag.windowID, holding: anchor, state: state, viewports: viewportsByMonitor)
    {
      restoreWorkspaceScroll(anchor, state: &state)
    }
    proxyDroppedWindowID = drag.windowID
    commitWindowDrag(drag.windowID, timestamp: timestamp, animated: animationsEnabled)
  }

  /// One layout for the whole gesture: every window lands once, and the dragged one takes focus.
  private func commitWindowDrag(_ windowID: WindowID, timestamp: TimeInterval, animated: Bool) {
    snapScrollOffsetsToTargets()
    applyCurrentLayout(
      asynchronousPositions: true,
      updateVisibility: true,
      positionTimeoutSeconds: 0.05,
      animated: animated,
      postCommitFocus: PostCommitFocus(windowID: windowID, inputTimestamp: timestamp),
      forcingFloatingFrameWritesFor: state.windows[windowID]?.floating == true ? [windowID] : [],
      source: "mouse-drop-animation")
    persistTopology()
    updateMenuBar()
    needsDesktopSync = true
    scheduleTick()
  }

  /// A floating window follows the pointer: its frame is written as it moves, across
  /// displays too.
  private func placeFloatingWindow(_ windowID: WindowID, at frame: Rect) {
    floatingWindowFrames[windowID] = frame
    let center = Rect(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2, width: 0, height: 0)
    if let monitorID = latestMonitors.first(where: { $0.physicalFrame.contains(centerOf: center) })?.id {
      moveFloatingWindow(windowID, to: monitorID, state: &state)
    }
    applyCurrentLayout(
      monitorIDs: state.monitorID(containing: windowID).map { [$0] },
      asynchronousPositions: true,
      forcingFloatingFrameWritesFor: [windowID],
      source: "window-drag-floating")
  }

  /// Another input or a lost release ended the gesture: everything shows where it really is.
  func cancelWindowDrag() {
    guard let drag = windowDrag else { return }
    windowDrag = nil
    platform.recordPerformanceTrace("window-drag-cancelled window=\(drag.windowID.rawValue)")
    guard drag.started else { return }
    proxyPreviewTarget = nil
    dragEdgeScroll = nil
    presentedEdgeScrollOffset = nil
    platform.endWindowProxyPreview()
    platform.endWindowProxyDrag()
    applyCurrentLayout(animated: animationsEnabled && !drag.floating, source: "window-drag-cancelled")
  }
}
