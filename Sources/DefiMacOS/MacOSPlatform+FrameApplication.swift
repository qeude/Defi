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
  func consumeAcceptedFrames(_ observations: [BorderGeometryObservation],
    handler: (([WindowID: Rect]) -> Void)?) {
    let frames = snapshotEngine.consumeAcceptedFrames(observations)
    if !frames.isEmpty { handler?(frames) }
  }

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
    let previousRibbonFrames = previousLogicalRibbonFrames
    previousLogicalRibbonFrames = Dictionary(uniqueKeysWithValues:
      ribbonFrames.map { ($0.windowID, $0.frame) })
    frameSubmissionGeneration &+= 1
    let submissionGeneration = frameSubmissionGeneration
    let skippedWindowIDs = requestedSkippedWindowIDs.union(
      nativeFullscreenWindowIDs
    )
    let horizontalRibbonNavigation = source == "command-animation" && positionsOnly
      && lastMonitorFrames.count == 1 && !ribbonFrames.isEmpty
    let usesWindowProxies = windowProxiesEnabled && applyWindowProxies(
      assignments: assignments, ribbonFrames: ribbonFrames,
      previousRibbonFrames: previousRibbonFrames, skippedWindowIDs: skippedWindowIDs,
      hiddenWindowIDs: hiddenWindowIDs,
      motion: windowProxyMotionDuration(source: source, animationDuration: animationDuration,
        hasRibbon: !ribbonFrames.isEmpty))
    // One switch, one slide: a later apply (a restore, a repair) must not reuse it.
    windowProxyWorkspaceShift = nil
    // Native windows jump once to their targets underneath the proxy overlay. A
    // vertical switch admitted only because of proxies must not slide natively.
    let animationDuration = usesWindowProxies
      || (windowProxiesEnabled && windowProxyNativeInstantSources.contains(source))
      // With proxies on, a motion the overlay could not draw (surface or wallpaper not
      // ready yet) jumps once instead of falling back to per-frame AX writes.
      || (windowProxiesEnabled && RibbonProxyStore.shared.isAuthorized && windowProxySources.contains(source))
      ? 0 : animationDuration
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
    let now = snapshotEngine.discoveryNow
    let unfinishedRibbonWindowIDs = source == "command-animation"
      ? frameCoordinator.pendingAnimatedWindowIDs : []
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
        pendingAnimation: unfinishedRibbonWindowIDs.contains(assignment.windowID),
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
    let layoutRibbonAnimation = source == "command-layout-animation"
    let ribbonTargets = ((source == "command-animation" && positionsOnly) || layoutRibbonAnimation)
      && lastMonitorFrames.count == 1
      ? Dictionary(uniqueKeysWithValues: ribbonFrames.map { ($0.windowID, $0.frame) })
      : [:]
    let sharedRibbonOffset = !layoutRibbonAnimation && lastMonitorFrames.count == 1 ? commonRibbonOffset(
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
        guard let logical = ribbonTargets[assignment.windowID] else { continue }
        // Unchanged parking anchors have no write intent, but their logical
        // columns can still cross the display during an end-to-end traversal.
        let observedFrame = referenceFrames[assignment.windowID]
          ?? latestObservedFrames[assignment.windowID] ?? assignment.frame
        guard let plannedFrame = ribbonAnimationStart(logical: logical, offset: offset,
          observed: observedFrame, monitorFrames: lastMonitorFrames) else { continue }
        let observed = CGPoint(x: observedFrame.x, y: observedFrame.y)
        let planned = CGPoint(x: plannedFrame.x, y: plannedFrame.y)
        animationStartPositions[assignment.windowID] = planned
        animationStartSizes[assignment.windowID] = CGSize(
          width: observedFrame.width, height: observedFrame.height)
        if requiresVerifiedOffscreenWrite(frame: observedFrame, monitorFrames: lastMonitorFrames),
          reentryStartRequiresStaging(observed: observed, planned: planned)
        {
          reenteringWindowIDs.insert(assignment.windowID)
        }
      }
    }
    if layoutRibbonAnimation {
      for assignment in assignments {
        guard let target = ribbonTargets[assignment.windowID],
          let observed = referenceFrames[assignment.windowID],
          let start = layoutRibbonAnimationStart(
            previousLogical: previousRibbonFrames[assignment.windowID], target: target,
            observed: observed, monitorFrames: lastMonitorFrames)
        else { continue }
        let point = CGPoint(x: start.x, y: start.y)
        animationStartPositions[assignment.windowID] = point
        if reentryStartRequiresStaging(observed: CGPoint(x: observed.x, y: observed.y), planned: point) {
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
      snapshotEngine.registerFrameCommit(FrameCommitExpectation(
        commitID: submissionGeneration,
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
        observedAt: nil,
        // Read back right after the motion instead of waiting for the quarantine deadline.
        firstVerificationAt: now + animationDuration + 0.1
      ), for: assignment.windowID)
    }
    var asynchronousWrites: [WindowID: AsyncPositionWrite] = [:]
    var parkingTargets: [WindowID: AsyncPositionWrite] = [:]
    var initialSettlementTargets: [WindowID: AsyncPositionWrite] = [:]
    var animatedWindowIDs = Set<WindowID>()
    let bindings = Dictionary(uniqueKeysWithValues: snapshotEngine.borderGeometryTargets(
      for: Set(assignments.map(\.windowID))).map { ($0.windowID, $0) })
    for assignment in assignments {
      guard !skippedWindowIDs.contains(assignment.windowID) else { continue }
      guard let binding = bindings[assignment.windowID] else { continue }
      let element = binding.element
      let isParked = hiddenWindowIDs.contains(assignment.windowID)
      let intent = writeIntents[assignment.windowID]

      let logicalPosition = CGPoint(x: assignment.frame.x, y: assignment.frame.y)
      let size = CGSize(width: assignment.frame.width, height: assignment.frame.height)
      let processID = binding.processID
      let application = binding.application
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
      let parkedRibbonTarget = ribbonAnimationTarget(
        logical: ribbonTargets[assignment.windowID], from: startFrame,
        isParked: isParked, monitorFrames: lastMonitorFrames)
      let animatesSizeChange =
        animateSizeChanges && intent?.size == true
        && targetSizeChanged(
          previous: previousTargetFrames[assignment.windowID], target: assignment.frame)
      let wantsFrameAnimation =
        animationDuration > 0
        && (!isParked || parkedRibbonTarget != nil)
        && transitionCrossesViewport(
          from: startFrame,
          to: parkedRibbonTarget ?? assignment.frame
        )
        && (intent?.position == true || parkedRibbonTarget != nil || animatesSizeChange)
      // Growth is committed once before motion; shrink holds its size until the end.
      let animatesSize =
        wantsFrameAnimation && animatesSizeChange
        && (size.width < startSize.width || size.height < startSize.height)
      let write = AsyncPositionWrite(
        element: element,
        application: application,
        processID: processID,
        fromPoint: startPoint,
        point: position,
        fromSize: startSize,
        size: size,
        positionChanged: intent?.position == true || parkedRibbonTarget != nil,
        sizeChanged: intent?.size == true,
        animatesSize: animatesSize,
        usesLogicalRibbonPath: layoutRibbonAnimation && ribbonTargets[assignment.windowID] != nil
          && lastMonitorFrames.count == 1 && wantsFrameAnimation,
        synchronousSizeWriteSucceeded: intent?.size != true,
        enhancedUIWasEnabled: enhancedUIByProcess[processID] == true,
        timeoutSeconds: asynchronousPositionTimeoutSeconds,
        isParked: isParked,
        isReentering: reenteringWindowIDs.contains(assignment.windowID),
        requiresVerifiedOffscreenWrite: needsVerifiedOffscreenWrite,
        animationPoint: parkedRibbonTarget.map { CGPoint(x: $0.x, y: $0.y) },
        usesCommonRibbonOffset: sharedRibbonOffset != nil && ribbonTargets[assignment.windowID] != nil
          && wantsFrameAnimation,
        binding: binding
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
          if refreshesBordersAfterCommit {
            self.refreshWindowBorders()
            // Once recent writes stop masking native samples, catch any clamp.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
              self?.presentRefreshWindowBorders()
            }
          }
          self.consumeAcceptedFrames(result.acceptedObservations, handler: acceptedFrameHandler)
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

func shouldAnimateParkedRibbonWindow(
  source: String,
  from: Rect,
  monitorFrames: [Rect]
) -> Bool {
  source == "command-animation"
    && !requiresVerifiedOffscreenWrite(frame: from, monitorFrames: monitorFrames)
}

func frameTransitionIsPending(target: Rect?, observed: Rect?) -> Bool {
  guard let target else { return false }
  guard let observed else { return true }
  return !approximatelyEqual(observed, target)
}

// Keyboard navigation, column width and order changes, vertical workspace
// switches and click-to-focus scrolling all draw through the proxy overlay.
extension MacOSPlatform {
  /// Every workspace switch slides vertically on the overlay, even when the daemon
  /// switched immediately; other sources animate when they asked for a duration.
  func windowProxyMotionDuration(source: String, animationDuration: TimeInterval,
    hasRibbon: Bool) -> TimeInterval? {
    guard lastMonitorFrames.count == 1 else { return nil }
    if windowProxyWorkspaceShift != nil { return animationDuration > 0 ? animationDuration : ribbonProxySpringDuration }
    return windowProxySources.contains(source) && animationDuration > 0 && hasRibbon ? animationDuration : nil
  }
}

/// Motions admitted only because proxies can draw them; without the overlay they jump.
let windowProxyNativeInstantSources: Set<String> = [
  "workspace-transition", "window-lifecycle-animation", "mouse-drop-animation",
]

let windowProxySources: Set<String> = [
  "window-lifecycle-animation", "mouse-drop-animation",
  "command-animation", "command-layout-animation", "workspace-transition", "native-focus-animation",
  "mouse-reorder-animation",
]

func windowProxyVisibleOverlap(_ frame: Rect, _ area: Rect) -> Double {
  guard frame.y < area.y + area.height, area.y < frame.y + frame.height else { return 0 }
  return max(min(frame.x + frame.width, area.x + area.width) - max(frame.x, area.x), 0)
}

/// Plans each proxy from what is on screen to its target. Windows without a
/// known start (entering from parking) travel with the shared motion.
func windowProxyMotion(ribbonTargets: [WindowID: Rect], otherTargets: [WindowID: Rect],
  previousLogical: [WindowID: Rect], observed: [WindowID: Rect], verticalShift: Double? = nil,
  settled: [WindowID: RibbonProxySettle] = [:])
  -> [(id: WindowID, from: Rect, to: Rect)] {
  let targets = otherTargets.merging(ribbonTargets) { _, ribbon in ribbon }
  let shared = verticalShift.map { CGPoint(x: 0, y: $0) } ?? targets.lazy.compactMap { id, to in
    previousLogical[id].map { CGPoint(x: to.x - $0.x, y: to.y - $0.y) }
  }.first ?? .zero
  return targets.compactMap { id, target in
    guard let native = observed[id] else { return nil }
    // In a vertical switch, leaving windows slide off with the shift on the overlay,
    // wherever their native windows park: from their ribbon place, or else from where
    // they are (no ribbon history must not send them sideways to their parking).
    let leavingFrom = verticalShift != nil && ribbonTargets[id] == nil ? previousLogical[id] ?? native : nil
    let logicalTo = leavingFrom.map { Rect(x: $0.x, y: $0.y + shared.y, width: $0.width, height: $0.height) }
      ?? target
    // Native clamping (a few points) owns the vertical extent; a real height change,
    // like stacking into a column, takes the layout's.
    let clamped = abs(native.height - logicalTo.height) < 40
    // Only a small offset is an app's own clamp; a large one is where the pointer
    // dropped the window.
    let offset = previousLogical[id].map { native.y - $0.y } ?? 0
    let clamp = clamped && abs(offset) < 40 ? offset : 0
    let start = leavingFrom ?? previousLogical[id]
      ?? Rect(x: logicalTo.x - shared.x, y: logicalTo.y - shared.y,
        width: logicalTo.width, height: logicalTo.height)
    // Where this app really put the window last time it had this size (its own cell
    // grid or clamp): the picture lands exactly on the window, not a few points off.
    if let settle = settled[id], settle.matches(logicalTo) {
      return (id, settle.apply(to: start), settle.apply(to: logicalTo))
    }
    return (id,
      Rect(x: start.x, y: start.y + clamp, width: start.width, height: clamped ? native.height : start.height),
      Rect(x: logicalTo.x, y: logicalTo.y + clamp, width: logicalTo.width,
        height: clamped ? native.height : logicalTo.height))
  }
}

@NavigationActor
extension MacOSPlatform {
  // Returns true when the proxy overlay presents this motion. Runs entirely
  // on the navigation actor: command intake never waits for the main thread.
  func applyWindowProxies(assignments: [FrameAssignment], ribbonFrames: [FrameAssignment],
    previousRibbonFrames: [WindowID: Rect], skippedWindowIDs: Set<WindowID>,
    hiddenWindowIDs: Set<WindowID>, motion duration: TimeInterval?) -> Bool {
    let presenter = RibbonProxyPresenter.shared
    let windows = Dictionary(lastSnapshotWindows.map { ($0.id, $0) }) { first, _ in first }
    var observed = latestObservedFrames
    for (id, window) in windows where observed[id] == nil { observed[id] = window.frame }
    let native = assignments.filter { !skippedWindowIDs.contains($0.windowID) }
    let ribbonTargets = Dictionary(ribbonFrames.filter { !skippedWindowIDs.contains($0.windowID) }
      .map { ($0.windowID, $0.frame) }) { first, _ in first }
    // A plain layout landing mid-motion (scroll to keep focus visible, a drop settling)
    // continues the running motion toward its targets instead of cutting it.
    let duration = duration ?? (lastMonitorFrames.count == 1 && !ribbonFrames.isEmpty
      && presenter.isRetargeted(by: assignments, generation: frameSubmissionGeneration)
      ? ribbonProxySpringDuration : nil)
    guard let duration, let viewport = lastMonitorFrames.first else {
      presenter.supersedeIfTargetsChanged(assignments, generation: frameSubmissionGeneration)
      let area = lastMonitorFrames.first.flatMap {
        RibbonProxyStore.shared.screen(containing: $0)?.visibleFrame
      }
      // Every managed window on the display: the active ribbon by distance, then
      // other workspaces so a vertical switch finds their pictures warm.
      let noted = native.compactMap { assignment -> RibbonProxyRefresh? in
        guard let window = windows[assignment.windowID], let processID = window.processID
        else { return nil }
        let distance = ribbonTargets[assignment.windowID].map { logical in
          area.map { ribbonProxyDistance(logical, $0) } ?? 0
        } ?? 100_000
        return RibbonProxyRefresh(id: assignment.windowID, appID: window.appID,
          processID: processID, frame: observed[assignment.windowID] ?? window.frame,
          distance: distance)
      }
      DispatchQueue.main.async {
        RibbonProxyRenderer.shared.noteWindows(noted, afterLanding: false)
      }
      return false
    }
    // Leaving windows (a vertical switch) only have native targets.
    let otherTargets = Dictionary(native.filter { ribbonTargets[$0.windowID] == nil }
      .map { ($0.windowID, $0.frame) }) { first, _ in first }
    let planned = windowProxyMotion(ribbonTargets: ribbonTargets, otherTargets: otherTargets,
      previousLogical: previousRibbonFrames, observed: observed,
      verticalShift: windowProxyWorkspaceShift, settled: RibbonProxyStore.shared.settled)
    // Windows discovered by this snapshot grow in at their place instead of sliding.
    let opened = newlyDiscoveredWindowIDs
    if let shift = windowProxyWorkspaceShift {
      ribbonProxyLogger.notice("workspace-switch shift=\(Int(shift))")
    }
    // The released window starts exactly where the pointer left it.
    let dropped = windowProxyDroppedWindowID.flatMap { id in
      ribbonProxyNativeFrames([id])[id].map { (id, $0) }
    }
    var proxies = planned.compactMap { plan -> RibbonProxyWindow? in
      guard let window = windows[plan.id], let processID = window.processID else { return nil }
      let appears = opened.contains(plan.id)
      let from = appears ? plan.to
        : plan.id == dropped?.0 ? dropped?.1 ?? plan.from : plan.from
      return RibbonProxyWindow(id: plan.id, appID: window.appID, processID: processID,
        from: from, to: plan.to, appears: appears)
    }
    // Visible managed windows without a planned motion (skipped writes, floating
    // windows) are drawn still at their real place instead of blocking the overlay.
    let moving = Set(proxies.map(\.id))
    for (id, window) in windows where !moving.contains(id) {
      guard let processID = window.processID, let frame = observed[id],
        windowProxyVisibleOverlap(frame, viewport) > 1.01 else { continue }
      proxies.append(RibbonProxyWindow(id: id, appID: window.appID, processID: processID,
        from: frame, to: frame))
    }
    let plannedTargets = Dictionary(planned.map { ($0.id, $0.to) }) { first, _ in first }
    let targets = Dictionary(native.compactMap { assignment -> (WindowID, Rect)? in
      guard !hiddenWindowIDs.contains(assignment.windowID),
        let planned = plannedTargets[assignment.windowID] else { return nil }
      // The native target position, with the planned (clamped) vertical extent.
      return (assignment.windowID, Rect(x: assignment.frame.x,
        y: planned.y + assignment.frame.y - (ribbonTargets[assignment.windowID]?.y ?? assignment.frame.y),
        width: assignment.frame.width, height: planned.height))
    }) { first, _ in first }
    if presenter.setBordersHidden == nil {
      presenter.setBordersHidden = { [weak self] hidden in
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            self?.borderManager.presentationHidden = hidden
            if hidden { self?.borderSettleTask?.cancel() } else { self?.settleWindowBordersOnRealFrames() }
          }
        }
      }
      presenter.nativeRingShown = { [weak self] windowID in
        await MainActor.run { self?.borderManager.showsActiveRing(for: windowID) ?? true }
      }
    }
    return presenter.begin(windows: proxies, viewport: viewport,
      generation: frameSubmissionGeneration, nativeTargets: targets, duration: duration,
      selectedWindowID: desiredSelectedWindowID, draggedWindowID: windowProxyDraggedWindowID,
      dragSlot: windowProxyDraggedWindowID.flatMap { id in
        ribbonFrames.first { $0.windowID == id }?.frame
      }, managedWindowIDs: Set(windows.keys))
  }
}
