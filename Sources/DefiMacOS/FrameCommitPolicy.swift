import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

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

struct InitialSettlementDriftSample: Equatable, Sendable {
  let generation: UInt64
  let frame: Rect
  let observedAt: TimeInterval
}

func initialSettlementDriftIsStable(
  previous: InitialSettlementDriftSample?,
  generation: UInt64,
  actual: Rect,
  now: TimeInterval,
  minimumStableDuration: TimeInterval = 0.06,
  tolerance: Double = 2
) -> Bool {
  guard let previous,
    previous.generation == generation,
    now - previous.observedAt >= minimumStableDuration
  else {
    return false
  }
  return frameDistance(previous.frame, actual) <= tolerance
}

func initialSettlementFollowUpDelay(
  now: TimeInterval,
  deadline: TimeInterval,
  minimumStableDuration: TimeInterval = 0.06
) -> TimeInterval? {
  let remaining = deadline - now
  guard remaining > minimumStableDuration else { return nil }
  return minimumStableDuration
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
  allowsCoalescedProcessRefresh: Bool = false,
  allowsCachedRefresh: Bool = false
) -> Set<pid_t>? {
  let affectedProcessIDs = processIDs.union(coalescedProcessIDs)
  guard hasCompletedSnapshot,
    !requiresFullSnapshot,
    !coalescedEventRequiresFullSnapshot
  else {
    return nil
  }
  if eventPending && !affectedProcessIDs.isEmpty {
    return affectedProcessIDs
  }
  if allowsCoalescedProcessRefresh && !coalescedProcessIDs.isEmpty {
    return coalescedProcessIDs
  }
  return allowsCachedRefresh ? [] : nil
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

func unresolvedFrameDebtWindowIDs(
  pendingWindowIDs: Set<WindowID>,
  debtWindowIDs: Set<WindowID>,
  targetFrames: [WindowID: Rect],
  observedFrames: [WindowID: Rect],
  tolerance: Double = 1
) -> Set<WindowID> {
  pendingWindowIDs.union(
    debtWindowIDs.filter { windowID in
      guard let target = targetFrames[windowID] else { return false }
      guard let observed = observedFrames[windowID] else { return true }
      return frameDistance(observed, target) > tolerance
    }
  )
}

func prunedFrameDebtWindowIDs(
  debtWindowIDs: Set<WindowID>,
  liveWindowIDs: Set<WindowID>,
  targetFrames: [WindowID: Rect],
  observedFrames: [WindowID: Rect],
  tolerance: Double = 1
) -> Set<WindowID> {
  debtWindowIDs.filter { windowID in
    guard liveWindowIDs.contains(windowID),
      let target = targetFrames[windowID]
    else {
      return false
    }
    guard let observed = observedFrames[windowID] else { return true }
    return frameDistance(observed, target) > tolerance
  }
}

func hiddenWindowsPreservingSkippedWindows(
  previous: Set<WindowID>,
  desired: Set<WindowID>,
  skippedWindowIDs: Set<WindowID>
) -> Set<WindowID> {
  desired.subtracting(skippedWindowIDs)
    .union(previous.intersection(skippedWindowIDs))
}
