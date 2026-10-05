import AppKit
import ApplicationServices
import DefiConfig
import DefiCore
import DefiModel
import OSLog

struct FrameWriteIntent: Equatable, Sendable {
  let position: Bool
  let size: Bool
}

func frameWritePosition(target: CGPoint, from start: CGPoint, horizontalOnly: Bool) -> CGPoint {
  CGPoint(x: target.x, y: horizontalOnly ? start.y : target.y)
}

func frameWriteIntent(
  reference: Rect,
  target: Rect,
  positionsOnly: Bool,
  horizontalOnly: Bool = false
) -> FrameWriteIntent {
  FrameWriteIntent(
    position: abs(reference.x - target.x) >= 0.5
      || (!horizontalOnly && abs(reference.y - target.y) >= 0.5),
    size: !positionsOnly
      && (abs(reference.width - target.width) >= 0.5
        || abs(reference.height - target.height) >= 0.5)
  )
}

func reentryStartRequiresStaging(
  observed: CGPoint,
  planned: CGPoint
) -> Bool {
  abs(observed.x - planned.x) >= 0.5
    || abs(observed.y - planned.y) >= 0.5
}

func successfulFrameWriteIntent(
  positionChanged: Bool,
  positionApplied: Bool,
  sizeChanged: Bool,
  sizeApplied: Bool
) -> FrameWriteIntent {
  FrameWriteIntent(
    position: positionChanged && positionApplied,
    size: sizeChanged && sizeApplied
  )
}

func acceptedFrameRequiresReadback(
  windowID: WindowID,
  sizeChanged: Bool,
  liveBorderWindowID: WindowID?
) -> Bool {
  sizeChanged || windowID == liveBorderWindowID
}

func interpolatedFrame(
  from: Rect,
  to: Rect,
  progress: Double
) -> Rect {
  let progress = min(max(progress, 0), 1)
  return Rect(
    x: from.x + (to.x - from.x) * progress,
    y: from.y + (to.y - from.y) * progress,
    width: from.width + (to.width - from.width) * progress,
    height: from.height + (to.height - from.height) * progress
  )
}

func frameCentersCrossDisplays(
  from source: Rect,
  to target: Rect,
  displayFrames: [Rect]
) -> Bool {
  guard let sourceDisplay = displayFrames.firstIndex(where: { $0.contains(centerOf: source) }),
    let targetDisplay = displayFrames.firstIndex(where: { $0.contains(centerOf: target) })
  else { return false }
  return sourceDisplay != targetDisplay
}

func shouldDeferAnimatedSizeUntilMovementCompletes(
  from source: Rect,
  to target: Rect,
  displayFrames: [Rect]
) -> Bool {
  frameCentersCrossDisplays(
      from: source,
      to: target,
      displayFrames: displayFrames
    )
}

struct AsyncPositionWrite: @unchecked Sendable {
  let element: AXUIElement
  let application: AXUIElement
  let processID: pid_t
  var fromPoint: CGPoint
  let point: CGPoint
  let fromSize: CGSize
  let size: CGSize
  let positionChanged: Bool
  let sizeChanged: Bool
  let animatesSize: Bool
  var usesLogicalRibbonPath = false
  let synchronousSizeWriteSucceeded: Bool
  let enhancedUIWasEnabled: Bool
  let timeoutSeconds: Float
  let isParked: Bool
  let isReentering: Bool
  let requiresVerifiedOffscreenWrite: Bool
  var animationPoint: CGPoint? = nil
  var usesCommonRibbonOffset = false
}

// One visible native window anchors the entire strip. Parking anchors are
// deliberately excluded: their one-pixel exposure is not a logical position.
func commonRibbonOffset(
  targets: [WindowID: CGPoint], starts: [WindowID: CGPoint],
  sizes: [WindowID: CGSize], monitor: Rect
) -> Double? {
  let candidates = targets.compactMap { id, target -> (WindowID, Double, Double)? in
    guard let start = starts[id], let size = sizes[id],
      size.width > 0 else { return nil }
    let exposure = min(start.x + size.width, monitor.x + monitor.width)
      - max(start.x, monitor.x)
    guard exposure > 1.5 else { return nil }
    return (id, exposure, start.x - target.x)
  }.sorted {
    $0.1 == $1.1 ? $0.0.rawValue < $1.0.rawValue : $0.1 > $1.1
  }
  return candidates.first?.2
}

