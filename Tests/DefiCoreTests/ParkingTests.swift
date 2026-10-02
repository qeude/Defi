import DefiCore
import DefiModel
import Testing

struct ParkingTests {
  @Test(arguments: [0.0, 0.5, 1.0, 1.5])
  func immediateStripKeepsMainParkingBoundary(overlap: Double) {
    let viewport = Rect(x: 0, y: 0, width: 2560, height: 1440)
    let id = WindowID(rawValue: 1)
    let plan = continuousStripFramesForActiveWorkspace(
      [FrameAssignment(windowID: id,
                       frame: Rect(x: -800 + overlap, y: 40, width: 800, height: 700))],
      viewport: viewport
    )
    // origin/main f89d0f1: an overlap up to one point uses the right anchor.
    let expectedX = overlap == 0 ? -799.0 : overlap <= 1 ? 2559.0 : -800 + overlap
    #expect(plan.frames[0].frame.x == expectedX)
    #expect(plan.parkedWindowIDs.contains(id) == (overlap <= 1))
  }

  @Test
  func `Left strip exit stays monotonic through its one pixel anchor`() {
    let viewport = Rect(x: 0, y: 0, width: 2560, height: 1440)
    let id = WindowID(rawValue: 1)
    let positions = [8.0, -400, -798, -799, -800, -808].map { x in
      continuousStripFramesForActiveWorkspace(
        [FrameAssignment(windowID: id, frame: Rect(x: x, y: 40, width: 800, height: 700))],
        viewport: viewport, preservingExitSide: true
      ).frames[0].frame.x
    }
    #expect(positions == [8, -400, -798, -799, -799, -799])
  }

  @Test
  func `Compact windows keep their vertical position when leaving the visible strip`() {
    let viewport = Rect(x: 0, y: 30, width: 2560, height: 1371)
    let id = WindowID(rawValue: 1)
    for x in [-338.0, 500.0, 2560.0] {
      let frame = Rect(x: x, y: 342, width: 338, height: 748)
      let plan = continuousStripFramesForActiveWorkspace(
        [FrameAssignment(windowID: id, frame: frame)], viewport: viewport
      )
      #expect(plan.frames[0].frame.y == frame.y)
      #expect(plan.frames[0].frame.height == frame.height)
      #expect(plan.parkedWindowIDs.contains(id) == (x != 500))
    }
  }

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

  @Test
  func `Parking between aligned displays never enters either neighbor`() {
    let left = Rect(x: 0, y: 0, width: 1_000, height: 700)
    let owner = Rect(x: 1_000, y: 0, width: 1_000, height: 700)
    let right = Rect(x: 2_000, y: 0, width: 1_000, height: 700)

    for side in [ParkingSide.left, .right] {
      let placement = resolveParkingPlacement(
        for: Rect(x: 1_000, y: 0, width: 500, height: 700),
        ownerFrame: owner,
        allMonitorFrames: [left, owner, right],
        preferredSide: side
      )

      #expect(placement.frame.x == (side == .left ? 501 : 1_999))
      #expect(intersectionArea(placement.frame, left) == 0)
      #expect(intersectionArea(placement.frame, right) == 0)
    }
  }

  @Test
  func `Aligned displays keep their reserved parking frames separate`() {
    let monitors = [
      Rect(x: 0, y: 0, width: 1_000, height: 700),
      Rect(x: 1_000, y: 0, width: 1_000, height: 700),
      Rect(x: 2_000, y: 0, width: 1_000, height: 700),
      Rect(x: 3_000, y: 0, width: 1_000, height: 700),
    ]
    var placements: [Rect] = []
    for (index, owner) in monitors.enumerated() {
      let placement = resolveParkingPlacement(
        for: Rect(x: owner.x, y: owner.y, width: 500, height: 700),
        ownerFrame: owner,
        allMonitorFrames: monitors,
        reservedParkingFrames: placements,
        preferredSide: index == 1 ? .right : .left
      )
      placements.append(placement.frame)
    }

    for index in placements.indices {
      for otherIndex in placements.indices where index != otherIndex {
        #expect(intersectionArea(placements[index], placements[otherIndex]) == 0)
        #expect(intersectionArea(placements[index], monitors[otherIndex]) == 0)
      }
    }
  }

  @Test
  func `Display gap parking reserves the first monitor target`() {
    let left = Rect(x: -1_200, y: 0, width: 800, height: 600)
    let right = Rect(x: 0, y: 0, width: 800, height: 600)
    let rightPlacement = resolveParkingPlacement(
      for: Rect(x: 0, y: 0, width: 300, height: 300),
      ownerFrame: right,
      allMonitorFrames: [right, left],
      preferredSide: .left
    )
    let leftPlacement = resolveParkingPlacement(
      for: Rect(x: left.x, y: left.y, width: 300, height: 300),
      ownerFrame: left,
      allMonitorFrames: [right, left],
      reservedParkingFrames: [rightPlacement.frame],
      preferredSide: .right
    )

    #expect(intersectionArea(leftPlacement.frame, rightPlacement.frame) == 0)
    #expect(intersectionArea(leftPlacement.frame, right) == 0)
    #expect(intersectionArea(rightPlacement.frame, left) == 0)
  }

