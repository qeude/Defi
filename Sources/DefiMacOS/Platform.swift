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

func axProcessIsLatencySensitive(
  previouslySensitive: Bool,
  predictedLatencyMS: Double,
  enterThresholdMS: Double = 12,
  exitThresholdMS: Double = 7
) -> Bool {
  guard predictedLatencyMS.isFinite else { return previouslySensitive }
  return previouslySensitive
    ? predictedLatencyMS >= exitThresholdMS
    : predictedLatencyMS >= enterThresholdMS
}

func frameTargetsPreservingSkippedWindows(
  previous: [WindowID: Rect],
  assignments: [FrameAssignment],
  skippedWindowIDs: Set<WindowID>
) -> [WindowID: Rect] {
  let assignedWindowIDs = Set(assignments.map(\.windowID))
  var next = Dictionary(
    uniqueKeysWithValues: assignments.compactMap { assignment in
      skippedWindowIDs.contains(assignment.windowID)
        ? nil
        : (assignment.windowID, assignment.frame)
    }
  )
  for windowID in skippedWindowIDs where assignedWindowIDs.contains(windowID) {
    next[windowID] = previous[windowID]
  }
  return next
}

func hiddenWindowsPreservingSkippedWindows(
  previous: Set<WindowID>,
  desired: Set<WindowID>,
  skippedWindowIDs: Set<WindowID>
) -> Set<WindowID> {
  desired.subtracting(skippedWindowIDs)
    .union(previous.intersection(skippedWindowIDs))
}

struct FrameWriteIntent: Equatable, Sendable {
  let position: Bool
  let size: Bool
}

func frameWriteIntent(
  reference: Rect,
  target: Rect,
  positionsOnly: Bool
) -> FrameWriteIntent {
  FrameWriteIntent(
    position: abs(reference.x - target.x) >= 0.5
      || abs(reference.y - target.y) >= 0.5,
    size: !positionsOnly
      && (abs(reference.width - target.width) >= 0.5
        || abs(reference.height - target.height) >= 0.5)
  )
}

func interpolatedFrame(
  from: Rect,
  to: Rect,
  progress: Double
) -> Rect {
  let progress = min(max(progress, 0), 1)
  return Rect(
    x: from.x + (to.x - from.x) * progress,
    y: from.y + (to.y - from.y) * progress,
    width: from.width + (to.width - from.width) * progress,
    height: from.height + (to.height - from.height) * progress
  )
}

private struct AsyncPositionWrite: @unchecked Sendable {
  let element: AXUIElement
  let application: AXUIElement
  let processID: pid_t
  let fromPoint: CGPoint
  let point: CGPoint
  let fromSize: CGSize
  let size: CGSize
  let positionChanged: Bool
  let sizeChanged: Bool
  let animatesSize: Bool
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
  let stagesVisibleBeforeParking: Bool
  let completion: (@Sendable (Bool) -> Void)?
}

