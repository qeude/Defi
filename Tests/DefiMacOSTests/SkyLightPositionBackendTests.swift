import Testing

@testable import DefiMacOS

struct SkyLightPositionBackendTests {
  @Test
  func disabledExperimentUsesAccessibility() {
    #expect(
      selectPositionAnimationBackend(
        experimentalSkyLightEnabled: false,
        skyLightAvailable: true,
        animatedPositionFrame: true,
        containsParkedWrite: false,
        containsSizeChange: false,
        containsVerticalMove: false
      ) == .accessibility
    )
  }

  @Test
  func visibleHorizontalIntermediateUsesSkyLight() {
    #expect(
      selectPositionAnimationBackend(
        experimentalSkyLightEnabled: true,
        skyLightAvailable: true,
        animatedPositionFrame: true,
        containsParkedWrite: false,
        containsSizeChange: false,
        containsVerticalMove: false
      ) == .skyLight
    )
  }

  @Test(
    arguments: [
      (true, false, false),
      (false, true, false),
      (false, false, true),
    ]
  )
  func unsafeWritesUseAccessibility(
    containsParkedWrite: Bool,
    containsSizeChange: Bool,
    containsVerticalMove: Bool
  ) {
    #expect(
      selectPositionAnimationBackend(
        experimentalSkyLightEnabled: true,
        skyLightAvailable: true,
        animatedPositionFrame: true,
        containsParkedWrite: containsParkedWrite,
        containsSizeChange: containsSizeChange,
        containsVerticalMove: containsVerticalMove
      ) == .accessibility
    )
  }

  @Test
  func nonAnimatedCommitUsesAccessibility() {
    #expect(
      selectPositionAnimationBackend(
        experimentalSkyLightEnabled: true,
        skyLightAvailable: true,
        animatedPositionFrame: false,
        containsParkedWrite: false,
        containsSizeChange: false,
        containsVerticalMove: false
      ) == .accessibility
    )
  }
}
