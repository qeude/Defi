import Foundation

public enum Direction: String, Equatable, Codable, Sendable {
  case left
  case right
  case up
  case down
  case next
  case previous
  case first
  case last
}

public enum WorkspaceTarget: Equatable, Codable, Sendable {
  case relative(Direction)
  case position(Int)
  case named(String)
  case lastActive
}

public enum WindowHeightChange: Equatable, Codable, Sendable {
  /// Share of the column height, from `N%`.
  case share(Double)
  /// Change of the share, from `+N%` or `-N%`.
  case adjust(Double)
  case points(Double)
}

/// A step of the recent windows switcher, which focuses nothing until confirmed.
public enum RecentWindowsAction: String, Equatable, Codable, Sendable {
  case next
  case previous
  case confirm
  case cancel
}

public enum Command: Equatable, Codable, Sendable {
  case focusColumn(Direction)
  case focusColumnOrMonitor(Direction)
  case focusFloating(Direction)
  case moveColumn(Direction)
  case moveWindow(Direction)
  case moveColumnToMonitor(Direction)
  case moveColumnOrToMonitor(Direction)
  case moveWindowToMonitor(Direction)
  case focusWindow(Direction)
  case focusWindowOrWorkspace(Direction)
  case focusWindowPrevious
  case focusWindowID(WindowID)
  /// Presses the window's close button: the focused window, or the one named.
  case closeWindow(WindowID?)
  case recentWindows(RecentWindowsAction)
  case moveWindowToWorkspace(WorkspaceID)
  case sendWindowToWorkspace(WorkspaceID)
  case switchWorkspace(WorkspaceID)
  case focusWorkspace(WorkspaceTarget)
  case moveColumnToWorkspace(WorkspaceTarget, follow: Bool)
  case moveWindowToWorkspaceTarget(WorkspaceTarget, follow: Bool)
  case reorderWorkspace(Direction)
  case moveWorkspaceToMonitor(Direction)
  case focusMonitor(Direction)
  case cycleWidth(Direction)
  case maximizeColumn
  case setColumnWidth(ColumnWidthChange)
  case expandColumnToAvailableWidth
  case setWindowHeight(WindowHeightChange)
  case resetWindowHeight
  case switchPresetWindowHeight
  case centerColumn
  case centerVisibleColumns
  /// Pins the focused column to an edge, or returns it to the strip from that edge.
  case pinColumn(ColumnPin)
  case toggleFloating
  /// Adds the focused window to the scratchpad, or takes it out.
  case toggleScratchpadWindow
  /// Shows the scratchpad's windows on the focused monitor, or parks them.
  case toggleScratchpad
  case activateFloating
  case activateWindow
  case joinWindow(Direction)
  case unjoinWindows
  case consumeOrExpelWindow(Direction)
  case swapWindow(Direction)
  case toggleCheatsheet
  case toggleOverview
  case openSettings
  case spawnShell(String)

  var effects: CommandEffects {
    switch self {
    case .cycleWidth, .maximizeColumn, .setColumnWidth, .expandColumnToAvailableWidth:
      return CommandEffects(editsSelectedLayout: true, resizesManagedLayout: true)
    case .moveColumn, .moveWindow, .toggleFloating, .toggleScratchpadWindow:
      return CommandEffects(editsSelectedLayout: true)
    case .toggleScratchpad:
      return CommandEffects(
        resizesManagedLayout: true, explicitlyFocusesFloating: true, movesWindowsAcrossMonitors: true)
    case .pinColumn:
      return CommandEffects(editsSelectedLayout: true, resizesManagedLayout: true)
    case .joinWindow, .unjoinWindows, .consumeOrExpelWindow, .swapWindow,
      .setWindowHeight, .resetWindowHeight, .switchPresetWindowHeight:
      return CommandEffects(editsSelectedLayout: true, resizesManagedLayout: true)
    case .moveColumnToMonitor, .moveWindowToMonitor:
      return CommandEffects(
        resizesManagedLayout: true, movesWindowsAcrossMonitors: true, followsWindowMove: true)
    case .moveWorkspaceToMonitor:
      return CommandEffects(
        resizesManagedLayout: true, activatesWorkspace: true, movesWindowsAcrossMonitors: true,
        followsWindowMove: true)
    case .moveColumnToWorkspace(_, follow: true), .moveWindowToWorkspaceTarget(_, follow: true):
      return CommandEffects(
        activatesWorkspace: true, movesWindowBetweenWorkspaces: true,
        movesWindowsAcrossMonitors: true, followsWindowMove: true)
    case .moveColumnToWorkspace(_, follow: false), .moveWindowToWorkspaceTarget(_, follow: false),
      .sendWindowToWorkspace:
      return CommandEffects(
        movesWindowBetweenWorkspaces: true, movesWindowsAcrossMonitors: true)
    case .moveWindowToWorkspace:
      return CommandEffects(
        activatesWorkspace: true, movesWindowBetweenWorkspaces: true,
        movesWindowsAcrossMonitors: true, followsWindowMove: true)
    case .switchWorkspace, .focusWorkspace, .focusWindowID, .focusMonitor:
      return CommandEffects(activatesWorkspace: true)
    case .activateFloating, .focusFloating:
      return CommandEffects(explicitlyFocusesFloating: true)
    case .focusColumn, .focusColumnOrMonitor, .moveColumnOrToMonitor, .focusWindow,
      .focusWindowOrWorkspace, .focusWindowPrevious, .recentWindows, .centerColumn,
      .centerVisibleColumns, .activateWindow, .reorderWorkspace, .toggleCheatsheet,
      .toggleOverview, .openSettings, .spawnShell, .closeWindow:
      return CommandEffects()
    }
  }

  public var editsSelectedLayout: Bool { effects.editsSelectedLayout }
  public var animatesManagedLayout: Bool { effects.editsSelectedLayout || effects.resizesManagedLayout }
  public var activatesWorkspace: Bool { effects.activatesWorkspace }
  public var movesWindowBetweenWorkspaces: Bool { effects.movesWindowBetweenWorkspaces }
  public var explicitlyFocusesFloating: Bool { effects.explicitlyFocusesFloating }
  public var movesWindowsAcrossMonitors: Bool { effects.movesWindowsAcrossMonitors }
  public var followsWindowMove: Bool { effects.followsWindowMove }
}

/// What a layout command changes. One exhaustive switch in `Command.effects` owns this, so a new
/// case fails the build instead of silently reading false.
struct CommandEffects: Equatable, Sendable {
  let editsSelectedLayout: Bool
  let resizesManagedLayout: Bool
  let activatesWorkspace: Bool
  let movesWindowBetweenWorkspaces: Bool
  let explicitlyFocusesFloating: Bool
  let movesWindowsAcrossMonitors: Bool
  let followsWindowMove: Bool

  init(
    editsSelectedLayout: Bool = false,
    resizesManagedLayout: Bool = false,
    activatesWorkspace: Bool = false,
    movesWindowBetweenWorkspaces: Bool = false,
    explicitlyFocusesFloating: Bool = false,
    movesWindowsAcrossMonitors: Bool = false,
    followsWindowMove: Bool = false
  ) {
    self.editsSelectedLayout = editsSelectedLayout
    self.resizesManagedLayout = resizesManagedLayout
    self.activatesWorkspace = activatesWorkspace
    self.movesWindowBetweenWorkspaces = movesWindowBetweenWorkspaces
    self.explicitlyFocusesFloating = explicitlyFocusesFloating
    self.movesWindowsAcrossMonitors = movesWindowsAcrossMonitors
    self.followsWindowMove = followsWindowMove
  }
}
