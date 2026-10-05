import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

private let enhancedUIRestoreDelay: TimeInterval = 0.12

final class ProcessWriteQueueReservation: @unchecked Sendable {
  let queue: DispatchQueue
  private weak var coordinator: AXFrameCoordinator?
  private let processID: pid_t
  private let lock = NSLock()
  private var isReleased = false

  init(queue: DispatchQueue, coordinator: AXFrameCoordinator, processID: pid_t) {
    self.queue = queue
    self.coordinator = coordinator
    self.processID = processID
  }

  func release() {
    lock.lock()
    guard !isReleased else {
      lock.unlock()
      return
    }
    isReleased = true
    let coordinator = coordinator
    lock.unlock()
    coordinator?.releaseProcessWriteQueueReservation(for: processID)
  }

  deinit { release() }
}

extension AXFrameCoordinator {
  func applyFrame(
    _ frame: QueuedPositionFrame,
    progress: Double,
    skippedProcesses: Set<pid_t>,
    intermediate: Bool = false,
    stagingReentry: Bool = false,
    recordFinalSuccess: Bool = true
  ) -> (
    applied: Int,
    stale: Int,
    slowProcesses: Set<pid_t>,
    completionSpreadMS: Double,
    frames: Int
  ) {
    guard isCurrent(generation: frame.generation) else {
      let stale = frame.writes.values.lazy.filter { !skippedProcesses.contains($0.processID) }.count
      return (0, stale, [], 0, 0)
    }
    let accumulator = FrameResultAccumulator()
    let parkedWindowIDs = Set(
      frame.writes.compactMap { windowID, write in
        write.isParked ? windowID : nil
      }
    )
    let writePhases = positionWritePhases(
      windowIDs: Set(frame.writes.keys),
      parkedWindowIDs: parkedWindowIDs,
      stagesVisibleBeforeParking: frame.stagesVisibleBeforeParking
    )
    let phases = stagingReentry ? writePhases.flatMap { phase in
      let entering = phase.filter { frame.writes[$0]?.isReentering == true }
      return [entering, phase.subtracting(entering)].filter { !$0.isEmpty }
    } : writePhases
    for phase in phases {
      if frame.stagesVisibleBeforeParking {
        let kind = phase.isSubset(of: parkedWindowIDs) ? "parking" : "visible"
        lock.lock()
        appendTraceLocked(
          "phase g=\(frame.generation) kind=\(kind) windows=\(phase.count)"
        )
        lock.unlock()
      }
      let batches = processWriteBatches(
        frame.writes,
        windowIDs: phase,
        skippedProcesses: skippedProcesses
      )
      let group = DispatchGroup()
      for batch in batches {
        group.enter()
        enqueueProcessWrite(for: batch.processID) { [self] in
          defer { group.leave() }
          let batchStartedAt = ProcessInfo.processInfo.systemUptime
          let result = applyBatch(
            batch,
            frame: frame,
            progress: progress,
            intermediate: intermediate,
            stagingReentry: stagingReentry && batch.writes.allSatisfy { $0.value.isReentering },
            recordFinalSuccess: recordFinalSuccess
          )
          let processLatencyMS =
            (ProcessInfo.processInfo.systemUptime - batchStartedAt) * 1_000
          accumulator.add(
            applied: result.applied,
            stale: result.stale,
            slowProcesses: result.slowProcesses,
            processID: batch.processID,
            processLatencyMS: processLatencyMS,
            attempted: result.attempted,
            completedAt: ProcessInfo.processInfo.systemUptime
          )
        }
      }
      group.wait()
    }
    let result = accumulator.result
    if !result.processLatencySamplesMS.isEmpty {
      recordProcessLatencySamples(result.processLatencySamplesMS, intermediate: intermediate)
    }
    return (
      result.applied,
      result.stale,
      result.slowProcesses,
      result.completionSpreadMS,
      1
    )
  }

  func processWriteBatches(
    _ writes: [WindowID: AsyncPositionWrite],
    windowIDs: Set<WindowID>,
    skippedProcesses: Set<pid_t> = []
  ) -> [ProcessWriteBatch] {
    let orderedWrites = writes.filter { windowIDs.contains($0.key) }
      .sorted {
        if $0.value.processID != $1.value.processID {
          return $0.value.processID < $1.value.processID
        }
        return $0.key.rawValue < $1.key.rawValue
      }
    return Dictionary(
      grouping: orderedWrites.filter {
        !skippedProcesses.contains($0.value.processID)
      },
      by: \.value.processID
    ).map {
      var entries = $0.value
      let deltas = entries.map {
        frameAnimationDestination($0.value, intermediate: true).x - $0.value.fromPoint.x
      }
      if entries.allSatisfy({ $0.value.usesCommonRibbonOffset }),
        let delta = deltas.first, abs(delta) >= 0.5,
        deltas.allSatisfy({ $0 * delta > 0 })
      {
        // AX writes are sequential within an application. Release space in
        // front of the strip before advancing its following native windows.
        entries.sort {
          let a = $0.value.fromPoint.x, b = $1.value.fromPoint.x
          return a == b ? $0.key.rawValue < $1.key.rawValue : (delta < 0 ? a < b : a > b)
        }
      }
      return ProcessWriteBatch(processID: $0.key, writes: entries)
    }.sorted { $0.processID < $1.processID }
  }

  func animationLanesAreReady(processIDs: [pid_t]) -> Bool {
    animationLaneLock.lock()
    defer { animationLaneLock.unlock() }
    return processIDs.allSatisfy { processAnimationLanes[$0]?.isRunning != true }
  }

