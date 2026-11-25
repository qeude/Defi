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
/// places the others. `pinned` windows always show, and the others count only what
/// they show of `viewport` beside them.
public func continuousStripFramesForActiveWorkspace(
  _ frames: [FrameAssignment],
  viewport: Rect,
  pinned: Set<WindowID> = [],
  park: (FrameAssignment) -> Rect
) -> ContinuousStripPlan {
  var visibility: [WindowID: WindowVisibilityState] = [:]
  let pinnedFrames = frames.filter { pinned.contains($0.windowID) }.map(\.frame)
  let planned = frames.map { assignment in
    let frame = assignment.frame
    let visibleWidth =
      min(frame.x + frame.width, viewport.x + viewport.width) - max(frame.x, viewport.x)
    // macOS cannot clip a window: one reaching under a pinned column would cover it.
    let underPin = pinnedFrames.contains {
      min(frame.x + frame.width, $0.x + $0.width) > max(frame.x, $0.x)
    }
    guard visibleWidth <= parkedSliverWidth || underPin, !pinned.contains(assignment.windowID) else {
      visibility[assignment.windowID] = .visible
      return assignment
    }
    visibility[assignment.windowID] = .parked
    return FrameAssignment(windowID: assignment.windowID, frame: park(assignment))
  }
  return ContinuousStripPlan(frames: planned, visibilityByWindowID: visibility)
}
