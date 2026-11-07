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

/// The selected window a scroll target was last resolved for, and whether it
/// overflowed the screen together with the previous selection when it became selected.
public struct ScrollFocus: Equatable, Codable, Sendable {
  public var windowID: WindowID
  public var centered: Bool
  /// `true` after `center-column`, until selection leaves the column. Never `false`:
  /// optional so stores written before it existed still decode.
  public var pinned: Bool?
  /// `true` where an unsnapped swipe left the strip, until selection leaves the column:
  /// the strip stays put while the column is in view. Never `false`, like `pinned`.
  public var free: Bool?
  /// Where `center-visible-columns` left the strip. The strip rests there while the
  /// selected column is fully in view; a selected column outside it drops the offset.
  public var heldOffset: Double?

  public init(
    windowID: WindowID, centered: Bool, pinned: Bool? = nil, free: Bool? = nil,
    heldOffset: Double? = nil
  ) {
    self.windowID = windowID
    self.centered = centered
    self.pinned = pinned
    self.free = free
    self.heldOffset = heldOffset
  }
}

public struct Workspace: Equatable, Codable, Sendable {
  public let id: WorkspaceID
  public var kind: WorkspaceKind
  public var name: String?
  public var affinity: MonitorID?
  public var affinityPosition: Int
  public var columns: [Column]
  public var floatingWindows: [WindowID]
  public var focusedFloatingWindow: Int
  public var focusedLayer: WindowFocusLayer
  public var focusedColumn: Int
  public var scrollOffset: Double
  public var targetScrollOffset: Double
  public var scrollFocus: ScrollFocus? = nil

  public init(
    id: WorkspaceID,
    kind: WorkspaceKind = .named,
    name: String? = nil,
    affinity: MonitorID? = nil,
    affinityPosition: Int = 0,
    columns: [Column] = [],
    floatingWindows: [WindowID] = [],
    focusedFloatingWindow: Int = 0,
    focusedLayer: WindowFocusLayer = .tiled,
    focusedColumn: Int = 0,
    scrollOffset: Double = 0,
    targetScrollOffset: Double = 0
  ) {
    self.id = id
    self.kind = kind
    self.name = name ?? (kind == .named ? id.rawValue : nil)
    self.affinity = affinity
    self.affinityPosition = affinityPosition
    self.columns = columns
    self.floatingWindows = floatingWindows
    self.focusedFloatingWindow = focusedFloatingWindow
    self.focusedLayer = focusedLayer
    self.focusedColumn = focusedColumn
    self.scrollOffset = scrollOffset
    self.targetScrollOffset = targetScrollOffset
  }

  public var isEmpty: Bool {
    columns.isEmpty && floatingWindows.isEmpty
  }

}

public enum WorkspaceKind: String, Equatable, Codable, Sendable {
  case named
  case ordinary
  case trailing
}

public enum WindowFocusLayer: String, Equatable, Codable, Sendable {
  case tiled
  case floating
}
