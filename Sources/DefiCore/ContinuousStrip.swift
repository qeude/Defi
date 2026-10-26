import DefiModel

public enum WindowVisibilityState: Equatable, Sendable {
  case visible
  case parked
}

public struct ContinuousStripPlan: Equatable, Sendable {
  public let frames: [FrameAssignment]
  public let visibilityByWindowID: [WindowID: WindowVisibilityState]

  public init(
    frames: [FrameAssignment],
    visibilityByWindowID: [WindowID: WindowVisibilityState]
  ) {
    self.frames = frames
    self.visibilityByWindowID = visibilityByWindowID
  }

  public var parkedWindowIDs: Set<WindowID> {
    Set(
      visibilityByWindowID.compactMap {
        $0.value == .visible ? nil : $0.key
      }
    )
  }
}

/// Columns that show more than a sliver of the viewport stay in place; `park`
/// places the others.
public func continuousStripFramesForActiveWorkspace(
  _ frames: [FrameAssignment],
  viewport: Rect,
  park: (FrameAssignment) -> Rect
) -> ContinuousStripPlan {
  var visibility: [WindowID: WindowVisibilityState] = [:]
  let planned = frames.map { assignment in
    let visibleWidth =
      min(assignment.frame.x + assignment.frame.width, viewport.x + viewport.width)
      - max(assignment.frame.x, viewport.x)
    guard visibleWidth <= parkedSliverWidth else {
      visibility[assignment.windowID] = .visible
      return assignment
    }
    visibility[assignment.windowID] = .parked
    return FrameAssignment(windowID: assignment.windowID, frame: park(assignment))
  }
  return ContinuousStripPlan(frames: planned, visibilityByWindowID: visibility)
}
