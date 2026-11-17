import Foundation

public enum CommandParseError: Error, Equatable, Sendable {
  case empty
  case unknownCommand(String)
  case missingArgument(String)
  case invalidDirection(String)
  case invalidPosition(String)
  case invalidWidth(String)
  case invalidWindowID(String)
  case invalidHeight(String)
}

/// Where a command belongs in the cheatsheet.
public enum CommandCategory: Sendable, CaseIterable {
  case column
  case window
  case workspace
  case monitor
  case size
  case floating
  case other
}

/// The argument a command takes. It describes what Settings may offer; the command's
/// builder still decides which values are accepted.
public enum CommandArgument: Equatable, Sendable {
  case none
  /// Values worth offering; the builder decides which it accepts.
  case keywords([String])
  /// A configured workspace name.
  case workspaceName
  /// `up`, `down`, or a configured workspace name or ID.
  case workspaceOrRelative
  /// A one-based position in the monitor's workspace stack.
  case workspacePosition
  /// Free text, with optional suggestions.
  case text(suggestions: [String])

  /// The workspace name this argument names, when it names one and is not a relative target.
  public func workspaceNameArgument(in rawCommand: String) -> String? {
    let argument = rawCommand.split(whereSeparator: \.isWhitespace).dropFirst().first.map(String.init)
    switch self {
    case .workspaceName:
      return argument
    case .workspaceOrRelative:
      guard let argument, argument != "up", argument != "down" else { return nil }
      return argument
    default:
      return nil
    }
  }

  /// Values Settings offers for this argument. Workspace arguments expand from the names.
  public func suggestions(workspaces: [String]) -> [String] {
    switch self {
    case .none: []
    case .keywords(let values): values
    case .workspaceName: workspaces
    case .workspaceOrRelative: ["up", "down"] + workspaces
    case .workspacePosition: (1...9).map(String.init)
    case .text(let suggestions): suggestions
    }
  }
}

public struct CommandSpec: Sendable {
  public let name: String
  public let category: CommandCategory
  public let argument: CommandArgument
  /// Settings offers this name in the shortcut recorder.
  public let isConfigurable: Bool
  let build: @Sendable (_ arguments: [String], _ remainder: String) throws -> Command
}

