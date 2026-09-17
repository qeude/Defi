import DefiCore
import DefiModel
import Testing

struct ParkingTests {
  @Test
  func `Side by side strip parking stays outside the neighboring monitor`() {
    let owner = Rect(x: 0, y: 0, width: 1_512, height: 982)
    let neighbor = Rect(x: 1_512, y: 0, width: 1_920, height: 1_080)
    let frames = [-1_210.0, 1_512.0].enumerated().map { index, x in
      FrameAssignment(
        windowID: WindowID(rawValue: UInt64(index + 1)),
        frame: Rect(x: x, y: 38, width: 1_210, height: 900)
      )
    }
    let plan = continuousStripFramesForActiveWorkspace(
      frames, viewport: owner, ownerFrame: owner,
      allMonitorFrames: [owner, neighbor]
    )
    #expect(plan.parkedWindowIDs.count == 2)
    for assignment in plan.frames {
      #expect(intersectionArea(assignment.frame, neighbor) == 0)
    }
  }

  @Test
  func `Continuous strip anchors every offscreen column`() {
    let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)
    let frames = (0..<10).map { index in
      FrameAssignment(
        windowID: WindowID(rawValue: UInt64(index + 1)),
        frame: Rect(
          x: Double(index - 5) * 500,
          y: 0,
          width: 500,
          height: 700
        )
      )
    }

    let plan = continuousStripFramesForActiveWorkspace(
      frames,
      viewport: viewport
    )
    let byID = Dictionary(
      uniqueKeysWithValues: plan.frames.map { ($0.windowID, $0.frame) }
    )

    #expect(byID.count == frames.count)
    for index in 0..<10 {
      let id = WindowID(rawValue: UInt64(index + 1))
      let expectedX = index < 5 ? -499.0 : index > 6 ? 999.0 : Double(index - 5) * 500
      #expect(byID[id] == Rect(x: expectedX, y: 0, width: 500, height: 700))
      #expect(plan.parkedWindowIDs.contains(id) == (index < 5 || index > 6))
    }
  }

  @Test
  func `Parking resolver avoids neighboring monitor`() {
    let owner = Rect(x: 0, y: 0, width: 1_000, height: 700)
    let leftNeighbor = Rect(x: -1_000, y: 0, width: 1_000, height: 700)
    let placement = resolveParkingPlacement(
      for: Rect(x: 0, y: 0, width: 500, height: 700),
      ownerFrame: owner,
      allMonitorFrames: [owner, leftNeighbor],
      preferredSide: .left
    )

    #expect(placement.side == .right)
    #expect(placement.frame == Rect(x: 999, y: 0, width: 500, height: 700))
  }

  @Test
  func `Parking resolver uses vertical lane around staggered displays`() {
    let owner = Rect(x: 1_000, y: 0, width: 1_000, height: 1_000)
    let leftNeighbor = Rect(x: 0, y: 400, width: 1_000, height: 500)
    let rightNeighbor = Rect(x: 2_000, y: 0, width: 1_000, height: 500)
    let placement = resolveParkingPlacement(
      for: Rect(x: 1_000, y: 0, width: 500, height: 300),
      ownerFrame: owner,
      allMonitorFrames: [owner, leftNeighbor, rightNeighbor],
      preferredSide: .left
    )

    #expect(verticalIntersection(placement.frame, owner) > 0)
    #expect(intersectionArea(placement.frame, leftNeighbor) == 0)
    #expect(intersectionArea(placement.frame, rightNeighbor) == 0)
  }

  private func intersectionArea(_ lhs: Rect, _ rhs: Rect) -> Double {
    max(
      min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x),
      0
    )
      * max(
        min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y),
        0
      )
  }

  private func verticalIntersection(_ lhs: Rect, _ rhs: Rect) -> Double {
    max(
      min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y),
      0
    )
  }
}
