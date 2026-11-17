public enum CenterFocusedColumn: String, Codable, Equatable, Sendable {
  case never
  case always
  case onOverflow = "on-overflow"
}

/// The layout input DefiCore lays out with. Defaults live here so Config and Core agree.
public struct LayoutSettings: Equatable, Sendable {
  public var defaultColumnWidth: Double
  public var presetColumnWidths: [Double]
  public var presetWindowHeights: [Double]
  public var centerFocusedColumn: CenterFocusedColumn
  public var alwaysCenterSingleColumn: Bool
  public var innerHorizontalGap: Double
  public var innerVerticalGap: Double
  public var outerTopGap: Double
  public var outerRightGap: Double
  public var outerBottomGap: Double
  public var outerLeftGap: Double

  public init(
    defaultColumnWidth: Double = 0.80,
    presetColumnWidths: [Double] = [0.33, 0.50, 0.66, 0.80],
    presetWindowHeights: [Double] = [0.33, 0.50, 0.66],
    centerFocusedColumn: CenterFocusedColumn = .never,
    alwaysCenterSingleColumn: Bool = false,
    innerHorizontalGap: Double = 4,
    innerVerticalGap: Double = 4,
    outerTopGap: Double = 8,
    outerRightGap: Double = 8,
    outerBottomGap: Double = 8,
    outerLeftGap: Double = 8
  ) {
    self.defaultColumnWidth = defaultColumnWidth
    self.presetColumnWidths = presetColumnWidths
    self.presetWindowHeights = presetWindowHeights
    self.centerFocusedColumn = centerFocusedColumn
    self.alwaysCenterSingleColumn = alwaysCenterSingleColumn
    self.innerHorizontalGap = innerHorizontalGap
    self.innerVerticalGap = innerVerticalGap
    self.outerTopGap = outerTopGap
    self.outerRightGap = outerRightGap
    self.outerBottomGap = outerBottomGap
    self.outerLeftGap = outerLeftGap
  }
}