func positionWritePhases(
  windowIDs: Set<WindowID>,
  parkedWindowIDs: Set<WindowID>,
  stagesVisibleBeforeParking: Bool
) -> [Set<WindowID>] {
  guard !windowIDs.isEmpty else { return [] }
  guard stagesVisibleBeforeParking else { return [windowIDs] }
  let visibleWindowIDs = windowIDs.subtracting(parkedWindowIDs)
  return [visibleWindowIDs, windowIDs.intersection(parkedWindowIDs)]
    .filter { !$0.isEmpty }
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

  var result:
    (
      applied: Int,
      stale: Int,
      slowProcesses: Set<pid_t>,
      processLatencySamplesMS: [pid_t: Double],
      completionSpreadMS: Double
    )
  {
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
  private var predictedProcessLatencyMS: [pid_t: Double] = [:]
  private var latencySensitiveProcessIDs = Set<pid_t>()
  private var processWriteQueues: [pid_t: DispatchQueue] = [:]
  private var experimentalSkyLightEnabled = false
  private var skyLightBackend: SkyLightPositionBackend?
  private var skyLightCompanionMoveBackend: SkyLightCompanionMoveBackend?
  private var skyLightVisualPositions: [WindowID: CGPoint] = [:]
  private var skyLightPositionCompanions: [WindowID: [SkyLightPositionCompanion]] = [:]
  private var completedAXSettlements = 0
  private var cancelledAXSettlements = 0
  private var repairedStaleAXSettlements = 0

  func configureExperimentalSkyLight(enabled: Bool) {
    lock.lock()
    experimentalSkyLightEnabled = enabled
    let shouldCreateBackend = enabled && skyLightBackend == nil
    let shouldCreateCompanionBackend =
      enabled && skyLightCompanionMoveBackend == nil
    lock.unlock()
    guard shouldCreateBackend || shouldCreateCompanionBackend else { return }

    let backend = shouldCreateBackend ? SkyLightPositionBackend() : nil
    let companionBackend =
      shouldCreateCompanionBackend
      ? SkyLightCompanionMoveBackend()
      : nil
    lock.lock()
    if enabled, skyLightBackend == nil {
      skyLightBackend = backend
    }
    if enabled, skyLightCompanionMoveBackend == nil {
      skyLightCompanionMoveBackend = companionBackend
    }
    lock.unlock()
  }

  func updateParkingTargets(_ targets: [WindowID: AsyncPositionWrite]) {
    lock.lock()
    parkingTargets = targets
    lock.unlock()
  }

  func updateSkyLightPositionCompanions(
    _ companions: [WindowID: [SkyLightPositionCompanion]]
  ) {
    lock.lock()
    guard skyLightPositionCompanions != companions else {
      lock.unlock()
      return
    }
    skyLightPositionCompanions = companions
    let surfaceCount = companions.values.reduce(0) { $0 + $1.count }
    let targetIDs = companions.keys.sorted {
      $0.rawValue < $1.rawValue
    }.map { String($0.rawValue) }.joined(separator: ",")
    appendTraceLocked(
      "border-companions targets=\(companions.count)[\(targetIDs)] surfaces=\(surfaceCount)"
    )
    lock.unlock()
  }

  func invalidate(reason: String) {
    lock.lock()
    nextGeneration &+= 1
    latestGeneration = nextGeneration
    pending = nil
    completedPositions.removeAll(keepingCapacity: true)
    completedSizes.removeAll(keepingCapacity: true)
    skyLightVisualPositions.removeAll(keepingCapacity: true)
    parkingTargets.removeAll(keepingCapacity: true)
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

  func alignVisualPosition(
    windowID: WindowID,
    point: CGPoint
  ) {
    lock.lock()
    let enabled = experimentalSkyLightEnabled
    let backend = enabled ? skyLightBackend : nil
    let companionBackend = enabled ? skyLightCompanionMoveBackend : nil
    let storedCompanions = skyLightPositionCompanions[windowID] ?? []
    let companions =
      shouldMoveSkyLightCompanions(
        experimentalSkyLightEnabled: enabled,
        companionCount: storedCompanions.count
      ) ? storedCompanions : []
    lock.unlock()
    guard
      let rawWindowID = UInt32(
        exactly: windowID.rawValue
      )
    else {
      return
    }
    let targetMove = SkyLightPositionMove(
      windowID: rawWindowID,
      point: point
    )
    backend?.alignIfManaged(targetMove)
    let companionMoves = skyLightCompanionMoves(
      for: targetMove,
      companions: companions
    )
    let companionsMoved = companionBackend?.apply(companionMoves) ?? false
    if !companionMoves.isEmpty {
      lock.lock()
      appendTraceLocked(
        "border-follow wid=\(windowID.rawValue) surfaces=\(companionMoves.count) moved=\(companionsMoved ? 1 : 0) x=\(Int(point.x.rounded())) y=\(Int(point.y.rounded()))"
      )
      lock.unlock()
    }
    for companionMove in companionMoves {
      backend?.alignIfManaged(
        companionMove
      )
    }
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

  var slowProcessIDs: Set<pid_t> {
    lock.lock()
    defer { lock.unlock() }
    return latencySensitiveProcessIDs
  }

  var positionBackendPerformance: SkyLightPositionPerformance {
    lock.lock()
    let enabled = experimentalSkyLightEnabled
    let backend = skyLightBackend
    lock.unlock()
    guard enabled else {
      return SkyLightPositionPerformance(
        state: "disabled",
        batches: 0,
        moves: 0,
        failures: 0,
        fallbacks: 0,
        lastDurationMS: 0,
        maximumDurationMS: 0,
        probeVerified: false
      )
    }
    return backend?.performance
      ?? SkyLightPositionPerformance(
        state: "initializing",
        batches: 0,
        moves: 0,
        failures: 0,
        fallbacks: 0,
        lastDurationMS: 0,
        maximumDurationMS: 0,
        probeVerified: false
      )
  }

  var axSettlementPerformance:
    (
      completed: Int,
      cancelled: Int,
      repaired: Int
    )
  {
    lock.lock()
    defer { lock.unlock() }
    return (
      completedAXSettlements,
      cancelledAXSettlements,
      repairedStaleAXSettlements
    )
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
          pointDistance($0, write.fromPoint) >= 0.5
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
    let animatedFrame = QueuedPositionFrame(
      generation: frame.generation,
      source: frame.source,
      writes: animatedWrites,
      animatedWindowIDs: frame.animatedWindowIDs,
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
    let maximumAXIntermediateFrames = min(
      availableIntermediateProgresses.count,
      3
    )
    var skyLightBackend = positionBackend(
      for: animatedWrites,
      animatedPositionFrame: true
    )
    let initialPredictedLatency =
      skyLightBackend == nil
      ? predictedFrameLatency(for: animatedWrites)
      : 0
    var intermediateFrameLimit =
      skyLightBackend == nil
      ? adaptiveIntermediateFrameLimit(
        predictedFrameLatency: initialPredictedLatency,
        refreshRateHz: frame.refreshRateHz,
        availableIntermediateFrames: maximumAXIntermediateFrames
      )
      : availableIntermediateProgresses.count
    let maximumIntermediateFrames =
      skyLightBackend == nil
      ? maximumAXIntermediateFrames
      : availableIntermediateProgresses.count
    if intermediateFrameLimit < maximumIntermediateFrames {
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

    let reentryWrites = animatedWrites.filter { $0.value.isReentering }
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
      let predictedLatency =
        skyLightBackend == nil
        ? predictedFrameLatency(for: animatedWrites)
        : 0
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
      let result:
        (
          applied: Int,
          stale: Int,
          slowProcesses: Set<pid_t>,
          completionSpreadMS: Double,
          frames: Int
        )
      if let backend = skyLightBackend,
        let skyLightResult = applySkyLightFrame(
          animatedFrame,
          progress: springProgress,
          backend: backend
        )
      {
        result = skyLightResult
      } else {
        skyLightBackend = nil
        result = applyFrame(
          animatedFrame,
          progress: springProgress,
          skippedProcesses: [],
          intermediate: true,
          stagingReentry: frames == 0 && !reentryWrites.isEmpty
        )
      }
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
        "sample g=\(frame.generation) backend=\(skyLightBackend == nil ? "ax" : "skylight") i=\(frames) pi=\(progressIndex) p=\(String(format: "%.3f", springProgress)) applied=\(result.applied) spread=\(String(format: "%.2f", result.completionSpreadMS)) ms=\(String(format: "%.2f", applyDurationMS)) reentry=\(frames == 1 ? reentryWrites.count : 0)"
      )
      lock.unlock()
      nextDeadline = nextCompletedFrameDispatchDeadline(
        completedAt: frameCompletedAt,
        refreshRateHz: frame.refreshRateHz
      )
    }

    guard isCurrent(generation: frame.generation) else {
      markAnimationFinished(
        generation: frame.generation,
        startedAt: startedAt
      )
      return (applied, stale + animatedWrites.count, frames)
    }
    let finalDispatchDelay: TimeInterval
    if skyLightBackend != nil {
      finalDispatchDelay = frame.animationDuration
    } else {
      finalDispatchDelay =
        intermediateFrameLimit == 0
        ? 0
        : anticipatedFinalFrameDispatchDelay(
          animationDuration: frame.animationDuration,
          predictedFrameLatency: predictedFrameLatency(for: animatedWrites)
        )
    }
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
      markAnimationFinished(
        generation: frame.generation,
        startedAt: startedAt
      )
      return (applied, stale + animatedWrites.count, frames)
    }
    let finalStartedAt = ProcessInfo.processInfo.systemUptime
    let final:
      (
        applied: Int,
        stale: Int,
        slowProcesses: Set<pid_t>,
        completionSpreadMS: Double,
        frames: Int
      )
    let usedSkyLightFinal: Bool
    if let backend = skyLightBackend,
      let skyLightFinal = applySkyLightFrame(
        animatedFrame,
        progress: 1,
        backend: backend
      )
    {
      final = skyLightFinal
      usedSkyLightFinal = true
    } else {
      skyLightBackend = nil
      final = applyFrame(
        animatedFrame,
        progress: 1,
        skippedProcesses: []
      )
      usedSkyLightFinal = false
    }
    applied += final.applied
    stale += final.stale
    let finalDurationMS =
      (ProcessInfo.processInfo.systemUptime - finalStartedAt) * 1_000
    lock.lock()
    appendTraceLocked(
      "sample g=\(frame.generation) backend=\(skyLightBackend == nil ? "ax" : "skylight") i=final p=1.000 applied=\(final.applied) spread=\(String(format: "%.2f", final.completionSpreadMS)) ms=\(String(format: "%.2f", finalDurationMS)) reentry=0"
    )
    lock.unlock()
    if usedSkyLightFinal, let backend = skyLightBackend {
      scheduleAXSettlement(
        animatedFrame,
        backend: backend
      )
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

  private func positionBackend(
    for writes: [WindowID: AsyncPositionWrite],
    animatedPositionFrame: Bool
  ) -> SkyLightPositionBackend? {
    lock.lock()
    let enabled = experimentalSkyLightEnabled
    let backend = skyLightBackend
    lock.unlock()
    let selected = selectPositionAnimationBackend(
      experimentalSkyLightEnabled: enabled,
      skyLightAvailable: backend?.isAvailable == true,
      animatedPositionFrame: animatedPositionFrame,
      containsParkedWrite: writes.values.contains(where: \.isParked),
      containsSizeChange: writes.values.contains(where: \.sizeChanged),
      containsVerticalMove: writes.values.contains(where: {
        abs($0.fromPoint.y - $0.point.y) >= 0.5
      })
    )
    guard selected == .skyLight else {
      if enabled, backend?.isAvailable == false {
        backend?.recordFallback()
      }
      return nil
    }
    return backend
  }

  private func applySkyLightFrame(
    _ frame: QueuedPositionFrame,
    progress: Double,
    backend: SkyLightPositionBackend
  ) -> (
    applied: Int,
    stale: Int,
    slowProcesses: Set<pid_t>,
    completionSpreadMS: Double,
    frames: Int
  )? {
    guard isCurrent(generation: frame.generation) else {
      return (
        applied: 0,
        stale: frame.writes.count,
        slowProcesses: [],
        completionSpreadMS: 0,
        frames: 1
      )
    }
    var completedPoints: [(windowID: WindowID, point: CGPoint)] = []
    completedPoints.reserveCapacity(frame.writes.count)
    var moves: [SkyLightPositionMove] = []
    moves.reserveCapacity(frame.writes.count)
    for (windowID, write) in frame.writes.sorted(
      by: { $0.key.rawValue < $1.key.rawValue }
    ) {
      guard let rawWindowID = UInt32(exactly: windowID.rawValue) else {
        backend.recordFallback()
        return nil
      }
      let point = CGPoint(
        x: write.fromPoint.x
          + (write.point.x - write.fromPoint.x) * progress,
        y: write.fromPoint.y
          + (write.point.y - write.fromPoint.y) * progress
      )
      completedPoints.append((windowID, point))
      moves.append(
        SkyLightPositionMove(
          windowID: rawWindowID,
          point: point
        )
      )
    }
    lock.lock()
    let companions = rawSkyLightCompanions(skyLightPositionCompanions)
    lock.unlock()
    let transactionMoves = skyLightMovesIncludingCompanions(
      moves,
      companions: companions
    )
    guard
      backend.apply(
        transactionMoves,
        verifyReadback: progress >= 0.999
      )
    else {
      return nil
    }
    lock.lock()
    for completed in completedPoints {
      completedPositions[completed.windowID] = completed.point
      skyLightVisualPositions[completed.windowID] = completed.point
    }
    lock.unlock()
    return (
      applied: completedPoints.count,
      stale: 0,
      slowProcesses: [],
      completionSpreadMS: 0,
      frames: 1
    )
  }

  private func scheduleAXSettlement(
    _ frame: QueuedPositionFrame,
    backend: SkyLightPositionBackend
  ) {
    queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      guard let self else { return }
      guard self.isCurrent(generation: frame.generation) else {
        self.lock.lock()
        self.cancelledAXSettlements += frame.writes.count
        self.appendTraceLocked(
          "ax-settle-cancel g=\(frame.generation) windows=\(frame.writes.count)"
        )
        self.lock.unlock()
        return
      }
      let batches = Dictionary(
        grouping: frame.writes.sorted {
          if $0.value.processID != $1.value.processID {
            return $0.value.processID < $1.value.processID
          }
          return $0.key.rawValue < $1.key.rawValue
        },
        by: \.value.processID
      ).map {
        ProcessWriteBatch(processID: $0.key, writes: $0.value)
      }
      for batch in batches {
        self.processWriteQueue(for: batch.processID).async { [self] in
          settleAXBatch(
            batch,
            frame: frame,
            backend: backend
          )
        }
      }
    }
  }

  private func settleAXBatch(
    _ batch: ProcessWriteBatch,
    frame: QueuedPositionFrame,
    backend: SkyLightPositionBackend
  ) {
    let startedAt = ProcessInfo.processInfo.systemUptime
    var completed = 0
    var cancelled = 0
    var staleWindowIDs: [WindowID] = []
    for item in batch.writes {
      guard isCurrent(generation: frame.generation) else {
        cancelled += 1
        continue
      }
      let write = item.value
      AXUIElementSetMessagingTimeout(
        write.application,
        max(write.timeoutSeconds, 0.016)
      )
      AXUIElementSetMessagingTimeout(
        write.element,
        max(write.timeoutSeconds, 0.016)
      )
      let applied = applyPosition(
        write,
        point: write.point
      )
      AXUIElementSetMessagingTimeout(write.element, 0)
      AXUIElementSetMessagingTimeout(write.application, 0)
      guard isCurrent(generation: frame.generation) else {
        cancelled += 1
        if applied {
          staleWindowIDs.append(item.key)
        }
        continue
      }
      if applied {
        alignVisualPosition(
          windowID: item.key,
          point: write.point
        )
        recordCompletedPosition(
          write.point,
          windowID: item.key
        )
        completed += 1
      }
    }
    let repaired = restoreLatestSkyLightPositions(
      for: staleWindowIDs,
      backend: backend
    )
    let elapsedMS =
      (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    recordProcessLatencySamples([batch.processID: elapsedMS])
    lock.lock()
    completedAXSettlements += completed
    cancelledAXSettlements += cancelled
    repairedStaleAXSettlements += repaired
    appendTraceLocked(
      "ax-settle g=\(frame.generation) pid=\(batch.processID) completed=\(completed) cancelled=\(cancelled) repaired=\(repaired) ms=\(String(format: "%.2f", elapsedMS))"
    )
    lock.unlock()
  }

  private func restoreLatestSkyLightPositions(
    for windowIDs: [WindowID],
    backend: SkyLightPositionBackend
  ) -> Int {
    guard windowIDs.isEmpty == false else { return 0 }
    lock.lock()
    let positions: [(windowID: WindowID, point: CGPoint)] =
      windowIDs.compactMap { windowID in
        guard let point = skyLightVisualPositions[windowID] else {
          return nil
        }
        return (
          windowID: windowID,
          point: point
        )
      }
    let companions = skyLightPositionCompanions
    lock.unlock()
    let targetMoves = positions.compactMap { position -> SkyLightPositionMove? in
      guard
        let rawWindowID = UInt32(exactly: position.windowID.rawValue)
      else {
        return nil
      }
      return SkyLightPositionMove(
        windowID: rawWindowID,
        point: position.point
      )
    }
    let moves = skyLightMovesIncludingCompanions(
      targetMoves,
      companions: rawSkyLightCompanions(companions)
    )
    guard targetMoves.count == positions.count,
      backend.apply(moves)
    else {
      return 0
    }
    return targetMoves.count
  }

  private func rawSkyLightCompanions(
    _ companions: [WindowID: [SkyLightPositionCompanion]]
  ) -> [UInt32: [SkyLightPositionCompanion]] {
    Dictionary(
      uniqueKeysWithValues: companions.compactMap {
        windowID, companions -> (UInt32, [SkyLightPositionCompanion])? in
        guard let rawWindowID = UInt32(exactly: windowID.rawValue) else {
          return nil
        }
        return (rawWindowID, companions)
      }
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
        || applySize(item.value, size: size)
      let positionApplied =
        !item.value.positionChanged
        || applyPosition(
          item.value,
          point: point,
          forceOffscreenAccess: (stagingReentry && item.value.isReentering)
            || (!intermediate && item.value.requiresVerifiedOffscreenWrite)
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
        alignVisualPosition(
          windowID: item.key,
          point: point
        )
        let completedPoint =
          requiresReadback
          ? readPosition(item.value.element) ?? point
          : point
        recordCompletedPosition(completedPoint, windowID: item.key)
        scheduleCompanionRepairs(
          windowID: item.key,
          point: completedPoint
        )
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

  private func applySize(
    _ write: AsyncPositionWrite,
    size: CGSize
  ) -> Bool {
    let initialResult = applySizeValue(write, size: size)
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
    return applySizeValue(write, size: size) == .success
  }

  private func applySizeValue(
    _ write: AsyncPositionWrite,
    size: CGSize
  ) -> AXError {
    var size = size
    guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
    return AXUIElementSetAttributeValue(
      write.element,
      kAXSizeAttribute as CFString,
      value
    )
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

  private func scheduleCompanionRepairs(
    windowID: WindowID,
    point: CGPoint
  ) {
    for delay in [0.016, 0.05] {
      queue.asyncAfter(deadline: .now() + delay) { [self] in
        lock.lock()
        guard experimentalSkyLightEnabled,
          let companionBackend = skyLightCompanionMoveBackend,
          let completed = completedPositions[windowID],
          pointDistance(completed, point) < 0.5,
          let companions = skyLightPositionCompanions[windowID],
          !companions.isEmpty
        else {
          lock.unlock()
          return
        }
        lock.unlock()
        let moves = companions.map {
          SkyLightPositionMove(
            windowID: $0.windowID,
            point: CGPoint(
              x: point.x + $0.offset.x,
              y: point.y + $0.offset.y
            )
          )
        }
        _ = companionBackend.apply(moves)
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
    alignVisualPosition(
      windowID: windowID,
      point: expectedPoint
    )
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
  let activatesApplication: Bool
}

private struct QueuedFocusRequest: @unchecked Sendable {
  let generation: UInt64
  let request: AsyncFocusRequest
  let completion: @Sendable (Bool) -> Void
}

private final class AXFocusWriter: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "com.quentin.defi.ax-focus",
    qos: .userInitiated
  )
  private let lock = NSLock()
  private var pending: QueuedFocusRequest?
  private var activeProcessID: pid_t?
  private var needsRecoveryActivation = false
  private var latestGeneration: UInt64 = 0
  private var running = false
  private var lastDurationMS = 0.0
  private var fastPathCount = 0
  private var cancelledCount = 0
  private var retryCount = 0
  private var lastMainDurationMS = 0.0
  private var lastRaiseDurationMS = 0.0
  private var lastActivationDurationMS = 0.0

  func submit(
    _ request: AsyncFocusRequest,
    completion: @escaping @Sendable (Bool) -> Void
  ) {
    lock.lock()
    latestGeneration &+= 1
    pending = QueuedFocusRequest(
      generation: latestGeneration,
      request: request,
      completion: completion
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

  func hasInFlightRequest(forDifferentProcess processID: pid_t) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return activeProcessID.map { $0 != processID } == true
      || pending.map { $0.request.processID != processID } == true
  }

  var durationMS: Double {
    lock.lock()
    defer { lock.unlock() }
    return lastDurationMS
  }

  var performance:
    (
      durationMS: Double,
      fastPaths: Int,
      cancelled: Int,
      retries: Int,
      mainDurationMS: Double,
      raiseDurationMS: Double,
      activationDurationMS: Double
    )
  {
    lock.lock()
    defer { lock.unlock() }
    return (
      lastDurationMS,
      fastPathCount,
      cancelledCount,
      retryCount,
      lastMainDurationMS,
      lastRaiseDurationMS,
      lastActivationDurationMS
    )
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
      activeProcessID = queued.request.processID
      lock.unlock()

      let startedAt = ProcessInfo.processInfo.systemUptime
      let request = queued.request
      guard isCurrent(queued.generation) else {
        lock.lock()
        activeProcessID = nil
        cancelledCount += 1
        lock.unlock()
        continue
      }
      var usedFastPath = false
      var cancelled = false
      var retried = false
      var mainDurationMS = 0.0
      var raiseDurationMS = 0.0
      var activationDurationMS = 0.0
      if request.selectsSpecificWindow {
        AXUIElementSetMessagingTimeout(request.application, 0.016)
        AXUIElementSetMessagingTimeout(request.element, 0.016)
        let mainStartedAt = ProcessInfo.processInfo.systemUptime
        var mainResult = AXUIElementSetAttributeValue(
          request.element,
          kAXMainAttribute as CFString,
          kCFBooleanTrue
        )
        mainDurationMS =
          (ProcessInfo.processInfo.systemUptime - mainStartedAt) * 1_000
        cancelled = !isCurrent(queued.generation)
        var raiseResult = AXError.cannotComplete
        if !cancelled, mainResult != .success {
          let raiseStartedAt = ProcessInfo.processInfo.systemUptime
          raiseResult = AXUIElementPerformAction(
            request.element,
            kAXRaiseAction as CFString
          )
          raiseDurationMS =
            (ProcessInfo.processInfo.systemUptime - raiseStartedAt) * 1_000
        }
        cancelled = cancelled || !isCurrent(queued.generation)
        if !cancelled,
          mainResult != .success && raiseResult != .success
        {
          retried = true
          AXUIElementSetMessagingTimeout(request.application, 0.05)
          AXUIElementSetMessagingTimeout(request.element, 0.05)
          let retryMainStartedAt = ProcessInfo.processInfo.systemUptime
          mainResult = AXUIElementSetAttributeValue(
            request.element,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
          )
          mainDurationMS +=
            (ProcessInfo.processInfo.systemUptime - retryMainStartedAt) * 1_000
          if isCurrent(queued.generation), mainResult != .success {
            let retryRaiseStartedAt = ProcessInfo.processInfo.systemUptime
            raiseResult = AXUIElementPerformAction(
              request.element,
              kAXRaiseAction as CFString
            )
            raiseDurationMS +=
              (ProcessInfo.processInfo.systemUptime - retryRaiseStartedAt) * 1_000
          }
          cancelled = !isCurrent(queued.generation)
        }
        resetTimeouts(request)
      } else {
        usedFastPath = true
      }
      var activationAttempted = false
      let activationRequired =
        cancelled
        ? nil
        : activationRequirement(
          requested: request.activatesApplication,
          generation: queued.generation
        )
      if activationRequired == true {
        activationAttempted = true
        let activationStartedAt = ProcessInfo.processInfo.systemUptime
        let system = AXUIElementCreateSystemWide()
        let activationResult = AXUIElementSetAttributeValue(
          system,
          kAXFocusedApplicationAttribute as CFString,
          request.application
        )
        if activationResult != .success, isCurrent(queued.generation) {
          NSRunningApplication(processIdentifier: request.processID)?.activate()
        }
        activationDurationMS =
          (ProcessInfo.processInfo.systemUptime - activationStartedAt) * 1_000
      } else if activationRequired == nil {
        cancelled = true
      }
      if activationAttempted, !isCurrent(queued.generation) {
        markRecoveryActivationNeeded()
        cancelled = true
      }
      let durationMS =
        (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
      lock.lock()
      lastDurationMS = durationMS
      if usedFastPath { fastPathCount += 1 }
      if cancelled { cancelledCount += 1 }
      if retried { retryCount += 1 }
      lastMainDurationMS = mainDurationMS
      lastRaiseDurationMS = raiseDurationMS
      lastActivationDurationMS = activationDurationMS
      activeProcessID = nil
      lock.unlock()
      queued.completion(!cancelled && isCurrent(queued.generation))
    }
  }

  private func isCurrent(_ generation: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return latestGeneration == generation
  }

  private func activationRequirement(
    requested: Bool,
    generation: UInt64
  ) -> Bool? {
    lock.lock()
    defer { lock.unlock() }
    guard latestGeneration == generation else { return nil }
    let required = requested || needsRecoveryActivation
    needsRecoveryActivation = false
    return required
  }

  private func markRecoveryActivationNeeded() {
    lock.lock()
    needsRecoveryActivation = true
    lock.unlock()
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
  public let mouseResizeGestureObserved: Bool
  public let targetMismatchCount: Int
  public let targetMismatches: [FrameMismatch]

  public init(
    monitors: [MonitorSnapshot],
    windows: [Window],
    focusedWindowID: WindowID?,
    nativeFocusChanged: Bool = false,
    externallyChangedFrames: [WindowID: Rect] = [:],
    leftMouseButtonDown: Bool = false,
    mouseResizeGestureObserved: Bool = false,
    targetMismatchCount: Int = 0,
    targetMismatches: [FrameMismatch] = []
  ) {
    self.monitors = monitors
    self.windows = windows
    self.focusedWindowID = focusedWindowID
    self.nativeFocusChanged = nativeFocusChanged
    self.externallyChangedFrames = externallyChangedFrames
    self.leftMouseButtonDown = leftMouseButtonDown
    self.mouseResizeGestureObserved = mouseResizeGestureObserved
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
  private let borderManager = WindowBorderManager()
  private var borderBoundsProvider: WindowServerBoundsProvider?
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
  private var mouseResizeGesturePending = false
  private var nativeFocusEventPending = false
  private var nativeFocusRetryCount = 0
  private var lastFocusedWindowByProcess: [pid_t: WindowID] = [:]
  private var internalFocusDeadlines: [WindowID: TimeInterval] = [:]
  private var positionWriteCount = 0
  private var sizeWriteCount = 0
  private var lastFrameApplyDurationMS = 0.0
  private var lastMonitorFrames: [Rect] = []
  private var borderFrames: [FrameAssignment] = []
  private var borderSelectedWindowID: WindowID?
  private var lastNativeFocusedWindowID: WindowID?
  private var borderHiddenWindowIDs = Set<WindowID>()
  private var borderLiveWindowID: WindowID?
  private var borderStyle = WindowBorderStyle(
    enabled: true,
    width: 4,
    activeColor: 0xffc0_99ff,
    inactiveEnabled: false,
    inactiveColor: 0x66c0_99ff,
    captureEnabled: false
  )

  public init() {}

  public func startObserving(
    _ handler: @escaping () -> Void,
    displayConfigurationHandler: @escaping () -> Void = {},
    mouseGestureHandler: @escaping () -> Void = {}
  ) {
    guard eventMonitor == nil else { return }
    let monitor = PlatformEventMonitor(
      handler: { [weak self] kind in
        if kind == .frame || kind == .mouse {
          self?.frameEventPending = true
        }
        if kind == .mouse {
          self?.mouseResizeGesturePending = true
        }
        if kind == .focus {
          self?.nativeFocusEventPending = true
          self?.nativeFocusRetryCount = 3
        }
        if kind == .screens {
          displayConfigurationHandler()
        }
        if kind == .mouse {
          mouseGestureHandler()
        }
        handler()
      },
      frameHandler: { [weak self] element in
        self?.refreshWindowBorderGeometry(for: element)
      },
      liveFrameHandler: { [weak self] in
        guard let self else { return }
        self.refreshWindowBorderGeometry(
          windowIDs: self.borderManager.liveGeometryWindowIDs
        )
      }
    )
    monitor.start()
    eventMonitor = monitor
    let windowsByProcess = Dictionary(
      grouping:
        elements
        .compactMap { windowID, element in
          processIDs[windowID].map { ($0, element) }
        },
      by: \.0
    ).mapValues { $0.map(\.1) }
    monitor.refresh(applications: windowsByProcess)
  }

  public func invalidateFrameStateForDisplayChange() {
    frameCoordinator.invalidate(reason: "display-change")
    clearFrameState()
  }

  public func cancelPendingFrameWrites() {
    frameCoordinator.invalidate(reason: "mouse-gesture")
  }

  public func prepareForSynchronousRestore() {
    frameCoordinator.invalidateAndWaitForWrites()
    clearFrameState()
  }

  private func clearFrameState() {
    targetFrames.removeAll(keepingCapacity: true)
    pendingFrameCorrections.removeAll(keepingCapacity: true)
    latestObservedFrames.removeAll(keepingCapacity: true)
    frameCommitExpectations.removeAll(keepingCapacity: true)
    lastHiddenWindowIDs.removeAll(keepingCapacity: true)
    borderFrames.removeAll(keepingCapacity: true)
    lastNativeFocusedWindowID = nil
    borderHiddenWindowIDs.removeAll(keepingCapacity: true)
    borderLiveWindowID = nil
    borderManager.hide()
    frameCoordinator.updateSkyLightPositionCompanions([:])
  }

  public func updateWindowBorders(
    frames: [FrameAssignment],
    selectedWindowID: WindowID?,
    liveWindowID: WindowID?,
    config: BordersConfig
  ) {
    borderFrames = frames
    borderSelectedWindowID = selectedWindowID
    borderHiddenWindowIDs = lastHiddenWindowIDs
    borderLiveWindowID = liveWindowID
    borderStyle = WindowBorderStyle(
      enabled: config.enabled,
      width: config.width,
      activeColor: parseBorderColor(config.color) ?? 0xffc0_99ff,
      inactiveEnabled: config.inactiveEnabled,
      inactiveColor: parseBorderColor(config.inactiveColor) ?? 0x66c0_99ff,
      captureEnabled: config.captureEnabled
    )
    refreshWindowBorders()
    if selectedWindowID == lastNativeFocusedWindowID {
      borderManager.revealPendingBorders()
    }
  }

  public func prepareWindowBorderSelection(_ selectedWindowID: WindowID?) {
    let selectedFrame = selectedWindowID.flatMap { windowID in
      resolvedBorderFrame(for: windowID)
    }
    borderManager.prepareForSelection(
      selectedWindowID,
      displayedFrame: selectedFrame
    )
    let freshFrames: [WindowID: Rect] = Dictionary(
      uniqueKeysWithValues: borderManager.liveGeometryWindowIDs.compactMap { windowID in
        guard let frame = resolvedBorderFrame(for: windowID) else { return nil }
        return (windowID, frame)
      }
    )
    borderManager.updateGeometry(frames: freshFrames, style: borderStyle)
    frameCoordinator.updateSkyLightPositionCompanions(
      borderManager.skyLightCompanions()
    )
  }

  public func refreshWindowBorders() {
    let liveGeometryWindowIDs = borderManager.liveGeometryWindowIDs
    if isLeftMouseButtonDown {
      refreshWindowBorderGeometry(windowIDs: liveGeometryWindowIDs)
      return
    }
    if frameCoordinator.isBusy {
      refreshWindowBorderGeometry(
        windowIDs: frameCoordinator.animatedSizeWindowIDs
          .intersection(liveGeometryWindowIDs)
      )
      return
    }
    let borderGeometryIsSettling = liveGeometryWindowIDs.contains { windowID in
      guard let expectation = frameCommitExpectations[windowID] else {
        return false
      }
      return expectation.observedAt == nil
    }
    guard !borderGeometryIsSettling else { return }
    let plan = planWindowBorders(
      frames: borderFrames,
      selectedWindowID: borderSelectedWindowID,
      hiddenWindowIDs: borderHiddenWindowIDs,
      monitorFrames: lastMonitorFrames,
      style: borderStyle
    )
    let planWindowIDs = Set(plan.tracked.map(\.windowID))
    let retainedLiveWindowIDs =
      liveGeometryWindowIDs
      .subtracting(planWindowIDs)
    let retainedLiveFrames = borderFrames.filter {
      retainedLiveWindowIDs.contains($0.windowID)
    }
    let relevantFrames =
      plan.tracked.map {
        FrameAssignment(windowID: $0.windowID, frame: $0.frame)
      } + retainedLiveFrames
    let displayedFrames = Dictionary(
      uniqueKeysWithValues: relevantFrames.map { assignment in
        (
          assignment.windowID,
          displayedBorderFrame(for: assignment)
        )
      }
    )
    borderManager.sync(
      plan,
      displayedFrames: displayedFrames
    )
    let finalDisplayedFrames: [WindowID: Rect] = Dictionary(
      uniqueKeysWithValues: borderManager.liveGeometryWindowIDs.compactMap { windowID in
        guard
          let fallback = displayedFrames[windowID]
            ?? relevantFrames.first(where: { $0.windowID == windowID })?.frame
        else {
          return nil
        }
        return (
          windowID,
          borderBoundsProvider?.frame(for: windowID) ?? fallback
        )
      }
    )
    borderManager.updateGeometry(
      frames: finalDisplayedFrames,
      style: borderStyle
    )
    frameCoordinator.updateSkyLightPositionCompanions(
      borderManager.skyLightCompanions()
    )
  }

  private func refreshWindowBorderGeometry(for element: AXUIElement) {
    guard
      let windowID = elements.first(where: { CFEqual($0.value, element) })?.key,
      borderManager.liveGeometryWindowIDs.contains(windowID)
    else {
      return
    }
    refreshWindowBorderGeometry(windowIDs: [windowID])
  }

  private func refreshWindowBorderGeometry(
    windowIDs: Set<WindowID>
  ) {
    guard !windowIDs.isEmpty else { return }
    let frames = Dictionary(
      uniqueKeysWithValues: windowIDs.compactMap { windowID in
        resolvedBorderFrame(for: windowID).map { (windowID, $0) }
      }
    )
    guard !frames.isEmpty,
      borderManager.updateGeometry(frames: frames, style: borderStyle)
    else {
      return
    }
    frameCoordinator.updateSkyLightPositionCompanions(
      borderManager.skyLightCompanions()
    )
  }

  public func hideWindowBorders() {
    borderManager.hide()
    frameCoordinator.updateSkyLightPositionCompanions([:])
  }

  public var windowBorderPerformance: WindowBorderPerformance {
    borderManager.performance
  }

  private func displayedBorderFrame(
    for assignment: FrameAssignment
  ) -> Rect {
    if let nativeFrame = borderBoundsProvider?.frame(for: assignment.windowID) {
      return nativeFrame
    }
    if assignment.windowID == borderLiveWindowID,
      let observed = latestObservedFrames[assignment.windowID]
    {
      return observed
    }
    let point = frameCoordinator.completedPosition(for: assignment.windowID)
    let size = frameCoordinator.completedSize(for: assignment.windowID)
    if point == nil, size == nil, frameCoordinator.isBusy,
      let observed = latestObservedFrames[assignment.windowID]
    {
      return observed
    }
    return Rect(
      x: point.map { Double($0.x) } ?? assignment.frame.x,
      y: point.map { Double($0.y) } ?? assignment.frame.y,
      width: size.map { Double($0.width) } ?? assignment.frame.width,
      height: size.map { Double($0.height) } ?? assignment.frame.height
    )
  }

  private func resolvedBorderFrame(for windowID: WindowID) -> Rect? {
    borderBoundsProvider?.frame(for: windowID)
      ?? latestObservedFrames[windowID]
      ?? borderFrames.first(where: { $0.windowID == windowID })?.frame
  }

  public func setFrameNotificationsEnabled(_ enabled: Bool) {
    eventMonitor?.setFrameNotificationsEnabled(enabled)
  }

  public var isLeftMouseButtonDown: Bool {
    CGEventSource.buttonState(.combinedSessionState, button: .left)
  }

  public func accessibilityTrusted(prompt: Bool) -> Bool {
    let options =
      [
        "AXTrustedCheckOptionPrompt": prompt
      ] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  private func configureExperimentalBorderTracking(enabled: Bool) {
    if enabled {
      if borderBoundsProvider == nil {
        borderBoundsProvider = WindowServerBoundsProvider()
      }
    } else {
      borderBoundsProvider = nil
    }
    borderManager.configureExperimentalNativeGeometry(enabled: enabled)
  }

  public func snapshot(config: Config) -> DesktopSnapshot {
    configureExperimentalBorderTracking(
      enabled: config.experimental.skyLightBorderTracking
    )
    frameCoordinator.configureExperimentalSkyLight(
      enabled: config.experimental.skyLightPositionAnimation
    )
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
    let mouseResizeGestureObserved = mouseResizeGesturePending
    let externalResizeGestureActive =
      leftMouseButtonDown || mouseResizeGestureObserved
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
          leftMouseButtonDown: externalResizeGestureActive
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
          leftMouseButtonDown: externalResizeGestureActive
        )
      {
        deferredMismatchCount += 1
        deferredFrameCommitMismatchCount += 1
        continue
      }
      targetMismatches.append(
        FrameMismatch(windowID: window.id, actual: window.frame, target: target)
      )
      if externalResizeGestureActive && frameEventPending {
        externallyChangedFrames[window.id] = window.frame
      }
    }
    frameEventPending = false
    mouseResizeGesturePending = false
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
    lastNativeFocusedWindowID = focusedWindowID
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
      mouseResizeGestureObserved: mouseResizeGestureObserved,
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
    animateSizeChanges: Bool = false,
    positionsOnly: Bool = false,
    updateVisibility: Bool = true,
    stagesVisibleBeforeParking: Bool = false,
    focusWindowIDAfterCommit: WindowID? = nil,
    source: String = "platform"
  ) {
    let applyStartedAt = ProcessInfo.processInfo.systemUptime
    let previousTargetFrames = targetFrames
    let effectiveHiddenWindowIDs = hiddenWindowsPreservingSkippedWindows(
      previous: lastHiddenWindowIDs,
      desired: hiddenWindowIDs,
      skippedWindowIDs: skippedWindowIDs
    )
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
      let intent = frameWriteIntent(
        reference: reference,
        target: assignment.frame,
        positionsOnly: positionsOnly
      )
      if intent.position || intent.size {
        writeIntents[assignment.windowID] = (intent.position, intent.size)
        referenceFrames[assignment.windowID] = reference
        startPositions[assignment.windowID] = CGPoint(
          x: reference.x,
          y: reference.y
        )
      }
    }
    targetFrames = frameTargetsPreservingSkippedWindows(
      previous: previousTargetFrames,
      assignments: assignments,
      skippedWindowIDs: skippedWindowIDs
    )
    var animationStartPositions = startPositions
    var animationStartSizes = referenceFrames.mapValues {
      CGSize(width: $0.width, height: $0.height)
    }
    if coordinatorWasBusy {
      for windowID in Array(animationStartPositions.keys) {
        if let completed = frameCoordinator.completedPosition(for: windowID) {
          animationStartPositions[windowID] = completed
        }
        if let completed = frameCoordinator.completedSize(for: windowID) {
          animationStartSizes[windowID] = completed
        }
      }
    }
    let newlyUnparkedWindowIDs =
      lastHiddenWindowIDs.subtracting(effectiveHiddenWindowIDs)
    var reenteringWindowIDs = Set<WindowID>()
    for assignment in assignments
    where newlyUnparkedWindowIDs.contains(assignment.windowID) {
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
      let start =
        animationStartPositions[assignment.windowID]
        ?? CGPoint(x: reference.x, y: reference.y)
      let startSize =
        animationStartSizes[assignment.windowID]
        ?? CGSize(width: reference.width, height: reference.height)
      frameCommitExpectations[assignment.windowID] = FrameCommitExpectation(
        from: Rect(
          x: start.x,
          y: start.y,
          width: startSize.width,
          height: startSize.height
        ),
        target: assignment.frame,
        issuedAt: now,
        deadline: commitDeadline,
        observedAt: nil
      )
    }
    let affectedProcessIDs =
      asynchronousPositions
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
    var animatedWindowIDs = Set<WindowID>()
    for assignment in assignments {
      guard !skippedWindowIDs.contains(assignment.windowID) else { continue }
      guard let element = elements[assignment.windowID] else { continue }
      let isParked = hiddenWindowIDs.contains(assignment.windowID)
      let intent = writeIntents[assignment.windowID]

      var position = CGPoint(x: assignment.frame.x, y: assignment.frame.y)
      var size = CGSize(width: assignment.frame.width, height: assignment.frame.height)
      guard let processID = processIDs[assignment.windowID],
        let application = applications[processID]
      else {
        continue
      }
      let needsVerifiedOffscreenWrite = requiresVerifiedOffscreenWrite(
        frame: assignment.frame,
        monitorFrames: lastMonitorFrames
      )
      let startPoint = animationStartPositions[assignment.windowID] ?? position
      let startSize = animationStartSizes[assignment.windowID] ?? size
      let startFrame = Rect(
        x: startPoint.x,
        y: startPoint.y,
        width: startSize.width,
        height: startSize.height
      )
      let wantsFrameAnimation =
        animationDuration > 0
        && !isParked
        && transitionCrossesViewport(
          from: startFrame,
          to: assignment.frame
        )
        && (intent?.position == true
          || (animateSizeChanges && intent?.size == true))
      let animatesSize =
        wantsFrameAnimation
        && animateSizeChanges
        && intent?.size == true
      let write = AsyncPositionWrite(
        element: element,
        application: application,
        processID: processID,
        fromPoint: startPoint,
        point: position,
        fromSize: startSize,
        size: size,
        positionChanged: intent?.position == true,
        sizeChanged: intent?.size == true,
        animatesSize: animatesSize,
        enhancedUIWasEnabled: enhancedUIByProcess[processID] == true,
        timeoutSeconds: asynchronousPositionTimeoutSeconds,
        isParked: isParked,
        isReentering: reenteringWindowIDs.contains(assignment.windowID),
        requiresVerifiedOffscreenWrite: needsVerifiedOffscreenWrite
      )
      if intent?.size == true, !animatesSize,
        let sizeValue = AXValueCreate(.cgSize, &size)
      {
        let result = AXUIElementSetAttributeValue(
          element,
          kAXSizeAttribute as CFString,
          sizeValue
        )
        if result == .success {
          frameCoordinator.alignCompletedSize(
            windowID: assignment.windowID,
            size: size
          )
          sizeWriteCount += 1
        }
      }
      if isParked || needsVerifiedOffscreenWrite {
        parkingTargets[assignment.windowID] = write
      }
      if wantsFrameAnimation {
        asynchronousWrites[assignment.windowID] = write
        animatedWindowIDs.insert(assignment.windowID)
      } else if intent?.position == true {
        if asynchronousPositions || isParked || needsVerifiedOffscreenWrite {
          asynchronousWrites[assignment.windowID] = write
        } else if let positionValue = AXValueCreate(.cgPoint, &position) {
          AXUIElementSetAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            positionValue
          )
          frameCoordinator.alignVisualPosition(
            windowID: assignment.windowID,
            point: position
          )
          positionWriteCount += 1
        }
      }
      pendingFrameCorrections[assignment.windowID] = nil
    }
    frameCoordinator.updateParkingTargets(parkingTargets)
    let refreshesBordersAfterCommit = !animatedWindowIDs.isEmpty
    let frameCompletion: (@Sendable (Bool) -> Void)?
    if !refreshesBordersAfterCommit, focusWindowIDAfterCommit == nil {
      frameCompletion = nil
    } else {
      frameCompletion = { [weak self] completedLatest in
        guard completedLatest else { return }
        DispatchQueue.main.async {
          guard let self else { return }
          if refreshesBordersAfterCommit {
            self.refreshWindowBorders()
          }
          if let focusWindowIDAfterCommit {
            self.focus(focusWindowIDAfterCommit)
          }
        }
      }
    }
    frameCoordinator.submit(
      asynchronousWrites,
      source: source,
      animationDuration:
        animatedWindowIDs.isEmpty ? 0 : animationDuration,
      refreshRateHz: animationRefreshRateHz,
      animatedWindowIDs: animatedWindowIDs,
      stagesVisibleBeforeParking: stagesVisibleBeforeParking,
      completion: frameCompletion
    )
    if asynchronousWrites.isEmpty, let focusWindowIDAfterCommit {
      focus(focusWindowIDAfterCommit)
    }
    if updateVisibility {
      lastHiddenWindowIDs = effectiveHiddenWindowIDs
    }
    lastFrameApplyDurationMS =
      (ProcessInfo.processInfo.systemUptime - applyStartedAt) * 1_000
  }

  public var hiddenWindowCount: Int {
    lastHiddenWindowIDs.count
  }

  public var latencySensitiveWindowIDs: Set<WindowID> {
    let processIDs = frameCoordinator.slowProcessIDs
    return Set(
      self.processIDs.compactMap { windowID, processID in
        processIDs.contains(processID) ? windowID : nil
      }
    )
  }

  public var latencySensitiveProcessCount: Int {
    frameCoordinator.slowProcessIDs.count
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

  public var positionBackendPerformance: SkyLightPositionPerformance {
    frameCoordinator.positionBackendPerformance
  }

  public var axSettlementPerformance:
    (
      completed: Int,
      cancelled: Int,
      repaired: Int
    )
  {
    frameCoordinator.axSettlementPerformance
  }

  public var frameCommitPerformance:
    (
      settling: Int,
      deferred: Int,
      observed: Int,
      maximumObservedLatencyMS: Double
    )
  {
    (
      frameCommitExpectations.count,
      deferredFrameCommitMismatchCount,
      observedFrameCommitCount,
      maximumObservedFrameCommitLatencyMS
    )
  }

  public var frameCoordinatorPerformance:
    (
      lastDurationMS: Double,
      maximumDurationMS: Double,
      slowFrames: Int,
      animationFrames: Int,
      animationDurationMS: Double
    )
  {
    frameCoordinator.performance
  }

  public var successfulSizeWriteCount: Int {
    sizeWriteCount + frameCoordinator.animatedSizeWriteCount
  }

  public var frameApplyDurationMS: Double {
    lastFrameApplyDurationMS
  }

  public var focusDurationMS: Double {
    focusWriter.durationMS
  }

  public var focusPerformance:
    (
      durationMS: Double,
      fastPaths: Int,
      cancelled: Int,
      retries: Int,
      mainDurationMS: Double,
      raiseDurationMS: Double,
      activationDurationMS: Double
    )
  {
    focusWriter.performance
  }

  public var hasPendingAnimatedFrameWrites: Bool {
    frameCoordinator.isAnimating
  }

  public var hasPendingFocusWrite: Bool {
    focusWriter.isBusy
  }

  private func transitionCrossesViewport(
    from: Rect,
    to: Rect
  ) -> Bool {
    guard !lastMonitorFrames.isEmpty else { return true }
    let minX = min(from.x, to.x)
    let minY = min(from.y, to.y)
    let maxX = max(from.x + from.width, to.x + to.width)
    let maxY = max(from.y + from.height, to.y + to.height)
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
    let focusWritePending = focusWriter.isBusy
    focusWriter.submit(
      AsyncFocusRequest(
        element: element,
        application: application,
        processID: processID,
        selectsSpecificWindow:
          processIDs.values.lazy.filter { $0 == processID }.prefix(2).count > 1
          && (focusWritePending
            || lastFocusedWindowByProcess[processID] != windowID),
        activatesApplication:
          focusWriter.hasInFlightRequest(forDifferentProcess: processID)
          || NSWorkspace.shared.frontmostApplication?.processIdentifier != processID
      )
    ) { [weak self] completedLatest in
      guard completedLatest else { return }
      Task { @MainActor [weak self] in
        self?.borderManager.revealPendingBorders()
      }
    }
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
    guard
      let record =
        (preferredWindowID.flatMap { preferred in
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
          ))
    else {
      return nil
    }
    let monitorID = monitor(containing: frame, monitors: monitors)?.id
    return (
      Window(
        id: WindowID(rawValue: UInt64(record.id)),
        appID: appID,
        title: title,
        frame: frame,
        role: role,
        subrole: subrole,
        processID: processID,
        monitorID: monitorID,
        forceTiling: false
      ), record.id
    )
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
