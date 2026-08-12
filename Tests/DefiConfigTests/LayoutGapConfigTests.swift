import DefiConfig
import Foundation
import Testing

struct LayoutGapConfigTests {
  @Test
  func decodesOuterGapOverrides() throws {
    let config = try Config.decode(
      Data(
        """
        [layout]
        gaps = 8
        outer_top_gap = 1
        outer_right_gap = 2
        outer_bottom_gap = 0
        outer_left_gap = 3
        """.utf8
      )
    )

    #expect(config.layout.gaps == 8)
    #expect(config.layout.outerTopGap == 1)
    #expect(config.layout.outerRightGap == 2)
    #expect(config.layout.outerBottomGap == 0)
    #expect(config.layout.outerLeftGap == 3)
  }

  @Test
  func leavesOuterGapOverridesUnsetByDefault() throws {
    let config = try Config.decode(Data())

    #expect(config.layout.outerTopGap == nil)
    #expect(config.layout.outerRightGap == nil)
    #expect(config.layout.outerBottomGap == nil)
    #expect(config.layout.outerLeftGap == nil)
  }

  @Test(
    arguments: [
      "outer_top_gap",
      "outer_right_gap",
      "outer_bottom_gap",
      "outer_left_gap",
    ]
  )
  func rejectsInvalidOuterGap(key: String) {
    #expect(throws: ConfigError.invalidValue("layout.\(key)")) {
      try Config.decode(
        Data(
          """
          [layout]
          \(key) = 257
          """.utf8
        )
      )
    }
  }
}
