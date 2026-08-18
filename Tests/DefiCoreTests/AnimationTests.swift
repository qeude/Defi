import DefiCore
import DefiModel
import XCTest

final class AnimationTests: XCTestCase {
  func testSpeculativeNavigationSettlementWaitsPastVisualAnimation() {
    XCTAssertEqual(
      speculativeNavigationSettlementDelay(animationDuration: 0.035),
      0.075,
      accuracy: 0.000_1
    )
    XCTAssertEqual(
      speculativeNavigationSettlementDelay(animationDuration: 0.1),
      0.12,
      accuracy: 0.000_1
    )
  }

  func testScrollAnimationUsesEaseOutCubicAndFinishesExactly() {
    XCTAssertEqual(animatedScalar(from: 0, to: 1, elapsed: 0, duration: 0.08), 0)
    XCTAssertEqual(
      animatedScalar(from: 0, to: 1, elapsed: 0.04, duration: 0.08),
      0.875,
      accuracy: 0.000_1
    )
    XCTAssertEqual(animatedScalar(from: 0, to: 1, elapsed: 0.08, duration: 0.08), 1)
  }

  func testCriticallyDampedSpringConvergesWithoutOvershoot() {
    var value = 0.0
    var velocity = 0.0
    for _ in 0..<90 {
      let step = criticallyDampedSpringStep(
        value: value,
        target: 500,
        velocity: velocity,
        deltaTime: 1 / 120,
        response: 0.18
      )
      XCTAssertGreaterThanOrEqual(step.value, value)
      XCTAssertLessThanOrEqual(step.value, 500)
      value = step.value
      velocity = step.velocity
    }
    XCTAssertEqual(value, 500, accuracy: 0.01)
    XCTAssertEqual(velocity, 0, accuracy: 0.5)
  }

  func testCompletedFrameSpringKeepsMultipleMonotonicSamples() {
    let at120Hz = completedFrameSpringProgresses(
      duration: 0.035,
      refreshRateHz: 120
    )
    let at60Hz = completedFrameSpringProgresses(
      duration: 0.035,
      refreshRateHz: 60
    )

    XCTAssertEqual(at120Hz.count, 4)
    XCTAssertEqual(at60Hz.count, 2)
    XCTAssertEqual(at120Hz.first ?? 0, 0.247, accuracy: 0.002)
    XCTAssertGreaterThan(at120Hz.last ?? 0, 0.85)
    XCTAssertLessThan(at120Hz.last ?? 1, 1)
    XCTAssertEqual(at120Hz, at120Hz.sorted())
  }

  func testCompletedFrameSpringUsesTheFullRefreshBudget() {
    let progresses = completedFrameSpringProgresses(
      duration: 0.08,
      refreshRateHz: 120
    )

    XCTAssertEqual(progresses.count, 9)
    XCTAssertGreaterThan(progresses.last ?? 0, 0.85)
  }

  func testRetargetedSpringKeepsForwardVelocityAndRemainsMonotonic() {
    let stationary = completedFrameSpringSamples(
      duration: 0.08,
      refreshRateHz: 120
    )
    let retargeted = completedFrameSpringSamples(
      duration: 0.08,
      refreshRateHz: 120,
      initialVelocity: 12
    )

    XCTAssertGreaterThan(
      retargeted.first?.progress ?? 0,
      stationary.first?.progress ?? 1
    )
    XCTAssertEqual(
      retargeted.map(\.progress),
      retargeted.map(\.progress).sorted()
    )
    XCTAssertLessThanOrEqual(retargeted.last?.progress ?? 2, 1)
    XCTAssertEqual(
      retainedSpringProgressVelocity(
        normalizedCandidates: [-4, 8, 12, .infinity],
        maximum: 10
      ),
      10
    )
    XCTAssertEqual(
      retainedSpringProgressVelocity(
        normalizedCandidates: [-4, -.infinity],
        maximum: 10
      ),
      0
    )
  }

  func testDisplayLinkedSpringSamplingUsesElapsedTimeAndNeverRollsBack() {
    let first = springProgressSample(
      elapsed: 1.0 / 120,
      duration: 0.08
    )
    let delayed = springProgressSample(
      elapsed: 0.027,
      duration: 0.08,
      minimumProgress: first.progress
    )
    let staleTimestamp = springProgressSample(
      elapsed: 0.020,
      duration: 0.08,
      minimumProgress: delayed.progress
    )

    XCTAssertGreaterThan(first.progress, 0)
    XCTAssertGreaterThan(delayed.progress, first.progress)
    XCTAssertEqual(staleTimestamp.progress, delayed.progress)
    XCTAssertEqual(staleTimestamp.velocity, 0)
    XCTAssertLessThanOrEqual(staleTimestamp.progress, 1)
  }

