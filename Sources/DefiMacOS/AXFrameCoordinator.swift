import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

final class AXFrameCoordinator: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "com.quentin.defi.ax-frame-coordinator",
    qos: .userInitiated
  )
  private let finalOnlyAnimationQueue = DispatchQueue(
    label: "com.quentin.defi.ax-final-only-animation",
    qos: .userInitiated
  )
  private let lock = NSLock()
  private let accessibilityWriter = AXFrameAccessibilityWriter()
  private var pending: QueuedPositionFrame?
  private var nextGeneration: UInt64 = 0
  private var latestGeneration: UInt64 = 0
  private var running = false
  private var activeAnimationRunning = false
  private var activeAnimatedSizeWindowIDs = Set<WindowID>()
  private var completedWrites = 0
  private var completedAnimatedSizeWrites = 0
  private var skippedStaleWrites = 0
  private var droppedFrameCount = 0
  private var completedPositions: [WindowID: CGPoint] = [:]
  private var completedSizes: [WindowID: CGSize] = [:]
  private var traceEntries: [String] = []
  private var lastFrameDurationMS = 0.0
  private var maximumFrameDurationMS = 0.0
  private var slowFrameCount = 0
  private var lastAnimationFrameCount = 0
  private var lastAnimationDurationMS = 0.0
  private var parkingTargets: [WindowID: AsyncPositionWrite] = [:]
  private var completedParkingChecks = 0
  private var repairedParkingDrifts = 0
  private var initialSettlementTargets: [WindowID: InitialSettlementTarget] = [:]
  private var nextInitialSettlementGeneration: UInt64 = 0
  private var initialSettlementRepairsSuspended = false
  private var pendingInitialSettlementEventChecks = Set<WindowID>()
  private var completedInitialSettlementChecks = 0
  private var repairedInitialSettlementDrifts = 0
  private var predictedProcessLatencyMS: [pid_t: Double] = [:]
  private var latencySensitiveProcessIDs = Set<pid_t>()
  private var processWriteQueues: [pid_t: DispatchQueue] = [:]

  func updateParkingTargets(_ targets: [WindowID: AsyncPositionWrite]) {
    lock.lock()
    parkingTargets = targets
    lock.unlock()
  }

  func updateInitialSettlementTargets(
    _ targets: [WindowID: AsyncPositionWrite],
    deadlines: [WindowID: TimeInterval],
    repairsSuspended: Bool
  ) {
    lock.lock()
    let wasSuspended = initialSettlementRepairsSuspended
    initialSettlementRepairsSuspended = repairsSuspended
    var nextTargets: [WindowID: InitialSettlementTarget] = [:]
    var changedTargets: [(WindowID, InitialSettlementTarget)] = []
    for (windowID, write) in targets {
      guard let deadline = deadlines[windowID] else { continue }
      if let previous = initialSettlementTargets[windowID],
        sameFrameTarget(previous.write, write),
        previous.deadline == deadline
      {
        nextTargets[windowID] = InitialSettlementTarget(
          generation: previous.generation,
          write: write,
          deadline: deadline
        )
      } else {
        nextInitialSettlementGeneration &+= 1
        let target = InitialSettlementTarget(
          generation: nextInitialSettlementGeneration,
          write: write,
          deadline: deadline
        )
        nextTargets[windowID] = target
        changedTargets.append((windowID, target))
      }
    }
    initialSettlementTargets = nextTargets
    if wasSuspended && !repairsSuspended {
      changedTargets = Array(nextTargets)
    }
    lock.unlock()
    for (windowID, target) in changedTargets {
      scheduleInitialSettlementVerification(
        windowID: windowID,
        generation: target.generation,
        deadline: target.deadline
      )
    }
  }

  func suspendInitialSettlementRepairs() {
    lock.lock()
    initialSettlementRepairsSuspended = true
    lock.unlock()
  }

  func requestInitialSettlementVerification(windowID: WindowID) {
    lock.lock()
    guard !initialSettlementRepairsSuspended,
      initialSettlementTargets[windowID] != nil,
      pendingInitialSettlementEventChecks.insert(windowID).inserted
    else {
      lock.unlock()
      return
    }
    lock.unlock()
    queue.async { [weak self] in
      guard let self else { return }
      self.lock.lock()
      self.pendingInitialSettlementEventChecks.remove(windowID)
      self.lock.unlock()
      self.recordTrace("initial-event-check wid=\(windowID.rawValue)")
      self.verifyInitialSettlementTarget(windowID: windowID)
    }
  }

  func invalidate(reason: String) {
    lock.lock()
    nextGeneration &+= 1
    latestGeneration = nextGeneration
    pending = nil
    completedPositions.removeAll(keepingCapacity: true)
    completedSizes.removeAll(keepingCapacity: true)
    parkingTargets.removeAll(keepingCapacity: true)
    initialSettlementTargets.removeAll(keepingCapacity: true)
    initialSettlementRepairsSuspended = false
    pendingInitialSettlementEventChecks.removeAll(keepingCapacity: true)
    appendTraceLocked("invalidate g=\(nextGeneration) reason=\(reason)")
    lock.unlock()
  }

  func invalidateAndWaitForWrites() {
    invalidate(reason: "synchronous-restore")
    queue.sync {}
  }

  func submit(
    _ writes: [WindowID: AsyncPositionWrite],
    source: String,
    animationDuration: TimeInterval = 0,
    refreshRateHz: Double = 60,
    animatedWindowIDs: Set<WindowID> = [],
    stagesVisibleBeforeParking: Bool = false,
    completion: (@Sendable (Bool) -> Void)? = nil
  ) {
    guard !writes.isEmpty else { return }
    lock.lock()
    nextGeneration &+= 1
    latestGeneration = nextGeneration
    if pending != nil {
      droppedFrameCount += 1
    }
    pending = QueuedPositionFrame(
      generation: nextGeneration,
      source: source,
      writes: writes,
      animatedWindowIDs: animatedWindowIDs,
      animationDuration: max(animationDuration, 0),
      refreshRateHz: min(max(refreshRateHz, 30), 120),
      stagesVisibleBeforeParking: stagesVisibleBeforeParking,
      completion: completion
    )
    let animatedIDs = animatedWindowIDs.sorted {
      $0.rawValue < $1.rawValue
    }.map { String($0.rawValue) }.joined(separator: ",")
    let writeIDs = writes.keys.sorted {
      $0.rawValue < $1.rawValue
    }.map { String($0.rawValue) }.joined(separator: ",")
    let parkedCount = writes.values.filter(\.isParked).count
    let durationMS = Int((animationDuration * 1_000).rounded())
    appendTraceLocked(
      "submit g=\(nextGeneration) source=\(source) windows=\(writes.count)[\(writeIDs)] animated=\(animatedWindowIDs.count)[\(animatedIDs)] parked=\(parkedCount) springMs=\(durationMS)"
    )
    let shouldStart = !running
    if shouldStart {
      running = true
    }
    lock.unlock()
    if shouldStart {
      queue.async { [self] in
        drain()
      }
    }
  }

  var isBusy: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running || pending != nil
  }

  var animatedSizeWindowIDs: Set<WindowID> {
    lock.lock()
    defer { lock.unlock() }
    return activeAnimatedSizeWindowIDs
  }

  var isAnimating: Bool {
    lock.lock()
    defer { lock.unlock() }
    return activeAnimationRunning
      || (pending?.animationDuration ?? 0) > 0
  }

  var writeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return completedWrites
  }

  var animatedSizeWriteCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return completedAnimatedSizeWrites
  }

  var staleWriteCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return skippedStaleWrites
  }

  var droppedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return droppedFrameCount
  }

  func completedPosition(for windowID: WindowID) -> CGPoint? {
    lock.lock()
    defer { lock.unlock() }
    return completedPositions[windowID]
  }

  func completedSize(for windowID: WindowID) -> CGSize? {
    lock.lock()
    defer { lock.unlock() }
    return completedSizes[windowID]
  }

  func alignCompletedSize(windowID: WindowID, size: CGSize) {
    lock.lock()
    completedSizes[windowID] = size
    lock.unlock()
  }

  var trace: String {
    lock.lock()
    defer { lock.unlock() }
    return traceEntries.joined(separator: "\n")
  }

  func recordTrace(_ event: String) {
    lock.lock()
    appendTraceLocked(event)
    lock.unlock()
  }

  func recordCommitObservation(
    deferred: Int,
    settled: Int,
    maximumLatencyMS: Double
  ) {
    guard deferred > 0 || settled > 0 else { return }
    lock.lock()
    appendTraceLocked(
      "commit-observed settled=\(settled) deferred=\(deferred) maxMs=\(String(format: "%.2f", maximumLatencyMS))"
    )
    lock.unlock()
  }

  var performance:
    (
      lastDurationMS: Double,
      maximumDurationMS: Double,
      slowFrames: Int,
      animationFrames: Int,
      animationDurationMS: Double
    )
  {
    lock.lock()
    defer { lock.unlock() }
    return (
      lastFrameDurationMS,
      maximumFrameDurationMS,
      slowFrameCount,
      lastAnimationFrameCount,
      lastAnimationDurationMS
    )
  }

  var parkingPerformance: (checks: Int, repairs: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (completedParkingChecks, repairedParkingDrifts)
  }

  var initialSettlementPerformance: (checks: Int, repairs: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (
      completedInitialSettlementChecks,
      repairedInitialSettlementDrifts
    )
  }

  var slowProcessIDs: Set<pid_t> {
    lock.lock()
    defer { lock.unlock() }
    return latencySensitiveProcessIDs
  }

  private func drain() {
    while true {
      lock.lock()
      guard let queuedFrame = pending else {
        running = false
        lock.unlock()
        return
      }
      pending = nil
      let (frame, rebasedWindowCount) =
        rebaseFrameToCompletedPositionsLocked(queuedFrame)
      let applicationCount = Set(frame.writes.values.map(\.processID)).count
      activeAnimationRunning = frame.animationDuration > 0
      activeAnimatedSizeWindowIDs = Set(
        frame.writes.compactMap { windowID, write in
          frame.animatedWindowIDs.contains(windowID) && write.animatesSize
            ? windowID
            : nil
        }
      )
      appendTraceLocked(
        "start g=\(frame.generation) apps=\(applicationCount) rebased=\(rebasedWindowCount)"
      )
      lock.unlock()

      let startedAt = ProcessInfo.processInfo.systemUptime
      let result: (applied: Int, stale: Int, frames: Int)
      if frame.animationDuration > 0 {
        result = animate(frame)
      } else {
        let appliedFrame = applyFrame(
          frame,
          progress: 1,
          skippedProcesses: []
        )
        result = (
          appliedFrame.applied,
          appliedFrame.stale,
          appliedFrame.frames
        )
      }
      let aborted = !isCurrent(generation: frame.generation)
      let elapsedMS =
        (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
      lock.lock()
      completedWrites += result.applied
      skippedStaleWrites += result.stale
      lastFrameDurationMS = elapsedMS
      maximumFrameDurationMS = max(maximumFrameDurationMS, elapsedMS)
      if elapsedMS > 16.67 {
        slowFrameCount += 1
      }
      lastAnimationFrameCount = result.frames
      lastAnimationDurationMS = elapsedMS
      appendTraceLocked(
        "\(aborted ? "abort" : "complete") g=\(frame.generation) applied=\(result.applied) frames=\(result.frames) ms=\(String(format: "%.2f", elapsedMS))"
      )
      activeAnimatedSizeWindowIDs.removeAll(keepingCapacity: true)
      lock.unlock()
      frame.completion?(!aborted)
    }
  }

  private func rebaseFrameToCompletedPositionsLocked(
    _ frame: QueuedPositionFrame
  ) -> (frame: QueuedPositionFrame, count: Int) {
    var writes = frame.writes
    var count = 0
    for (windowID, write) in frame.writes {
      guard !write.isReentering else { continue }
      let completedPoint = completedPositions[windowID]
      let completedSize = completedSizes[windowID]
      let rebasesPosition =
        completedPoint.map {
          accessibilityWriter.pointDistance($0, write.fromPoint) >= 0.5
        } ?? false
      let rebasesSize =
        completedSize.map {
          abs($0.width - write.fromSize.width) >= 0.5
            || abs($0.height - write.fromSize.height) >= 0.5
        } ?? false
      guard rebasesPosition || rebasesSize else { continue }
      writes[windowID] = AsyncPositionWrite(
        element: write.element,
        application: write.application,
        processID: write.processID,
        fromPoint: completedPoint ?? write.fromPoint,
        point: write.point,
        fromSize: completedSize ?? write.fromSize,
        size: write.size,
        positionChanged: write.positionChanged,
        sizeChanged: write.sizeChanged,
        animatesSize: write.animatesSize,
        enhancedUIWasEnabled: write.enhancedUIWasEnabled,
        timeoutSeconds: write.timeoutSeconds,
        isParked: write.isParked,
        isReentering: write.isReentering,
        requiresVerifiedOffscreenWrite: write.requiresVerifiedOffscreenWrite
      )
      count += 1
    }
    guard count > 0 else { return (frame, 0) }
    return (
      QueuedPositionFrame(
        generation: frame.generation,
        source: frame.source,
        writes: writes,
        animatedWindowIDs: frame.animatedWindowIDs,
        animationDuration: frame.animationDuration,
        refreshRateHz: frame.refreshRateHz,
        stagesVisibleBeforeParking: frame.stagesVisibleBeforeParking,
        completion: frame.completion
      ),
      count
    )
  }

  private func animate(
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

  private func markAnimationFinished(
    generation: UInt64,
    startedAt: TimeInterval
  ) {
    let elapsedMS =
      (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    lock.lock()
    activeAnimationRunning = false
    let settlementWindowIDs = Array(initialSettlementTargets.keys)
    appendTraceLocked(
      "visual-complete g=\(generation) ms=\(String(format: "%.2f", elapsedMS))"
    )
    lock.unlock()
    for windowID in settlementWindowIDs {
      requestInitialSettlementVerification(windowID: windowID)
    }
  }

  private func applyFrame(
    _ frame: QueuedPositionFrame,
    progress: Double,
    skippedProcesses: Set<pid_t>,
    intermediate: Bool = false,
    stagingReentry: Bool = false
  ) -> (
    applied: Int,
    stale: Int,
    slowProcesses: Set<pid_t>,
    completionSpreadMS: Double,
    frames: Int
  ) {
    let accumulator = FrameResultAccumulator()
    let parkedWindowIDs = Set(
      frame.writes.compactMap { windowID, write in
        write.isParked ? windowID : nil
      }
    )
    let phases = positionWritePhases(
      windowIDs: Set(frame.writes.keys),
      parkedWindowIDs: parkedWindowIDs,
      stagesVisibleBeforeParking: frame.stagesVisibleBeforeParking
    )
    for phase in phases {
      if frame.stagesVisibleBeforeParking {
        let kind = phase.isSubset(of: parkedWindowIDs) ? "parking" : "visible"
        lock.lock()
        appendTraceLocked(
          "phase g=\(frame.generation) kind=\(kind) windows=\(phase.count)"
        )
        lock.unlock()
      }
      let orderedWrites = frame.writes
        .filter { phase.contains($0.key) }
        .sorted {
          if $0.value.processID != $1.value.processID {
            return $0.value.processID < $1.value.processID
          }
          return $0.key.rawValue < $1.key.rawValue
        }
      let batches = Dictionary(
        grouping: orderedWrites.filter {
          !skippedProcesses.contains($0.value.processID)
        },
        by: \.value.processID
      ).map {
        ProcessWriteBatch(processID: $0.key, writes: $0.value)
      }.sorted { $0.processID < $1.processID }
      let group = DispatchGroup()
      for batch in batches {
        group.enter()
        processWriteQueue(for: batch.processID).async { [self] in
          let batchStartedAt = ProcessInfo.processInfo.systemUptime
          let result = applyBatch(
            batch,
            frame: frame,
            progress: progress,
            intermediate: intermediate,
            stagingReentry: stagingReentry
          )
          let processLatencyMS =
            (ProcessInfo.processInfo.systemUptime - batchStartedAt) * 1_000
          accumulator.add(
            applied: result.applied,
            stale: result.stale,
            slowProcesses: result.slowProcesses,
            processID: batch.processID,
            processLatencyMS: processLatencyMS,
            completedAt: ProcessInfo.processInfo.systemUptime
          )
          group.leave()
        }
      }
      group.wait()
    }
    let result = accumulator.result
    if frame.animationDuration > 0 {
      recordProcessLatencySamples(result.processLatencySamplesMS)
    }
    return (
      result.applied,
      result.stale,
      result.slowProcesses,
      result.completionSpreadMS,
      1
    )
  }

  private func processWriteQueue(for processID: pid_t) -> DispatchQueue {
    lock.lock()
    defer { lock.unlock() }
    if let existing = processWriteQueues[processID] {
      return existing
    }
    let queue = DispatchQueue(
      label: "com.quentin.defi.ax-process-\(processID)",
      qos: .userInteractive,
      autoreleaseFrequency: .workItem
    )
    processWriteQueues[processID] = queue
    return queue
  }

  private func predictedFrameLatency(
    for writes: [WindowID: AsyncPositionWrite]
  ) -> TimeInterval {
    let processIDs = Set(writes.values.map(\.processID))
    lock.lock()
    let maximumMS =
      processIDs.compactMap {
        predictedProcessLatencyMS[$0]
      }.max() ?? 0
    lock.unlock()
    return maximumMS / 1_000
  }

  private func finalOnlyAnimationProcessIDs(
    for writes: [WindowID: AsyncPositionWrite],
    refreshRateHz: Double
  ) -> Set<pid_t> {
    let processIDs = Set(writes.values.map(\.processID))
    lock.lock()
    let predictions = Dictionary(
      uniqueKeysWithValues: processIDs.map { processID in
        (processID, (predictedProcessLatencyMS[processID] ?? 0) / 1_000)
      }
    )
    lock.unlock()
    return Set(
      predictions.compactMap { processID, latency in
        adaptiveIntermediateFrameLimit(
          predictedFrameLatency: latency,
          refreshRateHz: refreshRateHz,
          availableIntermediateFrames: 1
        ) == 0
          ? processID
          : nil
      }
    )
  }

  private func recordProcessLatencySamples(
    _ samplesMS: [pid_t: Double]
  ) {
    lock.lock()
    for (processID, rawSample) in samplesMS {
      let sample = min(max(rawSample, 0), 120)
      let prediction: Double
      if let previous = predictedProcessLatencyMS[processID] {
        let sampleWeight = sample >= previous ? 0.75 : 0.5
        prediction = previous * (1 - sampleWeight) + sample * sampleWeight
      } else {
        prediction = sample
      }
      predictedProcessLatencyMS[processID] = prediction
      let wasSensitive = latencySensitiveProcessIDs.contains(processID)
      let isSensitive = axProcessIsLatencySensitive(
        previouslySensitive: wasSensitive,
        predictedLatencyMS: prediction
      )
      if isSensitive {
        latencySensitiveProcessIDs.insert(processID)
      } else {
        latencySensitiveProcessIDs.remove(processID)
      }
      if isSensitive != wasSensitive {
        let state = isSensitive ? "enter" : "exit"
        let predictionText = String(format: "%.2f", prediction)
        appendTraceLocked(
          "slow-lane pid=\(processID) state=\(state) predictedMs=\(predictionText)"
        )
      }
    }
    lock.unlock()
  }

  private func applyBatch(
    _ batch: ProcessWriteBatch,
    frame: QueuedPositionFrame,
    progress: Double,
    intermediate: Bool,
    stagingReentry: Bool
  ) -> (applied: Int, stale: Int, slowProcesses: Set<pid_t>) {
    var applied = 0
    var stale = 0
    var slowProcesses = Set<pid_t>()
    for (index, item) in batch.writes.enumerated() {
      guard isCurrent(generation: frame.generation) else {
        stale += batch.writes.count - index
        break
      }
      let interpolated = interpolatedFrame(
        from: Rect(
          x: item.value.fromPoint.x,
          y: item.value.fromPoint.y,
          width: item.value.fromSize.width,
          height: item.value.fromSize.height
        ),
        to: Rect(
          x: item.value.point.x,
          y: item.value.point.y,
          width: item.value.size.width,
          height: item.value.size.height
        ),
        progress: progress
      )
      let point = CGPoint(x: interpolated.x, y: interpolated.y)
      let size = CGSize(
        width: interpolated.width,
        height: interpolated.height
      )
      let writeStartedAt = ProcessInfo.processInfo.systemUptime
      let intermediateTimeout: Float = item.value.animatesSize ? 0.016 : 0.006
      let timeout =
        intermediate
        ? min(item.value.timeoutSeconds, intermediateTimeout)
        : max(item.value.timeoutSeconds, 0.016)
      AXUIElementSetMessagingTimeout(item.value.application, timeout)
      AXUIElementSetMessagingTimeout(item.value.element, timeout)
      let timeoutConfiguredAt = ProcessInfo.processInfo.systemUptime
      let sizeApplied =
        !item.value.animatesSize
        || accessibilityWriter.applySize(item.value, size: size)
      let positionApplied =
        !item.value.positionChanged
        || accessibilityWriter.applyPosition(
          item.value,
          point: point,
          forceOffscreenAccess: (stagingReentry && item.value.isReentering)
            || (!intermediate && item.value.requiresVerifiedOffscreenWrite),
          suppressNativeAnimation: suppressesNativePositionAnimation(
            stagesVisibleBeforeParking: frame.stagesVisibleBeforeParking,
            isParked: item.value.isParked,
            isIntermediate: intermediate
          )
        )
      let appliedWrite = sizeApplied && positionApplied
      let positionAppliedAt = ProcessInfo.processInfo.systemUptime
      AXUIElementSetMessagingTimeout(item.value.element, 0)
      AXUIElementSetMessagingTimeout(item.value.application, 0)
      let timeoutResetAt = ProcessInfo.processInfo.systemUptime
      let writeElapsedMS =
        (timeoutResetAt - writeStartedAt) * 1_000
      guard isCurrent(generation: frame.generation) else {
        stale += 1
        lock.lock()
        appendTraceLocked(
          "stale-completion g=\(frame.generation) pid=\(item.value.processID) wid=\(item.key.rawValue) applied=\(appliedWrite ? 1 : 0) ms=\(String(format: "%.2f", writeElapsedMS))"
        )
        lock.unlock()
        continue
      }
      let requiresReadback =
        item.value.isParked
        || item.value.requiresVerifiedOffscreenWrite
      if positionApplied, item.value.positionChanged {
        applied += 1
        let completedPoint =
          requiresReadback
          ? accessibilityWriter.readPosition(item.value.element) ?? point
          : point
        recordCompletedPosition(completedPoint, windowID: item.key)
      }
      if sizeApplied, item.value.animatesSize {
        recordCompletedSize(
          size,
          windowID: item.key,
          incrementWriteCount: true
        )
      }
      if requiresReadback, !intermediate {
        scheduleParkingVerification(
          windowID: item.key,
          expectedPoint: item.value.point
        )
      }
      if intermediate && (!appliedWrite || writeElapsedMS > 12) {
        slowProcesses.insert(item.value.processID)
      }
      if writeElapsedMS > 16.67 {
        lock.lock()
        appendTraceLocked(
          "slow g=\(frame.generation) pid=\(item.value.processID) windows=1 ms=\(String(format: "%.2f", writeElapsedMS)) setup=\(String(format: "%.2f", (timeoutConfiguredAt - writeStartedAt) * 1_000)) position=\(String(format: "%.2f", (positionAppliedAt - timeoutConfiguredAt) * 1_000)) reset=\(String(format: "%.2f", (timeoutResetAt - positionAppliedAt) * 1_000))"
        )
        lock.unlock()
      }
    }
    return (applied, stale, slowProcesses)
  }

  private func recordCompletedSize(
    _ size: CGSize,
    windowID: WindowID,
    incrementWriteCount: Bool
  ) {
    lock.lock()
    completedSizes[windowID] = size
    if incrementWriteCount {
      completedAnimatedSizeWrites += 1
    }
    lock.unlock()
  }

  private func scheduleParkingVerification(
    windowID: WindowID,
    expectedPoint: CGPoint
  ) {
    for delay in [0.4, 1.4] {
      queue.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.verifyParkingTarget(
          windowID: windowID,
          expectedPoint: expectedPoint
        )
      }
    }
  }

  private func scheduleInitialSettlementVerification(
    windowID: WindowID,
    generation: UInt64,
    deadline: TimeInterval
  ) {
    for delay in [0.12, 0.25, 0.45, 0.75, 1.1, 1.5, 2.1] {
      queue.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.verifyInitialSettlementTarget(windowID: windowID)
      }
    }
    let expirationDelay = max(
      deadline - ProcessInfo.processInfo.systemUptime,
      0
    )
    queue.asyncAfter(deadline: .now() + expirationDelay) { [weak self] in
      self?.clearInitialSettlementTarget(
        windowID: windowID,
        matchingGeneration: generation
      )
    }
  }

  private func verifyInitialSettlementTarget(windowID: WindowID) {
    let leftMouseButtonDown = CGEventSource.buttonState(
      .combinedSessionState,
      button: .left
    )
    lock.lock()
    guard let settlementTarget = initialSettlementTargets[windowID],
      ProcessInfo.processInfo.systemUptime < settlementTarget.deadline,
      initialSettlementRepairIsCurrent(
        expectedGeneration: settlementTarget.generation,
        currentGeneration: settlementTarget.generation,
        repairsSuspended: initialSettlementRepairsSuspended,
        leftMouseButtonDown: leftMouseButtonDown,
        animationRunning: activeAnimationRunning
          || (pending?.animationDuration ?? 0) > 0
      )
    else {
      lock.unlock()
      return
    }
    let write = settlementTarget.write
    lock.unlock()

    AXUIElementSetMessagingTimeout(write.application, 0.025)
    AXUIElementSetMessagingTimeout(write.element, 0.025)
    defer {
      AXUIElementSetMessagingTimeout(write.element, 0)
      AXUIElementSetMessagingTimeout(write.application, 0)
    }
    guard let actualPosition = accessibilityWriter.readPosition(write.element),
      let actualSize = accessibilityWriter.readSize(write.element)
    else {
      return
    }
    let actual = Rect(
      x: actualPosition.x,
      y: actualPosition.y,
      width: actualSize.width,
      height: actualSize.height
    )
    let target = Rect(
      x: write.point.x,
      y: write.point.y,
      width: write.size.width,
      height: write.size.height
    )
    lock.lock()
    completedInitialSettlementChecks += 1
    lock.unlock()
    switch initialSettlementObservation(
      actual: actual,
      target: target,
      now: ProcessInfo.processInfo.systemUptime,
      deadline: settlementTarget.deadline
    ) {
    case .expired:
      clearInitialSettlementTarget(
        windowID: windowID,
        matchingGeneration: settlementTarget.generation
      )
      return
    case .stable:
      return
    case .drifted:
      break
    }
    guard isInitialSettlementTargetCurrent(
      windowID: windowID,
      generation: settlementTarget.generation
    ) else { return }

    let sizeChanged = abs(actual.width - target.width) > 1
      || abs(actual.height - target.height) > 1
    let positionChanged = abs(actual.x - target.x) > 1
      || abs(actual.y - target.y) > 1
    if sizeChanged {
      guard isInitialSettlementTargetCurrent(
        windowID: windowID,
        generation: settlementTarget.generation
      ), accessibilityWriter.applySize(write, size: write.size)
      else { return }
    }
    if positionChanged {
      guard isInitialSettlementTargetCurrent(
        windowID: windowID,
        generation: settlementTarget.generation
      ), accessibilityWriter.applyPosition(write, point: write.point)
      else { return }
    }
    guard isInitialSettlementTargetCurrent(
      windowID: windowID,
      generation: settlementTarget.generation
    ) else {
      requestInitialSettlementVerification(windowID: windowID)
      return
    }
    if positionChanged {
      recordCompletedPosition(write.point, windowID: windowID)
    }
    if sizeChanged {
      recordCompletedSize(
        write.size,
        windowID: windowID,
        incrementWriteCount: true
      )
    }
    lock.lock()
    repairedInitialSettlementDrifts += 1
    appendTraceLocked(
      "initial-repair wid=\(windowID.rawValue) dx=\(String(format: "%.1f", actual.x - target.x)) dy=\(String(format: "%.1f", actual.y - target.y)) dw=\(String(format: "%.1f", actual.width - target.width)) dh=\(String(format: "%.1f", actual.height - target.height))"
    )
    lock.unlock()
  }

  private func clearInitialSettlementTarget(
    windowID: WindowID,
    matchingGeneration expectedGeneration: UInt64
  ) {
    lock.lock()
    if initialSettlementTargets[windowID]?.generation == expectedGeneration {
      initialSettlementTargets[windowID] = nil
    }
    lock.unlock()
  }

  private func isInitialSettlementTargetCurrent(
    windowID: WindowID,
    generation: UInt64
  ) -> Bool {
    let leftMouseButtonDown = CGEventSource.buttonState(
      .combinedSessionState,
      button: .left
    )
    lock.lock()
    defer { lock.unlock() }
    guard let currentTarget = initialSettlementTargets[windowID],
      ProcessInfo.processInfo.systemUptime < currentTarget.deadline
    else {
      return false
    }
    return initialSettlementRepairIsCurrent(
      expectedGeneration: generation,
      currentGeneration: currentTarget.generation,
      repairsSuspended: initialSettlementRepairsSuspended,
      leftMouseButtonDown: leftMouseButtonDown,
      animationRunning: activeAnimationRunning
        || (pending?.animationDuration ?? 0) > 0
    )
  }

  private func sameFrameTarget(
    _ lhs: AsyncPositionWrite,
    _ rhs: AsyncPositionWrite
  ) -> Bool {
    accessibilityWriter.pointDistance(lhs.point, rhs.point) <= 0.1
      && abs(lhs.size.width - rhs.size.width) <= 0.1
      && abs(lhs.size.height - rhs.size.height) <= 0.1
  }

  private func verifyParkingTarget(
    windowID: WindowID,
    expectedPoint: CGPoint
  ) {
    lock.lock()
    guard let write = parkingTargets[windowID],
      accessibilityWriter.pointDistance(write.point, expectedPoint) <= 0.1
    else {
      lock.unlock()
      return
    }
    lock.unlock()
    guard let actual = accessibilityWriter.readPosition(write.element) else { return }
    lock.lock()
    completedParkingChecks += 1
    lock.unlock()
    guard accessibilityWriter.pointDistance(actual, expectedPoint) > 1 else { return }
    guard
      accessibilityWriter.applyPosition(
        write,
        point: expectedPoint,
        forceOffscreenAccess: write.requiresVerifiedOffscreenWrite
      )
    else {
      return
    }
    let repaired = accessibilityWriter.readPosition(write.element) ?? expectedPoint
    recordCompletedPosition(repaired, windowID: windowID)
    lock.lock()
    repairedParkingDrifts += 1
    appendTraceLocked(
      "parking-repair wid=\(windowID.rawValue) sliver=\(write.requiresVerifiedOffscreenWrite ? 1 : 0) dx=\(String(format: "%.1f", actual.x - expectedPoint.x)) dy=\(String(format: "%.1f", actual.y - expectedPoint.y))"
    )
    lock.unlock()
  }

  private func isCurrent(generation: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return latestGeneration == generation
  }

  private func recordCompletedPosition(
    _ point: CGPoint,
    windowID: WindowID
  ) {
    lock.lock()
    completedPositions[windowID] = point
    lock.unlock()
  }

  private func appendTraceLocked(_ event: String) {
    let uptime = ProcessInfo.processInfo.systemUptime
    traceEntries.append(String(format: "%.6f %@", uptime, event))
    if traceEntries.count > 96 {
      traceEntries.removeFirst(traceEntries.count - 96)
    }
  }

}
