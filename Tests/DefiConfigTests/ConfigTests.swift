@testable import DefiConfig
import DefiModel
import Foundation
import Testing

struct ConfigTests {
  @Test(arguments: ["a", "alt-fn", "typo-left", "-left", "alt--left", "alt-left-", ""])
  func malformedAcceleratorsAreRejectedWithoutReplacingDefaults(accelerator: String) throws {
    let config = Config(keys: [accelerator: "diagnostic-mark"])
    #expect(config.keys["mod-left"] == "focus-column left")
    #expect(throws: ConfigError.invalidValue("keys.\(accelerator)")) {
      try config.validate()
    }
  }

  @Test
  func singleCharacterKeyNamesNormalizeAndSymbolsCollideWithTheirNames() {
    #expect(normalizedAccelerator("ctrl-alt-[", aliases: [:]) == "alt-ctrl-leftbracket")
    #expect(normalizedAccelerator("ctrl-alt-leftbracket", aliases: [:]) == "alt-ctrl-leftbracket")
    #expect(normalizedAccelerator("ctrl-alt-\\", aliases: [:]) == "alt-ctrl-backslash")
    #expect(normalizedAccelerator("ctrl-alt-É", aliases: [:]) == "alt-ctrl-é")
    #expect(normalizedAccelerator("ctrl-alt-e\u{301}", aliases: [:]) == normalizedAccelerator("ctrl-alt-\u{e9}", aliases: [:]))
    #expect(normalizedAccelerator("ctrl-alt-¥", aliases: [:]) == "alt-ctrl-¥")
    #expect(normalizedAccelerator("ctrl-alt-unknown", aliases: [:]) == nil)
    #expect(normalizedAccelerator("ctrl-alt-fn", aliases: [:]) == nil)
    #expect(normalizedAccelerator("ctrl-alt- ", aliases: [:]) == nil)
  }

  @Test
  func literalKeyNamesAreValidConfiguration() throws {
    let config = Config(keys: ["ctrl-alt-¥": "toggle-floating", "ctrl-alt-é": "maximize-column"])
    try config.validate()
    #expect(config.keys["ctrl-alt-¥"] == "toggle-floating")
  }

  @Test(arguments: ["ctrl+alt", "ctrl+alt+shift", "ctrl+cmd", "ctrl+cmd+shift"])
  func layeredBindingsYieldToBaseNavigation(modifier: String) throws {
    let config = try Config.decode(Data("mod = \"\(modifier)\"".utf8))
    #expect(config.keys["mod-left"] == "focus-column left")
    #expect(config.keys["mod-cmd-left"] == (modifier.contains("cmd") ? nil : "move-column left"))
    #expect(config.keys["mod-shift-left"] == (modifier.contains("shift") ? nil : "focus-monitor left"))
    let monitorMove = config.keys["mod-shift-cmd-left"]
    #expect(monitorMove == (modifier.contains("cmd") || modifier.contains("shift") ? nil : "move-column-to-monitor left"))
    let overridden = Config(mod: modifier, keys: ["mod-left": "focus-monitor left"])
    #expect(overridden.keys["mod-left"] == "focus-monitor left")
  }

  @Test(arguments: ["", "ctrl+fn", "hyper"])
  func invalidModIsRejected(mod: String) {
    #expect(throws: ConfigError.invalidValue("mod")) { try Config.decode(Data("mod = \"\(mod)\"".utf8)) }
  }

  @Test
  func defaultBindingsFocusMoveAndReachMonitorsInLayers() {
    let keys = Config().keys
    #expect(keys["mod-h"] == "focus-column left")
    #expect(keys["mod-down"] == "focus-window down")
    #expect(keys["mod-home"] == "focus-column first")
    #expect(keys["mod-u"] == "focus-workspace down")
    #expect(keys["mod-pageup"] == "focus-workspace up")
    #expect(keys["mod-cmd-l"] == "move-column right")
    #expect(keys["mod-cmd-k"] == "move-window up")
    #expect(keys["mod-cmd-end"] == "move-column last")
    #expect(keys["mod-cmd-i"] == "move-column-to-workspace up")
    #expect(keys["mod-cmd-2"] == "move-column-to-workspace-position 2")
    #expect(keys["mod-shift-j"] == "focus-monitor down")
    #expect(keys["mod-shift-cmd-right"] == "move-column-to-monitor right")
    #expect(keys["mod-shift-u"] == "reorder-workspace down")
    #expect(keys["mod-leftbracket"] == "consume-or-expel-window left")
    #expect(keys["mod-period"] == "unjoin-windows")
    #expect(keys["mod-r"] == "cycle-width next")
    #expect(keys["mod-shift-slash"] == "toggle-cheatsheet")
    #expect(!keys.values.contains { $0.hasPrefix("move-workspace-to-monitor") })
  }

  @Test
  func disabledBuiltInShortcutLeavesOtherDefaultsAndNamedMonitorAffinity() throws {
    let config = try Config.decode(Data("""
      disabled_keys = ["ctrl-alt-left"]

      [workspaces]
      names = ["dev"]
      monitor_ids = { dev = "display-uuid" }
      """.utf8))
    #expect(config.keys["mod-left"] == nil)
    #expect(config.keys["mod-right"] == "focus-column right")
    #expect(config.workspaces.monitorIDs == ["dev": "display-uuid"])
  }

  @Test
  func aliasedOverrideAcceleratorCollisionsAreRejected() throws {
    let data = Data("""
      mod = "alt"

      [keys]
      "alt-left" = "focus-column left"
      "mod-left" = "focus-monitor left"
      """.utf8)
    #expect {
      try Config.decode(data)
    } throws: { error in
      guard case ConfigError.conflictingAccelerators(let first, let second) = error else { return false }
      return Set([first, second]) == Set(["alt-left", "mod-left"])
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
    ("[animation]\nstiffness = 99", .invalidValue("animation.stiffness")),
    ("[animation]\ndamping_ratio = 1.1", .invalidValue("animation.damping_ratio")),
    ("[animation]\ndamping_ratio = 0.4", .invalidValue("animation.damping_ratio")),
    ("[overview]\nwindow_corner_radius = -1", .invalidValue("overview.window_corner_radius")),
    ("[overview]\nwindow_corner_radius = 65", .invalidValue("overview.window_corner_radius")),
    ("[decorations.borders]\nwidth = 65", .invalidValue("decorations.borders.width")),
    ("[decorations.borders]\ncolor = \"ffffff\"", .invalidValue("decorations.borders.color")),
    ("[input]\nfocus_follows_mouse_delay_ms = -1", .invalidValue("input.focus_follows_mouse_delay_ms")),
    ("[input]\nfocus_follows_mouse_max_scroll_amount = -0.1",
      .invalidValue("input.focus_follows_mouse_max_scroll_amount")),
    ("[input]\nfocus_follows_mouse_max_scroll_amount = 1.1",
      .invalidValue("input.focus_follows_mouse_max_scroll_amount")),
    ("[input]\nscroll_gesture_modifier = \"tab\"", .invalidValue("input.scroll_gesture_modifier")),
    ("[input]\nscroll_gesture_modifier = \"\"", .invalidValue("input.scroll_gesture_modifier")),
    ("[input]\nscroll_gesture_speed = 0", .invalidValue("input.scroll_gesture_speed")),
    ("[input]\nscroll_gesture_fingers = 5", .invalidValue("input.scroll_gesture_fingers")),
    ("[input]\nscroll_gesture_modifier = \"none\"", .invalidValue("input.scroll_gesture_modifier")),
    ("[input]\nscroll_gesture_speed = 5.0", .invalidValue("input.scroll_gesture_speed")),
    ("[layout]\nouter_top_gap = 257", .invalidValue("layout.outer_top_gap")),
    ("[layout]\nouter_right_gap = 257", .invalidValue("layout.outer_right_gap")),
    ("[layout]\nouter_bottom_gap = 257", .invalidValue("layout.outer_bottom_gap")),
    ("[layout]\nouter_left_gap = 257", .invalidValue("layout.outer_left_gap")),
    ("[layout]\npreset_window_heights = []", .invalidValue("layout.preset_window_heights")),
    ("[layout]\npreset_window_heights = [1.0]", .invalidValue("layout.preset_window_heights")),
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
    ("[[rules]]\napp_id = \"a\"\ntitle_regex = \"(unclosed\"", .invalidValue("rules.title_regex")),
    ("[[rules]]\napp_id = \"a\"\nmonitor = 2", .invalidValue("rules.monitor takes a display name")),
    ("[[rules]]\napp_id = \"a\"\nmonitor = \"\"", .invalidValue("rules.monitor")),
    ("[workspaces]\nnames = [\"dev\"]\n[[rules]]\napp_id = \"a\"\nworkspace = \"dev\"\nmonitor = \"DELL\"",
      .invalidValue("rules.monitor cannot be combined with rules.workspace")),
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
      scroll_gestures = true
      scroll_gesture_modifier = "cmd+shift"

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

      [keys]
      "mod-d" = "diagnostic-mark"
      """.utf8))
    #expect(config.overview.zoom == 0.25)
    #expect(config.input.scrollGestures)
    #expect(config.scrollGestureModifier == "cmd+shift")
    #expect(Config().scrollGestureModifier == Config().mod)
    let swipe = try Config.decode(Data("[input]\nscroll_gesture_fingers = 3\nscroll_gesture_modifier = \"none\"".utf8))
    #expect(swipe.input.scrollGestureFingers == 3)
    #expect(Config().input.scrollGestureFingers == 2)
    #expect(Config().input.scrollGestureSnap)
    #expect(try !Config.decode(Data("[input]\nscroll_gesture_snap = false".utf8)).input.scrollGestureSnap)
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
    #expect(config.keys["mod-d"] == "diagnostic-mark")
  }

  @Test(arguments: [
    ("never", CenterFocusedColumnConfig.never), ("always", .always), ("on-overflow", .onOverflow),
  ])
  func decodesCenterFocusedColumn(value: String, expected: CenterFocusedColumnConfig) throws {
    #expect(try Config.decode(Data("[layout]\ncenter_focused_column = \"\(value)\"".utf8)).layout
      .centerFocusedColumn == expected)
  }

  @Test(arguments: [("true", true), ("false", false)])
  func decodesAlwaysCenterSingleColumn(value: String, expected: Bool) throws {
    #expect(try Config.decode(Data("[layout]\nalways_center_single_column = \(value)".utf8)).layout
      .alwaysCenterSingleColumn == expected)
  }

  @Test
  func `A lone column stays uncentered by default`() throws {
    #expect(!LayoutConfig().alwaysCenterSingleColumn)
    #expect(!(try Config.decode(Data("[layout]\ngaps = 4".utf8)).layout.alwaysCenterSingleColumn))
  }

  @Test
  func `Decodes example shape and generates named workspace keys`() throws {
    let data = Data(
      """
      mod = "ctrl+alt+cmd"

      [layout]
      gaps = 4

      [animation]
      enabled = false
      stiffness = 1000

      [workspaces]
      names = ["dev", "web"]

      [[rules]]
      app_id = "com.apple.dt.Xcode"
      workspace = "dev"
      follow_focus = true
      """.utf8
    )

    let config = try Config.decode(data)

    #expect(config.layout.gaps == 4)
    #expect(!config.animation.enabled)
    #expect(config.animation.stiffness == 1000 && config.animation.dampingRatio == 0.9)
    #expect(config.workspaces.defaultName == "dev")
    #expect(config.keys["mod-1"] == "workspace dev")
    // A Hyper mod already holds Command, so mod-1 keeps the chord mod-cmd-1 would take.
    #expect(config.keys["mod-cmd-1"] == nil)
    #expect(config.keys["mod-3"] == "focus-workspace-position 3")
    #expect(config.keys["mod-minus"] == "cycle-width previous")
    #expect(config.keys["mod-equal"] == "cycle-width next")
    #expect(config.keys["mod-f"] == "maximize-column")
    #expect(config.keys["mod-c"] == "center-column")
    #expect(config.keys["mod-v"] == "toggle-floating")
    #expect(config.keys["mod-shift-v"] == "activate-floating")
    #expect(config.keys["mod-shift-comma"] == "focus-floating previous")
    #expect(config.keys["mod-shift-period"] == "focus-floating next")
    #expect(config.mod == "ctrl+alt+cmd")
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
          window: .forceFloating
        ),
        Rule(title: "Preview", window: .forceTiled, intrinsicSize: true),
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
    // The last matching window placement wins.
    #expect(!decision.floating)
    #expect(decision.forceTiling)
    #expect(decision.intrinsicSize)
  }

  @Test
  func `Placement rules decode monitor, focus, and title regex`() throws {
    let config = try Config.decode(Data("""
      [workspaces]
      names = ["chat"]
      [[rules]]
      app_id = "slack"
      monitor = "Built-in Retina Display"
      open_focused = false
      [[rules]]
      title_regex = "^(settings|preferences)$"
      monitor = "DELL U2720Q"
      open_focused = true
      [[rules]]
      app_id = "slack"
      title = "Huddle"
      workspace = "chat"
      """.utf8))
    #expect(config.rules.map(\.monitor) == ["Built-in Retina Display", "DELL U2720Q", nil])
    #expect(config.rules.map(\.openFocused) == [false, true, nil])
    #expect(config.decision(appID: "slack", title: "General", role: nil)
      == RuleDecision(monitor: "Built-in Retina Display", openFocused: false))
    #expect(config.decision(appID: "notes", title: "Settings", role: nil)
      == RuleDecision(monitor: "DELL U2720Q", openFocused: true))
    // The regex searches case-insensitively and must match the whole title only when anchored.
    #expect(config.decision(appID: "notes", title: "App Settings", role: nil) == RuleDecision())
    // A later workspace replaces an earlier monitor.
    #expect(config.decision(appID: "slack", title: "Huddle", role: nil)
      == RuleDecision(workspace: WorkspaceID(rawValue: "chat"), openFocused: false))
  }

  @Test
  func `Window placement decodes and the last matching rule wins`() throws {
    let config = try Config.decode(Data("""
      [[rules]]
      app_id = "net.kovidgoyal.kitty"
      window = "force-tiled"
      [[rules]]
      title = "Picture-in-Picture"
      window = "force-floating"
      """.utf8))
    #expect(config.rules.map(\.window) == [.forceTiled, .forceFloating])
    #expect(config.decision(appID: "net.kovidgoyal.kitty", title: "zsh", role: nil) == RuleDecision(forceTiling: true))
    #expect(config.decision(appID: "net.kovidgoyal.kitty", title: "Picture-in-Picture", role: nil) == RuleDecision(floating: true))
    #expect(throws: (any Error).self) { try Config.decode(Data("[[rules]]\napp_id = \"a\"\nwindow = \"stacked\"".utf8)) }
  }

  @Test
  func `Repository example decodes`() throws {
    let repository = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let config = try Config.load(from: repository.appending(path: "config.example.toml"))
    #expect(config.workspaces.names.first == "dev")
    #expect(config.keys["mod-left"] == "focus-column left")
  }

  @Test
  func `Removed keys fail with their replacement, also inside arrays of tables`() throws {
    let removed = ["default_key_modifier": "use mod", "rules.floating": "use window", "layout.old": "gone"]
    #expect(throws: ConfigError.removedKey("rules.floating", replacement: "use window")) {
      try Config.decode(Data("[[rules]]\napp_id = \"a\"\n[[rules]]\napp_id = \"b\"\nfloating = true\n".utf8), removedKeys: removed)
    }
    #expect(throws: ConfigError.removedKey("default_key_modifier", replacement: "use mod")) {
      try Config.decode(Data("default_key_modifier = \"hyper\"\n".utf8), removedKeys: removed)
    }
    _ = try Config.decode(Data("[layout]\n[[rules]]\napp_id = \"a\"\nwindow = \"force-tiled\"\n".utf8), removedKeys: removed)
  }
}

