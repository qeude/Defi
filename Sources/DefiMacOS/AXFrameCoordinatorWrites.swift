import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

private let enhancedUIRestoreDelay: TimeInterval = 0.12

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
      let batches = processWriteBatches(
        frame.writes,
        windowIDs: phase,
        skippedProcesses: skippedProcesses
      )
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
            attempted: result.attempted,
            completedAt: ProcessInfo.processInfo.systemUptime
          )
          group.leave()
        }
      }
      group.wait()
    }
    let result = accumulator.result
    if !result.processLatencySamplesMS.isEmpty {
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
      ProcessWriteBatch(processID: $0.key, writes: $0.value)
    }.sorted { $0.processID < $1.processID }
  }

  func submitAnimationSamples(
    _ samples: [ProcessAnimationSample],
    processQueues: [pid_t: DispatchQueue]
  ) -> Int {
    for _ in samples {
      animationLaneWriteGroup.enter()
    }
    var displacedSamples: [ProcessAnimationSample] = []
    var startingSamples: [ProcessAnimationSample] = []
    animationLaneLock.lock()
    for sample in samples {
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
      let queue =
        processQueues[sample.batch.processID]
        ?? processWriteQueue(for: sample.batch.processID)
      queue.async { [self] in
        drainAnimationLane(processID: sample.batch.processID)
      }
    }
    return displacedSamples.count
  }

  func drainAnimationLane(processID: pid_t) {
    while true {
      animationLaneLock.lock()
      guard var lane = processAnimationLanes[processID],
        let sample = lane.takeNext()
      else {
        processAnimationLanes[processID] = nil
        animationLaneLock.unlock()
        return
      }
      processAnimationLanes[processID] = lane
      animationLaneLock.unlock()

      let startedAt = ProcessInfo.processInfo.systemUptime
      let result = applyBatch(
        sample.batch,
        frame: sample.frame,
        progress: sample.progress,
        intermediate: sample.intermediate,
        stagingReentry: sample.stagingReentry,
        recordFinalSuccess: sample.recordFinalSuccess
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
        completedAt: completedAt
      )
      if result.attempted {
        recordProcessLatencySamples([processID: latencyMS])
      }
      publishCompletedBorderGeometry(
        Dictionary(uniqueKeysWithValues: sample.batch.writes)
      )
      if sample.intermediate {
        recordRetargetVelocity(
          frame: sample.frame,
          progressVelocity: sample.progressVelocity,
          windowIDs: Set(sample.batch.writes.map(\.key))
        )
      }
      sample.completion?()
      animationLaneWriteGroup.leave()
    }
  }

  func processWriteQueue(for processID: pid_t) -> DispatchQueue {
    lock.lock()
    defer { lock.unlock() }
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
    finalOnlyAnimationProcessIDs(
      for: Set(writes.values.map(\.processID)),
      animationDuration: animationDuration,
      refreshRateHz: refreshRateHz
    )
  }

  func animationSupportsIntermediateFrames(
    processIDs: Set<pid_t>,
    animationDuration: TimeInterval,
    refreshRateHz: Double
  ) -> Bool {
    let availableIntermediateFrames = completedFrameSpringSamples(
      duration: animationDuration,
      refreshRateHz: refreshRateHz
    ).count
    lock.lock()
    defer { lock.unlock() }
    return processIDs.allSatisfy {
      adaptiveIntermediateFrameLimit(
        predictedFrameLatency: (predictedProcessLatencyMS[$0] ?? 0) / 1_000,
        refreshRateHz: refreshRateHz,
        availableIntermediateFrames: availableIntermediateFrames
      ) >= 2
    }
  }

  private func finalOnlyAnimationProcessIDs(
    for processIDs: Set<pid_t>,
    animationDuration: TimeInterval,
    refreshRateHz: Double
  ) -> Set<pid_t> {
    let availableIntermediateFrames = completedFrameSpringSamples(
      duration: animationDuration,
      refreshRateHz: refreshRateHz
    ).count
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
          availableIntermediateFrames: availableIntermediateFrames
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
    recordFinalSuccess: Bool
  ) -> (
    applied: Int,
    stale: Int,
    slowProcesses: Set<pid_t>,
    attempted: Bool
  ) {
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
    let defersEnhancedUIRestore =
      enhancedUIWasEnabled
      && (
        pendingEnhancedUIRestore
          || batch.writes.contains {
            DefiMacOS.defersEnhancedUIRestore(
              stagesVisibleBeforeParking: frame.stagesVisibleBeforeParking,
              isIntermediate: intermediate,
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
        accessibilityWriter.setEnhancedUserInterface(
          false,
          application: batchApplication
        )
      }
    }
    defer {
      if let enhancedUIRestoreToken {
        scheduleEnhancedUIRestore(
          processID: batch.processID,
          token: enhancedUIRestoreToken
        )
      } else if let batchApplication, managesEnhancedUI {
        accessibilityWriter.setEnhancedUserInterface(
          true,
          application: batchApplication
        )
      }
    }
    for (index, item) in batch.writes.enumerated() {
      guard isCurrent(generation: frame.generation) else {
        stale += batch.writes.count - index
        break
      }
      attempted = true
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
      let readsLiveBorderPosition = acceptedFrameRequiresReadback(
        windowID: item.key,
        sizeChanged: false,
        liveBorderWindowID: currentLiveBorderWindowID()
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
              || accessibilityWriter.applySize(
                item.value,
                size: size,
                enhancedUIManagedByBatch: managesEnhancedUI
                  || defersEnhancedUIRestore
              )
          )
        let sizeApplied = frameSizeWriteSucceeded(
          sizeChanged: item.value.sizeChanged,
          synchronousWriteSucceeded: item.value.synchronousSizeWriteSucceeded,
          animatesSize: item.value.animatesSize,
          asynchronousWriteSucceeded: asynchronousSizeWriteSucceeded
        )
        let acceptedSize =
          sizeApplied && requiresAsynchronousSizeWrite && !intermediate
            && progress >= 1
          ? accessibilityWriter.readSize(item.value.element)
          : nil
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
                ),
                enhancedUIManagedByBatch: managesEnhancedUI
                  || defersEnhancedUIRestore
              )
            )
        let acceptedPosition =
          positionApplied && readsLiveBorderPosition
            ? accessibilityWriter.readPosition(item.value.element)
            : nil
        return (
          sizeApplied: sizeApplied,
          acceptedSize: acceptedSize,
          positionApplied: positionApplied,
          acceptedPosition: acceptedPosition,
          timeoutConfiguredAt: timeoutConfiguredAt,
          positionAppliedAt: ProcessInfo.processInfo.systemUptime
        )
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
          acceptedPosition
          ?? (requiresReadback
          && processNeedsImmediateReadback(item.value.processID)
          ? accessibilityWriter.readPosition(item.value.element) ?? point
          : point)
        recordCompletedPosition(completedPoint, windowID: item.key)
      } else if let acceptedPosition {
        recordCompletedPosition(acceptedPosition, windowID: item.key)
      }
      if sizeApplied, requiresAsynchronousSizeWrite {
        recordCompletedSize(
          acceptedSize ?? size,
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
      if !intermediate, progress >= 1, appliedWrite {
        frame.cursorWarpAfterWindowCommit?(item.key, frame.generation)
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
    nextEnhancedUIRestoreToken &+= 1
    let token = nextEnhancedUIRestoreToken
    deferredEnhancedUIRestores[processID] = (token, application)
    lock.unlock()
    accessibilityWriter.setEnhancedUserInterface(
      false,
      application: application
    )
    return token
  }

  func scheduleEnhancedUIRestore(
    processID: pid_t,
    token: UInt64
  ) {
    processWriteQueue(for: processID).asyncAfter(
      deadline: .now() + enhancedUIRestoreDelay
    ) { [weak self] in
      guard let self else { return }
      lock.lock()
      guard let restore = deferredEnhancedUIRestores[processID],
        restore.token == token
      else {
        lock.unlock()
        return
      }
      deferredEnhancedUIRestores[processID] = nil
      lock.unlock()
      accessibilityWriter.setEnhancedUserInterface(
        true,
        application: restore.application
      )
    }
  }

  func restoreDeferredEnhancedUserInterfaces() {
    lock.lock()
    let restores = Array(deferredEnhancedUIRestores.values)
    deferredEnhancedUIRestores.removeAll(keepingCapacity: true)
    lock.unlock()
    for restore in restores {
      accessibilityWriter.setEnhancedUserInterface(
        true,
        application: restore.application
      )
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
      processWriteQueue(for: entries[0].value.processID).async { [self] in
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
              enhancedUIManagedByBatch: false
            )
            return (
              succeeded: succeeded,
              acceptedSize: succeeded
                ? accessibilityWriter.readSize(write.element) : nil
            )
          }
          guard writeResult.succeeded else { continue }
          succeeded.insert(windowID)
          recordInternalFrameWrite(
            Rect(
              x: write.fromPoint.x,
              y: write.fromPoint.y,
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
            incrementWriteCount: true
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
    incrementWriteCount: Bool
  ) {
    lock.lock()
    completedSizes[windowID] = size
    if incrementWriteCount {
      completedAnimatedSizeWrites += 1
    }
    lock.unlock()
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
        incrementWriteCount: false
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
