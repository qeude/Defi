import DefiModel

public let parkedSliverWidth = 1.0

public enum CenterFocusedColumn: Equatable, Sendable {
  case never
  case always
}

public struct LayoutSettings: Equatable, Sendable {
  public var defaultColumnWidth: Double
  public var presetColumnWidths: [Double]
  public var centerFocusedColumn: CenterFocusedColumn
  public var innerHorizontalGap: Double
  public var innerVerticalGap: Double
  public var outerTopGap: Double
  public var outerRightGap: Double
  public var outerBottomGap: Double
  public var outerLeftGap: Double
  public var horizontalViewportPadding: Double

  public init(
    defaultColumnWidth: Double = 0.80,
    presetColumnWidths: [Double] = [0.33, 0.50, 0.66, 0.80],
    centerFocusedColumn: CenterFocusedColumn = .never,
    innerHorizontalGap: Double = 4,
    innerVerticalGap: Double = 4,
    outerTopGap: Double = 8,
    outerRightGap: Double = 8,
    outerBottomGap: Double = 8,
    outerLeftGap: Double = 8,
    horizontalViewportPadding: Double = 0
  ) {
    self.defaultColumnWidth = defaultColumnWidth
    self.presetColumnWidths = presetColumnWidths
    self.centerFocusedColumn = centerFocusedColumn
    self.innerHorizontalGap = innerHorizontalGap
    self.innerVerticalGap = innerVerticalGap
    self.outerTopGap = outerTopGap
    self.outerRightGap = outerRightGap
    self.outerBottomGap = outerBottomGap
    self.outerLeftGap = outerLeftGap
    self.horizontalViewportPadding = horizontalViewportPadding
  }
}

public struct FrameAssignment: Equatable, Sendable {
  public let windowID: WindowID
  public let frame: Rect

  public init(windowID: WindowID, frame: Rect) {
    self.windowID = windowID
    self.frame = frame
  }
}

public enum LayoutError: Error, Equatable, Sendable {
  case emptyWorkspace
  case unsupportedDirection
  case focusOutOfBounds
}
