import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

private let animationMachTimebase: mach_timebase_info_data_t = {
  var timebase = mach_timebase_info_data_t()
  mach_timebase_info(&timebase)
  return timebase
}()

func spinWaitPrecisely(for duration: TimeInterval) {
  guard duration > 0 else { return }
  let nanoseconds = duration * 1_000_000_000
  let ticks = UInt64(
    nanoseconds
      * Double(animationMachTimebase.denom)
      / Double(animationMachTimebase.numer)
  )
  let deadline = mach_absolute_time() &+ ticks
  while mach_absolute_time() < deadline {}
}


struct FrameWriteIntent: Equatable, Sendable {
  let position: Bool
  let size: Bool
}

func frameWriteIntent(
  reference: Rect,
  target: Rect,
  positionsOnly: Bool
) -> FrameWriteIntent {
  FrameWriteIntent(
    position: abs(reference.x - target.x) >= 0.5
      || abs(reference.y - target.y) >= 0.5,
    size: !positionsOnly
      && (abs(reference.width - target.width) >= 0.5
        || abs(reference.height - target.height) >= 0.5)
  )
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
  let animatesSize: Bool
  let synchronousSizeWriteSucceeded: Bool
  let enhancedUIWasEnabled: Bool
  let timeoutSeconds: Float
  let isParked: Bool
  let isReentering: Bool
  let requiresVerifiedOffscreenWrite: Bool
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
        size: debt.size,
        positionChanged: newer.positionChanged,
        sizeChanged: true,
        animatesSize: debt.animatesSize,
        synchronousSizeWriteSucceeded: debt.synchronousSizeWriteSucceeded,
        enhancedUIWasEnabled: newer.enhancedUIWasEnabled,
        timeoutSeconds: newer.timeoutSeconds,
        isParked: newer.isParked,
        isReentering: newer.isReentering,
        requiresVerifiedOffscreenWrite: newer.requiresVerifiedOffscreenWrite
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
  let positionMatches = !write.positionChanged
    || (abs(actual.x - write.frame.x) <= tolerance
      && abs(actual.y - write.frame.y) <= tolerance)
  let sizeMatches = !write.sizeChanged
    || (abs(actual.width - write.frame.width) <= tolerance
      && abs(actual.height - write.frame.height) <= tolerance)
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
  let animationDuration: TimeInterval
  let refreshRateHz: Double
  let stagesVisibleBeforeParking: Bool
  let completion: (@Sendable (FrameWriteCompletion) -> Void)?
}

struct FrameWriteCompletion: Equatable, Sendable {
  let completedLatest: Bool
  let attemptedWindowIDs: Set<WindowID>
  let successfulWindowIDs: Set<WindowID>
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
}

func frameAnimationLanePlan(
  animatedWindowIDs: Set<WindowID>,
  processIDs: [WindowID: pid_t],
  reenteringWindowIDs: Set<WindowID>,
  finalOnlyProcessIDs: Set<pid_t>
) -> FrameAnimationLanePlan {
  let finalOnlyWindowIDs = Set(
    animatedWindowIDs.filter { windowID in
      processIDs[windowID].map(finalOnlyProcessIDs.contains) ?? false
    }
  )
  return FrameAnimationLanePlan(
    interpolatedWindowIDs: animatedWindowIDs.subtracting(finalOnlyWindowIDs),
    finalOnlyWindowIDs: finalOnlyWindowIDs,
    stagedFinalOnlyReentryWindowIDs: finalOnlyWindowIDs.intersection(
      reenteringWindowIDs
    )
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

func suppressesNativePositionAnimation(
  stagesVisibleBeforeParking: Bool,
  isParked: Bool,
  isIntermediate: Bool
) -> Bool {
  stagesVisibleBeforeParking && !isParked && !isIntermediate
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
  private var slowProcesses = Set<pid_t>()
  private var processLatencySamplesMS: [pid_t: Double] = [:]
  private var firstCompletionAt = TimeInterval.greatestFiniteMagnitude
  private var lastCompletionAt = 0.0

  func add(
    applied: Int,
    stale: Int,
    slowProcesses: Set<pid_t>,
    processID: pid_t,
    processLatencyMS: Double,
    completedAt: TimeInterval
  ) {
    lock.lock()
    self.applied += applied
    self.stale += stale
    self.slowProcesses.formUnion(slowProcesses)
    processLatencySamplesMS[processID] = processLatencyMS
    firstCompletionAt = min(firstCompletionAt, completedAt)
    lastCompletionAt = max(lastCompletionAt, completedAt)
    lock.unlock()
  }

  var result:
    (
      applied: Int,
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
      stale,
      slowProcesses,
      processLatencySamplesMS,
      spread
    )
  }
}

struct ConcurrentFrameResult: Sendable {
  let applied: Int
  let stale: Int
  let completionSpreadMS: Double
  let frames: Int
}

final class ConcurrentFrameResultStore: @unchecked Sendable {
  private let lock = NSLock()
  private var storedResult: ConcurrentFrameResult?

  func store(_ result: ConcurrentFrameResult) {
    lock.lock()
    storedResult = result
    lock.unlock()
  }

  var result: ConcurrentFrameResult? {
    lock.lock()
    defer { lock.unlock() }
    return storedResult
  }
}
