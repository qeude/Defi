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
}

public enum Command: Equatable, Codable, Sendable {
  case focusColumn(Direction)
  case focusFloating(Direction)
  case moveColumn(Direction)
  case moveWindow(Direction)
  case moveColumnToMonitor(Direction)
  case moveWindowToMonitor(Direction)
  case focusWindow(Direction)
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
  case toggleFloating
  case activateFloating
  case joinWindow(Direction)
  case unjoinWindows
  case toggleOverview
  case runStartupCommands

  public var resizesManagedLayout: Bool {
    switch self {
    case .cycleWidth, .maximizeColumn, .joinWindow, .unjoinWindows,
      .moveColumnToMonitor, .moveWindowToMonitor, .moveWorkspaceToMonitor:
      true
    default:
      false
    }
  }

  public var activatesWorkspace: Bool {
    switch self {
    case .switchWorkspace, .moveWindowToWorkspace, .focusWorkspace,
      .moveColumnToWorkspace(_, follow: true),
      .moveWindowToWorkspaceTarget(_, follow: true), .moveWorkspaceToMonitor,
      .focusMonitor:
      true
    default:
      false
    }
  }

  public var movesWindowBetweenWorkspaces: Bool {
    switch self {
    case .moveWindowToWorkspace, .sendWindowToWorkspace,
      .moveColumnToWorkspace, .moveWindowToWorkspaceTarget:
      true
    default:
      false
    }
  }

  public var explicitlyFocusesFloating: Bool {
    switch self {
    case .activateFloating, .focusFloating:
      true
    default:
      false
    }
  }

  public var movesWindowsAcrossMonitors: Bool {
    switch self {
    case .moveColumnToMonitor, .moveWindowToMonitor, .moveWorkspaceToMonitor,
      .moveWindowToWorkspace, .sendWindowToWorkspace,
      .moveColumnToWorkspace, .moveWindowToWorkspaceTarget:
      true
    default:
      false
    }
  }

  public var followsWindowMove: Bool {
    switch self {
    case .moveColumnToMonitor, .moveWindowToMonitor, .moveWindowToWorkspace,
      .moveColumnToWorkspace(_, follow: true),
      .moveWindowToWorkspaceTarget(_, follow: true), .moveWorkspaceToMonitor:
      true
    default:
      false
    }
  }
}
