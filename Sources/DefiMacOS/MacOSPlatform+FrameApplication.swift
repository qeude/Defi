import DefiRuntime
import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

func reentryTransitionDelta(
  reentryStart: CGPoint,
  reentryTarget: Rect,
  candidateStart: CGPoint,
  candidateTarget: Rect
) -> CGPoint? {
  let delta = CGPoint(
    x: candidateTarget.x - candidateStart.x,
    y: candidateTarget.y - candidateStart.y
  )
  guard abs(delta.x) >= 0.5 || abs(delta.y) >= 0.5 else { return nil }
  guard abs(delta.y) > abs(delta.x) else {
    return CGPoint(x: delta.x, y: 0)
  }
  let reentryDelta = CGPoint(
    x: reentryTarget.x - reentryStart.x,
    y: reentryTarget.y - reentryStart.y
  )
  guard abs(reentryDelta.x - delta.x) >= 0.5
    || abs(reentryDelta.y - delta.y) >= 0.5
  else { return nil }
  return CGPoint(x: 0, y: delta.y)
}

@NavigationActor
extension MacOSPlatform {

  public func completedSize(for windowID: WindowID) -> CGSize? {
    frameCoordinator.completedSize(for: windowID)
  }

  public func apply(
    _ assignments: [FrameAssignment],
    ribbonFrames: [FrameAssignment] = [],
    hiddenWindowIDs: Set<WindowID> = [],
    skipping requestedSkippedWindowIDs: Set<WindowID> = [],
    asynchronousPositionTimeoutSeconds: Float = 0.016,
    animationDuration: TimeInterval = 0,
    animationRefreshRateHz: Double = 60,
    animationDisplayIDs: Set<UInt64> = [],
    animateSizeChanges: Bool = false,
    positionsOnly: Bool = false,
    updateVisibility: Bool = true,
    stagesVisibleBeforeParking: Bool = false,
    focusWindowIDAfterCommit: WindowID? = nil,
    focusInputTimestampAfterCommit: TimeInterval? = nil,
    cursorWarpWindowIDAfterCommit: WindowID? = nil,
    cursorWarpInputTimestampAfterCommit: TimeInterval? = nil,
    focusCompletionAfterCommit:
      (@NavigationActor @Sendable (NativeFocusResult) -> Void)? = nil,
    cursorWarpIsCurrentAfterCommit:
      (@NavigationActor @Sendable () -> Bool)? = nil,
    focusRequestIDAfterCommit:
      (@NavigationActor @Sendable (NativeFocusRequestID?) -> Void)? = nil,
    acceptedFrameHandler:
      (@NavigationActor @Sendable ([WindowID: Rect]) -> Void)? = nil,
    commandPerformance: CommandPerformanceContext? = nil,
    source: String = "platform"
  ) {
    if experimentalSurfaceRibbonEnabled && source != "command-animation" {
      snapshotEngine.onMain { _ in
        ExperimentalRibbonRenderer.shared.supersedeIfTargetsChanged(assignments)
      }
    }
    let usesSurfaceRibbon = experimentalSurfaceRibbonEnabled && source == "command-animation" && positionsOnly
      && snapshotEngine.onMain { platform in
        ExperimentalRibbonRenderer.shared.begin(assignments: assignments, duration: animationDuration,
          borderStyle: platform.borderStyle, selectedWindowID: platform.borderSelectedWindowID)
      }
    let animationDuration = usesSurfaceRibbon ? 0 : animationDuration
    frameSubmissionGeneration &+= 1
    let submissionGeneration = frameSubmissionGeneration
    let skippedWindowIDs = requestedSkippedWindowIDs.union(
      nativeFullscreenWindowIDs
    )
    let horizontalRibbonNavigation = source == "command-animation" && positionsOnly
      && lastMonitorFrames.count == 1 && !ribbonFrames.isEmpty
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
      let reference = frameApplicationReference(
        pendingCorrection: pendingFrameCorrections[assignment.windowID],
        settlingReference: settlingReference,
        completedPosition: frameCoordinator.completedPosition(
          for: assignment.windowID
        ),
        previousTarget: previousTargetFrames[assignment.windowID],
        prefersCompletedPosition: horizontalRibbonNavigation,
        nativeReference: latestObservedFrames[assignment.windowID]
          ?? lastSnapshotWindows.first(where: { $0.id == assignment.windowID })?.frame
      )
      guard let reference else { continue }
      let intent = frameWriteIntent(
        reference: reference,
        target: assignment.frame,
        positionsOnly: positionsOnly,
        horizontalOnly: horizontalRibbonNavigation
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
    if !writeIntents.isEmpty {
      invalidatePointerHitTestCache()
    }
    targetFrames = frameTargetsPreservingSkippedWindows(
      previous: previousTargetFrames,
      assignments: assignments,
      skippedWindowIDs: skippedWindowIDs
    )
    if let commandPerformance {
      let performancePlan = commandPerformanceFramePlan(
        writeWindowIDs: Set(writeIntents.keys),
        hiddenWindowIDs: effectiveHiddenWindowIDs,
        availableWindowIDs: Set(elements.keys)
      )
      recordCommandPlan(
        commandPerformance,
        expectedWindowIDs: performancePlan.expectedWindowIDs,
        hasFrameWrites: performancePlan.hasMeasuredFrameWrites,
        at: ProcessInfo.processInfo.systemUptime
      )
    }
    var writePerformanceByWindowID: [WindowID: CommandPerformanceContext] = [:]
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
    // Logical strip endpoints differ from the safe native parking anchors.
    // Use them only on a single display: an offscreen logical path must never
    // sweep a user window through another monitor's visible region.
    let ribbonTargets = source == "command-animation" && positionsOnly
      && lastMonitorFrames.count == 1
      ? Dictionary(uniqueKeysWithValues: ribbonFrames.map { ($0.windowID, $0.frame) })
      : [:]
    let sharedRibbonOffset = lastMonitorFrames.count == 1 ? commonRibbonOffset(
      targets: ribbonTargets.mapValues { CGPoint(x: $0.x, y: $0.y) },
      starts: animationStartPositions, sizes: animationStartSizes,
      monitor: lastMonitorFrames[0]) : nil
    let newlyUnparkedWindowIDs =
      lastHiddenWindowIDs.subtracting(effectiveHiddenWindowIDs)
    var reenteringWindowIDs = Set<WindowID>()
    for assignment in assignments
    where newlyUnparkedWindowIDs.contains(assignment.windowID) {
      guard let reentryStart = animationStartPositions[assignment.windowID]
      else { continue }
      let nearestTransition = assignments.compactMap {
        candidate -> (distance: Double, delta: CGPoint)? in
        guard candidate.windowID != assignment.windowID,
          !hiddenWindowIDs.contains(candidate.windowID),
          !newlyUnparkedWindowIDs.contains(candidate.windowID),
          let candidateStart = animationStartPositions[candidate.windowID],
          let delta = reentryTransitionDelta(
            reentryStart: reentryStart,
            reentryTarget: assignment.frame,
            candidateStart: candidateStart,
            candidateTarget: candidate.frame
          )
        else {
          return nil
        }
        let distance =
          abs(candidate.frame.x - assignment.frame.x)
          + abs(candidate.frame.y - assignment.frame.y)
        return (distance, delta)
      }.min { $0.distance < $1.distance }
      guard let nearestTransition else { continue }
      let plannedStart = CGPoint(
        x: assignment.frame.x - nearestTransition.delta.x,
        y: assignment.frame.y - nearestTransition.delta.y
      )
      animationStartPositions[assignment.windowID] = plannedStart
      if reentryStartRequiresStaging(
        observed: reentryStart,
        planned: plannedStart
      ) {
        reenteringWindowIDs.insert(assignment.windowID)
      }
    }
    if let offset = sharedRibbonOffset {
      for assignment in assignments {
        guard let logical = ribbonTargets[assignment.windowID],
          let observed = startPositions[assignment.windowID],
          let size = animationStartSizes[assignment.windowID] else { continue }
        let planned = CGPoint(x: logical.x + offset, y: observed.y)
        let observedFrame = Rect(x: observed.x, y: observed.y,
          width: size.width, height: size.height)
        let plannedFrame = Rect(x: planned.x, y: planned.y,
          width: size.width, height: size.height)
        guard transitionCrossesViewport(from: plannedFrame, to: logical) else { continue }
        animationStartPositions[assignment.windowID] = planned
        if requiresVerifiedOffscreenWrite(frame: observedFrame, monitorFrames: lastMonitorFrames),
          reentryStartRequiresStaging(observed: observed, planned: planned)
        {
          reenteringWindowIDs.insert(assignment.windowID)
        }
      }
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
      let continuedCommand = frameCommitExpectations[assignment.windowID]
        .flatMap { expectation in
          expectation.deadline > now
            && approximatelyEqual(expectation.target, assignment.frame)
            ? expectation.command
            : nil
        }
      if let writePerformance = commandPerformance ?? continuedCommand {
        writePerformanceByWindowID[assignment.windowID] = writePerformance
      }
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
        command: commandPerformance ?? continuedCommand,
        observedAt: nil
      )
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

      let logicalPosition = CGPoint(x: assignment.frame.x, y: assignment.frame.y)
      let size = CGSize(width: assignment.frame.width, height: assignment.frame.height)
      guard let processID = processIDs[assignment.windowID],
        let application = applications[processID]
      else {
        continue
      }
      let needsVerifiedOffscreenWrite = requiresVerifiedOffscreenWrite(
        frame: assignment.frame,
        monitorFrames: lastMonitorFrames
      )
      let startPoint = animationStartPositions[assignment.windowID] ?? logicalPosition
      // Preserve the native vertical clamp through the final commit and parking repair.
      let position = frameWritePosition(
        target: logicalPosition, from: startPoint, horizontalOnly: horizontalRibbonNavigation)
      let startSize = animationStartSizes[assignment.windowID] ?? size
      let startFrame = Rect(
        x: startPoint.x,
        y: startPoint.y,
        width: startSize.width,
        height: startSize.height
      )
      let leavingRibbonTarget = isParked && !requiresVerifiedOffscreenWrite(
        frame: startFrame, monitorFrames: lastMonitorFrames
      ) ? ribbonTargets[assignment.windowID] : nil
      let wantsFrameAnimation =
        animationDuration > 0
        && (!isParked || leavingRibbonTarget != nil)
        && transitionCrossesViewport(
          from: startFrame,
          to: leavingRibbonTarget ?? assignment.frame
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
        synchronousSizeWriteSucceeded: intent?.size != true,
        enhancedUIWasEnabled: enhancedUIByProcess[processID] == true,
        timeoutSeconds: asynchronousPositionTimeoutSeconds,
        isParked: isParked,
        isReentering: reenteringWindowIDs.contains(assignment.windowID),
        requiresVerifiedOffscreenWrite: needsVerifiedOffscreenWrite,
        animationPoint: leavingRibbonTarget.map { CGPoint(x: $0.x, y: $0.y) },
        usesCommonRibbonOffset: sharedRibbonOffset != nil && ribbonTargets[assignment.windowID] != nil
          && wantsFrameAnimation
      )
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
      } else if asynchronousSizeWriteIsRequired(
        sizeChanged: write.sizeChanged,
        synchronousWriteSucceeded: write.synchronousSizeWriteSucceeded,
        animatesSize: write.animatesSize
      ) {
        asynchronousWrites[assignment.windowID] = write
      } else if intent?.position == true {
        asynchronousWrites[assignment.windowID] = write
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
    let readsAcceptedFrames = writeIntents.values.contains { $0.size }
    let cursorWarpAfterWindowCommit:
      (@Sendable (WindowID, UInt64) -> Void)?
    if let cursorWarpWindowIDAfterCommit,
      let cursorWarpInputTimestampAfterCommit
    {
      cursorWarpAfterWindowCommit = { [weak self] committedWindowID, generation in
        guard committedWindowID == cursorWarpWindowIDAfterCommit else { return }
        NavigationActor.enqueue {
          guard let self,
            self.frameCoordinator.isCurrent(generation: generation),
            deferredFocusInputIsCurrent(
              requestedTimestamp: cursorWarpInputTimestampAfterCommit,
              latestUserInputTimestamp: self.userInputTracker.latestEventTimestamp
            ),
            cursorWarpIsCurrentAfterCommit?() ?? true
          else { return }
          self.warpCursor(
            to: cursorWarpWindowIDAfterCommit,
            unlessUserInputAfter: cursorWarpInputTimestampAfterCommit,
            preferringTargetFrame: true
          )
        }
      }
    } else {
      cursorWarpAfterWindowCommit = nil
    }
    let frameCompletion: (@Sendable (FrameWriteCompletion) -> Void)?
    if !readsAcceptedFrames, !refreshesBordersAfterCommit,
      focusWindowIDAfterCommit == nil,
      cursorWarpWindowIDAfterCommit == nil
    {
      frameCompletion = nil
    } else {
      frameCompletion = { [weak self] result in
        NavigationActor.enqueue {
          guard let self else {
            focusCompletionAfterCommit?(.frameSuperseded)
            return
          }
          guard result.completedLatest, self.frameSubmissionGeneration == submissionGeneration else {
            if let focusWindowIDAfterCommit {
              self.pendingFrameDebtWindowIDs.insert(focusWindowIDAfterCommit)
            }
            focusCompletionAfterCommit?(.frameSuperseded)
            return
          }
          if !result.acceptedFrames.isEmpty {
            for (windowID, frame) in result.acceptedFrames {
              self.latestObservedFrames[windowID] = frame
            }
          }
          if refreshesBordersAfterCommit {
            self.refreshWindowBorders()
          }
          if !result.acceptedFrames.isEmpty {
            acceptedFrameHandler?(result.acceptedFrames)
          }
          if let cursorWarpWindowIDAfterCommit,
            deferredFocusFrameCommitIsReady(
              targetWindowID: cursorWarpWindowIDAfterCommit,
              pendingFrameWindowIDs: self.pendingFrameWindowIDs,
              successfulWindowIDs: result.successfulWindowIDs,
              observedFrame:
                self.latestObservedFrames[cursorWarpWindowIDAfterCommit],
              targetFrame: self.targetFrames[cursorWarpWindowIDAfterCommit]
            ),
            let timestamp = cursorWarpTimestampAfterFrameCompletion(
              requestedTimestamp: cursorWarpInputTimestampAfterCommit,
              targetWindowID: cursorWarpWindowIDAfterCommit,
              completion: result
            ),
            deferredFocusInputIsCurrent(
              requestedTimestamp: timestamp,
              latestUserInputTimestamp:
                self.userInputTracker.latestEventTimestamp
            ),
            cursorWarpIsCurrentAfterCommit?() ?? true
          {
            self.warpCursor(
              to: cursorWarpWindowIDAfterCommit,
              unlessUserInputAfter: timestamp,
              preferringTargetFrame: true
            )
          }
          if let focusWindowIDAfterCommit {
            guard deferredFocusFrameCommitIsReady(
              targetWindowID: focusWindowIDAfterCommit,
              pendingFrameWindowIDs: self.pendingFrameWindowIDs,
              successfulWindowIDs: result.successfulWindowIDs,
              observedFrame: self.latestObservedFrames[focusWindowIDAfterCommit],
              targetFrame: self.targetFrames[focusWindowIDAfterCommit]
            ) else {
              self.pendingFrameDebtWindowIDs.insert(focusWindowIDAfterCommit)
              focusCompletionAfterCommit?(.frameSuperseded)
              return
            }
            guard deferredFocusInputIsCurrent(
              requestedTimestamp: focusInputTimestampAfterCommit,
              latestUserInputTimestamp:
                self.userInputTracker.latestEventTimestamp
            ),
              shouldApplyDeferredFocus(
              targetWindowID: focusWindowIDAfterCommit,
              selectedWindowID: self.desiredSelectedWindowID
            ) else {
              focusCompletionAfterCommit?(.cancelled)
              return
            }
            let requestID = self.focus(
              focusWindowIDAfterCommit,
              unlessUserInputAfter: focusInputTimestampAfterCommit,
              cursorWarpUnlessPointerMovedAfter:
                cursorWarpTimestampAfterFrameCompletion(
                  requestedTimestamp: cursorWarpInputTimestampAfterCommit,
                  targetWindowID: focusWindowIDAfterCommit,
                  completion: result
                ),
              cursorWarpPrefersTargetFrame: true,
              cursorWarpIsCurrent: cursorWarpIsCurrentAfterCommit,
              allowsNativeFullscreen: true,
              completion: focusCompletionAfterCommit
            )
            focusRequestIDAfterCommit?(requestID)
          }
        }
      }
    }
    if coordinatorWasBusy {
      // Keep superseded writes as readiness debt until fresh observations
      // confirm their targets; the next layout may omit equal optimistic frames.
      pendingFrameDebtWindowIDs.formUnion(frameCoordinator.pendingWindowIDs)
    }
    let commandSuccessfulWrite:
      (@Sendable (WindowID, TimeInterval) -> Void)?
    if !writePerformanceByWindowID.isEmpty {
      let writePerformanceByWindowID = writePerformanceByWindowID
      commandSuccessfulWrite = { [weak self] windowID, timestamp in
        guard let writePerformance = writePerformanceByWindowID[windowID] else {
          return
        }
        NavigationActor.enqueue {
          self?.recordCommandFirstWrite(writePerformance, at: timestamp)
        }
      }
    } else {
      commandSuccessfulWrite = nil
    }
    frameCoordinator.submit(
      asynchronousWrites,
      source: source,
      animationDuration:
        animatedWindowIDs.isEmpty ? 0 : animationDuration,
      refreshRateHz: animationRefreshRateHz,
      displayIDs: animationDisplayIDs,
      monitorFrames: lastMonitorFrames,
      animatedWindowIDs: animatedWindowIDs,
      stagesVisibleBeforeParking: stagesVisibleBeforeParking,
      successfulWrite: commandSuccessfulWrite,
      cursorWarpAfterWindowCommit: cursorWarpAfterWindowCommit,
      completion: frameCompletion
    )
    if tracesInitialFrame {
      let elapsedMS =
        (ProcessInfo.processInfo.systemUptime - applyStartedAt) * 1_000
      frameCoordinator.recordTrace(
        "initial-apply-complete ms=\(String(format: "%.2f", elapsedMS))"
      )
    }
    if asynchronousWrites.isEmpty, let focusWindowIDAfterCommit {
      let frameReady = deferredFocusFrameIsReady(
        targetWindowID: focusWindowIDAfterCommit,
        pendingFrameWindowIDs: pendingFrameWindowIDs
      )
      if frameReady, deferredFocusInputIsCurrent(
        requestedTimestamp: focusInputTimestampAfterCommit,
        latestUserInputTimestamp: userInputTracker.latestEventTimestamp
      ),
        shouldApplyDeferredFocus(
        targetWindowID: focusWindowIDAfterCommit,
        selectedWindowID: desiredSelectedWindowID
      ) {
        let requestID = focus(
          focusWindowIDAfterCommit,
          unlessUserInputAfter: focusInputTimestampAfterCommit,
          cursorWarpUnlessPointerMovedAfter:
          cursorWarpInputTimestampAfterCommit,
          cursorWarpPrefersTargetFrame: true,
          cursorWarpIsCurrent: cursorWarpIsCurrentAfterCommit,
          allowsNativeFullscreen: true,
          completion: focusCompletionAfterCommit
        )
        focusRequestIDAfterCommit?(requestID)
      } else if !frameReady {
        focusCompletionAfterCommit?(.frameSuperseded)
      } else {
        focusCompletionAfterCommit?(.cancelled)
      }
    }
    if asynchronousWrites.isEmpty,
      let cursorWarpWindowIDAfterCommit,
      let cursorWarpInputTimestampAfterCommit,
      deferredFocusFrameIsReady(
        targetWindowID: cursorWarpWindowIDAfterCommit,
        pendingFrameWindowIDs: pendingFrameWindowIDs
      ),
      deferredFocusInputIsCurrent(
        requestedTimestamp: cursorWarpInputTimestampAfterCommit,
        latestUserInputTimestamp: userInputTracker.latestEventTimestamp
      ),
      cursorWarpIsCurrentAfterCommit?() ?? true
    {
      warpCursor(
        to: cursorWarpWindowIDAfterCommit,
        unlessUserInputAfter: cursorWarpInputTimestampAfterCommit,
        preferringTargetFrame: true
      )
    }
    if updateVisibility {
      lastHiddenWindowIDs = effectiveHiddenWindowIDs
    }
    lastFrameApplyDurationMS =
      (ProcessInfo.processInfo.systemUptime - applyStartedAt) * 1_000
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


}

func frameTransitionIsPending(target: Rect?, observed: Rect?) -> Bool {
  guard let target else { return false }
  guard let observed else { return true }
  return !approximatelyEqual(observed, target)
}
