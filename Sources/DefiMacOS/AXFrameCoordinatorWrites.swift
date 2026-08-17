import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog


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
            stagingReentry: stagingReentry,
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

  func processWriteQueue(for processID: pid_t) -> DispatchQueue {
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

  func recordProcessLatencySamples(
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

  func applyBatch(
    _ batch: ProcessWriteBatch,
    frame: QueuedPositionFrame,
    progress: Double,
    intermediate: Bool,
    stagingReentry: Bool,
    recordFinalSuccess: Bool
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
      let requiresAsynchronousSizeWrite = asynchronousSizeWriteIsRequired(
        sizeChanged: item.value.sizeChanged,
        synchronousWriteSucceeded: item.value.synchronousSizeWriteSucceeded,
        animatesSize: item.value.animatesSize
      )
      let writeResult = AXMessagingTimeoutAccess.shared.withTimeout(
        timeout,
        elements: [item.value.application, item.value.element]
      ) {
        let timeoutConfiguredAt = ProcessInfo.processInfo.systemUptime
        let generationIsCurrent = isCurrent(generation: frame.generation)
        let asynchronousSizeWriteSucceeded =
          generationIsCurrent
          && (
            !requiresAsynchronousSizeWrite
              || accessibilityWriter.applySize(item.value, size: size)
          )
        let sizeApplied = frameSizeWriteSucceeded(
          sizeChanged: item.value.sizeChanged,
          synchronousWriteSucceeded: item.value.synchronousSizeWriteSucceeded,
          animatesSize: item.value.animatesSize,
          asynchronousWriteSucceeded: asynchronousSizeWriteSucceeded
        )
        let positionApplied =
          generationIsCurrent
          && (
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
            )
        return (
          sizeApplied: sizeApplied,
          positionApplied: positionApplied,
          timeoutConfiguredAt: timeoutConfiguredAt,
          positionAppliedAt: ProcessInfo.processInfo.systemUptime
        )
      }
      let sizeApplied = writeResult.sizeApplied
      let positionApplied = writeResult.positionApplied
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
      guard isCurrent(generation: frame.generation) else {
        stale += 1
        lock.lock()
        appendTraceLocked(
          "stale-completion g=\(frame.generation) pid=\(item.value.processID) wid=\(item.key.rawValue) applied=\(appliedWrite ? 1 : 0) ms=\(String(format: "%.2f", writeElapsedMS))"
        )
        lock.unlock()
        continue
      }
      if recordFinalSuccess, !intermediate, progress >= 1, appliedWrite {
        lock.lock()
        successfulFinalWritesByGeneration[frame.generation, default: []]
          .insert(item.key)
        lock.unlock()
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
      if sizeApplied, requiresAsynchronousSizeWrite {
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

  func recordCompletedSize(
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

  func pruneRecentInternalFrameWrites(liveWindowIDs: Set<WindowID>) {
    lock.lock()
    recentInternalFrameWrites = recentInternalFrameWrites.filter {
      liveWindowIDs.contains($0.key)
    }
    lock.unlock()
  }

  func recordCompletedActiveSizeWrite(windowID: WindowID) {
    lock.lock()
    activeWrites.removeValue(forKey: windowID)
    lock.unlock()
  }
}
