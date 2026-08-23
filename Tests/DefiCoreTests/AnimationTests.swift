import DefiCore
import DefiModel
import Testing
import XCTest

struct AnimationTests {
  @Test
  func `Speculative navigation settlement waits past visual animation`() {
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

  @Test
  func `Scroll animation uses ease out cubic and finishes exactly`() {
    #expect(animatedScalar(from: 0, to: 1, elapsed: 0, duration: 0.08) == 0)
    XCTAssertEqual(
      animatedScalar(from: 0, to: 1, elapsed: 0.04, duration: 0.08),
      0.875,
      accuracy: 0.000_1
    )
    #expect(animatedScalar(from: 0, to: 1, elapsed: 0.08, duration: 0.08) == 1)
  }

  @Test
  func `Critically damped spring converges without overshoot`() {
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
      #expect(step.value >= value)
      #expect(step.value <= 500)
      value = step.value
      velocity = step.velocity
    }
    XCTAssertEqual(value, 500, accuracy: 0.01)
    XCTAssertEqual(velocity, 0, accuracy: 0.5)
  }

  @Test
  func `Completed frame spring keeps multiple monotonic samples`() {
    let at120Hz = completedFrameSpringProgresses(
      duration: 0.035,
      refreshRateHz: 120
    )
    let at60Hz = completedFrameSpringProgresses(
      duration: 0.035,
      refreshRateHz: 60
    )

    #expect(at120Hz.count == 4)
    #expect(at60Hz.count == 2)
    XCTAssertEqual(at120Hz.first ?? 0, 0.247, accuracy: 0.002)
    #expect(at120Hz.last ?? 0 > 0.85)
    #expect(at120Hz.last ?? 1 < 1)
    #expect(at120Hz == at120Hz.sorted())
  }

  @Test
  func `Completed frame spring uses the full refresh budget`() {
    let progresses = completedFrameSpringProgresses(
      duration: 0.08,
      refreshRateHz: 120
    )

    #expect(progresses.count == 9)
    #expect(progresses.last ?? 0 > 0.85)
  }