  func submitAnimationSamples(
    _ samples: [ProcessAnimationSample]
  ) -> (coalesced: Int, submittedIntermediate: Bool) {
    var displacedSamples: [ProcessAnimationSample] = []
    var startingSamples: [ProcessAnimationSample] = []
    animationLaneLock.lock()
    // Gate the entire ribbon atomically. A busy app must not let its siblings
    // advance alone, and recovered lanes can resume on the very next tick.
    let intermediateIsBlocked = samples.contains {
      $0.intermediate && processAnimationLanes[$0.batch.processID]?.isRunning == true
    }
    let accepted = samples.filter { !$0.intermediate || !intermediateIsBlocked }
    for sample in accepted {
      animationLaneWriteGroup.enter()
      var lane = processAnimationLanes[sample.batch.processID]
        ?? LatestAnimationSampleState()
      let submission = lane.submit(sample)
      processAnimationLanes[sample.batch.processID] = lane
      if let displaced = submission.displaced {
        displacedSamples.append(displaced)
      }
      if submission.startsDrain {
        startingSamples.append(sample)
      }
    }
    animationLaneLock.unlock()
    for displaced in displacedSamples {
      displaced.completion?()
      animationLaneWriteGroup.leave()
    }
    for sample in startingSamples {
      let reservation = reserveProcessWriteQueue(for: sample.batch.processID)
      let prioritizesMotion = sample.intermediate && !sample.stagingReentry
        && sample.frame.source == "command-animation"
        && sample.batch.writes.allSatisfy {
          !$0.value.sizeChanged && $0.value.fromPoint.y == $0.value.point.y
        }
      reservation.queue.async(
        qos: prioritizesMotion ? .userInteractive : .unspecified,
        flags: prioritizesMotion ? .enforceQoS : []
      ) { [self] in
        defer { reservation.release() }
        drainAnimationLane(processID: sample.batch.processID)
      }
    }
    return (displacedSamples.count, accepted.contains { $0.intermediate })
  }

  func drainAnimationLane(processID: pid_t) {
    var laneReady: (@Sendable () -> Void)?
    while true {
      animationLaneLock.lock()
      guard var lane = processAnimationLanes[processID],
        let sample = lane.takeNext()
      else {
        processAnimationLanes[processID] = nil
        animationLaneLock.unlock()
        laneReady?()
        return
      }
      processAnimationLanes[processID] = lane
      animationLaneLock.unlock()
      laneReady = sample.laneReady

      let startedAt = ProcessInfo.processInfo.systemUptime
      let result = applyBatch(
        sample.batch,
        frame: sample.frame,
        progress: sample.progress,
        intermediate: sample.intermediate,
        stagingReentry: sample.stagingReentry,
        recordFinalSuccess: sample.recordFinalSuccess,
        progressVelocity: sample.progressVelocity
      )
      let completedAt = ProcessInfo.processInfo.systemUptime
      let latencyMS = (completedAt - startedAt) * 1_000
      sample.accumulator.add(
        applied: result.applied,
        stale: result.stale,
        slowProcesses: result.slowProcesses,
        processID: processID,
        processLatencyMS: latencyMS,
        attempted: result.attempted,
        completedAt: completedAt,
        intermediate: sample.intermediate
      )
      if result.attempted {
        recordProcessLatencySamples([processID: latencyMS], intermediate: sample.intermediate)
      }
      publishCompletedBorderGeometry(
        Dictionary(uniqueKeysWithValues: sample.batch.writes)
      )
      sample.completion?()
      animationLaneWriteGroup.leave()
    }
  }

  func processWriteQueue(for processID: pid_t) -> DispatchQueue {
    lock.lock()
    defer { lock.unlock() }
    return processWriteQueueLocked(for: processID)
  }

  func reserveProcessWriteQueue(for processID: pid_t) -> ProcessWriteQueueReservation {
    lock.lock()
    defer { lock.unlock() }
    return reserveProcessWriteQueueLocked(for: processID)
  }

  func reserveProcessWriteQueueLocked(
    for processID: pid_t
  ) -> ProcessWriteQueueReservation {
    let queue = processWriteQueueLocked(for: processID)
    processWriteQueueReservations[processID, default: 0] += 1
    return ProcessWriteQueueReservation(
      queue: queue, coordinator: self, processID: processID
    )
  }

  func processWriteQueueLocked(for processID: pid_t) -> DispatchQueue {
    if let existing = processWriteQueues[processID] {
      return existing
    }
    let queue = DispatchQueue(
      label: "com.quentin.defi.ax-process-\(processID)",
      qos: .userInitiated,
      autoreleaseFrequency: .workItem
    )
    processWriteQueues[processID] = queue
    return queue
  }

  func releaseProcessWriteQueueReservation(for processID: pid_t) {
    lock.lock()
    let reservations = processWriteQueueReservations[processID, default: 0]
    precondition(reservations > 0, "process queue reservation released more than once")
    if reservations == 1 {
      processWriteQueueReservations[processID] = nil
    } else {
      processWriteQueueReservations[processID] = reservations - 1
    }
    retireIdleProcessWriteQueuesLocked()
    lock.unlock()
  }

  func retireIdleProcessWriteQueuesLocked() {
    for processID in Array(processWriteQueueRetirementRequested) {
      guard processWriteQueueReservations[processID, default: 0] == 0,
        pending?.writes.values.contains(where: { $0.processID == processID }) != true,
        !activeWrites.values.contains(where: { $0.processID == processID })
      else { continue }
      animationLaneLock.lock()
      let hasAnimationLane = processAnimationLanes[processID] != nil
      animationLaneLock.unlock()
      guard !hasAnimationLane else { continue }
      processWriteQueues[processID] = nil
      processWriteQueueRetirementRequested.remove(processID)
    }
  }

  func enqueueProcessWrite(
    for processID: pid_t,
    qos: DispatchQoS = .unspecified,
    flags: DispatchWorkItemFlags = [],
    after deadline: DispatchTime? = nil,
    operation: @escaping @Sendable () -> Void
  ) {
    enqueueProcessWrite(
      using: reserveProcessWriteQueue(for: processID),
      qos: qos,
      flags: flags,
      after: deadline,
      operation: operation
    )
  }

