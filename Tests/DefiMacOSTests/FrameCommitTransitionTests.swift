import DefiModel
import Testing

@testable import DefiMacOS

struct FrameCommitTransitionTests {
  private let expectation = FrameCommitExpectation(
    from: Rect(x: 900, y: 80, width: 700, height: 600),
    target: Rect(x: 100, y: 40, width: 1_200, height: 900),
    issuedAt: 10,
    deadline: 10.8,
    observedAt: nil
  )

  @Test
  func commandLatencyCorrelatesLatestCommandStages() {
    let first = WindowID(rawValue: 1)
    let second = WindowID(rawValue: 2)
    let from = Rect(x: 0, y: 0, width: 100, height: 100)
    let target = Rect(x: 100, y: 0, width: 100, height: 100)
    let context = CommandPerformanceContext(
      generation: 1,
      inputTimestamp: 10
    )
    var latency = CommandLatencyAccumulator()

    latency.begin(context)
    let plan = latency.recordPlan(
      context,
      expectedWindowIDs: [first, second],
      at: 10.002
    )
    #expect(abs((plan ?? 0) - 2) < 0.001)
    let firstWrite = latency.recordFirstWrite(context, at: 10.003)
    #expect(abs((firstWrite ?? 0) - 3) < 0.001)
    #expect(latency.recordFirstWrite(context, at: 10.004) == nil)
    let firstObservation = latency.recordObservation(
      context,
      windowID: first,
      from: from,
      actual: target,
      target: target,
      at: 10.010
    )
    #expect(abs((firstObservation.firstObservationMS ?? 0) - 10) < 0.001)
    #expect(firstObservation.convergenceMS == nil)
    let convergence = latency.recordObservation(
      context,
      windowID: second,
      from: from,
      actual: target,
      target: target,
      at: 10.020
    )
    #expect(convergence.firstObservationMS == nil)
    #expect(abs((convergence.convergenceMS ?? 0) - 20) < 0.001)
    let focus = latency.recordFocus(context, at: 10.025)
    #expect(abs((focus ?? 0) - 25) < 0.001)

    let performance = latency.performance
    #expect(performance.started == 1)
    #expect(performance.superseded == 0)
    #expect(abs(performance.plan.p95MS - 2) < 0.001)
    #expect(abs(performance.firstWrite.p95MS - 3) < 0.001)
    #expect(abs(performance.firstObservation.p95MS - 10) < 0.001)
    #expect(abs(performance.convergence.p95MS - 20) < 0.001)
    #expect(abs(performance.focus.p95MS - 25) < 0.001)

    let superseded = CommandPerformanceContext(
      generation: 2,
      inputTimestamp: 20
    )
    latency.begin(superseded)
    _ = latency.recordPlan(
      superseded,
      expectedWindowIDs: [first],
      at: 20.001
    )
    latency.begin(
      CommandPerformanceContext(generation: 3, inputTimestamp: 21)
    )
    #expect(latency.recordFirstWrite(superseded, at: 21.001) == nil)
    #expect(latency.performance.superseded == 1)
  }

  @Test
  func commandLatencyKeepsOnlyItsLatestSamples() {
    var latency = CommandLatencyAccumulator()

    for generation in 1...121 {
      let context = CommandPerformanceContext(
        generation: UInt64(generation),
        inputTimestamp: Double(generation)
      )
      latency.begin(context)
      _ = latency.recordPlan(
        context,
        expectedWindowIDs: [],
        hasFrameWrites: false,
        at: Double(generation) + Double(generation) / 1_000
      )
    }

    #expect(latency.performance.plan.count == 120)
    #expect(abs(latency.performance.plan.p50MS - 62) < 0.001)
  }

  @Test
  func commandDiagnosticWaitsForConvergenceAndExpectedFocus() {
    let windowID = WindowID(rawValue: 1)
    let from = Rect(x: 0, y: 0, width: 100, height: 100)
    let target = Rect(x: 100, y: 0, width: 100, height: 100)
    let context = CommandPerformanceContext(generation: 1, inputTimestamp: 10)
    var latency = CommandLatencyAccumulator()

    latency.begin(context)
    latency.recordFocusExpectation(context, expectsFocus: true)
    _ = latency.recordPlan(
      context,
      expectedWindowIDs: [windowID],
      at: 10.002
    )
    _ = latency.recordFirstWrite(context, at: 10.003)
    _ = latency.recordObservation(
      context,
      windowID: windowID,
      from: from,
      actual: target,
      target: target,
      at: 10.010
    )
    #expect(latency.takeDiagnosticSamples().isEmpty)

    _ = latency.recordFocus(context, at: 10.012)

    let sample = latency.takeDiagnosticSamples().first
    #expect(sample?.generation == 1)
    #expect(sample?.outcome == .completed)
    #expect(sample?.expectedWindowCount == 1)
    #expect(abs((sample?.planMS ?? 0) - 2) < 0.001)
    #expect(abs((sample?.convergenceMS ?? 0) - 10) < 0.001)
    #expect(abs((sample?.focusMS ?? 0) - 12) < 0.001)
  }

