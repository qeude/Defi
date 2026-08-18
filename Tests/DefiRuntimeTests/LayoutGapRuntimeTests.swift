import DefiConfig
import DefiRuntime
import Testing

struct LayoutGapRuntimeTests {
  @Test
  func mapsOuterOverridesAndFallsBackToUniformGap() {
    let config = Config(
      layout: LayoutConfig(
        gaps: 8,
        outerTopGap: 1,
        outerBottomGap: 0
      )
    )

    let state = RuntimeState(config: config)

    #expect(state.layout.innerHorizontalGap == 4)
    #expect(state.layout.innerVerticalGap == 4)
    #expect(state.layout.outerTopGap == 1)
    #expect(state.layout.outerRightGap == 8)
    #expect(state.layout.outerBottomGap == 0)
    #expect(state.layout.outerLeftGap == 8)
  }
}
