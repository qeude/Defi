import DefiConfig
import Foundation
import Testing

struct InputConfigTests {
  @Test
  func inputFeaturesDefaultOff() throws {
    let config = try Config.decode(Data())

    #expect(config.input.focusFollowsMouse == false)
    #expect(config.input.mouseFollowsFocus == false)
  }

  @Test
  func inputFeaturesDecodeIndependently() throws {
    let config = try Config.decode(
      Data(
        """
        [input]
        focus_follows_mouse = true
        mouse_follows_focus = true
        """.utf8
      )
    )

    #expect(config.input.focusFollowsMouse)
    #expect(config.input.mouseFollowsFocus)
  }
}
