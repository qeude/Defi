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
      aliases: modifierAliases, mod: mod
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
    let columnWidths: [(String, Double?, [Double]?)] =
      [("layout", layout.defaultColumnWidth, layout.presetColumnWidths)]
      + layout.monitors.sorted { $0.key < $1.key }.map {
        ("layout.monitors.\($0.key)", $0.value.defaultColumnWidth, $0.value.presetColumnWidths)
      }
    for (table, defaultWidth, presets) in columnWidths {
      guard defaultWidth.map({ (0.05...1).contains($0) }) ?? true else {
        throw ConfigError.invalidValue("\(table).default_column_width")
      }
      guard presets.map({ !$0.isEmpty && $0.allSatisfy { (0.05...1).contains($0) } }) ?? true else {
        throw ConfigError.invalidValue("\(table).preset_column_widths")
      }
    }
    guard !layout.presetWindowHeights.isEmpty,
      layout.presetWindowHeights.allSatisfy({ (0.05...0.95).contains($0) })
    else {
      throw ConfigError.invalidValue("layout.preset_window_heights")
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
    guard animation.stiffness.isFinite, (100...2_000).contains(animation.stiffness) else {
      throw ConfigError.invalidValue("animation.stiffness")
    }
    guard animation.dampingRatio.isFinite, (0.5...1).contains(animation.dampingRatio) else {
      throw ConfigError.invalidValue("animation.damping_ratio")
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
      if let pattern = rule.titleRegex, Rule.titleExpression(pattern) == nil {
        throw ConfigError.invalidValue("rules.title_regex")
      }
      if let monitor = rule.monitor {
        guard !monitor.isEmpty else { throw ConfigError.invalidValue("rules.monitor") }
        // A named workspace already decides its monitor.
        guard rule.workspace == nil else {
          throw ConfigError.invalidValue("rules.monitor cannot be combined with rules.workspace")
        }
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
        result.monitor = nil
      }
      if let monitor = rule.monitor {
        result.monitor = monitor
        result.workspace = nil
      }
      if let openFocused = rule.openFocused {
        result.openFocused = openFocused
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
    aliases: [String: String],
    mod: String
  ) -> [String: String] {
    // `mod` focuses, the first of Command and Shift that `mod` lacks moves, and the
    // other one reaches other monitors; a layer with no free modifier stays unbound.
    let used = Set((normalizedAccelerator("mod-a", aliases: ["mod": mod]) ?? "").split(separator: "-"))
    var free = ["cmd", "shift"].filter { !used.contains(Substring($0)) }
    let move = free.isEmpty ? nil : free.removeFirst()
    let monitor = free.first
    // An unbound layer's prefix starts with "!" and is dropped below.
    let moveKey = move.map { "\(modifier)-\($0)" } ?? "!move"
    let monitorKey = monitor.map { "\(modifier)-\($0)" } ?? "!monitor"
    let moveMonitorKey = move.flatMap { m in monitor.map { "\(modifier)-\($0)-\(m)" } } ?? "!both"
    var result: [String: String] = [
      "\(modifier)-home": "focus-column first",
      "\(modifier)-end": "focus-column last",
      "\(moveKey)-home": "move-column first",
      "\(moveKey)-end": "move-column last",
      "\(modifier)-u": "focus-workspace down",
      "\(modifier)-i": "focus-workspace up",
      "\(modifier)-pagedown": "focus-workspace down",
      "\(modifier)-pageup": "focus-workspace up",
      "\(moveKey)-u": "move-column-to-workspace down",
      "\(moveKey)-i": "move-column-to-workspace up",
      "\(moveKey)-pagedown": "move-column-to-workspace down",
      "\(moveKey)-pageup": "move-column-to-workspace up",
      "\(monitorKey)-u": "reorder-workspace down",
      "\(monitorKey)-i": "reorder-workspace up",
      "\(monitorKey)-pagedown": "reorder-workspace down",
      "\(monitorKey)-pageup": "reorder-workspace up",
      "\(modifier)-leftbracket": "consume-or-expel-window left",
      "\(modifier)-rightbracket": "consume-or-expel-window right",
      "\(modifier)-period": "unjoin-windows",
      "\(modifier)-semicolon": "join-window left",
      "\(modifier)-quote": "join-window right",
      "\(modifier)-r": "cycle-width next",
      "\(modifier)-minus": "cycle-width previous",
      "\(modifier)-equal": "cycle-width next",
      "\(modifier)-f": "maximize-column",
      "\(modifier)-c": "center-column",
      "\(modifier)-v": "toggle-floating",
      "\(modifier)-shift-v": "activate-floating",
      "\(modifier)-shift-comma": "focus-floating previous",
      "\(modifier)-shift-period": "focus-floating next",
      "\(modifier)-o": "toggle-overview",
      "\(modifier)-shift-slash": "toggle-cheatsheet",
    ]
    let directions = [
      ("left", "h", "left"), ("right", "l", "right"), ("up", "k", "up"), ("down", "j", "down"),
    ]
    for (arrow, letter, direction) in directions {
      let horizontal = direction == "left" || direction == "right"
      for key in [arrow, letter] {
        result["\(modifier)-\(key)"] =
          horizontal ? "focus-column \(direction)" : "focus-window \(direction)"
        result["\(moveKey)-\(key)"] =
          horizontal ? "move-column \(direction)" : "move-window \(direction)"
        result["\(monitorKey)-\(key)"] = "focus-monitor \(direction)"
        result["\(moveMonitorKey)-\(key)"] = "move-column-to-monitor \(direction)"
      }
    }
    for number in 1...9 {
      if workspaceNames.indices.contains(number - 1) {
        let workspace = workspaceNames[number - 1]
        result["\(modifier)-\(number)"] = "workspace \(workspace)"
        result["\(moveKey)-\(number)"] =
          "move-column-to-workspace-name \(workspace)"
      } else {
        result["\(modifier)-\(number)"] = "focus-workspace-position \(number)"
        result["\(moveKey)-\(number)"] =
          "move-column-to-workspace-position \(number)"
      }
    }
    // When `mod` already includes Shift or Command, the binding with fewer added
    // modifiers wins the chord they share.
    func addedModifiers(_ accelerator: String) -> Int {
      ["-shift-", "-cmd-"].filter(accelerator.contains).count
    }
    result = result.filter { !$0.key.hasPrefix("!") }
    return [2, 1, 0].reduce(into: [String: String]()) { merged, count in
      merged = mergingKeyBindings(
        merged, overrides: result.filter { addedModifiers($0.key) == count }, aliases: aliases)
    }
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
