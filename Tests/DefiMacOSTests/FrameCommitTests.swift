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

  @Test
  func supersededOffscreenWriteDoesNotRetryAnObsoleteTarget() {
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
    let write = makeMotionWrite(fromX: 2568, toX: 1700, processID: -1, isParked: true)
    let frame = QueuedPositionFrame(
      generation: 1, source: "command-animation", writes: [id: write],
      stagesVisibleBeforeParking: false, completion: nil
    )
    _ = coordinator.applyBatch(
      ProcessWriteBatch(processID: -1, writes: [(key: id, value: write)]),
      frame: frame)
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
    coordinator.enhancedUIRestoreGroup.wait()
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
    #expect(coordinator.enhancedUIRestoreGroup.wait(timeout: .now()) == .timedOut)
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

  @Test(arguments: [false, true])
  func oneWriteMovesTheWindowWithoutNativeStaging(independentObservation: Bool) {
    let nativeReads = Mutex(0), writes = Mutex<[CGPoint]>([])
    let coordinator = AXFrameCoordinator(accessibilityWriter: AXFrameAccessibilityWriter(
      positionWriter: { _, point in writes.withLock { $0.append(point) }; return true },
      nativePositionReader: { _, _ in nativeReads.withLock { $0 += 1 }; return nil },
      independentBorderObservationAvailable: { independentObservation }
    ))
    coordinator.running = true
    let id = WindowID(rawValue: 1)
    coordinator.submit(
      [id: makeMotionWrite(fromX: 2568, toX: 1700, processID: -1)],
      source: "command-animation", monitorFrames: [Rect(x: 0, y: 0, width: 2560, height: 1440)])
    coordinator.drain()
    #expect(writes.withLock { $0 } == [CGPoint(x: 1700, y: 40)])
    #expect(nativeReads.withLock { $0 } == 0)
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
    let rediscovered = coordinator.beginDeferredEnhancedUIRestore(processID: -1, application: application)
    #expect(disables.withLock { $0 } == 3)
    #expect(coordinator.deferredEnhancedUIRestores[-1]?.token == rediscovered)
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
  func horizontalMotionDoesNotWaitForIndependentBorderObservation() {
    let reads = Mutex(0)
    let coordinator = AXFrameCoordinator(accessibilityWriter: AXFrameAccessibilityWriter(
      positionWriter: { _, _ in true },
      positionReader: { _ in Issue.record("Unexpected AX fallback"); return nil },
      nativePositionReader: { _, _ in
        reads.withLock { $0 += 1 }
        return CGPoint(x: 480, y: 40)
      },
      independentBorderObservationAvailable: { true }
    ))
    let id = WindowID(rawValue: 1)
    let before = Rect(x: 900, y: 40, width: 800, height: 700)
    coordinator.latestGeneration = 1
    coordinator.updateLiveBorderWindowID(id)
    coordinator.recordObservedBorderFrame(before, windowID: id, sampledAt: 0)
    let write = makeMotionWrite(fromX: 900, toX: 100)
    let frame = QueuedPositionFrame(
      generation: 1, source: "command-animation", writes: [id: write], stagesVisibleBeforeParking: false,
      completion: nil
    )
    _ = coordinator.applyBatch(
      ProcessWriteBatch(processID: 42, writes: [(key: id, value: write)]),
      frame: frame)
    #expect(reads.withLock { $0 } == 0)
    #expect(coordinator.completedPosition(for: id)?.x == 100)
    // A successful command point must not become an observed border frame.
    #expect(coordinator.latestBorderFrame(for: id)?.x == 900)
    let observed = Rect(x: 105, y: 40, width: 800, height: 700)
    // Right after an unverified write, a disagreeing sample may be WindowServer lag.
    coordinator.recordObservedBorderFrame(
      observed, windowID: id, sampledAt: ProcessInfo.processInfo.systemUptime
    )
    #expect(coordinator.latestBorderFrame(for: id)?.x == 900)
    coordinator.recordObservedBorderFrame(
      observed, windowID: id, sampledAt: ProcessInfo.processInfo.systemUptime + 0.25
    )
    #expect(coordinator.latestBorderFrame(for: id) == observed)
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
      generation: 1, source: "command-animation", writes: [id: write], stagesVisibleBeforeParking: false,
      completion: nil
    )
    let result = coordinator.applyBatch(
      ProcessWriteBatch(processID: -1, writes: [(id, write)]), frame: frame)
    #expect(result.stale == 1)
    #expect(coordinator.completedPositions[id]?.x == 100)
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
      positionChanged: true, sizeChanged: false,
      synchronousSizeWriteSucceeded: true, enhancedUIWasEnabled: true,
      timeoutSeconds: 0.016, isParked: false,
      requiresVerifiedOffscreenWrite: false
    )
    let windowID = WindowID(rawValue: 1)
    let frame = QueuedPositionFrame(
      generation: 1, source: "stale-setup-test", writes: [windowID: write], stagesVisibleBeforeParking: false, completion: nil
    )
    let batch = coordinator.applyBatch(
      ProcessWriteBatch(processID: -1, writes: [(windowID, write)]), frame: frame)
    #expect(batch.applied == 0 && batch.stale == 1 && !batch.attempted)
    #expect(coordinator.deferredEnhancedUIRestores.isEmpty)
    let result = coordinator.applyFrame(frame, skippedProcesses: [])
    #expect(result.applied == 0 && result.stale == 1)
    #expect(coordinator.processWriteQueues.isEmpty)
    let excluded = coordinator.applyFrame(frame, skippedProcesses: [-1])
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
    coordinator.activeWrites[target] = makeMotionWrite(fromX: 900, toX: 100, sizeChanged: true)
    #expect(coordinator.pendingWindowIDs == [target, sibling])
    coordinator.recordCompletedActiveSizeWrite(windowID: target)
    #expect(coordinator.pendingWindowIDs == [sibling])

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

    coordinator.invalidate(reason: "display-change")

    #expect(coordinator.latestGeneration != oldFrame.generation)
    #expect(coordinator.activeWrites.isEmpty)
    #expect(coordinator.parkingTargets.isEmpty)
    #expect(coordinator.parkingVerificationSchedules.isEmpty)

    let latestWrite = makeMotionWrite(fromX: 100, toX: 900)
    coordinator.updateParkingTargets([windowID: latestWrite])
    #expect(coordinator.parkingVerificationSchedules[windowID] == nil)

    let result = coordinator.applyFrame(oldFrame, skippedProcesses: [])
    #expect(result.stale == 1)
    #expect(result.applied == 0)
    #expect(coordinator.activeWrites.isEmpty)
    #expect(coordinator.parkingTargets[windowID]?.point == latestWrite.point)
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
      positionChanged: true, sizeChanged: false,
      synchronousSizeWriteSucceeded: true, enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016, isParked: true,
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

  @Test
  func parkedWindowStoppedByItsTitleBarIsNoDrift() {
    let target = Rect(x: 2_559, y: 1_365, width: 1_270, height: 1_359)
    #expect(parkedFrameHolds(Rect(x: 2_559, y: 1_345, width: 1_270, height: 1_359), target: target))
    #expect(!parkedFrameHolds(Rect(x: 2_559, y: 1_265, width: 1_270, height: 1_359), target: target),
      "Pulled back onto the display")
    #expect(!parkedFrameHolds(Rect(x: 2_000, y: 1_365, width: 1_270, height: 1_359), target: target),
      "Moved sideways")
    #expect(!parkedFrameHolds(Rect(x: 2_559, y: 1_365, width: 800, height: 1_359), target: target),
      "Resized")
  }

  @Test(arguments: [(20.0, 0), (100.0, 1)])
  func parkedWindowStoppedByItsTitleBarNeedsNoRepair(raisedBy: Double, repairs: Int) {
    let point = CGPoint(x: 2_559, y: 1_365)
    let writes = Mutex(0)
    let coordinator = AXFrameCoordinator(accessibilityWriter: AXFrameAccessibilityWriter(
      positionWriter: { _, _ in writes.withLock { $0 += 1 }; return true },
      positionReader: { _ in CGPoint(x: point.x, y: point.y - raisedBy) }))
    let windowID = WindowID(rawValue: 1)
    let element = AXUIElementCreateApplication(-1)
    let size = CGSize(width: 1_200, height: 900)
    coordinator.parkingTargets[windowID] = AsyncPositionWrite(
      element: element, application: element, processID: -1,
      fromPoint: point, point: point, fromSize: size, size: size,
      positionChanged: true, sizeChanged: false,
      synchronousSizeWriteSucceeded: true, enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016, isParked: true, requiresVerifiedOffscreenWrite: false
    )
    let schedule = ParkingVerificationSchedule(
      expectedPoint: point, deadline: ProcessInfo.processInfo.systemUptime + 1.4)
    coordinator.parkingVerificationSchedules[windowID] = schedule

    coordinator.verifyParkingTarget(
      windowID: windowID, expectedPoint: point, schedule: schedule, isFinalCheck: true)
    #expect(writes.withLock { $0 } == repairs * 2)
    #expect((coordinator.parkingVerificationSchedules[windowID] == nil) == (repairs == 0))
  }

  @Test
  func interruptedRibbonDoesNotMistakeUncommittedParkingTargetForAppliedPosition() {
    let target = Rect(x: -1505, y: 37, width: 1506, height: 902)
    let actual = CGPoint(x: -231, y: 37)
    let reference = frameApplicationReference(
      pendingCorrection: nil, completedPosition: actual,
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
    let parked = CGPoint(x: 2_559, y: 1_439)
    #expect(frameWritePosition(target: destination, from: parked, horizontalOnly: true)
      == destination, "A column leaving its parked corner must reach the ribbon's height")
    #expect(frameWriteIntent(reference: Rect(x: 2_559, y: 1_439, width: 1506, height: 902),
      target: target, positionsOnly: true, horizontalOnly: true).position)
  }

  private func makeMotionWrite(
    fromX: Double, toX: Double, sizeChanged: Bool = false, processID: pid_t = 42,
    isParked: Bool = false, toY: Double = 40
  ) -> AsyncPositionWrite {
    // Handles only: these tests never read or mutate the real desktop.
    let element = AXUIElementCreateSystemWide()
    return AsyncPositionWrite(
      element: element, application: element, processID: processID,
      fromPoint: CGPoint(x: fromX, y: 40), point: CGPoint(x: toX, y: toY),
      fromSize: CGSize(width: 800, height: 700), size: CGSize(width: 900, height: 700),
      positionChanged: true, sizeChanged: sizeChanged,
      synchronousSizeWriteSucceeded: !sizeChanged, enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016, isParked: isParked,
      requiresVerifiedOffscreenWrite: false
    )
  }

  @Test
  func `Frame application reference does not read native frame when cached`() {
    var nativeFrameWasRead = false

    _ = frameApplicationReference(
      pendingCorrection: Rect(x: 100, y: 40, width: 800, height: 700),
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
      processID: 42,
      processLatencyMS: 0.1,
      attempted: false
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
        asynchronousWriteSucceeded: false
      ) == false)
    #expect(
      frameSizeWriteSucceeded(
        sizeChanged: true,
        synchronousWriteSucceeded: true,
        asynchronousWriteSucceeded: false
      ))
    #expect(
      frameSizeWriteSucceeded(
        sizeChanged: true,
        synchronousWriteSucceeded: false,
        asynchronousWriteSucceeded: true
      ))
    #expect(
      frameSizeWriteSucceeded(
        sizeChanged: false,
        synchronousWriteSucceeded: false,
        asynchronousWriteSucceeded: false
      ))
  }

  @Test
  func `Asynchronous layout routes size writes to coordinator`() {
    #expect(
      asynchronousSizeWriteIsRequired(
        sizeChanged: true,
        synchronousWriteSucceeded: false
      ))
    #expect(
      asynchronousSizeWriteIsRequired(
        sizeChanged: true,
        synchronousWriteSucceeded: true
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
        synchronousSizeWriteSucceeded: synchronousSizeWriteSucceeded,
        enhancedUIWasEnabled: false,
        timeoutSeconds: 0.016,
        isParked: false,
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
        synchronousSizeWriteSucceeded: !sizeChanged,
        enhancedUIWasEnabled: false,
        timeoutSeconds: 0.016,
        isParked: false,
        requiresVerifiedOffscreenWrite: false
      )
    }
    let windowID = WindowID(rawValue: 1)
    let replacement = write(point: CGPoint(x: 100, y: 40),
      size: CGSize(width: 800, height: 600), positionChanged: true, sizeChanged: false)
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
      synchronousSizeWriteSucceeded: false,
      enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016,
      isParked: false,
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
  func `Recent internal writes expire for live windows without pruning`() {
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
      synchronousSizeWriteSucceeded: false,
      enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016,
      isParked: false,
      requiresVerifiedOffscreenWrite: false
    )

    coordinator.recordCompletedActiveSizeWrite(windowID: windowID)

    #expect(coordinator.activeWrites[windowID] == nil)
  }

  @Test
  func `Initial window commit quarantine is shorter than an ordinary commit`() {
    #expect(frameCommitQuarantineDuration(initialFrameSettlement: true) == 0.18)
    #expect(frameCommitQuarantineDuration(initialFrameSettlement: false) == 0.8)
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
        leftMouseButtonDown: false
      ))
    #expect(
      initialSettlementRepairIsCurrent(
        expectedGeneration: 4,
        currentGeneration: 5,
        repairsSuspended: false,
        leftMouseButtonDown: false
      ) == false)
    #expect(
      initialSettlementRepairIsCurrent(
        expectedGeneration: 4,
        currentGeneration: 4,
        repairsSuspended: true,
        leftMouseButtonDown: false
      ) == false)
    #expect(
      initialSettlementRepairIsCurrent(
        expectedGeneration: 4,
        currentGeneration: 4,
        repairsSuspended: false,
        leftMouseButtonDown: true
      ) == false)
  }

  struct IncrementalRefreshCase: CustomTestStringConvertible, Sendable {
    let name: String
    var hasCompletedSnapshot = true
    var eventPending = true
    var requiresFullSnapshot = false
    var processIDs: Set<pid_t> = [101, 202]
    var coalescedProcessIDs: Set<pid_t> = []
    var coalescedEventRequiresFullSnapshot = false
    var allowsCoalescedProcessRefresh = false
    var allowsCachedRefresh = false
    let expected: Set<pid_t>?

    var testDescription: String { name }
  }

  static let incrementalRefreshCases = [
    IncrementalRefreshCase(
      name: "pending event with stable PID context refreshes its processes",
      expected: [101, 202]
    ),
    IncrementalRefreshCase(
      name: "missing completed snapshot uses full refresh",
      hasCompletedSnapshot: false,
      expected: nil
    ),
    IncrementalRefreshCase(
      name: "required full snapshot uses full refresh",
      requiresFullSnapshot: true,
      expected: nil
    ),
    IncrementalRefreshCase(
      name: "pending event without process IDs uses full refresh",
      processIDs: [],
      expected: nil
    ),
    IncrementalRefreshCase(
      name: "incremental refresh includes coalesced frame process",
      processIDs: [101],
      coalescedProcessIDs: [202],
      expected: [101, 202]
    ),
    IncrementalRefreshCase(
      name: "coalesced frame process during gesture does not require topology event",
      eventPending: false,
      processIDs: [],
      coalescedProcessIDs: [202],
      allowsCoalescedProcessRefresh: true,
      expected: [202]
    ),
    IncrementalRefreshCase(
      name: "coalesced frame process outside gesture uses full refresh",
      eventPending: false,
      processIDs: [],
      coalescedProcessIDs: [202],
      expected: nil
    ),
    IncrementalRefreshCase(
      name: "focus only synchronization reuses cached windows",
      eventPending: false,
      processIDs: [],
      allowsCachedRefresh: true,
      expected: []
    ),
    IncrementalRefreshCase(
      name: "frame notification refreshes only affected process",
      eventPending: false,
      processIDs: [],
      coalescedProcessIDs: [202],
      allowsCoalescedProcessRefresh: true,
      allowsCachedRefresh: true,
      expected: [202]
    ),
    IncrementalRefreshCase(
      name: "coalesced mouse resize forces full refresh",
      processIDs: [101],
      coalescedEventRequiresFullSnapshot: true,
      expected: nil
    ),
  ]

  @Test(arguments: incrementalRefreshCases)
  func `Incremental window refresh process IDs follow snapshot and event context`(
    _ scenario: IncrementalRefreshCase
  ) {
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: scenario.hasCompletedSnapshot,
        eventPending: scenario.eventPending,
        requiresFullSnapshot: scenario.requiresFullSnapshot,
        processIDs: scenario.processIDs,
        coalescedProcessIDs: scenario.coalescedProcessIDs,
        coalescedEventRequiresFullSnapshot: scenario.coalescedEventRequiresFullSnapshot,
        allowsCoalescedProcessRefresh: scenario.allowsCoalescedProcessRefresh,
        allowsCachedRefresh: scenario.allowsCachedRefresh
      ) == scenario.expected
    )
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
    #expect(
      requiresVerifiedOffscreenWrite(
        frame: Rect(x: 0, y: 899, width: 1_204, height: 860),
        monitorFrames: [monitor]
      ), "A window parked below its display shows one row")
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
  func `Slow lane entry ignores single spike`() {
    var streak = ProcessLatencyStreak()
    #expect(processLatencyEntryIsConfirmed(sampleMS: 90, streak: &streak) == false)
    #expect(processLatencyEntryIsConfirmed(sampleMS: 25, streak: &streak))
    #expect(processLatencyEntryIsConfirmed(sampleMS: 4, streak: &streak) == false)
    #expect(processLatencyEntryIsConfirmed(sampleMS: 20, streak: &streak) == false)
    #expect(processLatencyEntryIsConfirmed(sampleMS: 30, streak: &streak))
  }

  struct DeferredSizeCase: CustomTestStringConvertible, Sendable {
    let name: String
    let displays: [Rect]
    let source: Rect
    let target: Rect
    let defers: Bool

    var testDescription: String { name }
  }

  static let deferredSizeCases = [
    DeferredSizeCase(
      name: "vertical cross-display resize defers size",
      displays: [
        Rect(x: 0, y: 0, width: 1_000, height: 700),
        Rect(x: 0, y: 700, width: 1_000, height: 700),
      ],
      source: Rect(x: 100, y: 100, width: 800, height: 500),
      target: Rect(x: 100, y: 800, width: 800, height: 500),
      defers: true
    ),
    DeferredSizeCase(
      name: "same display movement keeps size on the movement timeline",
      displays: [
        Rect(x: 0, y: 0, width: 1_000, height: 700),
        Rect(x: 0, y: 700, width: 1_000, height: 700),
      ],
      source: Rect(x: 100, y: 100, width: 800, height: 500),
      target: Rect(x: 100, y: 150, width: 800, height: 500),
      defers: false
    ),
    DeferredSizeCase(
      name: "growth past the display edge at its start position defers size",
      displays: [Rect(x: 0, y: 0, width: 1_512, height: 982)],
      source: Rect(x: 756, y: 25, width: 756, height: 910),
      target: Rect(x: 0, y: 25, width: 1_512, height: 910),
      defers: true
    ),
    DeferredSizeCase(
      name: "growth with a stale wide start size still defers size",
      displays: [Rect(x: 0, y: 0, width: 1_512, height: 982)],
      source: Rect(x: 756, y: 25, width: 1_512, height: 910),
      target: Rect(x: 0, y: 25, width: 1_512, height: 910),
      defers: true
    ),
    DeferredSizeCase(
      name: "growth that fits at its start position commits before motion",
      displays: [Rect(x: 0, y: 0, width: 1_512, height: 982)],
      source: Rect(x: 0, y: 25, width: 756, height: 910),
      target: Rect(x: 0, y: 25, width: 1_512, height: 910),
      defers: false
    ),
  ]

  @Test(arguments: deferredSizeCases)
  func `Animated size defers until movement completes across displays or past the display edge`(
    _ scenario: DeferredSizeCase
  ) {
    #expect(
      shouldDeferAnimatedSizeUntilMovementCompletes(
        from: scenario.source,
        to: scenario.target,
        displayFrames: scenario.displays
      ) == scenario.defers
    )
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

}