  @Test
  func `Retargeted spring keeps forward velocity and remains monotonic`() {
    let stationary = completedFrameSpringSamples(
      duration: 0.08,
      refreshRateHz: 120
    )
    let retargeted = completedFrameSpringSamples(
      duration: 0.08,
      refreshRateHz: 120,
      initialVelocity: 12
    )

    #expect(retargeted.first?.progress ?? 0 > stationary.first?.progress ?? 1)
    #expect(retargeted.map(\.progress) == retargeted.map(\.progress).sorted())
    #expect(retargeted.last?.progress ?? 2 <= 1)
    #expect(
      retainedSpringProgressVelocity(
        normalizedCandidates: [-4, 8, 12, .infinity],
        maximum: 10
      ) == 10)
    #expect(
      retainedSpringProgressVelocity(
        normalizedCandidates: [-4, -.infinity],
        maximum: 10
      ) == 0)
  }

  @Test
  func `Display linked spring sampling uses elapsed time and never rolls back`() {
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

    #expect(first.progress > 0)
    #expect(delayed.progress > first.progress)
    #expect(staleTimestamp.progress == delayed.progress)
    #expect(staleTimestamp.velocity == 0)
    #expect(staleTimestamp.progress <= 1)
  }

  @Test
  func `Adaptive frame limit avoids multiplying slow AX calls`() {
    #expect(
      adaptiveIntermediateFrameLimit(
        predictedFrameLatency: 0.004,
        refreshRateHz: 120,
        availableIntermediateFrames: 4
      ) == 4)
    #expect(
      adaptiveIntermediateFrameLimit(
        predictedFrameLatency: 0.012,
        refreshRateHz: 120,
        availableIntermediateFrames: 4
      ) == 1)
    #expect(
      adaptiveIntermediateFrameLimit(
        predictedFrameLatency: 0.030,
        refreshRateHz: 120,
        availableIntermediateFrames: 4
      ) == 0)
  }

  @Test
  func `Spring progress anticipates AX completion latency`() {
    #expect(
      anticipatedSpringProgressIndex(
        predictedFrameLatency: 0.002,
        refreshRateHz: 120,
        availableIntermediateFrames: 4
      ) == 0)
    #expect(
      anticipatedSpringProgressIndex(
        predictedFrameLatency: 0.018,
        refreshRateHz: 120,
        availableIntermediateFrames: 4
      ) == 2)
    #expect(
      anticipatedSpringProgressIndex(
        predictedFrameLatency: 0.030,
        refreshRateHz: 120,
        availableIntermediateFrames: 4
      ) == 3)
    #expect(
      anticipatedSpringProgressIndex(
        predictedFrameLatency: 0.051,
        refreshRateHz: 120,
        availableIntermediateFrames: 4,
        maximumIndex: 1
      ) == 1)
  }

  @Test
  func `Completed AX frame schedules next write after display interval`() {
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

  @Test
  func `Slow completed frame skips intermediate that cannot fit budget`() {
    #expect(
      shouldEmitAnotherIntermediateFrame(
        elapsed: 0.029,
        predictedFrameLatency: 0.024,
        budget: 0.06,
        completedIntermediateFrames: 1
      ))
    #expect(
      shouldEmitAnotherIntermediateFrame(
        elapsed: 0.029,
        predictedFrameLatency: 0.032,
        budget: 0.06,
        completedIntermediateFrames: 1
      ) == false)
    #expect(
      shouldEmitAnotherIntermediateFrame(
        elapsed: 0.059,
        predictedFrameLatency: 0.5,
        budget: 0.06,
        completedIntermediateFrames: 0
      ))
  }

  @Test
  func `Slow completed sample stops further AX frames`() {
    #expect(
      completedFrameSupportsAnotherSample(
        duration: 0.006,
        refreshRateHz: 120
      ))
    #expect(
      completedFrameSupportsAnotherSample(
        duration: 0.020,
        refreshRateHz: 120
      ) == false)
  }

  @Test
  func `Final AX frame is dispatched early enough to finish on animation deadline`() {
    XCTAssertEqual(
      anticipatedFinalFrameDispatchDelay(
        animationDuration: 0.035,
        predictedFrameLatency: 0.012
      ),
      0.023,
      accuracy: 0.000_1
    )
    #expect(
      anticipatedFinalFrameDispatchDelay(
        animationDuration: 0.035,
        predictedFrameLatency: 0.050
      ) == 0)
  }

  @Test
  func `Slow intermediate frame does not leave animation frozen until deadline`() {
    #expect(
      finalFrameDispatchDeadline(
        nominalDeadline: 10.08,
        nextDisplayDeadline: 10.025,
        previousFrameWasSlow: true
      ) == 10.08)
    #expect(
      finalFrameDispatchDeadline(
        nominalDeadline: 10.08,
        nextDisplayDeadline: 10.025,
        previousFrameWasSlow: false
      ) == 10.08)
    #expect(
      finalFrameDispatchDeadline(
        nominalDeadline: 10.075,
        nextDisplayDeadline: 10.12,
        previousFrameWasSlow: false,
        hardDeadline: 10.08
      ) == 10.08)
  }

  @Test
  func `Displayed frame rebase uses median and rejects outliers`() {
    #expect(
      rebaseScalarToDisplayedFrames(
        logicalValue: 500,
        expectedMinusDisplayedDeltas: [-82, -80, 4_000],
        maximumAbsoluteDelta: 1_000
      ) == DisplayedScalarRebase(value: 420, delta: -80))
    #expect(
      rebaseScalarToDisplayedFrames(
        logicalValue: 500,
        expectedMinusDisplayedDeltas: [0.1, 4_000],
        maximumAbsoluteDelta: 1_000
      ) == nil)
  }
}
