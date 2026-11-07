import DefiModel
import Foundation
import TOMLDecoder

public struct InputConfig: Codable, Equatable, Sendable {
  public var focusFollowsMouse: Bool
  public var focusFollowsMouseMaxScrollAmount: Double?
  public var focusFollowsMouseDelayMS: Int
  public var mouseFollowsFocus: Bool
  public var scrollGestures: Bool
  /// Held to scroll the strip; nil uses the `[keys]` modifier, "none" holds nothing.
  public var scrollGestureModifier: String?
  /// Fingers that swipe the strip: two scroll, three or four swipe.
  public var scrollGestureFingers: Int
  /// Multiplies how far the strip moves for the same finger travel.
  public var scrollGestureSpeed: Double
  /// Whether a released swipe rests on a column as a key press would place it.
  public var scrollGestureSnap: Bool

  public init(
    focusFollowsMouse: Bool = false,
    focusFollowsMouseMaxScrollAmount: Double? = 0,
    focusFollowsMouseDelayMS: Int = 50,
    mouseFollowsFocus: Bool = false,
    scrollGestures: Bool = false,
    scrollGestureModifier: String? = nil,
    scrollGestureFingers: Int = 2,
    scrollGestureSpeed: Double = 1,
    scrollGestureSnap: Bool = true
  ) {
    self.focusFollowsMouse = focusFollowsMouse
    self.focusFollowsMouseMaxScrollAmount = focusFollowsMouseMaxScrollAmount
    self.focusFollowsMouseDelayMS = focusFollowsMouseDelayMS
    self.mouseFollowsFocus = mouseFollowsFocus
    self.scrollGestures = scrollGestures
    self.scrollGestureModifier = scrollGestureModifier
    self.scrollGestureFingers = scrollGestureFingers
    self.scrollGestureSpeed = scrollGestureSpeed
    self.scrollGestureSnap = scrollGestureSnap
  }

  enum CodingKeys: String, CodingKey {
    case focusFollowsMouse = "focus_follows_mouse"
    case focusFollowsMouseMaxScrollAmount =
      "focus_follows_mouse_max_scroll_amount"
    case focusFollowsMouseDelayMS = "focus_follows_mouse_delay_ms"
    case mouseFollowsFocus = "mouse_follows_focus"
    case scrollGestures = "scroll_gestures"
    case scrollGestureModifier = "scroll_gesture_modifier"
    case scrollGestureFingers = "scroll_gesture_fingers"
    case scrollGestureSpeed = "scroll_gesture_speed"
    case scrollGestureSnap = "scroll_gesture_snap"
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = InputConfig()
    focusFollowsMouse =
      try values.decodeIfPresent(Bool.self, forKey: .focusFollowsMouse) ?? defaults.focusFollowsMouse
    focusFollowsMouseMaxScrollAmount =
      try values.decodeIfPresent(
        Double.self,
        forKey: .focusFollowsMouseMaxScrollAmount
      ) ?? defaults.focusFollowsMouseMaxScrollAmount
    focusFollowsMouseDelayMS =
      try values.decodeIfPresent(Int.self, forKey: .focusFollowsMouseDelayMS)
      ?? defaults.focusFollowsMouseDelayMS
    mouseFollowsFocus =
      try values.decodeIfPresent(Bool.self, forKey: .mouseFollowsFocus) ?? defaults.mouseFollowsFocus
    scrollGestures =
      try values.decodeIfPresent(Bool.self, forKey: .scrollGestures) ?? defaults.scrollGestures
    scrollGestureModifier = try values.decodeIfPresent(String.self, forKey: .scrollGestureModifier)
    scrollGestureFingers =
      try values.decodeIfPresent(Int.self, forKey: .scrollGestureFingers) ?? defaults.scrollGestureFingers
    scrollGestureSpeed =
      try values.decodeIfPresent(Double.self, forKey: .scrollGestureSpeed) ?? defaults.scrollGestureSpeed
    scrollGestureSnap =
      try values.decodeIfPresent(Bool.self, forKey: .scrollGestureSnap) ?? defaults.scrollGestureSnap
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
  /// Spring stiffness for a unit mass: higher moves faster.
  public var stiffness: Double
  /// 1 is critically damped; below 1 the motion arrives sooner and overshoots slightly.
  public var dampingRatio: Double

  public init(enabled: Bool = true, stiffness: Double = 800, dampingRatio: Double = 0.9) {
    self.enabled = enabled
    self.stiffness = stiffness
    self.dampingRatio = dampingRatio
  }