func nativeRibbonAnimationFrame(_ logical: Rect, monitor: Rect) -> Rect {
  let exposure = min(logical.x + logical.width, monitor.x + monitor.width)
    - max(logical.x, monitor.x)
  guard exposure <= parkedSliverWidth else { return logical }
  return resolveParkingPlacement(
    for: logical, ownerFrame: monitor, allMonitorFrames: [monitor],
    preferredSide: logical.x < monitor.x ? .left : .right,
    preferredY: logical.y).frame
}

func ribbonAnimationStart(
  logical: Rect, offset: Double, observed: Rect, monitorFrames: [Rect]
) -> Rect? {
  let start = Rect(x: logical.x + offset, y: observed.y,
    width: observed.width, height: observed.height)
  return ribbonAnimationTarget(logical: logical, from: start,
    isParked: true, monitorFrames: monitorFrames) == nil ? nil : start
}

func layoutRibbonAnimationStart(
  previousLogical: Rect?, target: Rect, observed: Rect, monitorFrames: [Rect]
) -> Rect? {
  guard monitorFrames.count == 1, let previousLogical,
    requiresVerifiedOffscreenWrite(frame: observed, monitorFrames: monitorFrames)
  else { return nil }
  let start = Rect(x: previousLogical.x, y: observed.y,
    width: observed.width, height: observed.height)
  return ribbonAnimationTarget(logical: target, from: start,
    isParked: true, monitorFrames: monitorFrames) == nil ? nil : start
}

func ribbonAnimationTarget(
  logical: Rect?, from: Rect, isParked: Bool, monitorFrames: [Rect]
) -> Rect? {
  // The logical path may cross the display even when both native endpoints
  // are parking anchors. Such columns must participate in the common timeline.
  guard isParked, monitorFrames.count == 1, let logical else { return nil }
  let monitor = monitorFrames[0]
  guard min(from.x, logical.x) < monitor.x + monitor.width,
    max(from.x + from.width, logical.x + logical.width) > monitor.x,
    min(from.y, logical.y) < monitor.y + monitor.height,
    max(from.y + from.height, logical.y + logical.height) > monitor.y
  else { return nil }
  return logical
}

func ribbonParkingPreparationWindowIDs(_ frame: QueuedPositionFrame) -> Set<WindowID> {
  guard frame.source == "command-animation" || frame.source == "command-layout-animation",
    frame.monitorFrames.count == 1 else { return [] }
  return Set(frame.writes.compactMap { id, write in
    write.isParked && !frame.animatedWindowIDs.contains(id) ? id : nil
  })
}

func frameAnimationDestination(_ write: AsyncPositionWrite, intermediate: Bool) -> CGPoint {
  intermediate ? (write.animationPoint ?? write.point) : write.point
}

func positionOnlyAnimationWrite(
  _ write: AsyncPositionWrite,
  holding size: CGSize
) -> AsyncPositionWrite {
  AsyncPositionWrite(
    element: write.element,
    application: write.application,
    processID: write.processID,
    fromPoint: write.fromPoint,
    point: write.point,
    fromSize: size,
    size: size,
    positionChanged: write.positionChanged,
    sizeChanged: write.sizeChanged,
    animatesSize: false,
    usesLogicalRibbonPath: write.usesLogicalRibbonPath,
    synchronousSizeWriteSucceeded: true,
    enhancedUIWasEnabled: write.enhancedUIWasEnabled,
    timeoutSeconds: write.timeoutSeconds,
    isParked: write.isParked,
    isReentering: write.isReentering,
    requiresVerifiedOffscreenWrite: write.requiresVerifiedOffscreenWrite,
    animationPoint: write.animationPoint,
    usesCommonRibbonOffset: write.usesCommonRibbonOffset
  )
}

func frameApplicationReference(
  pendingCorrection: Rect?,
  settlingReference: Rect?,
  completedPosition: CGPoint?,
  previousTarget: Rect?,
  prefersCompletedPosition: Bool = false,
  pendingAnimation: Bool = false,
  nativeReference: @autoclosure () -> Rect?
) -> Rect? {
  if let pendingCorrection {
    return pendingCorrection
  }
  if let completedPosition,
    let reference = settlingReference ?? (prefersCompletedPosition ? previousTarget : nil)
  {
    return Rect(
      x: completedPosition.x, y: completedPosition.y,
      width: reference.width, height: reference.height)
  }
  if pendingAnimation, let previousTarget {
    let position = completedPosition ?? nativeReference().map {
      CGPoint(x: $0.x, y: $0.y)
    }
    if let position {
      return Rect(
        x: position.x,
        y: position.y,
        width: previousTarget.width,
        height: previousTarget.height
      )
    }
  }
  return settlingReference ?? previousTarget ?? nativeReference()
}