  @Test
  func supersededCommandProducesOneDiagnosticSample() {
    let first = CommandPerformanceContext(generation: 1, inputTimestamp: 10)
    var latency = CommandLatencyAccumulator()

    latency.begin(first)
    latency.recordFocusExpectation(first, expectsFocus: true)
    _ = latency.recordPlan(
      first,
      expectedWindowIDs: [WindowID(rawValue: 1)],
      at: 10.002
    )
    latency.begin(CommandPerformanceContext(generation: 2, inputTimestamp: 20))

    let samples = latency.takeDiagnosticSamples()
    #expect(samples.count == 1)
    #expect(samples.first?.generation == 1)
    #expect(samples.first?.outcome == .superseded)
    #expect(latency.takeDiagnosticSamples().isEmpty)
  }

  @Test
  func onlyHighSignalTraceEventsBecomePersistentAnomalies() {
    #expect(traceEventIsDiagnosticAnomaly("parking-repair wid=1"))
    #expect(traceEventIsDiagnosticAnomaly("slow g=1 pid=2 windows=1 ms=20"))
    #expect(traceEventIsDiagnosticAnomaly("sample g=1 i=2 p=0.4") == false)
    #expect(traceEventIsDiagnosticAnomaly("command-plan cg=1 windows=2 ms=2") == false)
  }

  @Test
  func commandConvergenceUsesLatestObservationForEveryWindow() {
    let first = WindowID(rawValue: 1)
    let second = WindowID(rawValue: 2)
    let from = Rect(x: 0, y: 0, width: 100, height: 100)
    let target = Rect(x: 100, y: 0, width: 100, height: 100)
    let drifted = Rect(x: 80, y: 0, width: 100, height: 100)
    let context = CommandPerformanceContext(generation: 1, inputTimestamp: 10)
    var latency = CommandLatencyAccumulator()
    latency.begin(context)
    _ = latency.recordPlan(
      context,
      expectedWindowIDs: [first, second],
      at: 10.001
    )
    _ = latency.recordObservation(
      context,
      windowID: first,
      from: from,
      actual: target,
      target: target,
      at: 10.010
    )
    _ = latency.recordObservation(
      context,
      windowID: first,
      from: from,
      actual: drifted,
      target: target,
      at: 10.020
    )
    let provisional = latency.recordObservation(
      context,
      windowID: second,
      from: from,
      actual: target,
      target: target,
      at: 10.030
    )
    #expect(provisional.convergenceMS == nil)

    let final = latency.recordObservation(
      context,
      windowID: first,
      from: from,
      actual: target,
      target: target,
      at: 10.040
    )
    #expect(abs((final.convergenceMS ?? 0) - 40) < 0.001)
  }

  @Test
  func emptyVisibleFramePlanConvergesAfterItsParkingWrite() {
    let context = CommandPerformanceContext(generation: 1, inputTimestamp: 10)
    var latency = CommandLatencyAccumulator()
    latency.begin(context)
    latency.recordFocusExpectation(context, expectsFocus: false)
    _ = latency.recordPlan(
      context,
      expectedWindowIDs: [],
      hasFrameWrites: true,
      at: 10.002
    )
    #expect(latency.performance.convergence.count == 0)
    _ = latency.recordFirstWrite(context, at: 10.003)

    latency.begin(CommandPerformanceContext(generation: 2, inputTimestamp: 20))

    #expect(latency.performance.superseded == 0)
    #expect(latency.performance.convergence.count == 1)
  }

  @Test
  func parkingOnlyPlanConvergesWithoutWaitingForUnmeasuredWrites() {
    let parked = WindowID(rawValue: 1)
    let plan = commandPerformanceFramePlan(
      writeWindowIDs: [parked],
      hiddenWindowIDs: [parked],
      availableWindowIDs: [parked]
    )
    let context = CommandPerformanceContext(generation: 1, inputTimestamp: 10)
    var latency = CommandLatencyAccumulator()
    latency.begin(context)

    _ = latency.recordPlan(
      context,
      expectedWindowIDs: plan.expectedWindowIDs,
      hasFrameWrites: plan.hasMeasuredFrameWrites,
      at: 10.002
    )

    #expect(plan.expectedWindowIDs.isEmpty)
    #expect(plan.hasMeasuredFrameWrites == false)
    #expect(latency.performance.convergence.count == 1)
  }