  enum CodingKeys: String, CodingKey {
    case enabled
    case stiffness
    case dampingRatio = "damping_ratio"
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = AnimationConfig()
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
    stiffness = try values.decodeIfPresent(Double.self, forKey: .stiffness) ?? defaults.stiffness
    dampingRatio =
      try values.decodeIfPresent(Double.self, forKey: .dampingRatio) ?? defaults.dampingRatio
  }
}

public struct OverviewConfig: Codable, Equatable, Sendable {
  public var zoom: Double
  public var windowPreviews: Bool
  public var windowCornerRadius: Double

  public init(
    zoom: Double = 0.5,
    windowPreviews: Bool = true,
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
    let defaults = OverviewConfig()
    zoom = try values.decodeIfPresent(Double.self, forKey: .zoom) ?? defaults.zoom
    windowPreviews =
      try values.decodeIfPresent(Bool.self, forKey: .windowPreviews) ?? defaults.windowPreviews
    windowCornerRadius =
      try values.decodeIfPresent(Double.self, forKey: .windowCornerRadius) ?? defaults.windowCornerRadius
  }
}

public struct LayoutConfig: Codable, Equatable, Sendable {
  public var defaultColumnWidth: Double
  public var presetColumnWidths: [Double]
  public var presetWindowHeights: [Double]
  public var centerFocusedColumn: CenterFocusedColumnConfig
  public var alwaysCenterSingleColumn: Bool
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
    presetWindowHeights: [Double] = [0.33, 0.50, 0.66],
    centerFocusedColumn: CenterFocusedColumnConfig = .never,
    alwaysCenterSingleColumn: Bool = false,
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
    self.presetWindowHeights = presetWindowHeights
    self.centerFocusedColumn = centerFocusedColumn
    self.alwaysCenterSingleColumn = alwaysCenterSingleColumn
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
    case presetWindowHeights = "preset_window_heights"
    case centerFocusedColumn = "center_focused_column"
    case alwaysCenterSingleColumn = "always_center_single_column"
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
    let defaults = LayoutConfig()
    defaultColumnWidth =
      try values.decodeIfPresent(Double.self, forKey: .defaultColumnWidth) ?? defaults.defaultColumnWidth
    presetColumnWidths =
      try values.decodeIfPresent([Double].self, forKey: .presetColumnWidths)
      ?? defaults.presetColumnWidths
    presetWindowHeights =
      try values.decodeIfPresent([Double].self, forKey: .presetWindowHeights)
      ?? defaults.presetWindowHeights
    centerFocusedColumn =
      try values.decodeIfPresent(
        CenterFocusedColumnConfig.self,
        forKey: .centerFocusedColumn
      ) ?? defaults.centerFocusedColumn
    alwaysCenterSingleColumn =
      try values.decodeIfPresent(Bool.self, forKey: .alwaysCenterSingleColumn)
      ?? defaults.alwaysCenterSingleColumn
    gaps = try values.decodeIfPresent(Double.self, forKey: .gaps) ?? defaults.gaps
    outerTopGap = try values.decodeIfPresent(Double.self, forKey: .outerTopGap)
    outerRightGap = try values.decodeIfPresent(Double.self, forKey: .outerRightGap)
    outerBottomGap = try values.decodeIfPresent(Double.self, forKey: .outerBottomGap)
    outerLeftGap = try values.decodeIfPresent(Double.self, forKey: .outerLeftGap)
    reservedTop = try values.decodeIfPresent(Double.self, forKey: .reservedTop) ?? defaults.reservedTop
    reservedBottom = try values.decodeIfPresent(Double.self, forKey: .reservedBottom) ?? defaults.reservedBottom
  }
}

public enum WorkspaceLabelStyle: String, Codable, CaseIterable, Sendable {
  case name
  case icon
  case iconAndName = "icon_and_name"
}

public struct MenuBarConfig: Codable, Equatable, Sendable {
  public var enabled: Bool

  public var workspaceStyle: WorkspaceLabelStyle

  public init(enabled: Bool = true, workspaceStyle: WorkspaceLabelStyle = .name) {
    self.enabled = enabled
    self.workspaceStyle = workspaceStyle
  }

  enum CodingKeys: String, CodingKey {
    case enabled
    case workspaceStyle = "workspace_style"
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = MenuBarConfig()
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
    workspaceStyle = try values.decodeIfPresent(WorkspaceLabelStyle.self, forKey: .workspaceStyle) ?? defaults.workspaceStyle
  }
}

public enum CenterFocusedColumnConfig: String, Codable, Sendable {
  case never
  case always
  case onOverflow = "on-overflow"
}

