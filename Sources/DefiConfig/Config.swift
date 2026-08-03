import DefiModel
import Foundation
import TOMLDecoder

public struct Config: Equatable, Sendable {
  public var layout: LayoutConfig
  public var animation: AnimationConfig
  public var decorations: DecorationsConfig
  public var workspaces: WorkspacesConfig
  public var modifierCombinations: [String: String]
  public var defaultKeyModifier: String
  public var keys: [String: String]
  public var rules: [Rule]

  public init(
    layout: LayoutConfig = LayoutConfig(),
    animation: AnimationConfig = AnimationConfig(),
    decorations: DecorationsConfig = DecorationsConfig(),
    workspaces: WorkspacesConfig = WorkspacesConfig(),
    modifierCombinations: [String: String] = [:],
    defaultKeyModifier: String = "alt",
    keys: [String: String]? = nil,
    rules: [Rule] = []
  ) {
    self.layout = layout
    self.animation = animation
    self.decorations = decorations
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
      layout: raw.layout ?? LayoutConfig(),
      animation: raw.animation ?? AnimationConfig(),
      decorations: raw.decorations ?? DecorationsConfig(),
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
    guard (0...2_000).contains(animation.durationMS) else {
      throw ConfigError.invalidValue("animation.duration_ms")
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
    guard !workspaces.names.isEmpty,
      Set(workspaces.names).count == workspaces.names.count
    else {
      throw ConfigError.invalidWorkspaces
    }
    guard workspaces.names.contains(workspaces.defaultName) else {
      throw ConfigError.unknownWorkspace(workspaces.defaultName)
    }

    for (_, command) in keys {
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
    var result = RuleDecision()
    for rule in rules where rule.matches(window) {
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
      "\(modifier)-minus": "cycle-width previous",
      "\(modifier)-equal": "cycle-width next",
      "\(modifier)-f": "toggle-fullscreen",
      "\(modifier)-semicolon": "join-window left",
      "\(modifier)-quote": "join-window right",
      "\(modifier)-r": "unjoin-windows",
    ]
    for (index, workspace) in workspaceNames.prefix(9).enumerated() {
      let number = index + 1
      result["\(modifier)-\(number)"] = "workspace \(workspace)"
      result["\(modifier)-shift-\(number)"] = "move-window-to-workspace \(workspace)"
    }
    return result
  }
}

public struct DecorationsConfig: Codable, Equatable, Sendable {
  public var borders: BordersConfig

  public init(borders: BordersConfig = BordersConfig()) {
    self.borders = borders
  }

  enum CodingKeys: String, CodingKey {
    case borders
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    borders =
      try values.decodeIfPresent(BordersConfig.self, forKey: .borders)
      ?? BordersConfig()
  }
}

public struct BordersConfig: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var width: Double
  public var color: String
  public var inactiveEnabled: Bool
  public var inactiveColor: String
  public var captureEnabled: Bool

  public init(
    enabled: Bool = true,
    width: Double = 4,
    color: String = "#FFC099FF",
    inactiveEnabled: Bool = false,
    inactiveColor: String = "#66C099FF",
    captureEnabled: Bool = false
  ) {
    self.enabled = enabled
    self.width = width
    self.color = color
    self.inactiveEnabled = inactiveEnabled
    self.inactiveColor = inactiveColor
    self.captureEnabled = captureEnabled
  }

  enum CodingKeys: String, CodingKey {
    case enabled
    case width
    case color
    case inactiveEnabled = "inactive_enabled"
    case inactiveColor = "inactive_color"
    case captureEnabled = "capture_enabled"
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = BordersConfig()
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
    width = try values.decodeIfPresent(Double.self, forKey: .width) ?? defaults.width
    color = try values.decodeIfPresent(String.self, forKey: .color) ?? defaults.color
    inactiveEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .inactiveEnabled)
      ?? defaults.inactiveEnabled
    inactiveColor =
      try values.decodeIfPresent(String.self, forKey: .inactiveColor)
      ?? defaults.inactiveColor
    captureEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .captureEnabled)
      ?? defaults.captureEnabled
  }
}

public func parseBorderColor(_ value: String) -> UInt32? {
  let digits: Substring
  if value.hasPrefix("0x") || value.hasPrefix("0X") {
    digits = value.dropFirst(2)
  } else if value.hasPrefix("#") {
    digits = value.dropFirst()
  } else {
    return nil
  }
  guard digits.count == 8,
    digits.allSatisfy({ $0.isHexDigit }),
    let color = UInt32(digits, radix: 16)
  else {
    return nil
  }
  return color
}

public struct AnimationConfig: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var durationMS: Int

  public init(enabled: Bool = true, durationMS: Int = 35) {
    self.enabled = enabled
    self.durationMS = durationMS
  }

  enum CodingKeys: String, CodingKey {
    case enabled
    case durationMS = "duration_ms"
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    durationMS = try values.decodeIfPresent(Int.self, forKey: .durationMS) ?? 35
  }
}

public struct LayoutConfig: Codable, Equatable, Sendable {
  public var defaultColumnWidth: Double
  public var presetColumnWidths: [Double]
  public var centerFocusedColumn: CenterFocusedColumnConfig
  public var gaps: Double

