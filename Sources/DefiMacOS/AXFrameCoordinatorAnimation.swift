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
  var previousDispatchAt: TimeInterval?
  var maximumDispatchGapMS = 0.0
  var maximumLatenessMS = 0.0
  var maximumSubmissionMS = 0.0
  var coalescedLaneCount = 0
  var finalizedProcessIDs: Set<pid_t> = []
  var finished = false
}

extension AXFrameCoordinator {
  func animate(
    _ frame: QueuedPositionFrame
  ) -> (applied: Int, stale: Int, frames: Int) {
    let animatedWrites = frame.writes.filter {
      frame.animatedWindowIDs.contains($0.key)
    }
    let staticWrites = frame.writes.filter {
      !animatedWrites.keys.contains($0.key)
    }
    let deferredParkingWrites = staticWrites.filter { $0.value.isParked }
    let blockingStaticWrites = staticWrites.filter { !$0.value.isParked }
    let finalOnlyProcessIDs = finalOnlyAnimationProcessIDs(
      for: animatedWrites,
      animationDuration: frame.animationDuration,
      refreshRateHz: frame.refreshRateHz
    )
    let lanePlan = frameAnimationLanePlan(
      animatedWindowIDs: Set(animatedWrites.keys),
      processIDs: animatedWrites.mapValues(\.processID),
      reenteringWindowIDs: Set(
        animatedWrites.compactMap { windowID, write in
          write.isReentering ? windowID : nil
        }
      ),
      finalOnlyProcessIDs: finalOnlyProcessIDs,
      horizontallyMovingResizeWindowIDs: Set(
        animatedWrites.compactMap { windowID, write in
          asynchronousSizeWriteIsRequired(
            sizeChanged: write.sizeChanged,
            synchronousWriteSucceeded: write.synchronousSizeWriteSucceeded,
            animatesSize: write.animatesSize
          ) && abs(write.fromPoint.x - write.point.x) >= 0.5
            ? windowID
            : nil
        }
      )
    )
    let interpolatedWrites = animatedWrites.filter {
      lanePlan.interpolatedWindowIDs.contains($0.key)
    }
    let finalOnlyWrites = animatedWrites.filter {
      lanePlan.finalOnlyWindowIDs.contains($0.key)
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
      initialProgressVelocity: frame.initialProgressVelocity,
      stagesVisibleBeforeParking: frame.stagesVisibleBeforeParking,
      successfulWrite: frame.successfulWrite,
      completion: nil,
      cursorWarpAfterWindowCommit: frame.cursorWarpAfterWindowCommit
    )
    let finalOnlyFrame = QueuedPositionFrame(
      generation: frame.generation,
      source: frame.source,
      writes: finalOnlyWrites,
      animatedWindowIDs: lanePlan.finalOnlyWindowIDs,
      animationDuration: frame.animationDuration,
      refreshRateHz: frame.refreshRateHz,
      displayIDs: frame.displayIDs,
      initialProgressVelocity: 0,
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

    let startedAt = ProcessInfo.processInfo.systemUptime
    let interval = 1 / frame.refreshRateHz
    let availableIntermediateSamples = completedFrameSpringSamples(
      duration: frame.animationDuration,
      refreshRateHz: frame.refreshRateHz,
      initialVelocity: frame.initialProgressVelocity
    )
    let batches = processWriteBatches(
      loopWrites,
      windowIDs: Set(loopWrites.keys)
    )
    let processQueues = Dictionary(
      uniqueKeysWithValues: batches.map {
        ($0.processID, processWriteQueue(for: $0.processID))
      }
    )
    let finalSubmissionDelayByProcess = Dictionary(
      uniqueKeysWithValues: batches.map { batch in
        let writes = Dictionary(uniqueKeysWithValues: batch.writes)
        return (
          batch.processID,
          anticipatedFinalFrameDispatchDelay(
            animationDuration: frame.animationDuration,
            predictedFrameLatency: predictedFrameLatency(for: writes)
          )
        )
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

    let finalOnlyGroup = DispatchGroup()
    let finalOnlyResultStore = ConcurrentFrameResultStore()
    if !finalOnlyWrites.isEmpty {
      finalOnlyGroup.enter()
      finalOnlyAnimationQueue.async { [self] in
        defer { finalOnlyGroup.leave() }
        let result = applyFrame(
          finalOnlyFrame,
          progress: 1,
          skippedProcesses: [],
          stagingReentry: !lanePlan.stagedFinalOnlyReentryWindowIDs.isEmpty
        )
        finalOnlyResultStore.store(
          ConcurrentFrameResult(
            applied: result.applied,
            stale: result.stale,
            completionSpreadMS: result.completionSpreadMS,
            frames: result.frames
          )
        )
      }
      lock.lock()
      appendTraceLocked(
        "final-only-start g=\(frame.generation) processes=\(finalOnlyProcessIDs.count) windows=\(finalOnlyWrites.count) reentry=\(lanePlan.stagedFinalOnlyReentryWindowIDs.count)"
      )
      lock.unlock()
    }

    let clockDone = DispatchSemaphore(value: 0)
    let intervalNanoseconds = max(
      Int((interval * 1_000_000_000).rounded()),
      1
    )
    let clock = DispatchSource.makeTimerSource(
      flags: .strict,
      queue: animationClockQueue
    )
    clock.schedule(
      deadline: .now() + .nanoseconds(intervalNanoseconds),
      repeating: .nanoseconds(intervalNanoseconds),
      leeway: .microseconds(100)
    )
    clock.setEventHandler { [self] in
      guard isCurrent(generation: frame.generation) else {
        let shouldSignal = clockState.withLock { state in
          guard !state.finished else { return false }
          state.finished = true
          return true
        }
        if shouldSignal {
          clock.cancel()
          clockDone.signal()
        }
        return
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
          clock.cancel()
          clockDone.signal()
        }
        return
      }
      let springSample = availableIntermediateSamples[tick.index]
      let elapsed = tick.elapsed
      let (finalBatches, finalizedProcessIDs) = clockState.withLock { state in
        let due = batches.filter {
          !state.finalizedProcessIDs.contains($0.processID)
            && elapsed >= (finalSubmissionDelayByProcess[$0.processID] ?? .infinity)
        }
        state.finalizedProcessIDs.formUnion(due.map(\.processID))
        return (due, state.finalizedProcessIDs)
      }
      let intermediateBatches = batches.filter { batch in
        !finalizedProcessIDs.contains(batch.processID)
      }
      let submissionStartedAt = ProcessInfo.processInfo.systemUptime
      for _ in finalBatches {
        finalGroup.enter()
      }
      let coalesced = submitAnimationSamples(
        intermediateBatches.map { batch in
          ProcessAnimationSample(
            frame: animatedFrame,
            batch: batch,
            progress: springSample.progress,
            progressVelocity: springSample.velocity,
            intermediate: true,
            stagingReentry: false,
            recordFinalSuccess: false,
            accumulator: laneAccumulator,
            completion: nil
          )
        } + finalBatches.map { batch in
          ProcessAnimationSample(
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
        },
        processQueues: processQueues
      )
      let dispatchedAt = ProcessInfo.processInfo.systemUptime
      clockState.withLock { state in
        state.coalescedLaneCount += coalesced
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
    }
    clock.resume()
    // The clock runs independently of AX lanes. Scheduler delay extends the
    // motion; it must not force an abrupt final frame. Supersession stops it
    // on the next tick without waiting for slow applications.
    clockDone.wait()
    animationClockQueue.sync {}
    stagingGroup.wait()
    let stagingResult = stagingAccumulator.result
    applied += stagingResult.applied
    stale += stagingResult.stale
    let clockMetrics = clockState.withLock { $0 }
    let frames = clockMetrics.frames
    let maximumDispatchGapMS = clockMetrics.maximumDispatchGapMS
    let maximumDisplayWaitMS = clockMetrics.maximumLatenessMS
    let maximumSubmissionMS = clockMetrics.maximumSubmissionMS
    let coalescedLaneCount = clockMetrics.coalescedLaneCount

    guard isCurrent(generation: frame.generation) else {
      animationLaneWriteGroup.wait()
      finalOnlyGroup.wait()
      let laneResult = laneAccumulator.result
      recordAnimationCadence(
        generation: frame.generation,
        frames: frames,
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
    let remainingBatches = clockState.withLock { state in
      let remaining = batches.filter {
        !state.finalizedProcessIDs.contains($0.processID)
      }
      state.finalizedProcessIDs.formUnion(remaining.map(\.processID))
      return remaining
    }
    let finalSamples = remainingBatches.map { batch in
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
    finalOnlyGroup.wait()
    let finalOnlyResult = finalOnlyResultStore.result
    if let finalOnlyResult {
      applied += finalOnlyResult.applied
      stale += finalOnlyResult.stale
      lock.lock()
      appendTraceLocked(
        "final-only-complete g=\(frame.generation) applied=\(finalOnlyResult.applied) spread=\(String(format: "%.2f", finalOnlyResult.completionSpreadMS)) reentry=\(lanePlan.stagedFinalOnlyReentryWindowIDs.count)"
      )
      lock.unlock()
    }
    recordAnimationCadence(
      generation: frame.generation,
      frames: frames + (batches.isEmpty ? 0 : 1),
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
      max(interpolatedFrameCount, finalOnlyResult?.frames ?? 0)
    )
  }

  func recordAnimationCadence(
    generation: UInt64,
    frames: Int,
    maximumDispatchGapMS: Double,
    maximumDisplayWaitMS: Double,
    maximumSubmissionMS: Double,
    coalescedLaneCount: Int
  ) {
    lock.lock()
    appendTraceLocked(
      "cadence g=\(generation) frames=\(frames) maxGapMs=\(String(format: "%.2f", maximumDispatchGapMS)) waitMs=\(String(format: "%.2f", maximumDisplayWaitMS)) submitMs=\(String(format: "%.2f", maximumSubmissionMS)) coalesced=\(coalescedLaneCount)"
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
