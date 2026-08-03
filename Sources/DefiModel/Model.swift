import Foundation

public struct WindowID: RawRepresentable, Hashable, Codable, Sendable {
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }
}

public struct WorkspaceID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }
}

public struct MonitorID: RawRepresentable, Hashable, Codable, Sendable {
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }
}

public struct Rect: Hashable, Codable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public struct Window: Equatable, Codable, Sendable {
  public let id: WindowID
  public var appID: String
  public var title: String
  public var role: String?
  public var subrole: String?
  public var processID: Int32?
  public var monitorID: MonitorID?
  public var frame: Rect
  public var floating: Bool
  public var forceTiling: Bool
  public var intrinsicSize: Bool

  public init(
    id: WindowID,
    appID: String,
    title: String,
    frame: Rect,
    role: String? = nil,
    subrole: String? = nil,
    processID: Int32? = nil,
    monitorID: MonitorID? = nil,
    floating: Bool = false,
    forceTiling: Bool = false,
    intrinsicSize: Bool = false
  ) {
    self.id = id
    self.appID = appID
    self.title = title
    self.role = role
    self.subrole = subrole
    self.processID = processID
    self.monitorID = monitorID
    self.frame = frame
    self.floating = floating
    self.forceTiling = forceTiling
    self.intrinsicSize = intrinsicSize
  }
}

public enum ColumnWidth: Equatable, Codable, Sendable {
  case fraction(Double)
  case pixels(Double)
}

public struct Column: Equatable, Codable, Sendable {
  public var windows: [WindowID]
  public var focusedWindow: Int
  public var width: ColumnWidth
  public var fullscreenPreviousWidth: ColumnWidth?

  public init(
    window: WindowID,
    width: ColumnWidth,
    focusedWindow: Int = 0,
    fullscreenPreviousWidth: ColumnWidth? = nil
  ) {
    self.windows = [window]
    self.focusedWindow = focusedWindow
    self.width = width
    self.fullscreenPreviousWidth = fullscreenPreviousWidth
  }

  public init(
    windows: [WindowID],
    focusedWindow: Int,
    width: ColumnWidth,
    fullscreenPreviousWidth: ColumnWidth? = nil
  ) {
    self.windows = windows
    self.focusedWindow = focusedWindow
    self.width = width
    self.fullscreenPreviousWidth = fullscreenPreviousWidth
  }
}

public struct Workspace: Equatable, Codable, Sendable {
  public let id: WorkspaceID
  public var columns: [Column]
  public var floatingWindows: [WindowID]
  public var focusedFloatingWindow: Int
  public var focusedColumn: Int
  public var scrollOffset: Double
  public var targetScrollOffset: Double

  public init(
    id: WorkspaceID,
    columns: [Column] = [],
    floatingWindows: [WindowID] = [],
    focusedFloatingWindow: Int = 0,
    focusedColumn: Int = 0,
    scrollOffset: Double = 0,
    targetScrollOffset: Double = 0
  ) {
    self.id = id
    self.columns = columns
    self.floatingWindows = floatingWindows
    self.focusedFloatingWindow = focusedFloatingWindow
    self.focusedColumn = focusedColumn
    self.scrollOffset = scrollOffset
    self.targetScrollOffset = targetScrollOffset
  }
}

public struct Monitor: Equatable, Codable, Sendable {
  public let id: MonitorID
  public var workspaces: [Workspace]
  public var activeWorkspace: WorkspaceID

  public init(id: MonitorID, workspaces: [Workspace], activeWorkspace: WorkspaceID) {
    self.id = id
    self.workspaces = workspaces
    self.activeWorkspace = activeWorkspace
  }
}

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
  case toggleFullscreen
  case toggleFloating
  case joinWindow(Direction)
  case unjoinWindows
  case runStartupCommands

  public var resizesManagedLayout: Bool {
    switch self {
    case .cycleWidth, .toggleFullscreen:
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
}

public enum Event: Equatable, Codable, Sendable {
  case windowDiscovered(Window)
  case windowDestroyed(WindowID)
  case focusChanged(WindowID)
  case commandReceived(Command)
  case configChanged
  case monitorConnected(MonitorID)
  case monitorDisconnected(MonitorID)
}

public enum CommandParseError: Error, Equatable, Sendable {
  case empty
  case unknownCommand(String)
  case missingArgument(String)
  case invalidDirection(String)
}

public func parseCommand(_ input: String) throws -> Command {
  let parts = input.split(whereSeparator: \.isWhitespace).map(String.init)
  guard let name = parts.first else {
    throw CommandParseError.empty
  }

  func argument(_ name: String) throws -> String {
    guard parts.count > 1 else {
      throw CommandParseError.missingArgument(name)
    }
    return parts[1]
  }

  switch name {
  case "focus-column":
    return .focusColumn(try parseDirection(argument("direction")))
  case "focus-floating":
    return .focusFloating(try parseDirection(argument("direction")))
  case "move-column":
    let direction = try parseDirection(argument("direction"))
    guard [.left, .right, .first, .last].contains(direction) else {
      throw CommandParseError.invalidDirection(parts[1])
    }
    return .moveColumn(direction)
  case "move-window":
    let direction = try parseDirection(argument("direction"))
    guard [.up, .down].contains(direction) else {
      throw CommandParseError.invalidDirection(parts[1])
    }
    return .moveWindow(direction)
  case "focus-window":
    return .focusWindow(try parseDirection(argument("direction")))
  case "move-window-to-workspace":
    return .moveWindowToWorkspace(WorkspaceID(rawValue: try argument("workspace")))
  case "send-window-to-workspace":
    return .sendWindowToWorkspace(WorkspaceID(rawValue: try argument("workspace")))
  case "workspace":
    return .switchWorkspace(WorkspaceID(rawValue: try argument("workspace")))
  case "cycle-width":
    return .cycleWidth(try parseDirection(argument("direction")))
  case "toggle-fullscreen":
    return .toggleFullscreen
  case "toggle-floating":
    return .toggleFloating
  case "join-window":
    return .joinWindow(try parseDirection(argument("direction")))
  case "unjoin-windows":
    return .unjoinWindows
  case "run-startup-commands":
    return .runStartupCommands
  default:
    throw CommandParseError.unknownCommand(name)
  }
}

private func parseDirection(_ input: String) throws -> Direction {
  if input == "prev" {
    return .previous
  }
  guard let direction = Direction(rawValue: input) else {
    throw CommandParseError.invalidDirection(input)
  }
  return direction
}

public enum OffWorkspaceStrategy: String, Codable, Sendable {
  case parkOffscreen = "park_offscreen"
}

public enum NewWindowPlacement: String, Codable, Sendable {
  case afterActiveColumn = "after-active-column"
}
