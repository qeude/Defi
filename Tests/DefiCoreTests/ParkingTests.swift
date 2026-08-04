import DefiCore
import DefiModel
import XCTest

final class ParkingTests: XCTestCase {
  func testParkingUsesStableUniqueSlots() {
    let diff = parkOffscreen([
      WindowID(rawValue: 1),
      WindowID(rawValue: 2),
    ])

    XCTAssertEqual(diff.frames[0].frame, Rect(x: -10_000, y: -10_000, width: 1, height: 1))
    XCTAssertEqual(diff.frames[1].frame, Rect(x: -10_000, y: -10_020, width: 1, height: 1))
  }

  func testContinuousStripAnchorsEveryOffscreenColumnAndPrefetchesNeighbors() {
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
      viewport: viewport,
      prefetchViewports: 0,
      prefetchColumnsPerSide: 1
    )
    let byID = Dictionary(
      uniqueKeysWithValues: plan.frames.map { ($0.windowID, $0.frame) }
    )

    XCTAssertEqual(byID[WindowID(rawValue: 4)]?.x, -499)
    XCTAssertEqual(byID[WindowID(rawValue: 3)]?.x, -499)
    XCTAssertEqual(byID[WindowID(rawValue: 3)]?.y, 0)
    XCTAssertEqual(byID[WindowID(rawValue: 9)]?.x, 999)
    XCTAssertEqual(byID[WindowID(rawValue: 10)]?.x, 999)
    XCTAssertEqual(byID[WindowID(rawValue: 10)]?.y, 0)
    XCTAssertTrue(plan.parkedWindowIDs.contains(WindowID(rawValue: 3)))
    XCTAssertTrue(plan.parkedWindowIDs.contains(WindowID(rawValue: 10)))
    XCTAssertTrue(plan.parkedWindowIDs.contains(WindowID(rawValue: 4)))
    XCTAssertTrue(plan.parkedWindowIDs.contains(WindowID(rawValue: 9)))
    XCTAssertEqual(
      plan.visibilityByWindowID[WindowID(rawValue: 4)],
      .prefetched
    )
    XCTAssertEqual(
      plan.visibilityByWindowID[WindowID(rawValue: 3)],
      .parked
    )
  }

  func testParkingResolverAvoidsNeighboringMonitor() {
    let owner = Rect(x: 0, y: 0, width: 1_000, height: 700)
    let leftNeighbor = Rect(x: -1_000, y: 0, width: 1_000, height: 700)
    let placement = resolveParkingPlacement(
      for: Rect(x: 0, y: 0, width: 500, height: 700),
      ownerFrame: owner,
      allMonitorFrames: [owner, leftNeighbor],
      preferredSide: .left
    )

    XCTAssertEqual(placement.side, .right)
    XCTAssertEqual(
      placement.frame,
      Rect(x: 999, y: 0, width: 500, height: 700)
    )
  }

  func testParkingResolverUsesVerticalLaneAroundStaggeredDisplays() {
    let owner = Rect(x: 1_000, y: 0, width: 1_000, height: 1_000)
    let leftNeighbor = Rect(x: 0, y: 400, width: 1_000, height: 500)
    let rightNeighbor = Rect(x: 2_000, y: 0, width: 1_000, height: 500)
    let placement = resolveParkingPlacement(
      for: Rect(x: 1_000, y: 0, width: 500, height: 300),
      ownerFrame: owner,
      allMonitorFrames: [owner, leftNeighbor, rightNeighbor],
      preferredSide: .left
    )

    XCTAssertGreaterThan(
      verticalIntersection(placement.frame, owner),
      0
    )
    XCTAssertEqual(intersectionArea(placement.frame, leftNeighbor), 0)
    XCTAssertEqual(intersectionArea(placement.frame, rightNeighbor), 0)
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
