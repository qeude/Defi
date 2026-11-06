import DefiModel
import Foundation
import TOMLDecoder

public struct Config: Equatable, Sendable {
  public var input: InputConfig
  public var layout: LayoutConfig
  public var animation: AnimationConfig
  public var overview: OverviewConfig
  public var decorations: DecorationsConfig
  public var menuBar: MenuBarConfig
  public var workspaces: WorkspacesConfig
  /// The `+`-separated modifiers that `mod` stands for in every accelerator.
  public var mod: String
  public var showCheatsheetOnModifierHold: Bool
  public var disabledKeys: [String]
  public var keys: [String: String]
  public var keyOverrides: [String: String]
  public var rules: [Rule]

  public init(
    input: InputConfig = InputConfig(),
    layout: LayoutConfig = LayoutConfig(),
    animation: AnimationConfig = AnimationConfig(),
    overview: OverviewConfig = OverviewConfig(),
    decorations: DecorationsConfig = DecorationsConfig(),
    menuBar: MenuBarConfig = MenuBarConfig(),
    workspaces: WorkspacesConfig = WorkspacesConfig(),
    mod: String = Config.defaultMod,
    showCheatsheetOnModifierHold: Bool = true,
    disabledKeys: [String] = [],
    keys: [String: String]? = nil,
    rules: [Rule] = []
  ) {
    self.input = input
    self.layout = layout
    self.animation = animation
    self.overview = overview
    self.decorations = decorations
    self.menuBar = menuBar
    self.workspaces = workspaces
    self.mod = mod
    let modifierAliases = ["mod": mod]
    self.showCheatsheetOnModifierHold = showCheatsheetOnModifierHold
    self.disabledKeys = disabledKeys
    self.keyOverrides = keys ?? [:]
    let defaults = Self.defaultKeys(
      modifier: "mod", workspaceNames: workspaces.names,
      aliases: modifierAliases
    ).filter { accelerator, _ in
      guard let normalized = normalizedAccelerator(accelerator, aliases: modifierAliases) else {
        return true
      }
      return !disabledKeys.contains { normalizedAccelerator($0, aliases: modifierAliases) == normalized }
    }
    self.keys = mergingKeyBindings(
      defaults,
      overrides: keys ?? [:], aliases: modifierAliases
    )
    self.rules = rules
  }

  public static func decode(_ data: Data) throws -> Config {
    try decode(data, removedKeys: removedConfigKeys)
  }

  static func decode(_ data: Data, removedKeys: [String: String]) throws -> Config {
    if !removedKeys.isEmpty, let removed = firstRemovedKey(in: try TOMLTable(source: data), removed: removedKeys) {
      throw ConfigError.removedKey(removed.key, replacement: removed.replacement)
    }
    let raw = try TOMLDecoder().decode(RawConfig.self, from: data)
    let workspaces = raw.workspaces ?? WorkspacesConfig()
    let config = Config(
      input: raw.input ?? InputConfig(),
      layout: raw.layout ?? LayoutConfig(),
      animation: raw.animation ?? AnimationConfig(),
      overview: raw.overview ?? OverviewConfig(),
      decorations: raw.decorations ?? DecorationsConfig(),
      menuBar: raw.menuBar ?? MenuBarConfig(),
      workspaces: workspaces,
      mod: raw.mod ?? defaultMod,
      showCheatsheetOnModifierHold: raw.showCheatsheetOnModifierHold ?? true,
      disabledKeys: raw.disabledKeys ?? [],
      keys: raw.keys,
      rules: raw.rules ?? []
    )
    try config.validate()
    return config
  }

  public static func load(from url: URL?) throws -> Config {
    let path = url ?? defaultURL
    guard FileManager.default.fileExists(atPath: path.path) else {
      return Config()
    }
    return try decode(Data(contentsOf: path))
  }

  public static let defaultMod = "ctrl+alt"

  /// The aliases accelerators resolve: `mod` alone.
  public var modifierAliases: [String: String] { ["mod": mod] }

  /// The modifier held for scroll gestures.
  public var scrollGestureModifier: String { input.scrollGestureModifier ?? mod }

