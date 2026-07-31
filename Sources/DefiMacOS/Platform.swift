import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

private let frameCommitLogger = Logger(
  subsystem: "com.quentin.defi",
  category: "FrameCommit"
)

private let animationMachTimebase: mach_timebase_info_data_t = {
  var timebase = mach_timebase_info_data_t()
  mach_timebase_info(&timebase)
  return timebase
}()

private func spinWaitPrecisely(for duration: TimeInterval) {
  guard duration > 0 else { return }
  let nanoseconds = duration * 1_000_000_000
  let ticks = UInt64(
    nanoseconds
      * Double(animationMachTimebase.denom)
      / Double(animationMachTimebase.numer)
  )
  let deadline = mach_absolute_time() &+ ticks
  while mach_absolute_time() < deadline {}
}

struct FrameCommitExpectation: Equatable, Sendable {
  let from: Rect
  let target: Rect
  let issuedAt: TimeInterval
  let deadline: TimeInterval
  var observedAt: TimeInterval?
}

func frameIsOnExpectedCommitPath(
  actual: Rect,
  currentTarget: Rect,
  expectation: FrameCommitExpectation,
  now: TimeInterval,
  leftMouseButtonDown: Bool,
  tolerance: Double = 3
) -> Bool {
  guard !leftMouseButtonDown,
    now < expectation.deadline,
    frameDistance(currentTarget, expectation.target) <= tolerance
  else {
    return false
  }
  return [
    (actual.x, expectation.from.x, expectation.target.x),
    (actual.y, expectation.from.y, expectation.target.y),
    (actual.width, expectation.from.width, expectation.target.width),
    (actual.height, expectation.from.height, expectation.target.height),
  ].allSatisfy { value, from, target in
    value >= min(from, target) - tolerance
      && value <= max(from, target) + tolerance
  }
}

func requiresVerifiedOffscreenWrite(
  frame: Rect,
  monitorFrames: [Rect],
  maximumVisibleWidth: Double = parkedSliverWidth + 0.5
) -> Bool {
  let visibleWidth = monitorFrames.reduce(0.0) { currentMaximum, monitor in
    let verticalIntersection = max(
      min(frame.y + frame.height, monitor.y + monitor.height)
        - max(frame.y, monitor.y),
      0
    )
    guard verticalIntersection > 0 else { return currentMaximum }
    let horizontalIntersection = max(
      min(frame.x + frame.width, monitor.x + monitor.width)
        - max(frame.x, monitor.x),
      0
    )
    return max(currentMaximum, horizontalIntersection)
  }
  return visibleWidth <= maximumVisibleWidth
}

private struct AsyncPositionWrite: @unchecked Sendable {
  let element: AXUIElement
  let application: AXUIElement
  let processID: pid_t
  let fromPoint: CGPoint
  let point: CGPoint
  let size: CGSize
  let enhancedUIWasEnabled: Bool
  let timeoutSeconds: Float
  let isParked: Bool
  let isReentering: Bool
  let requiresVerifiedOffscreenWrite: Bool
}

private struct QueuedPositionFrame: @unchecked Sendable {
  let generation: UInt64
  let source: String
  let writes: [WindowID: AsyncPositionWrite]
  let animatedWindowIDs: Set<WindowID>
  let animationDuration: TimeInterval
  let refreshRateHz: Double
  let completion: (@Sendable (Bool) -> Void)?
}

private struct ProcessWriteBatch: @unchecked Sendable {
  let processID: pid_t
  let writes: [(key: WindowID, value: AsyncPositionWrite)]
}

private final class FrameResultAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private var applied = 0
  private var stale = 0
  private var slowProcesses = Set<pid_t>()
  private var processLatencySamplesMS: [pid_t: Double] = [:]
  private var firstCompletionAt = TimeInterval.greatestFiniteMagnitude
  private var lastCompletionAt = 0.0

  func add(
    applied: Int,
    stale: Int,
    slowProcesses: Set<pid_t>,
    processID: pid_t,
    processLatencyMS: Double,
    completedAt: TimeInterval
  ) {
    lock.lock()
    self.applied += applied
    self.stale += stale
    self.slowProcesses.formUnion(slowProcesses)
    processLatencySamplesMS[processID] = processLatencyMS
    firstCompletionAt = min(firstCompletionAt, completedAt)
    lastCompletionAt = max(lastCompletionAt, completedAt)
    lock.unlock()
  }

  var result: (
    applied: Int,
    stale: Int,
    slowProcesses: Set<pid_t>,
    processLatencySamplesMS: [pid_t: Double],
    completionSpreadMS: Double
  ) {
    lock.lock()
    defer { lock.unlock() }
    let spread =
      firstCompletionAt.isFinite
      ? max(lastCompletionAt - firstCompletionAt, 0) * 1_000
      : 0
    return (
      applied,
      stale,
      slowProcesses,
      processLatencySamplesMS,
      spread
    )
  }
}

