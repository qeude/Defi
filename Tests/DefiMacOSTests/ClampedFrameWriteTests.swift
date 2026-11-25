import ApplicationServices
import DefiModel
import Foundation
import Testing

@testable import DefiMacOS

struct ClampedFrameWriteTests {
  private final class NativeState {
    var point = CGPoint(x: 0, y: 40)
    var size = CGSize(width: 800, height: 700)
    var positions = 0
    var sizes = 0
  }

  // lateMove: a busy app applies each move only after the next resize message.
  @Test(arguments: [false, true])
  func clampedGrowthMovesBeforeResizingWithoutUncoveringTheDisplayEdge(lateMove: Bool) {
    let state = NativeState()
    var pendingPoint: CGPoint?
    state.point.x = 600
    state.size.width = 600
    let display = Rect(x: 0, y: 0, width: 1200, height: 900)
    let writer = AXFrameAccessibilityWriter(
      positionWriter: { _, point in
        state.positions += 1
        if lateMove { pendingPoint = point } else { state.point = point }
        return true
      },
      // macOS clamps a resize to the display at the window's current position.
      sizeWriter: { _, size in
        state.sizes += 1
        state.size = CGSize(width: min(size.width, 1200 - state.point.x), height: size.height)
        if let point = pendingPoint { state.point = point; pendingPoint = nil }
        return true
      },
      sizeReader: { _ in state.size }, positionReader: { _ in state.point },
      enhancedUIWriter: { _, _ in true }
    )
    let coordinator = AXFrameCoordinator(accessibilityWriter: writer)
    coordinator.latestGeneration = 1
    let id = WindowID(rawValue: 1), element = AXUIElementCreateApplication(-1)
    let write = AsyncPositionWrite(
      element: element, application: element, processID: -1,
      fromPoint: state.point, point: CGPoint(x: 0, y: 40),
      fromSize: state.size, size: CGSize(width: 1200, height: 700),
      positionChanged: true, sizeChanged: true,
      synchronousSizeWriteSucceeded: false, enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016, isParked: false,
      requiresVerifiedOffscreenWrite: false
    )
    let frame = QueuedPositionFrame(
      generation: 1, source: "command-layout-animation", writes: [id: write], monitorFrames: [display], stagesVisibleBeforeParking: false, completion: nil
    )
    coordinator.recordCompletedPosition(state.point, windowID: id)
    for _ in 1...4 {
      _ = coordinator.applyBatch(
        ProcessWriteBatch(processID: -1, writes: [(id, write)]), frame: frame)
      if !lateMove { #expect(abs(state.point.x + state.size.width - 1200) < 0.5) }
    }
    #expect(state.point.x == 0 && state.size.width == 1200)
  }

  // A column straddling the display edge widens in place, as when the strip beside a
  // pinned column grows: macOS clamps that growth at the final place too.
  @Test(arguments: [false, true])
  func growthPastTheDisplayEdgeInPlaceResizesWhereTheWindowFits(moves: Bool) {
    let state = NativeState()
    state.point.x = 595
    state.size.width = 384
    let display = Rect(x: 0, y: 0, width: 980, height: 900)
    let writer = AXFrameAccessibilityWriter(
      positionWriter: { _, point in
        state.positions += 1
        state.point = point
        return true
      },
      // macOS clamps a resize to the display at the window's current position.
      sizeWriter: { _, size in
        state.sizes += 1
        state.size = CGSize(width: min(size.width, 980 - state.point.x), height: size.height)
        return true
      },
      sizeReader: { _ in state.size }, positionReader: { _ in state.point },
      enhancedUIWriter: { _, _ in true }
    )
    let coordinator = AXFrameCoordinator(accessibilityWriter: writer)
    coordinator.latestGeneration = 1
    let id = WindowID(rawValue: 1), element = AXUIElementCreateApplication(-1)
    let target = CGPoint(x: moves ? 500 : 595, y: 40)
    let write = AsyncPositionWrite(
      element: element, application: element, processID: -1,
      fromPoint: state.point, point: target,
      fromSize: state.size, size: CGSize(width: 567, height: 700),
      positionChanged: moves, sizeChanged: true,
      synchronousSizeWriteSucceeded: false, enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016, isParked: false,
      requiresVerifiedOffscreenWrite: false
    )
    let frame = QueuedPositionFrame(
      generation: 1, source: "command-layout-animation", writes: [id: write], monitorFrames: [display],
      stagesVisibleBeforeParking: false, completion: nil
    )
    coordinator.recordCompletedPosition(state.point, windowID: id)
    _ = coordinator.applyBatch(ProcessWriteBatch(processID: -1, writes: [(id, write)]), frame: frame)
    #expect(state.point == target)
    #expect(state.size.width == 567)
  }

  // lateMove: a busy app applies each move only after the next resize message.
  @Test(arguments: [false, true])
  func movingToATallerDisplayFillsItsHeight(lateMove: Bool) {
    let state = NativeState()
    var pendingPoint: CGPoint?
    state.point = CGPoint(x: -1000, y: 30)
    state.size = CGSize(width: 640, height: 570)
    let small = Rect(x: -1000, y: 0, width: 1000, height: 600)
    let tall = Rect(x: 0, y: 0, width: 1400, height: 1000)
    let writer = AXFrameAccessibilityWriter(
      positionWriter: { _, point in
        state.positions += 1
        if lateMove { pendingPoint = point } else { state.point = point }
        return true
      },
      // macOS clamps a resize to the display at the window's current position.
      sizeWriter: { _, size in
        state.sizes += 1
        let display = state.point.x < 0 ? small : tall
        state.size = CGSize(width: size.width, height: min(size.height, display.y + display.height - state.point.y))
        if let point = pendingPoint { state.point = point; pendingPoint = nil }
        return true
      },
      sizeReader: { _ in state.size }, positionReader: { _ in state.point },
      enhancedUIWriter: { _, _ in true }
    )
    let coordinator = AXFrameCoordinator(accessibilityWriter: writer)
    coordinator.latestGeneration = 1
    let id = WindowID(rawValue: 1), element = AXUIElementCreateApplication(-1)
    let write = AsyncPositionWrite(
      element: element, application: element, processID: -1,
      fromPoint: state.point, point: CGPoint(x: 0, y: 30),
      fromSize: state.size, size: CGSize(width: 640, height: 970),
      positionChanged: true, sizeChanged: true,
      synchronousSizeWriteSucceeded: false, enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016, isParked: false,
      requiresVerifiedOffscreenWrite: false
    )
    let frame = QueuedPositionFrame(
      generation: 1, source: "test-monitor-height", writes: [id: write], monitorFrames: [small, tall],
      stagesVisibleBeforeParking: false, completion: nil
    )
    coordinator.recordCompletedPosition(state.point, windowID: id)
    _ = coordinator.applyBatch(ProcessWriteBatch(processID: -1, writes: [(id, write)]), frame: frame)
    if let point = pendingPoint { state.point = point }
    #expect(state.point == CGPoint(x: 0, y: 30))
    #expect(state.size == CGSize(width: 640, height: 970))
  }

}