  public static var defaultURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/defi/config.toml")
  }

  public func validate() throws {
    guard normalizedAccelerator("mod-a", aliases: modifierAliases) != nil else {
      throw ConfigError.invalidValue("mod")
    }
    if let maximumScrollAmount = input.focusFollowsMouseMaxScrollAmount {
      guard maximumScrollAmount.isFinite,
        (0...1).contains(maximumScrollAmount)
      else {
        throw ConfigError.invalidValue(
          "input.focus_follows_mouse_max_scroll_amount"
        )
      }
    }
    guard (0...1_000).contains(input.focusFollowsMouseDelayMS) else {
      throw ConfigError.invalidValue("input.focus_follows_mouse_delay_ms")
    }
    guard (2...4).contains(input.scrollGestureFingers) else {
      throw ConfigError.invalidValue("input.scroll_gesture_fingers")
    }
    // Two fingers without a modifier would take every app's scrolling.
    guard scrollGestureModifier == "none"
      ? input.scrollGestureFingers >= 3
      : normalizedAccelerator("\(scrollGestureModifier)-a", aliases: modifierAliases) != nil
    else {
      throw ConfigError.invalidValue("input.scroll_gesture_modifier")
    }
    guard (0.25...4).contains(input.scrollGestureSpeed) else {
      throw ConfigError.invalidValue("input.scroll_gesture_speed")
    }
    guard (0.05...1).contains(layout.defaultColumnWidth) else {
      throw ConfigError.invalidValue("layout.default_column_width")
    }
    guard !layout.presetColumnWidths.isEmpty,
      layout.presetColumnWidths.allSatisfy({ (0.05...1).contains($0) })
    else {
      throw ConfigError.invalidValue("layout.preset_column_widths")
    }
    guard (0...256).contains(layout.gaps) else {
      throw ConfigError.invalidValue("layout.gaps")
    }
    for (key, value) in [
      ("outer_top_gap", layout.outerTopGap),
      ("outer_right_gap", layout.outerRightGap),
      ("outer_bottom_gap", layout.outerBottomGap),
      ("outer_left_gap", layout.outerLeftGap),
    ] {
      if let value, value.isFinite == false || (0...256).contains(value) == false {
        throw ConfigError.invalidValue("layout.\(key)")
      }
    }
    guard layout.reservedTop.isFinite, (0...512).contains(layout.reservedTop) else {
      throw ConfigError.invalidValue("layout.reserved_top")
    }
    guard layout.reservedBottom.isFinite, (0...512).contains(layout.reservedBottom) else {
      throw ConfigError.invalidValue("layout.reserved_bottom")
    }
    guard overview.zoom.isFinite, (0...0.75).contains(overview.zoom) else {
      throw ConfigError.invalidValue("overview.zoom")
    }
    guard overview.windowCornerRadius.isFinite,
      (0...64).contains(overview.windowCornerRadius)
    else {
      throw ConfigError.invalidValue("overview.window_corner_radius")
    }
    guard (0...64).contains(decorations.borders.width) else {
      throw ConfigError.invalidValue("decorations.borders.width")
    }
    guard parseBorderColor(decorations.borders.color) != nil else {
      throw ConfigError.invalidValue("decorations.borders.color")
    }
    guard parseBorderColor(decorations.borders.inactiveColor) != nil else {
      throw ConfigError.invalidValue("decorations.borders.inactive_color")
    }
    guard ["inside", "outside"].contains(decorations.borders.placement) else {
      throw ConfigError.invalidValue("decorations.borders.placement")
    }
    guard Set(workspaces.names).count == workspaces.names.count,
      workspaces.names.allSatisfy({ name in
        !name.isEmpty
          && !name.hasPrefix(WorkspaceID.dynamicPrefix)
          && name.allSatisfy { !$0.isWhitespace }
      })
    else {
      throw ConfigError.invalidWorkspaces
    }
    if let defaultName = workspaces.defaultName,
      !workspaces.names.contains(defaultName)
    {
      throw ConfigError.unknownWorkspace(defaultName)
    }
    for (name, icon) in workspaces.icons {
      guard workspaces.names.contains(name) else { throw ConfigError.unknownWorkspace(name) }
      guard !icon.isEmpty else { throw ConfigError.invalidValue("workspaces.icons.\(name)") }
    }
    for (name, monitor) in workspaces.monitors {
      guard workspaces.names.contains(name) else {
        throw ConfigError.unknownWorkspace(name)
      }
      guard monitor > 0 else {
        throw ConfigError.invalidValue("workspaces.monitors.\(name)")
      }
    }
    for (name, monitorID) in workspaces.monitorIDs {
      guard workspaces.names.contains(name) else {
        throw ConfigError.unknownWorkspace(name)
      }
      guard !monitorID.isEmpty else {
        throw ConfigError.invalidValue("workspaces.monitor_ids.\(name)")
      }
      guard workspaces.monitors[name] == nil else {
        throw ConfigError.invalidValue("workspaces.monitor_ids.\(name)")
      }
    }

    var overrideAccelerators: [String: String] = [:]
    for accelerator in keyOverrides.keys {
      guard let normalized = normalizedAccelerator(accelerator, aliases: modifierAliases) else {
        throw ConfigError.invalidValue("keys.\(accelerator)")
      }
      if let existing = overrideAccelerators[normalized] {
        throw ConfigError.conflictingAccelerators(existing, accelerator)
      }
      overrideAccelerators[normalized] = accelerator
    }
    var disabledAccelerators = Set<String>()
    for accelerator in disabledKeys {
      guard let normalized = normalizedAccelerator(accelerator, aliases: modifierAliases) else {
        throw ConfigError.invalidValue("disabled_keys.\(accelerator)")
      }
      guard disabledAccelerators.insert(normalized).inserted else {
        throw ConfigError.invalidValue("disabled_keys.\(accelerator)")
      }
    }
    for (accelerator, command) in keys {
      guard normalizedAccelerator(accelerator, aliases: modifierAliases) != nil else {
        throw ConfigError.invalidValue("keys.\(accelerator)")
      }
      if command == "diagnostic-mark" { continue }
      do {
        try validateCommandWorkspace(try parseCommand(command))
      } catch let error as ConfigError {
        throw error
      } catch {
        throw ConfigError.invalidCommand(command)
      }
    }
    for rule in rules {
      if let width = rule.initialColumnWidth, !(0.05...1).contains(width) {
        throw ConfigError.invalidValue("rules.initial_column_width")
      }
      if let workspace = rule.workspace, !workspaces.names.contains(workspace) {
        throw ConfigError.unknownWorkspace(workspace)
      }
    }
  }

  public func decision(for window: Window) -> RuleDecision {
    decision(appID: window.appID, title: window.title, role: window.role)
  }

  public func decision(
    appID: String,
    title: String,
    role: String?
  ) -> RuleDecision {
    Self.decision(appID: appID, title: title, role: role, rules: rules)
  }

  public static func decision(
    appID: String, title: String, role: String?, rules: [Rule]
  ) -> RuleDecision {
    var result = RuleDecision()
    for rule in rules where rule.matches(appID: appID, title: title, role: role) {
      if let workspace = rule.workspace {
        result.workspace = WorkspaceID(rawValue: workspace)
      }
      if let width = rule.initialColumnWidth {
        result.initialColumnWidth = width
      }
      result.followFocus = result.followFocus || rule.followFocus
      if let window = rule.window {
        result.floating = window == .forceFloating
        result.forceTiling = window == .forceTiled
      }
      result.intrinsicSize = result.intrinsicSize || rule.intrinsicSize
      result.includeInitialWidthInCycle =
        result.includeInitialWidthInCycle || rule.includeInitialWidthInCycle
    }
    return result
  }

  private func validateCommandWorkspace(_ command: Command) throws {
    let workspaceName: String?
    switch command {
    case .switchWorkspace(let value),
      .moveWindowToWorkspace(let value),
      .sendWindowToWorkspace(let value):
      workspaceName = value.rawValue
    case .focusWorkspace(.named(let value)),
      .moveColumnToWorkspace(.named(let value), follow: _),
      .moveWindowToWorkspaceTarget(.named(let value), follow: _):
      workspaceName = value
    default:
      workspaceName = nil
    }
    if let workspaceName, !workspaces.names.contains(workspaceName) {
      throw ConfigError.unknownWorkspace(workspaceName)
    }
  }

  private static func defaultKeys(
    modifier: String,
    workspaceNames: [String],
    aliases: [String: String]
  ) -> [String: String] {
    var result = [
      "\(modifier)-left": "focus-column left",
      "\(modifier)-right": "focus-column right",
      "\(modifier)-j": "focus-window down",
      "\(modifier)-k": "focus-window up",
      "\(modifier)-up": "focus-workspace up",
      "\(modifier)-down": "focus-workspace down",
      "\(modifier)-leftbracket": "focus-column first",
      "\(modifier)-rightbracket": "focus-column last",
      "\(modifier)-shift-left": "move-column left",
      "\(modifier)-shift-right": "move-column right",
      "\(modifier)-shift-j": "move-window down",
      "\(modifier)-shift-k": "move-window up",
      "\(modifier)-shift-up": "move-column-to-workspace up",
      "\(modifier)-shift-down": "move-column-to-workspace down",
      "\(modifier)-shift-leftbracket": "move-column first",
      "\(modifier)-shift-rightbracket": "move-column last",
      "\(modifier)-minus": "cycle-width previous",
      "\(modifier)-equal": "cycle-width next",
      "\(modifier)-f": "maximize-column",
      "\(modifier)-c": "center-column",
      "\(modifier)-backslash": "toggle-floating",
      "\(modifier)-shift-backslash": "activate-floating",
      "\(modifier)-comma": "focus-floating previous",
      "\(modifier)-period": "focus-floating next",
      "\(modifier)-semicolon": "join-window left",
      "\(modifier)-quote": "join-window right",
      "\(modifier)-r": "unjoin-windows",
      "\(modifier)-o": "toggle-overview",
    ]
    // Configured navigation takes precedence over colliding fixed monitor keys.
    let monitorKeys = [
      "ctrl-cmd-left": "focus-monitor left",
      "ctrl-cmd-right": "focus-monitor right",
      "ctrl-cmd-up": "focus-monitor up",
      "ctrl-cmd-down": "focus-monitor down",
      "ctrl-cmd-shift-left": "move-column-to-monitor left",
      "ctrl-cmd-shift-right": "move-column-to-monitor right",
      "ctrl-cmd-shift-up": "move-column-to-monitor up",
      "ctrl-cmd-shift-down": "move-column-to-monitor down",
      "ctrl-cmd-alt-left": "move-workspace-to-monitor left",
      "ctrl-cmd-alt-right": "move-workspace-to-monitor right",
      "ctrl-cmd-alt-up": "move-workspace-to-monitor up",
      "ctrl-cmd-alt-down": "move-workspace-to-monitor down",
    ]
    for number in 1...9 {
      if workspaceNames.indices.contains(number - 1) {
        let workspace = workspaceNames[number - 1]
        result["\(modifier)-\(number)"] = "workspace \(workspace)"
        result["\(modifier)-shift-\(number)"] =
          "move-column-to-workspace-name \(workspace)"
      } else {
        result["\(modifier)-\(number)"] = "focus-workspace-position \(number)"
        result["\(modifier)-shift-\(number)"] =
          "move-column-to-workspace-position \(number)"
      }
    }
    // If the modifier already includes Shift, preserve base navigation.
    let shifted = result.filter { $0.key.hasPrefix("\(modifier)-shift-") }
    let base = result.filter { !$0.key.hasPrefix("\(modifier)-shift-") }
    let generated = mergingKeyBindings(shifted, overrides: base, aliases: aliases)
    return mergingKeyBindings(monitorKeys, overrides: generated, aliases: aliases)
  }
}