/// Every layout command Defi parses, in the order Settings lists them.
public let commandSpecs: [CommandSpec] = [
  spec("focus-column", .column, .keywords( ["left", "right", "first", "last"])) { arguments, _ in
    .focusColumn(try parseDirection(arguments, label: "direction"))
  },
  spec("focus-column-or-monitor", .monitor, .keywords( ["left", "right"])) { arguments, _ in
    .focusColumnOrMonitor(try horizontalDirection(arguments))
  },
  spec("focus-floating", .floating, .keywords( ["previous", "next", "first", "last"])) { arguments, _ in
    .focusFloating(try parseDirection(arguments, label: "direction"))
  },
  spec("move-column", .column, .keywords( ["left", "right", "first", "last"])) { arguments, _ in
    let direction = try parseDirection(arguments, label: "direction")
    guard [.left, .right, .first, .last].contains(direction) else { throw invalidDirection(arguments) }
    return .moveColumn(direction)
  },
  spec("move-column-or-to-monitor", .monitor, .keywords( ["left", "right"])) { arguments, _ in
    .moveColumnOrToMonitor(try horizontalDirection(arguments))
  },
  spec("move-window", .window, .keywords( ["up", "down"])) { arguments, _ in
    .moveWindow(try verticalDirection(arguments))
  },
  spec("move-column-to-monitor", .monitor, .keywords( ["left", "right", "up", "down"])) { arguments, _ in
    .moveColumnToMonitor(try spatialDirection(arguments))
  },
  spec("move-window-to-monitor", .monitor, .keywords( ["left", "right", "up", "down"])) { arguments, _ in
    .moveWindowToMonitor(try spatialDirection(arguments))
  },
  spec("focus-window", .window, .keywords( ["previous", "next", "first", "last"])) { arguments, _ in
    .focusWindow(try parseDirection(arguments, label: "direction"))
  },
  spec("focus-window-or-workspace", .workspace, .keywords( ["up", "down"])) { arguments, _ in
    .focusWindowOrWorkspace(try verticalDirection(arguments))
  },
  spec("focus-window-previous", .workspace) { _, _ in .focusWindowPrevious },
  spec(
    "recent-windows", .workspace, .text(suggestions: [])
  ) { arguments, _ in
    let value = try argument(arguments, label: "action")
    guard let action = RecentWindowsAction(rawValue: value == "prev" ? "previous" : value) else {
      throw CommandParseError.invalidDirection(value)
    }
    return .recentWindows(action)
  },
  spec(
    "move-window-to-workspace", .workspace, .workspaceOrRelative
  ) { arguments, _ in
    let value = try argument(arguments, label: "workspace")
    if value == "up" || value == "down" {
      return .moveWindowToWorkspaceTarget(try relativeWorkspace(arguments), follow: true)
    }
    return .moveWindowToWorkspace(WorkspaceID(rawValue: value))
  },
  spec(
    "send-window-to-workspace", .workspace, .workspaceOrRelative
  ) { arguments, _ in
    let value = try argument(arguments, label: "workspace")
    if value == "up" || value == "down" {
      return .moveWindowToWorkspaceTarget(try relativeWorkspace(arguments), follow: false)
    }
    return .sendWindowToWorkspace(WorkspaceID(rawValue: value))
  },
  spec(
    "move-column-to-workspace", .workspace, .workspaceOrRelative
  ) { arguments, _ in
    let value = try argument(arguments, label: "workspace")
    if value == "up" || value == "down" {
      return .moveColumnToWorkspace(try relativeWorkspace(arguments), follow: true)
    }
    return .moveColumnToWorkspace(.named(value), follow: true)
  },
  spec(
    "move-column-to-workspace-name", .workspace, .workspaceName
  ) { arguments, _ in
    .moveColumnToWorkspace(.named(try argument(arguments, label: "workspace")), follow: true)
  },
  spec(
    "send-column-to-workspace", .workspace, .workspaceOrRelative
  ) { arguments, _ in
    let value = try argument(arguments, label: "workspace")
    if value == "up" || value == "down" {
      return .moveColumnToWorkspace(try relativeWorkspace(arguments), follow: false)
    }
    return .moveColumnToWorkspace(.named(value), follow: false)
  },
  spec(
    "send-column-to-workspace-name", .workspace, .workspaceName
  ) { arguments, _ in
    .moveColumnToWorkspace(.named(try argument(arguments, label: "workspace")), follow: false)
  },
  spec(
    "move-column-to-workspace-position", .workspace, .workspacePosition
  ) { arguments, _ in
    .moveColumnToWorkspace(try workspacePosition(arguments), follow: true)
  },
  spec(
    "move-window-to-workspace-position", .workspace, .workspacePosition
  ) { arguments, _ in
    .moveWindowToWorkspaceTarget(try workspacePosition(arguments), follow: true)
  },
  spec(
    "send-window-to-workspace-position", .workspace, .workspacePosition
  ) { arguments, _ in
    .moveWindowToWorkspaceTarget(try workspacePosition(arguments), follow: false)
  },
  spec(
    "move-window-to-workspace-name", .workspace, .workspaceName
  ) { arguments, _ in
    .moveWindowToWorkspaceTarget(.named(try argument(arguments, label: "workspace")), follow: true)
  },
  spec(
    "send-window-to-workspace-name", .workspace, .workspaceName
  ) { arguments, _ in
    .moveWindowToWorkspaceTarget(.named(try argument(arguments, label: "workspace")), follow: false)
  },
  spec("workspace", .workspace, .workspaceName) { arguments, _ in
    .switchWorkspace(WorkspaceID(rawValue: try argument(arguments, label: "workspace")))
  },
  spec("focus-workspace", .workspace, .keywords( ["up", "down"])) { arguments, _ in
    .focusWorkspace(try relativeWorkspace(arguments))
  },
  spec("focus-workspace-position", .workspace, .workspacePosition) { arguments, _ in
    .focusWorkspace(try workspacePosition(arguments))
  },
  spec("focus-workspace-name", .workspace, .workspaceName) { arguments, _ in
    .focusWorkspace(.named(try argument(arguments, label: "workspace")))
  },
  spec("focus-workspace-previous", .workspace) { _, _ in
    .focusWorkspace(.lastActive)
  },
  spec("reorder-workspace", .workspace, .keywords( ["up", "down"])) { arguments, _ in
    .reorderWorkspace(try verticalDirection(arguments))
  },
  spec("move-workspace-to-monitor", .monitor, .keywords( ["left", "right", "up", "down"])) { arguments, _ in
    .moveWorkspaceToMonitor(try spatialDirection(arguments))
  },
  spec("focus-monitor", .monitor, .keywords( ["left", "right", "up", "down"])) { arguments, _ in
    .focusMonitor(try spatialDirection(arguments))
  },
  spec("cycle-width", .size, .keywords( ["previous", "next"])) { arguments, _ in
    .cycleWidth(try parseDirection(arguments, label: "direction"))
  },
  spec("maximize-column", .size) { _, _ in .maximizeColumn },
  spec("set-column-width", .size, .text(suggestions: ["-10%", "+10%"])) { arguments, _ in
    .setColumnWidth(try parseColumnWidthChange(try argument(arguments, label: "width")))
  },
  spec("expand-column-to-available-width", .size) { _, _ in .expandColumnToAvailableWidth },
  spec("set-window-height", .size, .text(suggestions: ["-10%", "+10%"])) { arguments, _ in
    .setWindowHeight(try parseWindowHeight(try argument(arguments, label: "height")))
  },
  spec("switch-preset-window-height", .size) { _, _ in .switchPresetWindowHeight },
  spec("reset-window-height", .size) { _, _ in .resetWindowHeight },
  spec("center-column", .column) { _, _ in .centerColumn },
  spec("center-visible-columns", .column) { _, _ in .centerVisibleColumns },
  spec("toggle-floating", .floating) { _, _ in .toggleFloating },
  spec("activate-floating", .floating) { _, _ in .activateFloating },
  spec("activate-window", .workspace) { _, _ in .activateWindow },
  spec("join-window", .window, .keywords( ["left", "right"])) { arguments, _ in
    .joinWindow(try parseDirection(arguments, label: "direction"))
  },
  spec("unjoin-windows", .window) { _, _ in .unjoinWindows },
  spec("consume-or-expel-window", .window, .keywords( ["left", "right"])) { arguments, _ in
    .consumeOrExpelWindow(try horizontalDirection(arguments))
  },
  spec("swap-window", .window, .keywords( ["left", "right"])) { arguments, _ in
    .swapWindow(try horizontalDirection(arguments))
  },
  spec("toggle-cheatsheet", .other) { _, _ in .toggleCheatsheet },
  spec("toggle-overview", .workspace) { _, _ in .toggleOverview },
  spec("open-settings", .other) { _, _ in .openSettings },
  spec(
    "focus-window-id", .window, .text(suggestions: []), isConfigurable: false
  ) { arguments, _ in
    let value = try argument(arguments, label: "window-id")
    guard let rawValue = UInt64(value) else { throw CommandParseError.invalidWindowID(value) }
    return .focusWindowID(WindowID(rawValue: rawValue))
  },
  spec("spawn-sh", .other, .text(suggestions: []), isConfigurable: false) {
    arguments, remainder in
    guard !remainder.isEmpty else { throw CommandParseError.missingArgument("command") }
    return .spawnShell(remainder)
  },
]