  @Test
  func focusOnlyPlanConvergesOnlyAfterSuccessfulFocus() {
    let context = CommandPerformanceContext(generation: 1, inputTimestamp: 10)
    var cancelled = CommandLatencyAccumulator()
    cancelled.begin(context)
    cancelled.recordFocusExpectation(context, expectsFocus: true)
    _ = cancelled.recordPlan(
      context,
      expectedWindowIDs: [],
      hasFrameWrites: false,
      at: 10.002
    )
    cancelled.begin(CommandPerformanceContext(generation: 2, inputTimestamp: 20))
    #expect(cancelled.performance.superseded == 1)

    var completed = CommandLatencyAccumulator()
    completed.begin(context)
    completed.recordFocusExpectation(context, expectsFocus: true)
    _ = completed.recordPlan(
      context,
      expectedWindowIDs: [],
      hasFrameWrites: false,
      at: 10.002
    )
    _ = completed.recordFocus(context, at: 10.010)
    completed.begin(CommandPerformanceContext(generation: 2, inputTimestamp: 20))
    #expect(completed.performance.superseded == 0)
    #expect(completed.performance.convergence.count == 1)
  }

  @Test
  func intermediatePositionAndSizeCommitIsQuarantined() {
    #expect(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 480, y: 60, width: 1_000, height: 760),
        currentTarget: expectation.target,
        expectation: expectation,
        now: 10.4,
        leftMouseButtonDown: false
      )
    )
  }

  @Test
  func geometryOutsideOwnCommitPathRemainsExternal() {
    #expect(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 480, y: 60, width: 1_280, height: 760),
        currentTarget: expectation.target,
        expectation: expectation,
        now: 10.4,
        leftMouseButtonDown: false
      ) == false
    )
  }

  @Test
  func mouseResizeBypassesCommitQuarantine() {
    #expect(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 480, y: 60, width: 1_000, height: 760),
        currentTarget: expectation.target,
        expectation: expectation,
        now: 10.4,
        leftMouseButtonDown: true
      ) == false
    )
  }

  @Test
  func targetWithoutFreshObservationRemainsPending() {
    #expect(frameTransitionIsPending(target: expectation.target, observed: nil))
    #expect(
      frameTransitionIsPending(
        target: expectation.target,
        observed: expectation.target
      ) == false
    )
  }

  @Test
  func borderRefreshSettleGateExpiresWithTheExpectationDeadline() {
    let windowID = WindowID(rawValue: 7)
    let liveWindowIDs: Set<WindowID> = [windowID]

    // Unresolved and inside the deadline: replanning waits.
    #expect(
      borderRefreshBlockedBySettling(
        liveWindowIDs: liveWindowIDs,
        expectations: [windowID: expectation],
        now: 10.5
      )
    )
    // Past the deadline the expectation is stale bookkeeping and must never
    // block border geometry updates.
    #expect(
      borderRefreshBlockedBySettling(
        liveWindowIDs: liveWindowIDs,
        expectations: [windowID: expectation],
        now: 10.8
      ) == false
    )
    // Observed expectations do not gate either.
    var observed = expectation
    observed.observedAt = 10.4
    #expect(
      borderRefreshBlockedBySettling(
        liveWindowIDs: liveWindowIDs,
        expectations: [windowID: observed],
        now: 10.5
      ) == false
    )
    // Windows without expectations never gate.
    #expect(
      borderRefreshBlockedBySettling(
        liveWindowIDs: [WindowID(rawValue: 9)],
        expectations: [windowID: expectation],
        now: 10.5
      ) == false
    )
  }

  @Test
  func minimumSizeDebtDoesNotBlockFocusReadiness() {
    let windowID = WindowID(rawValue: 1)
    let target = Rect(x: 100, y: 40, width: 800, height: 900)

    #expect(
      unresolvedPositionDebtWindowIDs(
        pendingWindowIDs: [],
        debtWindowIDs: [windowID],
        targetFrames: [windowID: target],
        observedFrames: [
          windowID: Rect(x: 100, y: 40, width: 1_000, height: 900)
        ]
      ).isEmpty
    )
    #expect(
      unresolvedPositionDebtWindowIDs(
        pendingWindowIDs: [],
        debtWindowIDs: [windowID],
        targetFrames: [windowID: target],
        observedFrames: [
          windowID: Rect(x: 101.5, y: 40, width: 1_000, height: 900)
        ]
      ) == [windowID]
    )
  }

  @Test
  func frameDebtPrunesConvergedAndRemovedWindows() {
    let converged = WindowID(rawValue: 1)
    let drifting = WindowID(rawValue: 2)
    let removed = WindowID(rawValue: 3)
    let target = Rect(x: 100, y: 40, width: 1_200, height: 900)

    #expect(
      prunedFrameDebtWindowIDs(
        debtWindowIDs: [converged, drifting, removed],
        liveWindowIDs: [converged, drifting],
        targetFrames: [converged: target, drifting: target],
        observedFrames: [
          converged: target,
          drifting: Rect(x: 900, y: 40, width: 1_200, height: 900),
        ]
      ) == [drifting]
    )
  }
}
