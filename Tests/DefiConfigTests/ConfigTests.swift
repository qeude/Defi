import DefiConfig
import DefiModel
import Foundation
import Testing

struct ConfigTests {
  @Test(arguments: ["a", "alt-fn", "typo-left", "-left", "alt--left", "alt-left-", ""])
  func malformedAcceleratorsAreRejectedWithoutReplacingDefaults(accelerator: String) throws {
    let config = Config(keys: [accelerator: "diagnostic-mark"])
    #expect(config.keys["alt-left"] == "focus-column left")
    #expect(throws: ConfigError.invalidValue("keys.\(accelerator)")) {
      try config.validate()
    }
  }

  @Test(arguments: ["ctrl-alt", "ctrl-alt-shift", "ctrl-cmd", "ctrl-cmd-shift"])
  func collidingMonitorKeysPreserveConfiguredNavigation(modifier: String) throws {
    let config = try Config.decode(Data("default_key_modifier = \"\(modifier)\"".utf8))
    #expect(config.keys["\(modifier)-left"] == "focus-column left")
    #expect(config.keys["\(modifier)-shift-left"] == (modifier.contains("shift") ? nil : "move-column left"))
    let overridden = Config(defaultKeyModifier: modifier, keys: ["\(modifier)-left": "focus-monitor left"])
    #expect(overridden.keys["\(modifier)-left"] == "focus-monitor left")
  }

  @Test
  func disabledBuiltInShortcutLeavesOtherDefaultsAndNamedMonitorAffinity() throws {
    let config = try Config.decode(Data("""
      disabled_keys = ["alt-left"]

      [workspaces]
      names = ["dev"]
      monitor_ids = { dev = "display-uuid" }
      """.utf8))
    #expect(config.keys["alt-left"] == nil)
    #expect(config.keys["alt-right"] == "focus-column right")
    #expect(config.workspaces.monitorIDs == ["dev": "display-uuid"])
  }

  @Test
  func aliasedOverrideAcceleratorCollisionsAreRejected() throws {
    let data = Data("""
      [modifier_combinations]
      hyper = "Alt"

      [keys]
      "alt-left" = "focus-column left"
      "hyper-left" = "focus-monitor left"
      """.utf8)
    #expect {
      try Config.decode(data)
    } throws: { error in
      guard case ConfigError.conflictingAccelerators(let first, let second) = error else { return false }
      return Set([first, second]) == Set(["alt-left", "hyper-left"])
    }
  }

  @Test
  func initialColumnWidthRulesCombineMatches() throws {
    let config = try Config.decode(Data("""
      [[rules]]
      app_id = "device"
      initial_column_width = 0.5
      include_initial_width_in_cycle = true
      [[rules]]
      title = "Phone"
      initial_column_width = 0.44
      [[rules]]
      app_id = "device"
      follow_focus = true
      """.utf8))
    #expect(config.decision(appID: "device", title: "Phone", role: nil).initialColumnWidth == 0.44)
    #expect(config.decision(appID: "device", title: "Other", role: nil).initialColumnWidth == 0.5)
    #expect(config.decision(appID: "other", title: "Other", role: nil).initialColumnWidth == nil)
    #expect(config.decision(appID: "device", title: "Phone", role: nil).includeInitialWidthInCycle)
    #expect(!config.decision(appID: "other", title: "Phone", role: nil).includeInitialWidthInCycle)
    for width in [0.05, 1.0] {
      try Config(rules: [Rule(appID: "device", initialColumnWidth: width)]).validate()
    }
  }

  static let rule = "[[rules]]\napp_id = \"device\"\ninitial_column_width"
  @Test(arguments: [
    ("[overview]\nzoom = 0.76", ConfigError.invalidValue("overview.zoom")),
    ("[overview]\nwindow_corner_radius = -1", .invalidValue("overview.window_corner_radius")),
    ("[overview]\nwindow_corner_radius = 65", .invalidValue("overview.window_corner_radius")),
    ("[decorations.borders]\nwidth = 65", .invalidValue("decorations.borders.width")),
    ("[decorations.borders]\ncolor = \"ffffff\"", .invalidValue("decorations.borders.color")),
    ("[input]\nfocus_follows_mouse_delay_ms = -1", .invalidValue("input.focus_follows_mouse_delay_ms")),
    ("[input]\nfocus_follows_mouse_max_scroll_amount = -0.1",
      .invalidValue("input.focus_follows_mouse_max_scroll_amount")),
    ("[input]\nfocus_follows_mouse_max_scroll_amount = 1.1",
      .invalidValue("input.focus_follows_mouse_max_scroll_amount")),
    ("[layout]\nouter_top_gap = 257", .invalidValue("layout.outer_top_gap")),
    ("[layout]\nouter_right_gap = 257", .invalidValue("layout.outer_right_gap")),
    ("[layout]\nouter_bottom_gap = 257", .invalidValue("layout.outer_bottom_gap")),
    ("[layout]\nouter_left_gap = 257", .invalidValue("layout.outer_left_gap")),
    ("[layout]\nreserved_top = -1", .invalidValue("layout.reserved_top")),
    ("[layout]\nreserved_top = 513", .invalidValue("layout.reserved_top")),
    ("\(rule) = 0", .invalidValue("rules.initial_column_width")),
    ("\(rule) = 0.049", .invalidValue("rules.initial_column_width")),
    ("\(rule) = 1.01", .invalidValue("rules.initial_column_width")),
    ("\(rule) = nan", .invalidValue("rules.initial_column_width")),
    ("\(rule) = inf", .invalidValue("rules.initial_column_width")),
    ("\(rule) = -inf", .invalidValue("rules.initial_column_width")),
    ("[workspaces]\nnames = [\"__defi_dynamic_1\"]", .invalidWorkspaces),
    ("[workspaces]\nnames = [\"dev\"]\n[[rules]]\napp_id = \"app\"\nworkspace = \"missing\"", .unknownWorkspace("missing")),
  ] as [(String, ConfigError)])
  func invalidValuesAreRejectedWithTheirKey(toml: String, error: ConfigError) {
    #expect(throws: error) { try Config.decode(Data(toml.utf8)) }
  }

  @Test
  func `Missing config uses defaults without creating files`() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "defi-missing-config-\(UUID().uuidString)")
    let config = try Config.load(from: directory.appending(path: "config.toml"))

    #expect(config == Config())
    #expect(FileManager.default.fileExists(atPath: directory.path) == false)
  }

  @Test
  func everySectionDecodesItsOverrides() throws {
    let config = try Config.decode(Data("""
      [overview]
      zoom = 0.25
      window_previews = false
      window_corner_radius = 18

      [decorations.borders]
      enabled = true
      width = 3.5
      color = "#ff33aaff"
      inactive_enabled = true
      inactive_color = "0x4433aaff"
      capture_enabled = true

      [input]
      focus_follows_mouse = true
      focus_follows_mouse_max_scroll_amount = 0.1
      focus_follows_mouse_delay_ms = 50
      mouse_follows_focus = true

      [layout]
      gaps = 8
      outer_top_gap = 1
      outer_right_gap = 2
      outer_bottom_gap = 0
      outer_left_gap = 3
      reserved_top = 11
      reserved_bottom = 4

      [menu_bar]
      enabled = false

      [modifier_combinations]
      hyper = "Alt + Cmd + Ctrl"

      [keys]
      "hyper-d" = "diagnostic-mark"
      """.utf8))
    #expect(config.overview.zoom == 0.25)
    #expect(!config.overview.windowPreviews)
    #expect(config.overview.windowCornerRadius == 18)
    #expect(config.decorations.borders.width == 3.5)
    #expect(config.decorations.borders.inactiveEnabled)
    #expect(config.decorations.borders.captureEnabled)
    #expect(parseBorderColor(config.decorations.borders.color) == 0xff33_aaff)
    #expect(parseBorderColor(config.decorations.borders.inactiveColor) == 0x4433_aaff)
    #expect(parseBorderColor("#fff") == nil)
    #expect(parseBorderColor("8033aaff") == nil)
    #expect(config.input.focusFollowsMouse)
    #expect(config.input.focusFollowsMouseMaxScrollAmount == 0.1)
    #expect(config.input.focusFollowsMouseDelayMS == 50)
    #expect(config.input.mouseFollowsFocus)
    #expect(config.layout.gaps == 8)
    #expect([config.layout.outerTopGap, config.layout.outerRightGap, config.layout.outerBottomGap,
      config.layout.outerLeftGap] == [1, 2, 0, 3])
    #expect(config.layout.reservedTop == 11)
    #expect(config.layout.reservedBottom == 4)
    #expect(!config.menuBar.enabled)
    #expect(config.keys["hyper-d"] == "diagnostic-mark")
  }

  @Test(arguments: [
    ("never", CenterFocusedColumnConfig.never), ("always", .always), ("on-overflow", .onOverflow),
  ])
  func decodesCenterFocusedColumn(value: String, expected: CenterFocusedColumnConfig) throws {
    #expect(try Config.decode(Data("[layout]\ncenter_focused_column = \"\(value)\"".utf8)).layout
      .centerFocusedColumn == expected)
  }

  @Test
  func `Decodes example shape and generates named workspace keys`() throws {
    let data = Data(
      """
      default_key_modifier = "hyper"

      [layout]
      gaps = 4

      [animation]
      enabled = false

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
    #expect(!config.animation.enabled)
    #expect(config.workspaces.defaultName == "dev")
    #expect(config.keys["hyper-1"] == "workspace dev")
    #expect(config.keys["hyper-shift-1"] == "move-column-to-workspace-name dev")
    #expect(config.keys["hyper-3"] == "focus-workspace-position 3")
    #expect(config.keys["hyper-minus"] == "cycle-width previous")
    #expect(config.keys["hyper-equal"] == "cycle-width next")
    #expect(config.keys["hyper-f"] == "maximize-column")
    #expect(config.keys["hyper-backslash"] == "toggle-floating")
    #expect(config.keys["hyper-shift-backslash"] == "activate-floating")
    #expect(config.keys["hyper-comma"] == "focus-floating previous")
    #expect(config.keys["hyper-period"] == "focus-floating next")
    #expect(config.modifierCombinations["hyper"] == "Alt + Cmd + Ctrl")
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
  func `Repository example decodes`() throws {
    let repository = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let config = try Config.load(from: repository.appending(path: "config.example.toml"))
    #expect(config.workspaces.names.first == "dev")
    #expect(config.keys["hyper-left"] == "focus-column left")
  }
}
