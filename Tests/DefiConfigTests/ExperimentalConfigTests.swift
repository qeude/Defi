import Foundation
import Testing

@testable import DefiConfig

struct ExperimentalConfigTests {
  @Test
  func skyLightPositionAnimationDefaultsOff() {
    #expect(Config().experimental.skyLightPositionAnimation == false)
  }

  @Test
  func decodesSkyLightPositionAnimationOptIn() throws {
    let config = try Config.decode(
      Data(
        """
        [experimental]
        skylight_position_animation = true
        """.utf8
      )
    )

    #expect(config.experimental.skyLightPositionAnimation)
  }
}
