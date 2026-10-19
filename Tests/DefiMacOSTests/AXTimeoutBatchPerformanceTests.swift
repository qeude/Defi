import ApplicationServices
import DefiModel
import Foundation
import Synchronization
import Testing
@testable import DefiMacOS

struct AXTimeoutBatchPerformanceTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["DEFI_PERF_JSON"] == "1"))
  func homogeneousMotionTimeouts() throws {
    let application = AXUIElementCreateApplication(-42)
    let calls = Mutex((application: 0, window: 0, writes: 0))
    let applicationBox = AssumedThreadSafe(application)
    let timeouts = AXMessagingTimeoutAccess(timeoutSetter: { element, _ in
      calls.withLock {
        if CFEqual(element, applicationBox.value) { $0.application += 1 }
        else { $0.window += 1 }
      }
    })
    let writer = AXFrameAccessibilityWriter(positionWriter: { _, _ in
      calls.withLock { $0.writes += 1 }; return true
    }, nativePositionReader: { _, _ in nil })
    let coordinator = AXFrameCoordinator(accessibilityWriter: writer, messagingTimeoutAccess: timeouts)
    coordinator.latestGeneration = 1
    let writes = Dictionary(uniqueKeysWithValues: (0..<8).map { index in
      (WindowID(rawValue: UInt64(index + 1)), AsyncPositionWrite(
        element: AXUIElementCreateApplication(-100 - Int32(index)), application: application, processID: 42,
        fromPoint: CGPoint(x: index * 800, y: 40), point: CGPoint(x: index * 800 - 1000, y: 40),
        fromSize: CGSize(width: 800, height: 700), size: CGSize(width: 800, height: 700),
        positionChanged: true, sizeChanged: false, animatesSize: false,
        synchronousSizeWriteSucceeded: true, enhancedUIWasEnabled: false, timeoutSeconds: 0.016,
        isParked: false, isReentering: false, requiresVerifiedOffscreenWrite: false))
    })
    let frame = QueuedPositionFrame(generation: 1, source: "performance", writes: writes,
      animatedWindowIDs: Set(writes.keys), animationDuration: 0.125, refreshRateHz: 120,
      displayIDs: [], initialProgressVelocity: 0, stagesVisibleBeforeParking: false, completion: nil)
    let batch = try #require(coordinator.processWriteBatches(writes, windowIDs: Set(writes.keys)).first)
    var applied = 0
    let started = ProcessInfo.processInfo.systemUptime
    for index in 1...100 {
      applied += coordinator.applyBatch(batch, frame: frame, progress: Double(index) / 100,
        intermediate: true, stagingReentry: false, recordFinalSuccess: false).applied
    }
    let counts = calls.withLock { $0 }
    #expect(applied == 800)
    #expect(counts.writes == 800)
    let record: [String: Any] = ["case": "ax-timeout-batch", "operations": 800,
      "errors": applied == 800 && counts.writes == 800 ? 0 : 1, "output": ["writes": counts.writes],
      "metrics": ["application_timeout_calls": Double(counts.application),
        "window_timeout_calls": Double(counts.window), "elapsed_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000]]
    let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    print("DEFI_PERF_JSON " + String(decoding: data, as: UTF8.self))
  }
}
