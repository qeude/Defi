import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

func completeSupersededFrame(_ frame: QueuedPositionFrame?) {
  guard let frame else { return }
  frame.completion?(
    FrameWriteCompletion(
      completedLatest: false,
      attemptedWindowIDs: Set(frame.writes.keys),
      successfulWindowIDs: []
    )
  )
}

final class AXFrameCoordinator: @unchecked Sendable {
  let queue = DispatchQueue(
    label: "com.quentin.defi.ax-frame-coordinator",
    qos: .userInteractive
  )
  let finalOnlyAnimationQueue = DispatchQueue(
    label: "com.quentin.defi.ax-final-only-animation",
    qos: .userInitiated
  )
  let parkingSettlementQueue = DispatchQueue(
    label: "com.quentin.defi.ax-parking-settlement",
    qos: .utility
  )
  let parkingSettlementGroup = DispatchGroup()
  let lock = NSLock()
  let accessibilityWriter = AXFrameAccessibilityWriter()
  let displayLinkClock = DisplayLinkClock()
  var pending: QueuedPositionFrame?
  var nextGeneration: UInt64 = 0
  var latestGeneration: UInt64 = 0
  var running = false
  var activeWindowIDs = Set<WindowID>()
  var activeWrites: [WindowID: AsyncPositionWrite] = [:]
  var activeAnimationRunning = false
  var activeAnimatedWindowIDs = Set<WindowID>()
  var activeAnimatedSizeWindowIDs = Set<WindowID>()
  var completedWrites = 0
  var completedAnimatedSizeWrites = 0
  var skippedStaleWrites = 0
  var droppedFrameCount = 0
  var completedPositions: [WindowID: CGPoint] = [:]
  var retargetHorizontalVelocities: [WindowID: Double] = [:]
  var deferredParkingWriteGenerations: [WindowID: UInt64] = [:]
  var completedSizes: [WindowID: CGSize] = [:]
  var recentInternalFrameWrites: [WindowID: [RecentInternalFrameWrite]] = [:]
  var successfulFinalWritesByGeneration: [UInt64: Set<WindowID>] = [:]
  var reportedSuccessfulWriteWindowIDsByGeneration:
    [UInt64: Set<WindowID>] = [:]
  var latestWriteSucceededByWindowID: [WindowID: Bool] = [:]
  var traceEntries: [String] = []
  var lastFrameDurationMS = 0.0
  var maximumFrameDurationMS = 0.0
  var slowFrameCount = 0
  var lastAnimationFrameCount = 0
  var lastAnimationDurationMS = 0.0
  var parkingTargets: [WindowID: AsyncPositionWrite] = [:]
  var completedParkingChecks = 0
  var repairedParkingDrifts = 0
  var initialSettlementTargets: [WindowID: InitialSettlementTarget] = [:]
  var initialSettlementDriftSamples: [WindowID: InitialSettlementDriftSample] = [:]
  var nextInitialSettlementGeneration: UInt64 = 0
  var initialSettlementRepairsSuspended = false
  var pendingInitialSettlementEventChecks = Set<WindowID>()
  var diagnosticAnomalyHandler:
    (@Sendable (TimeInterval, String) -> Void)?
  var completedInitialSettlementChecks = 0
  var repairedInitialSettlementDrifts = 0
  var predictedProcessLatencyMS: [pid_t: Double] = [:]
  var latencySensitiveProcessIDs = Set<pid_t>()
  var processLatencyStreaks: [pid_t: ProcessLatencyStreak] = [:]
  var processWriteQueues: [pid_t: DispatchQueue] = [:]
  var immediateReadbackProcessDeadlines: [pid_t: TimeInterval] = [:]