public enum ConfigError: Error, Equatable, CustomStringConvertible, Sendable {
  case invalidValue(String)
  case invalidWorkspaces
  case unknownWorkspace(String)
  case invalidCommand(String)
  case conflictingAccelerators(String, String)
  case removedKey(String, replacement: String)

  public var description: String {
    switch self {
    case .invalidValue(let key): "invalid value: \(key)"
    case .invalidWorkspaces:
      "workspace names must be unique, contain no whitespace, and not use Defi's reserved prefix"
    case .unknownWorkspace(let name): "unknown workspace: \(name)"
    case .invalidCommand(let command): "invalid command: \(command)"
    case .conflictingAccelerators(let first, let second):
      "conflicting key bindings: \(first) and \(second)"
    case .removedKey(let key, let replacement):
      "\(key) was removed: \(replacement)"
    }
  }
}

private struct RawConfig: Decodable {
  var input: InputConfig?
  var layout: LayoutConfig?
  var animation: AnimationConfig?
  var overview: OverviewConfig?
  var decorations: DecorationsConfig?
  var menuBar: MenuBarConfig?
  var workspaces: WorkspacesConfig?
  var mod: String?
  var showCheatsheetOnModifierHold: Bool?
  var disabledKeys: [String]?
  var keys: [String: String]?
  var rules: [Rule]?

  enum CodingKeys: String, CodingKey {
    case input
    case layout
    case animation
    case overview
    case decorations
    case menuBar = "menu_bar"
    case workspaces
    case mod
    case showCheatsheetOnModifierHold = "show_cheatsheet_on_modifier_hold"
    case disabledKeys = "disabled_keys"
    case keys
    case rules
  }
}
