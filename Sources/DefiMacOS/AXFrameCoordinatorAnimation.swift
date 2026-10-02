import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog
import Synchronization

private struct AnimationClockState: Sendable {
  var timeline: FrameAnimationClock
  var frames = 0
  var submittedIntermediateSteps = 0
  var previousDispatchAt: TimeInterval?
  var maximumDispatchGapMS = 0.0
  var maximumLatenessMS = 0.0
  var maximumSubmissionMS = 0.0
  var coalescedLaneCount = 0
  var finished = false
  var busyLanePulses = 0
}

extension AXFrameCoordinator {
  func animate(
    _ frame: QueuedPositionFrame
  ) -> (applied: Int, stale: Int, frames: Int) {
    let preparationStartedAt = ProcessInfo.processInfo.systemUptime
    let animatedWrites = frame.writes.filter {
      frame.animatedWindowIDs.contains($0.key)
    }
    let staticWrites = frame.writes.filter {
      !animatedWrites.keys.contains($0.key)
    }
    let deferredParkingWrites = staticWrites.filter { $0.value.isParked }
    let blockingStaticWrites = staticWrites.filter { !$0.value.isParked }
    // Horizontal motion uses live lane readiness at each display pulse. A
    // historical AX stall must not decimate an entire later ribbon animation.
    // Vertical transitions and resize keep their all-or-nothing latency budget.
    let usesLiveMotionCadence = !animatedWrites.isEmpty && animatedWrites.values.allSatisfy {
      !$0.sizeChanged && $0.fromPoint.y == $0.point.y
    }
    let finalOnlyProcessIDs = usesLiveMotionCadence ? [] : finalOnlyAnimationProcessIDs(
      for: animatedWrites,
      animationDuration: frame.animationDuration,
      refreshRateHz: frame.refreshRateHz
    )
    // Never mix a jumping lane with interpolated neighbors, even when latency
    // changed after the frame was submitted.
    if !finalOnlyProcessIDs.isEmpty {
      recordAnimationFallback(frame, reason: "motion-budget-before-staging", details: "pids=\(finalOnlyProcessIDs.sorted())")
      let result = applyFrame(frame, progress: 1, skippedProcesses: [], stagingReentry: true)
      markAnimationFinished(generation: frame.generation, startedAt: preparationStartedAt)
      return (result.applied, result.stale, result.frames)
    }
    let lanePlan = frameAnimationLanePlan(
      animatedWindowIDs: Set(animatedWrites.keys),
      processIDs: animatedWrites.mapValues(\.processID),
      reenteringWindowIDs: Set(
        animatedWrites.compactMap { windowID, write in
          write.isReentering ? windowID : nil
        }
      ),
      finalOnlyProcessIDs: [],
      deferredSizeWindowIDs: Set(
        animatedWrites.compactMap { windowID, write in
          guard asynchronousSizeWriteIsRequired(
            sizeChanged: write.sizeChanged,
            synchronousWriteSucceeded: write.synchronousSizeWriteSucceeded,
            animatesSize: write.animatesSize
          ) else { return nil }
          return shouldDeferAnimatedSizeUntilMovementCompletes(
            from: Rect(
              x: write.fromPoint.x,
              y: write.fromPoint.y,
              width: write.fromSize.width,
              height: write.fromSize.height
            ),
            to: Rect(
              x: write.point.x,
              y: write.point.y,
              width: write.size.width,
              height: write.size.height
            ),
            displayFrames: frame.monitorFrames
          )
            ? windowID
            : nil
        }
      )
    )
    let interpolatedWrites = animatedWrites.filter {
      lanePlan.interpolatedWindowIDs.contains($0.key)
    }
    let deferredSizeWrites = interpolatedWrites.filter {
      lanePlan.deferredSizeWindowIDs.contains($0.key)
    }
    var loopWrites = interpolatedWrites
    // Move first; one final size write must not block the animation clock.
    for (windowID, write) in deferredSizeWrites {
      loopWrites[windowID] = positionOnlyAnimationWrite(
        write,
        holding: write.fromSize
      )
    }
    let sizeCommitCandidates = interpolatedWrites.filter {
      !lanePlan.deferredSizeWindowIDs.contains($0.key)
        && !$0.value.isReentering
        && !$0.value.requiresVerifiedOffscreenWrite
        && asynchronousSizeWriteIsRequired(
          sizeChanged: $0.value.sizeChanged,
          synchronousWriteSucceeded: $0.value.synchronousSizeWriteSucceeded,
          animatesSize: $0.value.animatesSize
        )
    }
    if !sizeCommitCandidates.isEmpty {
      let committedWindowIDs = commitFinalSizesOnce(
        sizeCommitCandidates,
        generation: frame.generation
      )
      for (windowID, write) in sizeCommitCandidates
      where committedWindowIDs.contains(windowID) {
        loopWrites[windowID] = positionOnlyAnimationWrite(
          write,
          holding: write.size
        )
      }
    }
    let animatedFrame = QueuedPositionFrame(
      generation: frame.generation,
      source: frame.source,
      writes: loopWrites,
      animatedWindowIDs: lanePlan.interpolatedWindowIDs,
      animationDuration: frame.animationDuration,
      refreshRateHz: frame.refreshRateHz,
      displayIDs: frame.displayIDs,
      monitorFrames: frame.monitorFrames,
      initialProgressVelocity: frame.initialProgressVelocity,
      stagesVisibleBeforeParking: frame.stagesVisibleBeforeParking,
      successfulWrite: frame.successfulWrite,
      completion: nil,
      cursorWarpAfterWindowCommit: frame.cursorWarpAfterWindowCommit
    )
    var applied = 0
    var stale = 0
    let stagingGroup = DispatchGroup()
    let stagingAccumulator = FrameResultAccumulator()
    let reentryWrites = loopWrites.filter { $0.value.isReentering }
    if !reentryWrites.isEmpty {
      let reentryFrame = QueuedPositionFrame(
        generation: frame.generation,
        source: frame.source,
        writes: reentryWrites,
        animatedWindowIDs: Set(reentryWrites.keys),
        animationDuration: 0,
        refreshRateHz: frame.refreshRateHz,
        displayIDs: frame.displayIDs,
        monitorFrames: frame.monitorFrames,
        initialProgressVelocity: 0,
        stagesVisibleBeforeParking: frame.stagesVisibleBeforeParking,
        successfulWrite: frame.successfulWrite,
        completion: nil,
        cursorWarpAfterWindowCommit: frame.cursorWarpAfterWindowCommit
      )
      let stagingBatches = processWriteBatches(
        reentryWrites,
        windowIDs: Set(reentryWrites.keys)
      )
      for batch in stagingBatches {
        stagingGroup.enter()
        processWriteQueue(for: batch.processID).async { [self] in
          defer { stagingGroup.leave() }
          let startedAt = ProcessInfo.processInfo.systemUptime
          let result = applyBatch(
            batch,
            frame: reentryFrame,
            progress: 0,
            intermediate: true,
            stagingReentry: true,
            recordFinalSuccess: false
          )
          let completedAt = ProcessInfo.processInfo.systemUptime
          let latencyMS = (completedAt - startedAt) * 1_000
          stagingAccumulator.add(
            applied: result.applied,
            stale: result.stale,
            slowProcesses: result.slowProcesses,
            processID: batch.processID,
            processLatencyMS: latencyMS,
            attempted: result.attempted,
            completedAt: completedAt
          )
          if result.attempted {
            recordProcessLatencySamples([batch.processID: latencyMS])
          }
        }
      }
    }

    // Entering windows must reach their strip origin before any sibling moves.
    stagingGroup.wait()
    let stagingResult = stagingAccumulator.result
    applied += stagingResult.applied
    stale += stagingResult.stale
    guard isCurrent(generation: frame.generation) else {
      markAnimationFinished(generation: frame.generation, startedAt: preparationStartedAt)
      return (applied, stale + animatedWrites.count, 0)
    }
    if stagingResult.applied < reentryWrites.values.filter(\.positionChanged).count {
      recordAnimationFallback(frame, reason: "reentry-staging", details: "applied=\(stagingResult.applied) expected=\(reentryWrites.values.filter(\.positionChanged).count)")
      let result = applyFrame(frame, progress: 1, skippedProcesses: [])
      markAnimationFinished(generation: frame.generation, startedAt: preparationStartedAt)
      return (applied + result.applied, stale + result.stale, result.frames)
    }
    let startedAt = ProcessInfo.processInfo.systemUptime
    let frameLimit = usesLiveMotionCadence ? nil : intermediateFrameLimits(
      for: interpolatedWrites,
      availableFrames: completedFrameSpringSamples(
        duration: frame.animationDuration, refreshRateHz: frame.refreshRateHz
      ).count,
      refreshRateHz: frame.refreshRateHz
    ).values.min()
    if let frameLimit, frameLimit < 2 {
      recordAnimationFallback(frame, reason: "motion-budget-after-staging", details: "limit=\(frameLimit)")
      let result = applyFrame(frame, progress: 1, skippedProcesses: [])
      markAnimationFinished(generation: frame.generation, startedAt: preparationStartedAt)
      return (applied + result.applied, stale + result.stale, result.frames)
    }
    let availableIntermediateSamples = completedFrameSpringSamples(
      duration: frame.animationDuration,
      refreshRateHz: frame.refreshRateHz,
      initialVelocity: frame.initialProgressVelocity,
      maximumFrames: frameLimit
    )
    let interval = frame.animationDuration / Double(availableIntermediateSamples.count)
    let batches = processWriteBatches(
      loopWrites,
      windowIDs: Set(loopWrites.keys)
    )
    let processQueues = Dictionary(
      uniqueKeysWithValues: batches.map {
        ($0.processID, processWriteQueue(for: $0.processID))
      }
    )
    let clockState = Mutex<AnimationClockState>(AnimationClockState(
      timeline: FrameAnimationClock(
        startedAt: startedAt, interval: interval,
        sampleCount: availableIntermediateSamples.count
      )
    ))
    let laneAccumulator = FrameResultAccumulator()
    let finalGroup = DispatchGroup()

    let clockDone = DispatchSemaphore(value: 0)
    let clock = FrameAnimationDriver(
      interval: interval, refreshInterval: 1 / frame.refreshRateHz,
      displayIDs: frame.displayIDs, queue: animationClockQueue
    ) { [self] driver in
      guard isCurrent(generation: frame.generation) else {
        let shouldSignal = clockState.withLock { state in
          guard !state.finished else { return false }
          state.finished = true
          return true
        }
        if shouldSignal {
          driver.stop()
          clockDone.signal()
        }
        return false
      }
      // Backpressure pauses progress, not just writes. Consuming a spring
      // sample while a lane is busy makes its next accepted position jump.
      guard animationLanesAreReady(processIDs: batches.map(\.processID)) else {
        clockState.withLock { $0.busyLanePulses += 1 }
        return false
      }
      let now = ProcessInfo.processInfo.systemUptime
      let tick = clockState.withLock { state in
        let tick = state.timeline.next(at: now)
        state.maximumLatenessMS = max(
          state.maximumLatenessMS,
          (tick?.lateness ?? 0) * 1_000
        )
        return tick
      }
      guard let tick else {
        let shouldSignal = clockState.withLock { state in
          guard !state.finished else { return false }
          state.finished = true
          return true
        }
        if shouldSignal {
          driver.stop()
          clockDone.signal()
        }
        return false
      }
      let springSample = availableIntermediateSamples[tick.index]
      let submissionStartedAt = ProcessInfo.processInfo.systemUptime
      let submission = submitAnimationSamples(
        batches.map { batch in
          ProcessAnimationSample(
            frame: animatedFrame,
            batch: batch,
            progress: springSample.progress,
            progressVelocity: springSample.velocity,
            intermediate: true,
            stagingReentry: false,
            recordFinalSuccess: false,
            accumulator: laneAccumulator,
            completion: nil,
            laneReady: { [weak driver] in driver?.requestTick(afterLaneCompletion: true) }
          )
        },
        processQueues: processQueues
      )
      let dispatchedAt = ProcessInfo.processInfo.systemUptime
      clockState.withLock { state in
        state.coalescedLaneCount += submission.coalesced
        if submission.submittedIntermediate { state.submittedIntermediateSteps += 1 }
        state.maximumSubmissionMS = max(
          state.maximumSubmissionMS,
          (dispatchedAt - submissionStartedAt) * 1_000
        )
        if let previousDispatchAt = state.previousDispatchAt {
          state.maximumDispatchGapMS = max(
            state.maximumDispatchGapMS,
            (dispatchedAt - previousDispatchAt) * 1_000
          )
        }
        state.previousDispatchAt = dispatchedAt
        state.frames += 1
      }
      if tick.index == availableIntermediateSamples.count - 1 {
        clockState.withLock { $0.finished = true }
        driver.stop()
        clockDone.signal()
      }
      return submission.submittedIntermediate
    }
    defer { clock.stop() }
    // The clock runs independently of AX lanes. Scheduler delay extends the
    // motion; it must not force an abrupt final frame. Supersession stops it
    // on the next tick without waiting for slow applications.
    clockDone.wait()
    animationClockQueue.sync {}
    animationLaneWriteGroup.wait()
    let clockMetrics = clockState.withLock { $0 }
    recordTrace("clock g=\(frame.generation) \(clock.diagnosticSummary) busyPulses=\(clockMetrics.busyLanePulses) laneMs=\(String(format: "%.2f", laneAccumulator.maximumIntermediateLatencyMS))")
    let frames = clockMetrics.frames
    let maximumDispatchGapMS = clockMetrics.maximumDispatchGapMS
    let maximumDisplayWaitMS = clockMetrics.maximumLatenessMS
    let maximumSubmissionMS = clockMetrics.maximumSubmissionMS
    let coalescedLaneCount = clockMetrics.coalescedLaneCount

    guard isCurrent(generation: frame.generation) else {
      animationLaneWriteGroup.wait()
      let laneResult = laneAccumulator.result
      recordAnimationCadence(
        generation: frame.generation,
        frames: frames,
        submittedIntermediateSteps: clockMetrics.submittedIntermediateSteps,
        appliedIntermediateWrites: laneResult.intermediateApplied,
        maximumDispatchGapMS: maximumDispatchGapMS,
        maximumDisplayWaitMS: maximumDisplayWaitMS,
        maximumSubmissionMS: maximumSubmissionMS,
        coalescedLaneCount: coalescedLaneCount
      )
      markAnimationFinished(
        generation: frame.generation,
        startedAt: startedAt
      )
      return (
        applied + laneResult.applied,
        stale + laneResult.stale + animatedWrites.count,
        frames
      )
    }
    let finalSamples = batches.map { batch in
      finalGroup.enter()
      return ProcessAnimationSample(
        frame: animatedFrame,
        batch: batch,
        progress: 1,
        progressVelocity: 0,
        intermediate: false,
        stagingReentry: false,
        recordFinalSuccess: true,
        accumulator: laneAccumulator,
        completion: { finalGroup.leave() }
      )
    }
    _ = submitAnimationSamples(
      finalSamples,
      processQueues: processQueues
    )
    finalGroup.wait()
    let laneResult = laneAccumulator.result
    applied += laneResult.applied
    stale += laneResult.stale
    if !deferredSizeWrites.isEmpty,
      isCurrent(generation: frame.generation)
    {
      let deferredSizeWindowIDs = Set(deferredSizeWrites.keys)
      let committedWindowIDs = commitFinalSizesOnce(
        deferredSizeWrites,
        generation: frame.generation
      )
      lock.lock()
      var successfulWindowIDs = successfulFinalWritesByGeneration[
        frame.generation,
        default: []
      ]
      successfulWindowIDs.subtract(deferredSizeWindowIDs)
      successfulWindowIDs.formUnion(committedWindowIDs)
      successfulFinalWritesByGeneration[frame.generation] = successfulWindowIDs
      lock.unlock()
      publishCompletedBorderGeometry(deferredSizeWrites)
    }
    recordAnimationCadence(
      generation: frame.generation,
      frames: frames + (batches.isEmpty ? 0 : 1),
      submittedIntermediateSteps: clockMetrics.submittedIntermediateSteps,
      appliedIntermediateWrites: laneResult.intermediateApplied,
      maximumDispatchGapMS: maximumDispatchGapMS,
      maximumDisplayWaitMS: maximumDisplayWaitMS,
      maximumSubmissionMS: maximumSubmissionMS,
      coalescedLaneCount: coalescedLaneCount
    )
    markAnimationFinished(
      generation: frame.generation,
      startedAt: startedAt
    )
    if !blockingStaticWrites.isEmpty, isCurrent(generation: frame.generation) {
      let staticFrame = QueuedPositionFrame(
        generation: frame.generation,
        source: frame.source,
        writes: blockingStaticWrites,
        animatedWindowIDs: [],
        animationDuration: 0,
        refreshRateHz: frame.refreshRateHz,
        displayIDs: frame.displayIDs,
        monitorFrames: frame.monitorFrames,
        initialProgressVelocity: 0,
        stagesVisibleBeforeParking: frame.stagesVisibleBeforeParking,
        successfulWrite: frame.successfulWrite,
        completion: nil,
        cursorWarpAfterWindowCommit: frame.cursorWarpAfterWindowCommit
      )
      let result = applyFrame(
        staticFrame,
        progress: 1,
        skippedProcesses: []
      )
      applied += result.applied
      stale += result.stale
    }
    if !deferredParkingWrites.isEmpty, isCurrent(generation: frame.generation) {
      deferParkingWrites(
        deferredParkingWrites,
        from: frame
      )
    }
    let interpolatedFrameCount = frames + (interpolatedWrites.isEmpty ? 0 : 1)
    return (
      applied,
      stale,
      interpolatedFrameCount
    )
  }

