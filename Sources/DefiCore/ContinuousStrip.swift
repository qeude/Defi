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

public func continuousStripFramesForActiveWorkspace(
  _ frames: [FrameAssignment],
  viewport: Rect,
  ownerFrame: Rect? = nil,
  parkingFrame: Rect? = nil,
  allMonitorFrames: [Rect]? = nil
) -> ContinuousStripPlan {
  let parkingOwnerFrame = ownerFrame ?? viewport
  let parkingMonitorFrames = allMonitorFrames ?? [parkingOwnerFrame]
  var strip: [FrameAssignment] = []
  var left: [FrameAssignment] = []
  var right: [FrameAssignment] = []

  for assignment in frames {
    let visibleWidth = max(
      min(assignment.frame.x + assignment.frame.width, viewport.x + viewport.width)
        - max(assignment.frame.x, viewport.x),
      0
    )
    if visibleWidth > parkedSliverWidth {
      strip.append(assignment)
    } else if assignment.frame.x + assignment.frame.width <= viewport.x {
      left.append(assignment)
    } else {
      right.append(assignment)
    }
  }
  left.sort {
    ($0.frame.x + $0.frame.width) > ($1.frame.x + $1.frame.width)
  }
  right.sort { $0.frame.x < $1.frame.x }

  var visibility = Dictionary(
    uniqueKeysWithValues: strip.map { ($0.windowID, WindowVisibilityState.visible) }
  )
  for (assignments, side) in [(left, ParkingSide.left), (right, ParkingSide.right)] {
    strip.append(contentsOf: parkFramesInSafeCorner(
      assignments,
      ownerFrame: parkingOwnerFrame,
      parkingFrame: parkingFrame,
      allMonitorFrames: parkingMonitorFrames,
      preferredSide: side
    ))
    for assignment in assignments {
      visibility[assignment.windowID] = .parked
    }
  }
  return ContinuousStripPlan(frames: strip, visibilityByWindowID: visibility)
}
