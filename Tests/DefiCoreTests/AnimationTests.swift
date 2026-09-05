import DefiCore
import DefiModel
import Testing

struct AnimationTests {
  @Test(arguments: [60.0, 120.0])
  func delayedClockPreservesEveryMotionStep(refreshRate: Double) throws {
    let interval = 1 / refreshRate
    var clock = FrameAnimationClock(startedAt: 10, interval: interval, sampleCount: 8)
    for index in 0..<8 {
      // A scheduler stall must not fast-forward the animation or its final write.
      let now = 10 + Double(index + 1) * interval + (index >= 1 ? 0.1 : 0)
      let next = clock.next(at: now)
      let tick = try #require(next)
      #expect(tick.index == index)
      #expect(abs((tick.elapsed) - (Double(index + 1) * interval)) <= 0.000_001)
      #expect(abs((tick.lateness) - (index >= 1 ? 0.1 : 0)) <= 0.000_001)
    }
    let exhausted = clock.next(at: 11)
    #expect(exhausted == nil)
  }

  @Test
  func `Scroll animation uses ease out cubic and finishes exactly`() {
    #expect(animatedScalar(from: 0, to: 1, elapsed: 0, duration: 0.08) == 0)
    #expect(abs((animatedScalar(from: 0, to: 1, elapsed: 0.04, duration: 0.08)) - (0.875)) <= 0.000_1)
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
    #expect(abs((value) - (500)) <= 0.01)
    #expect(abs((velocity) - (0)) <= 0.5)
  }

  @Test
  func `Completed frame spring keeps multiple monotonic samples`() {
    let at120Hz = completedFrameSpringSamples(
      duration: 0.035,
      refreshRateHz: 120
    ).map(\.progress)
    let at60Hz = completedFrameSpringSamples(
      duration: 0.035,
      refreshRateHz: 60
    ).map(\.progress)

    #expect(at120Hz.count == 4)
    #expect(at60Hz.count == 2)
    #expect(abs(((at120Hz.first ?? 0)) - (0.247)) <= 0.002)
    #expect(at120Hz.last ?? 0 > 0.85)
    #expect(at120Hz.last ?? 1 < 1)
    #expect(at120Hz == at120Hz.sorted())
  }

  @Test
  func `Completed frame spring uses the full refresh budget`() {
    let progresses = completedFrameSpringSamples(
      duration: 0.08,
      refreshRateHz: 120
    ).map(\.progress)

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
    #expect(
      adaptiveIntermediateFrameLimit(
        predictedFrameLatency: 0.030,
        refreshRateHz: 120,
        availableIntermediateFrames: 22
      ) == 5)
  }

  @Test
  func `Final AX frame is dispatched early enough to finish on animation deadline`() {
    #expect(abs((anticipatedFinalFrameDispatchDelay(
        animationDuration: 0.035,
        predictedFrameLatency: 0.012
      )) - (0.023)) <= 0.000_1)
    #expect(
      anticipatedFinalFrameDispatchDelay(
        animationDuration: 0.035,
        predictedFrameLatency: 0.050
      ) == 0)
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