  func recordAnimationFallback(_ frame: QueuedPositionFrame, reason: String, details: String) {
    lock.lock()
    appendTraceLocked("animation-fallback g=\(frame.generation) reason=\(reason) \(details)")
    lock.unlock()
  }

  func recordAnimationCadence(
    generation: UInt64,
    frames: Int,
    submittedIntermediateSteps: Int,
    appliedIntermediateWrites: Int,
    maximumDispatchGapMS: Double,
    maximumDisplayWaitMS: Double,
    maximumSubmissionMS: Double,
    coalescedLaneCount: Int
  ) {
    lock.lock()
    appendTraceLocked(
      "cadence g=\(generation) frames=\(frames) submittedSteps=\(submittedIntermediateSteps) appliedIntermediateWrites=\(appliedIntermediateWrites) maxGapMs=\(String(format: "%.2f", maximumDispatchGapMS)) waitMs=\(String(format: "%.2f", maximumDisplayWaitMS)) submitMs=\(String(format: "%.2f", maximumSubmissionMS)) coalesced=\(coalescedLaneCount)"
    )
    lock.unlock()
  }

  /// Border overlays ride the geometry that has actually been written and
  /// accepted - never the interpolated target - so they always match the
  /// displayed window frame.
  func publishCompletedBorderGeometry(
    _ writes: [WindowID: AsyncPositionWrite]
  ) {
    guard let borderLiveGeometryHandler else { return }
    var liveFrames: [WindowID: Rect] = [:]
    for (windowID, _) in writes {
      if let position = completedPosition(for: windowID),
        let size = completedSize(for: windowID) {
        liveFrames[windowID] = Rect(
          x: position.x,
          y: position.y,
          width: size.width,
          height: size.height
        )
      }
    }
    if !liveFrames.isEmpty {
      borderLiveGeometryHandler(liveFrames)
    }
  }

