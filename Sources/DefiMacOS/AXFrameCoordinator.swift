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
  typealias BatchResult = (applied: Int, stale: Int, attempted: Bool)
  typealias BatchWriter = @Sendable (ProcessWriteBatch, QueuedPositionFrame) -> BatchResult
  weak var snapshotEngine: SnapshotEngine?
  let batchWriter: BatchWriter?

  init(
    batchWriter: BatchWriter? = nil,
    accessibilityWriter: AXFrameAccessibilityWriter = AXFrameAccessibilityWriter(),
    messagingTimeoutAccess: AXMessagingTimeoutAccess = .shared
  ) {
    self.batchWriter = batchWriter
    self.accessibilityWriter = accessibilityWriter
    self.messagingTimeoutAccess = messagingTimeoutAccess
  }

  /// Reports completed geometry so borders cannot outrun window writes.
  var borderLiveGeometryHandler: (@Sendable ([WindowID: Rect]) -> Void)?

  var borderReadLanes: [pid_t: BorderGeometryReadLane] = [:]
  let borderGeometryReadGroup = DispatchGroup()
  var borderNativeFrameReader: @Sendable (WindowID) -> Rect? = { _ in nil }
  var borderBindingIsCurrent: @Sendable (BorderGeometryReadTarget) -> Bool = { _ in false }
  var borderReadFreshness: [WindowID: (ticket: BorderGeometryReadTicket, sampledAt: TimeInterval)] = [:]
  var borderObservationMailbox: [WindowID: BorderGeometryObservation] = [:]
  var borderObservationDeliveryScheduled = false
  var borderObservationHandler: (@MainActor @Sendable ([BorderGeometryObservation]) -> Void)?
  var borderObservationScheduler: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = {
    DispatchQueue.main.async(execute: $0)
  }

  let queue = DispatchQueue(
    label: "com.qeude.defi.ax-frame-coordinator",
    qos: .userInteractive
  )
  let parkingSettlementQueue = DispatchQueue(
    label: "com.qeude.defi.ax-parking-settlement",
    qos: .utility
  )
  let parkingSettlementGroup = DispatchGroup()
  let enhancedUIRestoreGroup = DispatchGroup()
  let lock = NSLock()
  let accessibilityWriter: AXFrameAccessibilityWriter
  let messagingTimeoutAccess: AXMessagingTimeoutAccess
  var pending: QueuedPositionFrame?
  var nextGeneration: UInt64 = 0
  var latestGeneration: UInt64 = 0
  var running = false
  var activeWindowIDs = Set<WindowID>()
  var activeWrites: [WindowID: AsyncPositionWrite] = [:]
  var completedWrites = 0
  var completedAsynchronousSizeWrites = 0
  var skippedStaleWrites = 0
  var droppedFrameCount = 0
  var completedPositions: [WindowID: CGPoint] = [:]
  var borderGeometryWrittenAt: [WindowID: TimeInterval] = [:]
  var borderGeometries: [WindowID: (frame: Rect, sampledAt: TimeInterval)] = [:]
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
  var parkingTargets: [WindowID: AsyncPositionWrite] = [:]
  var parkingVerificationSchedules: [WindowID: ParkingVerificationSchedule] = [:]
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
  var processWriteQueueReservations: [pid_t: Int] = [:]
  var processWriteQueueRetirementRequested = Set<pid_t>()
  var nextEnhancedUIRestoreToken: UInt64 = 0
  var deferredEnhancedUIRestores:
    [pid_t: (token: UInt64, application: AXUIElement, disabled: Bool)] = [:]
  var immediateReadbackProcessDeadlines: [pid_t: TimeInterval] = [:]
  var liveBorderWindowID: WindowID?

  func updateLiveBorderWindowID(_ windowID: WindowID?) {
    lock.lock()
    liveBorderWindowID = windowID
    lock.unlock()
  }

  func currentLiveBorderWindowID() -> WindowID? {
    lock.lock()
    defer { lock.unlock() }
    return liveBorderWindowID
  }

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

  func updateParkingTargets(_ targets: [WindowID: AsyncPositionWrite]) {
    lock.lock()
    parkingTargets = targets
    parkingVerificationSchedules = parkingVerificationSchedules.filter {
      windowID, schedule in
      targets[windowID]?.point == schedule.expectedPoint
    }
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
    for processID in Array(borderReadLanes.keys) {
      borderReadLanes[processID]?.retain([])
    }
    borderObservationMailbox.removeAll(keepingCapacity: true)
    borderReadFreshness.removeAll(keepingCapacity: true)
    // The generation reset invalidates in-flight geometry too.
    activeWrites.removeAll(keepingCapacity: true)
    completedPositions.removeAll(keepingCapacity: true)
    borderGeometries.removeAll(keepingCapacity: true)
    borderGeometryWrittenAt.removeAll(keepingCapacity: true)
    completedSizes.removeAll(keepingCapacity: true)
    successfulFinalWritesByGeneration.removeAll(keepingCapacity: true)
    reportedSuccessfulWriteWindowIDsByGeneration.removeAll(
      keepingCapacity: true
    )
    latestWriteSucceededByWindowID.removeAll(keepingCapacity: true)
    parkingTargets.removeAll(keepingCapacity: true)
    parkingVerificationSchedules.removeAll(keepingCapacity: true)
    initialSettlementTargets.removeAll(keepingCapacity: true)
    initialSettlementDriftSamples.removeAll(keepingCapacity: true)
    initialSettlementRepairsSuspended = false
    pendingInitialSettlementEventChecks.removeAll(keepingCapacity: true)
    retireIdleProcessWriteQueuesLocked()
    appendTraceLocked("invalidate g=\(nextGeneration) reason=\(reason)")
    lock.unlock()
    completeSupersededFrame(displacedFrame)
  }

  func invalidateAndWaitForWrites() {
    invalidate(reason: "synchronous-restore")
    queue.sync {}
    enhancedUIRestoreGroup.wait()
    parkingSettlementGroup.wait()
    borderGeometryReadGroup.wait()
    parkingSettlementQueue.sync {}
    restoreDeferredEnhancedUserInterfaces()
  }

  func submit(
    _ writes: [WindowID: AsyncPositionWrite],
    source: String,
    monitorFrames: [Rect] = [],
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
      monitorFrames: monitorFrames,
      stagesVisibleBeforeParking: stagesVisibleBeforeParking,
      successfulWrite: successfulWrite,
      completion: completion,
      cursorWarpAfterWindowCommit: cursorWarpAfterWindowCommit
    )
    successfulFinalWritesByGeneration[nextGeneration] = []
    if let displacedFrame {
      successfulFinalWritesByGeneration[displacedFrame.generation] = nil
    }
    let writeIDs = preservedWrites.keys.sorted {
      $0.rawValue < $1.rawValue
    }.map { String($0.rawValue) }.joined(separator: ",")
    let parkedCount = preservedWrites.values.filter(\.isParked).count
    appendTraceLocked(
      "submit g=\(nextGeneration) source=\(source) windows=\(preservedWrites.count)[\(writeIDs)] parked=\(parkedCount)"
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
    return running || pending != nil
  }

  func isBusy(for windowID: WindowID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return activeWriteIsPendingLocked(for: windowID)
      || pending?.writes[windowID] != nil
  }

  private func activeWriteIsPendingLocked(for windowID: WindowID) -> Bool {
    guard activeWindowIDs.contains(windowID) else { return false }
    if let write = activeWrites[windowID], asynchronousSizeWriteIsRequired(
      sizeChanged: write.sizeChanged,
      synchronousWriteSucceeded: write.synchronousSizeWriteSucceeded
    ) { return true }
    return successfulFinalWritesByGeneration[latestGeneration]?.contains(windowID) != true
  }

  var pendingWindowIDs: Set<WindowID> {
    lock.lock()
    defer { lock.unlock() }
    // A completed target must not wait for another application's AX lane.
    var windowIDs = activeWindowIDs.filter { activeWriteIsPendingLocked(for: $0) }
    if let pending {
      windowIDs.formUnion(pending.writes.keys)
    }
    return windowIDs
  }

  var writeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return completedWrites
  }

  var asynchronousSizeWriteCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return completedAsynchronousSizeWrites
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

  // Use the start of the native read, not callback delivery time: a slow
  // snapshot may finish after a newer write or frame notification.
  func recordObservedBorderFrame(
    _ frame: Rect, windowID: WindowID, sampledAt: TimeInterval
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard sampledAt >= max(
      borderGeometries[windowID]?.sampledAt ?? -.infinity,
      borderGeometryWrittenAt[windowID] ?? -.infinity
    ), !observationContradictsRecentWriteLocked(frame, windowID: windowID, sampledAt: sampledAt)
    else { return }
    borderGeometries[windowID] = (frame, sampledAt)
  }

  func latestBorderFrame(for windowID: WindowID) -> Rect? {
    lock.lock()
    defer { lock.unlock() }
    return borderGeometries[windowID]?.frame
  }

  // Display-only: never feed this back into observed frames.
  func latestDisplayedBorderFrame(for windowID: WindowID) -> Rect? {
    lock.lock()
    defer { lock.unlock() }
    let written = completedPositions[windowID].flatMap { point in
      borderGeometryWrittenAt[windowID].map { (point, completedSizes[windowID], $0) }
    }
    return displayedWindowBorderFrame(observed: borderGeometries[windowID], written: written)
  }

  /// WindowServer can still report a slow app's previous position for a few
  /// frames after its AX write returns; a native sample this soon is not proof.
  func borderWriteIsRecent(for windowID: WindowID, within seconds: TimeInterval = 0.2) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return (borderGeometryWrittenAt[windowID] ?? -.infinity)
      > ProcessInfo.processInfo.systemUptime - seconds
  }

  func retainBorderGeometry(for windowIDs: Set<WindowID>) {
    lock.lock()
    for processID in Array(borderReadLanes.keys) {
      borderReadLanes[processID]?.retain(windowIDs)
    }
    borderObservationMailbox = borderObservationMailbox.filter { windowIDs.contains($0.key) }
    borderReadFreshness = borderReadFreshness.filter { windowIDs.contains($0.key) }
    borderGeometries = borderGeometries.filter { windowIDs.contains($0.key) }
    borderGeometryWrittenAt = borderGeometryWrittenAt.filter { windowIDs.contains($0.key) }
    completedPositions = completedPositions.filter { windowIDs.contains($0.key) }
    completedSizes = completedSizes.filter { windowIDs.contains($0.key) }
    lock.unlock()
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

  func predictedProcessLatency(processID: pid_t) -> Double {
    lock.lock()
    defer { lock.unlock() }
    return predictedProcessLatencyMS[processID] ?? 8.0
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
      slowFrames: Int
    )
  {
    lock.lock()
    defer { lock.unlock() }
    return (lastFrameDurationMS, maximumFrameDurationMS, slowFrameCount)
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
    processWriteQueueRetirementRequested.formUnion(
      processWriteQueues.keys.filter { !liveProcessIDs.contains($0) }
    )
    processWriteQueueRetirementRequested.subtract(liveProcessIDs)
    let retiredEnhancedUIRestores = deferredEnhancedUIRestores.filter {
      !liveProcessIDs.contains($0.key)
    }
    var restoreReservations: [pid_t: ProcessWriteQueueReservation] = [:]
    for processID in retiredEnhancedUIRestores.keys {
      enhancedUIRestoreGroup.enter()
      processWriteQueueRetirementRequested.insert(processID)
      deferredEnhancedUIRestores[processID] = nil
      restoreReservations[processID] = reserveProcessWriteQueueLocked(for: processID)
    }
    retireIdleProcessWriteQueuesLocked()
    lock.unlock()
    for (processID, restore) in retiredEnhancedUIRestores {
      guard let reservation = restoreReservations[processID] else { continue }
      let token = restore.token
      reservation.queue.async { [self, reservation] in
        defer {
          reservation.release()
          enhancedUIRestoreGroup.leave()
        }
        lock.lock()
        let superseded = deferredEnhancedUIRestores[processID] != nil
        lock.unlock()
        guard !superseded else { return }
        // AXUIElement isn't Sendable; an application element is fully identified by its pid.
        let application = AXUIElementCreateApplication(processID)
        let restored = AXMessagingTimeoutAccess.shared.withTimeout(0.016, elements: [application]) {
          accessibilityWriter.setEnhancedUserInterface(true, application: application)
        }
        lock.lock()
        deferredEnhancedUIRestores[processID]?.disabled = false
        if !restored {
          // Keep a failed retirement recoverable by rediscovery or shutdown.
          if deferredEnhancedUIRestores[processID] == nil {
            deferredEnhancedUIRestores[processID] = (token, application, false)
          }
          appendTraceLocked("enhanced-ui-restore-failed pid=\(processID) token=\(token) retired=1")
        }
        lock.unlock()
      }
    }
  }

}
