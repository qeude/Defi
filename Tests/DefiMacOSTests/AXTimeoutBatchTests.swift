import ApplicationServices
import DefiModel
import Synchronization
import Testing
@testable import DefiMacOS

struct AXTimeoutBatchTests {
  @Test(arguments: [false, true]) func mixedTimeoutsRetainPerWindowScopes(mixed: Bool) {
    let result = runBatch(mixed: mixed, supersede: false)
    #expect(result.writes == 2)
    #expect(result.applied == 2)
    #expect(result.stale == 0)
    #expect(result.applicationTimeouts == (mixed ? [0.016, 0, 0.025, 0] : [0.025, 0]))
    #expect(result.windowTimeouts == (mixed ? [0.016, 0, 0.025, 0] : [0.025, 0, 0.025, 0]))
  }

  @Test func supersededBatchRestoresTimeoutsAndStopsWriting() {
    let result = runBatch(mixed: false, supersede: true)
    #expect(result.writes == 1)
    #expect(result.applied == 0)
    #expect(result.stale == 2)
    #expect(result.applicationTimeouts == [0.025, 0])
    #expect(result.windowTimeouts == [0.025, 0])
  }

  private func runBatch(mixed: Bool, supersede: Bool) -> (
    applicationTimeouts: [Float], windowTimeouts: [Float], writes: Int, applied: Int, stale: Int
  ) {
    let application = AssumedThreadSafe(AXUIElementCreateApplication(-42))
    let transitions = Mutex((application: [Float](), window: [Float](), writes: 0))
    let access = AXMessagingTimeoutAccess(timeoutSetter: { element, timeout in
      transitions.withLock {
        if CFEqual(element, application.value) { $0.application.append(timeout) }
        else { $0.window.append(timeout) }
      }
    })
    var coordinator: AXFrameCoordinator!
    let writer = AXFrameAccessibilityWriter(positionWriter: { _, _ in
      transitions.withLock { $0.writes += 1 }
      if supersede { coordinator.latestGeneration = 2 }
      return true
    }, nativePositionReader: { _, _ in nil })
    coordinator = AXFrameCoordinator(accessibilityWriter: writer, messagingTimeoutAccess: access)
    coordinator.latestGeneration = 1
    let writes = Dictionary(uniqueKeysWithValues: (1...2).map { index in
      (WindowID(rawValue: UInt64(index)), AsyncPositionWrite(
        element: AXUIElementCreateApplication(-100 - Int32(index)), application: application.value, processID: 42,
        fromPoint: CGPoint(x: 0, y: 40), point: CGPoint(x: -1000, y: 40),
        fromSize: CGSize(width: 800, height: 700), size: CGSize(width: 800, height: 700),
        positionChanged: true, sizeChanged: false, animatesSize: false,
        synchronousSizeWriteSucceeded: true, enhancedUIWasEnabled: false,
        timeoutSeconds: mixed && index == 1 ? 0.006 : 0.025,
        isParked: false, isReentering: false, requiresVerifiedOffscreenWrite: false))
    })
    let frame = QueuedPositionFrame(generation: 1, source: "test", writes: writes,
      animatedWindowIDs: [], animationDuration: 0, refreshRateHz: 120, displayIDs: [],
      initialProgressVelocity: 0, stagesVisibleBeforeParking: false, completion: nil)
    let batch = ProcessWriteBatch(processID: 42, writes: writes.sorted { $0.key.rawValue < $1.key.rawValue })
    let result = coordinator.applyBatch(batch, frame: frame, progress: 1, intermediate: false,
      stagingReentry: false, recordFinalSuccess: false)
    let observed = transitions.withLock { $0 }
    return (observed.application, observed.window, observed.writes, result.applied, result.stale)
  }
}
