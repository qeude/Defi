import DefiCore
import DefiModel
import Testing

struct MonitorRoutingTests {
  @Test(arguments: [(900.0, 900.0), (100, 800)])
  func selectsTheNearestMonitorWhoseMainAxisDominates(lowerRightX: Double, lowerRightY: Double) {
    let source = MonitorID(rawValue: 1), right = MonitorID(rawValue: 2), lowerRight = MonitorID(rawValue: 3)
    let frames = [
      source: Rect(x: 0, y: 0, width: 1_000, height: 800),
      right: Rect(x: 1_000, y: 0, width: 1_000, height: 800),
      lowerRight: Rect(x: lowerRightX, y: lowerRightY, width: 1_000, height: 800),
    ]
    #expect(spatialMonitor(from: source, toward: .right, frames: frames) == right)
    #expect(spatialMonitor(from: source, toward: .down, frames: frames) == lowerRight)
    #expect(spatialMonitor(from: source, toward: .left, frames: frames) == nil)
  }

  @Test(arguments: [
    (Rect(x: 400, y: 300, width: 200, height: 200), Rect(x: 1_000, y: 0, width: 2_000, height: 1_000),
      Rect(x: 1_900, y: 400, width: 200, height: 200)),
    // an oversized frame keeps its size on a smaller monitor
    (Rect(x: 0, y: 0, width: 1_200, height: 900), Rect(x: 1_000, y: 0, width: 600, height: 500),
      Rect(x: 1_000, y: 0, width: 1_200, height: 900)),
  ])
  func floatingFrameKeepsRelativePositionAndSizeAcrossMonitors(frame: Rect, destination: Rect, expected: Rect) {
    #expect(rebasedFloatingFrame(frame, from: Rect(x: 0, y: 0, width: 1_000, height: 800), to: destination)
      == expected)
  }

}