/// Commands the daemon and CLI understand without the layout reducer. They can be bound
/// like layout commands, but have no `Command` value.
public enum ClientVerb: String, CaseIterable, Sendable {
  case diagnosticMark = "diagnostic-mark"
}

public let clientVerbNames: [String] = ClientVerb.allCases.map(\.rawValue)

private let commandSpecsByName = Dictionary(uniqueKeysWithValues: commandSpecs.map { ($0.name, $0) })

public func commandSpec(named name: String) -> CommandSpec? {
  commandSpecsByName[name]
}

public func isClientVerb(_ input: String) -> Bool {
  clientVerbNames.contains(input)
}

public func parseCommand(_ input: String) throws -> Command {
  let body = input.drop { $0.isWhitespace }
  guard body.first != nil else {
    throw CommandParseError.empty
  }
  let name = String(body.prefix { !$0.isWhitespace })
  guard let spec = commandSpec(named: name) else {
    throw CommandParseError.unknownCommand(name)
  }
  let arguments = body.split(whereSeparator: \.isWhitespace).map(String.init).dropFirst()
  let remainder = String(body.dropFirst(name.count)).trimmingCharacters(in: .whitespacesAndNewlines)
  return try spec.build(Array(arguments), remainder)
}

private func spec(
  _ name: String,
  _ category: CommandCategory,
  _ argument: CommandArgument = .none,
  isConfigurable: Bool = true,
  build: @escaping @Sendable ([String], String) throws -> Command
) -> CommandSpec {
  CommandSpec(
    name: name, category: category, argument: argument, isConfigurable: isConfigurable,
    build: build)
}

