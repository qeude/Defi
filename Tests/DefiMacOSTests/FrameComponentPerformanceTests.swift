import ApplicationServices
import DefiModel
import Foundation
import Testing

@testable import DefiMacOS

struct FrameComponentPerformanceTests {
  private final class NativeState {
    var point = CGPoint(x: 0, y: 40)
    var size = CGSize(width: 800, height: 700)
    var positions = 0
    var sizes = 0
  }

  private func exercise(projected: Bool, samples: Int, completedSizeKnown: Bool = true,
                        finish: Bool = false) -> (NativeState, Double) {
    let state = NativeState()
    if projected { state.point.x = 1199 }
    let writer = AXFrameAccessibilityWriter(
      positionWriter: { _, point in state.positions += 1; state.point = point; return true },
      sizeWriter: { _, size in
        state.sizes += 1
        state.size = size
        state.point.x += 17
        return true
      },
      sizeReader: { _ in state.size }, positionReader: { _ in state.point },
      enhancedUIWriter: { _, _ in true }, nativePositionReader: { _, _ in nil }
    )
    let coordinator = AXFrameCoordinator(accessibilityWriter: writer)
    coordinator.latestGeneration = 1
    let id = WindowID(rawValue: 1), element = AXUIElementCreateApplication(-1)
    let write = AsyncPositionWrite(
      element: element, application: element, processID: -1,
      fromPoint: CGPoint(x: projected ? 6000 : 0, y: 40),
      point: CGPoint(x: projected ? 6100 : 200, y: 40),
      fromSize: state.size, size: CGSize(width: 801, height: 700),
      positionChanged: true, sizeChanged: true, animatesSize: true,
      synchronousSizeWriteSucceeded: false, enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016, isParked: false, isReentering: false,
      requiresVerifiedOffscreenWrite: false
    )
    let frame = QueuedPositionFrame(
      generation: 1, source: "command-animation", writes: [id: write],
      animatedWindowIDs: [id], animationDuration: 0.15, refreshRateHz: 120,
      displayIDs: [],
      monitorFrames: projected ? [Rect(x: 0, y: 0, width: 1200, height: 900)] : [],
      initialProgressVelocity: 0, stagesVisibleBeforeParking: false,
      completion: nil
    )
    coordinator.recordCompletedPosition(state.point, windowID: id)
    if completedSizeKnown {
      coordinator.recordCompletedSize(state.size, windowID: id,
                                      incrementWriteCount: false, sizeWasReadBack: true)
    }
    let start = ProcessInfo.processInfo.systemUptime
    var staleSamples = 0
    var incorrectPositionSamples = 0
    for i in 1...samples {
      let result = coordinator.applyBatch(
        ProcessWriteBatch(processID: -1, writes: [(id, write)]), frame: frame,
        progress: Double(i) / Double(samples), intermediate: true,
        stagingReentry: false, recordFinalSuccess: false
      )
      staleSamples += result.stale
      let positionCorrect = projected
        ? state.point.x == 1199
        : abs(state.point.x - Double(i) * 200 / Double(samples)) < 0.5
      if !positionCorrect { incorrectPositionSamples += 1 }
    }
    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
    #expect(staleSamples == 0)
    #expect(incorrectPositionSamples == 0)
    if finish {
      let result = coordinator.applyBatch(
        ProcessWriteBatch(processID: -1, writes: [(id, write)]), frame: frame,
        progress: 1, intermediate: false, stagingReentry: false, recordFinalSuccess: true
      )
      #expect(result.applied == 1 && result.stale == 0)
      #expect(state.point.x == (projected ? 6100 : 200))
      #expect(state.size.width == 801)
    }
    return (state, elapsed)
  }

  @Test(arguments: [false, true])
  func quantizedSizeSamplesKeepCorrectivePosition(projected: Bool) {
    let (state, _) = exercise(projected: projected, samples: 100)
    #expect(state.sizes == 2)
    #expect(state.positions == (projected ? 2 : 100))
    #expect(state.size.width == 801)
  }

  @Test func unknownSizeIsWrittenAndFinalGeometryStillConverges() {
    let (state, _) = exercise(projected: false, samples: 100,
                              completedSizeKnown: false, finish: true)
    #expect(state.sizes == 3)
    #expect(state.positions == 101)
  }

  @Test func performanceComponents() throws {
    guard ProcessInfo.processInfo.environment["DEFI_PERF_JSON"] == "1" else { return }
    for projected in [false, true] {
      let (state, elapsed) = exercise(projected: projected, samples: 100)
      #expect(abs(state.size.width - 801) < 0.5)
      let data = try JSONSerialization.data(withJSONObject: [
        "case": projected ? "projected-components" : "width-components",
        "operations": 100, "errors": 0, "output": ["samples": 100, "converged": true],
        "metrics": ["size_calls": Double(state.sizes), "position_calls": Double(state.positions),
                    "elapsed_ms": elapsed]
      ])
      print("DEFI_PERF_JSON " + String(decoding: data, as: UTF8.self))
    }
  }
}
