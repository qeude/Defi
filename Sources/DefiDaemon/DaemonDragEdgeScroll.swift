import CoreGraphics
import DefiCore
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
  /// updates the drop under the pointer. Only the overlay moves; the drop commits the scroll.
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
    // The target follows the pointer every frame; an unchanged one redraws nothing.
    presentMouseDropPreview(edge.windowID, pointer: pointer, force: changed)
  }

  /// Marks on the overlay where a drop at `pointer` would land; nil previews no drop.
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
    // The strip scrolling at an edge moves under the pointer at once.
    var scroll: (shift: Double, windowIDs: Set<WindowID>)?
    if let edge = dragEdgeScroll {
      scroll = presentedEdgeScrollOffset.map { edgeScrollShift(edge, since: $0, viewports: viewports) }
      presentedEdgeScrollOffset = edge.offset
    } else {
      presentedEdgeScrollOffset = nil
    }
    platform.presentWindowProxyPreview(
      mouseDropHeldFrames(windowID, target, state: viewed, viewports: viewports, monitorFrames: monitorFrames),
      heldWindowID: windowID,
      rejectedFrame: mouseDropRejectedFrame(target, state: viewed, viewports: viewports),
      hint: target.flatMap { mouseDropHintFrame(windowID, $0, state: viewed, viewports: viewports) },
      scroll: scroll)
  }

  /// The points the strip moved since `offset` was drawn: its windows follow the pointer
  /// at once instead of springing after it.
  private func edgeScrollShift(
    _ edge: DragEdgeScroll, since offset: Double, viewports: [MonitorID: Rect]
  ) -> (shift: Double, windowIDs: Set<WindowID>) {
    let windowIDs = state.monitors.first { $0.id == edge.anchor.monitorID }?.workspaces
      .first { $0.id == edge.anchor.workspaceID }.map { Set($0.columns.flatMap(\.windows)) } ?? []
    let strip = viewports[edge.anchor.monitorID].map { stripViewport($0, settings: state.layout).width } ?? 0
    return ((offset - edge.offset) * strip, windowIDs)
  }

  /// Without the overlay carrying the window nothing draws the scroll, so the strip stays.
  private func dragEdgeScrollIsCurrent(_ edge: DragEdgeScroll) -> Bool {
    platform.windowProxyCarrying
      && edge.isCurrent(state: state, viewports: viewportsByMonitor, monitorFrames: physicalMonitorFrames)
  }
}