private func argument(_ arguments: [String], label: String) throws -> String {
  guard let value = arguments.first else {
    throw CommandParseError.missingArgument(label)
  }
  return value
}

private func invalidDirection(_ arguments: [String]) -> CommandParseError {
  .invalidDirection(arguments.first ?? "")
}

private func parseDirection(_ arguments: [String], label: String) throws -> Direction {
  let input = try argument(arguments, label: label)
  if input == "prev" {
    return .previous
  }
  guard let direction = Direction(rawValue: input) else {
    throw CommandParseError.invalidDirection(input)
  }
  return direction
}

private func verticalDirection(_ arguments: [String]) throws -> Direction {
  let direction = try parseDirection(arguments, label: "direction")
  guard [.up, .down].contains(direction) else {
    throw invalidDirection(arguments)
  }
  return direction
}

private func horizontalDirection(_ arguments: [String]) throws -> Direction {
  let direction = try parseDirection(arguments, label: "direction")
  guard [.left, .right].contains(direction) else {
    throw invalidDirection(arguments)
  }
  return direction
}

private func spatialDirection(_ arguments: [String]) throws -> Direction {
  let direction = try parseDirection(arguments, label: "direction")
  guard [.left, .right, .up, .down].contains(direction) else {
    throw invalidDirection(arguments)
  }
  return direction
}

private func relativeWorkspace(_ arguments: [String]) throws -> WorkspaceTarget {
  .relative(try verticalDirection(arguments))
}

private func workspacePosition(_ arguments: [String]) throws -> WorkspaceTarget {
  let input = try argument(arguments, label: "position")
  guard let position = Int(input), position > 0 else {
    throw CommandParseError.invalidPosition(input)
  }
  return .position(position)
}

/// `+5%`, `-10%`, `60%` or `960`: a signed value adjusts, a `%` counts the usable width.
private func parseColumnWidthChange(_ input: String) throws -> ColumnWidthChange {
  let sign: Double?
  switch input.first {
  case "+": sign = 1
  case "-": sign = -1
  default: sign = nil
  }
  let percent = input.hasSuffix("%")
  let digits = input.dropFirst(sign == nil ? 0 : 1).dropLast(percent ? 1 : 0)
  guard digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
    let magnitude = Double(digits), magnitude.isFinite, sign != nil || magnitude > 0
  else { throw CommandParseError.invalidWidth(input) }
  let value = (sign ?? 1) * magnitude
  let width: ColumnWidth = percent ? .fraction(value / 100) : .pixels(value)
  return sign == nil ? .set(width) : .adjust(width)
}

/// `N%` sets a share of the column, `+N%`/`-N%` changes it, and a bare number is points.
private func parseWindowHeight(_ input: String) throws -> WindowHeightChange {
  let sign = input.first.flatMap { "+-".contains($0) ? $0 : nil }
  let body = sign == nil ? input[...] : input.dropFirst()
  let percent = body.hasSuffix("%")
  guard let value = Double(percent ? body.dropLast() : body), value.isFinite, value >= 0,
    body.first?.isNumber == true
  else { throw CommandParseError.invalidHeight(input) }
  switch (sign, percent) {
  case ("+", true): return .adjust(value / 100)
  case ("-", true): return .adjust(-value / 100)
  case (nil, true) where value > 0 && value <= 100: return .share(value / 100)
  case (nil, false) where value > 0: return .points(value)
  default: throw CommandParseError.invalidHeight(input)
  }
}
