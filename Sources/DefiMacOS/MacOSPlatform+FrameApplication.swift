import DefiRuntime
import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

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
    animated: Bool = false,
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
    previousLogicalRibbonFrames = windowProxyRibbonHistory(ribbonFrames,
      previous: previousRibbonFrames, monitors: windowProxyMonitors)
    frameSubmissionGeneration &+= 1
    let submissionGeneration = frameSubmissionGeneration
    let skippedWindowIDs = requestedSkippedWindowIDs.union(
      nativeFullscreenWindowIDs
    )
    let horizontalRibbonNavigation = source == "command-animation" && positionsOnly
      && lastMonitorFrames.count == 1 && !ribbonFrames.isEmpty
    if windowProxiesEnabled {
      applyWindowProxies(assignments: assignments, ribbonFrames: ribbonFrames,
        previousRibbonFrames: previousRibbonFrames, skippedWindowIDs: skippedWindowIDs,
        hiddenWindowIDs: hiddenWindowIDs, source: source, animated: animated)
    }
    // One switch, one slide: a later apply (a restore, a repair) must not reuse it.
    for index in windowProxyMonitors.indices { windowProxyMonitors[index].workspaceShift = nil }
    // Native windows jump once to their targets, under the overlay when it draws the motion.
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
    let now = snapshotEngine.discoveryNow
    for assignment in assignments where !skippedWindowIDs.contains(assignment.windowID) {
      let reference = frameApplicationReference(
        pendingCorrection: pendingFrameCorrections[assignment.windowID],
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
    // Where each write starts: the completed native frame when a write is still in flight.
    var startFrames = referenceFrames
    if coordinatorWasBusy {
      for windowID in Array(startFrames.keys) {
        guard let reference = startFrames[windowID] else { continue }
        let position = frameCoordinator.completedPosition(for: windowID)
        let size = frameCoordinator.completedSize(for: windowID)
        startFrames[windowID] = Rect(
          x: position.map { Double($0.x) } ?? reference.x,
          y: position.map { Double($0.y) } ?? reference.y,
          width: size.map { Double($0.width) } ?? reference.width,
          height: size.map { Double($0.height) } ?? reference.height)
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
      guard let start = startFrames[assignment.windowID] else { continue }
      let initialFrameSettlement =
        initialFrameSettlementDeadlines[assignment.windowID].map { $0 > now }
        ?? false
      let commitDeadline = now + frameCommitQuarantineDuration(
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
        from: start,
        target: assignment.frame,
        issuedAt: now,
        deadline: commitDeadline,
        command: commandPerformance ?? continuedCommand,
        observedAt: nil,
        // Read back right after the write instead of waiting for the quarantine deadline.
        firstVerificationAt: now + 0.1
      ), for: assignment.windowID)
    }
    var asynchronousWrites: [WindowID: AsyncPositionWrite] = [:]
    var parkingTargets: [WindowID: AsyncPositionWrite] = [:]
    var initialSettlementTargets: [WindowID: AsyncPositionWrite] = [:]
    let bindings = Dictionary(uniqueKeysWithValues: snapshotEngine.borderGeometryTargets(
      for: Set(assignments.map(\.windowID))).map { ($0.windowID, $0) })
    for assignment in assignments {
      guard !skippedWindowIDs.contains(assignment.windowID) else { continue }
      guard let binding = bindings[assignment.windowID] else { continue }
      let isParked = hiddenWindowIDs.contains(assignment.windowID)
      let intent = writeIntents[assignment.windowID]
      let logicalPosition = CGPoint(x: assignment.frame.x, y: assignment.frame.y)
      let size = CGSize(width: assignment.frame.width, height: assignment.frame.height)
      let processID = binding.processID
      let needsVerifiedOffscreenWrite = requiresVerifiedOffscreenWrite(
        frame: assignment.frame,
        monitorFrames: lastMonitorFrames
      )
      let start = startFrames[assignment.windowID] ?? assignment.frame
      let startPoint = CGPoint(x: start.x, y: start.y)
      let write = AsyncPositionWrite(
        element: binding.element,
        application: binding.application,
        processID: processID,
        fromPoint: startPoint,
        // Preserve the native vertical clamp through the final commit and parking repair.
        point: frameWritePosition(
          target: logicalPosition, from: startPoint, horizontalOnly: horizontalRibbonNavigation),
        fromSize: CGSize(width: start.width, height: start.height),
        size: size,
        positionChanged: intent?.position == true,
        sizeChanged: intent?.size == true,
        synchronousSizeWriteSucceeded: intent?.size != true,
        enhancedUIWasEnabled: enhancedUIByProcess[processID] == true,
        timeoutSeconds: asynchronousPositionTimeoutSeconds,
        isParked: isParked,
        requiresVerifiedOffscreenWrite: needsVerifiedOffscreenWrite,
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
      if intent?.position == true || asynchronousSizeWriteIsRequired(
        sizeChanged: write.sizeChanged,
        synchronousWriteSucceeded: write.synchronousSizeWriteSucceeded
      ) {
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
    if !readsAcceptedFrames,
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
      monitorFrames: lastMonitorFrames,
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
  /// switched immediately; other sources move when they asked for motion.
  func windowProxyMotionDuration(source: String, animated: Bool,
    hasRibbon: Bool, workspaceShift: Double?) -> TimeInterval? {
    workspaceShift != nil || windowProxySources.contains(source) && animated && hasRibbon
      ? ribbonProxySpringDuration : nil
  }
}

let windowProxySources: Set<String> = [
  "window-lifecycle-animation", "mouse-drop-animation",
  "command-animation", "command-layout-animation", "workspace-transition", "native-focus-animation",
]

func windowProxyVisibleOverlap(_ frame: Rect, _ area: Rect) -> Double {
  guard frame.y < area.y + area.height, area.y < frame.y + frame.height else { return 0 }
  return max(min(frame.x + frame.width, area.x + area.width) - max(frame.x, area.x), 0)
}

/// The logical ribbon frames the next layout moves from. A display this layout left
/// out keeps its own: its next layout must not read as every window entering.
func windowProxyRibbonHistory(_ ribbonFrames: [FrameAssignment], previous: [WindowID: Rect],
  monitors: [WindowProxyMonitor]) -> [WindowID: Rect] {
  var history = Dictionary(uniqueKeysWithValues: ribbonFrames.map { ($0.windowID, $0.frame) })
  for monitor in monitors where !monitor.laidOut {
    for id in monitor.windowIDs { history[id] = previous[id] }
  }
  return history
}

/// Whether a layout moves anything on one display. With several displays a command
/// usually moves one of them: the others present nothing, so their borders and windows
/// stay untouched.
func windowProxyDisplayMoves(_ monitor: WindowProxyMonitor, displayCount: Int,
  ribbonTargets: [WindowID: Rect], previousRibbonFrames: [WindowID: Rect],
  opened: Set<WindowID>, dropped: WindowID?, skipped: Set<WindowID> = []) -> Bool {
  displayCount == 1 || monitor.workspaceShift != nil
    || !monitor.windowIDs.isDisjoint(with: opened.union([dropped].compactMap { $0 }))
    || ribbonTargets.contains { id, to in previousRibbonFrames[id].map { !approximatelyEqual($0, to) } ?? true }
    || previousRibbonFrames.keys.contains {
      monitor.windowIDs.contains($0) && ribbonTargets[$0] == nil && !skipped.contains($0)
    }
}

/// Plans each proxy from what is on screen to its target. Windows without a
/// known start (entering from parking) travel with the shared motion.
func windowProxyMotion(ribbonTargets: [WindowID: Rect], otherTargets: [WindowID: Rect],
  previousLogical: [WindowID: Rect], observed: [WindowID: Rect], verticalShift: Double? = nil,
  settled: [WindowID: RibbonProxySettle] = [:], dropped: WindowID? = nil, opened: Set<WindowID> = [])
  -> [(id: WindowID, from: Rect, to: Rect)] {
  let targets = otherTargets.merging(ribbonTargets) { _, ribbon in ribbon }
  let shared = verticalShift.map { CGPoint(x: 0, y: $0) } ?? targets.lazy.compactMap { id, to in
    previousLogical[id].map { CGPoint(x: to.x - $0.x, y: to.y - $0.y) }
  }.first ?? .zero
  // The pointer, not the app, placed the dropped window: it settles where its
  // neighbours on this display do (a notched display clamps them all alike).
  let siblingClamps = dropped == nil ? [] : ribbonTargets.compactMap { id, to -> Double? in
    guard id != dropped, let native = observed[id], let previous = previousLogical[id],
      abs(native.height - to.height) < 40, abs(native.y - previous.y) < 40 else { return nil }
    return (native.y - previous.y).rounded()
  }
  let siblingClamp = Dictionary(grouping: siblingClamps) { $0 }
    .max { ($0.value.count, -abs($0.key), $0.key) < ($1.value.count, -abs($1.key), $1.key) }?.key ?? 0
  // A window entering the ribbon rides the scroll of the column on its left, as in Niri:
  // columns on its right also moved aside to make room for it.
  func ribbonShift(_ target: Rect) -> CGPoint {
    guard verticalShift == nil else { return shared }
    let left = ribbonTargets.filter { id, to in previousLogical[id] != nil && to.x + to.width <= target.x + 1 }
      .max { ($0.value.x, $0.key.rawValue) < ($1.value.x, $1.key.rawValue) }
    return left.flatMap { id, to in previousLogical[id].map { CGPoint(x: to.x - $0.x, y: to.y - $0.y) } }
      ?? shared
  }
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
    // A window just opened is as tall as macOS spawned it (Ghostty: 12 pt under the window
    // it opened over), which says nothing of the app's clamp.
    let clamped = !opened.contains(id) && abs(native.height - logicalTo.height) < 40
    // Only a small offset is an app's own clamp; a large one is where the pointer
    // dropped the window.
    let offset = id == dropped ? siblingClamp : previousLogical[id].map { native.y - $0.y } ?? 0
    let clamp = clamped && abs(offset) < 40 ? offset : 0
    // Off the ribbon without history (another workspace's window re-parked): it stays
    // put. Shifted with the ribbon, it crossed the screen into its parking corner.
    let shift = ribbonTargets[id] == nil ? .zero : ribbonShift(logicalTo)
    let start = leavingFrom ?? previousLogical[id]
      ?? Rect(x: logicalTo.x - shift.x, y: logicalTo.y - shift.y, width: logicalTo.width, height: logicalTo.height)
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
  // Runs entirely on the navigation actor: command intake never waits for the main thread.
  func applyWindowProxies(assignments: [FrameAssignment], ribbonFrames: [FrameAssignment],
    previousRibbonFrames: [WindowID: Rect], skippedWindowIDs: Set<WindowID>,
    hiddenWindowIDs: Set<WindowID>, source: String, animated: Bool) {
    let allWindows = Dictionary(lastSnapshotWindows.map { ($0.id, $0) }) { first, _ in first }
    // Each display moves on its own overlay, exactly as a single display does.
    for monitor in windowProxyMonitors {
      guard let display = RibbonProxyStore.shared.screen(containing: monitor.viewport)?.displayID else {
        DispatchQueue.main.async { RibbonProxyRenderer.shared.refreshEnvironment() }
        continue
      }
      let owned = monitor.windowIDs
      let presenter = RibbonProxyPresenter.on(display)
      let released = windowProxyDroppedWindowID.map { !owned.contains($0) && presenter.release($0) } ?? false
      // Its windows are absent from this layout's ribbon, not leaving it.
      guard monitor.laidOut else {
        if released { presenter.landDrop() }
        continue
      }
      let ribbon = ribbonFrames.filter { owned.contains($0.windowID) }
      let shown = applyWindowProxies(on: monitor, presenter: presenter,
        assignments: assignments.filter { owned.contains($0.windowID) }, ribbonFrames: ribbon,
        previousRibbonFrames: previousRibbonFrames, skippedWindowIDs: skippedWindowIDs,
        hiddenWindowIDs: hiddenWindowIDs, allWindows: allWindows,
        motion: windowProxyMotionDuration(source: source, animated: animated,
          hasRibbon: !ribbon.isEmpty, workspaceShift: monitor.workspaceShift))
      if released, !shown { presenter.landDrop() }
    }
  }

  private func applyWindowProxies(on monitor: WindowProxyMonitor, presenter: RibbonProxyPresenter,
    assignments: [FrameAssignment], ribbonFrames: [FrameAssignment],
    previousRibbonFrames: [WindowID: Rect], skippedWindowIDs: Set<WindowID>,
    hiddenWindowIDs: Set<WindowID>, allWindows: [WindowID: Window],
    motion duration: TimeInterval?) -> Bool {
    let viewport = monitor.viewport, workspaceShift = monitor.workspaceShift
    let windows = allWindows.filter { monitor.windowIDs.contains($0.key) }
    var observed = latestObservedFrames
    for (id, window) in windows where observed[id] == nil { observed[id] = window.frame }
    let native = assignments.filter { !skippedWindowIDs.contains($0.windowID) }
    let ribbonTargets = Dictionary(ribbonFrames.filter { !skippedWindowIDs.contains($0.windowID) }
      .map { ($0.windowID, $0.frame) }) { first, _ in first }
    // Windows discovered by this snapshot grow in at their place instead of sliding.
    let opened = newlyDiscoveredWindowIDs
    let moves = windowProxyDisplayMoves(monitor, displayCount: windowProxyMonitors.count,
      ribbonTargets: ribbonTargets, previousRibbonFrames: previousRibbonFrames, opened: opened,
      dropped: windowProxyDroppedWindowID, skipped: skippedWindowIDs)
    // A plain layout landing mid-motion (scroll to keep focus visible, a drop settling)
    // continues the running motion toward its targets instead of cutting it.
    let duration = moves ? duration ?? (!ribbonFrames.isEmpty
      && presenter.isRetargeted(by: assignments, generation: frameSubmissionGeneration)
      ? ribbonProxySpringDuration : nil) : nil
    guard let duration else {
      presenter.supersedeIfTargetsChanged(assignments, generation: frameSubmissionGeneration)
      let area = RibbonProxyStore.shared.screen(containing: viewport)?.visibleFrame
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
        WindowCaptureCache.shared.noteWindows(noted, afterLanding: false)
      }
      return false
    }
    // Leaving windows (a vertical switch) only have native targets.
    let otherTargets = Dictionary(native.filter { ribbonTargets[$0.windowID] == nil }
      .map { ($0.windowID, $0.frame) }) { first, _ in first }
    let planned = windowProxyMotion(ribbonTargets: ribbonTargets, otherTargets: otherTargets,
      previousLogical: previousRibbonFrames, observed: observed,
      verticalShift: workspaceShift, settled: RibbonProxyStore.shared.settled,
      dropped: windowProxyDroppedWindowID, opened: opened)
    if let shift = workspaceShift {
      ribbonProxyLogger.notice("workspace-switch shift=\(Int(shift))")
    }
    // The released window starts exactly where the pointer left it.
    let dropped = windowProxyDroppedWindowID.flatMap { id in
      ribbonProxyNativeFrames([id])[id].map { (id, $0) }
    }
    // A window just opened is on screen where macOS placed it: captured there before any
    // native write, it grows in its slot as itself instead of as an icon card.
    let spawned = planned.compactMap { plan -> RibbonProxyRefresh? in
      guard opened.contains(plan.id), let frame = observed[plan.id], let window = windows[plan.id],
        let processID = window.processID, windowProxyVisibleOverlap(frame, viewport) > 1.01 else { return nil }
      return RibbonProxyRefresh(id: plan.id, appID: window.appID, processID: processID, frame: frame, distance: 0)
    }
    captureSpawnedWindows(spawned)
    var proxies = planned.compactMap { plan -> RibbonProxyWindow? in
      guard let window = windows[plan.id], let processID = window.processID else { return nil }
      let appears = opened.contains(plan.id)
      let from = plan.id == dropped?.0 ? dropped?.1 ?? plan.from : plan.from
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
      // The native target with the planned app placement (learned or clamped).
      let logical = ribbonTargets[assignment.windowID]
      return (assignment.windowID, Rect(x: assignment.frame.x + planned.x - (logical?.x ?? planned.x),
        y: planned.y + assignment.frame.y - (logical?.y ?? assignment.frame.y),
        width: assignment.frame.width + planned.width - (logical?.width ?? planned.width),
        height: planned.height))
    }) { first, _ in first }
    let requested = Dictionary(native.filter { targets[$0.windowID] != nil }
      .map { ($0.windowID, $0.frame) }) { first, _ in first }
    if RibbonProxyPresenter.setBordersHidden == nil {
      RibbonProxyPresenter.setBordersHidden = { [weak self] display, windowIDs in
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard let self else { return }
            // Rings shown again sit on the real frames from their first frame: a ring kept
            // from before the motion (a new window's spawn place) flashed there once.
            if windowIDs.isEmpty { self.refreshWindowBorderGeometry(windowIDs: self.borderManager.liveGeometryWindowIDs) }
            self.borderManager.setPresentationHidden(windowIDs, for: display)
            // A display landing settles every border on real frames, others still moving included.
            if windowIDs.isEmpty { self.settleWindowBordersOnRealFrames() } else { self.borderSettleTask?.cancel() }
          }
        }
      }
      RibbonProxyPresenter.nativeRingShown = { [weak self] windowID in
        await MainActor.run { self?.borderManager.showsActiveRing(for: windowID) ?? true }
      }
    }
    return presenter.begin(windows: proxies, viewport: viewport,
      generation: frameSubmissionGeneration, nativeTargets: targets, requestedTargets: requested,
      duration: duration,
      selectedWindowID: desiredSelectedWindowID, managedWindowIDs: Set(allWindows.keys),
      borderWindowIDs: monitor.windowIDs)
  }

  /// The display a new window lands on: the selected window's, as Defi places it there.
  func holdWindowProxiesForOpening(_ processID: pid_t) {
    let all = Dictionary(lastSnapshotWindows.map { ($0.id, $0) }) { first, _ in first }
    // shortcut: an app rule sending the window to another display or floating it holds
    // the screen still for 0.5 s; read the app rules here if that shows up.
    guard let monitor = windowProxyMonitors.first(where: { monitor in
      desiredSelectedWindowID.map(monitor.windowIDs.contains) ?? false
    }) ?? windowProxyMonitors.first,
      let display = RibbonProxyStore.shared.screen(containing: monitor.viewport)?.displayID else { return }
    let shown = all.compactMap { id, window -> RibbonProxyWindow? in
      let frame = latestObservedFrames[id] ?? window.frame
      guard monitor.windowIDs.contains(id), let owner = window.processID,
        windowProxyVisibleOverlap(frame, monitor.viewport) > 1.01 else { return nil }
      return RibbonProxyWindow(id: id, appID: window.appID, processID: owner, from: frame, to: frame)
    }
    RibbonProxyPresenter.on(display).hold(windows: shown, viewport: monitor.viewport,
      generation: frameSubmissionGeneration, processID: processID,
      selectedWindowID: desiredSelectedWindowID, managedWindowIDs: Set(all.keys),
      borderWindowIDs: monitor.windowIDs)
  }

  /// `frame` is nil for a dialog, a panel or a tab. A new native tab can also show
  /// first without its tab bar, over its group's window: it takes that slot, nothing moves.
  func releaseOpeningHoldUnlessOwnWindow(_ processID: pid_t, at frame: Rect?) {
    let opensColumn = frame.map { frame in
      !lastSnapshotWindows.contains { window in
        window.processID == processID
          && frameDistance(latestObservedFrames[window.id] ?? window.frame, frame) <= 2
      }
    } ?? false
    if !opensColumn { RibbonProxyPresenter.releaseHolds() }
  }

  private func captureSpawnedWindows(_ windows: [RibbonProxyRefresh]) {
    guard !windows.isEmpty, RibbonProxyStore.shared.isAuthorized,
      let capture = ribbonProxyWindowServerCapture else { return }
    let started = CACurrentMediaTime()
    for window in windows where WindowCaptureStore.shared.picture(window.id) == nil {
      guard let number = CGWindowID(exactly: window.id.rawValue), let images = capture([number]),
        images.count == 1, let image = images.first,
        let scale = RibbonProxyStore.shared.screen(containing: window.frame)?.scale else { continue }
      WindowCaptureStore.shared.setPicture(ribbonProxyGrowingPicture(image, scale: scale), for: window)
    }
    ribbonProxyLogger.notice("capture-spawned ids=\(windows.map(\.id.rawValue), privacy: .public) ms=\(Int((CACurrentMediaTime() - started) * 1_000))")
  }
}