func frameCorrectionsPreservingDebt(
  existing: [WindowID: Rect],
  observed: [WindowID: Rect],
  debtWindowIDs: Set<WindowID>
) -> [WindowID: Rect] {
  var corrections = observed
  for windowID in debtWindowIDs where corrections[windowID] == nil {
    corrections[windowID] = existing[windowID]
  }
  return corrections
}

func frameWritesPreservingSupersededAsyncSizes(
  active: [WindowID: AsyncPositionWrite],
  pending: [WindowID: AsyncPositionWrite],
  replacement: [WindowID: AsyncPositionWrite]
) -> [WindowID: AsyncPositionWrite] {
  var sizeDebt = active.filter { _, write in
    asynchronousSizeWriteIsRequired(
      sizeChanged: write.sizeChanged,
      synchronousWriteSucceeded: write.synchronousSizeWriteSucceeded,
      animatesSize: write.animatesSize
    )
  }
  for (windowID, write) in pending {
    guard asynchronousSizeWriteIsRequired(
      sizeChanged: write.sizeChanged,
      synchronousWriteSucceeded: write.synchronousSizeWriteSucceeded,
      animatesSize: write.animatesSize
    ) else { continue }
    sizeDebt[windowID] = write
  }
  var result = sizeDebt
  for (windowID, newer) in replacement {
    if let debt = sizeDebt[windowID], !newer.sizeChanged {
      result[windowID] = AsyncPositionWrite(
        element: newer.element,
        application: newer.application,
        processID: newer.processID,
        fromPoint: newer.fromPoint,
        point: newer.point,
        fromSize: newer.fromSize,
        size: newer.size,
        positionChanged: newer.positionChanged,
        sizeChanged: true,
        animatesSize: debt.animatesSize,
        usesLogicalRibbonPath: newer.usesLogicalRibbonPath,
        synchronousSizeWriteSucceeded: debt.synchronousSizeWriteSucceeded,
        enhancedUIWasEnabled: newer.enhancedUIWasEnabled,
        timeoutSeconds: newer.timeoutSeconds,
        isParked: newer.isParked,
        isReentering: newer.isReentering,
        requiresVerifiedOffscreenWrite: newer.requiresVerifiedOffscreenWrite,
        animationPoint: newer.animationPoint,
        usesCommonRibbonOffset: newer.usesCommonRibbonOffset
      )
    } else {
      result[windowID] = newer
    }
  }
  return result
}

struct RecentInternalFrameWrite: Equatable, Sendable {
  let frame: Rect
  let positionChanged: Bool
  let sizeChanged: Bool
  let deadline: TimeInterval
}

func frameMatchesRecentInternalWrite(
  actual: Rect,
  write: RecentInternalFrameWrite,
  tolerance: Double = 3
) -> Bool {
  let positionMatches = abs(actual.x - write.frame.x) <= tolerance
    && abs(actual.y - write.frame.y) <= tolerance
  let sizeMatches = abs(actual.width - write.frame.width) <= tolerance
    && abs(actual.height - write.frame.height) <= tolerance
  return positionMatches && sizeMatches
}

struct InitialSettlementTarget: @unchecked Sendable {
  let generation: UInt64
  let write: AsyncPositionWrite
  let deadline: TimeInterval
}

struct QueuedPositionFrame: @unchecked Sendable {
  let generation: UInt64
  let source: String
  let writes: [WindowID: AsyncPositionWrite]
  let animatedWindowIDs: Set<WindowID>
  var animationDuration: TimeInterval
  let refreshRateHz: Double
  let displayIDs: Set<UInt64>
  let monitorFrames: [Rect]
  let initialProgressVelocity: Double
  let stagesVisibleBeforeParking: Bool
  let successfulWrite: (@Sendable (WindowID, TimeInterval) -> Void)?
  let completion: (@Sendable (FrameWriteCompletion) -> Void)?
  let cursorWarpAfterWindowCommit:
    (@Sendable (WindowID, UInt64) -> Void)?

