import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

@MainActor
extension MacOSPlatform {

  public func completedSize(for windowID: WindowID) -> CGSize? {
    frameCoordinator.completedSize(for: windowID)
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
    let tracesInitialFrame = !newlyDiscoveredWindowIDs.isEmpty
    if tracesInitialFrame {
      let discoveredIDs = newlyDiscoveredWindowIDs.sorted {
        $0.rawValue < $1.rawValue
      }.map { String($0.rawValue) }.joined(separator: ",")
      frameCoordinator.recordTrace("initial-apply ids=[\(discoveredIDs)]")
    }
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
    for assignment in assignments
    where newlyDiscoveredWindowIDs.contains(assignment.windowID)
      && previousTargetFrames[assignment.windowID] == nil
      && !hiddenWindowIDs.contains(assignment.windowID)
      && writeIntents[assignment.windowID] != nil
      && !requiresVerifiedOffscreenWrite(
        frame: assignment.frame,
        monitorFrames: lastMonitorFrames
      )
    {
      initialFrameSettlementDeadlines[assignment.windowID] = now + 2.5
    }
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
      let initialFrameSettlement =
        initialFrameSettlementDeadlines[assignment.windowID].map { $0 > now }
        ?? false
      let commitDeadline = now + frameCommitQuarantineDuration(
        animationDuration: animationDuration,
        initialFrameSettlement: initialFrameSettlement
      )
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
    var initialSettlementTargets: [WindowID: AsyncPositionWrite] = [:]
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
        let sizeWriteStartedAt = ProcessInfo.processInfo.systemUptime
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
        if newlyDiscoveredWindowIDs.contains(assignment.windowID) {
          let elapsedMS =
            (ProcessInfo.processInfo.systemUptime - sizeWriteStartedAt) * 1_000
          frameCoordinator.recordTrace(
            "initial-size wid=\(assignment.windowID.rawValue) result=\(result.rawValue) ms=\(String(format: "%.2f", elapsedMS))"
          )
        }
      }
      if isParked || needsVerifiedOffscreenWrite {
        parkingTargets[assignment.windowID] = write
      }
      if initialFrameSettlementDeadlines[assignment.windowID].map({ $0 > now })
        == true
      {
        initialSettlementTargets[assignment.windowID] = write
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
          positionWriteCount += 1
        }
      }
      pendingFrameCorrections[assignment.windowID] = nil
    }
    frameCoordinator.updateParkingTargets(parkingTargets)
    frameCoordinator.updateInitialSettlementTargets(
      initialSettlementTargets,
      deadlines: initialFrameSettlementDeadlines,
      repairsSuspended: isLeftMouseButtonDown
    )
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
          if let focusWindowIDAfterCommit,
            shouldApplyDeferredFocus(
              targetWindowID: focusWindowIDAfterCommit,
              selectedWindowID: self.desiredSelectedWindowID
            )
          {
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
    if tracesInitialFrame {
      let elapsedMS =
        (ProcessInfo.processInfo.systemUptime - applyStartedAt) * 1_000
      frameCoordinator.recordTrace(
        "initial-apply-complete ms=\(String(format: "%.2f", elapsedMS))"
      )
    }
    if asynchronousWrites.isEmpty, let focusWindowIDAfterCommit,
      shouldApplyDeferredFocus(
        targetWindowID: focusWindowIDAfterCommit,
        selectedWindowID: desiredSelectedWindowID
      )
    {
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

  public func isWindowHidden(_ windowID: WindowID) -> Bool {
    lastHiddenWindowIDs.contains(windowID)
  }

  public func hasPendingFrameTransition(_ windowID: WindowID) -> Bool {
    guard let target = targetFrames[windowID],
      let observed = latestObservedFrames[windowID]
    else {
      return false
    }
    return !approximatelyEqual(observed, target)
  }

  public func acceptObservedFrame(_ frame: Rect, for windowID: WindowID) {
    targetFrames[windowID] = nil
    pendingFrameCorrections[windowID] = nil
    frameCommitExpectations[windowID] = nil
    latestObservedFrames[windowID] = frame
  }

  public func userAdjustedFrames(
    for windowIDs: Set<WindowID>
  ) -> [WindowID: Rect] {
    guard mouseResizeGesturePending, !windowIDs.isEmpty else { return [:] }
    return framesByWindowID(for: windowIDs, in: copyCGWindows())
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

  public var hasNewlyDiscoveredWindows: Bool {
    !newlyDiscoveredWindowIDs.isEmpty
  }

  public func recordPerformanceTrace(_ event: String) {
    frameCoordinator.recordTrace(event)
  }

  public var parkingPerformance: (checks: Int, repairs: Int) {
    frameCoordinator.parkingPerformance
  }

  public var initialSettlementPerformance: (checks: Int, repairs: Int) {
    frameCoordinator.initialSettlementPerformance
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

}
