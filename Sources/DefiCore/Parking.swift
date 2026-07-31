import DefiModel

public enum WindowVisibilityState: Equatable, Sendable {
  case visible
  case prefetched
  case parked
}

public enum ParkingSide: Equatable, Sendable {
  case left
  case right
}

public struct ParkingPlacement: Equatable, Sendable {
  public let frame: Rect
  public let side: ParkingSide

  public init(frame: Rect, side: ParkingSide) {
    self.frame = frame
    self.side = side
  }
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

public func parkOffscreen(_ windowIDs: [WindowID]) -> LayoutDiff {
  LayoutDiff(
    frames: windowIDs.enumerated().map { index, windowID in
      FrameAssignment(
        windowID: windowID,
        frame: Rect(
          x: offscreenParkingOriginX,
          y: offscreenParkingOriginY - Double(index) * 20,
          width: 1,
          height: 1
        )
      )
    }
  )
}

public func resolveParkingPlacement(
  for frame: Rect,
  ownerFrame: Rect,
  parkingFrame: Rect? = nil,
  allMonitorFrames: [Rect],
  preferredSide: ParkingSide,
  anchorSize: Double = parkedSliverWidth
) -> ParkingPlacement {
  let anchor = max(anchorSize, 1)
  let writableFrame = parkingFrame ?? ownerFrame
  let targetY =
    writableFrame.y + max(writableFrame.height - frame.height, 0)
  let otherFrames = allMonitorFrames.filter { $0 != ownerFrame }
  let verticalOrigins = parkingVerticalOrigins(
    for: frame,
    targetY: targetY,
    ownerFrame: ownerFrame,
    otherFrames: otherFrames
  )
  let candidates = [preferredSide, opposite(preferredSide)].flatMap { side in
    verticalOrigins.map { y in
      let x =
        side == .left
        ? ownerFrame.x - frame.width + anchor
        : ownerFrame.x + ownerFrame.width - anchor
      return ParkingPlacement(
        frame: Rect(
          x: x,
          y: y,
          width: frame.width,
          height: frame.height
        ),
        side: side
      )
    }
  }
  return candidates.min {
    isParkingScore(
      parkingScore(
        $0,
        ownerFrame: ownerFrame,
        otherFrames: otherFrames,
        targetY: targetY,
        preferredSide: preferredSide
      ),
      betterThan: parkingScore(
        $1,
        ownerFrame: ownerFrame,
        otherFrames: otherFrames,
        targetY: targetY,
        preferredSide: preferredSide
      )
    )
  } ?? candidates[0]
}

public func parkFramesInSafeCorner(
  _ frames: [FrameAssignment],
  ownerFrame: Rect,
  parkingFrame: Rect? = nil,
  allMonitorFrames: [Rect],
  preferredSide: ParkingSide
) -> LayoutDiff {
  LayoutDiff(
    frames: frames.map { assignment in
      let placement = resolveParkingPlacement(
        for: assignment.frame,
        ownerFrame: ownerFrame,
        parkingFrame: parkingFrame,
        allMonitorFrames: allMonitorFrames,
        preferredSide: preferredSide
      )
      return FrameAssignment(
        windowID: assignment.windowID,
        frame: placement.frame
      )
    }
  )
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

private func opposite(_ side: ParkingSide) -> ParkingSide {
  side == .left ? .right : .left
}

private func parkingScore(
  _ placement: ParkingPlacement,
  ownerFrame: Rect,
  otherFrames: [Rect],
  targetY: Double,
  preferredSide: ParkingSide
) -> (Int, Double, Double, Int) {
  let ownerVerticalOverlap = verticalIntersectionLength(
    placement.frame,
    ownerFrame
  )
  let lanePenalty = ownerVerticalOverlap > 0 ? 0 : 1
  let otherOverlap = otherFrames.reduce(0) {
    $0 + intersectionArea(placement.frame, $1)
  }
  let verticalDistance = abs(placement.frame.y - targetY)
  let sidePenalty = placement.side == preferredSide ? 0 : 1
  return (lanePenalty, otherOverlap, verticalDistance, sidePenalty)
}

private func isParkingScore(
  _ lhs: (
    lanePenalty: Int,
    otherOverlap: Double,
    verticalDistance: Double,
    sidePenalty: Int
  ),
  betterThan rhs: (
    lanePenalty: Int,
    otherOverlap: Double,
    verticalDistance: Double,
    sidePenalty: Int
  )
) -> Bool {
  if lhs.lanePenalty != rhs.lanePenalty {
    return lhs.lanePenalty < rhs.lanePenalty
  }
  if lhs.otherOverlap != rhs.otherOverlap {
    return lhs.otherOverlap < rhs.otherOverlap
  }
  if lhs.verticalDistance != rhs.verticalDistance {
    return lhs.verticalDistance < rhs.verticalDistance
  }
  return lhs.sidePenalty < rhs.sidePenalty
}

private func parkingVerticalOrigins(
  for frame: Rect,
  targetY: Double,
  ownerFrame: Rect,
  otherFrames: [Rect]
) -> [Double] {
  var origins: [Double] = []
  func append(_ value: Double) {
    guard value.isFinite,
      !origins.contains(where: { abs($0 - value) < 0.5 })
    else {
      return
    }
    origins.append(value)
  }

  append(targetY)
  append(ownerFrame.y)
  append(ownerFrame.y + ownerFrame.height - frame.height)
  for otherFrame in otherFrames {
    append(otherFrame.y - frame.height)
    append(otherFrame.y + otherFrame.height)
  }
  return origins
}

private func verticalIntersectionLength(_ lhs: Rect, _ rhs: Rect) -> Double {
  max(
    min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y),
    0
  )
}

private func intersectionArea(_ lhs: Rect, _ rhs: Rect) -> Double {
  let width = max(
    min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x),
    0
  )
  let height = max(
    min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y),
    0
  )
  return width * height
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

