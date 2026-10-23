import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog
import Synchronization

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
    skippedProcesses: Set<pid_t>
  ) -> (applied: Int, stale: Int) {
    guard isCurrent(generation: frame.generation) else {
      let stale = frame.writes.values.lazy.filter { !skippedProcesses.contains($0.processID) }.count
      return (0, stale)
    }
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
        enqueueProcessWrite(for: batch.processID) { [self] in
          defer { group.leave() }
          let batchStartedAt = ProcessInfo.processInfo.systemUptime
          let result = applyBatch(batch, frame: frame)
          accumulator.add(
            applied: result.applied,
            stale: result.stale,
            processID: batch.processID,
            processLatencyMS: (ProcessInfo.processInfo.systemUptime - batchStartedAt) * 1_000,
            attempted: result.attempted
          )
        }
      }
      group.wait()
    }
    let result = accumulator.result
    if !result.processLatencySamplesMS.isEmpty {
      recordProcessLatencySamples(result.processLatencySamplesMS)
    }
    return (result.applied, result.stale)
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
      label: "com.qeude.defi.ax-process-\(processID)",
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

  func recordProcessLatencySamples(_ samplesMS: [pid_t: Double]) {
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
    applicationTimeoutManagedByBatch: Bool = false
  ) -> BatchResult {
    guard isCurrent(generation: frame.generation) else {
      return (0, batch.writes.count, false)
    }
    if let batchWriter {
      return batchWriter(batch, frame)
    }
    if !applicationTimeoutManagedByBatch, batch.writes.count > 1,
      let first = batch.writes.first?.value,
      !hasDeferredEnhancedUIRestore(processID: batch.processID),
      batch.writes.allSatisfy({
        $0.value.processID == batch.processID && !$0.value.enhancedUIWasEnabled
          && CFEqual($0.value.application, first.application)
          && !CFEqual($0.value.element, first.application)
          && frameMessagingTimeout($0.value) == frameMessagingTimeout(first)
      })
    {
      return messagingTimeoutAccess.withTimeout(
        frameMessagingTimeout(first), elements: [first.application]
      ) {
        applyBatch(batch, frame: frame, applicationTimeoutManagedByBatch: true)
      }
    }
    var applied = 0
    var stale = 0
    var attempted = false
    let batchApplication = batch.writes.first?.value.application
    let enhancedUIWasEnabled = batch.writes.contains {
      $0.value.enhancedUIWasEnabled
    }
    let pendingEnhancedUIRestore = hasDeferredEnhancedUIRestore(
      processID: batch.processID
    )
    // Keep the app's own animation disabled through every position write and its
    // asynchronous consumption.
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
        _ = messagingTimeoutAccess.withTimeout(0.006, elements: [batchApplication]) {
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
        _ = messagingTimeoutAccess.withTimeout(0.016, elements: [batchApplication]) {
          accessibilityWriter.setEnhancedUserInterface(true, application: batchApplication)
        }
      }
    }
    for (index, item) in batch.writes.enumerated() {
      guard isCurrent(generation: frame.generation) else {
        stale += batch.writes.count - index
        break
      }
      let point = item.value.point
      let size = item.value.size
      let writeStartedAt = ProcessInfo.processInfo.systemUptime
      let timeout = frameMessagingTimeout(item.value)
      let requiresAsynchronousSizeWrite = asynchronousSizeWriteIsRequired(
        sizeChanged: item.value.sizeChanged,
        synchronousWriteSucceeded: item.value.synchronousSizeWriteSucceeded
      )
      let positionWriteRequired = item.value.positionChanged
      let readsLiveBorderPosition = acceptedFrameRequiresReadback(
        windowID: item.key,
        sizeChanged: false,
        liveBorderWindowID: currentLiveBorderWindowID()
      )
      let readsImmediatePosition =
        (item.value.isParked || item.value.requiresVerifiedOffscreenWrite)
        && processNeedsImmediateReadback(item.value.processID)
      // Presentation already samples native geometry independently. Right after a
      // write, WindowServer can lag slow apps by frames; the written point is the
      // better border position for horizontal motion.
      let defersBorderReadback = readsLiveBorderPosition
        && !requiresAsynchronousSizeWrite
        && item.value.fromPoint.y == item.value.point.y
        && !item.value.isParked
        && !item.value.requiresVerifiedOffscreenWrite && !readsImmediatePosition
        && accessibilityWriter.independentBorderObservationAvailable()
      attempted = true
      var timeoutWaitMS = 0.0
      let writeResult = messagingTimeoutAccess.withTimeout(
        timeout,
        elements: applicationTimeoutManagedByBatch ? [item.value.element] : [item.value.application, item.value.element],
        observeWait: { timeoutWaitMS = $0 * 1_000 }
      ) {
        let timeoutConfiguredAt = ProcessInfo.processInfo.systemUptime
        let generationIsCurrent = isCurrent(generation: frame.generation)
        // Growth that macOS would clamp to the display at the window's current
        // position resizes after the move instead.
        let currentPoint = completedPosition(for: item.key) ?? item.value.fromPoint
        let resizesAfterMove = requiresAsynchronousSizeWrite && positionWriteRequired
          && (size.width > item.value.fromSize.width + 0.5 || size.height > item.value.fromSize.height + 0.5)
          && !requiresVerifiedOffscreenWrite(
            frame: Rect(x: point.x, y: point.y, width: size.width, height: size.height),
            monitorFrames: frame.monitorFrames)
          && shouldDeferAnimatedSizeUntilMovementCompletes(
            from: Rect(x: currentPoint.x, y: currentPoint.y, width: size.width, height: size.height),
            to: Rect(x: point.x, y: point.y, width: size.width, height: size.height),
            displayFrames: frame.monitorFrames)
        var sizeApplied = false
        var acceptedSize: CGSize?
        let applyAsynchronousSize = {
          let asynchronousSizeWriteSucceeded =
            self.isCurrent(generation: frame.generation)
            && (
              !requiresAsynchronousSizeWrite
                || self.accessibilityWriter.applySize(
                  item.value,
                  size: size,
                  enhancedUIManagedByBatch: managesEnhancedUI
                    || defersEnhancedUIRestore,
                  shouldApply: { self.isCurrent(generation: frame.generation) }
                )
            )
          sizeApplied = frameSizeWriteSucceeded(
            sizeChanged: item.value.sizeChanged,
            synchronousWriteSucceeded: item.value.synchronousSizeWriteSucceeded,
            asynchronousWriteSucceeded: asynchronousSizeWriteSucceeded
          )
          acceptedSize = sizeApplied && requiresAsynchronousSizeWrite
            ? self.accessibilityWriter.readSize(item.value.element)
            : nil
        }
        if !resizesAfterMove { applyAsynchronousSize() }
        let sizeWasClampedBeforeMove = item.value.positionChanged && !resizesAfterMove
          && (acceptedSize.map {
            abs($0.width - size.width) >= 0.5 || abs($0.height - size.height) >= 0.5
          } ?? false)
        let applyFinalPosition = {
          self.accessibilityWriter.applyPosition(
            item.value,
            point: point,
            forceOffscreenAccess: item.value.requiresVerifiedOffscreenWrite,
            verifyParkedPosition: true,
            enhancedUIManagedByBatch: managesEnhancedUI || defersEnhancedUIRestore,
            shouldApply: { self.isCurrent(generation: frame.generation) }
          )
        }
        let positionStartedAt = ProcessInfo.processInfo.systemUptime
        var positionApplied = generationIsCurrent
          && (!positionWriteRequired || applyFinalPosition())
        let positionDurationMS =
          (ProcessInfo.processInfo.systemUptime - positionStartedAt) * 1_000
        if resizesAfterMove {
          applyAsynchronousSize()
          if sizeApplied, isCurrent(generation: frame.generation) {
            // A busy app can apply the move after the resize and clamp it; retry once.
            if let accepted = acceptedSize,
              abs(accepted.width - size.width) >= 0.5 || abs(accepted.height - size.height) >= 0.5
            {
              applyAsynchronousSize()
            }
            // A resize can shift the origin; correct the final position once.
            positionApplied = accessibilityWriter.applyPosition(
              item.value, point: point, forceOffscreenAccess: false, verifyParkedPosition: true,
              enhancedUIManagedByBatch: managesEnhancedUI || defersEnhancedUIRestore,
                shouldApply: { self.isCurrent(generation: frame.generation) })
          }
        }
        // AppKit can clamp a resize at the source position, even on the same
        // display. Retry the final size once after moving, only after a measured
        // mismatch.
        if positionApplied, sizeWasClampedBeforeMove, isCurrent(generation: frame.generation) {
          sizeApplied = accessibilityWriter.applySize(
            item.value, size: size,
            enhancedUIManagedByBatch: managesEnhancedUI || defersEnhancedUIRestore,
            shouldApply: { self.isCurrent(generation: frame.generation) }
          )
          acceptedSize = sizeApplied ? accessibilityWriter.readSize(item.value.element) : nil
          if isCurrent(generation: frame.generation) {
            positionApplied = applyFinalPosition()
          }
        }
        // Keep borders on observed geometry without another message to the app's AX
        // handler. Mandatory AX readback and unavailable WindowServer metadata keep
        // their existing fallback.
        let acceptedPosition = positionApplied
          && ((readsLiveBorderPosition && !defersBorderReadback) || readsImmediatePosition)
          ? accessibilityWriter.readPosition(item.value.element) : nil
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
      let sizeApplied = writeResult.sizeApplied
      let acceptedSize = writeResult.acceptedSize
      let positionApplied = writeResult.positionApplied
      let acceptedPosition = writeResult.acceptedPosition
      let appliedWrite = sizeApplied && positionApplied
      let successfulWrite = successfulFrameWriteIntent(
        positionChanged: positionWriteRequired,
        positionApplied: positionApplied,
        sizeChanged: requiresAsynchronousSizeWrite,
        sizeApplied: sizeApplied
      )
      let timeoutConfiguredAt = writeResult.timeoutConfiguredAt
      let positionAppliedAt = writeResult.positionAppliedAt
      let timeoutResetAt = ProcessInfo.processInfo.systemUptime
      let writeElapsedMS =
        (timeoutResetAt - writeStartedAt) * 1_000
      if sizeApplied, requiresAsynchronousSizeWrite {
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
      let requiresReadback = item.value.isParked || item.value.requiresVerifiedOffscreenWrite
      if positionApplied, positionWriteRequired {
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
      if positionApplied, positionWriteRequired {
        applied += 1
      }
      if requiresReadback {
        scheduleParkingVerification(
          windowID: item.key,
          expectedPoint: item.value.point
        )
      }
      if appliedWrite {
        lock.lock()
        // Publish readiness only after its completed geometry is available.
        if latestGeneration == frame.generation {
          successfulFinalWritesByGeneration[frame.generation, default: []]
            .insert(item.key)
        }
        lock.unlock()
        frame.cursorWarpAfterWindowCommit?(item.key, frame.generation)
      }
      if writeElapsedMS > 16.67 {
        lock.lock()
        appendTraceLocked(
          "slow g=\(frame.generation) pid=\(item.value.processID) windows=1 ms=\(String(format: "%.2f", writeElapsedMS)) setup=\(String(format: "%.2f", (timeoutConfiguredAt - writeStartedAt) * 1_000)) position=\(String(format: "%.2f", writeResult.positionDurationMS)) geometry=\(String(format: "%.2f", (positionAppliedAt - timeoutConfiguredAt) * 1_000 - writeResult.positionDurationMS)) wait=\(String(format: "%.2f", timeoutWaitMS)) reset=\(String(format: "%.2f", (timeoutResetAt - positionAppliedAt) * 1_000))"
        )
        lock.unlock()
      }
    }
    return (applied, stale, attempted)
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
      let disabled = messagingTimeoutAccess.withTimeout(0.006, elements: [application]) {
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
      let restored = messagingTimeoutAccess.withTimeout(0.016, elements: [restore.application]) {
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
      let restored = messagingTimeoutAccess.withTimeout(0.016, elements: [restore.application]) {
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
      completedAsynchronousSizeWrites += 1
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
  ) -> [BorderGeometryObservation] {
    guard let snapshotEngine else { return [] }
    let liveBorderWindowID = currentLiveBorderWindowID()
    let eligible = frame.writes.filter { windowID, write in
      successfulWindowIDs.contains(windowID) && write.binding != nil && acceptedFrameRequiresReadback(
        windowID: windowID, sizeChanged: write.sizeChanged, liveBorderWindowID: liveBorderWindowID
      )
    }
    let batches = Dictionary(grouping: eligible, by: { $0.value.processID })
    let reservations = batches.mapValues { reserveProcessWriteQueue(for: $0[0].value.processID) }
    let results = Mutex<[BorderGeometryObservation]>([])
    let group = DispatchGroup()
    for (processID, writes) in batches {
      guard let reservation = reservations[processID] else { continue }
      group.enter()
      reservation.queue.async { [self, reservation] in
        defer { reservation.release(); group.leave() }
        var observed: [BorderGeometryObservation] = []
        for (_, write) in writes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
          guard isCurrent(generation: frame.generation) else { break }
          guard let target = write.binding, snapshotEngine.borderBindingIsCurrent(target) else { continue }
          let sampledAt = ProcessInfo.processInfo.systemUptime
          let accepted = messagingTimeoutAccess.withTimeout(
            max(write.timeoutSeconds, 0.025), elements: [target.application, target.element]
          ) { accessibilityWriter.readFrame(target.element) }
          if let accepted, snapshotEngine.borderBindingIsCurrent(target) {
            observed.append(BorderGeometryObservation(
              ticket: BorderGeometryReadTicket(target: target, generation: frame.generation),
              sampledAt: sampledAt, frame: accepted))
          }
        }
        results.withLock { $0.append(contentsOf: observed) }
      }
    }
    group.wait()
    let accepted = snapshotEngine.reconcileAcceptedObservations(results.withLock { $0 })
    if !accepted.isEmpty {
      borderLiveGeometryHandler?(Dictionary(uniqueKeysWithValues: accepted.map { ($0.windowID, $0.frame) }))
    }
    return accepted
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

private func frameMessagingTimeout(_ write: AsyncPositionWrite) -> Float {
  max(write.timeoutSeconds, 0.016)
}
