import DefiConfig
import Foundation
import Testing

struct SketchyBarConfigTests {
  @Test
  func decodesReservedEdgesAndNativeMenuBarSetting() throws {
    let config = try Config.decode(
      Data(
        """
        [layout]
        reserved_top = 11
        reserved_bottom = 4

        [menu_bar]
        enabled = false
        """.utf8
      )
    )

    #expect(config.layout.reservedTop == 11)
    #expect(config.layout.reservedBottom == 4)
    #expect(config.menuBar.enabled == false)
  }

  @Test(arguments: [-1.0, 513.0])
  func rejectsInvalidReservedEdges(value: Double) {
    #expect(throws: ConfigError.invalidValue("layout.reserved_top")) {
      try Config.decode(
        Data(
          """
          [layout]
          reserved_top = \(value)
          """.utf8
        )
      )
    }
  }
}