  @Test
  func `Active strip parking avoids earlier monitor reservations`() {
    let left = Rect(x: -1_200, y: 0, width: 800, height: 600)
    let right = Rect(x: 0, y: 0, width: 800, height: 600)
    let earlierParking = resolveParkingPlacement(
      for: Rect(x: left.x, y: left.y, width: 300, height: 300),
      ownerFrame: left,
      allMonitorFrames: [left, right],
      preferredSide: .right
    )
    let activeStrip = continuousStripFramesForActiveWorkspace(
      [FrameAssignment(
        windowID: WindowID(rawValue: 1),
        frame: Rect(x: -300, y: 0, width: 300, height: 300)
      )],
      viewport: right,
      ownerFrame: right,
      allMonitorFrames: [left, right],
      reservedParkingFrames: [earlierParking.frame]
    )

    #expect(activeStrip.frames.count == 1)
    if let activeFrame = activeStrip.frames.first?.frame {
      #expect(intersectionArea(activeFrame, earlierParking.frame) == 0)
    }
  }

  @Test
  func `Outgoing strip parking avoids reservations after its vertical translation`() {
    let left = Rect(x: -1_200, y: 400, width: 800, height: 600)
    let right = Rect(x: 0, y: 0, width: 800, height: 600)
    let deltaY = 400.0
    let earlierParking = resolveParkingPlacement(
      for: Rect(x: left.x, y: left.y, width: 300, height: 300),
      ownerFrame: left,
      allMonitorFrames: [left, right],
      preferredSide: .right
    )
    let offscreenColumn = FrameAssignment(
      windowID: WindowID(rawValue: 1),
      frame: Rect(x: -300, y: 300, width: 300, height: 300)
    )
    let unreserved = continuousStripFramesForActiveWorkspace(
      [offscreenColumn],
      viewport: right,
      ownerFrame: right,
      allMonitorFrames: [left, right]
    )
    #expect(unreserved.frames.count == 1)
    if var finalFrame = unreserved.frames.first?.frame {
      finalFrame.y += deltaY
      #expect(intersectionArea(finalFrame, earlierParking.frame) > 0)
    }

    var reservationBeforeTranslation = earlierParking.frame
    reservationBeforeTranslation.y -= deltaY
    let reserved = continuousStripFramesForActiveWorkspace(
      [offscreenColumn],
      viewport: right,
      ownerFrame: right,
      allMonitorFrames: [left, right],
      reservedParkingFrames: [reservationBeforeTranslation]
    )

    #expect(reserved.frames.count == 1)
    if var finalFrame = reserved.frames.first?.frame {
      finalFrame.y += deltaY
      #expect(intersectionArea(finalFrame, earlierParking.frame) == 0)
    }
  }

  @Test
  func `Outgoing strip parking avoids neighboring displays after its vertical translation`() {
    let owner = Rect(x: 0, y: 0, width: 800, height: 600)
    let neighbor = Rect(x: -900, y: -500, width: 800, height: 600)
    let deltaY = -600.0
    let offscreenColumn = FrameAssignment(
      windowID: WindowID(rawValue: 1),
      frame: Rect(x: -300, y: 300, width: 300, height: 300)
    )
    let unshifted = continuousStripFramesForActiveWorkspace(
      [offscreenColumn],
      viewport: owner,
      ownerFrame: owner,
      allMonitorFrames: [owner, neighbor]
    )

    #expect(unshifted.frames.count == 1)
    if var finalFrame = unshifted.frames.first?.frame {
      finalFrame.y += deltaY
      #expect(intersectionArea(finalFrame, neighbor) > 0)
    }

    var neighborBeforeTranslation = neighbor
    neighborBeforeTranslation.y -= deltaY
    let shifted = continuousStripFramesForActiveWorkspace(
      [offscreenColumn],
      viewport: owner,
      ownerFrame: owner,
      allMonitorFrames: [neighborBeforeTranslation]
    )

    #expect(shifted.frames.count == 1)
    if var finalFrame = shifted.frames.first?.frame {
      finalFrame.y += deltaY
      #expect(intersectionArea(finalFrame, neighbor) == 0)
    }
  }

  @Test
  func `Outgoing strip parking keeps a stacked neighbor matching the owner`() {
    let owner = Rect(x: 0, y: 0, width: 800, height: 600)
    let neighbor = Rect(x: 0, y: 600, width: 800, height: 600)
    let deltaY = 600.0
    var neighborBeforeTranslation = neighbor
    neighborBeforeTranslation.y -= deltaY
    #expect(neighborBeforeTranslation == owner)

    let strip = continuousStripFramesForActiveWorkspace(
      [FrameAssignment(
        windowID: WindowID(rawValue: 1),
        frame: Rect(x: -300, y: 0, width: 300, height: 300)
      )],
      viewport: owner,
      ownerFrame: owner,
      allMonitorFrames: [owner, neighborBeforeTranslation]
    )

    #expect(strip.frames.count == 1)
    if var finalFrame = strip.frames.first?.frame {
      finalFrame.y += deltaY
      #expect(intersectionArea(finalFrame, neighbor) == 0)
    }
  }

  @Test
  func `Parking recalculates after a neighboring display grows`() {
    let owner = Rect(x: 0, y: 0, width: 1_000, height: 700)
    let oldNeighbor = Rect(x: 1_500, y: 0, width: 1_000, height: 700)
    let newNeighbor = Rect(x: 999, y: 0, width: 1_500, height: 900)
    let frame = Rect(x: 0, y: 0, width: 500, height: 700)
    let oldPlacement = resolveParkingPlacement(
      for: frame,
      ownerFrame: owner,
      allMonitorFrames: [owner, oldNeighbor],
      preferredSide: .right
    )

    let updatedPlacement = resolveParkingPlacement(
      for: frame,
      ownerFrame: owner,
      allMonitorFrames: [owner, newNeighbor],
      preferredSide: .right
    )

    #expect(intersectionArea(oldPlacement.frame, oldNeighbor) == 0)
    #expect(intersectionArea(updatedPlacement.frame, newNeighbor) == 0)
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
