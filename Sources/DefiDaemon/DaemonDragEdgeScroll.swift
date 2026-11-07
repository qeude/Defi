import CoreGraphics
import DefiModel
import DefiRuntime
import Foundation

extension Daemon {
  var physicalMonitorFrames: [MonitorID: Rect] {
    Dictionary(latestMonitors.map { ($0.id, $0.physicalFrame) }) { first, _ in first }
  }

  func mousePointer() -> (x: Double, y: Double)? {
    CGEvent(source: nil).map { (Double($0.location.x), Double($0.location.y)) }
  }

  /// Every held frame: scrolls the strip while the dragged window rests at a side edge and
  /// redraws the drop over it. Only the overlay moves; the drop commits the scroll.
  func advanceDragEdgeScroll() {
    guard var edge = dragEdgeScroll, let pointer = mousePointer() else { return }
    guard dragEdgeScrollIsCurrent(edge) else {
      presentMouseDropPreview(edge.windowID, pointer: pointer)
      return
    }
    let wasInZone = edge.isInEdgeZone
    let changed = edge.advance(
      pointer: pointer, now: ProcessInfo.processInfo.systemUptime, refreshRate: activeDisplayRefreshRate,
      state: state)
    dragEdgeScroll = edge
    if edge.isInEdgeZone != wasInZone {
      platform.recordPerformanceTrace(
        "drag-edge-scroll window=\(edge.windowID.rawValue) phase=\(edge.phase) offset=\(edge.offset)")
    }
    if changed { presentMouseDropPreview(edge.windowID, pointer: pointer, force: true) }
  }

  /// Shows on the overlay the layout a drop at `pointer` would produce; nil previews no drop.
  func presentMouseDropPreview(_ windowID: WindowID, pointer: (x: Double, y: Double)?, force: Bool = false) {
    var force = force
    if let edge = dragEdgeScroll, edge.windowID != windowID || !dragEdgeScrollIsCurrent(edge) {
      // The strip returns to where it really is, and the drop target with it.
      dragEdgeScroll = nil
      force = true
      platform.recordPerformanceTrace("drag-edge-scroll window=\(edge.windowID.rawValue) cancelled")
    }
    let monitorFrames = physicalMonitorFrames
    let viewports = viewportsByMonitor
    let viewed = dragEdgeScroll?.applied(to: state) ?? state
    let target = pointer.flatMap { pointer in
      mouseDropTarget(windowID, pointer: dragEdgeScroll?.targetPointer(pointer) ?? pointer,
        previous: proxyPreviewTarget, allowsStacking: dragEdgeScroll?.isInEdgeZone != true,
        state: viewed, viewports: viewports, monitorFrames: monitorFrames)
    }
    guard force || target != proxyPreviewTarget else { return }
    if target != proxyPreviewTarget {
      if mouseDropSlotMoved(windowID, from: proxyPreviewTarget, to: target, state: viewed,
        viewports: viewports, monitorFrames: monitorFrames)
      {
        platform.playDropSlotHaptic()
      }
      platform.recordPerformanceTrace(
        "mouse-drop-preview window=\(windowID.rawValue) target=\(target.map { "\($0)" } ?? "none")"
          + (dragEdgeScroll.map { " edge-offset=\($0.offset)" } ?? ""))
    }
    proxyPreviewTarget = target
    var preview = viewed
    if let target {
      applyMouseDrop(windowID, target, state: &preview, viewports: viewports, monitorFrames: monitorFrames)
    }
    // At an edge the strip stays where the scroll draws it instead of turning to the drop.
    if let edge = dragEdgeScroll, edge.isInEdgeZone { preview = edge.applied(to: preview) }
    platform.presentWindowProxyPreview(
      mouseDropPreviewFrames(in: preview, viewports: viewports),
      heldWindowID: windowID,
      rejectedFrame: mouseDropRejectedFrame(target, state: viewed, viewports: viewports))
  }

  /// Without the overlay carrying the window nothing draws the scroll, so the strip stays.
  func dragEdgeScrollIsCurrent(_ edge: DragEdgeScroll) -> Bool {
    platform.windowProxyCarrying
      && edge.isCurrent(state: state, viewports: viewportsByMonitor, monitorFrames: physicalMonitorFrames)
  }
}
