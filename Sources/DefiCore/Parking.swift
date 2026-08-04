import DefiModel

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
