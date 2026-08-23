import DefiConfig
import DefiModel
import Foundation
import Testing

struct ConfigTests {
  @Test
  func `Empty config uses defaults`() throws {
    let config = try Config.decode(Data())

    #expect(config.workspaces.names == (1...9).map(String.init))
    #expect(config.layout.defaultColumnWidth == 0.8)
    #expect(config.animation.enabled)
    #expect(config.animation.durationMS == 35)
    #expect(config.decorations.borders.enabled)
    #expect(config.decorations.borders.width == 4)
    #expect(config.decorations.borders.color == "#FFC099FF")
    #expect(config.decorations.borders.inactiveEnabled == false)
    #expect(config.decorations.borders.inactiveColor == "#66C099FF")
    #expect(config.decorations.borders.captureEnabled == false)
    #expect(config.keys["alt-left"] == "focus-column left")
    #expect(config.keys["alt-backslash"] == "toggle-floating")
    #expect(config.keys["alt-shift-backslash"] == "activate-floating")
    #expect(config.keys["alt-period"] == "focus-floating next")
    #expect(config.keys["alt-shift-1"] == "move-window-to-workspace 1")
    #expect(config.keys["alt-shift-h"] == "move-column-to-monitor left")
    #expect(config.keys["alt-shift-j"] == "move-column-to-monitor down")
    #expect(config.keys["alt-shift-k"] == "move-column-to-monitor up")
    #expect(config.keys["alt-shift-l"] == "move-column-to-monitor right")
  }

  @Test
  func `Decodes border configuration`() throws {
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

    #expect(config.decorations.borders.width == 3.5)
    #expect(config.decorations.borders.color == "#ff33aaff")
    #expect(config.decorations.borders.inactiveEnabled)
    #expect(config.decorations.borders.inactiveColor == "0x4433aaff")
    #expect(config.decorations.borders.captureEnabled)
  }

  @Test(arguments: [
    (
      "width = 65",
      ConfigError.invalidValue("decorations.borders.width")
    ),
    (
      "color = \"ffffff\"",
      ConfigError.invalidValue("decorations.borders.color")
    ),
  ])
  func `Rejects invalid border configuration`(
    testCase: (setting: String, expectedError: ConfigError)
  ) {
    let data = Data(
      """
      [decorations.borders]
      \(testCase.setting)
      """.utf8
    )

    #expect(throws: testCase.expectedError) {
      try Config.decode(data)
    }
  }

  @Test(arguments: [
    ("0xffffffff", UInt32(0xffff_ffff)),
    ("#8033aaff", UInt32(0x8033_aaff)),
    ("#fff", nil),
    ("8033aaff", nil),
  ])
  func `Parses border colors`(
    testCase: (value: String, expected: UInt32?)
  ) {
    #expect(parseBorderColor(testCase.value) == testCase.expected)
  }

  @Test
  func `Decodes example shape and generates named workspace keys`() throws {
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

    #expect(config.layout.gaps == 4)
    #expect(config.animation.durationMS == 120)
    #expect(config.workspaces.defaultName == "dev")
    #expect(config.keys["hyper-1"] == "workspace dev")
    #expect(config.keys["hyper-minus"] == "cycle-width previous")
    #expect(config.keys["hyper-equal"] == "cycle-width next")
    #expect(config.keys["hyper-f"] == "maximize-column")
    #expect(config.keys["hyper-backslash"] == "toggle-floating")
    #expect(config.keys["hyper-shift-backslash"] == "activate-floating")
    #expect(config.keys["hyper-comma"] == "focus-floating previous")
    #expect(config.keys["hyper-period"] == "focus-floating next")
    #expect(config.modifierCombinations["hyper"] == "Alt + Cmd + Ctrl")
    #expect(config.rules.count == 1)
  }

  @Test
  func `Accepts diagnostic marker binding`() throws {
    let config = try Config.decode(
      Data(
        """
        [keys]
        "hyper-d" = "diagnostic-mark"

        [modifier_combinations]
        hyper = "Alt + Cmd + Ctrl"
        """.utf8
      )
    )

    #expect(config.keys["hyper-d"] == "diagnostic-mark")
  }

  @Test
  func `Rule decision combines matches`() {
    let config = Config(
      workspaces: WorkspacesConfig(names: ["dev", "web"]),
      rules: [
        Rule(
          appID: "com.apple.dt.Xcode",
          workspace: "dev",
          followFocus: true,
          floating: true
        ),
        Rule(title: "Preview", forceTiling: true, intrinsicSize: true),
      ]
    )
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "com.apple.dt.Xcode",
      title: "Preview",
      frame: Rect(x: 0, y: 0, width: 500, height: 600)
    )

    let decision = config.decision(for: window)

    #expect(
      decision == config.decision(appID: window.appID, title: window.title, role: window.role))
    #expect(decision.workspace == WorkspaceID(rawValue: "dev"))
    #expect(decision.followFocus)
    #expect(decision.floating)
    #expect(decision.forceTiling)
    #expect(decision.intrinsicSize)
  }

  @Test
  func `Rejects unknown rule workspace`() {
    let data = Data(
      """
      [workspaces]
      names = ["dev"]

      [[rules]]
      app_id = "app"
      workspace = "missing"
      """.utf8
    )

    #expect(throws: ConfigError.unknownWorkspace("missing")) {
      try Config.decode(data)
    }
  }

  @Test
  func `Repository example decodes`() throws {
    let repository = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let config = try Config.load(from: repository.appending(path: "defi.example.toml"))

    #expect(config.workspaces.names.first == "dev")
    #expect(config.keys["hyper-left"] == "focus-column left")
    #expect(config.rules.count == 9)
  }
}