  public init(
    defaultColumnWidth: Double = 0.80,
    presetColumnWidths: [Double] = [0.33, 0.50, 0.66, 0.80],
    centerFocusedColumn: CenterFocusedColumnConfig = .never,
    gaps: Double = 8
  ) {
    self.defaultColumnWidth = defaultColumnWidth
    self.presetColumnWidths = presetColumnWidths
    self.centerFocusedColumn = centerFocusedColumn
    self.gaps = gaps
  }

  enum CodingKeys: String, CodingKey {
    case defaultColumnWidth = "default_column_width"
    case presetColumnWidths = "preset_column_widths"
    case centerFocusedColumn = "center_focused_column"
    case gaps
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    defaultColumnWidth =
      try values.decodeIfPresent(Double.self, forKey: .defaultColumnWidth) ?? 0.80
    presetColumnWidths =
      try values.decodeIfPresent([Double].self, forKey: .presetColumnWidths)
      ?? [0.33, 0.50, 0.66, 0.80]
    centerFocusedColumn =
      try values.decodeIfPresent(
        CenterFocusedColumnConfig.self,
        forKey: .centerFocusedColumn
      ) ?? .never
    gaps = try values.decodeIfPresent(Double.self, forKey: .gaps) ?? 8
  }
}

public enum CenterFocusedColumnConfig: String, Codable, Sendable {
  case never
  case always
}

public struct WorkspacesConfig: Codable, Equatable, Sendable {
  public var names: [String]
  public var defaultName: String

  public init(
    names: [String] = (1...9).map(String.init),
    defaultName: String? = nil
  ) {
    self.names = names
    self.defaultName = defaultName ?? names.first ?? "1"
  }

  enum CodingKeys: String, CodingKey {
    case names
    case defaultName = "default"
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    names =
      try values.decodeIfPresent([String].self, forKey: .names)
      ?? (1...9).map(String.init)
    defaultName =
      try values.decodeIfPresent(String.self, forKey: .defaultName)
      ?? names.first
      ?? "1"
  }
}

public struct Rule: Codable, Equatable, Sendable {
  public var appID: String?
  public var title: String?
  public var role: String?
  public var workspace: String?
  public var followFocus: Bool
  public var floating: Bool
  public var forceTiling: Bool
  public var intrinsicSize: Bool

  public init(
    appID: String? = nil,
    title: String? = nil,
    role: String? = nil,
    workspace: String? = nil,
    followFocus: Bool = false,
    floating: Bool = false,
    forceTiling: Bool = false,
    intrinsicSize: Bool = false
  ) {
    self.appID = appID
    self.title = title
    self.role = role
    self.workspace = workspace
    self.followFocus = followFocus
    self.floating = floating
    self.forceTiling = forceTiling
    self.intrinsicSize = intrinsicSize
  }

  enum CodingKeys: String, CodingKey {
    case appID = "app_id"
    case title
    case role
    case workspace
    case followFocus = "follow_focus"
    case floating
    case forceTiling = "force_tiling"
    case intrinsicSize = "intrinsic_size"
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    appID = try values.decodeIfPresent(String.self, forKey: .appID)
    title = try values.decodeIfPresent(String.self, forKey: .title)
    role = try values.decodeIfPresent(String.self, forKey: .role)
    workspace = try values.decodeIfPresent(String.self, forKey: .workspace)
    followFocus = try values.decodeIfPresent(Bool.self, forKey: .followFocus) ?? false
    floating = try values.decodeIfPresent(Bool.self, forKey: .floating) ?? false
    forceTiling = try values.decodeIfPresent(Bool.self, forKey: .forceTiling) ?? false
    intrinsicSize = try values.decodeIfPresent(Bool.self, forKey: .intrinsicSize) ?? false
  }

  func matches(_ window: Window) -> Bool {
    if let appID {
      let candidate = appID.lowercased()
      let actual = window.appID.lowercased()
      guard
        actual == candidate
          || actual.hasSuffix(candidate)
          || candidate.hasSuffix(actual)
      else {
        return false
      }
    }
    if let title, !window.title.localizedCaseInsensitiveContains(title) {
      return false
    }
    if let role, window.role != role {
      return false
    }
    return appID != nil || title != nil || role != nil
  }
}

public struct RuleDecision: Equatable, Sendable {
  public var workspace: WorkspaceID?
  public var followFocus: Bool
  public var floating: Bool
  public var forceTiling: Bool
  public var intrinsicSize: Bool

  public init(
    workspace: WorkspaceID? = nil,
    followFocus: Bool = false,
    floating: Bool = false,
    forceTiling: Bool = false,
    intrinsicSize: Bool = false
  ) {
    self.workspace = workspace
    self.followFocus = followFocus
    self.floating = floating
    self.forceTiling = forceTiling
    self.intrinsicSize = intrinsicSize
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
  var layout: LayoutConfig?
  var animation: AnimationConfig?
  var decorations: DecorationsConfig?
  var workspaces: WorkspacesConfig?
  var modifierCombinations: [String: String]?
  var defaultKeyModifier: String?
  var keys: [String: String]?
  var rules: [Rule]?

  enum CodingKeys: String, CodingKey {
    case layout
    case animation
    case decorations
    case workspaces
    case modifierCombinations = "modifier_combinations"
    case defaultKeyModifier = "default_key_modifier"
    case keys
    case rules
  }
}
