import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog


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
    let finalOnlyProcessIDs = finalOnlyAnimationProcessIDs(
      for: animatedWrites,
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
      finalOnlyProcessIDs: finalOnlyProcessIDs
    )
    let interpolatedWrites = animatedWrites.filter {
      lanePlan.interpolatedWindowIDs.contains($0.key)
    }
    let finalOnlyWrites = animatedWrites.filter {
      lanePlan.finalOnlyWindowIDs.contains($0.key)
    }
    let animatedFrame = QueuedPositionFrame(
      generation: frame.generation,
      source: frame.source,
      writes: interpolatedWrites,
      animatedWindowIDs: lanePlan.interpolatedWindowIDs,
      animationDuration: frame.animationDuration,
      refreshRateHz: frame.refreshRateHz,
      stagesVisibleBeforeParking: frame.stagesVisibleBeforeParking,
      completion: nil
    )
    let finalOnlyFrame = QueuedPositionFrame(
      generation: frame.generation,
      source: frame.source,
      writes: finalOnlyWrites,
      animatedWindowIDs: lanePlan.finalOnlyWindowIDs,
      animationDuration: frame.animationDuration,
      refreshRateHz: frame.refreshRateHz,
      stagesVisibleBeforeParking: frame.stagesVisibleBeforeParking,
      completion: nil
    )
    let startedAt = ProcessInfo.processInfo.systemUptime
    let interval = 1 / frame.refreshRateHz
    let intermediateBudget = max(
      frame.animationDuration * 1.5,
      interval * 2
    )
    let availableIntermediateProgresses = completedFrameSpringProgresses(
      duration: frame.animationDuration,
      refreshRateHz: frame.refreshRateHz
    )
    let maximumIntermediateFrames = min(
      availableIntermediateProgresses.count,
      3
    )
    let initialPredictedLatency = predictedFrameLatency(
      for: interpolatedWrites
    )
    var intermediateFrameLimit =
      interpolatedWrites.isEmpty
      ? 0
      : adaptiveIntermediateFrameLimit(
        predictedFrameLatency: initialPredictedLatency,
        refreshRateHz: frame.refreshRateHz,
        availableIntermediateFrames: maximumIntermediateFrames
      )
    if !interpolatedWrites.isEmpty,
      intermediateFrameLimit < maximumIntermediateFrames
    {
      lock.lock()
      appendTraceLocked(
        "quality g=\(frame.generation) predictedMs=\(String(format: "%.2f", initialPredictedLatency * 1_000)) intermediates=\(intermediateFrameLimit)"
      )
      lock.unlock()
    }
    var nextDeadline = startedAt
    var applied = 0
    var stale = 0
    var frames = 0
    var nextProgressIndex = 0
    var lastCompletedFrameDuration = 0.0

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

    let reentryWrites = interpolatedWrites.filter { $0.value.isReentering }
    while frames < intermediateFrameLimit
      && nextProgressIndex < availableIntermediateProgresses.count
      && isCurrent(generation: frame.generation)
    {
      let remaining = nextDeadline - ProcessInfo.processInfo.systemUptime
      if remaining > 0 {
        spinWaitPrecisely(for: remaining)
      }
      let now = ProcessInfo.processInfo.systemUptime
      let elapsed = now - startedAt
      let predictedLatency = predictedFrameLatency(for: interpolatedWrites)
      if frames > 0,
        !completedFrameSupportsAnotherSample(
          duration: lastCompletedFrameDuration,
          refreshRateHz: frame.refreshRateHz
        )
      {
        break
      }
      if !shouldEmitAnotherIntermediateFrame(
        elapsed: elapsed,
        predictedFrameLatency: predictedLatency,
        budget: intermediateBudget,
        completedIntermediateFrames: frames
      ) {
        break
      }
      guard
        let progressIndex = anticipatedSpringProgressIndex(
          predictedFrameLatency: predictedLatency,
          refreshRateHz: frame.refreshRateHz,
          availableIntermediateFrames: availableIntermediateProgresses.count,
          minimumIndex: nextProgressIndex,
          maximumIndex: frames == 0 ? 1 : nil
        )
      else {
        break
      }
      let springProgress = availableIntermediateProgresses[progressIndex]
      nextProgressIndex = progressIndex + 1
      let applyStartedAt = ProcessInfo.processInfo.systemUptime
      let result = applyFrame(
        animatedFrame,
        progress: springProgress,
        skippedProcesses: [],
        intermediate: true,
        stagingReentry: frames == 0 && !reentryWrites.isEmpty
      )
      applied += result.applied
      stale += result.stale
      frames += 1
      let applyDurationMS =
        (ProcessInfo.processInfo.systemUptime - applyStartedAt) * 1_000
      let frameCompletedAt = ProcessInfo.processInfo.systemUptime
      lastCompletedFrameDuration = applyDurationMS / 1_000
      if frames == 1,
        intermediateFrameLimit < maximumIntermediateFrames,
        completedFrameSupportsAnotherSample(
          duration: lastCompletedFrameDuration,
          refreshRateHz: frame.refreshRateHz
        )
      {
        intermediateFrameLimit = maximumIntermediateFrames
        lock.lock()
        appendTraceLocked(
          "quality-recovered g=\(frame.generation) actualMs=\(String(format: "%.2f", applyDurationMS)) intermediates=\(intermediateFrameLimit)"
        )
        lock.unlock()
      }
      lock.lock()
      appendTraceLocked(
        "sample g=\(frame.generation) i=\(frames) pi=\(progressIndex) p=\(String(format: "%.3f", springProgress)) applied=\(result.applied) spread=\(String(format: "%.2f", result.completionSpreadMS)) ms=\(String(format: "%.2f", applyDurationMS)) reentry=\(frames == 1 ? reentryWrites.count : 0)"
      )
      lock.unlock()
      nextDeadline = nextCompletedFrameDispatchDeadline(
        completedAt: frameCompletedAt,
        refreshRateHz: frame.refreshRateHz
      )
    }

    guard isCurrent(generation: frame.generation) else {
      finalOnlyGroup.wait()
      markAnimationFinished(
        generation: frame.generation,
        startedAt: startedAt
      )
      return (applied, stale + animatedWrites.count, frames)
    }
    let finalDispatchDelay =
      intermediateFrameLimit == 0
      ? 0
      : anticipatedFinalFrameDispatchDelay(
        animationDuration: frame.animationDuration,
        predictedFrameLatency: predictedFrameLatency(for: interpolatedWrites)
      )
    let finalDeadline = max(
      startedAt + finalDispatchDelay,
      frames > 0 ? nextDeadline : startedAt
    )
    let finalRemaining =
      finalDeadline - ProcessInfo.processInfo.systemUptime
    if finalRemaining > 0 {
      spinWaitPrecisely(for: finalRemaining)
    }
    guard isCurrent(generation: frame.generation) else {
      finalOnlyGroup.wait()
      markAnimationFinished(
        generation: frame.generation,
        startedAt: startedAt
      )
      return (applied, stale + animatedWrites.count, frames)
    }
    if !interpolatedWrites.isEmpty {
      let finalStartedAt = ProcessInfo.processInfo.systemUptime
      let final = applyFrame(
        animatedFrame,
        progress: 1,
        skippedProcesses: []
      )
      applied += final.applied
      stale += final.stale
      let finalDurationMS =
        (ProcessInfo.processInfo.systemUptime - finalStartedAt) * 1_000
      lock.lock()
      appendTraceLocked(
        "sample g=\(frame.generation) i=final p=1.000 applied=\(final.applied) spread=\(String(format: "%.2f", final.completionSpreadMS)) ms=\(String(format: "%.2f", finalDurationMS)) reentry=0"
      )
      lock.unlock()
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
    markAnimationFinished(
      generation: frame.generation,
      startedAt: startedAt
    )
    if !staticWrites.isEmpty, isCurrent(generation: frame.generation) {
      let staticFrame = QueuedPositionFrame(
        generation: frame.generation,
        source: frame.source,
        writes: staticWrites,
        animatedWindowIDs: [],
        animationDuration: 0,
        refreshRateHz: frame.refreshRateHz,
        stagesVisibleBeforeParking: frame.stagesVisibleBeforeParking,
        completion: nil
      )
      let result = applyFrame(
        staticFrame,
        progress: 1,
        skippedProcesses: []
      )
      applied += result.applied
      stale += result.stale
    }
    let interpolatedFrameCount = frames + (interpolatedWrites.isEmpty ? 0 : 1)
    return (
      applied,
      stale,
      max(interpolatedFrameCount, finalOnlyResult?.frames ?? 0)
    )
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
}
