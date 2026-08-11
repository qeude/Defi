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

public enum Command: Equatable, Codable, Sendable {
  case focusColumn(Direction)
  case focusFloating(Direction)
  case moveColumn(Direction)
  case moveWindow(Direction)
  case focusWindow(Direction)
  case moveWindowToWorkspace(WorkspaceID)
  case sendWindowToWorkspace(WorkspaceID)
  case switchWorkspace(WorkspaceID)
  case cycleWidth(Direction)
  case maximizeColumn
  case toggleFloating
  case activateFloating
  case joinWindow(Direction)
  case unjoinWindows
  case runStartupCommands

  public var resizesManagedLayout: Bool {
    switch self {
    case .cycleWidth, .maximizeColumn, .joinWindow, .unjoinWindows:
      true
    default:
      false
    }
  }

  public var activatesWorkspace: Bool {
    switch self {
    case .switchWorkspace, .moveWindowToWorkspace:
      true
    default:
      false
    }
  }

  public var movesWindowBetweenWorkspaces: Bool {
    switch self {
    case .moveWindowToWorkspace, .sendWindowToWorkspace:
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
}
