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
  let command: CommandPerformanceContext?
  var observedAt: TimeInterval?

  init(
    from: Rect,
    target: Rect,
    issuedAt: TimeInterval,
    deadline: TimeInterval,
    command: CommandPerformanceContext? = nil,
    observedAt: TimeInterval?
  ) {
    self.from = from
    self.target = target
    self.issuedAt = issuedAt
    self.deadline = deadline
    self.command = command
    self.observedAt = observedAt
  }
}

public struct CommandPerformanceContext: Equatable, Sendable {
  public let generation: UInt64
  public let inputTimestamp: TimeInterval

  public init(generation: UInt64, inputTimestamp: TimeInterval) {
    self.generation = generation
    self.inputTimestamp = inputTimestamp
  }
}

public struct LatencyPercentiles: Equatable, Sendable {
  public let count: Int
  public let p50MS: Double
  public let p95MS: Double
  public let p99MS: Double
}

public struct CommandLatencyPerformance: Equatable, Sendable {
  public let started: Int
  public let superseded: Int
  public let plan: LatencyPercentiles
  public let firstWrite: LatencyPercentiles
  public let firstObservation: LatencyPercentiles
  public let convergence: LatencyPercentiles
  public let focus: LatencyPercentiles
}

struct CommandLatencyRecord: Equatable {
  let inputTimestamp: TimeInterval
  var expectedWindowIDs = Set<WindowID>()
  var convergedWindowIDs = Set<WindowID>()
  var expectsFocus = false
  var firstWriteRecorded = false
  var firstObservationRecorded = false
  var convergenceRecorded = false
  var focusRecorded = false
}

struct CommandLatencyAccumulator {
  private(set) var latestGeneration: UInt64 = 0
  private(set) var started = 0
  private(set) var superseded = 0
  private(set) var record: CommandLatencyRecord?
  private(set) var planSamplesMS: [Double] = []
  private(set) var firstWriteSamplesMS: [Double] = []
  private(set) var firstObservationSamplesMS: [Double] = []
  private(set) var convergenceSamplesMS: [Double] = []
  private(set) var focusSamplesMS: [Double] = []

  mutating func begin(_ context: CommandPerformanceContext) {
    guard context.generation > latestGeneration else { return }
    if let previous = record,
      !previous.convergenceRecorded
        && (previous.expectsFocus
          || !previous.expectedWindowIDs.isEmpty
          || previous.firstWriteRecorded
          || previous.firstObservationRecorded)
    {
      superseded += 1
    }
    latestGeneration = context.generation
    record = CommandLatencyRecord(inputTimestamp: context.inputTimestamp)
    started += 1
  }

  mutating func recordFocusExpectation(
    _ context: CommandPerformanceContext,
    expectsFocus: Bool
  ) {
    guard var record = currentRecord(for: context) else { return }
    record.expectsFocus = expectsFocus
    self.record = record
  }

  mutating func recordPlan(
    _ context: CommandPerformanceContext,
    expectedWindowIDs: Set<WindowID>,
    hasFrameWrites: Bool = true,
    at timestamp: TimeInterval
  ) -> Double? {
    guard var record = currentRecord(for: context) else { return nil }
    record.expectedWindowIDs = expectedWindowIDs
    let latency = latencyMS(from: context, to: timestamp)
    recordDurationSample(latency, in: &planSamplesMS)
    if expectedWindowIDs.isEmpty,
      !record.expectsFocus,
      !hasFrameWrites,
      !record.convergenceRecorded
    {
      record.convergenceRecorded = true
      recordDurationSample(latency, in: &convergenceSamplesMS)
    }
    self.record = record
    return latency
  }

  mutating func recordFirstWrite(
    _ context: CommandPerformanceContext,
    at timestamp: TimeInterval
  ) -> Double? {
    guard var record = currentRecord(for: context),
      !record.firstWriteRecorded
    else { return nil }
    record.firstWriteRecorded = true
    let latency = latencyMS(from: context, to: timestamp)
    recordDurationSample(latency, in: &firstWriteSamplesMS)
    if record.expectedWindowIDs.isEmpty,
      !record.expectsFocus,
      !record.convergenceRecorded
    {
      record.convergenceRecorded = true
      recordDurationSample(latency, in: &convergenceSamplesMS)
    }
    self.record = record
    return latency
  }

