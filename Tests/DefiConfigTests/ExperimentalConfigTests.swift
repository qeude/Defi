import Foundation
import Testing

@testable import DefiConfig

struct ExperimentalConfigTests {
  @Test
  func skyLightPositionAnimationDefaultsOff() {
    #expect(Config().experimental.skyLightPositionAnimation == false)
    #expect(Config().experimental.skyLightBorderTracking == false)
  }

  @Test
  func decodesSkyLightPositionAnimationOptIn() throws {
    let config = try Config.decode(
      Data(
        """
        [experimental]
        skylight_position_animation = true
        skylight_border_tracking = true
        """.utf8
      )
    )

    #expect(config.experimental.skyLightPositionAnimation)
    #expect(config.experimental.skyLightBorderTracking)
  }
}
