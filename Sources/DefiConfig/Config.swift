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
  public var modifierCombinations: [String: String]
  public var defaultKeyModifier: String
  public var keys: [String: String]
  public var rules: [Rule]

  public init(
    input: InputConfig = InputConfig(),
    layout: LayoutConfig = LayoutConfig(),
    animation: AnimationConfig = AnimationConfig(),
    overview: OverviewConfig = OverviewConfig(),
    decorations: DecorationsConfig = DecorationsConfig(),
    menuBar: MenuBarConfig = MenuBarConfig(),
    workspaces: WorkspacesConfig = WorkspacesConfig(),
    modifierCombinations: [String: String] = [:],
    defaultKeyModifier: String = "alt",
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
    self.modifierCombinations = modifierCombinations
    self.defaultKeyModifier = defaultKeyModifier
    self.keys = Self.defaultKeys(
      modifier: defaultKeyModifier,
      workspaceNames: workspaces.names
    ).merging(keys ?? [:]) { _, override in override }
    self.rules = rules
  }

  public static func decode(_ data: Data) throws -> Config {
    let raw = try TOMLDecoder().decode(RawConfig.self, from: data)
    let workspaces = raw.workspaces ?? WorkspacesConfig()
    let modifier = raw.defaultKeyModifier ?? "alt"
    let config = Config(
      input: raw.input ?? InputConfig(),
      layout: raw.layout ?? LayoutConfig(),
      animation: raw.animation ?? AnimationConfig(),
      overview: raw.overview ?? OverviewConfig(),
      decorations: raw.decorations ?? DecorationsConfig(),
      menuBar: raw.menuBar ?? MenuBarConfig(),
      workspaces: workspaces,
      modifierCombinations: raw.modifierCombinations ?? [:],
      defaultKeyModifier: modifier,
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

  public static var defaultURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".config/defi/config.toml")
  }

  public func validate() throws {
    if let maximumScrollAmount = input.focusFollowsMouseMaxScrollAmount {
      guard maximumScrollAmount.isFinite,
        (0...1).contains(maximumScrollAmount)
      else {
        throw ConfigError.invalidValue(
          "input.focus_follows_mouse_max_scroll_amount"
        )
      }
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
    guard (0...2_000).contains(animation.durationMS) else {
      throw ConfigError.invalidValue("animation.duration_ms")
    }
    guard overview.zoom.isFinite, (0...0.75).contains(overview.zoom) else {
      throw ConfigError.invalidValue("overview.zoom")
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
    guard !workspaces.names.isEmpty,
      Set(workspaces.names).count == workspaces.names.count
    else {
      throw ConfigError.invalidWorkspaces
    }
    guard workspaces.names.contains(workspaces.defaultName) else {
      throw ConfigError.unknownWorkspace(workspaces.defaultName)
    }

    for (_, command) in keys {
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
    var result = RuleDecision()
    for rule in rules where rule.matches(appID: appID, title: title, role: role) {
      if let workspace = rule.workspace {
        result.workspace = WorkspaceID(rawValue: workspace)
      }
      result.followFocus = result.followFocus || rule.followFocus
      result.floating = result.floating || rule.floating
      result.forceTiling = result.forceTiling || rule.forceTiling
      result.intrinsicSize = result.intrinsicSize || rule.intrinsicSize
    }
    return result
  }

  private func validateCommandWorkspace(_ command: Command) throws {
    let workspace: WorkspaceID?
    switch command {
    case .switchWorkspace(let value),
      .moveWindowToWorkspace(let value),
      .sendWindowToWorkspace(let value):
      workspace = value
    default:
      workspace = nil
    }
    if let workspace, !workspaces.names.contains(workspace.rawValue) {
      throw ConfigError.unknownWorkspace(workspace.rawValue)
    }
  }

  private static func defaultKeys(
    modifier: String,
    workspaceNames: [String]
  ) -> [String: String] {
    var result = [
      "\(modifier)-left": "focus-column left",
      "\(modifier)-right": "focus-column right",
      "\(modifier)-up": "focus-window up",
      "\(modifier)-down": "focus-window down",
      "\(modifier)-leftbracket": "focus-column first",
      "\(modifier)-rightbracket": "focus-column last",
      "\(modifier)-shift-left": "move-column left",
      "\(modifier)-shift-right": "move-column right",
      "\(modifier)-shift-up": "move-window up",
      "\(modifier)-shift-down": "move-window down",
      "\(modifier)-shift-leftbracket": "move-column first",
      "\(modifier)-shift-rightbracket": "move-column last",
      "\(modifier)-shift-h": "move-column-to-monitor left",
      "\(modifier)-shift-j": "move-column-to-monitor down",
      "\(modifier)-shift-k": "move-column-to-monitor up",
      "\(modifier)-shift-l": "move-column-to-monitor right",
      "\(modifier)-minus": "cycle-width previous",
      "\(modifier)-equal": "cycle-width next",
      "\(modifier)-f": "maximize-column",
      "\(modifier)-backslash": "toggle-floating",
      "\(modifier)-shift-backslash": "activate-floating",
      "\(modifier)-comma": "focus-floating previous",
      "\(modifier)-period": "focus-floating next",
      "\(modifier)-semicolon": "join-window left",
      "\(modifier)-quote": "join-window right",
      "\(modifier)-r": "unjoin-windows",
      "\(modifier)-o": "toggle-overview",
    ]
    for (index, workspace) in workspaceNames.prefix(9).enumerated() {
      let number = index + 1
      result["\(modifier)-\(number)"] = "workspace \(workspace)"
      result["\(modifier)-shift-\(number)"] = "move-window-to-workspace \(workspace)"
    }
    return result
  }
}

public enum ConfigError: Error, Equatable, CustomStringConvertible, Sendable {
  case invalidValue(String)
  case invalidWorkspaces
  case unknownWorkspace(String)
  case invalidCommand(String)

  public var description: String {
    switch self {
    case .invalidValue(let key): "invalid value: \(key)"
    case .invalidWorkspaces: "workspace names must be non-empty and unique"
    case .unknownWorkspace(let name): "unknown workspace: \(name)"
    case .invalidCommand(let command): "invalid command: \(command)"
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
  var modifierCombinations: [String: String]?
  var defaultKeyModifier: String?
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
    case modifierCombinations = "modifier_combinations"
    case defaultKeyModifier = "default_key_modifier"
    case keys
    case rules
  }
}