  func processNeedsImmediateReadback(_ processID: pid_t) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard let deadline = immediateReadbackProcessDeadlines[processID] else {
      return false
    }
    let now = ProcessInfo.processInfo.systemUptime
    if deadline < now {
      immediateReadbackProcessDeadlines[processID] = nil
      return false
    }
    return true
  }

  func markProcessNeedsImmediateReadback(
    _ processID: pid_t,
    duration: TimeInterval = 30
  ) {
    lock.lock()
    defer { lock.unlock() }
    immediateReadbackProcessDeadlines[processID] =
      ProcessInfo.processInfo.systemUptime + duration
  }

  @MainActor
  func startDisplayLink() {
    displayLinkClock.start()
  }

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
    initialSettlementDriftSamples = initialSettlementDriftSamples.filter {
      windowID, sample in
      nextTargets[windowID]?.generation == sample.generation
    }
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
    let displacedFrame = pending
    nextGeneration &+= 1
    latestGeneration = nextGeneration
    pending = nil
    // The generation reset invalidates in-flight geometry too.
    activeWrites.removeAll(keepingCapacity: true)
    completedPositions.removeAll(keepingCapacity: true)
    retargetHorizontalVelocities.removeAll(keepingCapacity: true)
    deferredParkingWriteGenerations.removeAll(keepingCapacity: true)
    completedSizes.removeAll(keepingCapacity: true)
    successfulFinalWritesByGeneration.removeAll(keepingCapacity: true)
    reportedSuccessfulWriteWindowIDsByGeneration.removeAll(
      keepingCapacity: true
    )
    latestWriteSucceededByWindowID.removeAll(keepingCapacity: true)
    parkingTargets.removeAll(keepingCapacity: true)
    initialSettlementTargets.removeAll(keepingCapacity: true)
    initialSettlementDriftSamples.removeAll(keepingCapacity: true)
    initialSettlementRepairsSuspended = false
    pendingInitialSettlementEventChecks.removeAll(keepingCapacity: true)
    appendTraceLocked("invalidate g=\(nextGeneration) reason=\(reason)")
    lock.unlock()
    completeSupersededFrame(displacedFrame)
  }

  func invalidateAndWaitForWrites() {
    invalidate(reason: "synchronous-restore")
    queue.sync {}
    parkingSettlementGroup.wait()
    parkingSettlementQueue.sync {}
  }

  func submit(
    _ writes: [WindowID: AsyncPositionWrite],
    source: String,
    animationDuration: TimeInterval = 0,
    refreshRateHz: Double = 60,
    displayIDs: Set<UInt64> = [],
    animatedWindowIDs: Set<WindowID> = [],
    stagesVisibleBeforeParking: Bool = false,
    successfulWrite: (@Sendable (WindowID, TimeInterval) -> Void)? = nil,
    cursorWarpAfterWindowCommit:
      (@Sendable (WindowID, UInt64) -> Void)? = nil,
    completion: (@Sendable (FrameWriteCompletion) -> Void)? = nil
  ) {
    guard !writes.isEmpty else { return }
    lock.lock()
    let displacedFrame = pending
    nextGeneration &+= 1
    latestGeneration = nextGeneration
    if pending != nil {
      droppedFrameCount += 1
    }
    let preservedWrites = frameWritesPreservingSupersededAsyncSizes(
      active: activeWrites,
      pending: displacedFrame?.writes ?? [:],
      replacement: writes
    )
    pending = QueuedPositionFrame(
      generation: nextGeneration,
      source: source,
      writes: preservedWrites,
      animatedWindowIDs: animatedWindowIDs,
      animationDuration: max(animationDuration, 0),
      refreshRateHz: min(max(refreshRateHz, 30), 120),
      displayIDs: displayIDs,
      initialProgressVelocity: 0,
      stagesVisibleBeforeParking: stagesVisibleBeforeParking,
      successfulWrite: successfulWrite,
      completion: completion,
      cursorWarpAfterWindowCommit: cursorWarpAfterWindowCommit
    )
    successfulFinalWritesByGeneration[nextGeneration] = []
    if let displacedFrame {
      successfulFinalWritesByGeneration[displacedFrame.generation] = nil
    }
    let animatedIDs = animatedWindowIDs.sorted {
      $0.rawValue < $1.rawValue
    }.map { String($0.rawValue) }.joined(separator: ",")
    let writeIDs = preservedWrites.keys.sorted {
      $0.rawValue < $1.rawValue
    }.map { String($0.rawValue) }.joined(separator: ",")
    let parkedCount = preservedWrites.values.filter(\.isParked).count
    let durationMS = Int((animationDuration * 1_000).rounded())
    appendTraceLocked(
      "submit g=\(nextGeneration) source=\(source) windows=\(preservedWrites.count)[\(writeIDs)] animated=\(animatedWindowIDs.count)[\(animatedIDs)] parked=\(parkedCount) springMs=\(durationMS)"
    )
    let shouldStart = !running
    if shouldStart {
      running = true
    }
    lock.unlock()
    completeSupersededFrame(displacedFrame)
    if shouldStart {
      queue.async { [self] in
        drain()
      }
    }
  }

  func reportSuccessfulWrite(
    for frame: QueuedPositionFrame,
    windowID: WindowID,
    at timestamp: TimeInterval
  ) {
    lock.lock()
    let isFirst = reportedSuccessfulWriteWindowIDsByGeneration[
      frame.generation,
      default: []
    ].insert(windowID).inserted
    lock.unlock()
    if isFirst {
      frame.successfulWrite?(windowID, timestamp)
    }
  }

  var isBusy: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running || pending != nil || !deferredParkingWriteGenerations.isEmpty
  }

  func isBusy(for windowID: WindowID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return activeWindowIDs.contains(windowID)
      || pending?.writes[windowID] != nil
      || deferredParkingWriteGenerations[windowID] != nil
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

  var hasPendingDeferredParkingWrites: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !deferredParkingWriteGenerations.isEmpty
  }

  var pendingAnimatedWindowIDs: Set<WindowID> {
    lock.lock()
    defer { lock.unlock() }
    var windowIDs = activeAnimationRunning
      ? activeAnimatedWindowIDs
      : []
    if let pending, pending.animationDuration > 0 {
      windowIDs.formUnion(pending.animatedWindowIDs)
    }
    return windowIDs
  }

  var pendingWindowIDs: Set<WindowID> {
    lock.lock()
    defer { lock.unlock() }
    var windowIDs = activeWindowIDs
    if let pending {
      windowIDs.formUnion(pending.writes.keys)
    }
    windowIDs.formUnion(deferredParkingWriteGenerations.keys)
    return windowIDs
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

  func latestWriteSucceeded(for windowID: WindowID) -> Bool? {
    lock.lock()
    defer { lock.unlock() }
    return latestWriteSucceededByWindowID[windowID]
  }

  func alignCompletedSize(windowID: WindowID, size: CGSize) {
    lock.lock()
    completedSizes[windowID] = size
    lock.unlock()
  }

  func frameMatchesRecentInternalWrite(
    windowID: WindowID,
    actual: Rect,
    now: TimeInterval
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return recentInternalFrameWrites[windowID]?.contains {
      $0.deadline >= now
        && DefiMacOS.frameMatchesRecentInternalWrite(actual: actual, write: $0)
    } == true
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

  func setDiagnosticAnomalyHandler(
    _ handler: @escaping @Sendable (TimeInterval, String) -> Void
  ) {
    lock.lock()
    diagnosticAnomalyHandler = handler
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

  var slowProcessLatenciesMS: [pid_t: Double] {
    lock.lock()
    defer { lock.unlock() }
    return predictedProcessLatencyMS.filter {
      latencySensitiveProcessIDs.contains($0.key)
    }
  }

  var processLatenciesMS: [pid_t: Double] {
    lock.lock()
    defer { lock.unlock() }
    return predictedProcessLatencyMS
  }

  func pruneProcessLatencyState(liveProcessIDs: Set<pid_t>) {
    lock.lock()
    predictedProcessLatencyMS = predictedProcessLatencyMS.filter {
      liveProcessIDs.contains($0.key)
    }
    latencySensitiveProcessIDs.formIntersection(liveProcessIDs)
    processLatencyStreaks = processLatencyStreaks.filter {
      liveProcessIDs.contains($0.key)
    }
    immediateReadbackProcessDeadlines = immediateReadbackProcessDeadlines.filter {
      liveProcessIDs.contains($0.key)
    }
    let retiredQueues = processWriteQueues.filter {
      !liveProcessIDs.contains($0.key)
    }
    for processID in retiredQueues.keys {
      processWriteQueues[processID] = nil
    }
    lock.unlock()
    // Drain outside the lock: pending work items observe the empty queue map
    // and their writes are generation-checked, so they become no-ops.
    for (_, queue) in retiredQueues {
      queue.async { }
    }
  }

}
