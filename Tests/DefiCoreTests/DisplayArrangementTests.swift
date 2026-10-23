import DefiCore
import DefiModel
import Testing

struct DisplayArrangementTests {
  let laptop = MonitorID(rawValue: 1)
  let external = MonitorID(rawValue: 2)

  @Test
  func fastPointerCrossingDoesNotWaitForAnotherEventAtTheClampedEdge() throws {
    let desk = [
      laptop: Rect(x: 0, y: 0, width: 1_000, height: 700),
      external: Rect(x: 1_000, y: 0, width: 1_000, height: 700),
    ]
    let technical = isolatedDisplayArrangement(desk, primary: laptop)
    let destination = try #require(displayPointerDestination(
      x: 1_008, y: 350, deltaX: 16, deltaY: 0,
      technical: technical, desk: desk
    ))
    #expect(destination.monitorID == external)
    #expect(destination.x == 1_008)
    #expect(destination.y == -350)
  }

  @Test
  func `Pointer crosses the physical desk edge without bouncing or crossing a gap`() throws {
    let desk = [
      laptop: Rect(x: -1_512, y: 50, width: 1_512, height: 982),
      external: Rect(x: 0, y: 0, width: 1_920, height: 1_080),
    ]
    let technical = isolatedDisplayArrangement(desk, primary: external)
    let left = try #require(technical[laptop])
    let destination = try #require(displayPointerDestination(
      x: left.x + left.width - 1, y: left.y + 200, deltaX: 10, deltaY: 0,
      technical: technical, desk: desk
    ))
    #expect(destination.monitorID == external)
    #expect(destination.x == 2)
    #expect(destination.y == 250)
    #expect(displayPointerDestination(
      x: destination.x, y: destination.y, deltaX: 10, deltaY: 0,
      technical: technical, desk: desk
    ) == nil)
    #expect(displayPointerDestination(
      x: 0, y: 10, deltaX: -10, deltaY: 0, technical: technical, desk: desk
    ) == nil)
    let back = try #require(displayPointerDestination(
      x: 0, y: 250, deltaX: -10, deltaY: 0, technical: technical, desk: desk
    ))
    #expect(back.monitorID == laptop)
    #expect(back.y == left.y + 200)
  }

  @Test
  func diagonalOvershootUsesTheEdgeIntersectionForAdjacency() {
    let desk = [
      laptop: Rect(x: 0, y: 0, width: 1_000, height: 700),
      external: Rect(x: 1_000, y: 650, width: 1_000, height: 700),
    ]
    let technical = [
      laptop: desk[laptop]!,
      external: Rect(x: 1_000, y: -700, width: 1_000, height: 700),
    ]
    #expect(displayPointerDestination(
      x: 1_010, y: 720, deltaX: 20, deltaY: 160,
      technical: technical, desk: desk
    ) == nil) // The pointer crossed the right edge at y=640, above the neighbor.
    #expect(displayPointerDestination(
      x: 1_010, y: 720, deltaX: 20, deltaY: 40,
      technical: technical, desk: desk
    ) == nil) // Touching the source's bottom corner is not a shared edge.
    #expect(displayPointerDestination(
      x: 1_010, y: 720, deltaX: 20, deltaY: 140,
      technical: technical, desk: desk
    )?.monitorID == external) // Here the edge intersection is y=650.
  }
}