  mutating func recordObservation(
    _ context: CommandPerformanceContext,
    windowID: WindowID,
    from: Rect,
    actual: Rect,
    target: Rect,
    at timestamp: TimeInterval
  ) -> (firstObservationMS: Double?, convergenceMS: Double?) {
    guard var record = currentRecord(for: context) else { return (nil, nil) }
    var firstObservationMS: Double?
    if !record.firstObservationRecorded,
      frameDistance(from, actual) >= 0.5
    {
      record.firstObservationRecorded = true
      firstObservationMS = latencyMS(from: context, to: timestamp)
      recordDurationSample(
        firstObservationMS ?? 0,
        in: &firstObservationSamplesMS
      )
    }
    if approximatelyEqual(actual, target) {
      record.convergedWindowIDs.insert(windowID)
    } else {
      record.convergedWindowIDs.remove(windowID)
    }
    var convergenceMS: Double?
    if !record.convergenceRecorded,
      !record.expectedWindowIDs.isEmpty,
      record.expectedWindowIDs.isSubset(of: record.convergedWindowIDs)
    {
      record.convergenceRecorded = true
      convergenceMS = latencyMS(from: context, to: timestamp)
      recordDurationSample(convergenceMS ?? 0, in: &convergenceSamplesMS)
    }
    self.record = record
    return (firstObservationMS, convergenceMS)
  }

  mutating func recordFocus(
    _ context: CommandPerformanceContext,
    at timestamp: TimeInterval
  ) -> Double? {
    guard var record = currentRecord(for: context), !record.focusRecorded
    else { return nil }
    record.focusRecorded = true
    let latency = latencyMS(from: context, to: timestamp)
    recordDurationSample(latency, in: &focusSamplesMS)
    if record.expectedWindowIDs.isEmpty,
      record.expectsFocus,
      !record.convergenceRecorded
    {
      record.convergenceRecorded = true
      recordDurationSample(latency, in: &convergenceSamplesMS)
    }
    self.record = record
    return latency
  }

  var performance: CommandLatencyPerformance {
    CommandLatencyPerformance(
      started: started,
      superseded: superseded,
      plan: percentiles(planSamplesMS),
      firstWrite: percentiles(firstWriteSamplesMS),
      firstObservation: percentiles(firstObservationSamplesMS),
      convergence: percentiles(convergenceSamplesMS),
      focus: percentiles(focusSamplesMS)
    )
  }

  private func currentRecord(
    for context: CommandPerformanceContext
  ) -> CommandLatencyRecord? {
    guard context.generation == latestGeneration,
      let record,
      record.inputTimestamp == context.inputTimestamp
    else { return nil }
    return record
  }

  private func latencyMS(
    from context: CommandPerformanceContext,
    to timestamp: TimeInterval
  ) -> Double {
    max(timestamp - context.inputTimestamp, 0) * 1_000
  }

  private func percentiles(_ samples: [Double]) -> LatencyPercentiles {
    LatencyPercentiles(
      count: samples.count,
      p50MS: durationPercentile(0.50, samples: samples),
      p95MS: durationPercentile(0.95, samples: samples),
      p99MS: durationPercentile(0.99, samples: samples)
    )
  }
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

func updatedInitialSettlementDriftSample(
  previous: InitialSettlementDriftSample?,
  generation: UInt64,
  actual: Rect,
  now: TimeInterval,
  tolerance: Double = 2
) -> InitialSettlementDriftSample {
  let preservesFirstObservation = previous.map {
    $0.generation == generation
      && frameDistance($0.frame, actual) <= tolerance
  } ?? false
  return InitialSettlementDriftSample(
    generation: generation,
    frame: actual,
    observedAt: preservesFirstObservation
      ? previous?.observedAt ?? now
      : now
  )
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
