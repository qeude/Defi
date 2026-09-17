import DefiCore
import DefiModel
import Testing

struct DisplayArrangementTests {
  let laptop = MonitorID(rawValue: 1)
  let external = MonitorID(rawValue: 2)

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
  func `Partial ribbon remains visible without crossing another display`() throws {
    let desk = [
      laptop: Rect(x: -1_512, y: 50, width: 1_512, height: 982),
      external: Rect(x: 0, y: 0, width: 1_920, height: 1_080),
    ]
    let isolated = isolatedDisplayArrangement(desk, primary: external)
    for id in [laptop, external] {
      let owner = try #require(isolated[id])
      let neighbor = try #require(isolated[id == laptop ? external : laptop])
      for x in [owner.x - owner.width * 0.6, owner.x + owner.width * 0.8] {
        let partial = FrameAssignment(windowID: WindowID(rawValue: 1), frame: Rect(
          x: x, y: owner.y + 40, width: owner.width * 0.8, height: owner.height - 80
        ))
        let strip = continuousStripFramesForActiveWorkspace(
          [partial], viewport: owner, allMonitorFrames: Array(isolated.values)
        )
        #expect(strip.parkedWindowIDs.isEmpty)
        #expect(strip.frames == [partial])
        let overlapX = max(0, min(partial.frame.x + partial.frame.width, neighbor.x + neighbor.width) - max(partial.frame.x, neighbor.x))
        let overlapY = max(0, min(partial.frame.y + partial.frame.height, neighbor.y + neighbor.height) - max(partial.frame.y, neighbor.y))
        #expect(overlapX * overlapY == 0)
      }
    }
    #expect(isolated[external]?.x == 0)
    #expect(isolated[external]?.y == 0)
    #expect(spatialMonitor(from: laptop, toward: .right, frames: desk) == external)
  }
}
