import DefiModel

/// The edges a resize drag moves: always a side, and the top or bottom too when the
/// pointer starts in the window's upper or lower third.
public struct WindowResizeEdges: Equatable, Sendable {
  public enum Vertical: Equatable, Sendable { case top, bottom }

  public var left: Bool
  public var vertical: Vertical?

  public init(left: Bool, vertical: Vertical?) {
    self.left = left
    self.vertical = vertical
  }

  /// The side in the pointer's half; the top or bottom in its outer thirds, as Niri splits a
  /// window. Unlike Niri the middle still resizes the width, so no press does nothing.
  public init(pointer: (x: Double, y: Double), frame: Rect) {
    left = pointer.x < frame.x + frame.width / 2
    vertical = pointer.y < frame.y + frame.height / 3 ? .top
      : pointer.y > frame.y + frame.height * 2 / 3 ? .bottom : nil
  }
}

/// Smaller than any window macOS draws: the layout's own bounds apply after.
private let windowResizeMinimumSide = 50.0

/// `frame` with its dragged edges moved by the pointer's travel; the opposite edges stay.
public func windowResizedFrame(_ frame: Rect, edges: WindowResizeEdges, dx: Double, dy: Double) -> Rect {
  let width = max(frame.width + (edges.left ? -dx : dx), windowResizeMinimumSide)
  var resized = Rect(x: edges.left ? frame.x + frame.width - width : frame.x, y: frame.y,
    width: width, height: frame.height)
  switch edges.vertical {
  case .top:
    resized.height = max(frame.height - dy, windowResizeMinimumSide)
    resized.y = frame.y + frame.height - resized.height
  case .bottom:
    resized.height = max(frame.height + dy, windowResizeMinimumSide)
  case nil:
    break
  }
  return resized
}

/// The tiled layout once `windowID`, laid out at `frame` when the drag began, is resized to
/// the pointer's travel: its column takes the width and, in a stack, the window the height.
/// A dragged left edge scrolls the strip so the right edge stays.
public func tiledWindowResized(
  _ windowID: WindowID, from frame: Rect, edges: WindowResizeEdges, dx: Double, dy: Double,
  state: RuntimeState, viewports: [MonitorID: Rect]
) -> RuntimeState {
  var resized = state
  let target = windowResizedFrame(frame, edges: edges, dx: dx, dy: dy)
  learnTiledWindowWidth(windowID, actualFrame: target, state: &resized, viewports: viewports)
  if edges.vertical != nil {
    learnStackedWindowHeight(windowID, actualFrame: target, state: &resized, viewports: viewports)
  }
  return resized
}
