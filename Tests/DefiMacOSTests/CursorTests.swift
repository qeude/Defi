import CoreGraphics
import DefiModel
import Testing

@testable import DefiMacOS

struct CursorTests {
  private let frame = Rect(x: 100, y: 200, width: 400, height: 600)

  @Test
  func cursorOutsideWindowWarpsToCenter() {
    #expect(
      cursorWarpDestination(
        frame: frame,
        currentLocation: CGPoint(x: 0, y: 0)
      ) == CGPoint(x: 300, y: 500)
    )
  }

  @Test
  func cursorAlreadyInsideWindowDoesNotWarp() {
    #expect(
      cursorWarpDestination(
        frame: frame,
        currentLocation: CGPoint(x: 300, y: 500)
      ) == nil
    )
  }

  @Test
  func newerPhysicalMotionRejectsStaleWarp() {
    #expect(
      cursorWarpIsCurrent(
        latestPointerMotionTimestamp: 12,
        maximumPointerMotionTimestamp: 11
      ) == false
    )
    #expect(
      cursorWarpIsCurrent(
        latestPointerMotionTimestamp: 11,
        maximumPointerMotionTimestamp: 11
      )
    )
  }
}
