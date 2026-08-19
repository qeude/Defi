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
  func supersededFrameDebtStaysUntilTargetIsObserved() {
    let displaced = WindowID(rawValue: 1)
    let replacement = WindowID(rawValue: 2)
    let target = Rect(x: 100, y: 40, width: 1_200, height: 900)
    let observedElsewhere = Rect(x: 900, y: 40, width: 1_200, height: 900)

    let pending = unresolvedFrameDebtWindowIDs(
      pendingWindowIDs: [replacement],
      debtWindowIDs: [displaced],
      targetFrames: [displaced: target],
      observedFrames: [displaced: observedElsewhere]
    )
    #expect(pending == [displaced, replacement])

    let observed = unresolvedFrameDebtWindowIDs(
      pendingWindowIDs: [replacement],
      debtWindowIDs: [displaced],
      targetFrames: [displaced: target],
      observedFrames: [displaced: target]
    )
    #expect(observed == [replacement])
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
