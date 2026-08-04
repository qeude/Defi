import DefiConfig
import DefiModel
import Foundation
import XCTest

final class ConfigTests: XCTestCase {
  func testEmptyConfigUsesDefaults() throws {
    let config = try Config.decode(Data())

    XCTAssertEqual(config.workspaces.names, (1...9).map(String.init))
    XCTAssertEqual(config.layout.defaultColumnWidth, 0.8)
    XCTAssertTrue(config.animation.enabled)
    XCTAssertEqual(config.animation.durationMS, 35)
    XCTAssertTrue(config.decorations.borders.enabled)
    XCTAssertEqual(config.decorations.borders.width, 4)
    XCTAssertEqual(config.decorations.borders.color, "#FFC099FF")
    XCTAssertFalse(config.decorations.borders.inactiveEnabled)
    XCTAssertEqual(config.decorations.borders.inactiveColor, "#66C099FF")
    XCTAssertFalse(config.decorations.borders.captureEnabled)
    XCTAssertEqual(config.keys["alt-left"], "focus-column left")
    XCTAssertEqual(config.keys["alt-backslash"], "toggle-floating")
    XCTAssertEqual(config.keys["alt-shift-backslash"], "activate-floating")
    XCTAssertEqual(config.keys["alt-period"], "focus-floating next")
    XCTAssertEqual(config.keys["alt-shift-1"], "move-window-to-workspace 1")
  }

  func testDecodesBorderConfiguration() throws {
    let config = try Config.decode(
      Data(
        """
        [decorations.borders]
        enabled = true
        width = 3.5
        color = "#ff33aaff"
        inactive_enabled = true
        inactive_color = "0x4433aaff"
        capture_enabled = true
        """.utf8
      )
    )

    XCTAssertEqual(config.decorations.borders.width, 3.5)
    XCTAssertEqual(config.decorations.borders.color, "#ff33aaff")
    XCTAssertTrue(config.decorations.borders.inactiveEnabled)
    XCTAssertEqual(config.decorations.borders.inactiveColor, "0x4433aaff")
    XCTAssertTrue(config.decorations.borders.captureEnabled)
  }

  func testRejectsInvalidBorderConfiguration() {
    XCTAssertThrowsError(
      try Config.decode(
        Data(
          """
          [decorations.borders]
          width = 65
          """.utf8
        )
      )
    )
    XCTAssertThrowsError(
      try Config.decode(
        Data(
          """
          [decorations.borders]
          color = "ffffff"
          """.utf8
        )
      )
    )
  }

  func testParsesBorderColors() {
    XCTAssertEqual(parseBorderColor("0xffffffff"), 0xffff_ffff)
    XCTAssertEqual(parseBorderColor("#8033aaff"), 0x8033_aaff)
    XCTAssertNil(parseBorderColor("#fff"))
    XCTAssertNil(parseBorderColor("8033aaff"))
  }

  func testDecodesExampleShapeAndGeneratesNamedWorkspaceKeys() throws {
    let data = Data(
      """
      default_key_modifier = "hyper"

      [layout]
      gaps = 4

      [animation]
      enabled = true
      duration_ms = 120

      [workspaces]
      names = ["dev", "web"]

      [modifier_combinations]
      hyper = "Alt + Cmd + Ctrl"

      [[rules]]
      app_id = "com.apple.dt.Xcode"
      workspace = "dev"
      follow_focus = true
      """.utf8
    )

    let config = try Config.decode(data)

    XCTAssertEqual(config.layout.gaps, 4)
    XCTAssertEqual(config.animation.durationMS, 120)
    XCTAssertEqual(config.workspaces.defaultName, "dev")
    XCTAssertEqual(config.keys["hyper-1"], "workspace dev")
    XCTAssertEqual(config.keys["hyper-minus"], "cycle-width previous")
    XCTAssertEqual(config.keys["hyper-equal"], "cycle-width next")
    XCTAssertEqual(config.keys["hyper-f"], "toggle-fullscreen")
    XCTAssertEqual(config.keys["hyper-backslash"], "toggle-floating")
    XCTAssertEqual(config.keys["hyper-shift-backslash"], "activate-floating")
    XCTAssertEqual(config.keys["hyper-comma"], "focus-floating previous")
    XCTAssertEqual(config.keys["hyper-period"], "focus-floating next")
    XCTAssertEqual(config.modifierCombinations["hyper"], "Alt + Cmd + Ctrl")
    XCTAssertEqual(config.rules.count, 1)
  }

  func testRuleDecisionCombinesMatches() {
    let config = Config(
      workspaces: WorkspacesConfig(names: ["dev", "web"]),
      rules: [
        Rule(appID: "com.apple.dt.Xcode", workspace: "dev", followFocus: true),
        Rule(title: "Preview", intrinsicSize: true),
      ]
    )
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "com.apple.dt.Xcode",
      title: "Preview",
      frame: Rect(x: 0, y: 0, width: 500, height: 600)
    )

    let decision = config.decision(for: window)

    XCTAssertEqual(decision.workspace, WorkspaceID(rawValue: "dev"))
    XCTAssertTrue(decision.followFocus)
    XCTAssertTrue(decision.intrinsicSize)
  }

  func testRejectsUnknownRuleWorkspace() {
    let data = Data(
      """
      [workspaces]
      names = ["dev"]

      [[rules]]
      app_id = "app"
      workspace = "missing"
      """.utf8
    )

    XCTAssertThrowsError(try Config.decode(data))
  }

  func testRepositoryExampleDecodes() throws {
    let repository = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let config = try Config.load(from: repository.appending(path: "defi.example.toml"))

    XCTAssertEqual(config.workspaces.names.first, "dev")
    XCTAssertEqual(config.keys["hyper-left"], "focus-column left")
    XCTAssertEqual(config.rules.count, 9)
  }
}
