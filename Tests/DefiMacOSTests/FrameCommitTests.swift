import ApplicationServices
import Darwin
import DefiCore
import DefiModel
import Synchronization
import Testing

@testable import DefiMacOS

struct FrameCommitTests {
  @Test func overviewExitAcceptsVerifiedParkingDespiteNativeVerticalClamping() {
    let visible = WindowID(rawValue: 1), parked = WindowID(rawValue: 2)
    let monitor = Rect(x: 0, y: 0, width: 1512, height: 910)
    let shown = Rect(x: 0, y: 37, width: 752, height: 902)
    let target = Rect(x: 1511, y: 37, width: 752, height: 902)
    let clamped = Rect(x: 1511, y: 30, width: 752, height: 902)
    func ready(_ actual: Rect, pending: Set<WindowID> = []) -> Bool {
      overviewExitFramesAreReady(windowIDs: [visible, parked], hiddenWindowIDs: [parked],
        pendingWriteWindowIDs: pending, unresolvedWindowIDs: [parked],
        targets: [visible: shown, parked: target], observed: [visible: shown, parked: actual],
        monitorFrames: [monitor])
    }
    #expect(ready(clamped), "A safe parked window must not disable the visible zoom handoff")
    #expect(!ready(shown), "A parking leak must still prevent uncovering native windows")
    #expect(!ready(clamped, pending: [parked]), "Outstanding writes must settle before uncovering")
    #expect(!overviewExitFramesAreReady(windowIDs: [visible], hiddenWindowIDs: [],
      pendingWriteWindowIDs: [], unresolvedWindowIDs: [visible], targets: [visible: shown],
      observed: [visible: shown], monitorFrames: [monitor]))
    #expect(!overviewExitFramesAreReady(windowIDs: [parked], hiddenWindowIDs: [parked],
      pendingWriteWindowIDs: [], unresolvedWindowIDs: [parked], targets: [parked: target],
      observed: [parked: clamped], monitorFrames: [monitor,
        Rect(x: 1512, y: 0, width: 1512, height: 910)]),
      "Parking must be safe on every monitor")
    #expect(!overviewExitFramesAreReady(windowIDs: [visible], hiddenWindowIDs: [],
      pendingWriteWindowIDs: [], unresolvedWindowIDs: [], targets: [visible: shown],
      observed: [visible: clamped], monitorFrames: [monitor]))
  }

  @Test(arguments: [false, true])
  func horizontalMotionPromotesOnlyIntermediateLaneWork(intermediate: Bool) {
    let observed = Mutex<UInt32?>(nil)
    let finished = DispatchSemaphore(value: 0)
    let coordinator = AXFrameCoordinator(batchWriter: { _, _, _, _, _, _ in
      observed.withLock { $0 = qos_class_self().rawValue }
      return (1, 0, [], true)
    })
    coordinator.latestGeneration = 1
    let id = WindowID(rawValue: 1)
    let write = makeMotionWrite(fromX: 0, toX: -1000)
    let frame = QueuedPositionFrame(
      generation: 1, source: "command-animation", writes: [id: write],
      animatedWindowIDs: [id], animationDuration: 0.125, refreshRateHz: 120,
      displayIDs: [], initialProgressVelocity: 0, stagesVisibleBeforeParking: false,
      completion: nil
    )
    let sample = ProcessAnimationSample(
      frame: frame, batch: ProcessWriteBatch(processID: write.processID, writes: [(id, write)]),
      progress: intermediate ? 0.5 : 1, progressVelocity: 0,
      intermediate: intermediate, stagingReentry: false, recordFinalSuccess: false,
      accumulator: FrameResultAccumulator(), completion: { finished.signal() }
    )
    let origin = coordinator.animationClockQueue
    origin.async {
      _ = coordinator.submitAnimationSamples([sample])
    }
    #expect(finished.wait(timeout: .now() + 1) == .success)
    #expect(coordinator.animationLaneWriteGroup.wait(timeout: .now() + 1) == .success)
    #expect(observed.withLock { $0 } == (
      intermediate ? QOS_CLASS_USER_INTERACTIVE.rawValue : QOS_CLASS_USER_INITIATED.rawValue
    ))
  }

  @Test
  func laneCompletionDuringBusyTickIsRetriedWithoutWaitingForTimer() {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let retried = DispatchSemaphore(value: 0)
    let calls = Mutex(0)
    let queue = DispatchQueue(label: "test.animation-lane-wake")
    // Keep the fallback out of the test: only the completion can wake this tick.
    let driver = FrameAnimationDriver(interval: 60, refreshInterval: 1 / 120,
                                     displayIDs: [], queue: queue) { _ in
      let first = calls.withLock { $0 += 1; return $0 == 1 }
      if first {
        entered.signal()
        _ = release.wait(timeout: .now() + 1)
        return false
      }
      retried.signal()
      return true
    }
    defer { driver.stop() }
    driver.requestTick()
    #expect(entered.wait(timeout: .now() + 1) == .success)
    driver.requestTick(afterLaneCompletion: true)
    release.signal()
    #expect(retried.wait(timeout: .now() + 1) == .success)
    queue.sync {}
    #expect(calls.withLock { $0 } == 2)
  }

  @Test(arguments: [60.0, 120.0])
  func coalescedLaneCompletionDoesNotRepeatAcceptedOrCancelledTick(refreshRate: Double) {
    let interval = 1 / refreshRate
    for cancelled in [false, true] {
      var state = FrameAnimationPulseState()
      let queued = state.enqueue(now: 10, displayTimestamp: nil,
                                 interval: interval, refreshInterval: interval)
      #expect(queued)
      let completionQueued = state.enqueue(now: 10, displayTimestamp: nil, interval: interval,
                                           refreshInterval: interval, afterLaneCompletion: true)
      #expect(!completionQueued)
      state.stopped = cancelled
      let retries = state.finishTick(at: 10, advanced: !cancelled)
      #expect(!retries)
      let earlyQueued = state.enqueue(now: 10 + interval * 0.9, displayTimestamp: nil,
                                      interval: interval, refreshInterval: interval,
                                      afterLaneCompletion: true)
      #expect(!earlyQueued)
    }
  }

  @Test(arguments: [60.0, 120.0])
  func laneCompletionRecoversMissedRefreshWithoutAccelerating(refreshRate: Double) {
    let interval = 1 / refreshRate
    var state = FrameAnimationPulseState(lastTick: 10, lastTickExecutedAt: 10)
    func enqueue(_ time: Double, lane: Bool = true) -> Bool {
      state.enqueue(now: time, displayTimestamp: nil, interval: interval,
                    refreshInterval: interval, afterLaneCompletion: lane)
    }
    #expect(!enqueue(10 + interval * 0.9))
    #expect(enqueue(10 + interval, lane: false))
    state.finishTick(at: 10 + interval, advanced: false) // Still writing.
    let readyAt = 10 + interval * 1.1
    #expect(enqueue(readyAt))
    state.finishTick(at: readyAt, advanced: true)
    #expect(!enqueue(readyAt + interval * 0.9))
    state.stopped = true
    #expect(!enqueue(readyAt + interval * 2))
  }

  @Test
  func completedLaneWakesTheClockAfterReleasingReadiness() {
    let coordinator = AXFrameCoordinator(batchWriter: { _, _, _, _, _, _ in
      (0, 0, [], true)
    })
    coordinator.latestGeneration = 1
    let frame = QueuedPositionFrame(
      generation: 1, source: "command-animation", writes: [:],
      animatedWindowIDs: [], animationDuration: 0.125, refreshRateHz: 120,
      displayIDs: [], initialProgressVelocity: 0, stagesVisibleBeforeParking: false,
      completion: nil
    )
    let ready = DispatchSemaphore(value: 0)
    let sample = ProcessAnimationSample(
      frame: frame, batch: ProcessWriteBatch(processID: 42, writes: []),
      progress: 0.5, progressVelocity: 0, intermediate: true,
      stagingReentry: false, recordFinalSuccess: false,
      accumulator: FrameResultAccumulator(), completion: nil,
      laneReady: {
        #expect(coordinator.animationLanesAreReady(processIDs: [42]))
        ready.signal()
      }
    )
    _ = coordinator.submitAnimationSamples([sample])
    #expect(ready.wait(timeout: .now() + 1) == .success)
    coordinator.animationLaneWriteGroup.wait()
  }

  @Test(arguments: [60.0, 120.0])
  func firstDisplayPulseIsNotDelayedByConstructionPhase(refreshRate: Double) {
    let now = ProcessInfo.processInfo.systemUptime
    var state = FrameAnimationPulseState()
    let accepted = state.enqueue(
      now: now, displayTimestamp: now - 1 / refreshRate,
      interval: 1 / refreshRate, refreshInterval: 1 / refreshRate
    )
    #expect(accepted)
  }

  @Test(arguments: [60.0, 120.0])
  func displayPulseCadenceIgnoresExecutionJitter(refreshRate: Double) {
    let interval = 1 / refreshRate
    var state = FrameAnimationPulseState(lastTick: 10 - interval)
    for step in 0..<8 {
      let timestamp = 10 + Double(step) * interval
      let enqueued = state.enqueue(now: timestamp + (step.isMultiple(of: 2) ? interval * 0.5 : 0),
                                   displayTimestamp: timestamp,
                                   interval: interval, refreshInterval: interval)
      #expect(enqueued)
      let started = state.beginTick()
      #expect(started)
      state.finishTick(at: timestamp, advanced: true)
    }
    state.stopped = true
    let stopped = state.enqueue(now: 11, displayTimestamp: 11,
                                interval: interval, refreshInterval: interval)
    #expect(!stopped)
  }

  @Test
  func displayPulseCoalescesAndTimerRecoversWithoutCatchUp() {
    var state = FrameAnimationPulseState(lastTick: 10 - 0.01)
    func enqueue(_ now: Double, display: Double? = nil) -> Bool {
      state.enqueue(now: now, displayTimestamp: display, interval: 0.01, refreshInterval: 0.01)
    }
    #expect(enqueue(10, display: 10))
    #expect(!enqueue(10.01, display: 10.01))
    let started = state.beginTick()
    #expect(started)
    state.finishTick(at: 10, advanced: true)
    // A coalesced display callback must not postpone fallback for an unapplied step.
    #expect(enqueue(10.025))
    #expect(!enqueue(10.05))
  }

  @Test(arguments: [60.0, 120.0])
  func timerMaintainsCadenceWhenDisplayCallbacksSkipRefreshes(refreshRate: Double) {
    let interval = 1 / refreshRate
    var state = FrameAnimationPulseState()
    var accepted: [Double] = []
    // The timer is offset from display refreshes, as it is in production.
    // Even display callbacks arrive; the missing odd callbacks need fallback.
    for step in 0..<12 {
      let displayTime = 10 + Double(step) * interval
      if step.isMultiple(of: 2), state.enqueue(
        now: displayTime, displayTimestamp: displayTime,
        interval: interval, refreshInterval: interval
      ) {
        accepted.append(displayTime)
        state.finishTick(at: displayTime, advanced: true)
      }
      let timerTime = displayTime + 0.4 * interval
      if state.enqueue(now: timerTime, displayTimestamp: nil,
                       interval: interval, refreshInterval: interval) {
        accepted.append(timerTime)
        state.finishTick(at: timerTime, advanced: true)
      }
    }
    #expect(accepted.count == 12)
    #expect(zip(accepted.dropFirst(), accepted).allSatisfy { $0 - $1 <= 1.5 * interval })
  }

  @Test(arguments: [60.0, 120.0])
  func fallbackDoesNotReplayDelayedDisplaySamples(refreshRate: Double) {
    let interval = 1 / refreshRate
    var state = FrameAnimationPulseState()
    func enqueue(_ now: Double, display: Double? = nil) -> Bool {
      state.enqueue(now: now, displayTimestamp: display, interval: interval, refreshInterval: interval)
    }
    #expect(enqueue(10, display: 10 - interval))
    state.finishTick(at: 10 - interval, executedAt: 10, advanced: true)
    #expect(!enqueue(10 + interval * 0.2))
    #expect(enqueue(10 + interval))
    state.finishTick(at: 10 + interval, advanced: true)
    #expect(!enqueue(10 + interval * 1.1, display: 10))
    #expect(!enqueue(10 + interval * 1.2))
  }

  @Test(arguments: [60.0, 120.0])
  func busyLanePollDoesNotDelayTheNextReadyDisplayPulse(refreshRate: Double) {
    let refresh = 1 / refreshRate
    let interval = 2 * refresh
    var state = FrameAnimationPulseState()
    func enqueue(_ timestamp: TimeInterval) -> Bool {
      state.enqueue(now: timestamp, displayTimestamp: timestamp,
                    interval: interval, refreshInterval: refresh)
    }
    #expect(enqueue(10))
    state.finishTick(at: 10, advanced: true)
    #expect(enqueue(10 + interval))
    // The AX lane is still busy: this pulse emits no ribbon sample.
    state.finishTick(at: 10 + interval, advanced: false)
    #expect(enqueue(10 + interval + refresh))
    state.finishTick(at: 10 + interval + refresh, advanced: true)
    #expect(!enqueue(10 + interval + 2 * refresh))
  }

  @Test(arguments: [true, false])
  func supersededOffscreenWriteDoesNotRetryAnObsoleteTarget(animated: Bool) {
    let attempts = Mutex(0)
    var coordinator: AXFrameCoordinator!
    let writer = AXFrameAccessibilityWriter(
      positionWriter: { _, _ in
        attempts.withLock { $0 += 1 }
        coordinator.lock.lock()
        coordinator.latestGeneration = 2
        coordinator.lock.unlock()
        return true
      },
      positionReader: { _ in CGPoint(x: 2520, y: 40) },
      nativePositionReader: { _, _ in nil }
    )
    coordinator = AXFrameCoordinator(accessibilityWriter: writer)
    coordinator.latestGeneration = 1
    let id = WindowID(rawValue: 1)
    let write = makeMotionWrite(fromX: 2568, toX: 1700, processID: -1,
                                isReentering: animated, isParked: !animated)
    let frame = QueuedPositionFrame(
      generation: 1, source: "command-animation", writes: [id: write],
      animatedWindowIDs: animated ? [id] : [], animationDuration: animated ? 0.15 : 0,
      refreshRateHz: 120, displayIDs: [], initialProgressVelocity: 0,
      stagesVisibleBeforeParking: false, completion: nil
    )
    _ = coordinator.applyBatch(
      ProcessWriteBatch(processID: -1, writes: [(key: id, value: write)]),
      frame: frame, progress: animated ? 0 : 1, intermediate: animated,
      stagingReentry: animated, recordFinalSuccess: !animated
    )
    #expect(attempts.withLock { $0 } == 1)
    #expect(coordinator.successfulFinalWritesByGeneration[1] == nil)
  }

  @Test
  func failedRetiredEnhancedUIRestoreRemainsRecoverable() {
    let attempts = Mutex(0)
    let coordinator = AXFrameCoordinator(accessibilityWriter: AXFrameAccessibilityWriter(
      enhancedUIWriter: { _, enabled in
        guard enabled else { return true }
        return attempts.withLock { $0 += 1; return $0 > 1 }
      }
    ))
    _ = coordinator.beginDeferredEnhancedUIRestore(
      processID: -1, application: AXUIElementCreateApplication(-1)
    )
    coordinator.pruneProcessLatencyState(liveProcessIDs: [])
    coordinator.animationLaneWriteGroup.wait()
    #expect(coordinator.hasDeferredEnhancedUIRestore(processID: -1))
    #expect(coordinator.processWriteQueues[-1] == nil)
    coordinator.invalidateAndWaitForWrites()
    #expect(attempts.withLock { $0 } == 2)
    #expect(!coordinator.hasDeferredEnhancedUIRestore(processID: -1))
  }

  @Test
  func transientDiscoveryLossKeepsTheSameSerializedAXLane() {
    let enables = Mutex(0)
    let coordinator = AXFrameCoordinator(accessibilityWriter: AXFrameAccessibilityWriter(
      enhancedUIWriter: { _, enabled in
        if enabled { enables.withLock { $0 += 1 } }
        return true
      }
    ))
    _ = coordinator.beginDeferredEnhancedUIRestore(
      processID: 42, application: AXUIElementCreateApplication(-1)
    )
    let pendingReservation = coordinator.reserveProcessWriteQueue(for: 42)
    let original = pendingReservation.queue
    let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    original.async { started.signal(); release.wait() }
    #expect(started.wait(timeout: .now() + 1) == .success)
    defer {
      release.signal(); original.sync { }
      pendingReservation.release()
      #expect(enables.withLock { $0 } == 1)
    }
    coordinator.pruneProcessLatencyState(liveProcessIDs: [])
    #expect(coordinator.processWriteQueue(for: 42) === original)
    #expect(enables.withLock { $0 } == 0)
    #expect(coordinator.animationLaneWriteGroup.wait(timeout: .now()) == .timedOut)
    coordinator.pruneProcessLatencyState(liveProcessIDs: [42])
    let rediscoveredReservation = coordinator.reserveProcessWriteQueue(for: 42)
    #expect(rediscoveredReservation.queue === original)
    release.signal()
    original.sync { }
    pendingReservation.release()
    rediscoveredReservation.release()
    #expect(coordinator.processWriteQueues[42] === original)
    coordinator.pruneProcessLatencyState(liveProcessIDs: [])
    #expect(coordinator.processWriteQueues[42] == nil)
  }

  @Test
  func delayedProcessWorkKeepsItsQueueAcrossRetirementAndRediscovery() {
    let coordinator = AXFrameCoordinator()
    let workStarted = DispatchSemaphore(value: 0)
    let releaseWork = DispatchSemaphore(value: 0)
    let original = coordinator.processWriteQueue(for: 42)
    defer { releaseWork.signal() }

    coordinator.enqueueProcessWrite(for: 42, after: .now() + 0.1) {
      workStarted.signal()
      releaseWork.wait()
    }
    #expect(coordinator.processWriteQueueReservations[42] == 1)
    coordinator.pruneProcessLatencyState(liveProcessIDs: [])
    #expect(coordinator.processWriteQueue(for: 42) === original)
    coordinator.pruneProcessLatencyState(liveProcessIDs: [42])
    let rediscovered = coordinator.reserveProcessWriteQueue(for: 42)
    #expect(rediscovered.queue === original)

    #expect(workStarted.wait(timeout: .now() + 3) == .success)
    releaseWork.signal()
    original.sync { }
    rediscovered.release()
    #expect(coordinator.processWriteQueues[42] === original)

    coordinator.pruneProcessLatencyState(liveProcessIDs: [])
    #expect(coordinator.processWriteQueues[42] == nil)
  }

  @Test(arguments: [true, false])
  func shutdownRestoreRetriesAndRetainsAnUnrestoredApplication(recovers: Bool) {
    let enables = Mutex(0)
    let writer = AXFrameAccessibilityWriter(enhancedUIWriter: { _, enabled in
      guard enabled else { return true }
      return enables.withLock { $0 += 1; return recovers && $0 == 2 }
    })
    let coordinator = AXFrameCoordinator(accessibilityWriter: writer)
    _ = coordinator.beginDeferredEnhancedUIRestore(
      processID: -1, application: AXUIElementCreateApplication(-1)
    )
    coordinator.restoreDeferredEnhancedUserInterfaces()
    #expect(enables.withLock { $0 } == 2)
    #expect(coordinator.deferredEnhancedUIRestores.isEmpty == recovers)
  }

  @Test
  func queuedAnimationAdmitsRecoveredLanesAtExecutionTime() {
    let coordinator = AXFrameCoordinator(batchWriter: { batch, _, _, _, _, _ in
      (batch.writes.count, 0, [], true)
    })
    coordinator.running = true
    let id = WindowID(rawValue: 1)
    coordinator.recordProcessLatencySamples([42: 100], intermediate: true)
    coordinator.submit(
      [id: makeMotionWrite(fromX: 900, toX: 100)], source: "command-animation",
      animationDuration: 0.15, refreshRateHz: 120, animatedWindowIDs: [id]
    )
    #expect(coordinator.pending?.animationDuration == 0.15)
    for _ in 0..<16 { coordinator.recordProcessLatencySamples([42: 2], intermediate: true) }
    if let frame = coordinator.pending { #expect(coordinator.animate(frame).frames > 1) }
  }

  @Test(arguments: [false, true])
  func liveBackpressureReplacesHistoricalHorizontalDecimation(vertical: Bool) {
    let samples = Mutex<[(Double, Bool)]>([])
    let coordinator = AXFrameCoordinator(batchWriter: { batch, _, progress, intermediate, _, _ in
      samples.withLock { $0.append((progress, intermediate)) }
      return (batch.writes.count, 0, [], true)
    })
    coordinator.running = true
    let first = WindowID(rawValue: 1), second = WindowID(rawValue: 2)
    coordinator.recordProcessLatencySamples([42: 2, 43: 100], intermediate: true)
    coordinator.submit(
      [first: makeMotionWrite(fromX: 900, toX: 100, processID: 42, toY: vertical ? 600 : 40),
       second: makeMotionWrite(fromX: 1800, toX: 1000, processID: 43, toY: vertical ? 600 : 40)],
      source: "command-animation", animationDuration: 0.15,
      refreshRateHz: 120, animatedWindowIDs: [first, second]
    )
    if let frame = coordinator.pending {
      let result = coordinator.animate(frame)
      #expect(vertical ? result.frames == 1 : result.frames >= 18)
    }
    let recorded = samples.withLock { $0 }
    if vertical {
      #expect(recorded.count == 2)
      #expect(recorded.allSatisfy { $0.0 == 1 && !$0.1 })
    } else {
      #expect(recorded.contains { $0.0 > 0 && $0.0 < 1 && $0.1 })
      #expect(recorded.count >= 36)
    }
  }

  @Test(arguments: [false, true])
  func disabledAnimationUsesOnlyTheFinalWriteWithoutNativeStaging(independentObservation: Bool) {
    let nativeReads = Mutex(0), writes = Mutex<[CGPoint]>([])
    let coordinator = AXFrameCoordinator(accessibilityWriter: AXFrameAccessibilityWriter(
      positionWriter: { _, point in writes.withLock { $0.append(point) }; return true },
      nativePositionReader: { _, _ in nativeReads.withLock { $0 += 1 }; return nil },
      independentBorderObservationAvailable: { independentObservation }
    ))
    coordinator.running = true
    let id = WindowID(rawValue: 1)
    coordinator.submit(
      [id: makeMotionWrite(fromX: 2568, toX: 1700, processID: -1, isReentering: true)],
      source: "command-animation", animationDuration: 0,
      refreshRateHz: 120, monitorFrames: [Rect(x: 0, y: 0, width: 2560, height: 1440)],
      animatedWindowIDs: [id]
    )
    coordinator.drain()
    #expect(writes.withLock { $0 } == [CGPoint(x: 1700, y: 40)])
    #expect(nativeReads.withLock { $0 } == 0)
    #expect(coordinator.lastAnimationFrameCount == 1)
  }

  @Test
  func failedEnhancedUIRestoreRetriesWithoutLosingTheLatestToken() {
    let enables = Mutex(0)
    let restored = DispatchSemaphore(value: 0)
    let writer = AXFrameAccessibilityWriter(enhancedUIWriter: { _, enabled in
      guard enabled else { return true }
      let attempt = enables.withLock { $0 += 1; return $0 }
      if attempt == 2 { restored.signal() }
      return attempt == 2
    })
    let coordinator = AXFrameCoordinator(accessibilityWriter: writer)
    let application = AXUIElementCreateApplication(-1)
    let old = coordinator.beginDeferredEnhancedUIRestore(processID: -1, application: application)
    coordinator.scheduleEnhancedUIRestore(processID: -1, token: old)
    let latest = coordinator.beginDeferredEnhancedUIRestore(processID: -1, application: application)
    coordinator.scheduleEnhancedUIRestore(processID: -1, token: latest)
    #expect(restored.wait(timeout: .now() + 1) == .success)
    coordinator.processWriteQueue(for: -1).sync { }
    #expect(enables.withLock { $0 } == 2)
    #expect(coordinator.deferredEnhancedUIRestores.isEmpty)
  }

  @Test
  func retiredEnhancedUIRestoreInvalidatesARediscoveredDisable() {
    let disables = Mutex(0)
    let application = AXUIElementCreateApplication(-1)
    var coordinator: AXFrameCoordinator!
    let writer = AXFrameAccessibilityWriter(enhancedUIWriter: { _, enabled in
      if enabled {
        _ = coordinator.beginDeferredEnhancedUIRestore(processID: -1, application: application)
      } else { disables.withLock { $0 += 1 } }
      return true
    })
    coordinator = AXFrameCoordinator(accessibilityWriter: writer)
    _ = coordinator.beginDeferredEnhancedUIRestore(processID: -1, application: application)
    coordinator.pruneProcessLatencyState(liveProcessIDs: [])
    coordinator.processWriteQueue(for: -1).sync { }
    _ = coordinator.beginDeferredEnhancedUIRestore(processID: -1, application: application)
    #expect(disables.withLock { $0 } == 3)
  }

  @Test(arguments: [true, false])
  func continuousMotionDisablesEnhancedUIOnceButRetriesFailedDisables(succeeds: Bool) {
    let disables = Mutex(0)
    let writer = AXFrameAccessibilityWriter(enhancedUIWriter: { _, enabled in
      if !enabled { disables.withLock { $0 += 1 } }
      return succeeds
    })
    let coordinator = AXFrameCoordinator(accessibilityWriter: writer)
    let application = AXUIElementCreateApplication(-1)
    let first = coordinator.beginDeferredEnhancedUIRestore(processID: -1, application: application)
    let second = coordinator.beginDeferredEnhancedUIRestore(processID: -1, application: application)
    #expect(second > first)
    #expect(disables.withLock { $0 } == (succeeds ? 1 : 2))
  }

  @Test
  func reentryDoesNotRepeatAnAcceptedNativeStageWhenAXReadbackLags() {
    let stagedWrites = Mutex(0)
    let stagingAXReads = Mutex(0)
    let nativePoint = Mutex(CGPoint(x: 2520, y: 40))
    let writer = AXFrameAccessibilityWriter(
      positionWriter: { _, point in
        if point.x == 2559 { stagedWrites.withLock { $0 += 1 } }
        nativePoint.withLock { $0 = point }
        return true
      },
      positionReader: { _ in
        if nativePoint.withLock({ $0.x == 2559 }) { stagingAXReads.withLock { $0 += 1 } }
        return CGPoint(x: 2520, y: 40)
      },
      nativePositionReader: { _, _ in nativePoint.withLock { $0 } }
    )
    let coordinator = AXFrameCoordinator(accessibilityWriter: writer)
    coordinator.latestGeneration = 1
    let id = WindowID(rawValue: 1)
    let write = makeMotionWrite(fromX: 2568, toX: 1700, processID: -1, isReentering: true)
    let frame = QueuedPositionFrame(
      generation: 1, source: "command-animation", writes: [id: write],
      animatedWindowIDs: [id], animationDuration: 0.15, refreshRateHz: 120,
      displayIDs: [], monitorFrames: [Rect(x: 0, y: 0, width: 2560, height: 1440)],
      initialProgressVelocity: 0, stagesVisibleBeforeParking: false, completion: nil
    )
    let result = coordinator.animate(frame)
    #expect(stagedWrites.withLock { $0 } == 1)
    #expect(stagingAXReads.withLock { $0 } == 0)
    #expect(result.frames > 1)
    #expect(coordinator.completedPositions[id]?.x == 1700)
  }

  @Test(arguments: [true, false])
  func reentryRetainsAXVerificationWhenNativeReadbackCannotVerify(available: Bool) {
    let attempts = Mutex(0)
    let writer = AXFrameAccessibilityWriter(
      positionWriter: { _, _ in attempts.withLock { $0 += 1 }; return true },
      positionReader: { _ in
        CGPoint(x: attempts.withLock { $0 } == 1 ? 2520 : 2559, y: 40)
      }
    )
    let applied = writer.applyPosition(
      makeMotionWrite(fromX: 2568, toX: 1700, processID: -1, isReentering: true),
      point: CGPoint(x: 2559, y: 40), forceOffscreenAccess: true,
      nativePositionIsVerified: {
        let native: CGPoint? = available ? CGPoint(x: 2520, y: 40) : nil
        return native.map { writer.pointDistance($0, CGPoint(x: 2559, y: 40)) <= 1 } ?? false
      }
    )
    #expect(applied)
    #expect(attempts.withLock { $0 } == 2)
  }

  @Test(arguments: [true, false])
  func intermediateBorderReadbackUsesNativeGeometryWithAXFallback(nativeAvailable: Bool) {
    let axReads = Mutex(0)
    let coordinator = AXFrameCoordinator(accessibilityWriter: AXFrameAccessibilityWriter(
      positionWriter: { _, _ in true },
      positionReader: { _ in axReads.withLock { $0 += 1 }; return CGPoint(x: 490, y: 40) },
      nativePositionReader: { _, _ in nativeAvailable ? CGPoint(x: 480, y: 40) : nil }
    ))
    let id = WindowID(rawValue: 1)
    let write = makeMotionWrite(fromX: 900, toX: 100)
    coordinator.latestGeneration = 1
    coordinator.updateLiveBorderWindowID(id)
    let frame = QueuedPositionFrame(
      generation: 1, source: "command-animation", writes: [id: write],
      animatedWindowIDs: [id], animationDuration: 0.15, refreshRateHz: 120,
      displayIDs: [], initialProgressVelocity: 0, stagesVisibleBeforeParking: false,
      completion: nil
    )
    _ = coordinator.applyBatch(
      ProcessWriteBatch(processID: 42, writes: [(key: id, value: write)]),
      frame: frame, progress: 0.5, intermediate: true,
      stagingReentry: false, recordFinalSuccess: false
    )
    #expect(axReads.withLock { $0 } == (nativeAvailable ? 0 : 1))
    #expect(coordinator.completedPositions[id] == CGPoint(x: nativeAvailable ? 480 : 490, y: 40))
  }

  @Test(arguments: [false, true])
  func horizontalMotionDoesNotWaitForIndependentBorderObservation(available: Bool) {
    let reads = Mutex(0)
    let coordinator = AXFrameCoordinator(accessibilityWriter: AXFrameAccessibilityWriter(
      positionWriter: { _, _ in true },
      positionReader: { _ in Issue.record("Unexpected AX fallback"); return nil },
      nativePositionReader: { _, _ in
        reads.withLock { $0 += 1 }
        return CGPoint(x: 480, y: 40)
      },
      independentBorderObservationAvailable: { available }
    ))
    let id = WindowID(rawValue: 1)
    let before = Rect(x: 900, y: 40, width: 800, height: 700)
    coordinator.latestGeneration = 1
    coordinator.updateLiveBorderWindowID(id)
    coordinator.recordObservedBorderFrame(before, windowID: id, sampledAt: 0)
    let write = makeMotionWrite(fromX: 900, toX: 100)
    let frame = QueuedPositionFrame(
      generation: 1, source: "command-animation", writes: [id: write],
      animatedWindowIDs: [id], animationDuration: 0.15, refreshRateHz: 120,
      displayIDs: [], initialProgressVelocity: 0, stagesVisibleBeforeParking: false,
      completion: nil
    )
    _ = coordinator.applyBatch(
      ProcessWriteBatch(processID: 42, writes: [(key: id, value: write)]),
      frame: frame, progress: 0.5, intermediate: true,
      stagingReentry: false, recordFinalSuccess: false
    )
    #expect(reads.withLock { $0 } == (available ? 0 : 1))
    #expect(coordinator.completedPosition(for: id)?.x == (available ? 500 : 480))
    // A successful command point must not become an observed border frame.
    #expect(coordinator.latestBorderFrame(for: id)?.x == (available ? 900 : 480))
    coordinator.recordObservedBorderFrame(before, windowID: id, sampledAt: 0)
    #expect(coordinator.latestBorderFrame(for: id)?.x == (available ? 900 : 480))
    let observed = Rect(x: 485, y: 40, width: 800, height: 700)
    coordinator.recordObservedBorderFrame(
      observed, windowID: id, sampledAt: ProcessInfo.processInfo.systemUptime
    )
    #expect(coordinator.latestBorderFrame(for: id) == observed)
  }

  @Test
  func ribbonDriverKeepsOneProgressUntilSharedFinal() {
    let samples = Mutex<[(pid_t, Double)]>([])
    let coordinator = AXFrameCoordinator(batchWriter: { batch, _, progress, _, _, _ in
      samples.withLock { $0.append((batch.processID, progress)) }
      return (batch.writes.count, 0, [], true)
    })
    coordinator.latestGeneration = 1
    coordinator.recordProcessLatencySamples([42: 2, 43: 40], intermediate: true)
    let first = WindowID(rawValue: 1), second = WindowID(rawValue: 2)
    let frame = QueuedPositionFrame(
      generation: 1, source: "command-animation",
      writes: [first: makeMotionWrite(fromX: 0, toX: -1000, processID: 42),
               second: makeMotionWrite(fromX: 800, toX: -200, processID: 43)],
      animatedWindowIDs: [first, second], animationDuration: 0.15,
      refreshRateHz: 120, displayIDs: [], initialProgressVelocity: 0,
      stagesVisibleBeforeParking: false, completion: nil
    )
    _ = coordinator.animate(frame)
    let recorded = samples.withLock { $0 }
    let fast = recorded.filter { $0.0 == 42 }.map { $0.1 }
    let slow = recorded.filter { $0.0 == 43 }.map { $0.1 }
    #expect(fast == slow)
    #expect(fast.count > 2 && fast.last == 1)
    #expect(fast.count >= 18)
  }

  @Test
  func slowFinalWritesCannotPreventFirstHorizontalMotionMeasurement() {
    let coordinator = AXFrameCoordinator()
    coordinator.running = true
    coordinator.predictedProcessLatencyMS[42] = 100
    let id = WindowID(rawValue: 1)
    coordinator.submit(
      [id: makeMotionWrite(fromX: 900, toX: 100, processID: 42)],
      source: "command-animation", animationDuration: 0.15,
      refreshRateHz: 120, animatedWindowIDs: [id]
    )
    #expect(coordinator.pending?.animationDuration == 0.15)
  }

  @Test(arguments: [false, true])
  func offscreenLogicalReentryUsesNativeAnchorWithoutCancellingRibbon(axReadbackLags: Bool) {
    let points = Mutex<[CGPoint]>([])
    let writer = AXFrameAccessibilityWriter(
      positionWriter: { _, point in
        points.withLock { $0.append(point) }
        return point.x <= 2559 && !(axReadbackLags && point.x == 2559)
      },
      nativePositionReader: { _, _ in axReadbackLags ? CGPoint(x: 2559, y: 40) : nil }
    )
    let coordinator = AXFrameCoordinator(accessibilityWriter: writer)
    coordinator.latestGeneration = 1
    let id = WindowID(rawValue: 1)
    let element = AXUIElementCreateApplication(-1)
    let entering = AsyncPositionWrite(
      element: element, application: element, processID: -1,
      fromPoint: CGPoint(x: 2568, y: 40), point: CGPoint(x: 1700, y: 40),
      fromSize: CGSize(width: 800, height: 700), size: CGSize(width: 800, height: 700),
      positionChanged: true, sizeChanged: false, animatesSize: false,
      synchronousSizeWriteSucceeded: true, enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016, isParked: false, isReentering: true,
      requiresVerifiedOffscreenWrite: false
    )
    let frame = QueuedPositionFrame(
      generation: 1, source: "command-animation", writes: [id: entering],
      animatedWindowIDs: [id], animationDuration: 0.15, refreshRateHz: 120,
      displayIDs: [], monitorFrames: [Rect(x: 0, y: 0, width: 2560, height: 1440)],
      initialProgressVelocity: 0, stagesVisibleBeforeParking: false, completion: nil
    )
    let result = coordinator.animate(frame)
    let recorded = points.withLock { $0 }
    if axReadbackLags {
      #expect(recorded.allSatisfy { $0.x < 2559 })
    } else {
      #expect(recorded.first?.x == 2559)
    }
    #expect(result.frames > 1)
    #expect(recorded.contains { $0.x < 2559 && $0.x > 1700 })
    #expect(coordinator.completedPositions[id]?.x == 1700)
  }

  @Test(arguments: [false, true])
  func ribbonWaitsForReentryBeforeMovingNeighbors(stagingFails: Bool) {
    let staged = Mutex(false)
    let movedBeforeStaging = Mutex(false)
    let coordinator = AXFrameCoordinator(batchWriter: { batch, _, _, _, staging, _ in
      if staging {
        Thread.sleep(forTimeInterval: 0.04)
        staged.withLock { $0 = true }
      } else if !staged.withLock({ $0 }) {
        movedBeforeStaging.withLock { $0 = true }
      }
      return (staging && stagingFails ? 0 : batch.writes.count, 0, [], true)
    })
    coordinator.latestGeneration = 1
    coordinator.activeAnimationRunning = true
    let entering = WindowID(rawValue: 1), neighbor = WindowID(rawValue: 2)
    let base = makeMotionWrite(fromX: 800, toX: -200, processID: 43)
    let reentry = AsyncPositionWrite(
      element: base.element, application: base.application, processID: base.processID,
      fromPoint: base.fromPoint, point: base.point, fromSize: base.fromSize, size: base.size,
      positionChanged: true, sizeChanged: false, animatesSize: false,
      synchronousSizeWriteSucceeded: true, enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016, isParked: false, isReentering: true,
      requiresVerifiedOffscreenWrite: false
    )
    let frame = QueuedPositionFrame(
      generation: 1, source: "command-animation",
      writes: [entering: reentry,
               neighbor: makeMotionWrite(fromX: 0, toX: -1000, processID: 42)],
      animatedWindowIDs: [entering, neighbor], animationDuration: 0.15,
      refreshRateHz: 120, displayIDs: [], initialProgressVelocity: 0,
      stagesVisibleBeforeParking: false, completion: nil
    )
    _ = coordinator.animate(frame)
    #expect(staged.withLock { $0 })
    #expect(!movedBeforeStaging.withLock { $0 })
    #expect(!coordinator.activeAnimationRunning)
  }

  @Test
  func failedMotionClearsVelocityAndUnchangedMotionSkipsAX() {
    let coordinator = AXFrameCoordinator()
    coordinator.latestGeneration = 1
    let id = WindowID(rawValue: 1)
    let write = makeMotionWrite(fromX: 0, toX: 100, processID: -1)
    let frame = QueuedPositionFrame(
      generation: 1, source: "command-animation", writes: [id: write],
      animatedWindowIDs: [id], animationDuration: 0.15, refreshRateHz: 120,
      displayIDs: [], initialProgressVelocity: 0, stagesVisibleBeforeParking: false,
      completion: nil
    )
    coordinator.retargetHorizontalVelocities[id] = 100
    let failed = coordinator.applyBatch(
      ProcessWriteBatch(processID: -1, writes: [(id, write)]), frame: frame,
      progress: 0.5, intermediate: true, stagingReentry: false,
      recordFinalSuccess: false, progressVelocity: 5
    )
    #expect(failed.applied == 0)
    #expect(coordinator.retargetHorizontalVelocities[id] == 0)
    coordinator.completedPositions[id] = CGPoint(x: 50, y: write.fromPoint.y)
    let unchanged = coordinator.applyBatch(
      ProcessWriteBatch(processID: -1, writes: [(id, write)]), frame: frame,
      progress: 0.5, intermediate: true, stagingReentry: false, recordFinalSuccess: false
    )
    #expect(!unchanged.attempted)
  }

  @Test
  func supersededSuccessfulWriteKeepsPhysicalPositionWithoutFinalReadiness() {
    var coordinator: AXFrameCoordinator!
    let writer = AXFrameAccessibilityWriter(positionWriter: { _, _ in
      coordinator.latestGeneration = 2
      return true
    })
    coordinator = AXFrameCoordinator(accessibilityWriter: writer)
    defer { coordinator = nil }
    coordinator.latestGeneration = 1
    let id = WindowID(rawValue: 1)
    let write = makeMotionWrite(fromX: 0, toX: 100, processID: -1)
    let frame = QueuedPositionFrame(
      generation: 1, source: "command-animation", writes: [id: write],
      animatedWindowIDs: [id], animationDuration: 0.15, refreshRateHz: 120,
      displayIDs: [], initialProgressVelocity: 0, stagesVisibleBeforeParking: false,
      completion: nil
    )
    let result = coordinator.applyBatch(
      ProcessWriteBatch(processID: -1, writes: [(id, write)]), frame: frame,
      progress: 0.5, intermediate: true, stagingReentry: false, recordFinalSuccess: true
    )
    #expect(result.stale == 1)
    #expect(coordinator.completedPositions[id]?.x == 50)
    #expect(coordinator.successfulFinalWritesByGeneration[1] == nil)
  }

  @Test func supersededFramesSkipQueueAndEnhancedUISetup() {
    let coordinator = AXFrameCoordinator()
    coordinator.latestGeneration = 2
    // An invalid process handle keeps the pre-fix failure independent of desktop permission.
    let element = AXUIElementCreateApplication(-1)
    let write = AsyncPositionWrite(
      element: element, application: element, processID: -1,
      fromPoint: CGPoint(x: 0, y: 40), point: CGPoint(x: 100, y: 40),
      fromSize: CGSize(width: 800, height: 700), size: CGSize(width: 800, height: 700),
      positionChanged: true, sizeChanged: false, animatesSize: false,
      synchronousSizeWriteSucceeded: true, enhancedUIWasEnabled: true,
      timeoutSeconds: 0.016, isParked: false, isReentering: false,
      requiresVerifiedOffscreenWrite: false
    )
    let windowID = WindowID(rawValue: 1)
    let frame = QueuedPositionFrame(
      generation: 1, source: "stale-setup-test", writes: [windowID: write],
      animatedWindowIDs: [], animationDuration: 0, refreshRateHz: 120,
      displayIDs: [], initialProgressVelocity: 0, stagesVisibleBeforeParking: false, completion: nil
    )
    let batch = coordinator.applyBatch(
      ProcessWriteBatch(processID: -1, writes: [(windowID, write)]), frame: frame,
      progress: 1, intermediate: false, stagingReentry: false, recordFinalSuccess: true
    )
    #expect(batch.applied == 0 && batch.stale == 1 && !batch.attempted)
    #expect(coordinator.deferredEnhancedUIRestores.isEmpty)
    let result = coordinator.applyFrame(frame, progress: 1, skippedProcesses: [])
    #expect(result.applied == 0 && result.stale == 1 && result.frames == 0)
    #expect(coordinator.processWriteQueues.isEmpty)
    let excluded = coordinator.applyFrame(frame, progress: 1, skippedProcesses: [-1])
    #expect(excluded.stale == 0)
  }

  @Test func completedTargetDoesNotWaitForSlowSibling() {
    let target = WindowID(rawValue: 1)
    let sibling = WindowID(rawValue: 2)
    let coordinator = AXFrameCoordinator()
    coordinator.latestGeneration = 10
    coordinator.activeWindowIDs = [target, sibling]
    #expect(coordinator.pendingWindowIDs == [target, sibling])

    coordinator.successfulFinalWritesByGeneration[10] = [target]
    #expect(coordinator.pendingWindowIDs == [sibling])
    #expect(coordinator.isBusy(for: target) == false)
    #expect(coordinator.isBusy(for: sibling))

    // A final position must still wait for its deferred size write.
    coordinator.activeAnimatedSizeWindowIDs = [target]
    #expect(coordinator.pendingWindowIDs == [target, sibling])
    coordinator.activeAnimatedSizeWindowIDs = []
    coordinator.activeWrites[target] = makeMotionWrite(fromX: 900, toX: 100, sizeChanged: true)
    #expect(coordinator.pendingWindowIDs == [target, sibling])
    coordinator.recordCompletedActiveSizeWrite(windowID: target)
    #expect(coordinator.pendingWindowIDs == [sibling])
    coordinator.deferredParkingWriteGenerations[target] = 10
    #expect(coordinator.pendingWindowIDs == [target, sibling])
    coordinator.deferredParkingWriteGenerations = [:]

    // Completion of an older generation cannot release a replacement target.
    coordinator.latestGeneration = 11
    #expect(coordinator.pendingWindowIDs == [target, sibling])
  }

  @Test
  func `Display invalidation rejects an old queued frame without replacing its parking target`() {
    let windowID = WindowID(rawValue: 42)
    let coordinator = AXFrameCoordinator()
    coordinator.nextGeneration = 7
    coordinator.latestGeneration = 7
    let oldWrite = makeMotionWrite(fromX: 900, toX: 100)
    let oldFrame = QueuedPositionFrame(
      generation: 7,
      source: "old-topology-parking",
      writes: [windowID: oldWrite],
      animatedWindowIDs: [],
      animationDuration: 0,
      refreshRateHz: 60,
      displayIDs: [],
      initialProgressVelocity: 0,
      stagesVisibleBeforeParking: false,
      completion: nil
    )
    coordinator.activeWrites[windowID] = oldWrite
    coordinator.updateParkingTargets([windowID: oldWrite])
    let oldSchedule = ParkingVerificationSchedule(
      expectedPoint: oldWrite.point,
      deadline: 10
    )
    coordinator.parkingVerificationSchedules[windowID] = oldSchedule
    coordinator.deferredParkingWriteGenerations[windowID] = 7

    coordinator.invalidate(reason: "display-change")

    #expect(coordinator.latestGeneration != oldFrame.generation)
    #expect(coordinator.activeWrites.isEmpty)
    #expect(coordinator.parkingTargets.isEmpty)
    #expect(coordinator.parkingVerificationSchedules.isEmpty)
    #expect(coordinator.deferredParkingWriteGenerations.isEmpty)

    let latestWrite = makeMotionWrite(fromX: 100, toX: 900)
    coordinator.updateParkingTargets([windowID: latestWrite])
    #expect(coordinator.parkingVerificationSchedules[windowID] == nil)

    let result = coordinator.applyFrame(
      oldFrame,
      progress: 1,
      skippedProcesses: []
    )
    #expect(result.stale == 1)
    #expect(result.applied == 0)
    #expect(result.frames == 0)
    #expect(coordinator.activeWrites.isEmpty)
    #expect(coordinator.parkingTargets[windowID]?.point == latestWrite.point)
    #expect(coordinator.deferredParkingWriteGenerations.isEmpty)
  }

  @Test
  func unchangedParkingTargetsShareOneVerificationWindow() {
    let point = CGPoint(x: 100, y: 200)
    let pending = ParkingVerificationSchedule(
      expectedPoint: point,
      deadline: 10
    )

    #expect(
      !parkingVerificationShouldSchedule(
        current: pending,
        expectedPoint: point,
        now: 9
      )
    )
    #expect(
      parkingVerificationShouldSchedule(
        current: pending,
        expectedPoint: CGPoint(x: 100, y: 201),
        now: 9
      )
    )
    #expect(
      parkingVerificationShouldSchedule(
        current: pending,
        expectedPoint: point,
        now: 10
      )
    )
  }

  @Test
  func failedFinalParkingReadKeepsVerificationScheduled() {
    let coordinator = AXFrameCoordinator()
    let windowID = WindowID(rawValue: 1)
    let element = AXUIElementCreateApplication(-1)
    let point = CGPoint(x: 100, y: 200)
    let write = AsyncPositionWrite(
      element: element, application: element, processID: -1,
      fromPoint: point, point: point,
      fromSize: CGSize(width: 800, height: 700),
      size: CGSize(width: 800, height: 700),
      positionChanged: true, sizeChanged: false, animatesSize: false,
      synchronousSizeWriteSucceeded: true, enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016, isParked: true, isReentering: false,
      requiresVerifiedOffscreenWrite: false
    )
    let schedule = ParkingVerificationSchedule(
      expectedPoint: point,
      deadline: ProcessInfo.processInfo.systemUptime + 1.4
    )
    coordinator.parkingTargets[windowID] = write
    coordinator.parkingVerificationSchedules[windowID] = schedule

    coordinator.verifyParkingTarget(
      windowID: windowID, expectedPoint: point,
      schedule: schedule, isFinalCheck: true
    )
    #expect(coordinator.parkingVerificationSchedules[windowID] == schedule)
  }

  @Test(arguments: [-100.0, 900.0])
  func interruptedRibbonStartsAtCompletedPositionAndKeepsOnlyForwardVelocity(targetX: Double) {
    let windowID = WindowID(rawValue: 1)
    let coordinator = AXFrameCoordinator()
    coordinator.recordCompletedPosition(CGPoint(x: 400, y: 40), windowID: windowID)
    coordinator.retargetHorizontalVelocities[windowID] = -500
    let frame = QueuedPositionFrame(
      generation: 2, source: "test-retarget",
      writes: [windowID: makeMotionWrite(fromX: 900, toX: targetX)],
      animatedWindowIDs: [windowID], animationDuration: 0.18,
      refreshRateHz: 120, displayIDs: [], initialProgressVelocity: 0,
      stagesVisibleBeforeParking: false, completion: nil
    )
    let rebased = coordinator.rebaseFrameToCompletedPositionsLocked(frame)
    #expect(rebased.frame.writes[windowID]?.fromPoint.x == 400)
    #expect(rebased.frame.writes[windowID]?.point.x == CGFloat(targetX))
    #expect(rebased.frame.initialProgressVelocity == (targetX < 400 ? 1 : 0))
    let samples = completedFrameSpringSamples(
      duration: 0.18, refreshRateHz: 120,
      initialVelocity: rebased.frame.initialProgressVelocity
    )
    let positions = samples.map { 400 + (targetX - 400) * $0.progress }
    #expect(positions.allSatisfy { $0 >= min(400, targetX) && $0 <= max(400, targetX) })
    #expect(positions == positions.sorted(by: targetX < 400 ? (>) : (<)))
  }

  @Test
  func interruptedRibbonPreservesColumnSpacingAcrossDifferentCompletionTimes() {
    let first = WindowID(rawValue: 1), second = WindowID(rawValue: 2)
    let coordinator = AXFrameCoordinator()
    coordinator.recordCompletedPosition(CGPoint(x: 100, y: 40), windowID: first)
    coordinator.recordCompletedPosition(CGPoint(x: 1000, y: 40), windowID: second)
    var a = makeMotionWrite(fromX: 200, toX: -300)
    var b = makeMotionWrite(fromX: 1000, toX: 500)
    a.usesCommonRibbonOffset = true
    b.usesCommonRibbonOffset = true
    let frame = QueuedPositionFrame(
      generation: 2, source: "command-animation", writes: [first: a, second: b],
      animatedWindowIDs: [first, second], animationDuration: 0.125,
      refreshRateHz: 120, displayIDs: [],
      monitorFrames: [Rect(x: 0, y: 0, width: 1512, height: 910)],
      initialProgressVelocity: 0, stagesVisibleBeforeParking: false, completion: nil)
    let rebased = coordinator.rebaseFrameToCompletedPositionsLocked(frame).frame
    let firstStart = rebased.writes[first]!.fromPoint.x
    let secondStart = rebased.writes[second]!.fromPoint.x
    #expect(secondStart - firstStart == 800)
    #expect(firstStart == 100)
    for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
      let x = firstStart + (-300 - firstStart) * progress
      let y = secondStart + (500 - secondStart) * progress
      #expect(y - x == 800)
    }
  }

  @Test(arguments: [-400.0, 400.0])
  func ribbonWritesReleaseSpaceBeforeMovingNeighbor(delta: Double) {
    let left = WindowID(rawValue: 2), right = WindowID(rawValue: 1)
    var a = makeMotionWrite(fromX: 100, toX: 100 + delta)
    var b = makeMotionWrite(fromX: 900, toX: 900 + delta)
    a.usesCommonRibbonOffset = true
    b.usesCommonRibbonOffset = true
    let batches = AXFrameCoordinator().processWriteBatches(
      [left: a, right: b], windowIDs: [left, right])
    #expect(batches.first?.writes.map(\.key) == (delta < 0 ? [left, right] : [right, left]))
  }

  @Test
  func horizontalRibbonOffsetIgnoresNativeVerticalClamping() {
    let id = WindowID(rawValue: 1)
    #expect(commonRibbonOffset(
      targets: [id: CGPoint(x: -300, y: 41)],
      starts: [id: CGPoint(x: 100, y: 37)],
      sizes: [id: CGSize(width: 752, height: 902)],
      monitor: Rect(x: 0, y: 0, width: 1512, height: 910)) == 400)
  }

  @Test(arguments: [(-2000.0, -751.0), (-751.0, -751.0), (-700.0, -700.0), (400.0, 400.0), (3500.0, 1511.0)])
  func logicalRibbonMotionUsesNativeAnchorsOnlyOutsideViewport(x: Double, expected: Double) {
    let logical = Rect(x: x, y: 37, width: 752, height: 902)
    let native = nativeRibbonAnimationFrame(logical,
      monitor: Rect(x: 0, y: 0, width: 1512, height: 910))
    #expect(native.x == expected)
    #expect(native.y == logical.y)
    #expect(native.width == logical.width)
    #expect(native.height == logical.height)
  }

  @Test(arguments: [-1.0, 1.0])
  func distantRibbonTraversalIncludesColumnsParkedAtBothEnds(direction: Double) {
    let monitor = Rect(x: 0, y: 0, width: 1512, height: 910)
    let start = Rect(x: direction < 0 ? 2400 : -1600, y: 37, width: 752, height: 902)
    let target = Rect(x: direction < 0 ? -1600 : 2400, y: 37, width: 752, height: 902)
    // The native reference can remain at exactly the same parking anchor,
    // so no write intent or startPositions entry exists for this column.
    let anchor = Rect(x: 1511, y: 37, width: 752, height: 902)
    #expect(ribbonAnimationStart(logical: target, offset: start.x - target.x,
      observed: anchor, monitorFrames: [monitor]) == start)
    #expect(requiresVerifiedOffscreenWrite(frame: start, monitorFrames: [monitor]))
    #expect(requiresVerifiedOffscreenWrite(frame: target, monitorFrames: [monitor]))
    #expect(ribbonAnimationTarget(logical: target, from: start,
      isParked: true, monitorFrames: [monitor]) == target)
    #expect(ribbonAnimationTarget(logical: nil, from: start,
      isParked: true, monitorFrames: [monitor]) == nil)
    #expect(ribbonAnimationTarget(logical: target, from: target,
      isParked: true, monitorFrames: [monitor]) == nil)
    #expect(ribbonAnimationTarget(logical: target, from: start,
      isParked: true, monitorFrames: [monitor, monitor]) == nil)
  }

  @Test(arguments: ["command-animation", "workspace-transition"])
  func staticRibbonParkingPrecedesNextHorizontalMovement(source: String) {
    let orphan = WindowID(rawValue: 1), moving = WindowID(rawValue: 2)
    let base = makeMotionWrite(fromX: -369, toX: -751)
    let parked = AsyncPositionWrite(
      element: base.element, application: base.application, processID: base.processID,
      fromPoint: base.fromPoint, point: base.point, fromSize: base.fromSize, size: base.size,
      positionChanged: true, sizeChanged: false, animatesSize: false,
      synchronousSizeWriteSucceeded: true, enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016, isParked: true, isReentering: false,
      requiresVerifiedOffscreenWrite: true)
    let frame = QueuedPositionFrame(
      generation: 2, source: source,
      writes: [orphan: parked, moving: makeMotionWrite(fromX: 387, toX: -369)],
      animatedWindowIDs: [moving], animationDuration: 0.125,
      refreshRateHz: 120, displayIDs: [],
      monitorFrames: [Rect(x: 0, y: 0, width: 1512, height: 910)],
      initialProgressVelocity: 0, stagesVisibleBeforeParking: false, completion: nil)
    #expect(ribbonParkingPreparationWindowIDs(frame) ==
      (source == "command-animation" ? [orphan] : []))
  }

  @Test
  func interruptedRibbonDoesNotMistakeUncommittedParkingTargetForAppliedPosition() {
    let target = Rect(x: -1505, y: 37, width: 1506, height: 902)
    let actual = CGPoint(x: -231, y: 37)
    let reference = frameApplicationReference(
      pendingCorrection: nil, settlingReference: nil, completedPosition: actual,
      previousTarget: target, prefersCompletedPosition: true, nativeReference: nil)
    #expect(reference?.x == Double(actual.x))
    #expect(frameWriteIntent(reference: reference!, target: target, positionsOnly: true).position)
    #expect(reference?.width == target.width)
  }

  @Test
  func ribbonAvoidsRepeatedVerticalWritesForNativeHeightClamping() {
    let native = Rect(x: -1505, y: 37, width: 1506, height: 902)
    let target = Rect(x: -1505, y: 41, width: 1506, height: 869)
    #expect(!frameWriteIntent(reference: native, target: target,
      positionsOnly: true, horizontalOnly: true).position)
    #expect(frameWriteIntent(reference: native, target: target,
      positionsOnly: true).position)
    let start = CGPoint(x: -231, y: native.y)
    let destination = CGPoint(x: target.x, y: target.y)
    #expect(frameWritePosition(target: destination, from: start, horizontalOnly: true)
      == CGPoint(x: target.x, y: native.y))
    #expect(frameWritePosition(target: destination, from: start, horizontalOnly: false)
      == destination)
  }

  @Test(arguments: [-300.0, 300.0])
  func interruptedReentryKeepsItsGapWithTheRebasedNeighbor(offset: Double) {
    let neighbor = WindowID(rawValue: 1), entering = WindowID(rawValue: 2)
    let coordinator = AXFrameCoordinator()
    coordinator.recordCompletedPosition(CGPoint(x: 1700 + offset, y: 40), windowID: neighbor)
    let frame = QueuedPositionFrame(
      generation: 2, source: "command-animation",
      writes: [neighbor: makeMotionWrite(fromX: 1700, toX: 832),
               entering: makeMotionWrite(fromX: 2568, toX: 1700, isReentering: true)],
      animatedWindowIDs: [neighbor, entering], animationDuration: 0.15,
      refreshRateHz: 120, displayIDs: [],
      monitorFrames: [Rect(x: 0, y: 0, width: 2560, height: 1440)],
      initialProgressVelocity: 0,
      stagesVisibleBeforeParking: false, completion: nil
    )
    let writes = coordinator.rebaseFrameToCompletedPositionsLocked(frame).frame.writes
    let first = writes[neighbor]!, second = writes[entering]!
    for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
      let x1 = first.fromPoint.x + (first.point.x - first.fromPoint.x) * progress
      let x2 = second.fromPoint.x + (second.point.x - second.fromPoint.x) * progress
      #expect(abs(x2 - x1 - 868) < 0.5)
    }
  }

  @Test
  func reentryRebaseUsesTheNearestRowAsWellAsColumn() throws {
    let sameRow = WindowID(rawValue: 1), otherRow = WindowID(rawValue: 2)
    let entering = WindowID(rawValue: 3)
    let coordinator = AXFrameCoordinator()
    coordinator.recordCompletedPosition(CGPoint(x: 200, y: 40), windowID: sameRow)
    coordinator.recordCompletedPosition(CGPoint(x: 700, y: 1_040), windowID: otherRow)
    var distantRow = makeMotionWrite(fromX: 600, toX: 900, toY: 1_040)
    distantRow.fromPoint.y = 1_040
    let frame = QueuedPositionFrame(
      generation: 2, source: "command-animation",
      writes: [sameRow: makeMotionWrite(fromX: 100, toX: 400), otherRow: distantRow,
               entering: makeMotionWrite(fromX: 700, toX: 1_000, isReentering: true)],
      animatedWindowIDs: [sameRow, otherRow, entering], animationDuration: 0.125,
      refreshRateHz: 120, displayIDs: [],
      monitorFrames: [Rect(x: 0, y: 0, width: 2_560, height: 1_440)],
      initialProgressVelocity: 0, stagesVisibleBeforeParking: false, completion: nil
    )
    let rebased = coordinator.rebaseFrameToCompletedPositionsLocked(frame).frame
    let write = try #require(rebased.writes[entering])
    #expect(write.fromPoint.x == 800)
  }

  @Test
  func `Rapid retarget does not jump on its first frame`() {
    let windowID = WindowID(rawValue: 1)
    let coordinator = AXFrameCoordinator()
    coordinator.recordCompletedPosition(CGPoint(x: 400, y: 40), windowID: windowID)
    coordinator.retargetHorizontalVelocities[windowID] = 9_000
    let frame = QueuedPositionFrame(
      generation: 2, source: "command-animation",
      writes: [windowID: makeMotionWrite(fromX: 900, toX: 1_000)],
      animatedWindowIDs: [windowID], animationDuration: 0.22,
      refreshRateHz: 120, displayIDs: [], initialProgressVelocity: 0,
      stagesVisibleBeforeParking: false, completion: nil
    )

    let rebased = coordinator.rebaseFrameToCompletedPositionsLocked(frame)
    let samples = completedFrameSpringSamples(
      duration: 0.22, refreshRateHz: 120,
      initialVelocity: rebased.frame.initialProgressVelocity
    )
    #expect(rebased.frame.initialProgressVelocity <= 1 / 0.22)
    #expect((samples.first?.progress ?? 1) <= 0.05)
  }

  private func makeMotionWrite(
    fromX: Double, toX: Double, sizeChanged: Bool = false, processID: pid_t = 42,
    animatesSize: Bool = false,
    isReentering: Bool = false, isParked: Bool = false, toY: Double = 40
  ) -> AsyncPositionWrite {
    // Handles only: these tests never read or mutate the real desktop.
    let element = AXUIElementCreateSystemWide()
    return AsyncPositionWrite(
      element: element, application: element, processID: processID,
      fromPoint: CGPoint(x: fromX, y: 40), point: CGPoint(x: toX, y: toY),
      fromSize: CGSize(width: 800, height: 700), size: CGSize(width: 900, height: 700),
      positionChanged: true, sizeChanged: sizeChanged, animatesSize: animatesSize,
      synchronousSizeWriteSucceeded: !sizeChanged, enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016, isParked: isParked, isReentering: isReentering,
      requiresVerifiedOffscreenWrite: false
    )
  }

  private let expectation = FrameCommitExpectation(
    from: Rect(x: 900, y: 40, width: 800, height: 700),
    target: Rect(x: 100, y: 40, width: 800, height: 700),
    issuedAt: 10,
    deadline: 10.65,
    observedAt: nil
  )

  @Test
  func `Animation lane keeps only its latest pending sample`() {
    var lane = LatestAnimationSampleState<Int>()

    #expect(lane.submit(1).startsDrain)
    #expect(lane.submit(2).startsDrain == false)
    let latest = lane.submit(3)
    #expect(latest.startsDrain == false)
    #expect(latest.displaced == 2)
    #expect(lane.takeNext() == 3)
    #expect(lane.takeNext() == nil)
    #expect(lane.isRunning == false)
  }

  @Test
  func `Busy animation lane holds the whole ribbon until it recovers`() {
    let coordinator = AXFrameCoordinator()
    coordinator.latestGeneration = 2 // No native writes from these stale samples.
    let frame = QueuedPositionFrame(
      generation: 1, source: "readiness-test", writes: [:],
      animatedWindowIDs: [], animationDuration: 0.2, refreshRateHz: 120,
      displayIDs: [], initialProgressVelocity: 0, stagesVisibleBeforeParking: false, completion: nil
    )
    let queues: [pid_t: DispatchQueue] = [
      42: coordinator.processWriteQueue(for: 42),
      43: coordinator.processWriteQueue(for: 43),
    ]
    let queue42 = queues[42]!
    let queue43 = queues[43]!
    let accumulator = FrameResultAccumulator()
    func sample(_ pid: pid_t, _ progress: Double, intermediate: Bool = true) -> ProcessAnimationSample {
      ProcessAnimationSample(
        frame: frame, batch: ProcessWriteBatch(processID: pid, writes: []),
        progress: progress, progressVelocity: 0, intermediate: intermediate,
        stagingReentry: false, recordFinalSuccess: !intermediate,
        accumulator: accumulator, completion: nil
      )
    }
    queue42.suspend()
    queue43.suspend()
    _ = coordinator.submitAnimationSamples([sample(42, 0.1)])
    _ = coordinator.submitAnimationSamples([sample(42, 0.2), sample(43, 0.2)])
    coordinator.animationLaneLock.lock()
    var busyLane = coordinator.processAnimationLanes[42]
    let heldProgress = busyLane?.takeNext()?.progress
    let idleSiblingWasQueued = coordinator.processAnimationLanes[43] != nil
    coordinator.animationLaneLock.unlock()
    #expect(heldProgress == 0.1)
    #expect(!idleSiblingWasQueued)
    #expect(!coordinator.animationLanesAreReady(processIDs: [42, 43]))
    // Final samples must bypass readiness and replace obsolete intermediate work.
    _ = coordinator.submitAnimationSamples([sample(42, 1, intermediate: false)])
    coordinator.animationLaneLock.lock()
    var finalLane = coordinator.processAnimationLanes[42]
    let finalProgress = finalLane?.takeNext()?.progress
    coordinator.animationLaneLock.unlock()
    #expect(finalProgress == 1)
    queue42.resume()
    queue43.resume()
    coordinator.animationLaneWriteGroup.wait()
    #expect(coordinator.animationLanesAreReady(processIDs: [42, 43]))
    queue42.suspend()
    queue43.suspend()
    _ = coordinator.submitAnimationSamples([sample(42, 0.3), sample(43, 0.3)])
    coordinator.animationLaneLock.lock()
    let recovered = [42, 43].allSatisfy { coordinator.processAnimationLanes[pid_t($0)]?.isRunning == true }
    coordinator.animationLaneLock.unlock()
    #expect(recovered)
    queue42.resume()
    queue43.resume()
    coordinator.animationLaneWriteGroup.wait()
  }

  @Test
  func `Submission preserves animation intent across transient latency`() {
    let coordinator = AXFrameCoordinator()
    coordinator.running = true // Inspect submission without starting native writes.
    let fast = WindowID(rawValue: 1)
    let slow = WindowID(rawValue: 2)
    let writes = [
      fast: makeMotionWrite(fromX: 900, toX: 100, processID: 42),
      slow: makeMotionWrite(fromX: 1800, toX: 1000, processID: 43)
    ]
    coordinator.recordProcessLatencySamples([42: 2, 43: 30], intermediate: true)
    coordinator.submit(
      writes, source: "test-scroll", animationDuration: 0.035,
      refreshRateHz: 120, animatedWindowIDs: [fast, slow]
    )
    #expect(coordinator.pending?.animationDuration == 0.035)
    #expect(coordinator.pending?.writes.count == 2)

    for _ in 0..<16 { coordinator.recordProcessLatencySamples([43: 2], intermediate: true) }
    coordinator.submit(
      writes, source: "test-scroll", animationDuration: 0.035,
      refreshRateHz: 120, animatedWindowIDs: [fast, slow]
    )
    #expect(coordinator.pending?.animationDuration == 0.035)
  }

  @Test
  func `Horizontal ribbon retains common motion after a recent AX stall`() {
    let coordinator = AXFrameCoordinator()
    coordinator.running = true
    let first = WindowID(rawValue: 1), second = WindowID(rawValue: 2)
    coordinator.recordProcessLatencySamples([42: 120])
    coordinator.predictedProcessLatencyMS[43] = 2
    let writes = [
      first: makeMotionWrite(fromX: 900, toX: 100, processID: 42),
      second: makeMotionWrite(fromX: 1800, toX: 1000, processID: 43),
    ]
    coordinator.submit(writes, source: "command-animation", animationDuration: 0.125,
      refreshRateHz: 120, animatedWindowIDs: [first, second])
    let duration = coordinator.pending?.animationDuration ?? 0
    #expect(duration == 0.125)

    coordinator.recentIntermediateProcessLatencySamplesMS = [:]
    coordinator.predictedProcessLatencyMS = [42: 2, 43: 2]
    coordinator.submit(writes, source: "command-animation", animationDuration: 0.125,
      refreshRateHz: 120, animatedWindowIDs: [first, second])
    #expect(coordinator.pending?.animationDuration == 0.125)
  }

  @Test
  func managedWidthAnimationRetainsIntermediateFramesAfterAnAXStall() {
    let coordinator = AXFrameCoordinator()
    coordinator.running = true
    let selected = WindowID(rawValue: 1), neighbor = WindowID(rawValue: 2)
    coordinator.recordProcessLatencySamples([42: 70, 43: 2])
    let resizing = makeMotionWrite(fromX: 500, toX: 0, sizeChanged: true, animatesSize: true)
    let writes = [selected: resizing,
      neighbor: makeMotionWrite(fromX: 1300, toX: 900, processID: 43)]
    coordinator.submit(writes, source: "command-layout-animation", animationDuration: 0.125,
      refreshRateHz: 120, monitorFrames: [Rect(x: 0, y: 0, width: 1512, height: 982)],
      animatedWindowIDs: [selected, neighbor])
    #expect(coordinator.pending?.animationDuration == 0.125)
    let duration = coordinator.horizontalAnimationDuration(
      for: writes, requested: 0.125, refreshRateHz: 120, allowsSizeChanges: true)
    #expect(duration >= 0.21 && duration <= 0.4)
    #expect(coordinator.animationSupportsIntermediateFrames(
      processIDs: [42, 43], animationDuration: duration, refreshRateHz: 120))
    #expect(coordinator.pending?.writes[selected]?.animatesSize == true)
    coordinator.predictedProcessLatencyMS = [42: 2, 43: 2]
    coordinator.recentIntermediateProcessLatencySamplesMS = [:]
    coordinator.submit(writes, source: "command-layout-animation", animationDuration: 0.125,
      refreshRateHz: 120, monitorFrames: [Rect(x: 0, y: 0, width: 1512, height: 982),
        Rect(x: 1512, y: 0, width: 1512, height: 982)],
      animatedWindowIDs: [selected, neighbor])
    #expect(coordinator.pending?.animationDuration == 0.125,
      "Cross-display layout defers its safety decision until worker admission")
  }

  @Test
  func `Leaving ribbon window follows strip motion before final parking`() {
    var leaving = makeMotionWrite(fromX: 100, toX: -759)
    leaving.animationPoint = CGPoint(x: -900, y: leaving.point.y)
    let middle = frameAnimationDestination(leaving, intermediate: true)
    let parked = frameAnimationDestination(leaving, intermediate: false)
    #expect(middle.x == -900)
    #expect(parked.x == -759)
    let neighbor = makeMotionWrite(fromX: 900, toX: -100)
    let leavingFrame = interpolatedFrame(
      from: Rect(x: 100, y: 0, width: 760, height: 700),
      to: Rect(x: middle.x, y: 0, width: 760, height: 700), progress: 0.5)
    let neighborFrame = interpolatedFrame(
      from: Rect(x: 900, y: 0, width: 760, height: 700),
      to: Rect(x: frameAnimationDestination(neighbor, intermediate: true).x,
        y: 0, width: 760, height: 700), progress: 0.5)
    #expect(neighborFrame.x - leavingFrame.x == 800)
    #expect(positionOnlyAnimationWrite(leaving, holding: leaving.size).animationPoint == middle)
  }

  @Test
  func `Recent AX stalls prevent animation from restarting after a few fast writes`() {
    let coordinator = AXFrameCoordinator()
    coordinator.recordProcessLatencySamples([42: 55], intermediate: true)
    for _ in 0..<6 { coordinator.recordProcessLatencySamples([42: 2], intermediate: true) }
    #expect(coordinator.animationSupportsIntermediateFrames(
      processIDs: [42], animationDuration: 0.035, refreshRateHz: 120
    ) == false)
    for _ in 0..<16 { coordinator.recordProcessLatencySamples([42: 2], intermediate: true) }
    #expect(coordinator.animationSupportsIntermediateFrames(
      processIDs: [42], animationDuration: 0.035, refreshRateHz: 120
    ))
  }

  @Test
  func horizontalReadPriorityExcludesVerticalResizeAndDisabledMotion() {
    let coordinator = AXFrameCoordinator()
    let id = WindowID(rawValue: 1)
    let horizontal = makeMotionWrite(fromX: 0, toX: 100)
    coordinator.activeAnimatedWindowIDs = [id]
    coordinator.activeWrites = [id: horizontal]
    #expect(!coordinator.hasPendingHorizontalMotion)
    coordinator.activeAnimationRunning = true
    #expect(coordinator.hasPendingHorizontalMotion)
    var vertical = horizontal
    vertical.fromPoint.y -= 100
    coordinator.activeWrites = [id: vertical]
    #expect(!coordinator.hasPendingHorizontalMotion)
    coordinator.activeWrites = [id: makeMotionWrite(fromX: 0, toX: 100, sizeChanged: true)]
    #expect(!coordinator.hasPendingHorizontalMotion)
    coordinator.activeAnimationRunning = false
    coordinator.activeWrites = [:]
    coordinator.running = true
    coordinator.submit([id: horizontal], source: "command-animation", animationDuration: 0.125,
                       refreshRateHz: 120, animatedWindowIDs: [id])
    #expect(coordinator.hasPendingHorizontalMotion)
  }

  @Test
  func mixedPendingFrameKeepsHorizontalDiscoveryPriority() {
    let coordinator = AXFrameCoordinator()
    let horizontal = WindowID(rawValue: 1), vertical = WindowID(rawValue: 2)
    coordinator.activeAnimationRunning = true
    coordinator.activeAnimatedWindowIDs = [horizontal]
    coordinator.activeWrites = [horizontal: makeMotionWrite(fromX: 0, toX: 100)]
    coordinator.running = true
    coordinator.submit([vertical: makeMotionWrite(fromX: 0, toX: 0, toY: 200)],
                       source: "workspace-animation", animationDuration: 0.18,
                       refreshRateHz: 120, animatedWindowIDs: [vertical])
    #expect(coordinator.hasPendingHorizontalMotion)
  }

  @Test
  func finalFallbackStagesOnlyEnteringWindows() {
    let stagedIDs = Mutex(Set<WindowID>())
    let ordinaryIDs = Mutex(Set<WindowID>())
    let coordinator = AXFrameCoordinator(batchWriter: { batch, _, _, _, staging, _ in
      let ids = Set(batch.writes.map(\.key))
      if staging { stagedIDs.withLock { $0.formUnion(ids) } }
      else { ordinaryIDs.withLock { $0.formUnion(ids) } }
      return (batch.writes.count, 0, [], true)
    })
    let entering = WindowID(rawValue: 1), offscreen = WindowID(rawValue: 2)
    coordinator.latestGeneration = 1
    let frame = QueuedPositionFrame(
      generation: 1, source: "command-animation",
      writes: [entering: makeMotionWrite(fromX: 1_000, toX: 100, isReentering: true),
               offscreen: makeMotionWrite(fromX: -1_000, toX: -1_200)],
      animatedWindowIDs: [entering], animationDuration: 0.125, refreshRateHz: 120,
      displayIDs: [], initialProgressVelocity: 0, stagesVisibleBeforeParking: false,
      completion: nil
    )
    _ = coordinator.applyFrame(frame, progress: 1, skippedProcesses: [], stagingReentry: true)
    #expect(stagedIDs.withLock { $0 } == [entering])
    #expect(ordinaryIDs.withLock { $0 } == [offscreen])
  }

  @Test(arguments: ["motion", "failed", "parked", "reentry"])
  func onlySuccessfulOrdinaryPositionBatchesSeedColdMotion(kind: String) {
    let writer = AXFrameAccessibilityWriter(
      positionWriter: { _, _ in kind != "failed" },
      positionReader: { _ in CGPoint(x: 100, y: 40) }
    )
    let coordinator = AXFrameCoordinator(accessibilityWriter: writer)
    coordinator.latestGeneration = 1
    let id = WindowID(rawValue: 1)
    let write = makeMotionWrite(
      fromX: 0, toX: 100, processID: -1,
      isReentering: kind == "reentry", isParked: kind == "parked"
    )
    let frame = QueuedPositionFrame(
      generation: 1, source: "command", writes: [id: write],
      animatedWindowIDs: [], animationDuration: 0, refreshRateHz: 120,
      displayIDs: [], initialProgressVelocity: 0, stagesVisibleBeforeParking: false,
      completion: nil
    )
    _ = coordinator.applyBatch(
      ProcessWriteBatch(processID: -1, writes: [(id, write)]), frame: frame,
      progress: 1, intermediate: false, stagingReentry: false, recordFinalSuccess: false
    )
    #expect((coordinator.recentIntermediateProcessLatencySamplesMS[-1] != nil) == (kind == "motion"))
  }

  @Test
  func expiredMotionCostCanBeReseededByASuccessfulFinalWrite() {
    let coordinator = AXFrameCoordinator()
    coordinator.recordInitialMotionLatency(processID: 42, latencyMS: 2, sampledAt: 10)
    coordinator.recordInitialMotionLatency(processID: 42, latencyMS: 40, sampledAt: 12)
    #expect(coordinator.intermediateFrameLimits(
      for: [42], availableFrames: 23, refreshRateHz: 120, sampledAt: 12, motionOnly: true
    )[42] == 3)
  }

  @Test(arguments: [60.0, 120.0])
  func delayedDisplayExecutionDoesNotBurstOnTheNextPulse(refreshRate: Double) {
    let interval = 1 / refreshRate
    var state = FrameAnimationPulseState()
    let first = state.enqueue(now: 10, displayTimestamp: 10,
                              interval: interval, refreshInterval: interval)
    #expect(first)
    state.finishTick(at: 10, executedAt: 10 + 4 * interval, advanced: true)
    let immediate = state.enqueue(now: 10 + 4.1 * interval, displayTimestamp: 10 + 4 * interval,
                                  interval: interval, refreshInterval: interval)
    #expect(immediate == false)
    let next = state.enqueue(now: 10 + 5 * interval, displayTimestamp: 10 + 5 * interval,
                             interval: interval, refreshInterval: interval)
    #expect(next)
  }

  @Test
  func firstMotionUsesComparableSuccessfulPositionCostWithoutReplacingMeasuredMotion() {
    let coordinator = AXFrameCoordinator()
    coordinator.recordInitialMotionLatency(processID: 42, latencyMS: 40, sampledAt: 10)
    #expect(coordinator.intermediateFrameLimits(
      for: [42], availableFrames: 23, refreshRateHz: 120, sampledAt: 10, motionOnly: true
    )[42] == 3)
    coordinator.recordProcessLatencySamples([42: 2], intermediate: true, sampledAt: 10.3)
    coordinator.recordInitialMotionLatency(processID: 42, latencyMS: 100, sampledAt: 10.3)
    #expect(coordinator.intermediateFrameLimits(
      for: [42], availableFrames: 23, refreshRateHz: 120, sampledAt: 10.3, motionOnly: true
    )[42] == 23)
    #expect(coordinator.predictedProcessLatencyMS[42] == 2)
  }

  @Test
  func isolatedMotionStallRetiresOnlyAfterConfirmedRecovery() {
    let coordinator = AXFrameCoordinator()
    coordinator.recordProcessLatencySamples([42: 55], intermediate: true, sampledAt: 10)
    for _ in 0..<6 {
      coordinator.recordProcessLatencySamples([42: 2], intermediate: true, sampledAt: 10)
    }
    #expect(coordinator.intermediateFrameLimits(
      for: [42], availableFrames: 18, refreshRateHz: 120, sampledAt: 10, motionOnly: true
    )[42]! < 18)
    for _ in 0..<2 {
      coordinator.recordProcessLatencySamples([42: 2], intermediate: true, sampledAt: 10)
    }
    #expect(coordinator.intermediateFrameLimits(
      for: [42], availableFrames: 18, refreshRateHz: 120, sampledAt: 10, motionOnly: true
    )[42] == 18)
    coordinator.recordProcessLatencySamples([42: 55], intermediate: true, sampledAt: 10)
    #expect(coordinator.intermediateFrameLimits(
      for: [42], availableFrames: 18, refreshRateHz: 120, sampledAt: 10, motionOnly: true
    )[42]! < 18)
  }

  @Test
  func animationRecoversAfterExpiredIntermediateStall() {
    let coordinator = AXFrameCoordinator()
    coordinator.recordProcessLatencySamples(
      [42: 55], intermediate: true,
      sampledAt: ProcessInfo.processInfo.systemUptime - 1
    )
    // A disabled lane produces only final writes; it must recover without
    // requiring an intermediate sample that it can no longer produce.
    for _ in 0..<16 { coordinator.recordProcessLatencySamples([42: 2]) }
    #expect(coordinator.animationSupportsIntermediateFrames(
      processIDs: [42], animationDuration: 0.035, refreshRateHz: 120
    ))
  }

  @Test
  func verticalAdmissionKeepsGeneralLatencyAfterMotionHistoryExpires() {
    let coordinator = AXFrameCoordinator()
    coordinator.recordProcessLatencySamples([42: 2], intermediate: true, sampledAt: 10)
    coordinator.predictedProcessLatencyMS[42] = 100
    #expect(coordinator.intermediateFrameLimits(
      for: [42], availableFrames: 18, refreshRateHz: 120, sampledAt: 11
    )[42] == 0)
    #expect(coordinator.intermediateFrameLimits(
      for: [42], availableFrames: 18, refreshRateHz: 120,
      sampledAt: 11, motionOnly: true
    )[42] == 18)
  }

  @Test(arguments: [0.2, 0.28, 0.5, 0.9, 1.1])
  func horizontalCadenceRetainsMeasuredCostBetweenNavigationCommands(pause: TimeInterval) {
    let coordinator = AXFrameCoordinator()
    coordinator.recordProcessLatencySamples([42: 40], intermediate: true, sampledAt: 10)
    let limit = coordinator.intermediateFrameLimits(
      for: [42], availableFrames: 23, refreshRateHz: 120,
      sampledAt: 10 + pause, motionOnly: true
    )[42]
    #expect(limit == (pause < 1 ? 3 : 23))
    // A real fast movement can retire the old stall; parking cannot.
    coordinator.recordProcessLatencySamples([42: 2], intermediate: true, sampledAt: 10 + pause)
    let recovered = coordinator.intermediateFrameLimits(
      for: [42], availableFrames: 23, refreshRateHz: 120,
      sampledAt: 10 + pause, motionOnly: true
    )[42]
    #expect(recovered == (pause <= 0.25 ? 3 : 23))
  }

  @Test(arguments: [0.2, 0.3])
  func severeMotionStallStillRecoversWithoutAnIntermediateWrite(pause: TimeInterval) {
    let coordinator = AXFrameCoordinator()
    coordinator.recordProcessLatencySamples([42: 120], intermediate: true, sampledAt: 10)
    let limit = coordinator.intermediateFrameLimits(
      for: [42], availableFrames: 23, refreshRateHz: 120,
      sampledAt: 10 + pause, motionOnly: true
    )[42]
    #expect(limit == (pause <= 0.25 ? 0 : 23))
  }

  @Test
  func `Slow final verification does not throttle measured fast animation writes`() {
    let coordinator = AXFrameCoordinator()
    for _ in 0..<16 {
      coordinator.recordProcessLatencySamples([42: 2], intermediate: true)
    }
    coordinator.recordProcessLatencySamples([42: 40])
    #expect(coordinator.intermediateFrameLimits(
      for: [42], availableFrames: 23, refreshRateHz: 120
    )[42] == 23)
    coordinator.recordProcessLatencySamples([42: 40], intermediate: true)
    #expect(coordinator.intermediateFrameLimits(
      for: [42], availableFrames: 23, refreshRateHz: 120
    )[42] == 3)
  }

  @Test
  func `Sparse fast samples recover cadence after a transient stall`() {
    let coordinator = AXFrameCoordinator()
    coordinator.recordProcessLatencySamples([42: 40], intermediate: true, sampledAt: 10)
    coordinator.recordProcessLatencySamples([42: 2], intermediate: true, sampledAt: 10.1)
    #expect(coordinator.intermediateFrameLimits(
      for: [42], availableFrames: 23, refreshRateHz: 120, sampledAt: 10.1
    )[42] == 3)
    coordinator.recordProcessLatencySamples([42: 2], intermediate: true, sampledAt: 10.3)
    #expect(coordinator.intermediateFrameLimits(
      for: [42], availableFrames: 23, refreshRateHz: 120, sampledAt: 10.3
    )[42] == 23)
    coordinator.recordProcessLatencySamples([42: 40], intermediate: true, sampledAt: 10.31)
    #expect(coordinator.intermediateFrameLimits(
      for: [42], availableFrames: 23, refreshRateHz: 120, sampledAt: 10.31
    )[42] == 3)
  }

  @Test
  func `Workspace animation accepts an adaptively sampled AX lane`() {
    let coordinator = AXFrameCoordinator()
    coordinator.predictedProcessLatencyMS[42] = 12
    coordinator.predictedProcessLatencyMS[43] = 90

    let limits = coordinator.intermediateFrameLimits(
      for: [42, 43], availableFrames: 22, refreshRateHz: 120
    )
    #expect(limits[42] == 14)
    #expect(limits[43] == 1)

    #expect(
      coordinator.animationSupportsIntermediateFrames(
        processIDs: [42],
        animationDuration: 0.18,
        refreshRateHz: 120
      ))
    #expect(
      coordinator.animationSupportsIntermediateFrames(
        processIDs: [43],
        animationDuration: 0.18,
        refreshRateHz: 120
      ) == false)
  }

  @Test
  func `Vertical reentry ignores cross-axis drift and leaving windows`() {
    let candidateStart = CGPoint(x: 8, y: 20)
    let candidateTarget = Rect(x: 10, y: -880, width: 800, height: 700)

    #expect(
      reentryTransitionDelta(
        reentryStart: CGPoint(x: 1_600, y: 20),
        reentryTarget: Rect(x: 10, y: 20, width: 800, height: 700),
        candidateStart: candidateStart,
        candidateTarget: candidateTarget
      ) == CGPoint(x: 0, y: -900))
    #expect(
      reentryTransitionDelta(
        reentryStart: candidateStart,
        reentryTarget: candidateTarget,
        candidateStart: candidateStart,
        candidateTarget: candidateTarget
      ) == nil)
  }

  @Test
  func `Reverse retarget uses last completed position during observation lag`() {
    let staleObserved = Rect(x: 900, y: 40, width: 800, height: 700)
    let completed = CGPoint(x: 100, y: 40)

    #expect(
      frameApplicationReference(
        pendingCorrection: nil,
        settlingReference: staleObserved,
        completedPosition: completed,
        previousTarget: Rect(x: 100, y: 40, width: 800, height: 700),
        nativeReference: nil
      ) == Rect(x: 100, y: 40, width: 800, height: 700))
  }

  @Test
  func `Interrupted ribbon keeps moving windows whose target is unchanged`() {
    let target = Rect(x: 1_000, y: 40, width: 800, height: 700)
    let completed = CGPoint(x: 400, y: 40)
    let reference = frameApplicationReference(
      pendingCorrection: nil,
      settlingReference: nil,
      completedPosition: completed,
      previousTarget: target,
      pendingAnimation: true,
      nativeReference: nil
    )
    #expect(reference?.x == 400)
    #expect(reference.map {
      frameWriteIntent(reference: $0, target: target, positionsOnly: true).position
    } == true)
    #expect(frameApplicationReference(
      pendingCorrection: nil,
      settlingReference: nil,
      completedPosition: completed,
      previousTarget: target,
      nativeReference: nil
    ) == target)
  }

  @Test
  func `Frame application reference does not read native frame when cached`() {
    var nativeFrameWasRead = false

    _ = frameApplicationReference(
      pendingCorrection: Rect(x: 100, y: 40, width: 800, height: 700),
      settlingReference: nil,
      completedPosition: nil,
      previousTarget: nil,
      nativeReference: {
        nativeFrameWasRead = true
        return Rect(x: 900, y: 40, width: 800, height: 700)
      }()
    )

    #expect(nativeFrameWasRead == false)
  }

  @Test
  func `Deferred frame correction survives snapshot rebuild`() {
    let windowID = WindowID(rawValue: 42)
    let deferred = Rect(x: 900, y: 40, width: 800, height: 700)
    let fresh = Rect(x: 100, y: 40, width: 800, height: 700)

    #expect(
      frameCorrectionsPreservingDebt(
        existing: [windowID: deferred],
        observed: [:],
        debtWindowIDs: [windowID]
      )[windowID] == deferred)
    #expect(
      frameCorrectionsPreservingDebt(
        existing: [windowID: deferred],
        observed: [windowID: fresh],
        debtWindowIDs: [windowID]
      )[windowID] == fresh)
  }

  @Test
  func `Deferred parking keeps coordinator busy until invalidated`() {
    let coordinator = AXFrameCoordinator()
    coordinator.deferredParkingWriteGenerations[WindowID(rawValue: 42)] = 3

    #expect(coordinator.isBusy)
    #expect(coordinator.hasPendingDeferredParkingWrites)
    #expect(coordinator.isBusy(for: WindowID(rawValue: 42)))
    #expect(coordinator.isBusy(for: WindowID(rawValue: 43)) == false)

    coordinator.invalidate(reason: "mouse-gesture")

    #expect(coordinator.isBusy == false)
    #expect(coordinator.hasPendingDeferredParkingWrites == false)
  }

  @Test
  func `Static settlement samples can exit the slow lane`() {
    let coordinator = AXFrameCoordinator()
    coordinator.predictedProcessLatencyMS[42] = 12
    coordinator.latencySensitiveProcessIDs.insert(42)

    coordinator.recordProcessLatencySamples([42: 0])

    #expect(coordinator.latencySensitiveProcessIDs.contains(42) == false)
  }

  @Test
  func `Exited processes are removed from slow lane diagnostics`() {
    let coordinator = AXFrameCoordinator()
    coordinator.predictedProcessLatencyMS = [42: 20, 43: 18]
    coordinator.latencySensitiveProcessIDs = [42, 43]
    _ = coordinator.processWriteQueue(for: 42)
    _ = coordinator.processWriteQueue(for: 43)

    coordinator.pruneProcessLatencyState(liveProcessIDs: [43])

    #expect(coordinator.slowProcessLatenciesMS == [43: 18])
    #expect(Set(coordinator.processWriteQueues.keys) == [43])
  }

  @Test
  func `Stale batch does not record latency sample`() {
    let accumulator = FrameResultAccumulator()
    accumulator.add(
      applied: 0,
      stale: 1,
      slowProcesses: [],
      processID: 42,
      processLatencyMS: 0.1,
      attempted: false,
      completedAt: 1
    )

    #expect(accumulator.result.processLatencySamplesMS.isEmpty)
  }

  @Test
  func `Cursor warp requires successful target frame write`() {
    let target = WindowID(rawValue: 2)
    let sibling = WindowID(rawValue: 3)
    let failed = FrameWriteCompletion(
      completedLatest: true,
      attemptedWindowIDs: [target, sibling],
      successfulWindowIDs: [sibling]
    )
    let succeeded = FrameWriteCompletion(
      completedLatest: true,
      attemptedWindowIDs: [target, sibling],
      successfulWindowIDs: [target, sibling]
    )

    #expect(
      cursorWarpTimestampAfterFrameCompletion(
        requestedTimestamp: 10,
        targetWindowID: target,
        completion: failed
      ) == nil)
    #expect(
      cursorWarpTimestampAfterFrameCompletion(
        requestedTimestamp: 10,
        targetWindowID: target,
        completion: succeeded
      ) == 10)
  }

  @Test
  func `Cursor warp allows observed convergence after failed write`() {
    let target = Rect(x: 100, y: 40, width: 800, height: 700)

    #expect(
      cursorWarpFrameReadiness(
        latestWriteSucceeded: false,
        observedFrame: Rect(x: 900, y: 40, width: 800, height: 700),
        targetFrame: target
      ) == false)
    #expect(
      cursorWarpFrameReadiness(
        latestWriteSucceeded: false,
        observedFrame: target,
        targetFrame: target
      ))
  }

  @Test
  func `Synchronous size failure blocks warp readiness`() {
    #expect(
      frameSizeWriteSucceeded(
        sizeChanged: true,
        synchronousWriteSucceeded: false,
        animatesSize: false,
        asynchronousWriteSucceeded: false
      ) == false)
    #expect(
      frameSizeWriteSucceeded(
        sizeChanged: true,
        synchronousWriteSucceeded: true,
        animatesSize: false,
        asynchronousWriteSucceeded: false
      ))
    #expect(
      frameSizeWriteSucceeded(
        sizeChanged: true,
        synchronousWriteSucceeded: true,
        animatesSize: true,
        asynchronousWriteSucceeded: false
      ) == false)
    #expect(
      frameSizeWriteSucceeded(
        sizeChanged: true,
        synchronousWriteSucceeded: false,
        animatesSize: false,
        asynchronousWriteSucceeded: true
      ))
    #expect(
      frameSizeWriteSucceeded(
        sizeChanged: false,
        synchronousWriteSucceeded: false,
        animatesSize: false,
        asynchronousWriteSucceeded: false
      ))
  }

  @Test
  func `Asynchronous layout routes non animated size writes to coordinator`() {
    #expect(
      asynchronousSizeWriteIsRequired(
        sizeChanged: true,
        synchronousWriteSucceeded: false,
        animatesSize: false
      ))
    #expect(
      asynchronousSizeWriteIsRequired(
        sizeChanged: true,
        synchronousWriteSucceeded: true,
        animatesSize: false
      ) == false)
  }

  @Test
  func `Deferred frame focus rejects newer input before submission`() {
    #expect(
      deferredFocusInputIsCurrent(
        requestedTimestamp: 10,
        latestUserInputTimestamp: 10
      ))
    #expect(
      deferredFocusInputIsCurrent(
        requestedTimestamp: 10,
        latestUserInputTimestamp: 11
      ) == false)
    #expect(
      deferredFocusInputIsCurrent(
        requestedTimestamp: nil,
        latestUserInputTimestamp: 11
      ))
  }

  @Test
  func `Deferred frame focus waits for pending frame debt`() {
    let target = WindowID(rawValue: 42)

    #expect(
      deferredFocusFrameIsReady(
        targetWindowID: target,
        pendingFrameWindowIDs: [target]
      ) == false)
    #expect(
      deferredFocusFrameIsReady(
        targetWindowID: target,
        pendingFrameWindowIDs: []
      ))
  }

  @Test
  func `Deferred frame focus requires target write or observed convergence`() {
    let target = WindowID(rawValue: 42)
    let frame = Rect(x: 10, y: 20, width: 300, height: 400)

    #expect(
      deferredFocusFrameCommitIsReady(
        targetWindowID: target,
        pendingFrameWindowIDs: [],
        successfulWindowIDs: [],
        observedFrame: nil,
        targetFrame: frame
      ) == false)
    #expect(
      deferredFocusFrameCommitIsReady(
        targetWindowID: target,
        pendingFrameWindowIDs: [],
        successfulWindowIDs: [target],
        observedFrame: nil,
        targetFrame: frame
      ))
    #expect(
      deferredFocusFrameCommitIsReady(
        targetWindowID: target,
        pendingFrameWindowIDs: [],
        successfulWindowIDs: [],
        observedFrame: frame,
        targetFrame: frame
      ))
    #expect(
      deferredFocusFrameCommitIsReady(
        targetWindowID: target,
        pendingFrameWindowIDs: [target],
        successfulWindowIDs: [target],
        observedFrame: frame,
        targetFrame: frame
      ) == false)
  }

  @Test
  func `Displaced queued frame completes as superseded`() async {
    await confirmation { confirm in
      let frame = QueuedPositionFrame(
        generation: 1,
        source: "test",
        writes: [:],
        animatedWindowIDs: [],
        animationDuration: 0,
        refreshRateHz: 60,
        displayIDs: [],
        initialProgressVelocity: 0,
        stagesVisibleBeforeParking: false
      ) { result in
        #expect(result.completedLatest == false)
        #expect(result.successfulWindowIDs.isEmpty)
        confirm()
      }

      completeSupersededFrame(frame)
    }
  }

  @Test
  func `Successful write reports the window that was written`() {
    let coordinator = AXFrameCoordinator()
    let firstWindowID = WindowID(rawValue: 42)
    let secondWindowID = WindowID(rawValue: 43)
    let reportedWindowIDs = Mutex<[WindowID]>([])
    let frame = QueuedPositionFrame(
      generation: 1,
      source: "test",
      writes: [:],
      animatedWindowIDs: [],
      animationDuration: 0,
      refreshRateHz: 60,
      displayIDs: [],
      initialProgressVelocity: 0,
      stagesVisibleBeforeParking: false,
      successfulWrite: { windowID, _ in
        reportedWindowIDs.withLock { $0.append(windowID) }
      },
      completion: nil
    )

    coordinator.reportSuccessfulWrite(
      for: frame,
      windowID: firstWindowID,
      at: 10
    )
    coordinator.reportSuccessfulWrite(
      for: frame,
      windowID: firstWindowID,
      at: 11
    )
    coordinator.reportSuccessfulWrite(
      for: frame,
      windowID: secondWindowID,
      at: 12
    )

    #expect(reportedWindowIDs.withLock { $0 } == [firstWindowID, secondWindowID])
  }

  @Test
  func `Replacement frame preserves superseded async size write`() {
    let element = AXUIElementCreateSystemWide()
    func write(
      size: CGSize,
      point: CGPoint = .zero,
      positionChanged: Bool = false,
      sizeChanged: Bool = true,
      synchronousSizeWriteSucceeded: Bool = false
    )
      -> AsyncPositionWrite
    {
      AsyncPositionWrite(
        element: element,
        application: element,
        processID: 42,
        fromPoint: .zero,
        point: point,
        fromSize: CGSize(width: 800, height: 600),
        size: size,
        positionChanged: positionChanged,
        sizeChanged: sizeChanged,
        animatesSize: false,
        synchronousSizeWriteSucceeded: synchronousSizeWriteSucceeded,
        enhancedUIWasEnabled: false,
        timeoutSeconds: 0.016,
        isParked: false,
        isReentering: false,
        requiresVerifiedOffscreenWrite: false
      )
    }
    let carriedWindowID = WindowID(rawValue: 1)
    let replacementWindowID = WindowID(rawValue: 2)
    let result = frameWritesPreservingSupersededAsyncSizes(
      active: [carriedWindowID: write(size: CGSize(width: 900, height: 700))],
      pending: [:],
      replacement: [
        replacementWindowID: write(size: CGSize(width: 1_000, height: 700))
      ]
    )

    #expect(result[carriedWindowID]?.size.width == 900)
    #expect(result[replacementWindowID]?.size.width == 1_000)
  }

  @Test
  func `Position only replacement retargets async size debt to latest plan`() {
    let element = AXUIElementCreateSystemWide()
    func write(
      point: CGPoint,
      size: CGSize,
      positionChanged: Bool,
      sizeChanged: Bool
    ) -> AsyncPositionWrite {
      AsyncPositionWrite(
        element: element,
        application: element,
        processID: 42,
        fromPoint: .zero,
        point: point,
        fromSize: CGSize(width: 800, height: 600),
        size: size,
        positionChanged: positionChanged,
        sizeChanged: sizeChanged,
        animatesSize: false,
        synchronousSizeWriteSucceeded: !sizeChanged,
        enhancedUIWasEnabled: false,
        timeoutSeconds: 0.016,
        isParked: false,
        isReentering: false,
        requiresVerifiedOffscreenWrite: false
      )
    }
    let windowID = WindowID(rawValue: 1)
    var replacement = write(point: CGPoint(x: 100, y: 40),
      size: CGSize(width: 800, height: 600), positionChanged: true, sizeChanged: false)
    replacement.animationPoint = CGPoint(x: -900, y: 40)
    let result = frameWritesPreservingSupersededAsyncSizes(
      active: [
        windowID: write(
          point: .zero,
          size: CGSize(width: 900, height: 700),
          positionChanged: false,
          sizeChanged: true
        )
      ],
      pending: [:],
      replacement: [
        windowID: replacement
      ]
    )

    #expect(result[windowID]?.animationPoint == replacement.animationPoint)
    #expect(result[windowID]?.point == CGPoint(x: 100, y: 40))
    #expect(result[windowID]?.size == CGSize(width: 800, height: 600))
    #expect(result[windowID]?.positionChanged == true)
    #expect(result[windowID]?.sizeChanged == true)
    #expect(result[windowID]?.synchronousSizeWriteSucceeded != true)
  }

  @Test
  func `Recent internal write matches every recorded component`() {
    let sizeWrite = RecentInternalFrameWrite(
      frame: Rect(x: 100, y: 40, width: 900, height: 700),
      positionChanged: false,
      sizeChanged: true,
      deadline: 20
    )
    let positionWrite = RecentInternalFrameWrite(
      frame: Rect(x: 100, y: 40, width: 900, height: 700),
      positionChanged: true,
      sizeChanged: false,
      deadline: 20
    )

    #expect(
      frameMatchesRecentInternalWrite(
        actual: sizeWrite.frame,
        write: sizeWrite
      ))
    #expect(
      frameMatchesRecentInternalWrite(
        actual: positionWrite.frame,
        write: positionWrite
      ))
    #expect(
      frameMatchesRecentInternalWrite(
        actual: Rect(x: 400, y: 200, width: 900, height: 700),
        write: sizeWrite
      ) == false)
    #expect(
      frameMatchesRecentInternalWrite(
        actual: Rect(x: 100, y: 40, width: 1_200, height: 800),
        write: positionWrite
      ) == false)
    #expect(
      frameMatchesRecentInternalWrite(
        actual: Rect(x: 400, y: 200, width: 1_200, height: 800),
        write: sizeWrite
      ) == false)
  }

  @Test
  func `Recent internal write history retains every live target`() {
    let coordinator = AXFrameCoordinator()
    let windowID = WindowID(rawValue: 42)
    let first = Rect(x: 100, y: 40, width: 900, height: 700)
    let second = Rect(x: 300, y: 40, width: 900, height: 700)

    coordinator.recordInternalFrameWrite(
      first,
      windowID: windowID,
      positionChanged: true,
      sizeChanged: false,
      now: 10
    )
    coordinator.recordInternalFrameWrite(
      second,
      windowID: windowID,
      positionChanged: true,
      sizeChanged: false,
      now: 10.1
    )

    #expect(
      coordinator.frameMatchesRecentInternalWrite(
        windowID: windowID,
        actual: first,
        now: 10.2
      ))
    #expect(
      coordinator.frameMatchesRecentInternalWrite(
        windowID: windowID,
        actual: second,
        now: 10.2
      ))
  }

  @Test
  func `Invalidation retains recent internal write history`() {
    let coordinator = AXFrameCoordinator()
    let windowID = WindowID(rawValue: 42)
    let frame = Rect(x: 100, y: 40, width: 900, height: 700)

    coordinator.recordInternalFrameWrite(
      frame,
      windowID: windowID,
      positionChanged: true,
      sizeChanged: true,
      now: 10
    )
    let element = AXUIElementCreateSystemWide()
    coordinator.activeWrites[windowID] = AsyncPositionWrite(
      element: element,
      application: element,
      processID: 42,
      fromPoint: .zero,
      point: .zero,
      fromSize: CGSize(width: 800, height: 600),
      size: CGSize(width: 900, height: 700),
      positionChanged: false,
      sizeChanged: true,
      animatesSize: false,
      synchronousSizeWriteSucceeded: false,
      enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016,
      isParked: false,
      isReentering: false,
      requiresVerifiedOffscreenWrite: false
    )
    coordinator.invalidate(reason: "display-change")

    #expect(coordinator.activeWrites.isEmpty)
    #expect(
      coordinator.frameMatchesRecentInternalWrite(
        windowID: windowID,
        actual: frame,
        now: 10.1
      ))
  }

  @Test
  func `Pruning recent internal writes drops closed windows`() {
    let coordinator = AXFrameCoordinator()
    let windowID = WindowID(rawValue: 42)
    coordinator.recordInternalFrameWrite(
      Rect(x: 100, y: 40, width: 900, height: 700),
      windowID: windowID,
      positionChanged: true,
      sizeChanged: true,
      now: 10
    )

    coordinator.pruneRecentInternalFrameWrites(liveWindowIDs: [], now: 10.2)

    #expect(
      coordinator.frameMatchesRecentInternalWrite(
        windowID: windowID,
        actual: Rect(x: 100, y: 40, width: 900, height: 700),
        now: 10.1
      ) == false)
  }

  @Test
  func `Pruning recent internal writes drops expired entries for live windows`() {
    let coordinator = AXFrameCoordinator()
    let windowID = WindowID(rawValue: 42)
    coordinator.recordInternalFrameWrite(
      Rect(x: 100, y: 40, width: 900, height: 700),
      windowID: windowID,
      positionChanged: true,
      sizeChanged: true,
      now: 10
    )

    #expect(
      coordinator.frameMatchesRecentInternalWrite(
        windowID: windowID,
        actual: Rect(x: 100, y: 40, width: 900, height: 700),
        now: 12.6
      ) == false)
    #expect(
      coordinator.frameMatchesRecentInternalWrite(
        windowID: windowID,
        actual: Rect(x: 100, y: 40, width: 900, height: 700),
        now: 12.4
      ))
  }

  @Test
  func `Successful frame write intent keeps partial position write`() {
    #expect(
      successfulFrameWriteIntent(
        positionChanged: true,
        positionApplied: true,
        sizeChanged: true,
        sizeApplied: false
      ) == FrameWriteIntent(position: true, size: false))
  }

  @Test
  func `Live border window requires accepted frame readback after position write`() {
    let liveWindowID = WindowID(rawValue: 42)

    #expect(
      acceptedFrameRequiresReadback(
        windowID: liveWindowID,
        sizeChanged: false,
        liveBorderWindowID: liveWindowID
      ))
    #expect(
      acceptedFrameRequiresReadback(
        windowID: WindowID(rawValue: 43),
        sizeChanged: false,
        liveBorderWindowID: liveWindowID
      ) == false)
  }

  @Test
  func `Completed active size write is not carried into replacement`() {
    let coordinator = AXFrameCoordinator()
    let element = AXUIElementCreateSystemWide()
    let windowID = WindowID(rawValue: 42)
    coordinator.activeWrites[windowID] = AsyncPositionWrite(
      element: element,
      application: element,
      processID: 42,
      fromPoint: .zero,
      point: .zero,
      fromSize: CGSize(width: 800, height: 600),
      size: CGSize(width: 900, height: 700),
      positionChanged: false,
      sizeChanged: true,
      animatesSize: false,
      synchronousSizeWriteSucceeded: false,
      enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016,
      isParked: false,
      isReentering: false,
      requiresVerifiedOffscreenWrite: false
    )

    coordinator.recordCompletedActiveSizeWrite(windowID: windowID)

    #expect(coordinator.activeWrites[windowID] == nil)
  }

  @Test
  func `Initial window commit uses short quarantine for fast retries`() {
    #expect(
      abs(frameCommitQuarantineDuration(
        animationDuration: 0,
        initialFrameSettlement: true
      ) - 0.18) <= 0.000_1
    )
    #expect(
      abs(frameCommitQuarantineDuration(
        animationDuration: 0,
        initialFrameSettlement: false
      ) - 0.8) <= 0.000_1
    )
  }

  @Test
  func `Initial window commit still covers animation`() {
    #expect(
      abs(frameCommitQuarantineDuration(
        animationDuration: 0.35,
        initialFrameSettlement: true
      ) - 0.47) <= 0.000_1
    )
  }

  @Test
  func `Initial settlement repairs position or size drift`() {
    let target = Rect(x: 100, y: 40, width: 1_200, height: 900)

    #expect(initialFrameNeedsRepair(actual: target, target: target) == false)
    #expect(
      initialFrameNeedsRepair(
        actual: Rect(x: 140, y: 40, width: 1_200, height: 900),
        target: target
      ))
    #expect(
      initialFrameNeedsRepair(
        actual: Rect(x: 100, y: 40, width: 900, height: 700),
        target: target
      ))
  }

  @Test
  func `Initial settlement stays armed after matching frame`() {
    let target = Rect(x: 100, y: 40, width: 1_200, height: 900)

    #expect(
      initialSettlementObservation(
        actual: target,
        target: target,
        now: 10,
        deadline: 12.5
      ) == .stable)
    #expect(
      initialSettlementObservation(
        actual: target,
        target: target,
        now: 12.5,
        deadline: 12.5
      ) == .expired)
  }

  @Test
  func `Initial settlement repairs only stable drift`() {
    let generation: UInt64 = 4
    let first = InitialSettlementDriftSample(
      generation: generation,
      frame: Rect(x: 100, y: 40, width: 900, height: 700),
      observedAt: 10
    )

    #expect(
      initialSettlementDriftIsStable(
        previous: first,
        generation: generation,
        actual: Rect(x: 100, y: 40, width: 1_000, height: 760),
        now: 10.1
      ) == false)
    #expect(
      initialSettlementDriftIsStable(
        previous: first,
        generation: generation,
        actual: first.frame,
        now: 10.04
      ) == false)
    #expect(
      initialSettlementDriftIsStable(
        previous: first,
        generation: generation,
        actual: Rect(x: 101, y: 40, width: 900, height: 700),
        now: 10.08
      ))
  }

  @Test
  func `Unchanged settlement drift preserves first observation time`() {
    let first = InitialSettlementDriftSample(
      generation: 4,
      frame: Rect(x: 100, y: 40, width: 900, height: 700),
      observedAt: 10
    )
    let unchanged = updatedInitialSettlementDriftSample(
      previous: first,
      generation: 4,
      actual: Rect(x: 101, y: 40, width: 900, height: 700),
      now: 10.03
    )
    let changed = updatedInitialSettlementDriftSample(
      previous: unchanged,
      generation: 4,
      actual: Rect(x: 100, y: 40, width: 1_000, height: 700),
      now: 10.04
    )

    #expect(unchanged.observedAt == 10)
    #expect(changed.observedAt == 10.04)
  }

  @Test
  func `Initial settlement schedules stable follow up before expiration`() {
    #expect(
      abs((initialSettlementFollowUpDelay(now: 12.1, deadline: 12.5) ?? 0) - 0.06)
        <= 0.000_1
    )
    #expect(initialSettlementFollowUpDelay(now: 12.48, deadline: 12.5) == nil)
    #expect(initialSettlementFollowUpDelay(now: 12.5, deadline: 12.5) == nil)
  }

  @Test
  func `Initial settlement repair requires current generation and idle mouse`() {
    #expect(
      initialSettlementRepairIsCurrent(
        expectedGeneration: 4,
        currentGeneration: 4,
        repairsSuspended: false,
        leftMouseButtonDown: false,
        animationRunning: false
      ))
    #expect(
      initialSettlementRepairIsCurrent(
        expectedGeneration: 4,
        currentGeneration: 5,
        repairsSuspended: false,
        leftMouseButtonDown: false,
        animationRunning: false
      ) == false)
    #expect(
      initialSettlementRepairIsCurrent(
        expectedGeneration: 4,
        currentGeneration: 4,
        repairsSuspended: true,
        leftMouseButtonDown: false,
        animationRunning: false
      ) == false)
    #expect(
      initialSettlementRepairIsCurrent(
        expectedGeneration: 4,
        currentGeneration: 4,
        repairsSuspended: false,
        leftMouseButtonDown: true,
        animationRunning: false
      ) == false)
    #expect(
      initialSettlementRepairIsCurrent(
        expectedGeneration: 4,
        currentGeneration: 4,
        repairsSuspended: false,
        leftMouseButtonDown: false,
        animationRunning: true
      ) == false)
  }

  @Test
  func `Window events use incremental refresh only with stable PID context`() {
    let processIDs: Set<pid_t> = [101, 202]

    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: true,
        requiresFullSnapshot: false,
        processIDs: processIDs
      ) == processIDs)
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: false,
        eventPending: true,
        requiresFullSnapshot: false,
        processIDs: processIDs
      ) == nil)
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: true,
        requiresFullSnapshot: true,
        processIDs: processIDs
      ) == nil)
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: true,
        requiresFullSnapshot: false,
        processIDs: []
      ) == nil)
  }

  @Test
  func `Incremental refresh includes coalesced frame process`() {
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: true,
        requiresFullSnapshot: false,
        processIDs: [101],
        coalescedProcessIDs: [202]
      ) == [101, 202])
  }

  @Test
  func `Coalesced frame process during gesture does not require topology event`() {
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: false,
        requiresFullSnapshot: false,
        processIDs: [],
        coalescedProcessIDs: [202],
        allowsCoalescedProcessRefresh: true
      ) == [202])
  }

  @Test
  func `Coalesced frame process outside gesture uses full refresh`() {
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: false,
        requiresFullSnapshot: false,
        processIDs: [],
        coalescedProcessIDs: [202]
      ) == nil)
  }

  @Test
  func `Focus only synchronization reuses cached windows`() {
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: false,
        requiresFullSnapshot: false,
        processIDs: [],
        allowsCachedRefresh: true
      ) == [])
  }

  @Test
  func `Frame notification refreshes only affected process`() {
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: false,
        requiresFullSnapshot: false,
        processIDs: [],
        coalescedProcessIDs: [202],
        allowsCoalescedProcessRefresh: true,
        allowsCachedRefresh: true
      ) == [202])
  }

  @Test
  func `Coalesced mouse resize forces full refresh`() {
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: true,
        requiresFullSnapshot: false,
        processIDs: [101],
        coalescedEventRequiresFullSnapshot: true
      ) == nil)
  }

  @Test
  func `Workspace switch places visible windows before parking old workspace`() {
    let visible = WindowID(rawValue: 1)
    let parked = Set([WindowID(rawValue: 2), WindowID(rawValue: 3)])
    let all = parked.union([visible])

    #expect(
      positionWritePhases(
        windowIDs: all,
        parkedWindowIDs: parked,
        stagesVisibleBeforeParking: true
      ) == [Set([visible]), parked])
    #expect(
      positionWritePhases(
        windowIDs: all,
        parkedWindowIDs: parked,
        stagesVisibleBeforeParking: false
      ) == [all])
  }

  @Test
  func `Position writes defer enhanced UI restoration throughout navigation`() {
    #expect(
      defersEnhancedUIRestore(
        enhancedUIWasEnabled: true,
        positionChanged: true
      ))
    #expect(
      defersEnhancedUIRestore(
        enhancedUIWasEnabled: false,
        positionChanged: true
      ) == false)
    #expect(
      defersEnhancedUIRestore(
        enhancedUIWasEnabled: true,
        positionChanged: false
      ) == false)
  }

  @Test
  func `Deferred focus only applies to current selection`() {
    let target = WindowID(rawValue: 1)

    #expect(
      shouldApplyDeferredFocus(
        targetWindowID: target,
        selectedWindowID: target
      ))
    #expect(
      shouldApplyDeferredFocus(
        targetWindowID: target,
        selectedWindowID: WindowID(rawValue: 2)
      ) == false)
  }

  @Test
  func `Expected horizontal commit lag is quarantined`() {
    #expect(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 420, y: 40, width: 800, height: 700),
        currentTarget: expectation.target,
        expectation: expectation,
        now: 10.4,
        leftMouseButtonDown: false
      ))
  }

  @Test
  func `Late intermediate rollback remains quarantined after target was observed`() {
    var observedExpectation = expectation
    observedExpectation.observedAt = 10.2

    #expect(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 260, y: 40, width: 800, height: 700),
        currentTarget: expectation.target,
        expectation: observedExpectation,
        now: 10.5,
        leftMouseButtonDown: false
      ))
  }

  @Test
  func `Expired or external movement is not quarantined`() {
    #expect(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 420, y: 40, width: 800, height: 700),
        currentTarget: expectation.target,
        expectation: expectation,
        now: 10.7,
        leftMouseButtonDown: false
      ) == false)
    #expect(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 1_400, y: 180, width: 800, height: 700),
        currentTarget: expectation.target,
        expectation: expectation,
        now: 10.4,
        leftMouseButtonDown: false
      ) == false)
    #expect(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 420, y: 40, width: 800, height: 700),
        currentTarget: expectation.target,
        expectation: expectation,
        now: 10.4,
        leftMouseButtonDown: true
      ) == false)
  }

  @Test
  func `One pixel strip anchors require verified offscreen writes`() {
    let monitor = Rect(x: 0, y: 0, width: 1_512, height: 900)

    #expect(
      requiresVerifiedOffscreenWrite(
        frame: Rect(x: 1_511, y: 40, width: 1_204, height: 860),
        monitorFrames: [monitor]
      ))
    #expect(
      requiresVerifiedOffscreenWrite(
        frame: Rect(x: -1_203, y: 40, width: 1_204, height: 860),
        monitorFrames: [monitor]
      ))
    #expect(
      requiresVerifiedOffscreenWrite(
        frame: Rect(x: -905, y: 40, width: 1_204, height: 860),
        monitorFrames: [monitor]
      ) == false)
  }

  @Test
  func `Visible ribbon window moves to its offscreen anchor before parking`() {
    let monitor = Rect(x: 0, y: 0, width: 1_000, height: 700)
    let id = WindowID(rawValue: 1)
    let visible = Rect(x: 500, y: 0, width: 500, height: 700)
    let strip = continuousStripFramesForActiveWorkspace(
      [FrameAssignment(windowID: id, frame: Rect(x: 1_000, y: 0, width: 500, height: 700))],
      viewport: monitor
    )

    #expect(strip.parkedWindowIDs == [id])
    #expect(shouldAnimateParkedRibbonWindow(
      source: "command-animation", from: visible, monitorFrames: [monitor]
    ))
    #expect(!shouldAnimateParkedRibbonWindow(
      source: "command-animation", from: strip.frames[0].frame, monitorFrames: [monitor]
    ))
    #expect(!shouldAnimateParkedRibbonWindow(
      source: "command-animation",
      from: Rect(x: -499, y: 0, width: 500, height: 700),
      monitorFrames: [monitor]
    ))
    #expect(!shouldAnimateParkedRibbonWindow(
      source: "workspace-transition", from: visible, monitorFrames: [monitor]
    ))
  }

  @Test
  func `Neighboring monitor prevents false sliver classification`() {
    #expect(
      requiresVerifiedOffscreenWrite(
        frame: Rect(x: 1_511, y: 40, width: 1_204, height: 860),
        monitorFrames: [
          Rect(x: 0, y: 0, width: 1_512, height: 900),
          Rect(x: 1_512, y: 0, width: 1_920, height: 1_080),
        ]
      ) == false)
  }

  @Test
  func `AX latency classification uses hysteresis`() {
    #expect(
      axProcessIsLatencySensitive(
        previouslySensitive: false,
        predictedLatencyMS: 11.9
      ) == false)
    #expect(
      axProcessIsLatencySensitive(
        previouslySensitive: false,
        predictedLatencyMS: 12
      ))
    #expect(
      axProcessIsLatencySensitive(
        previouslySensitive: true,
        predictedLatencyMS: 7
      ))
    #expect(
      axProcessIsLatencySensitive(
        previouslySensitive: true,
        predictedLatencyMS: 6.9
      ) == false)
  }

  @Test
  func `Slow lane entry requires consecutive samples`() {
    var streak = ProcessLatencyStreak()
    #expect(processLatencyEntryIsConfirmed(sampleMS: 120, streak: &streak) == false)
    #expect(processLatencyEntryIsConfirmed(sampleMS: 15, streak: &streak))
  }

  @Test
  func `Slow lane entry ignores single spike`() {
    var streak = ProcessLatencyStreak()
    #expect(processLatencyEntryIsConfirmed(sampleMS: 90, streak: &streak) == false)
    #expect(processLatencyEntryIsConfirmed(sampleMS: 25, streak: &streak))
    #expect(processLatencyEntryIsConfirmed(sampleMS: 4, streak: &streak) == false)
    #expect(processLatencyEntryIsConfirmed(sampleMS: 20, streak: &streak) == false)
    #expect(processLatencyEntryIsConfirmed(sampleMS: 30, streak: &streak))
  }

  @Test
  func `Animation lanes keep fast processes interpolated`() {
    let fast = WindowID(rawValue: 1)
    let slow = WindowID(rawValue: 2)

    #expect(
      frameAnimationLanePlan(
        animatedWindowIDs: [fast, slow],
        processIDs: [fast: 101, slow: 202],
        reenteringWindowIDs: [],
        finalOnlyProcessIDs: [202],
        deferredSizeWindowIDs: []
      )
        == FrameAnimationLanePlan(
          interpolatedWindowIDs: [fast],
          finalOnlyWindowIDs: [slow],
          stagedFinalOnlyReentryWindowIDs: [],
          deferredSizeWindowIDs: []
        ))
  }

  @Test
  func `Horizontally moving resize animates before its final size commit`() {
    let resizing = WindowID(rawValue: 1)
    let translating = WindowID(rawValue: 2)

    #expect(
      frameAnimationLanePlan(
        animatedWindowIDs: [resizing, translating],
        processIDs: [resizing: 101, translating: 202],
        reenteringWindowIDs: [],
        finalOnlyProcessIDs: [],
        deferredSizeWindowIDs: [resizing]
      )
        == FrameAnimationLanePlan(
          interpolatedWindowIDs: [resizing, translating],
          finalOnlyWindowIDs: [],
          stagedFinalOnlyReentryWindowIDs: [],
          deferredSizeWindowIDs: [resizing]
        ))
  }

  @Test
  func `Vertical cross-display resize defers size until movement completes`() {
    let displays = [
      Rect(x: 0, y: 0, width: 1_000, height: 700),
      Rect(x: 0, y: 700, width: 1_000, height: 700),
    ]
    let source = Rect(x: 100, y: 100, width: 800, height: 500)
    let target = Rect(x: 100, y: 800, width: 800, height: 500)

    #expect(shouldDeferAnimatedSizeUntilMovementCompletes(
      from: source, to: target, displayFrames: displays
    ))
    #expect(!shouldDeferAnimatedSizeUntilMovementCompletes(
      from: source,
      to: Rect(x: 100, y: 150, width: 800, height: 500),
      displayFrames: displays
    ))
  }

  @Test func sameDisplayReflowKeepsSizeOnTheMovementTimeline() {
    let display = Rect(x: 0, y: 0, width: 1_512, height: 982)
    let source = Rect(x: 756, y: 25, width: 756, height: 910)
    let target = Rect(x: 0, y: 25, width: 1_512, height: 910)
    #expect(!shouldDeferAnimatedSizeUntilMovementCompletes(
      from: source, to: target, displayFrames: [display]))
  }

  @Test func reorderedParkedColumnStartsAtItsPreviousLogicalSlot() throws {
    let monitor = Rect(x: 0, y: 25, width: 1_512, height: 910)
    let previous = Rect(x: -1_512, y: 25, width: 756, height: 910)
    let target = Rect(x: 756, y: 25, width: 756, height: 910)
    let parked = nativeRibbonAnimationFrame(previous, monitor: monitor)
    let start = try #require(layoutRibbonAnimationStart(previousLogical: previous,
      target: target, observed: parked, monitorFrames: [monitor]))
    #expect(start.x == previous.x)
    #expect(start.x != parked.x)
    let halfway = nativeRibbonAnimationFrame(
      interpolatedFrame(from: start, to: target, progress: 0.5), monitor: monitor)
    #expect(halfway.x < target.x)
    #expect(layoutRibbonAnimationStart(previousLogical: nil, target: target,
      observed: parked, monitorFrames: [monitor]) == nil)
    #expect(layoutRibbonAnimationStart(previousLogical: previous, target: target,
      observed: parked, monitorFrames: [monitor, Rect(x: 1_512, y: 0, width: 1_000, height: 800)]) == nil)
  }

  @Test
  func `Final only reentry keeps verified staging write`() {
    let fast = WindowID(rawValue: 1)
    let slowReentry = WindowID(rawValue: 2)

    #expect(
      frameAnimationLanePlan(
        animatedWindowIDs: [fast, slowReentry],
        processIDs: [fast: 101, slowReentry: 202],
        reenteringWindowIDs: [slowReentry],
        finalOnlyProcessIDs: [202],
        deferredSizeWindowIDs: []
      ).stagedFinalOnlyReentryWindowIDs == [slowReentry])
  }

  @Test
  func `Skipped window keeps previous target until settlement`() {
    let skipped = WindowID(rawValue: 1)
    let fast = WindowID(rawValue: 2)
    let previous: [WindowID: Rect] = [
      skipped: Rect(x: 10, y: 0, width: 400, height: 700),
      fast: Rect(x: 420, y: 0, width: 400, height: 700),
    ]
    let next = frameTargetsPreservingSkippedWindows(
      previous: previous,
      assignments: [
        FrameAssignment(
          windowID: skipped,
          frame: Rect(x: -390, y: 0, width: 400, height: 700)
        ),
        FrameAssignment(
          windowID: fast,
          frame: Rect(x: 20, y: 0, width: 400, height: 700)
        ),
      ],
      skippedWindowIDs: [skipped]
    )

    #expect(next[skipped] == previous[skipped])
    #expect(next[fast] == Rect(x: 20, y: 0, width: 400, height: 700))
  }

  @Test
  func `Skipped window keeps previous parking state until settlement`() {
    let skipped = WindowID(rawValue: 1)
    let fast = WindowID(rawValue: 2)

    #expect(
      hiddenWindowsPreservingSkippedWindows(
        previous: [skipped],
        desired: [fast],
        skippedWindowIDs: [skipped]
      ) == [skipped, fast])
  }

  @Test
  func `Ribbon navigation never plans size writes`() {
    #expect(
      frameWriteIntent(
        reference: Rect(x: 800, y: 0, width: 600, height: 700),
        target: Rect(x: 100, y: 0, width: 1_000, height: 900),
        positionsOnly: true
      ) == FrameWriteIntent(position: true, size: false))
  }

  @Test
  func `Frame animation interpolates position and size`() {
    #expect(
      interpolatedFrame(
        from: Rect(x: 100, y: 40, width: 600, height: 700),
        to: Rect(x: 40, y: 20, width: 1_000, height: 800),
        progress: 0.25
      ) == Rect(x: 85, y: 35, width: 700, height: 725))
  }

  @Test
  func `Frame centers distinguish same-display and cross-display movement`() {
    let displays = [
      Rect(x: 0, y: 0, width: 1_000, height: 700),
      Rect(x: 1_000, y: 0, width: 1_000, height: 700),
    ]
    let initial = Rect(x: 100, y: 0, width: 800, height: 700)
    #expect(frameCentersCrossDisplays(
      from: initial, to: Rect(x: 1_100, y: 0, width: 800, height: 700),
      displayFrames: displays
    ))
    #expect(!frameCentersCrossDisplays(
      from: initial, to: Rect(x: 150, y: 0, width: 800, height: 700),
      displayFrames: displays
    ))
    #expect(!frameCentersCrossDisplays(
      from: initial, to: Rect(x: 2_100, y: 0, width: 800, height: 700),
      displayFrames: displays
    ))
    #expect(frameCentersCrossDisplays(
      from: Rect(x: 600, y: 0, width: 800, height: 700),
      to: Rect(x: 100, y: 0, width: 800, height: 700),
      displayFrames: displays
    ))
    #expect(!frameCentersCrossDisplays(
      from: Rect(x: -900, y: 0, width: 800, height: 700),
      to: Rect(x: 100, y: 0, width: 800, height: 700),
      displayFrames: displays
    ))
  }

  @Test
  func `Matching vertical reentry start skips staging`() {
    #expect(
      reentryStartRequiresStaging(
        observed: CGPoint(x: 4, y: 899),
        planned: CGPoint(x: 4, y: 899)
      ) == false
    )
    #expect(
      reentryStartRequiresStaging(
        observed: CGPoint(x: 1_511, y: 37),
        planned: CGPoint(x: 4, y: 899)
      )
    )
  }
}
