import DefiModel
import Foundation
import TOMLDecoder

public struct InputConfig: Codable, Equatable, Sendable {
  public var focusFollowsMouse: Bool
  public var focusFollowsMouseMaxScrollAmount: Double?
  public var mouseFollowsFocus: Bool

  public init(
    focusFollowsMouse: Bool = false,
    focusFollowsMouseMaxScrollAmount: Double? = 0,
    mouseFollowsFocus: Bool = false
  ) {
    self.focusFollowsMouse = focusFollowsMouse
    self.focusFollowsMouseMaxScrollAmount = focusFollowsMouseMaxScrollAmount
    self.mouseFollowsFocus = mouseFollowsFocus
  }

  enum CodingKeys: String, CodingKey {
    case focusFollowsMouse = "focus_follows_mouse"
    case focusFollowsMouseMaxScrollAmount =
      "focus_follows_mouse_max_scroll_amount"
    case mouseFollowsFocus = "mouse_follows_focus"
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    focusFollowsMouse =
      try values.decodeIfPresent(Bool.self, forKey: .focusFollowsMouse) ?? false
    focusFollowsMouseMaxScrollAmount =
      try values.decodeIfPresent(
        Double.self,
        forKey: .focusFollowsMouseMaxScrollAmount
      ) ?? 0
    mouseFollowsFocus =
      try values.decodeIfPresent(Bool.self, forKey: .mouseFollowsFocus) ?? false
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
  public var placement: String

  public init(
    enabled: Bool = true,
    width: Double = 4,
    color: String = "#FFC099FF",
    inactiveEnabled: Bool = false,
    inactiveColor: String = "#66C099FF",
    captureEnabled: Bool = false,
    placement: String = "outside"
  ) {
    self.enabled = enabled
    self.width = width
    self.color = color
    self.inactiveEnabled = inactiveEnabled
    self.inactiveColor = inactiveColor
    self.captureEnabled = captureEnabled
    self.placement = placement
  }

  enum CodingKeys: String, CodingKey {
    case enabled
    case width
    case color
    case inactiveEnabled = "inactive_enabled"
    case inactiveColor = "inactive_color"
    case captureEnabled = "capture_enabled"
    case placement
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
    placement =
      try values.decodeIfPresent(String.self, forKey: .placement)
      ?? defaults.placement
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

public struct OverviewConfig: Codable, Equatable, Sendable {
  public var zoom: Double
  public var windowPreviews: Bool
  public var windowCornerRadius: Double

  public init(
    zoom: Double = 0.5,
    windowPreviews: Bool = false,
    windowCornerRadius: Double = 12
  ) {
    self.zoom = zoom
    self.windowPreviews = windowPreviews
    self.windowCornerRadius = windowCornerRadius
  }

  enum CodingKeys: String, CodingKey {
    case zoom
    case windowPreviews = "window_previews"
    case windowCornerRadius = "window_corner_radius"
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    zoom = try values.decodeIfPresent(Double.self, forKey: .zoom) ?? 0.5
    windowPreviews =
      try values.decodeIfPresent(Bool.self, forKey: .windowPreviews) ?? false
    windowCornerRadius =
      try values.decodeIfPresent(Double.self, forKey: .windowCornerRadius) ?? 12
  }
}

public struct LayoutConfig: Codable, Equatable, Sendable {
  public var defaultColumnWidth: Double
  public var presetColumnWidths: [Double]
  public var centerFocusedColumn: CenterFocusedColumnConfig
  public var gaps: Double
  public var outerTopGap: Double?
  public var outerRightGap: Double?
  public var outerBottomGap: Double?
  public var outerLeftGap: Double?
  public var reservedTop: Double
  public var reservedBottom: Double

  public init(
    defaultColumnWidth: Double = 0.80,
    presetColumnWidths: [Double] = [0.33, 0.50, 0.66, 0.80],
    centerFocusedColumn: CenterFocusedColumnConfig = .never,
    gaps: Double = 8,
    outerTopGap: Double? = nil,
    outerRightGap: Double? = nil,
    outerBottomGap: Double? = nil,
    outerLeftGap: Double? = nil,
    reservedTop: Double = 0,
    reservedBottom: Double = 0
  ) {
    self.defaultColumnWidth = defaultColumnWidth
    self.presetColumnWidths = presetColumnWidths
    self.centerFocusedColumn = centerFocusedColumn
    self.gaps = gaps
    self.outerTopGap = outerTopGap
    self.outerRightGap = outerRightGap
    self.outerBottomGap = outerBottomGap
    self.outerLeftGap = outerLeftGap
    self.reservedTop = reservedTop
    self.reservedBottom = reservedBottom
  }

  enum CodingKeys: String, CodingKey {
    case defaultColumnWidth = "default_column_width"
    case presetColumnWidths = "preset_column_widths"
    case centerFocusedColumn = "center_focused_column"
    case gaps
    case outerTopGap = "outer_top_gap"
    case outerRightGap = "outer_right_gap"
    case outerBottomGap = "outer_bottom_gap"
    case outerLeftGap = "outer_left_gap"
    case reservedTop = "reserved_top"
    case reservedBottom = "reserved_bottom"
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
    outerTopGap = try values.decodeIfPresent(Double.self, forKey: .outerTopGap)
    outerRightGap = try values.decodeIfPresent(Double.self, forKey: .outerRightGap)
    outerBottomGap = try values.decodeIfPresent(Double.self, forKey: .outerBottomGap)
    outerLeftGap = try values.decodeIfPresent(Double.self, forKey: .outerLeftGap)
    reservedTop = try values.decodeIfPresent(Double.self, forKey: .reservedTop) ?? 0
    reservedBottom = try values.decodeIfPresent(Double.self, forKey: .reservedBottom) ?? 0
  }
}

public struct MenuBarConfig: Codable, Equatable, Sendable {
  public var enabled: Bool

  public init(enabled: Bool = true) {
    self.enabled = enabled
  }

  enum CodingKeys: String, CodingKey {
    case enabled
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
  }
}

public enum CenterFocusedColumnConfig: String, Codable, Sendable {
  case never
  case always
}

public struct WorkspacesConfig: Codable, Equatable, Sendable {
  public var names: [String]
  public var defaultName: String?
  public var monitors: [String: Int]

  public init(
    names: [String] = [],
    defaultName: String? = nil,
    monitors: [String: Int] = [:]
  ) {
    self.names = names
    self.defaultName = defaultName ?? names.first
    self.monitors = monitors
  }

  enum CodingKeys: String, CodingKey {
    case names
    case defaultName = "default"
    case monitors
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    names =
      try values.decodeIfPresent([String].self, forKey: .names)
      ?? []
    defaultName =
      try values.decodeIfPresent(String.self, forKey: .defaultName)
      ?? names.first
    monitors =
      try values.decodeIfPresent([String: Int].self, forKey: .monitors)
      ?? [:]
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

  func matches(appID actualAppID: String, title actualTitle: String, role actualRole: String?)
    -> Bool
  {
    if let appID {
      let candidate = appID.lowercased()
      let actual = actualAppID.lowercased()
      guard
        actual == candidate
          || actual.hasSuffix(candidate)
          || candidate.hasSuffix(actual)
      else {
        return false
      }
    }
    if let title, !actualTitle.localizedCaseInsensitiveContains(title) {
      return false
    }
    if let role, actualRole != role {
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
