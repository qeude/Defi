import Foundation

public struct Column: Equatable, Codable, Sendable {
  public var windows: [WindowID]
  public var focusedWindow: Int
  public var width: ColumnWidth
  public var preMaximizedWidth: ColumnWidth?

  public init(
    window: WindowID,
    width: ColumnWidth,
    focusedWindow: Int = 0,
    preMaximizedWidth: ColumnWidth? = nil
  ) {
    self.windows = [window]
    self.focusedWindow = focusedWindow
    self.width = width
    self.preMaximizedWidth = preMaximizedWidth
  }

  public init(
    windows: [WindowID],
    focusedWindow: Int,
    width: ColumnWidth,
    preMaximizedWidth: ColumnWidth? = nil
  ) {
    self.windows = windows
    self.focusedWindow = focusedWindow
    self.width = width
    self.preMaximizedWidth = preMaximizedWidth
  }
}

public struct Workspace: Equatable, Codable, Sendable {
  public let id: WorkspaceID
  public var columns: [Column]
  public var floatingWindows: [WindowID]
  public var focusedFloatingWindow: Int
  public var focusedLayer: WindowFocusLayer
  public var focusedColumn: Int
  public var scrollOffset: Double
  public var targetScrollOffset: Double

  public init(
    id: WorkspaceID,
    columns: [Column] = [],
    floatingWindows: [WindowID] = [],
    focusedFloatingWindow: Int = 0,
    focusedLayer: WindowFocusLayer = .tiled,
    focusedColumn: Int = 0,
    scrollOffset: Double = 0,
    targetScrollOffset: Double = 0
  ) {
    self.id = id
    self.columns = columns
    self.floatingWindows = floatingWindows
    self.focusedFloatingWindow = focusedFloatingWindow
    self.focusedLayer = focusedLayer
    self.focusedColumn = focusedColumn
    self.scrollOffset = scrollOffset
    self.targetScrollOffset = targetScrollOffset
  }
}

public enum WindowFocusLayer: String, Equatable, Codable, Sendable {
  case tiled
  case floating
}
