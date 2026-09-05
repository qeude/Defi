import Foundation

public enum CommandParseError: Error, Equatable, Sendable {
  case empty
  case unknownCommand(String)
  case missingArgument(String)
  case invalidDirection(String)
  case invalidPosition(String)
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
    let value = try argument("workspace")
    if value == "up" || value == "down" {
      return .moveWindowToWorkspaceTarget(try parseWorkspaceTarget(value), follow: true)
    }
    return .moveWindowToWorkspace(WorkspaceID(rawValue: value))
  case "send-window-to-workspace":
    let value = try argument("workspace")
    if value == "up" || value == "down" {
      return .moveWindowToWorkspaceTarget(try parseWorkspaceTarget(value), follow: false)
    }
    return .sendWindowToWorkspace(WorkspaceID(rawValue: value))
  case "move-column-to-workspace":
    return .moveColumnToWorkspace(
      try parseWorkspaceTarget(argument("workspace")),
      follow: true
    )
  case "move-column-to-workspace-name":
    return .moveColumnToWorkspace(.named(try argument("workspace")), follow: true)
  case "send-column-to-workspace":
    return .moveColumnToWorkspace(
      try parseWorkspaceTarget(argument("workspace")),
      follow: false
    )
  case "send-column-to-workspace-name":
    return .moveColumnToWorkspace(.named(try argument("workspace")), follow: false)
  case "move-column-to-workspace-position":
    return .moveColumnToWorkspace(
      try parseWorkspacePosition(argument("position")),
      follow: true
    )
  case "move-window-to-workspace-position":
    return .moveWindowToWorkspaceTarget(
      try parseWorkspacePosition(argument("position")),
      follow: true
    )
  case "send-window-to-workspace-position":
    return .moveWindowToWorkspaceTarget(
      try parseWorkspacePosition(argument("position")),
      follow: false
    )
  case "move-window-to-workspace-name":
    return .moveWindowToWorkspaceTarget(.named(try argument("workspace")), follow: true)
  case "send-window-to-workspace-name":
    return .moveWindowToWorkspaceTarget(.named(try argument("workspace")), follow: false)
  case "workspace":
    return .switchWorkspace(WorkspaceID(rawValue: try argument("workspace")))
  case "focus-workspace":
    return .focusWorkspace(try parseRelativeWorkspace(argument("direction")))
  case "focus-workspace-position":
    return .focusWorkspace(try parseWorkspacePosition(argument("position")))
  case "focus-workspace-name":
    return .focusWorkspace(.named(try argument("workspace")))
  case "reorder-workspace":
    return .reorderWorkspace(try parseVerticalDirection(argument("direction")))
  case "move-workspace-to-monitor":
    return .moveWorkspaceToMonitor(
      try parseSpatialDirection(argument("direction"))
    )
  case "focus-monitor":
    return .focusMonitor(try parseSpatialDirection(argument("direction")))
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
  case "toggle-cheatsheet":
    return .toggleCheatsheet
  case "toggle-overview":
    return .toggleOverview
  case "run-startup-commands":
    return .runStartupCommands
  default:
    throw CommandParseError.unknownCommand(name)
  }
}

private func parseWorkspaceTarget(_ input: String) throws -> WorkspaceTarget {
  if input == "up" || input == "down" {
    return try parseRelativeWorkspace(input)
  }
  return .named(input)
}

private func parseRelativeWorkspace(_ input: String) throws -> WorkspaceTarget {
  .relative(try parseVerticalDirection(input))
}

private func parseWorkspacePosition(_ input: String) throws -> WorkspaceTarget {
  guard let position = Int(input), position > 0 else {
    throw CommandParseError.invalidPosition(input)
  }
  return .position(position)
}

private func parseVerticalDirection(_ input: String) throws -> Direction {
  let direction = try parseDirection(input)
  guard [.up, .down].contains(direction) else {
    throw CommandParseError.invalidDirection(input)
  }
  return direction
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