  func enqueueProcessWrite(
    using reservation: ProcessWriteQueueReservation,
    qos: DispatchQoS = .unspecified,
    flags: DispatchWorkItemFlags = [],
    after deadline: DispatchTime? = nil,
    operation: @escaping @Sendable () -> Void
  ) {
    let work: @Sendable () -> Void = {
      defer { reservation.release() }
      operation()
    }
    if let deadline {
      reservation.queue.asyncAfter(
        deadline: deadline, qos: qos, flags: flags, execute: work
      )
    } else {
      reservation.queue.async(qos: qos, flags: flags, execute: work)
    }
  }

  func predictedFrameLatency(
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

  func finalOnlyAnimationProcessIDs(
    for writes: [WindowID: AsyncPositionWrite],
    animationDuration: TimeInterval,
    refreshRateHz: Double
  ) -> Set<pid_t> {
    Set(intermediateFrameLimits(
      for: writes,
      availableFrames: completedFrameSpringSamples(
        duration: animationDuration, refreshRateHz: refreshRateHz
      ).count,
      refreshRateHz: refreshRateHz
    ).compactMap { $0.value < 2 ? $0.key : nil })
  }

  func intermediateFrameLimits(
    for writes: [WindowID: AsyncPositionWrite],
    availableFrames: Int,
    refreshRateHz: Double
  ) -> [pid_t: Int] {
    // Parking, final verification, and resizing do not predict position-only
    // horizontal motion. Measure its first animation before deciding to skip it.
    let motionOnly = writes.values.allSatisfy {
      !$0.sizeChanged && $0.fromPoint.y == $0.point.y
    }
    return intermediateFrameLimits(
      for: Set(writes.values.map(\.processID)), availableFrames: availableFrames,
      refreshRateHz: refreshRateHz, motionOnly: motionOnly
    )
  }

  func horizontalAnimationDuration(
    for writes: [WindowID: AsyncPositionWrite],
    requested: TimeInterval,
    refreshRateHz: Double,
    allowsSizeChanges: Bool = false
  ) -> TimeInterval {
    guard requested > 0, !writes.isEmpty,
      writes.values.allSatisfy({
        (!$0.animatesSize || allowsSizeChanges)
          && ($0.usesCommonRibbonOffset || abs($0.point.y - $0.fromPoint.y) < 0.5) })
    else { return requested }
    lock.lock()
    let latency = writes.values.map {
      (recentIntermediateProcessLatencySamplesMS[$0.processID]?.map(\.latencyMS).max()
        ?? predictedProcessLatencyMS[$0.processID] ?? 0) / 1_000
    }.max() ?? 0
    lock.unlock()
    // Give every participating native lane two intermediate writes plus its
    // final write. A bounded common timeline avoids replacing the whole strip
    // with a jump after a recent stall, without queuing more AX work.
    let interval = 1 / min(max(refreshRateHz, 30), 120)
    return max(requested, min(0.4, 3 * latency + 2 * interval))
  }

  func animationSupportsIntermediateFrames(
    processIDs: Set<pid_t>,
    animationDuration: TimeInterval,
    refreshRateHz: Double
  ) -> Bool {
    intermediateFrameLimits(
      for: processIDs,
      availableFrames: completedFrameSpringSamples(
        duration: animationDuration,
        refreshRateHz: refreshRateHz
      ).count,
      refreshRateHz: refreshRateHz
    ).values.allSatisfy { $0 >= 2 }
  }

  func intermediateFrameLimits(
    for processIDs: Set<pid_t>,
    availableFrames: Int,
    refreshRateHz: Double,
    sampledAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
    motionOnly: Bool = false
  ) -> [pid_t: Int] {
    lock.lock()
    defer { lock.unlock() }
    return Dictionary(uniqueKeysWithValues: processIDs.map { processID in
      (
        processID,
        adaptiveIntermediateFrameLimit(
          predictedFrameLatency:
            (recentIntermediateProcessLatencySamplesMS[processID]?
              // Retain useful motion budgets across ordinary key pauses. A
              // disabling stall must expire sooner so the lane can probe again.
              .filter { sample in
                let age = sampledAt - sample.sampledAt
                return age <= 0.25 || (motionOnly && age <= 1
                  && adaptiveIntermediateFrameLimit(
                    predictedFrameLatency: sample.latencyMS / 1_000,
                    refreshRateHz: refreshRateHz, availableIntermediateFrames: availableFrames
                  ) >= 2)
              }
              .suffix(8).map(\.latencyMS).max()
              ?? (motionOnly ? 0 : predictedProcessLatencyMS[processID] ?? 0)) / 1_000,
          refreshRateHz: refreshRateHz,
          availableIntermediateFrames: availableFrames
        )
      )
    })
  }

  func recordInitialMotionLatency(
    processID: pid_t,
    latencyMS: Double,
    sampledAt: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard !(recentIntermediateProcessLatencySamplesMS[processID] ?? []).contains(where: {
      sampledAt - $0.sampledAt <= 1
    }) else { return }
    recentIntermediateProcessLatencySamplesMS[processID] = [
      (sampledAt, min(max(latencyMS, 0), 120))
    ]
  }

  func recordProcessLatencySamples(
    _ samplesMS: [pid_t: Double],
    intermediate: Bool = false,
    sampledAt: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) {
    lock.lock()
    for (processID, rawSample) in samplesMS {
      let sample = min(max(rawSample, 0), 120)
      // Final parking verification and size commits cost more than movement.
      // Expire motion stalls when fresh writes confirm recovery: a count-only
      // history recovers slowly because throttling also reduces new samples.
      if intermediate {
        var recent = recentIntermediateProcessLatencySamplesMS[processID] ?? []
        recent.removeAll { sampledAt - $0.sampledAt > 0.25 }
        recent.append((sampledAt, sample))
        if recent.count > 16 { recent.removeFirst(recent.count - 16) }
        recentIntermediateProcessLatencySamplesMS[processID] = recent
      }
      let prediction: Double
      if let previous = predictedProcessLatencyMS[processID] {
        // Clamp a single outlier so one slow write cannot yank the
        // prediction (and the lane) away from the observed steady state.
        let clampedSample = min(sample, previous + 30)
        let sampleWeight = clampedSample >= previous ? 0.75 : 0.5
        prediction = previous * (1 - sampleWeight) + clampedSample * sampleWeight
      } else {
        prediction = sample
      }
      predictedProcessLatencyMS[processID] = prediction
      var streak = processLatencyStreaks[processID] ?? ProcessLatencyStreak()
      let wasSensitive = latencySensitiveProcessIDs.contains(processID)
      let isSensitive: Bool
      if wasSensitive {
        isSensitive = axProcessIsLatencySensitive(
          previouslySensitive: true,
          predictedLatencyMS: prediction
        )
      } else {
        isSensitive = processLatencyEntryIsConfirmed(
          sampleMS: sample,
          streak: &streak
        )
      }
      processLatencyStreaks[processID] = streak
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

  func applyBatch(
    _ batch: ProcessWriteBatch,
    frame: QueuedPositionFrame,
    progress: Double,
    intermediate: Bool,
    stagingReentry: Bool,
    recordFinalSuccess: Bool,
    progressVelocity: Double = 0
  ) -> (
    applied: Int,
    stale: Int,
    slowProcesses: Set<pid_t>,
    attempted: Bool
  ) {
    guard isCurrent(generation: frame.generation) else {
      return (0, batch.writes.count, [], false)
    }
    if let batchWriter {
      return batchWriter(batch, frame, progress, intermediate, stagingReentry, recordFinalSuccess)
    }
    let seedsMotionCost = !intermediate && !stagingReentry && progress >= 1
      && !batch.writes.isEmpty && batch.writes.allSatisfy {
        $0.value.positionChanged && !$0.value.sizeChanged && !$0.value.isParked
          && !$0.value.isReentering && !$0.value.requiresVerifiedOffscreenWrite
          && $0.value.fromPoint.y == $0.value.point.y
      }
    var motionCostMS = 0.0
    var applied = 0
    var stale = 0
    var slowProcesses = Set<pid_t>()
    var attempted = false
    let batchApplication = batch.writes.first?.value.application
    let enhancedUIWasEnabled = batch.writes.contains {
      $0.value.enhancedUIWasEnabled
    }
    let pendingEnhancedUIRestore = hasDeferredEnhancedUIRestore(
      processID: batch.processID
    )
    // Keep native animation disabled through every position sample and its
    // asynchronous consumption, including horizontal navigation.
    let defersEnhancedUIRestore =
      enhancedUIWasEnabled
      && (
        pendingEnhancedUIRestore
          || batch.writes.contains {
            DefiMacOS.defersEnhancedUIRestore(
              enhancedUIWasEnabled: $0.value.enhancedUIWasEnabled,
              positionChanged: $0.value.positionChanged
            )
          }
      )
    // Hoist the AXEnhancedUserInterface toggle to batch granularity: one
    // disable/restore pair per application instead of two round-trips per
    // parked or verified-offscreen write.
    let managesEnhancedUI =
      enhancedUIWasEnabled
      && batch.writes.contains {
        $0.value.isParked || $0.value.requiresVerifiedOffscreenWrite
      }
    let enhancedUIRestoreToken: UInt64?
    if let batchApplication, defersEnhancedUIRestore {
      enhancedUIRestoreToken = beginDeferredEnhancedUIRestore(
        processID: batch.processID,
        application: batchApplication
      )
    } else {
      enhancedUIRestoreToken = nil
      if let batchApplication, managesEnhancedUI {
        _ = AXMessagingTimeoutAccess.shared.withTimeout(0.006, elements: [batchApplication]) {
          accessibilityWriter.setEnhancedUserInterface(false, application: batchApplication)
        }
      }
    }
    defer {
      if let enhancedUIRestoreToken {
        scheduleEnhancedUIRestore(
          processID: batch.processID,
          token: enhancedUIRestoreToken
        )
      } else if let batchApplication, managesEnhancedUI {
        _ = AXMessagingTimeoutAccess.shared.withTimeout(0.016, elements: [batchApplication]) {
          accessibilityWriter.setEnhancedUserInterface(true, application: batchApplication)
        }
      }
    }
    for (index, item) in batch.writes.enumerated() {
      guard isCurrent(generation: frame.generation) else {
        stale += batch.writes.count - index
        break
      }
      let destination = frameAnimationDestination(item.value, intermediate: intermediate)
      let interpolated = interpolatedFrame(
        from: Rect(
          x: item.value.fromPoint.x,
          y: item.value.fromPoint.y,
          width: item.value.fromSize.width,
          height: item.value.fromSize.height
        ),
        to: Rect(
          x: destination.x,
          y: destination.y,
          width: item.value.size.width,
          height: item.value.size.height
        ),
        progress: progress
      )
      let nativeRibbonSample = (intermediate || stagingReentry)
        && (item.value.usesCommonRibbonOffset || item.value.usesLogicalRibbonPath)
        && frame.monitorFrames.count == 1
      let ribbonSample = item.value.usesCommonRibbonOffset
        ? Rect(x: interpolated.x, y: item.value.fromPoint.y,
          width: item.value.fromSize.width, height: item.value.fromSize.height)
        : interpolated
      let projectsNativeStrip = (intermediate || stagingReentry)
        && frame.source == "command-animation"
        && item.value.fromPoint.y == item.value.point.y
        && frame.monitorFrames.count == 1
      let nativeFrame = (nativeRibbonSample || projectsNativeStrip) ? nativeRibbonAnimationFrame(
        ribbonSample,
        monitor: frame.monitorFrames[0]) : interpolated
      let point = CGPoint(x: nativeFrame.x, y: nativeFrame.y)
      let parksRibbonSample = nativeRibbonSample && requiresVerifiedOffscreenWrite(
        frame: nativeFrame, monitorFrames: frame.monitorFrames)
      // A distant logical column stays at its verified strip anchor. Do not
      // send identical offscreen positions at every display refresh.
      if parksRibbonSample, !stagingReentry, !item.value.sizeChanged, !item.value.animatesSize,
        let completed = completedPosition(for: item.key),
        accessibilityWriter.pointDistance(completed, point) < 0.5
      {
        continue
      }
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
      let requiresAsynchronousSizeWrite = asynchronousSizeWriteIsRequired(
        sizeChanged: item.value.sizeChanged,
        synchronousWriteSucceeded: item.value.synchronousSizeWriteSucceeded,
        animatesSize: item.value.animatesSize
      )
      if intermediate {
        lock.lock()
        let completedPoint = completedPositions[item.key]
        let completedSize = completedSizes[item.key] ?? item.value.fromSize
        lock.unlock()
        if let completedPoint {
          let intent = frameWriteIntent(
            reference: Rect(x: completedPoint.x, y: completedPoint.y,
                            width: completedSize.width, height: completedSize.height),
            target: interpolated, positionsOnly: !requiresAsynchronousSizeWrite
          )
          if !intent.position && !intent.size {
            if stagingReentry, item.value.positionChanged { applied += 1 }
            recordRetargetVelocity(frame: frame, progressVelocity: 0, windowIDs: [item.key])
            continue
          }
        }
      }
      // A parked surface already at its projected origin needs no AX round trip
      // before the shared timeline. Read only this window when the cache missed.
      if stagingReentry, !requiresAsynchronousSizeWrite,
        let native = accessibilityWriter.nativePositionReader(item.key, item.value.processID),
        accessibilityWriter.pointDistance(native, point) <= 1
      {
        recordCompletedPosition(native, windowID: item.key)
        if item.value.positionChanged { applied += 1 }
        recordRetargetVelocity(frame: frame, progressVelocity: 0, windowIDs: [item.key])
        continue
      }
      let readsLiveBorderPosition = acceptedFrameRequiresReadback(
        windowID: item.key,
        sizeChanged: false,
        liveBorderWindowID: currentLiveBorderWindowID()
      )
      let readsImmediatePosition =
        (item.value.isParked || item.value.requiresVerifiedOffscreenWrite)
        && processNeedsImmediateReadback(item.value.processID)
      // Presentation already samples native geometry independently. Do not make
      // every ribbon lane wait for a second border-only WindowServer round trip.
      let defersBorderReadback = readsLiveBorderPosition && intermediate && !stagingReentry
        && frame.source == "command-animation" && !requiresAsynchronousSizeWrite
        && item.value.fromPoint.y == item.value.point.y
        && !item.value.isParked && !item.value.isReentering
        && !item.value.requiresVerifiedOffscreenWrite && !readsImmediatePosition
        && accessibilityWriter.independentBorderObservationAvailable()
      attempted = true
      var timeoutWaitMS = 0.0
      let writeResult = AXMessagingTimeoutAccess.shared.withTimeout(
        timeout,
        elements: [item.value.application, item.value.element],
        observeWait: { timeoutWaitMS = $0 * 1_000 }
      ) {
        let timeoutConfiguredAt = ProcessInfo.processInfo.systemUptime
        let generationIsCurrent = isCurrent(generation: frame.generation)
        let asynchronousSizeWriteSucceeded =
          generationIsCurrent
          && (
            !requiresAsynchronousSizeWrite
              || accessibilityWriter.applySize(
                item.value,
                size: size,
                enhancedUIManagedByBatch: managesEnhancedUI
                  || defersEnhancedUIRestore,
                shouldApply: { self.isCurrent(generation: frame.generation) }
              )
          )
        var sizeApplied = frameSizeWriteSucceeded(
          sizeChanged: item.value.sizeChanged,
          synchronousWriteSucceeded: item.value.synchronousSizeWriteSucceeded,
          animatesSize: item.value.animatesSize,
          asynchronousWriteSucceeded: asynchronousSizeWriteSucceeded
        )
        var acceptedSize =
          sizeApplied && requiresAsynchronousSizeWrite
            && ((!intermediate && progress >= 1) || readsLiveBorderPosition)
          ? accessibilityWriter.readSize(item.value.element)
          : nil
        let sizeWasClampedBeforeMove = item.value.positionChanged
          && (acceptedSize.map {
            abs($0.width - size.width) >= 0.5 || abs($0.height - size.height) >= 0.5
          } ?? false)
        var nativeStagingPosition: CGPoint?
        let verifyNativeStage: (() -> Bool)? =
          stagingReentry && item.value.isReentering && !item.value.isParked
            && !item.value.requiresVerifiedOffscreenWrite ? {
          guard self.isCurrent(generation: frame.generation),
            let native = self.accessibilityWriter.nativePositionReader(item.key, item.value.processID),
            self.accessibilityWriter.pointDistance(native, point) <= 1
          else { return false }
          nativeStagingPosition = native
          return true
        } : nil
        let positionStartedAt = ProcessInfo.processInfo.systemUptime
        var positionApplied =
          generationIsCurrent
          && (
            !item.value.positionChanged
              || accessibilityWriter.applyPosition(
                item.value,
                point: point,
                forceOffscreenAccess: parksRibbonSample || (stagingReentry && item.value.isReentering)
                  || (!intermediate && item.value.requiresVerifiedOffscreenWrite),
                verifyParkedPosition: !intermediate,
                enhancedUIManagedByBatch: managesEnhancedUI
                  || defersEnhancedUIRestore,
                nativePositionIsVerified: verifyNativeStage,
                shouldApply: { self.isCurrent(generation: frame.generation) }
              )
            )
        let positionDurationMS =
          (ProcessInfo.processInfo.systemUptime - positionStartedAt) * 1_000
        // AppKit can clamp a resize at the source position, even on the same
        // display. Retry the final size once after moving, only after a measured
        // mismatch; intermediate samples must keep their bounded write budget.
        if !intermediate, progress >= 1, positionApplied,
          sizeWasClampedBeforeMove,
          isCurrent(generation: frame.generation)
        {
          sizeApplied = accessibilityWriter.applySize(
            item.value, size: size,
            enhancedUIManagedByBatch: managesEnhancedUI || defersEnhancedUIRestore,
            shouldApply: { self.isCurrent(generation: frame.generation) }
          )
          acceptedSize = sizeApplied ? accessibilityWriter.readSize(item.value.element) : nil
          if isCurrent(generation: frame.generation) {
            nativeStagingPosition = nil
            positionApplied = accessibilityWriter.applyPosition(
              item.value, point: point,
              forceOffscreenAccess: parksRibbonSample || (stagingReentry && item.value.isReentering)
                || (!intermediate && item.value.requiresVerifiedOffscreenWrite),
              verifyParkedPosition: !intermediate,
              enhancedUIManagedByBatch: managesEnhancedUI || defersEnhancedUIRestore,
              nativePositionIsVerified: verifyNativeStage,
              shouldApply: { self.isCurrent(generation: frame.generation) }
            )
          }
        }
        var acceptedPosition = nativeStagingPosition
        if acceptedPosition == nil,
          (positionApplied && ((readsLiveBorderPosition && !defersBorderReadback) || readsImmediatePosition))
            || (stagingReentry && !positionApplied)
        {
          // Keep borders on observed geometry without another message to the
          // app's AX handler on every moving sample. Mandatory AX readback and
          // unavailable WindowServer metadata keep their existing fallback.
          if intermediate, readsLiveBorderPosition, !readsImmediatePosition {
            acceptedPosition = accessibilityWriter.nativePositionReader(
              item.key, item.value.processID
            )
          }
          acceptedPosition = acceptedPosition ?? accessibilityWriter.readPosition(item.value.element)
        }
        // AX can report AppKit's transient clamp while WindowServer has already
        // accepted the staging anchor. Read only this surface, only on disagreement.
        if stagingReentry, !positionApplied, isCurrent(generation: frame.generation),
          let native = accessibilityWriter.nativePositionReader(item.key, item.value.processID),
          accessibilityWriter.pointDistance(native, point) <= 1
        {
          positionApplied = true
          acceptedPosition = native
        }
        return (
          sizeApplied: sizeApplied,
          acceptedSize: acceptedSize,
          positionApplied: positionApplied,
          acceptedPosition: acceptedPosition,
          timeoutConfiguredAt: timeoutConfiguredAt,
          positionAppliedAt: ProcessInfo.processInfo.systemUptime,
          positionDurationMS: positionDurationMS
        )
      }
      if stagingReentry, !writeResult.positionApplied, isCurrent(generation: frame.generation) {
        let observed = writeResult.acceptedPosition
        lock.lock()
        appendTraceLocked("reentry-stage-rejected g=\(frame.generation) wid=\(item.key.rawValue) expected=\(point) observed=\(String(describing: observed))")
        lock.unlock()
      }
      let sizeApplied = writeResult.sizeApplied
      let acceptedSize = writeResult.acceptedSize
      let positionApplied = writeResult.positionApplied
      let acceptedPosition = writeResult.acceptedPosition
      let appliedWrite = sizeApplied && positionApplied
      let successfulWrite = successfulFrameWriteIntent(
        positionChanged: item.value.positionChanged,
        positionApplied: positionApplied,
        sizeChanged: requiresAsynchronousSizeWrite,
        sizeApplied: sizeApplied
      )
      let timeoutConfiguredAt = writeResult.timeoutConfiguredAt
      let positionAppliedAt = writeResult.positionAppliedAt
      let timeoutResetAt = ProcessInfo.processInfo.systemUptime
      let writeElapsedMS =
        (timeoutResetAt - writeStartedAt) * 1_000
      if sizeApplied, requiresAsynchronousSizeWrite,
        !intermediate, progress >= 1
      {
        recordCompletedActiveSizeWrite(windowID: item.key)
      }
      if successfulWrite.position || successfulWrite.size {
        reportSuccessfulWrite(
          for: frame,
          windowID: item.key,
          at: timeoutResetAt
        )
        recordInternalFrameWrite(
          Rect(
            x: point.x,
            y: point.y,
            width: size.width,
            height: size.height
          ),
          windowID: item.key,
          positionChanged: successfulWrite.position,
          sizeChanged: successfulWrite.size,
          now: timeoutResetAt
        )
      }
      // A superseded write can still have moved the native window. Keep that
      // physical starting point; process lanes serialize it before replacement.
      let requiresReadback = !intermediate
        && (item.value.isParked || item.value.requiresVerifiedOffscreenWrite)
      if positionApplied, item.value.positionChanged {
        let completedPoint = acceptedPosition ?? point
        recordCompletedPosition(
          completedPoint, windowID: item.key,
          positionWasReadBack: acceptedPosition != nil || requiresReadback
        )
      } else if let acceptedPosition {
        recordCompletedPosition(acceptedPosition, windowID: item.key)
      }
      if sizeApplied, requiresAsynchronousSizeWrite {
        recordCompletedSize(
          acceptedSize ?? size,
          windowID: item.key,
          incrementWriteCount: true,
          sizeWasReadBack: acceptedSize != nil
        )
      }
      guard isCurrent(generation: frame.generation) else {
        stale += 1
        lock.lock()
        appendTraceLocked(
          "stale-completion g=\(frame.generation) pid=\(item.value.processID) wid=\(item.key.rawValue) applied=\(appliedWrite ? 1 : 0) ms=\(String(format: "%.2f", writeElapsedMS))"
        )
        lock.unlock()
        continue
      }
      if positionApplied, item.value.positionChanged {
        applied += 1
        motionCostMS += writeResult.positionDurationMS
          + (timeoutConfiguredAt - writeStartedAt + timeoutResetAt - positionAppliedAt) * 1_000
      }
      if intermediate {
        recordRetargetVelocity(
          frame: frame, progressVelocity: positionApplied ? progressVelocity : 0,
          windowIDs: [item.key]
        )
      }
      if requiresReadback, !intermediate {
        scheduleParkingVerification(
          windowID: item.key,
          expectedPoint: item.value.point
        )
      }
      if recordFinalSuccess, !intermediate, progress >= 1, appliedWrite {
        lock.lock()
        // Publish readiness only after its completed geometry is available.
        if latestGeneration == frame.generation {
          successfulFinalWritesByGeneration[frame.generation, default: []]
            .insert(item.key)
        }
        lock.unlock()
      }
      if !intermediate, progress >= 1, appliedWrite {
        frame.cursorWarpAfterWindowCommit?(item.key, frame.generation)
      }
      if intermediate && (!appliedWrite || writeElapsedMS > 12) {
        slowProcesses.insert(item.value.processID)
      }
      if writeElapsedMS > 16.67 {
        lock.lock()
        appendTraceLocked(
          "slow g=\(frame.generation) pid=\(item.value.processID) windows=1 ms=\(String(format: "%.2f", writeElapsedMS)) setup=\(String(format: "%.2f", (timeoutConfiguredAt - writeStartedAt) * 1_000)) position=\(String(format: "%.2f", writeResult.positionDurationMS)) geometry=\(String(format: "%.2f", (positionAppliedAt - timeoutConfiguredAt) * 1_000 - writeResult.positionDurationMS)) wait=\(String(format: "%.2f", timeoutWaitMS)) reset=\(String(format: "%.2f", (timeoutResetAt - positionAppliedAt) * 1_000)) phase=\(stagingReentry ? "staging" : intermediate ? "motion" : "final")"
        )
        lock.unlock()
      }
    }
    if seedsMotionCost, applied == batch.writes.count, stale == 0,
      isCurrent(generation: frame.generation)
    {
      recordInitialMotionLatency(processID: batch.processID, latencyMS: motionCostMS)
    }
    return (applied, stale, slowProcesses, attempted)
  }

  func hasDeferredEnhancedUIRestore(processID: pid_t) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return deferredEnhancedUIRestores[processID] != nil
  }

  func beginDeferredEnhancedUIRestore(
    processID: pid_t,
    application: AXUIElement
  ) -> UInt64 {
    lock.lock()
    let alreadyDisabled = deferredEnhancedUIRestores[processID]?.disabled == true
    nextEnhancedUIRestoreToken &+= 1
    let token = nextEnhancedUIRestoreToken
    deferredEnhancedUIRestores[processID] = (token, application, alreadyDisabled)
    lock.unlock()
    if !alreadyDisabled {
      let disabled = AXMessagingTimeoutAccess.shared.withTimeout(0.006, elements: [application]) {
        accessibilityWriter.setEnhancedUserInterface(false, application: application)
      }
      lock.lock()
      if deferredEnhancedUIRestores[processID]?.token == token {
        deferredEnhancedUIRestores[processID]?.disabled = disabled
      }
      lock.unlock()
    }
    return token
  }

  func scheduleEnhancedUIRestore(
    processID: pid_t,
    token: UInt64,
    retryFailedRestore: Bool = true
  ) {
    enqueueProcessWrite(
      for: processID,
      after: .now() + enhancedUIRestoreDelay
    ) { [weak self] in
      guard let self else { return }
      lock.lock()
      guard let restore = deferredEnhancedUIRestores[processID],
        restore.token == token
      else {
        lock.unlock()
        return
      }
      deferredEnhancedUIRestores[processID]?.disabled = false
      lock.unlock()
      let restored = AXMessagingTimeoutAccess.shared.withTimeout(0.016, elements: [restore.application]) {
        accessibilityWriter.setEnhancedUserInterface(true, application: restore.application)
      }
      lock.lock()
      let stillCurrent = deferredEnhancedUIRestores[processID]?.token == token
      if restored, stillCurrent { deferredEnhancedUIRestores[processID] = nil }
      if !restored, stillCurrent {
        appendTraceLocked("enhanced-ui-restore-failed pid=\(processID) token=\(token)")
      }
      lock.unlock()
      if !restored, stillCurrent, retryFailedRestore {
        scheduleEnhancedUIRestore(processID: processID, token: token, retryFailedRestore: false)
      }
    }
  }

  func restoreDeferredEnhancedUserInterfaces() {
    lock.lock()
    let restores = deferredEnhancedUIRestores
    lock.unlock()
    for (processID, restore) in restores {
      lock.lock()
      let current = deferredEnhancedUIRestores[processID]?.token == restore.token
      if current { deferredEnhancedUIRestores[processID]?.disabled = false }
      lock.unlock()
      guard current else { continue }
      let restored = AXMessagingTimeoutAccess.shared.withTimeout(0.016, elements: [restore.application]) {
        accessibilityWriter.setEnhancedUserInterface(true, application: restore.application)
          || accessibilityWriter.setEnhancedUserInterface(true, application: restore.application)
      }
      lock.lock()
      if deferredEnhancedUIRestores[processID]?.token == restore.token {
        if restored { deferredEnhancedUIRestores[processID] = nil }
        else { appendTraceLocked("enhanced-ui-restore-failed pid=\(processID) token=\(restore.token) shutdown=1") }
      } else {
        deferredEnhancedUIRestores[processID]?.disabled = false
      }
      lock.unlock()
    }
  }

  func commitFinalSizesOnce(
    _ writes: [WindowID: AsyncPositionWrite],
    generation: UInt64
  ) -> Set<WindowID> {
    guard !writes.isEmpty else { return [] }
    let byProcess = Dictionary(grouping: writes) { $0.value.processID }
    let group = DispatchGroup()
    lock.lock()
    appendTraceLocked(
      "size-commit g=\(generation) processes=\(byProcess.count) windows=\(writes.count)"
    )
    lock.unlock()
    let committed = WindowIDCollector()
    for entries in byProcess.values {
      group.enter()
      enqueueProcessWrite(for: entries[0].value.processID) { [self] in
        defer { group.leave() }
        var succeeded = Set<WindowID>()
        for (windowID, write) in entries.sorted(by: {
          $0.key.rawValue < $1.key.rawValue
        }) {
          guard isCurrent(generation: generation) else { break }
          let writeResult = AXMessagingTimeoutAccess.shared.withTimeout(
            max(write.timeoutSeconds, 0.016),
            elements: [write.application, write.element]
          ) {
            let succeeded = accessibilityWriter.applySize(
              write,
              size: write.size,
              enhancedUIManagedByBatch: false,
              shouldApply: { self.isCurrent(generation: generation) }
            )
            return (
              succeeded: succeeded,
              acceptedSize: succeeded
                ? accessibilityWriter.readSize(write.element) : nil
            )
          }
          guard writeResult.succeeded else { continue }
          succeeded.insert(windowID)
          let completedPoint = completedPosition(for: windowID)
            ?? write.fromPoint
          recordInternalFrameWrite(
            Rect(
              x: completedPoint.x,
              y: completedPoint.y,
              width: write.size.width,
              height: write.size.height
            ),
            windowID: windowID,
            positionChanged: false,
            sizeChanged: true,
            now: ProcessInfo.processInfo.systemUptime
          )
          recordCompletedSize(
            writeResult.acceptedSize ?? write.size,
            windowID: windowID,
            incrementWriteCount: true,
            sizeWasReadBack: writeResult.acceptedSize != nil
          )
        }
        committed.add(succeeded)
      }
    }
    group.wait()
    return committed.value
  }

  func recordCompletedSize(
    _ size: CGSize,
    windowID: WindowID,
    incrementWriteCount: Bool,
    sizeWasReadBack: Bool
  ) {
    lock.lock()
    defer { lock.unlock() }
    completedSizes[windowID] = size
    if incrementWriteCount {
      completedAnimatedSizeWrites += 1
    }
    // A successful AX write can still be clamped by the application.
    guard sizeWasReadBack else { return }
    let now = ProcessInfo.processInfo.systemUptime
    borderGeometryWrittenAt[windowID] = now
    let point = borderGeometries[windowID].map {
      CGPoint(x: $0.frame.x, y: $0.frame.y)
    } ?? completedPositions[windowID]
    if let point {
      borderGeometries[windowID] = (
        Rect(x: point.x, y: point.y, width: size.width, height: size.height), now
      )
    }
  }

  func readAcceptedFrames(
    for frame: QueuedPositionFrame,
    successfulWindowIDs: Set<WindowID>
  ) -> [WindowID: Rect] {
    var acceptedFrames: [WindowID: Rect] = [:]
    let liveBorderWindowID = currentLiveBorderWindowID()
    for (windowID, write) in frame.writes.sorted(by: {
      $0.key.rawValue < $1.key.rawValue
    }) where acceptedFrameRequiresReadback(
      windowID: windowID,
      sizeChanged: write.sizeChanged,
      liveBorderWindowID: liveBorderWindowID
    ) && successfulWindowIDs.contains(windowID) {
      guard isCurrent(generation: frame.generation) else { break }
      let accepted = AXMessagingTimeoutAccess.shared.withTimeout(
        max(write.timeoutSeconds, 0.025),
        elements: [write.application, write.element]
      ) {
        guard let position = accessibilityWriter.readPosition(write.element),
          let size = accessibilityWriter.readSize(write.element)
        else {
          return nil as Rect?
        }
        return Rect(
          x: position.x,
          y: position.y,
          width: size.width,
          height: size.height
        )
      }
      guard let accepted, isCurrent(generation: frame.generation) else {
        continue
      }
      recordCompletedPosition(
        CGPoint(x: accepted.x, y: accepted.y),
        windowID: windowID
      )
      recordCompletedSize(
        CGSize(width: accepted.width, height: accepted.height),
        windowID: windowID,
        incrementWriteCount: false,
        sizeWasReadBack: true
      )
      acceptedFrames[windowID] = accepted
    }
    if !acceptedFrames.isEmpty {
      borderLiveGeometryHandler?(acceptedFrames)
    }
    return acceptedFrames
  }

  func recordInternalFrameWrite(
    _ frame: Rect,
    windowID: WindowID,
    positionChanged: Bool,
    sizeChanged: Bool,
    now: TimeInterval
  ) {
    lock.lock()
    var writes = recentInternalFrameWrites[windowID, default: []]
    writes.removeAll { $0.deadline < now }
    writes.append(RecentInternalFrameWrite(
      frame: frame,
      positionChanged: positionChanged,
      sizeChanged: sizeChanged,
      deadline: now + 2.5
    ))
    recentInternalFrameWrites[windowID] = writes
    lock.unlock()
  }

  func pruneRecentInternalFrameWrites(
    liveWindowIDs: Set<WindowID>,
    now: TimeInterval
  ) {
    lock.lock()
    var pruned: [WindowID: [RecentInternalFrameWrite]] = [:]
    for (windowID, writes) in recentInternalFrameWrites {
      guard liveWindowIDs.contains(windowID) else { continue }
      let unexpired = writes.filter { $0.deadline >= now }
      if !unexpired.isEmpty {
        pruned[windowID] = unexpired
      }
    }
    recentInternalFrameWrites = pruned
    lock.unlock()
  }

  func recordCompletedActiveSizeWrite(windowID: WindowID) {
    lock.lock()
    activeWrites.removeValue(forKey: windowID)
    activeAnimatedSizeWindowIDs.remove(windowID)
    lock.unlock()
  }
}

/// Lock-guarded because per-process write queues merge concurrently.
private final class WindowIDCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var ids = Set<WindowID>()

  func add(_ newIDs: Set<WindowID>) {
    lock.lock()
    ids.formUnion(newIDs)
    lock.unlock()
  }

  var value: Set<WindowID> {
    lock.lock()
    defer { lock.unlock() }
    return ids
  }
}