  func testAdaptiveFrameLimitAvoidsMultiplyingSlowAXCalls() {
    XCTAssertEqual(
      adaptiveIntermediateFrameLimit(
        predictedFrameLatency: 0.004,
        refreshRateHz: 120,
        availableIntermediateFrames: 4
      ),
      4
    )
    XCTAssertEqual(
      adaptiveIntermediateFrameLimit(
        predictedFrameLatency: 0.012,
        refreshRateHz: 120,
        availableIntermediateFrames: 4
      ),
      1
    )
    XCTAssertEqual(
      adaptiveIntermediateFrameLimit(
        predictedFrameLatency: 0.030,
        refreshRateHz: 120,
        availableIntermediateFrames: 4
      ),
      0
    )
  }

  func testSpringProgressAnticipatesAXCompletionLatency() {
    XCTAssertEqual(
      anticipatedSpringProgressIndex(
        predictedFrameLatency: 0.002,
        refreshRateHz: 120,
        availableIntermediateFrames: 4
      ),
      0
    )
    XCTAssertEqual(
      anticipatedSpringProgressIndex(
        predictedFrameLatency: 0.018,
        refreshRateHz: 120,
        availableIntermediateFrames: 4
      ),
      2
    )
    XCTAssertEqual(
      anticipatedSpringProgressIndex(
        predictedFrameLatency: 0.030,
        refreshRateHz: 120,
        availableIntermediateFrames: 4
      ),
      3
    )
    XCTAssertEqual(
      anticipatedSpringProgressIndex(
        predictedFrameLatency: 0.051,
        refreshRateHz: 120,
        availableIntermediateFrames: 4,
        maximumIndex: 1
      ),
      1
    )
  }

  func testCompletedAXFrameSchedulesNextWriteAfterDisplayInterval() {
    XCTAssertEqual(
      nextCompletedFrameDispatchDeadline(
        completedAt: 10,
        refreshRateHz: 120
      ),
      10 + 1.0 / 120,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      nextCompletedFrameDispatchDeadline(
        completedAt: 10,
        refreshRateHz: 60
      ),
      10 + 1.0 / 60,
      accuracy: 0.000_001
    )
  }

  func testSlowCompletedFrameSkipsIntermediateThatCannotFitBudget() {
    XCTAssertTrue(
      shouldEmitAnotherIntermediateFrame(
        elapsed: 0.029,
        predictedFrameLatency: 0.024,
        budget: 0.06,
        completedIntermediateFrames: 1
      )
    )
    XCTAssertFalse(
      shouldEmitAnotherIntermediateFrame(
        elapsed: 0.029,
        predictedFrameLatency: 0.032,
        budget: 0.06,
        completedIntermediateFrames: 1
      )
    )
    XCTAssertTrue(
      shouldEmitAnotherIntermediateFrame(
        elapsed: 0.059,
        predictedFrameLatency: 0.5,
        budget: 0.06,
        completedIntermediateFrames: 0
      )
    )
  }

  func testSlowCompletedSampleStopsFurtherAXFrames() {
    XCTAssertTrue(
      completedFrameSupportsAnotherSample(
        duration: 0.006,
        refreshRateHz: 120
      )
    )
    XCTAssertFalse(
      completedFrameSupportsAnotherSample(
        duration: 0.020,
        refreshRateHz: 120
      )
    )
  }

  func testFinalAXFrameIsDispatchedEarlyEnoughToFinishOnAnimationDeadline() {
    XCTAssertEqual(
      anticipatedFinalFrameDispatchDelay(
        animationDuration: 0.035,
        predictedFrameLatency: 0.012
      ),
      0.023,
      accuracy: 0.000_1
    )
    XCTAssertEqual(
      anticipatedFinalFrameDispatchDelay(
        animationDuration: 0.035,
        predictedFrameLatency: 0.050
      ),
      0
    )
  }

  func testSlowIntermediateFrameDoesNotLeaveAnimationFrozenUntilDeadline() {
    XCTAssertEqual(
      finalFrameDispatchDeadline(
        nominalDeadline: 10.08,
        nextDisplayDeadline: 10.025,
        previousFrameWasSlow: true
      ),
      10.08
    )
    XCTAssertEqual(
      finalFrameDispatchDeadline(
        nominalDeadline: 10.08,
        nextDisplayDeadline: 10.025,
        previousFrameWasSlow: false
      ),
      10.08
    )
    XCTAssertEqual(
      finalFrameDispatchDeadline(
        nominalDeadline: 10.075,
        nextDisplayDeadline: 10.12,
        previousFrameWasSlow: false,
        hardDeadline: 10.08
      ),
      10.08
    )
  }

  func testDisplayedFrameRebaseUsesMedianAndRejectsOutliers() {
    XCTAssertEqual(
      rebaseScalarToDisplayedFrames(
        logicalValue: 500,
        expectedMinusDisplayedDeltas: [-82, -80, 4_000],
        maximumAbsoluteDelta: 1_000
      ),
      DisplayedScalarRebase(value: 420, delta: -80)
    )
    XCTAssertNil(
      rebaseScalarToDisplayedFrames(
        logicalValue: 500,
        expectedMinusDisplayedDeltas: [0.1, 4_000],
        maximumAbsoluteDelta: 1_000
      )
    )
  }
}