public func focusedColumnScrollOffset(
  workspace: Workspace,
  viewport: Rect = Rect(x: 0, y: 0, width: 1_000, height: 1),
  windows: [Window] = []
) -> Double {
  focusedColumnTargetScrollOffset(
    workspace: workspace,
    viewport: viewport,
    windows: windows,
    centerFocusedColumn: .never
  )
}

public func focusedColumnLeftScrollOffset(
  workspace: Workspace,
  viewport: Rect = Rect(x: 0, y: 0, width: 1_000, height: 1),
  windows: [Window] = []
) -> Double {
  let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
  let focusedLeft = columnsWidth(
    Array(workspace.columns.prefix(workspace.focusedColumn)),
    viewport: viewport,
    windowsByID: windowsByID
  )
  let totalWidth = columnsWidth(workspace.columns, viewport: viewport, windowsByID: windowsByID)
  return min(max(focusedLeft, 0), max(totalWidth - 1, 0))
}

public func focusedColumnRevealScrollOffset(
  workspace: Workspace,
  viewport: Rect = Rect(x: 0, y: 0, width: 1_000, height: 1),
  windows: [Window] = []
) -> Double {
  let minimumReveal = focusedColumnTargetScrollOffset(
    workspace: workspace,
    viewport: viewport,
    windows: windows,
    centerFocusedColumn: .never
  )
  let pixelTolerance = 1 / max(viewport.width, 1)
  guard abs(minimumReveal - workspace.scrollOffset) > pixelTolerance else {
    return minimumReveal
  }
  return focusedColumnLeftScrollOffset(
    workspace: workspace,
    viewport: viewport,
    windows: windows
  )
}

public func focusedColumnTargetScrollOffset(
  workspace: Workspace,
  viewport: Rect = Rect(x: 0, y: 0, width: 1_000, height: 1),
  windows: [Window] = [],
  centerFocusedColumn: CenterFocusedColumn
) -> Double {
  let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
  let focusedLeft = columnsWidth(
    Array(workspace.columns.prefix(workspace.focusedColumn)),
    viewport: viewport,
    windowsByID: windowsByID
  )
  let focusedWidth =
    workspace.columns.indices.contains(workspace.focusedColumn)
    ? columnWidthInViewports(
      workspace.columns[workspace.focusedColumn],
      viewport: viewport,
      windowsByID: windowsByID
    )
    : 0
  let totalWidth = columnsWidth(workspace.columns, viewport: viewport, windowsByID: windowsByID)
  let maxContentScroll = max(totalWidth - 1, 0)

  switch centerFocusedColumn {
  case .always:
    return min(max(focusedLeft + focusedWidth / 2 - 0.5, 0), maxContentScroll)
  case .never:
    let focusedRight = focusedLeft + focusedWidth
    let minimumScroll = max(focusedRight - 1, 0)
    let maximumScroll = min(focusedLeft, maxContentScroll)
    return minimumScroll > maximumScroll
      ? maximumScroll
      : min(max(workspace.scrollOffset, minimumScroll), maximumScroll)
  }
}

private func columnsWidth(
  _ columns: [Column],
  viewport: Rect,
  windowsByID: [WindowID: Window]
) -> Double {
  columns.reduce(0) {
    $0 + columnWidthInViewports($1, viewport: viewport, windowsByID: windowsByID)
  }
}

private func columnWidthInViewports(
  _ column: Column,
  viewport: Rect,
  windowsByID: [WindowID: Window]
) -> Double {
  columnLayoutWidth(column, viewport: viewport, windowsByID: windowsByID)
    / max(viewport.width, 1)
}

func repairWorkspaceScroll(_ workspace: inout Workspace, settings: LayoutSettings) {
  workspace.targetScrollOffset = focusedColumnTargetScrollOffset(
    workspace: workspace,
    centerFocusedColumn: settings.centerFocusedColumn
  )
}

func nearestPresetIndex(current: Double, presets: [Double]) -> Int {
  presets.indices.min {
    abs(presets[$0] - current) < abs(presets[$1] - current)
  } ?? 0
}
