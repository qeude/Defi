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

struct FrameCommitExpectation: Equatable, Sendable {
  let from: Rect
  let target: Rect
  let issuedAt: TimeInterval
  let deadline: TimeInterval
  var observedAt: TimeInterval?
}

func frameCommitQuarantineDuration(
  animationDuration: TimeInterval,
  initialFrameSettlement: Bool
) -> TimeInterval {
  if initialFrameSettlement {
    return max(animationDuration + 0.12, 0.18)
  }
  return max(animationDuration + 0.25, 0.8)
}

func initialFrameNeedsRepair(
  actual: Rect,
  target: Rect,
  tolerance: Double = 1
) -> Bool {
  abs(actual.x - target.x) > tolerance
    || abs(actual.y - target.y) > tolerance
    || abs(actual.width - target.width) > tolerance
    || abs(actual.height - target.height) > tolerance
}

enum InitialSettlementObservation: Equatable {
  case expired
  case stable
  case drifted
}

func initialSettlementObservation(
  actual: Rect,
  target: Rect,
  now: TimeInterval,
  deadline: TimeInterval
) -> InitialSettlementObservation {
  guard now < deadline else { return .expired }
  return initialFrameNeedsRepair(actual: actual, target: target)
    ? .drifted
    : .stable
}

func initialSettlementRepairIsCurrent(
  expectedGeneration: UInt64,
  currentGeneration: UInt64?,
  repairsSuspended: Bool,
  leftMouseButtonDown: Bool,
  animationRunning: Bool
) -> Bool {
  !repairsSuspended
    && !leftMouseButtonDown
    && !animationRunning
    && currentGeneration == expectedGeneration
}

func incrementalWindowRefreshProcessIDs(
  hasCompletedSnapshot: Bool,
  eventPending: Bool,
  requiresFullSnapshot: Bool,
  processIDs: Set<pid_t>,
  coalescedProcessIDs: Set<pid_t> = [],
  coalescedEventRequiresFullSnapshot: Bool = false,
  allowsCoalescedProcessRefresh: Bool = false
) -> Set<pid_t>? {
  let affectedProcessIDs = processIDs.union(coalescedProcessIDs)
  guard hasCompletedSnapshot,
    eventPending
      || (allowsCoalescedProcessRefresh && !coalescedProcessIDs.isEmpty),
    !requiresFullSnapshot,
    !coalescedEventRequiresFullSnapshot,
    !affectedProcessIDs.isEmpty
  else {
    return nil
  }
  return affectedProcessIDs
}

func frameIsOnExpectedCommitPath(
  actual: Rect,
  currentTarget: Rect,
  expectation: FrameCommitExpectation,
  now: TimeInterval,
  leftMouseButtonDown: Bool,
  tolerance: Double = 3
) -> Bool {
  guard !leftMouseButtonDown,
    now < expectation.deadline,
    frameDistance(currentTarget, expectation.target) <= tolerance
  else {
    return false
  }
  return [
    (actual.x, expectation.from.x, expectation.target.x),
    (actual.y, expectation.from.y, expectation.target.y),
    (actual.width, expectation.from.width, expectation.target.width),
    (actual.height, expectation.from.height, expectation.target.height),
  ].allSatisfy { value, from, target in
    value >= min(from, target) - tolerance
      && value <= max(from, target) + tolerance
  }
}

func requiresVerifiedOffscreenWrite(
  frame: Rect,
  monitorFrames: [Rect],
  maximumVisibleWidth: Double = parkedSliverWidth + 0.5
) -> Bool {
  let visibleWidth = monitorFrames.reduce(0.0) { currentMaximum, monitor in
    let verticalIntersection = max(
      min(frame.y + frame.height, monitor.y + monitor.height)
        - max(frame.y, monitor.y),
      0
    )
    guard verticalIntersection > 0 else { return currentMaximum }
    let horizontalIntersection = max(
      min(frame.x + frame.width, monitor.x + monitor.width)
        - max(frame.x, monitor.x),
      0
    )
    return max(currentMaximum, horizontalIntersection)
  }
  return visibleWidth <= maximumVisibleWidth
}

func axProcessIsLatencySensitive(
  previouslySensitive: Bool,
  predictedLatencyMS: Double,
  enterThresholdMS: Double = 12,
  exitThresholdMS: Double = 7
) -> Bool {
  guard predictedLatencyMS.isFinite else { return previouslySensitive }
  return previouslySensitive
    ? predictedLatencyMS >= exitThresholdMS
    : predictedLatencyMS >= enterThresholdMS
}

func frameTargetsPreservingSkippedWindows(
  previous: [WindowID: Rect],
  assignments: [FrameAssignment],
  skippedWindowIDs: Set<WindowID>
) -> [WindowID: Rect] {
  let assignedWindowIDs = Set(assignments.map(\.windowID))
  var next = Dictionary(
    uniqueKeysWithValues: assignments.compactMap { assignment in
      skippedWindowIDs.contains(assignment.windowID)
        ? nil
        : (assignment.windowID, assignment.frame)
    }
  )
  for windowID in skippedWindowIDs where assignedWindowIDs.contains(windowID) {
    next[windowID] = previous[windowID]
  }
  return next
}

func hiddenWindowsPreservingSkippedWindows(
  previous: Set<WindowID>,
  desired: Set<WindowID>,
  skippedWindowIDs: Set<WindowID>
) -> Set<WindowID> {
  desired.subtracting(skippedWindowIDs)
    .union(previous.intersection(skippedWindowIDs))
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
  let enhancedUIWasEnabled: Bool
  let timeoutSeconds: Float
  let isParked: Bool
  let isReentering: Bool
  let requiresVerifiedOffscreenWrite: Bool
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