private final class AXFrameCoordinator: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "com.quentin.defi.ax-frame-coordinator",
    qos: .userInitiated
  )
  private let lock = NSLock()
  private var pending: QueuedPositionFrame?
  private var nextGeneration: UInt64 = 0
  private var latestGeneration: UInt64 = 0
  private var running = false
  private var activeAnimationRunning = false
  private var completedWrites = 0
  private var skippedStaleWrites = 0
  private var droppedFrameCount = 0
  private var completedPositions: [WindowID: CGPoint] = [:]
  private var traceEntries: [String] = []
  private var lastFrameDurationMS = 0.0
  private var maximumFrameDurationMS = 0.0
  private var slowFrameCount = 0
  private var lastAnimationFrameCount = 0
  private var lastAnimationDurationMS = 0.0
  private var parkingTargets: [WindowID: AsyncPositionWrite] = [:]
  private var completedParkingChecks = 0
  private var repairedParkingDrifts = 0
  private var predictedProcessLatencyMS: [pid_t: Double] = [:]
  private var processWriteQueues: [pid_t: DispatchQueue] = [:]

  func updateParkingTargets(_ targets: [WindowID: AsyncPositionWrite]) {
    lock.lock()
    parkingTargets = targets
    lock.unlock()
  }

  func invalidate() {
    lock.lock()
    nextGeneration &+= 1
    latestGeneration = nextGeneration
    pending = nil
    completedPositions.removeAll(keepingCapacity: true)
    parkingTargets.removeAll(keepingCapacity: true)
    appendTraceLocked("invalidate g=\(nextGeneration) reason=display-change")
    lock.unlock()
  }

  func submit(
    _ writes: [WindowID: AsyncPositionWrite],
    source: String,
    animationDuration: TimeInterval = 0,
    refreshRateHz: Double = 60,
    animatedWindowIDs: Set<WindowID> = [],
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

  var trace: String {
    lock.lock()
    defer { lock.unlock() }
    return traceEntries.joined(separator: "\n")
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

  var performance: (
    lastDurationMS: Double,
    maximumDurationMS: Double,
    slowFrames: Int,
    animationFrames: Int,
    animationDurationMS: Double
  ) {
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
      guard !write.isReentering,
        let completed = completedPositions[windowID],
        pointDistance(completed, write.fromPoint) >= 0.5
      else {
        continue
      }
      writes[windowID] = AsyncPositionWrite(
        element: write.element,
        application: write.application,
        processID: write.processID,
        fromPoint: completed,
        point: write.point,
        size: write.size,
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
    let animatedFrame = QueuedPositionFrame(
      generation: frame.generation,
      source: frame.source,
      writes: animatedWrites,
      animatedWindowIDs: frame.animatedWindowIDs,
      animationDuration: frame.animationDuration,
      refreshRateHz: frame.refreshRateHz,
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
    let initialPredictedLatency = predictedFrameLatency(for: animatedWrites)
    let intermediateFrameLimit = adaptiveIntermediateFrameLimit(
      predictedFrameLatency: initialPredictedLatency,
      refreshRateHz: frame.refreshRateHz,
      availableIntermediateFrames: availableIntermediateProgresses.count
    )
    let intermediateProgresses = Array(
      availableIntermediateProgresses.prefix(intermediateFrameLimit)
    )
    if intermediateFrameLimit < availableIntermediateProgresses.count {
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
    var lastCompletedFrameDuration = 0.0

    let reentryWrites = animatedWrites.filter { $0.value.isReentering }
    while frames < intermediateProgresses.count
      && isCurrent(generation: frame.generation)
    {
      let remaining = nextDeadline - ProcessInfo.processInfo.systemUptime
      if remaining > 0 {
        spinWaitPrecisely(for: remaining)
      }
      let now = ProcessInfo.processInfo.systemUptime
      let elapsed = now - startedAt
      let predictedLatency = predictedFrameLatency(for: animatedWrites)
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
      let springProgress = intermediateProgresses[frames]
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
      lastCompletedFrameDuration = applyDurationMS / 1_000
      lock.lock()
      appendTraceLocked(
        "sample g=\(frame.generation) i=\(frames) p=\(String(format: "%.3f", springProgress)) applied=\(result.applied) spread=\(String(format: "%.2f", result.completionSpreadMS)) ms=\(String(format: "%.2f", applyDurationMS)) reentry=\(frames == 1 ? reentryWrites.count : 0)"
      )
      lock.unlock()
      nextDeadline += interval
      if nextDeadline < ProcessInfo.processInfo.systemUptime {
        nextDeadline = ProcessInfo.processInfo.systemUptime
      }
    }

    guard isCurrent(generation: frame.generation) else {
      markAnimationFinished(
        generation: frame.generation,
        startedAt: startedAt
      )
      return (applied, stale + animatedWrites.count, frames)
    }
    let finalDispatchDelay =
      intermediateProgresses.isEmpty
      ? 0
      : anticipatedFinalFrameDispatchDelay(
        animationDuration: frame.animationDuration,
        predictedFrameLatency: predictedFrameLatency(for: animatedWrites)
      )
    let finalDeadline = startedAt + finalDispatchDelay
    let finalRemaining =
      finalDeadline - ProcessInfo.processInfo.systemUptime
    if finalRemaining > 0 {
      spinWaitPrecisely(for: finalRemaining)
    }
    guard isCurrent(generation: frame.generation) else {
      markAnimationFinished(
        generation: frame.generation,
        startedAt: startedAt
      )
      return (applied, stale + animatedWrites.count, frames)
    }
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
    return (applied, stale, frames + 1)
  }

  private func markAnimationFinished(
    generation: UInt64,
    startedAt: TimeInterval
  ) {
    let elapsedMS =
      (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    lock.lock()
    activeAnimationRunning = false
    appendTraceLocked(
      "visual-complete g=\(generation) ms=\(String(format: "%.2f", elapsedMS))"
    )
    lock.unlock()
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
    let orderedWrites = frame.writes.sorted {
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
    let accumulator = FrameResultAccumulator()
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
    let maximumMS = processIDs.compactMap {
      predictedProcessLatencyMS[$0]
    }.max() ?? 0
    lock.unlock()
    return maximumMS / 1_000
  }

  private func recordProcessLatencySamples(
    _ samplesMS: [pid_t: Double]
  ) {
    lock.lock()
    for (processID, rawSample) in samplesMS {
      let sample = min(max(rawSample, 0), 120)
      guard let previous = predictedProcessLatencyMS[processID] else {
        predictedProcessLatencyMS[processID] = sample
        continue
      }
      let sampleWeight = sample >= previous ? 0.75 : 0.15
      predictedProcessLatencyMS[processID] =
        previous * (1 - sampleWeight) + sample * sampleWeight
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
      let point = CGPoint(
        x: item.value.fromPoint.x
          + (item.value.point.x - item.value.fromPoint.x) * progress,
        y: item.value.fromPoint.y
          + (item.value.point.y - item.value.fromPoint.y) * progress
      )
      let writeStartedAt = ProcessInfo.processInfo.systemUptime
      let timeout = intermediate
        ? min(item.value.timeoutSeconds, 0.006)
        : max(item.value.timeoutSeconds, 0.016)
      AXUIElementSetMessagingTimeout(item.value.application, timeout)
      AXUIElementSetMessagingTimeout(item.value.element, timeout)
      let timeoutConfiguredAt = ProcessInfo.processInfo.systemUptime
      let appliedWrite = applyPosition(
        item.value,
        point: point,
        forceOffscreenAccess:
          (stagingReentry && item.value.isReentering)
          || (!intermediate && item.value.requiresVerifiedOffscreenWrite)
      )
      let positionAppliedAt = ProcessInfo.processInfo.systemUptime
      AXUIElementSetMessagingTimeout(item.value.element, 0)
      AXUIElementSetMessagingTimeout(item.value.application, 0)
      let timeoutResetAt = ProcessInfo.processInfo.systemUptime
      let writeElapsedMS =
        (timeoutResetAt - writeStartedAt) * 1_000
      let requiresReadback =
        item.value.isParked
        || item.value.requiresVerifiedOffscreenWrite
      if appliedWrite {
        applied += 1
        let completedPoint =
          requiresReadback
          ? readPosition(item.value.element) ?? point
          : point
        recordCompletedPosition(completedPoint, windowID: item.key)
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

  private func apply(_ write: AsyncPositionWrite, point: CGPoint) -> AXError {
    var point = point
    guard let value = AXValueCreate(.cgPoint, &point) else {
      return .failure
    }
    return AXUIElementSetAttributeValue(
      write.element,
      kAXPositionAttribute as CFString,
      value
    )
  }

  private func applyPosition(
    _ write: AsyncPositionWrite,
    point: CGPoint,
    forceOffscreenAccess: Bool = false
  ) -> Bool {
    if write.isParked || forceOffscreenAccess {
      setEnhancedUserInterface(false, application: write.application)
      defer {
        if write.enhancedUIWasEnabled {
          setEnhancedUserInterface(true, application: write.application)
        }
      }
      for _ in 0..<2 {
        guard apply(write, point: point) == .success else { continue }
        guard let actual = readPosition(write.element) else { return true }
        if pointDistance(actual, point) <= 1 {
          return true
        }
      }
      return false
    }
    let initialResult = apply(write, point: point)
    if initialResult == .success {
      return true
    }
    guard initialResult != .cannotComplete,
      write.enhancedUIWasEnabled
    else {
      return false
    }
    setEnhancedUserInterface(false, application: write.application)
    defer {
      setEnhancedUserInterface(true, application: write.application)
    }
    return apply(write, point: point) == .success
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

  private func verifyParkingTarget(
    windowID: WindowID,
    expectedPoint: CGPoint
  ) {
    lock.lock()
    guard let write = parkingTargets[windowID],
      pointDistance(write.point, expectedPoint) <= 0.1
    else {
      lock.unlock()
      return
    }
    lock.unlock()
    guard let actual = readPosition(write.element) else { return }
    lock.lock()
    completedParkingChecks += 1
    lock.unlock()
    guard pointDistance(actual, expectedPoint) > 1 else { return }
    guard
      applyPosition(
        write,
        point: expectedPoint,
        forceOffscreenAccess: write.requiresVerifiedOffscreenWrite
      )
    else {
      return
    }
    let repaired = readPosition(write.element) ?? expectedPoint
    recordCompletedPosition(repaired, windowID: windowID)
    lock.lock()
    repairedParkingDrifts += 1
    appendTraceLocked(
      "parking-repair wid=\(windowID.rawValue) sliver=\(write.requiresVerifiedOffscreenWrite ? 1 : 0) dx=\(String(format: "%.1f", actual.x - expectedPoint.x)) dy=\(String(format: "%.1f", actual.y - expectedPoint.y))"
    )
    lock.unlock()
  }

  private func readPosition(_ element: AXUIElement) -> CGPoint? {
    var rawValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        kAXPositionAttribute as CFString,
        &rawValue
      ) == .success,
      let rawValue,
      CFGetTypeID(rawValue) == AXValueGetTypeID()
    else {
      return nil
    }
    var point = CGPoint.zero
    guard AXValueGetValue(rawValue as! AXValue, .cgPoint, &point) else {
      return nil
    }
    return point
  }

  private func pointDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> Double {
    abs(lhs.x - rhs.x) + abs(lhs.y - rhs.y)
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

  private func setEnhancedUserInterface(
    _ enabled: Bool,
    application: AXUIElement
  ) {
    AXUIElementSetAttributeValue(
      application,
      "AXEnhancedUserInterface" as CFString,
      enabled ? kCFBooleanTrue : kCFBooleanFalse
    )
  }
}

private struct AsyncFocusRequest: @unchecked Sendable {
  let element: AXUIElement
  let application: AXUIElement
  let processID: pid_t
  let selectsSpecificWindow: Bool
}

private struct QueuedFocusRequest: @unchecked Sendable {
  let generation: UInt64
  let request: AsyncFocusRequest
}

private final class AXFocusWriter: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "com.quentin.defi.ax-focus",
    qos: .userInitiated
  )
  private let lock = NSLock()
  private var pending: QueuedFocusRequest?
  private var latestGeneration: UInt64 = 0
  private var running = false
  private var lastDurationMS = 0.0

  func submit(_ request: AsyncFocusRequest) {
    lock.lock()
    latestGeneration &+= 1
    pending = QueuedFocusRequest(
      generation: latestGeneration,
      request: request
    )
    let shouldStart = !running
    if shouldStart {
      running = true
    }
    lock.unlock()
    if shouldStart {
      queue.async { [self] in drain() }
    }
  }

  var isBusy: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running || pending != nil
  }

  var durationMS: Double {
    lock.lock()
    defer { lock.unlock() }
    return lastDurationMS
  }

  private func drain() {
    while true {
      lock.lock()
      guard let queued = pending else {
        running = false
        lock.unlock()
        return
      }
      pending = nil
      lock.unlock()

      let startedAt = ProcessInfo.processInfo.systemUptime
      let request = queued.request
      guard isCurrent(queued.generation) else { continue }
      if request.selectsSpecificWindow {
        AXUIElementSetMessagingTimeout(request.application, 0.05)
        AXUIElementSetMessagingTimeout(request.element, 0.05)
        AXUIElementSetAttributeValue(
          request.element,
          kAXMainAttribute as CFString,
          kCFBooleanTrue
        )
        AXUIElementPerformAction(
          request.element,
          kAXRaiseAction as CFString
        )
      }
      NSRunningApplication(processIdentifier: request.processID)?.activate()
      if request.selectsSpecificWindow {
        resetTimeouts(request)
      }
      let durationMS =
        (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
      lock.lock()
      lastDurationMS = durationMS
      lock.unlock()
    }
  }

  private func isCurrent(_ generation: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return latestGeneration == generation
  }

  private func resetTimeouts(_ request: AsyncFocusRequest) {
    AXUIElementSetMessagingTimeout(request.element, 0)
    AXUIElementSetMessagingTimeout(request.application, 0)
  }
}

public struct MonitorSnapshot: Equatable, Sendable {
  public let id: MonitorID
  public let frame: Rect
  public let physicalFrame: Rect
  public let refreshRateHz: Double

  public init(
    id: MonitorID,
    frame: Rect,
    physicalFrame: Rect? = nil,
    refreshRateHz: Double = 60
  ) {
    self.id = id
    self.frame = frame
    self.physicalFrame = physicalFrame ?? frame
    self.refreshRateHz = refreshRateHz
  }
}

public func monitorGeometryChanged(
  from previous: [MonitorSnapshot],
  to next: [MonitorSnapshot],
  tolerance: Double = 0.5
) -> Bool {
  guard previous.count == next.count else { return true }
  let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
  for monitor in next {
    guard let old = previousByID[monitor.id] else { return true }
    for (lhs, rhs) in [
      (old.frame.x, monitor.frame.x),
      (old.frame.y, monitor.frame.y),
      (old.frame.width, monitor.frame.width),
      (old.frame.height, monitor.frame.height),
      (old.physicalFrame.x, monitor.physicalFrame.x),
      (old.physicalFrame.y, monitor.physicalFrame.y),
      (old.physicalFrame.width, monitor.physicalFrame.width),
      (old.physicalFrame.height, monitor.physicalFrame.height),
    ] where abs(lhs - rhs) > tolerance {
      return true
    }
  }
  return false
}

public struct DesktopSnapshot: Sendable {
  public let monitors: [MonitorSnapshot]
  public let windows: [Window]
  public let focusedWindowID: WindowID?
  public let nativeFocusChanged: Bool
  public let externallyChangedFrames: [WindowID: Rect]
  public let leftMouseButtonDown: Bool
  public let targetMismatchCount: Int
  public let targetMismatches: [FrameMismatch]

  public init(
    monitors: [MonitorSnapshot],
    windows: [Window],
    focusedWindowID: WindowID?,
    nativeFocusChanged: Bool = false,
    externallyChangedFrames: [WindowID: Rect] = [:],
    leftMouseButtonDown: Bool = false,
    targetMismatchCount: Int = 0,
    targetMismatches: [FrameMismatch] = []
  ) {
    self.monitors = monitors
    self.windows = windows
    self.focusedWindowID = focusedWindowID
    self.nativeFocusChanged = nativeFocusChanged
    self.externallyChangedFrames = externallyChangedFrames
    self.leftMouseButtonDown = leftMouseButtonDown
    self.targetMismatchCount = targetMismatchCount
    self.targetMismatches = targetMismatches
  }
}

public struct FrameMismatch: Equatable, Sendable {
  public let windowID: WindowID
  public let actual: Rect
  public let target: Rect

  public init(windowID: WindowID, actual: Rect, target: Rect) {
    self.windowID = windowID
    self.actual = actual
    self.target = target
  }
}

public enum PlatformError: Error, CustomStringConvertible {
  case accessibilityPermissionMissing
  case attribute(String, AXError)
  case action(String, AXError)
  case windowUnavailable(WindowID)

  public var description: String {
    switch self {
    case .accessibilityPermissionMissing:
      "Accessibility permission missing"
    case .attribute(let name, let error):
      "AX attribute \(name) failed: \(error.rawValue)"
    case .action(let name, let error):
      "AX action \(name) failed: \(error.rawValue)"
    case .windowUnavailable(let id):
      "window unavailable: \(id.rawValue)"
    }
  }
}

@MainActor
public final class MacOSPlatform {
  private var elements: [WindowID: AXUIElement] = [:]
  private var processIDs: [WindowID: pid_t] = [:]
  private var applications: [pid_t: AXUIElement] = [:]
  private var enhancedUIByProcess: [pid_t: Bool] = [:]
  private let frameCoordinator = AXFrameCoordinator()
  private let focusWriter = AXFocusWriter()
  private var targetFrames: [WindowID: Rect] = [:]
  private var pendingFrameCorrections: [WindowID: Rect] = [:]
  private var latestObservedFrames: [WindowID: Rect] = [:]
  private var frameCommitExpectations: [WindowID: FrameCommitExpectation] = [:]
  private var deferredFrameCommitMismatchCount = 0
  private var observedFrameCommitCount = 0
  private var maximumObservedFrameCommitLatencyMS = 0.0
  private var lastHiddenWindowIDs = Set<WindowID>()
  private var eventMonitor: PlatformEventMonitor?
  private var frameEventPending = false
  private var nativeFocusEventPending = false
  private var nativeFocusRetryCount = 0
  private var lastFocusedWindowByProcess: [pid_t: WindowID] = [:]
  private var internalFocusDeadlines: [WindowID: TimeInterval] = [:]
  private var positionWriteCount = 0
  private var sizeWriteCount = 0
  private var lastFrameApplyDurationMS = 0.0
  private var lastMonitorFrames: [Rect] = []

  public init() {}

  public func startObserving(
    _ handler: @escaping () -> Void,
    displayConfigurationHandler: @escaping () -> Void = {}
  ) {
    guard eventMonitor == nil else { return }
    let monitor = PlatformEventMonitor { [weak self] kind in
      if kind == .frame {
        self?.frameEventPending = true
      }
      if kind == .focus {
        self?.nativeFocusEventPending = true
        self?.nativeFocusRetryCount = 3
      }
      if kind == .screens {
        displayConfigurationHandler()
      }
      handler()
    }
    monitor.start()
    eventMonitor = monitor
    let windowsByProcess = Dictionary(
      grouping: elements
        .compactMap { windowID, element in
          processIDs[windowID].map { ($0, element) }
        },
      by: \.0
    ).mapValues { $0.map(\.1) }
    monitor.refresh(applications: windowsByProcess)
  }

  public func invalidateFrameStateForDisplayChange() {
    frameCoordinator.invalidate()
    targetFrames.removeAll(keepingCapacity: true)
    pendingFrameCorrections.removeAll(keepingCapacity: true)
    latestObservedFrames.removeAll(keepingCapacity: true)
    frameCommitExpectations.removeAll(keepingCapacity: true)
    lastHiddenWindowIDs.removeAll(keepingCapacity: true)
  }

  public func setFrameNotificationsEnabled(_ enabled: Bool) {
    eventMonitor?.setFrameNotificationsEnabled(enabled)
  }

  public func accessibilityTrusted(prompt: Bool) -> Bool {
    let options =
      [
        "AXTrustedCheckOptionPrompt": prompt
      ] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  public func snapshot(config: Config) -> DesktopSnapshot {
    let monitors = discoverMonitors()
    lastMonitorFrames = monitors.map(\.frame)
    let cgWindows = copyCGWindows()
    let previousElements = elements
    let previousProcessIDs = processIDs
    var nextElements: [WindowID: AXUIElement] = [:]
    var nextProcessIDs: [WindowID: pid_t] = [:]
    var nextApplications: [pid_t: AXUIElement] = [:]
    var applicationWindows: [pid_t: [AXUIElement]] = [:]
    var windows: [Window] = []

    for application in NSWorkspace.shared.runningApplications
    where application.processIdentifier != ProcessInfo.processInfo.processIdentifier
      && !application.isTerminated
      && application.activationPolicy == .regular
    {
      let appID =
        application.bundleIdentifier
        ?? application.localizedName
        ?? "pid-\(application.processIdentifier)"
      let appElement = AXUIElementCreateApplication(application.processIdentifier)
      nextApplications[application.processIdentifier] = appElement
      if enhancedUIByProcess[application.processIdentifier] == nil {
        enhancedUIByProcess[application.processIdentifier] =
          value(
            appElement,
            attribute: "AXEnhancedUserInterface",
            as: Bool.self
          ) ?? false
      }
      guard let appWindows = copyElements(appElement, attribute: kAXWindowsAttribute)
      else {
        continue
      }
      applicationWindows[application.processIdentifier] = appWindows
      var usedCGWindowIDs = Set<CGWindowID>()

      for element in appWindows {
        let previousWindowID = previousElements.first { windowID, previousElement in
          previousProcessIDs[windowID] == application.processIdentifier
            && CFEqual(previousElement, element)
        }?.key
        guard
          let (candidate, cgWindowID) = makeWindow(
            element: element,
            processID: application.processIdentifier,
            appID: appID,
            cgWindows: cgWindows,
            monitors: monitors,
            preferredWindowID: previousWindowID,
            excluding: usedCGWindowIDs
          )
        else {
          continue
        }
        let decision = config.decision(for: candidate)
        guard shouldManage(candidate, forceTiling: decision.forceTiling) else {
          continue
        }
        guard usedCGWindowIDs.insert(cgWindowID).inserted else {
          continue
        }
        windows.append(candidate)
        nextElements[candidate.id] = element
        nextProcessIDs[candidate.id] = application.processIdentifier
      }
    }

    elements = nextElements
    processIDs = nextProcessIDs
    applications = nextApplications
    enhancedUIByProcess = enhancedUIByProcess.filter { nextApplications[$0.key] != nil }
    eventMonitor?.refresh(applications: applicationWindows)
    targetFrames = targetFrames.filter { nextElements[$0.key] != nil }
    pendingFrameCorrections = pendingFrameCorrections.filter { nextElements[$0.key] != nil }
    latestObservedFrames = latestObservedFrames.filter { nextElements[$0.key] != nil }
    frameCommitExpectations = frameCommitExpectations.filter {
      nextElements[$0.key] != nil
    }
    lastHiddenWindowIDs = lastHiddenWindowIDs.filter { nextElements[$0] != nil }
    let leftMouseButtonDown = CGEventSource.buttonState(
      .combinedSessionState,
      button: .left
    )
    let now = ProcessInfo.processInfo.systemUptime
    var externallyChangedFrames: [WindowID: Rect] = [:]
    var targetMismatches: [FrameMismatch] = []
    var deferredMismatchCount = 0
    var settledCommitLatenciesMS: [Double] = []
    for window in windows {
      latestObservedFrames[window.id] = window.frame
      if var expectation = frameCommitExpectations[window.id],
        let target = targetFrames[window.id]
      {
        if now >= expectation.deadline {
          frameCommitExpectations[window.id] = nil
        } else if approximatelyEqual(window.frame, target) {
          let firstObservation = expectation.observedAt == nil
          if firstObservation {
            expectation.observedAt = now
            frameCommitExpectations[window.id] = expectation
          }
          let latencyMS = max(now - expectation.issuedAt, 0) * 1_000
          if firstObservation {
            settledCommitLatenciesMS.append(latencyMS)
            observedFrameCommitCount += 1
            maximumObservedFrameCommitLatencyMS = max(
              maximumObservedFrameCommitLatencyMS,
              latencyMS
            )
          }
        } else if !frameIsOnExpectedCommitPath(
          actual: window.frame,
          currentTarget: target,
          expectation: expectation,
          now: now,
          leftMouseButtonDown: leftMouseButtonDown
        ) {
          frameCommitExpectations[window.id] = nil
        }
      }
      guard let target = targetFrames[window.id],
        !approximatelyEqual(window.frame, target)
      else {
        continue
      }
      guard targetIntersectsAnyMonitor(target, monitors: monitors) else {
        continue
      }
      if let expectation = frameCommitExpectations[window.id],
        frameIsOnExpectedCommitPath(
          actual: window.frame,
          currentTarget: target,
          expectation: expectation,
          now: now,
          leftMouseButtonDown: leftMouseButtonDown
        )
      {
        deferredMismatchCount += 1
        deferredFrameCommitMismatchCount += 1
        continue
      }
      targetMismatches.append(
        FrameMismatch(windowID: window.id, actual: window.frame, target: target)
      )
      if leftMouseButtonDown && frameEventPending {
        externallyChangedFrames[window.id] = window.frame
      }
    }
    frameEventPending = false
    pendingFrameCorrections = Dictionary(
      uniqueKeysWithValues: targetMismatches.map { ($0.windowID, $0.actual) }
    )
    let maximumSettledLatencyMS = settledCommitLatenciesMS.max() ?? 0
    frameCoordinator.recordCommitObservation(
      deferred: deferredMismatchCount,
      settled: settledCommitLatenciesMS.count,
      maximumLatencyMS: maximumSettledLatencyMS
    )
    if deferredMismatchCount > 0 || !settledCommitLatenciesMS.isEmpty {
      frameCommitLogger.debug(
        "frame commit observed settled=\(settledCommitLatenciesMS.count) deferred=\(deferredMismatchCount) max_latency_ms=\(maximumSettledLatencyMS, format: .fixed(precision: 2))"
      )
    }
    let focusedWindowID = focusedWindowID(in: windows)
    if let focusedWindowID,
      let processID = nextProcessIDs[focusedWindowID]
    {
      lastFocusedWindowByProcess[processID] = focusedWindowID
    }
    lastFocusedWindowByProcess = lastFocusedWindowByProcess.filter {
      nextProcessIDs[$0.value] == $0.key
    }
    internalFocusDeadlines = internalFocusDeadlines.filter { $0.value >= now }
    var nativeFocusChanged = nativeFocusEventPending
    if nativeFocusChanged,
      let focusedWindowID,
      internalFocusDeadlines.removeValue(forKey: focusedWindowID) != nil
    {
      nativeFocusChanged = false
    }
    if nativeFocusEventPending, focusedWindowID == nil, nativeFocusRetryCount > 0 {
      nativeFocusRetryCount -= 1
    } else {
      nativeFocusEventPending = false
      nativeFocusRetryCount = 0
    }
    return DesktopSnapshot(
      monitors: monitors,
      windows: windows,
      focusedWindowID: focusedWindowID,
      nativeFocusChanged: nativeFocusChanged,
      externallyChangedFrames: externallyChangedFrames,
      leftMouseButtonDown: leftMouseButtonDown,
      targetMismatchCount: targetMismatches.count,
      targetMismatches: targetMismatches
    )
  }

  public func apply(
    _ assignments: [FrameAssignment],
    hiddenWindowIDs: Set<WindowID> = [],
    skipping skippedWindowIDs: Set<WindowID> = [],
    asynchronousPositions: Bool = false,
    asynchronousPositionTimeoutSeconds: Float = 0.016,
    animationDuration: TimeInterval = 0,
    animationRefreshRateHz: Double = 60,
    updateVisibility: Bool = true,
    source: String = "platform"
  ) {
    let applyStartedAt = ProcessInfo.processInfo.systemUptime
    let previousTargetFrames = targetFrames
    let coordinatorWasBusy = frameCoordinator.isBusy
    var writeIntents: [WindowID: (position: Bool, size: Bool)] = [:]
    var referenceFrames: [WindowID: Rect] = [:]
    var startPositions: [WindowID: CGPoint] = [:]
    let now = ProcessInfo.processInfo.systemUptime
    for assignment in assignments where !skippedWindowIDs.contains(assignment.windowID) {
      let settlingReference = frameCommitExpectations[assignment.windowID]
        .flatMap { expectation -> Rect? in
          guard animationDuration > 0,
            let observed = latestObservedFrames[assignment.windowID],
            frameIsOnExpectedCommitPath(
              actual: observed,
              currentTarget: expectation.target,
              expectation: expectation,
              now: now,
              leftMouseButtonDown: false
            )
          else {
            return nil
          }
          return observed
        }
      let reference =
        pendingFrameCorrections[assignment.windowID]
        ?? settlingReference
        ?? previousTargetFrames[assignment.windowID]
        ?? elements[assignment.windowID].flatMap(frame(of:))
      guard let reference else { continue }
      let positionChanged =
        abs(reference.x - assignment.frame.x) >= 0.5
        || abs(reference.y - assignment.frame.y) >= 0.5
      let sizeChanged =
        abs(reference.width - assignment.frame.width) >= 0.5
        || abs(reference.height - assignment.frame.height) >= 0.5
      if positionChanged || sizeChanged {
        writeIntents[assignment.windowID] = (positionChanged, sizeChanged)
        referenceFrames[assignment.windowID] = reference
        startPositions[assignment.windowID] = CGPoint(
          x: reference.x,
          y: reference.y
        )
      }
    }
    targetFrames = Dictionary(
      uniqueKeysWithValues: assignments.map { ($0.windowID, $0.frame) }
    )
    var animationStartPositions = startPositions
    if coordinatorWasBusy {
      for windowID in Array(animationStartPositions.keys) {
        if let completed = frameCoordinator.completedPosition(for: windowID) {
          animationStartPositions[windowID] = completed
        }
      }
    }
    let newlyUnparkedWindowIDs =
      lastHiddenWindowIDs.subtracting(hiddenWindowIDs)
    var reenteringWindowIDs = Set<WindowID>()
    for assignment in assignments
    where newlyUnparkedWindowIDs.contains(assignment.windowID)
    {
      let nearestTransition = assignments.compactMap {
        candidate -> (distance: Double, deltaX: Double)? in
        guard candidate.windowID != assignment.windowID,
          !hiddenWindowIDs.contains(candidate.windowID),
          !newlyUnparkedWindowIDs.contains(candidate.windowID),
          let start = animationStartPositions[candidate.windowID]
        else {
          return nil
        }
        let deltaX = candidate.frame.x - start.x
        guard abs(deltaX) >= 0.5 else { return nil }
        let distance =
          abs(candidate.frame.x - assignment.frame.x)
          + abs(candidate.frame.y - assignment.frame.y)
        return (distance, deltaX)
      }.min { $0.distance < $1.distance }
      guard let nearestTransition else { continue }
      animationStartPositions[assignment.windowID] = CGPoint(
        x: assignment.frame.x - nearestTransition.deltaX,
        y: assignment.frame.y
      )
      reenteringWindowIDs.insert(assignment.windowID)
    }
    let commitDeadline =
      now + max(animationDuration + 0.25, 0.8)
    for assignment in assignments
    where !hiddenWindowIDs.contains(assignment.windowID)
      && writeIntents[assignment.windowID] != nil
    {
      guard let reference = referenceFrames[assignment.windowID] else {
        continue
      }
      let start = animationStartPositions[assignment.windowID]
        ?? CGPoint(x: reference.x, y: reference.y)
      frameCommitExpectations[assignment.windowID] = FrameCommitExpectation(
        from: Rect(
          x: start.x,
          y: start.y,
          width: reference.width,
          height: reference.height
        ),
        target: assignment.frame,
        issuedAt: now,
        deadline: commitDeadline,
        observedAt: nil
      )
    }
    let affectedProcessIDs = asynchronousPositions
      ? []
      : Set(writeIntents.keys.compactMap { processIDs[$0] })
    let enhancedProcessIDs = affectedProcessIDs.filter {
      enhancedUIByProcess[$0] == true
    }
    for processID in enhancedProcessIDs {
      setEnhancedUserInterface(false, processID: processID)
    }
    defer {
      for processID in enhancedProcessIDs {
        setEnhancedUserInterface(true, processID: processID)
      }
    }
    var asynchronousWrites: [WindowID: AsyncPositionWrite] = [:]
    var parkingTargets: [WindowID: AsyncPositionWrite] = [:]
    for assignment in assignments {
      guard !skippedWindowIDs.contains(assignment.windowID) else { continue }
      guard let element = elements[assignment.windowID] else { continue }
      let isParked = hiddenWindowIDs.contains(assignment.windowID)
      let intent = writeIntents[assignment.windowID]

      var position = CGPoint(x: assignment.frame.x, y: assignment.frame.y)
      var size = CGSize(width: assignment.frame.width, height: assignment.frame.height)
      if intent?.size == true, let sizeValue = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        sizeWriteCount += 1
      }
      guard let processID = processIDs[assignment.windowID],
        let application = applications[processID]
      else {
        continue
      }
      let needsVerifiedOffscreenWrite = requiresVerifiedOffscreenWrite(
        frame: assignment.frame,
        monitorFrames: lastMonitorFrames
      )
      let write = AsyncPositionWrite(
        element: element,
        application: application,
        processID: processID,
        fromPoint: animationStartPositions[assignment.windowID] ?? position,
        point: position,
        size: size,
        enhancedUIWasEnabled: enhancedUIByProcess[processID] == true,
        timeoutSeconds: asynchronousPositionTimeoutSeconds,
        isParked: isParked,
        isReentering: reenteringWindowIDs.contains(assignment.windowID),
        requiresVerifiedOffscreenWrite: needsVerifiedOffscreenWrite
      )
      if isParked || needsVerifiedOffscreenWrite {
        parkingTargets[assignment.windowID] = write
      }
      if intent?.position == true {
        if asynchronousPositions || isParked || needsVerifiedOffscreenWrite {
          asynchronousWrites[assignment.windowID] = write
        } else if let positionValue = AXValueCreate(.cgPoint, &position) {
          AXUIElementSetAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            positionValue
          )
          positionWriteCount += 1
        }
      }
      pendingFrameCorrections[assignment.windowID] = nil
    }
    frameCoordinator.updateParkingTargets(parkingTargets)
    let animatedWindowIDs =
      animationDuration > 0
      ? Set(
        asynchronousWrites.compactMap { windowID, write in
          !write.isParked && transitionCrossesViewport(write)
            ? windowID
            : nil
        }
      )
      : []
    frameCoordinator.submit(
      asynchronousWrites,
      source: source,
      animationDuration:
        animatedWindowIDs.isEmpty ? 0 : animationDuration,
      refreshRateHz: animationRefreshRateHz,
      animatedWindowIDs: animatedWindowIDs,
      completion: nil
    )
    if updateVisibility {
      lastHiddenWindowIDs = hiddenWindowIDs
    }
    lastFrameApplyDurationMS =
      (ProcessInfo.processInfo.systemUptime - applyStartedAt) * 1_000
  }

  public var screenCaptureAvailable: Bool {
    CGPreflightScreenCaptureAccess()
  }

  public var hiddenWindowCount: Int {
    lastHiddenWindowIDs.count
  }

  public var successfulPositionWriteCount: Int {
    positionWriteCount + frameCoordinator.writeCount
  }

  public var skippedStalePositionWriteCount: Int {
    frameCoordinator.staleWriteCount
  }

  public var droppedPositionFrameCount: Int {
    frameCoordinator.droppedCount
  }

  public func completedPosition(for windowID: WindowID) -> CGPoint? {
    frameCoordinator.completedPosition(for: windowID)
  }

  public var frameCoordinatorTrace: String {
    frameCoordinator.trace
  }

  public var parkingPerformance: (checks: Int, repairs: Int) {
    frameCoordinator.parkingPerformance
  }

  public var frameCommitPerformance: (
    settling: Int,
    deferred: Int,
    observed: Int,
    maximumObservedLatencyMS: Double
  ) {
    (
      frameCommitExpectations.count,
      deferredFrameCommitMismatchCount,
      observedFrameCommitCount,
      maximumObservedFrameCommitLatencyMS
    )
  }

  public var frameCoordinatorPerformance: (
    lastDurationMS: Double,
    maximumDurationMS: Double,
    slowFrames: Int,
    animationFrames: Int,
    animationDurationMS: Double
  ) {
    frameCoordinator.performance
  }

  public var successfulSizeWriteCount: Int {
    sizeWriteCount
  }

  public var frameApplyDurationMS: Double {
    lastFrameApplyDurationMS
  }

  public var focusDurationMS: Double {
    focusWriter.durationMS
  }

  public var hasPendingAnimatedFrameWrites: Bool {
    frameCoordinator.isAnimating
  }

  public var hasPendingFocusWrite: Bool {
    focusWriter.isBusy
  }

  private func transitionCrossesViewport(
    _ write: AsyncPositionWrite
  ) -> Bool {
    guard !lastMonitorFrames.isEmpty else { return true }
    let minX = min(write.fromPoint.x, write.point.x)
    let minY = min(write.fromPoint.y, write.point.y)
    let maxX =
      max(write.fromPoint.x, write.point.x) + write.size.width
    let maxY =
      max(write.fromPoint.y, write.point.y) + write.size.height
    let swept = Rect(
      x: minX,
      y: minY,
      width: maxX - minX,
      height: maxY - minY
    )
    return lastMonitorFrames.contains {
      swept.x <= $0.x + $0.width
        && swept.x + swept.width >= $0.x
        && swept.y <= $0.y + $0.height
        && swept.y + swept.height >= $0.y
    }
  }

  private func setEnhancedUserInterface(_ enabled: Bool, processID: pid_t) {
    guard let application = applications[processID] else { return }
    AXUIElementSetAttributeValue(
      application,
      "AXEnhancedUserInterface" as CFString,
      enabled ? kCFBooleanTrue : kCFBooleanFalse
    )
  }

  public func focus(_ windowID: WindowID) {
    guard let element = elements[windowID],
      let processID = processIDs[windowID],
      let application = applications[processID]
    else {
      return
    }
    internalFocusDeadlines[windowID] =
      ProcessInfo.processInfo.systemUptime + 2
    focusWriter.submit(
      AsyncFocusRequest(
        element: element,
        application: application,
        processID: processID,
        selectsSpecificWindow:
          processIDs.values.lazy.filter { $0 == processID }.prefix(2).count > 1
      )
    )
  }

  public func discoverMonitors() -> [MonitorSnapshot] {
    let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
    return NSScreen.screens.compactMap { screen in
      guard
        let number = screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber
      else {
        return nil
      }
      let visible = screen.visibleFrame
      let physical = screen.frame
      return MonitorSnapshot(
        id: MonitorID(rawValue: number.uint64Value),
        frame: Rect(
          x: visible.minX,
          y: mainTop - visible.maxY,
          width: visible.width,
          height: visible.height
        ),
        physicalFrame: Rect(
          x: physical.minX,
          y: mainTop - physical.maxY,
          width: physical.width,
          height: physical.height
        ),
        refreshRateHz: Double(screen.maximumFramesPerSecond)
      )
    }
  }

  private func makeWindow(
    element: AXUIElement,
    processID: pid_t,
    appID: String,
    cgWindows: [CGWindowRecord],
    monitors: [MonitorSnapshot],
    preferredWindowID: WindowID?,
    excluding usedCGWindowIDs: Set<CGWindowID>
  ) -> (Window, CGWindowID)? {
    guard value(element, attribute: kAXMinimizedAttribute, as: Bool.self) != true,
      let frame = frame(of: element),
      frame.width >= 80,
      frame.height >= 60
    else {
      return nil
    }
    let title = value(element, attribute: kAXTitleAttribute, as: String.self) ?? ""
    let role = value(element, attribute: kAXRoleAttribute, as: String.self)
    let subrole = value(element, attribute: kAXSubroleAttribute, as: String.self)
    guard let record = (
        preferredWindowID.flatMap { preferred in
          cgWindows.first {
            $0.id == CGWindowID(preferred.rawValue)
              && $0.processID == processID
              && !usedCGWindowIDs.contains($0.id)
          }
        }
        ?? bestCGWindow(
          processID: processID,
          title: title,
          frame: frame,
          records: cgWindows,
          excluding: usedCGWindowIDs
        )
    )
    else {
      return nil
    }
    let monitorID = monitor(containing: frame, monitors: monitors)?.id
    return (Window(
      id: WindowID(rawValue: UInt64(record.id)),
      appID: appID,
      title: title,
      frame: frame,
      role: role,
      subrole: subrole,
      processID: processID,
      monitorID: monitorID,
      forceTiling: false
    ), record.id)
  }

  private func shouldManage(_ window: Window, forceTiling: Bool) -> Bool {
    if forceTiling { return true }
    guard window.role == kAXWindowRole,
      window.subrole == kAXStandardWindowSubrole
    else {
      return false
    }
    let ignoredApps = [
      "com.apple.dock",
      "com.apple.systemuiserver",
      "com.raycast.macos",
    ]
    guard !ignoredApps.contains(window.appID.lowercased()) else { return false }
    return true
  }

  private func focusedWindowID(
    in windows: [Window]
  ) -> WindowID? {
    let frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    var focusedApplication: CFTypeRef?
    let system = AXUIElementCreateSystemWide()
    guard
      AXUIElementCopyAttributeValue(
        system,
        kAXFocusedApplicationAttribute as CFString,
        &focusedApplication
      ) == .success,
      let focusedApplication
    else {
      return stableWindowID(processID: frontmostProcessID, in: windows)
    }
    var focusedProcessID: pid_t = 0
    guard
      AXUIElementGetPid(
        focusedApplication as! AXUIElement,
        &focusedProcessID
      ) == .success
    else {
      return stableWindowID(processID: frontmostProcessID, in: windows)
    }
    var focusedWindow: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        focusedApplication as! AXUIElement,
        kAXFocusedWindowAttribute as CFString,
        &focusedWindow
      ) == .success,
      let focusedWindow
    else {
      return stableWindowID(processID: focusedProcessID, in: windows)
    }
    let focusedElement = focusedWindow as! AXUIElement
    if let exact = elements.first(where: { CFEqual($0.value, focusedElement) }) {
      return exact.key
    }
    guard let focusedFrame = frame(of: focusedElement) else {
      return stableWindowID(processID: focusedProcessID, in: windows)
    }
    let ranked = windows.filter {
      $0.processID == focusedProcessID
    }.sorted {
      frameDistance($0.frame, focusedFrame) < frameDistance($1.frame, focusedFrame)
    }
    guard let closest = ranked.first else { return nil }
    if ranked.count > 1,
      abs(
        frameDistance(closest.frame, focusedFrame)
          - frameDistance(ranked[1].frame, focusedFrame)
      ) < 0.5
    {
      return nil
    }
    return closest.id
  }

  private func stableWindowID(
    processID: pid_t?,
    in windows: [Window]
  ) -> WindowID? {
    guard let processID else { return nil }
    let candidates = windows.filter { $0.processID == processID }
    if let previous = lastFocusedWindowByProcess[processID],
      candidates.contains(where: { $0.id == previous })
    {
      return previous
    }
    return candidates.count == 1 ? candidates[0].id : nil
  }

  private func frame(of element: AXUIElement) -> Rect? {
    guard let positionValue = copyAttribute(element, name: kAXPositionAttribute),
      let sizeValue = copyAttribute(element, name: kAXSizeAttribute),
      CFGetTypeID(positionValue) == AXValueGetTypeID(),
      CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else {
      return nil
    }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
      AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    else {
      return nil
    }
    return Rect(x: position.x, y: position.y, width: size.width, height: size.height)
  }

  private func copyAttribute(_ element: AXUIElement, name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  private func value<Value>(
    _ element: AXUIElement,
    attribute: String,
    as type: Value.Type
  ) -> Value? {
    copyAttribute(element, name: attribute) as? Value
  }

  private func copyElements(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
    copyAttribute(element, name: attribute) as? [AXUIElement]
  }
}

private struct CGWindowRecord {
  let id: CGWindowID
  let processID: pid_t
  let title: String
  let frame: Rect
}

private func copyCGWindows() -> [CGWindowRecord] {
  guard
    let info = CGWindowListCopyWindowInfo(
      [.optionAll, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[CFString: Any]]
  else {
    return []
  }
  return info.compactMap { item in
    guard (item[kCGWindowLayer] as? NSNumber)?.intValue == 0,
      let number = item[kCGWindowNumber] as? NSNumber,
      let ownerPID = item[kCGWindowOwnerPID] as? NSNumber,
      let bounds = item[kCGWindowBounds] as? NSDictionary,
      let cgRect = CGRect(dictionaryRepresentation: bounds)
    else {
      return nil
    }
    return CGWindowRecord(
      id: number.uint32Value,
      processID: ownerPID.int32Value,
      title: item[kCGWindowName] as? String ?? "",
      frame: Rect(
        x: cgRect.minX,
        y: cgRect.minY,
        width: cgRect.width,
        height: cgRect.height
      )
    )
  }
}

private func bestCGWindow(
  processID: pid_t,
  title: String,
  frame: Rect,
  records: [CGWindowRecord],
  excluding usedWindowIDs: Set<CGWindowID> = []
) -> CGWindowRecord? {
  let candidates = records.filter {
    $0.processID == processID && !usedWindowIDs.contains($0.id)
  }
  let matchingTitles = candidates.filter {
    title.isEmpty || $0.title.isEmpty || $0.title == title
  }
  return (matchingTitles.isEmpty ? candidates : matchingTitles).min {
    frameDistance($0.frame, frame) < frameDistance($1.frame, frame)
  }
}

private func monitor(
  containing frame: Rect,
  monitors: [MonitorSnapshot]
) -> MonitorSnapshot? {
  let centerX = frame.x + frame.width / 2
  let centerY = frame.y + frame.height / 2
  return monitors.first {
    centerX >= $0.frame.x
      && centerX < $0.frame.x + $0.frame.width
      && centerY >= $0.frame.y
      && centerY < $0.frame.y + $0.frame.height
  }
}

private func frameDistance(_ lhs: Rect, _ rhs: Rect) -> Double {
  abs(lhs.x - rhs.x)
    + abs(lhs.y - rhs.y)
    + abs(lhs.width - rhs.width)
    + abs(lhs.height - rhs.height)
}

private func targetIntersectsAnyMonitor(
  _ frame: Rect,
  monitors: [MonitorSnapshot]
) -> Bool {
  monitors.contains { monitor in
    frame.x + frame.width > monitor.frame.x
      && frame.x < monitor.frame.x + monitor.frame.width
      && frame.y + frame.height > monitor.frame.y
      && frame.y < monitor.frame.y + monitor.frame.height
  }
}

private func targetIntersects(_ frame: Rect, monitor: Rect) -> Bool {
  frame.x + frame.width > monitor.x
    && frame.x < monitor.x + monitor.width
    && frame.y + frame.height > monitor.y
    && frame.y < monitor.y + monitor.height
}

private func approximatelyEqual(_ lhs: Rect, _ rhs: Rect) -> Bool {
  frameDistance(lhs, rhs) < 2
}
