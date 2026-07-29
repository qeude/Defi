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
    XCTAssertEqual(config.keys["alt-left"], "focus-column left")
    XCTAssertEqual(config.keys["alt-shift-1"], "move-window-to-workspace 1")
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