public struct WorkspacesConfig: Codable, Equatable, Sendable {
  public var icons: [String: String]
  public var names: [String]
  public var defaultName: String?
  public var monitors: [String: Int]
  public var monitorIDs: [String: String]

  public init(
    names: [String] = [],
    icons: [String: String] = [:],
    defaultName: String? = nil,
    monitors: [String: Int] = [:],
    monitorIDs: [String: String] = [:]
  ) {
    self.icons = icons
    self.names = names
    self.defaultName = defaultName ?? names.first
    self.monitors = monitors
    self.monitorIDs = monitorIDs
  }

  enum CodingKeys: String, CodingKey {
    case icons
    case names
    case defaultName = "default"
    case monitors
    case monitorIDs = "monitor_ids"
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = WorkspacesConfig()
    icons = try values.decodeIfPresent([String: String].self, forKey: .icons) ?? defaults.icons
    names =
      try values.decodeIfPresent([String].self, forKey: .names)
      ?? defaults.names
    defaultName =
      try values.decodeIfPresent(String.self, forKey: .defaultName)
      ?? names.first
    monitors =
      try values.decodeIfPresent([String: Int].self, forKey: .monitors)
      ?? defaults.monitors
    monitorIDs =
      try values.decodeIfPresent([String: String].self, forKey: .monitorIDs)
      ?? defaults.monitorIDs
  }
}

/// How a rule places matching windows.
public enum RuleWindow: String, Codable, Equatable, Sendable, CaseIterable {
  case forceFloating = "force-floating"
  /// Tiles even windows that automatic classification would float or ignore.
  case forceTiled = "force-tiled"
}

public struct Rule: Codable, Equatable, Sendable {
  public var appID: String?
  public var title: String?
  public var role: String?
  public var workspace: String?
  public var followFocus: Bool
  public var window: RuleWindow?
  public var intrinsicSize: Bool
  public var initialColumnWidth: Double?
  public var includeInitialWidthInCycle: Bool

  public init(
    appID: String? = nil,
    title: String? = nil,
    role: String? = nil,
    workspace: String? = nil,
    followFocus: Bool = false,
    window: RuleWindow? = nil,
    intrinsicSize: Bool = false,
    initialColumnWidth: Double? = nil,
    includeInitialWidthInCycle: Bool = false
  ) {
    self.appID = appID
    self.title = title
    self.role = role
    self.workspace = workspace
    self.followFocus = followFocus
    self.window = window
    self.intrinsicSize = intrinsicSize
    self.initialColumnWidth = initialColumnWidth
    self.includeInitialWidthInCycle = includeInitialWidthInCycle
  }

  enum CodingKeys: String, CodingKey {
    case appID = "app_id"
    case title
    case role
    case workspace
    case followFocus = "follow_focus"
    case window
    case intrinsicSize = "intrinsic_size"
    case initialColumnWidth = "initial_column_width"
    case includeInitialWidthInCycle = "include_initial_width_in_cycle"
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Rule()
    appID = try values.decodeIfPresent(String.self, forKey: .appID)
    title = try values.decodeIfPresent(String.self, forKey: .title)
    role = try values.decodeIfPresent(String.self, forKey: .role)
    workspace = try values.decodeIfPresent(String.self, forKey: .workspace)
    followFocus = try values.decodeIfPresent(Bool.self, forKey: .followFocus) ?? defaults.followFocus
    window = try values.decodeIfPresent(RuleWindow.self, forKey: .window)
    intrinsicSize = try values.decodeIfPresent(Bool.self, forKey: .intrinsicSize) ?? defaults.intrinsicSize
    initialColumnWidth = try values.decodeIfPresent(Double.self, forKey: .initialColumnWidth)
    includeInitialWidthInCycle =
      try values.decodeIfPresent(Bool.self, forKey: .includeInitialWidthInCycle) ?? false
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
  public var initialColumnWidth: Double?
  public var includeInitialWidthInCycle: Bool

  public init(
    workspace: WorkspaceID? = nil,
    followFocus: Bool = false,
    floating: Bool = false,
    forceTiling: Bool = false,
    intrinsicSize: Bool = false,
    initialColumnWidth: Double? = nil,
    includeInitialWidthInCycle: Bool = false
  ) {
    self.workspace = workspace
    self.followFocus = followFocus
    self.floating = floating
    self.forceTiling = forceTiling
    self.intrinsicSize = intrinsicSize
    self.initialColumnWidth = initialColumnWidth
    self.includeInitialWidthInCycle = includeInitialWidthInCycle
  }
}