  init(
    generation: UInt64,
    source: String,
    writes: [WindowID: AsyncPositionWrite],
    animatedWindowIDs: Set<WindowID>,
    animationDuration: TimeInterval,
    refreshRateHz: Double,
    displayIDs: Set<UInt64>,
    monitorFrames: [Rect] = [],
    initialProgressVelocity: Double,
    stagesVisibleBeforeParking: Bool,
    successfulWrite: (@Sendable (WindowID, TimeInterval) -> Void)? = nil,
    completion: (@Sendable (FrameWriteCompletion) -> Void)?,
    cursorWarpAfterWindowCommit:
      (@Sendable (WindowID, UInt64) -> Void)? = nil
  ) {
    self.generation = generation
    self.source = source
    self.writes = writes
    self.animatedWindowIDs = animatedWindowIDs
    self.animationDuration = animationDuration
    self.refreshRateHz = refreshRateHz
    self.displayIDs = displayIDs
    self.monitorFrames = monitorFrames
    self.initialProgressVelocity = initialProgressVelocity
    self.stagesVisibleBeforeParking = stagesVisibleBeforeParking
    self.successfulWrite = successfulWrite
    self.completion = completion
    self.cursorWarpAfterWindowCommit = cursorWarpAfterWindowCommit
  }
}

struct FrameWriteCompletion: Equatable, Sendable {
  let completedLatest: Bool
  let attemptedWindowIDs: Set<WindowID>
  let successfulWindowIDs: Set<WindowID>
  let acceptedFrames: [WindowID: Rect]

  init(
    completedLatest: Bool,
    attemptedWindowIDs: Set<WindowID>,
    successfulWindowIDs: Set<WindowID>,
    acceptedFrames: [WindowID: Rect] = [:]
  ) {
    self.completedLatest = completedLatest
    self.attemptedWindowIDs = attemptedWindowIDs
    self.successfulWindowIDs = successfulWindowIDs
    self.acceptedFrames = acceptedFrames
  }
}

func cursorWarpTimestampAfterFrameCompletion(
  requestedTimestamp: TimeInterval?,
  targetWindowID: WindowID,
  completion: FrameWriteCompletion
) -> TimeInterval? {
  guard completion.completedLatest,
    !completion.attemptedWindowIDs.contains(targetWindowID)
      || completion.successfulWindowIDs.contains(targetWindowID)
  else {
    return nil
  }
  return requestedTimestamp
}

func deferredFocusInputIsCurrent(
  requestedTimestamp: TimeInterval?,
  latestUserInputTimestamp: TimeInterval
) -> Bool {
  guard let requestedTimestamp else { return true }
  return latestUserInputTimestamp <= requestedTimestamp
}

func deferredFocusFrameIsReady(
  targetWindowID: WindowID,
  pendingFrameWindowIDs: Set<WindowID>
) -> Bool {
  !pendingFrameWindowIDs.contains(targetWindowID)
}

func deferredFocusFrameCommitIsReady(
  targetWindowID: WindowID,
  pendingFrameWindowIDs: Set<WindowID>,
  successfulWindowIDs: Set<WindowID>,
  observedFrame: Rect?,
  targetFrame: Rect?
) -> Bool {
  guard !pendingFrameWindowIDs.contains(targetWindowID) else { return false }
  if successfulWindowIDs.contains(targetWindowID) { return true }
  guard let observedFrame, let targetFrame else { return false }
  return frameDistance(observedFrame, targetFrame) <= 1
}

func cursorWarpFrameReadiness(
  latestWriteSucceeded: Bool?,
  observedFrame: Rect?,
  targetFrame: Rect?
) -> Bool {
  if latestWriteSucceeded != false {
    return true
  }
  guard let observedFrame, let targetFrame else { return false }
  return frameDistance(observedFrame, targetFrame) <= 1
}

func frameSizeWriteSucceeded(
  sizeChanged: Bool,
  synchronousWriteSucceeded: Bool,
  animatesSize: Bool,
  asynchronousWriteSucceeded: Bool
) -> Bool {
  !sizeChanged
    || (synchronousWriteSucceeded && !animatesSize)
    || asynchronousWriteSucceeded
}

func asynchronousSizeWriteIsRequired(
  sizeChanged: Bool,
  synchronousWriteSucceeded: Bool,
  animatesSize: Bool
) -> Bool {
  sizeChanged && (animatesSize || !synchronousWriteSucceeded)
}

struct FrameAnimationLanePlan: Equatable, Sendable {
  let interpolatedWindowIDs: Set<WindowID>
  let finalOnlyWindowIDs: Set<WindowID>
  let stagedFinalOnlyReentryWindowIDs: Set<WindowID>
  let deferredSizeWindowIDs: Set<WindowID>
}

