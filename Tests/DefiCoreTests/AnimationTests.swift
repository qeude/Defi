import DefiCore
import DefiModel
import Testing

struct AnimationTests {
  @Test
  func `Scroll animation uses ease out cubic and finishes exactly`() {
    #expect(animatedScalar(from: 0, to: 1, elapsed: 0, duration: 0.08) == 0)
    #expect(abs((animatedScalar(from: 0, to: 1, elapsed: 0.04, duration: 0.08)) - (0.875)) <= 0.000_1)
    #expect(animatedScalar(from: 0, to: 1, elapsed: 0.08, duration: 0.08) == 1)
  }

  @Test
  func displayedScrollRebaseConvertsPointsToViewportUnits() {
    #expect(rebaseScalarToDisplayedFrames(
      logicalValue: 0.5, expectedMinusDisplayedDeltas: [200, 202, 4000],
      maximumAbsoluteDelta: 2000, logicalScale: 2000
    ) == DisplayedScalarRebase(value: 0.601, delta: 202))
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
