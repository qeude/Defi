import DefiModel

public enum WindowVisibilityState: Equatable, Sendable {
  case visible
  case prefetched
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
  allMonitorFrames: [Rect]? = nil,
  prefetchViewports: Double = 1,
  prefetchColumnsPerSide: Int = 2
) -> ContinuousStripPlan {
  let parkingOwnerFrame = ownerFrame ?? viewport
  let parkingMonitorFrames = allMonitorFrames ?? [parkingOwnerFrame]
  let minX = viewport.x - viewport.width * max(prefetchViewports, 0)
  let maxX =
    viewport.x + viewport.width * (1 + max(prefetchViewports, 0))
  var strip: [FrameAssignment] = []
  var nearLeft: [FrameAssignment] = []
  var nearRight: [FrameAssignment] = []
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
      if assignment.frame.x + assignment.frame.width >= minX {
        nearLeft.append(assignment)
      } else {
        left.append(assignment)
      }
    } else {
      if assignment.frame.x <= maxX {
        nearRight.append(assignment)
      } else {
        right.append(assignment)
      }
    }
  }
  nearLeft.sort {
    ($0.frame.x + $0.frame.width) > ($1.frame.x + $1.frame.width)
  }
  nearRight.sort { $0.frame.x < $1.frame.x }
  left.sort {
    ($0.frame.x + $0.frame.width) > ($1.frame.x + $1.frame.width)
  }
  right.sort { $0.frame.x < $1.frame.x }

  let leftSplit = splitPrefetchColumns(
    left,
    maximumColumns: prefetchColumnsPerSide
  )
  let rightSplit = splitPrefetchColumns(
    right,
    maximumColumns: prefetchColumnsPerSide
  )
  let leftPrefetched = nearLeft + leftSplit.prefetched
  let rightPrefetched = nearRight + rightSplit.prefetched
  let anchoredLeftPrefetched = parkFramesInSafeCorner(
    leftPrefetched,
    ownerFrame: parkingOwnerFrame,
    parkingFrame: parkingFrame,
    allMonitorFrames: parkingMonitorFrames,
    preferredSide: .left
  ).frames
  let anchoredRightPrefetched = parkFramesInSafeCorner(
    rightPrefetched,
    ownerFrame: parkingOwnerFrame,
    parkingFrame: parkingFrame,
    allMonitorFrames: parkingMonitorFrames,
    preferredSide: .right
  ).frames
  strip.append(contentsOf: anchoredLeftPrefetched)
  strip.append(contentsOf: anchoredRightPrefetched)
  strip.append(
    contentsOf: parkFramesInSafeCorner(
      leftSplit.parked,
      ownerFrame: parkingOwnerFrame,
      parkingFrame: parkingFrame,
      allMonitorFrames: parkingMonitorFrames,
      preferredSide: .left
    ).frames
  )
  strip.append(
    contentsOf: parkFramesInSafeCorner(
      rightSplit.parked,
      ownerFrame: parkingOwnerFrame,
      parkingFrame: parkingFrame,
      allMonitorFrames: parkingMonitorFrames,
      preferredSide: .right
    ).frames
  )
  var visibility = Dictionary(
    uniqueKeysWithValues: strip.map { ($0.windowID, WindowVisibilityState.visible) }
  )
  for assignment in leftPrefetched + rightPrefetched {
    visibility[assignment.windowID] = .prefetched
  }
  for assignment in leftSplit.parked + rightSplit.parked {
    visibility[assignment.windowID] = .parked
  }
  return ContinuousStripPlan(
    frames: strip,
    visibilityByWindowID: visibility
  )
}

private func splitPrefetchColumns(
  _ frames: [FrameAssignment],
  maximumColumns: Int
) -> (
  prefetched: [FrameAssignment],
  parked: [FrameAssignment]
) {
  var prefetched: [FrameAssignment] = []
  var parked: [FrameAssignment] = []
  var columns: [Rect] = []
  for assignment in frames {
    if columns.contains(where: {
      abs($0.x - assignment.frame.x) <= 1
        && abs($0.width - assignment.frame.width) <= 1
    }) {
      prefetched.append(assignment)
    } else if columns.count < max(maximumColumns, 0) {
      columns.append(assignment.frame)
      prefetched.append(assignment)
    } else {
      parked.append(assignment)
    }
  }
  return (prefetched, parked)
}
