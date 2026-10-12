import DefiConfig
import Foundation
import Testing

struct InputConfigTests {
  @Test
  func inputFeaturesDefaultOff() throws {
    let config = try Config.decode(Data())

    #expect(config.input.focusFollowsMouse == false)
    #expect(config.input.focusFollowsMouseMaxScrollAmount == 0)
    #expect(config.input.mouseFollowsFocus == false)
  }

  @Test
  func inputFeaturesDecodeIndependently() throws {
    let config = try Config.decode(
      Data(
        """
        [input]
        focus_follows_mouse = true
        focus_follows_mouse_max_scroll_amount = 0.1
        mouse_follows_focus = true
        """.utf8
      )
    )

    #expect(config.input.focusFollowsMouse)
    #expect(config.input.focusFollowsMouseMaxScrollAmount == 0.1)
    #expect(config.input.mouseFollowsFocus)
  }

  @Test
  func focusFollowsMouseDelayDecodesAndRejectsOutOfRange() throws {
    let config = try Config.decode(
      Data("[input]\nfocus_follows_mouse_delay_ms = 50\n".utf8)
    )
    #expect(config.input.focusFollowsMouseDelayMS == 50)
    #expect(throws: ConfigError.invalidValue("input.focus_follows_mouse_delay_ms")) {
      try Config.decode(Data("[input]\nfocus_follows_mouse_delay_ms = -1\n".utf8))
    }
  }

  @Test(arguments: [-0.1, 1.1])
  func focusFollowsMouseScrollLimitRejectsOutOfRangeValues(
    value: Double
  ) {
    #expect(
      throws: ConfigError.invalidValue(
        "input.focus_follows_mouse_max_scroll_amount"
      )
    ) {
      try Config.decode(
        Data(
          """
          [input]
          focus_follows_mouse_max_scroll_amount = \(value)
          """.utf8
        )
      )
    }
  }
}
