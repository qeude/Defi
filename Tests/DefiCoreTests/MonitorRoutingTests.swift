import DefiCore
import DefiModel
import Testing

struct MonitorRoutingTests {
  @Test
  func selectsNearestMonitorInPhysicalDirection() {
    let source = MonitorID(rawValue: 1)
    let right = MonitorID(rawValue: 2)
    let lowerRight = MonitorID(rawValue: 3)
    let frames = [
      source: Rect(x: 0, y: 0, width: 1_000, height: 800),
      right: Rect(x: 1_000, y: 0, width: 1_000, height: 800),
      lowerRight: Rect(x: 900, y: 900, width: 1_000, height: 800),
    ]

    #expect(spatialMonitor(from: source, toward: .right, frames: frames) == right)
    #expect(spatialMonitor(from: source, toward: .down, frames: frames) == lowerRight)
    #expect(spatialMonitor(from: source, toward: .left, frames: frames) == nil)
  }

  @Test
  func floatingFrameKeepsRelativePositionAndSizeAcrossMonitors() {
    #expect(
      rebasedFloatingFrame(
        Rect(x: 400, y: 300, width: 200, height: 200),
        from: Rect(x: 0, y: 0, width: 1_000, height: 800),
        to: Rect(x: 1_000, y: 0, width: 2_000, height: 1_000)
      ) == Rect(x: 1_900, y: 400, width: 200, height: 200)
    )
  }
}
