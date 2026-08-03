import CoreGraphics
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

  @Test
  func borderCompanionsUseTargetPositionAndStableOffsets() {
    let moves = skyLightMovesIncludingCompanions(
      [
        SkyLightPositionMove(
          windowID: 10,
          point: CGPoint(x: 100, y: 200)
        )
      ],
      companions: [
        10: [
          SkyLightPositionCompanion(
            windowID: 90,
            offset: CGPoint(x: -3, y: -3)
          ),
          SkyLightPositionCompanion(
            windowID: 91,
            offset: CGPoint(x: 7, y: 11)
          ),
        ]
      ]
    )

    #expect(
      moves == [
        SkyLightPositionMove(
          windowID: 10,
          point: CGPoint(x: 100, y: 200)
        ),
        SkyLightPositionMove(
          windowID: 90,
          point: CGPoint(x: 97, y: 197)
        ),
        SkyLightPositionMove(
          windowID: 91,
          point: CGPoint(x: 107, y: 211)
        ),
      ]
    )
  }
}