func frameAnimationLanePlan(
  animatedWindowIDs: Set<WindowID>,
  processIDs: [WindowID: pid_t],
  reenteringWindowIDs: Set<WindowID>,
  finalOnlyProcessIDs: Set<pid_t>,
  deferredSizeWindowIDs: Set<WindowID>
) -> FrameAnimationLanePlan {
  let finalOnlyWindowIDs = Set(
    animatedWindowIDs.filter { windowID in
      processIDs[windowID].map(finalOnlyProcessIDs.contains) ?? false
    }
  )
  let interpolatedWindowIDs = animatedWindowIDs.subtracting(finalOnlyWindowIDs)
  return FrameAnimationLanePlan(
    interpolatedWindowIDs: interpolatedWindowIDs,
    finalOnlyWindowIDs: finalOnlyWindowIDs,
    stagedFinalOnlyReentryWindowIDs: finalOnlyWindowIDs.intersection(
      reenteringWindowIDs
    ),
    deferredSizeWindowIDs: deferredSizeWindowIDs.intersection(interpolatedWindowIDs)
  )
}

func positionWritePhases(
  windowIDs: Set<WindowID>,
  parkedWindowIDs: Set<WindowID>,
  stagesVisibleBeforeParking: Bool
) -> [Set<WindowID>] {
  guard !windowIDs.isEmpty else { return [] }
  guard stagesVisibleBeforeParking else { return [windowIDs] }
  let visibleWindowIDs = windowIDs.subtracting(parkedWindowIDs)
  return [visibleWindowIDs, windowIDs.intersection(parkedWindowIDs)]
    .filter { !$0.isEmpty }
}

func defersEnhancedUIRestore(
  enhancedUIWasEnabled: Bool,
  positionChanged: Bool
) -> Bool {
  enhancedUIWasEnabled && positionChanged
}

func shouldApplyDeferredFocus(
  targetWindowID: WindowID,
  selectedWindowID: WindowID?
) -> Bool {
  targetWindowID == selectedWindowID
}

struct ProcessWriteBatch: @unchecked Sendable {
  let processID: pid_t
  let writes: [(key: WindowID, value: AsyncPositionWrite)]
}

struct ProcessAnimationSample: @unchecked Sendable {
  let frame: QueuedPositionFrame
  let batch: ProcessWriteBatch
  let progress: Double
  let progressVelocity: Double
  let intermediate: Bool
  let stagingReentry: Bool
  let recordFinalSuccess: Bool
  let accumulator: FrameResultAccumulator
  let completion: (@Sendable () -> Void)?
  var laneReady: (@Sendable () -> Void)? = nil
}

struct LatestAnimationSampleState<Sample> {
  private(set) var isRunning = false
  private var pending: Sample?

  mutating func submit(
    _ sample: Sample
  ) -> (startsDrain: Bool, displaced: Sample?) {
    let displaced = pending
    pending = sample
    guard !isRunning else { return (false, displaced) }
    isRunning = true
    return (true, displaced)
  }

  mutating func takeNext() -> Sample? {
    guard let pending else {
      isRunning = false
      return nil
    }
    self.pending = nil
    return pending
  }
}

final class FrameResultAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private var applied = 0
  private var intermediateApplied = 0
  private var stale = 0
  private var slowProcesses = Set<pid_t>()
  private var processLatencySamplesMS: [pid_t: Double] = [:]
  private var firstCompletionAt = TimeInterval.greatestFiniteMagnitude
  private var lastCompletionAt = 0.0
  private var peakIntermediateLatencyMS = 0.0

  var maximumIntermediateLatencyMS: Double {
    lock.lock()
    defer { lock.unlock() }
    return peakIntermediateLatencyMS
  }

  func add(
    applied: Int,
    stale: Int,
    slowProcesses: Set<pid_t>,
    processID: pid_t,
    processLatencyMS: Double,
    attempted: Bool,
    completedAt: TimeInterval,
    intermediate: Bool = false
  ) {
    lock.lock()
    self.applied += applied
    if intermediate {
      intermediateApplied += applied
      peakIntermediateLatencyMS = max(peakIntermediateLatencyMS, processLatencyMS)
    }
    self.stale += stale
    self.slowProcesses.formUnion(slowProcesses)
    if attempted {
      processLatencySamplesMS[processID] = processLatencyMS
    }
    firstCompletionAt = min(firstCompletionAt, completedAt)
    lastCompletionAt = max(lastCompletionAt, completedAt)
    lock.unlock()
  }

  var result:
    (
      applied: Int,
      intermediateApplied: Int,
      stale: Int,
      slowProcesses: Set<pid_t>,
      processLatencySamplesMS: [pid_t: Double],
      completionSpreadMS: Double
    )
  {
    lock.lock()
    defer { lock.unlock() }
    let spread =
      firstCompletionAt.isFinite
      ? max(lastCompletionAt - firstCompletionAt, 0) * 1_000
      : 0
    return (
      applied,
      intermediateApplied,
      stale,
      slowProcesses,
      processLatencySamplesMS,
      spread
    )
  }
}
