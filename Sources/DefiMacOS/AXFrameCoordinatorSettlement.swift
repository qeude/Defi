import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog


extension AXFrameCoordinator {
  func scheduleParkingVerification(
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

  func scheduleInitialSettlementVerification(
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

  func verifyInitialSettlementTarget(windowID: WindowID) {
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

    let observedFrame = AXMessagingTimeoutAccess.shared.withTimeout(
      0.025,
      elements: [write.application, write.element]
    ) {
      guard let actualPosition = accessibilityWriter.readPosition(write.element),
        let actualSize = accessibilityWriter.readSize(write.element)
      else {
        return nil as Rect?
      }
      return Rect(
        x: actualPosition.x,
        y: actualPosition.y,
        width: actualSize.width,
        height: actualSize.height
      )
    }
    guard let actual = observedFrame
    else {
      return
    }
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
      lock.lock()
      initialSettlementDriftSamples[windowID] = nil
      lock.unlock()
      return
    case .drifted:
      break
    }
    let observationTime = ProcessInfo.processInfo.systemUptime
    lock.lock()
    let previousDrift = initialSettlementDriftSamples[windowID]
    let driftIsStable = initialSettlementDriftIsStable(
      previous: previousDrift,
      generation: settlementTarget.generation,
      actual: actual,
      now: observationTime
    )
    initialSettlementDriftSamples[windowID] = updatedInitialSettlementDriftSample(
      previous: previousDrift,
      generation: settlementTarget.generation,
      actual: actual,
      now: observationTime
    )
    lock.unlock()
    guard driftIsStable else {
      if let delay = initialSettlementFollowUpDelay(
        now: observationTime,
        deadline: settlementTarget.deadline
      ) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
          self?.verifyInitialSettlementTarget(windowID: windowID)
        }
      }
      return
    }
    guard isInitialSettlementTargetCurrent(
      windowID: windowID,
      generation: settlementTarget.generation
    ) else { return }

    let sizeChanged = abs(actual.width - target.width) > 1
      || abs(actual.height - target.height) > 1
    let positionChanged = abs(actual.x - target.x) > 1
      || abs(actual.y - target.y) > 1
    let repairSucceeded = AXMessagingTimeoutAccess.shared.withTimeout(
      0.025,
      elements: [write.application, write.element]
    ) { [self] in
      if sizeChanged {
        guard isInitialSettlementTargetCurrent(
          windowID: windowID,
          generation: settlementTarget.generation
        ), accessibilityWriter.applySize(write, size: write.size)
        else { return false }
      }
      if positionChanged {
        guard isInitialSettlementTargetCurrent(
          windowID: windowID,
          generation: settlementTarget.generation
        ), accessibilityWriter.applyPosition(write, point: write.point)
        else { return false }
      }
      return true
    }
    guard repairSucceeded else { return }
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
    initialSettlementDriftSamples[windowID] = nil
    repairedInitialSettlementDrifts += 1
    appendTraceLocked(
      "initial-repair wid=\(windowID.rawValue) dx=\(String(format: "%.1f", actual.x - target.x)) dy=\(String(format: "%.1f", actual.y - target.y)) dw=\(String(format: "%.1f", actual.width - target.width)) dh=\(String(format: "%.1f", actual.height - target.height))"
    )
    lock.unlock()
  }

  func clearInitialSettlementTarget(
    windowID: WindowID,
    matchingGeneration expectedGeneration: UInt64
  ) {
    lock.lock()
    if initialSettlementTargets[windowID]?.generation == expectedGeneration {
      initialSettlementTargets[windowID] = nil
      initialSettlementDriftSamples[windowID] = nil
    }
    lock.unlock()
  }

  func isInitialSettlementTargetCurrent(
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

  func sameFrameTarget(
    _ lhs: AsyncPositionWrite,
    _ rhs: AsyncPositionWrite
  ) -> Bool {
    accessibilityWriter.pointDistance(lhs.point, rhs.point) <= 0.1
      && abs(lhs.size.width - rhs.size.width) <= 0.1
      && abs(lhs.size.height - rhs.size.height) <= 0.1
  }

  func verifyParkingTarget(
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
    markProcessNeedsImmediateReadback(write.processID)
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

  func isCurrent(generation: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return latestGeneration == generation
  }

  func recordCompletedPosition(
    _ point: CGPoint,
    windowID: WindowID
  ) {
    lock.lock()
    completedPositions[windowID] = point
    lock.unlock()
  }

  func appendTraceLocked(_ event: String) {
    let uptime = ProcessInfo.processInfo.systemUptime
    traceEntries.append(String(format: "%.6f %@", uptime, event))
    if traceEntries.count > 512 {
      traceEntries.removeFirst(traceEntries.count - 512)
    }
    if traceEventIsDiagnosticAnomaly(event) {
      diagnosticAnomalyHandler?(uptime, event)
    }
  }
}

func traceEventIsDiagnosticAnomaly(_ event: String) -> Bool {
  [
    "focus-recovery ",
    "initial-repair ",
    "parking-repair ",
    "slow ",
    "slow-lane ",
    "stale-completion ",
  ].contains { event.hasPrefix($0) }
}
