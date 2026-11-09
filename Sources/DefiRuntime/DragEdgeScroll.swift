import DefiCore
import DefiModel

public enum EdgeDirection: Equatable, Sendable { case left, right }

public enum EdgeScrollPhase: Equatable, Sendable {
  case idle
  case dwelling(EdgeDirection, since: Double)
  case scrolling(EdgeDirection, lastTick: Double)
}

/// Scrolls a dragged tiled window's strip while the pointer holds it near a side edge of
/// its display, so columns beyond the edge become drop targets. The offset lives here and
/// only reaches the state through the drop.
public struct DragEdgeScroll: Equatable, Sendable {
  /// Points from the viewport's side edge where scrolling starts.
  public static let zoneWidth = 48.0
  /// Extra points a pointer already in the zone may drift back before it leaves.
  public static let hysteresis = 12.0
  /// Seconds the pointer rests in the zone before the strip moves: a drag passing by
  /// toward another display or a quick flick does not scroll.
  public static let dwell = 0.25
  /// Viewport widths per second, from the zone's inner edge to the screen's edge.
  public static let speeds = 0.2...1.0

  public let windowID: WindowID
  public let anchor: WorkspaceScrollAnchor
  public let viewport: Rect
  /// The display's full frame: a pointer pushed against its edge past a side Dock still scrolls.
  public let screen: Rect
  public private(set) var offset: Double
  public private(set) var phase: EdgeScrollPhase = .idle

  public init?(
    windowID: WindowID, state: RuntimeState, viewports: [MonitorID: Rect], monitorFrames: [MonitorID: Rect]
  ) {
    guard let anchor = workspaceScrollAnchor(containing: windowID, state: state),
      let viewport = viewports[anchor.monitorID]
    else { return nil }
    self.windowID = windowID
    self.anchor = anchor
    self.viewport = viewport
    self.screen = monitorFrames[anchor.monitorID] ?? viewport
    self.offset = anchor.scrollOffset
    guard isCurrent(state: state, viewports: viewports, monitorFrames: monitorFrames) else { return nil }
  }

  /// From the first moment in a zone, dwell included: only new columns are offered there,
  /// so columns passing under a still pointer never flip the drop into a stack.
  public var isInEdgeZone: Bool { phase != .idle }

  public var scrolled: Bool { offset != anchor.scrollOffset }

  /// The state as the overlay draws it during the drag.
  public func applied(to state: RuntimeState) -> RuntimeState {
    var state = state
    restoreWorkspaceScroll(
      WorkspaceScrollAnchor(monitorID: anchor.monitorID, workspaceID: anchor.workspaceID, scrollOffset: offset),
      state: &state)
    return state
  }

  /// The pointer the drop reads: between the viewport and the screen's side edge it still
  /// drops on this strip, not on another display.
  public func targetPointer(_ pointer: (x: Double, y: Double)) -> (x: Double, y: Double) {
    guard onScreen(pointer) else { return pointer }
    return (min(max(pointer.x, viewport.x), viewport.x + viewport.width), pointer.y)
  }

  /// False once a display, workspace or the window's tiling changed under the drag.
  public func isCurrent(state: RuntimeState, viewports: [MonitorID: Rect], monitorFrames: [MonitorID: Rect]) -> Bool {
    viewports[anchor.monitorID] == viewport && (monitorFrames[anchor.monitorID] ?? viewport) == screen
      && state.windows[windowID]?.floating == false && !state.nativeFullscreenWindowIDs.contains(windowID)
      && state.monitors.first(where: { $0.id == anchor.monitorID })?.activeWorkspace == anchor.workspaceID
      && state.location(containing: windowID).map {
        $0.monitorID == anchor.monitorID && $0.workspaceID == anchor.workspaceID
      } == true
  }

  /// Moves the strip by the time since the last tick, capped to two refresh intervals so a
  /// late tick never catches up in a jump. True when the strip or the zone changed.
  @discardableResult
  public mutating func advance(
    pointer: (x: Double, y: Double), now: Double, refreshRate: Double, state: RuntimeState
  ) -> Bool {
    let before = (offset, isInEdgeZone)
    let edge = self.edge(pointer)
    switch (phase, edge) {
    case (_, nil):
      phase = .idle
    case (.dwelling(let direction, let since), let edge?) where edge == direction:
      // Scrolling starts from now: the dwell is never paid back as distance.
      if now - since >= Self.dwell { phase = .scrolling(direction, lastTick: now) }
    case (.scrolling(let direction, let lastTick), let edge?) where edge == direction:
      let elapsed = min(max(now - lastTick, 0), 2 / max(refreshRate, 30))
      let bounds = scrollBounds(state)
      let strip = stripViewport(viewport, settings: state.layout).width
      let step = speed(pointer, direction) * viewport.width * elapsed / strip
      let clamped = min(max(offset, bounds.lowerBound), bounds.upperBound)
      offset = direction == .right
        ? min(clamped + step, max(bounds.upperBound, clamped))
        : max(clamped - step, min(bounds.lowerBound, clamped))
      phase = .scrolling(direction, lastTick: now)
    case (_, let edge?):
      phase = .dwelling(edge, since: now)
    }
    return offset != before.0 || isInEdgeZone != before.1
  }

  private var direction: EdgeDirection? {
    switch phase {
    case .idle: nil
    case .dwelling(let direction, _), .scrolling(let direction, _): direction
    }
  }

  private var zone: Double { min(Self.zoneWidth, viewport.width / 4) }

  /// The whole display: a title bar held at the top drifts under the menu bar, and the
  /// hand there still means this edge.
  private func onScreen(_ pointer: (x: Double, y: Double)) -> Bool {
    pointer.x >= screen.x && pointer.x <= screen.x + screen.width
      && pointer.y >= screen.y && pointer.y <= screen.y + screen.height
  }

  /// Off this display (toward a neighbor) is no edge: the drop goes to that display.
  private func edge(_ pointer: (x: Double, y: Double)) -> EdgeDirection? {
    guard onScreen(pointer) else { return nil }
    if pointer.x <= viewport.x + zone + (direction == .left ? Self.hysteresis : 0) { return .left }
    if pointer.x >= viewport.x + viewport.width - zone - (direction == .right ? Self.hysteresis : 0) {
      return .right
    }
    return nil
  }

  /// Faster the deeper the pointer sits in the zone.
  private func speed(_ pointer: (x: Double, y: Double), _ direction: EdgeDirection) -> Double {
    let depth = direction == .left ? viewport.x + zone - pointer.x : pointer.x - (viewport.x + viewport.width - zone)
    let fraction = min(max(depth / zone, 0), 1)
    return Self.speeds.lowerBound + (Self.speeds.upperBound - Self.speeds.lowerBound) * fraction
  }

  /// The offsets that keep the strip on screen, and never past where the drag started. The
  /// dragged window counts: a drop at either end makes room for it there.
  private func scrollBounds(_ state: RuntimeState) -> ClosedRange<Double> {
    let start = anchor.scrollOffset
    guard let monitor = state.monitors.first(where: { $0.id == anchor.monitorID }),
      let workspace = monitor.workspaces.first(where: { $0.id == anchor.workspaceID })
    else { return start...start }
    let extents = scrollGestureExtents(
      workspace: workspace, viewport: viewport,
      windows: workspace.columns.flatMap(\.windows).compactMap { state.windows[$0] },
      settings: state.layout, excludingWindowIDs: state.nativeFullscreenWindowIDs)
    guard let lowest = extents.map(\.lowerBound).min(), let highest = extents.map(\.upperBound).max()
    else { return start...start }
    return min(lowest, start)...max(highest, start)
  }
}