  func markAnimationFinished(
    generation: UInt64,
    startedAt: TimeInterval
  ) {
    let elapsedMS =
      (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    lock.lock()
    activeAnimationRunning = false
    activeAnimatedWindowIDs.removeAll(keepingCapacity: true)
    let settlementWindowIDs = Array(initialSettlementTargets.keys)
    appendTraceLocked(
      "visual-complete g=\(generation) ms=\(String(format: "%.2f", elapsedMS))"
    )
    lock.unlock()
    for windowID in settlementWindowIDs {
      requestInitialSettlementVerification(windowID: windowID)
    }
  }

  func recordRetargetVelocity(
    frame: QueuedPositionFrame,
    progressVelocity: Double,
    windowIDs: Set<WindowID>? = nil
  ) {
    lock.lock()
    guard latestGeneration == frame.generation else {
      lock.unlock()
      return
    }
    for windowID in windowIDs ?? frame.animatedWindowIDs {
      guard let write = frame.writes[windowID] else { continue }
      retargetHorizontalVelocities[windowID] =
        (write.point.x - write.fromPoint.x) * progressVelocity
    }
    lock.unlock()
  }

  func deferParkingWrites(
    _ writes: [WindowID: AsyncPositionWrite],
    from frame: QueuedPositionFrame
  ) {
    let parkingFrame = QueuedPositionFrame(
      generation: frame.generation,
      source: frame.source,
      writes: writes,
      animatedWindowIDs: [],
      animationDuration: 0,
      refreshRateHz: frame.refreshRateHz,
      displayIDs: frame.displayIDs,
      monitorFrames: frame.monitorFrames,
      initialProgressVelocity: 0,
      stagesVisibleBeforeParking: frame.stagesVisibleBeforeParking,
      successfulWrite: frame.successfulWrite,
      completion: nil,
      cursorWarpAfterWindowCommit: frame.cursorWarpAfterWindowCommit
    )
    lock.lock()
    for windowID in writes.keys {
      deferredParkingWriteGenerations[windowID] = frame.generation
    }
    appendTraceLocked(
      "parking-deferred-start g=\(frame.generation) windows=\(writes.count)"
    )
    lock.unlock()
    parkingSettlementGroup.enter()
    parkingSettlementQueue.async { [self] in
      defer { parkingSettlementGroup.leave() }
      let result = applyFrame(
        parkingFrame,
        progress: 1,
        skippedProcesses: [],
        recordFinalSuccess: false
      )
      lock.lock()
      completedWrites += result.applied
      skippedStaleWrites += result.stale
      for windowID in writes.keys
      where deferredParkingWriteGenerations[windowID] == frame.generation {
        deferredParkingWriteGenerations[windowID] = nil
      }
      appendTraceLocked(
        "parking-deferred-complete g=\(frame.generation) applied=\(result.applied) stale=\(result.stale)"
      )
      lock.unlock()
    }
  }
}
