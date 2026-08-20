import Foundation

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
  case "move-column-to-monitor":
    return .moveColumnToMonitor(
      try parseSpatialDirection(argument("direction"))
    )
  case "move-window-to-monitor":
    return .moveWindowToMonitor(
      try parseSpatialDirection(argument("direction"))
    )
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
  case "maximize-column":
    return .maximizeColumn
  case "toggle-floating":
    return .toggleFloating
  case "activate-floating":
    return .activateFloating
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

private func parseSpatialDirection(_ input: String) throws -> Direction {
  let direction = try parseDirection(input)
  guard [.left, .right, .up, .down].contains(direction) else {
    throw CommandParseError.invalidDirection(input)
  }
  return direction
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
