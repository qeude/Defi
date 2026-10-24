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

/// Horizontal navigation keeps an app's own vertical clamp (a few points), never
/// a parked window's place below its display.
func keepsNativeY(from startY: Double, to targetY: Double, horizontalOnly: Bool) -> Bool {
  horizontalOnly && abs(targetY - startY) < 40
}

func frameWritePosition(target: CGPoint, from start: CGPoint, horizontalOnly: Bool) -> CGPoint {
  CGPoint(x: target.x,
    y: keepsNativeY(from: start.y, to: target.y, horizontalOnly: horizontalOnly) ? start.y : target.y)
}

func frameWriteIntent(
  reference: Rect,
  target: Rect,
  positionsOnly: Bool,
  horizontalOnly: Bool = false
) -> FrameWriteIntent {
  FrameWriteIntent(
    position: abs(reference.x - target.x) >= 0.5
      || (!keepsNativeY(from: reference.y, to: target.y, horizontalOnly: horizontalOnly)
        && abs(reference.y - target.y) >= 0.5),
    size: !positionsOnly
      && (abs(reference.width - target.width) >= 0.5
        || abs(reference.height - target.height) >= 0.5)
  )
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
  if frameCentersCrossDisplays(from: source, to: target, displayFrames: displayFrames) {
    return true
  }
  // macOS clamps an Accessibility resize to the display at the window's current
  // position, so growth past its right edge only fits once the window has moved.
  // Locate by the leading edge: a stale start size can push the center off the display.
  let leadingEdge = Rect(x: source.x, y: source.y, width: 0, height: source.height)
  guard let display = displayFrames.first(where: { $0.contains(centerOf: leadingEdge) }) else {
    return false
  }
  return source.x + target.width > display.x + display.width + 1
}

struct AsyncPositionWrite: @unchecked Sendable {
  let element: AXUIElement
  let application: AXUIElement
  let processID: pid_t
  let fromPoint: CGPoint
  let point: CGPoint
  let fromSize: CGSize
  let size: CGSize
  let positionChanged: Bool
  let sizeChanged: Bool
  let synchronousSizeWriteSucceeded: Bool
  let enhancedUIWasEnabled: Bool
  let timeoutSeconds: Float
  let isParked: Bool
  let requiresVerifiedOffscreenWrite: Bool
  var binding: BorderGeometryReadTarget? = nil
}

func frameApplicationReference(
  pendingCorrection: Rect?,
  completedPosition: CGPoint?,
  previousTarget: Rect?,
  prefersCompletedPosition: Bool = false,
  nativeReference: @autoclosure () -> Rect?
) -> Rect? {
  if let pendingCorrection {
    return pendingCorrection
  }
  if prefersCompletedPosition, let completedPosition, let previousTarget {
    return Rect(
      x: completedPosition.x, y: completedPosition.y,
      width: previousTarget.width, height: previousTarget.height)
  }
  return previousTarget ?? nativeReference()
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
      synchronousWriteSucceeded: write.synchronousSizeWriteSucceeded
    )
  }
  for (windowID, write) in pending {
    guard asynchronousSizeWriteIsRequired(
      sizeChanged: write.sizeChanged,
      synchronousWriteSucceeded: write.synchronousSizeWriteSucceeded
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
        synchronousSizeWriteSucceeded: debt.synchronousSizeWriteSucceeded,
        enhancedUIWasEnabled: newer.enhancedUIWasEnabled,
        timeoutSeconds: newer.timeoutSeconds,
        isParked: newer.isParked,
        requiresVerifiedOffscreenWrite: newer.requiresVerifiedOffscreenWrite,
        binding: newer.binding
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
  let monitorFrames: [Rect]
  let stagesVisibleBeforeParking: Bool
  let successfulWrite: (@Sendable (WindowID, TimeInterval) -> Void)?
  let completion: (@Sendable (FrameWriteCompletion) -> Void)?
  let cursorWarpAfterWindowCommit:
    (@Sendable (WindowID, UInt64) -> Void)?

  init(
    generation: UInt64,
    source: String,
    writes: [WindowID: AsyncPositionWrite],
    monitorFrames: [Rect] = [],
    stagesVisibleBeforeParking: Bool,
    successfulWrite: (@Sendable (WindowID, TimeInterval) -> Void)? = nil,
    completion: (@Sendable (FrameWriteCompletion) -> Void)?,
    cursorWarpAfterWindowCommit:
      (@Sendable (WindowID, UInt64) -> Void)? = nil
  ) {
    self.generation = generation
    self.source = source
    self.writes = writes
    self.monitorFrames = monitorFrames
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
  let acceptedObservations: [BorderGeometryObservation]

  init(
    completedLatest: Bool,
    attemptedWindowIDs: Set<WindowID>,
    successfulWindowIDs: Set<WindowID>,
    acceptedObservations: [BorderGeometryObservation] = []
  ) {
    self.completedLatest = completedLatest
    self.attemptedWindowIDs = attemptedWindowIDs
    self.successfulWindowIDs = successfulWindowIDs
    self.acceptedObservations = acceptedObservations
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
  asynchronousWriteSucceeded: Bool
) -> Bool {
  !sizeChanged || synchronousWriteSucceeded || asynchronousWriteSucceeded
}

func asynchronousSizeWriteIsRequired(
  sizeChanged: Bool,
  synchronousWriteSucceeded: Bool
) -> Bool {
  sizeChanged && !synchronousWriteSucceeded
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

final class FrameResultAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private var applied = 0
  private var stale = 0
  private var processLatencySamplesMS: [pid_t: Double] = [:]

  func add(
    applied: Int,
    stale: Int,
    processID: pid_t,
    processLatencyMS: Double,
    attempted: Bool
  ) {
    lock.lock()
    self.applied += applied
    self.stale += stale
    if attempted {
      processLatencySamplesMS[processID] = processLatencyMS
    }
    lock.unlock()
  }

  var result: (applied: Int, stale: Int, processLatencySamplesMS: [pid_t: Double]) {
    lock.lock()
    defer { lock.unlock() }
    return (applied, stale, processLatencySamplesMS)
  }
}
