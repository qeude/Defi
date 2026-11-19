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

/// A verb the daemon answers itself, without the layout reducer.
public enum DaemonVerb: Equatable, Sendable {
  case listWorkspaces(json: Bool)
  case listWindows(json: Bool)
  case status
  case trace
  case borderAudit
  case restore
  /// `quit` restores the windows; `handoff` leaves them for the next daemon.
  case stop(handsOffWindows: Bool)
  case setReservedArea(edge: ReservedEdge, points: Double)
  case clearReservedArea
  case diagnosticMark
}

/// A viewport edge whose reserved area a command sets.
public enum ReservedEdge: String, Equatable, Sendable {
  case top
  case bottom
}

/// What a command line names. Every verb Defi accepts is one of these.
public enum Verb: Equatable, Sendable {
  case layout(Command)
  case daemon(DaemonVerb)

  /// Answers without changing anything, so the daemon may serve a recent answer.
  public var isReadOnly: Bool {
    switch self {
    case .daemon(.listWorkspaces), .daemon(.listWindows), .daemon(.status), .daemon(.trace):
      return true
    case .daemon, .layout:
      return false
    }
  }

  /// The key a read-only answer is cached under; nil for anything that changes state.
  public var cacheKey: String? {
    switch self {
    case .daemon(.listWorkspaces(let json)): "list-workspaces:\(json)"
    case .daemon(.listWindows(let json)): "list-windows:\(json)"
    case .daemon(.status): "status"
    case .daemon(.trace): "trace"
    case .daemon, .layout: nil
    }
  }

  /// Runs a shell with Defi's own grants, so the socket refuses it.
  public var isAllowedOverIPC: Bool {
    if case .layout(.spawnShell) = self { return false }
    return true
  }
}

public struct CommandSpec: Sendable {
  public let name: String
  public let category: CommandCategory
  public let argument: CommandArgument
  /// Settings offers this name in the shortcut recorder.
  public let isConfigurable: Bool
  /// Accepted verbatim as a key binding although it is not a layout command.
  public let isClientVerb: Bool
  let build: @Sendable (_ arguments: [String], _ remainder: String) throws -> Verb
}

/// Every layout command Defi parses, in the order Settings lists them.
public let commandSpecs: [CommandSpec] = [
  layout("focus-column", .column, .keywords( ["left", "right", "first", "last"])) { arguments, _ in
    .focusColumn(try parseDirection(arguments, label: "direction"))
  },
  layout("focus-column-or-monitor", .monitor, .keywords( ["left", "right"])) { arguments, _ in
    .focusColumnOrMonitor(try horizontalDirection(arguments))
  },
  layout("focus-floating", .floating, .keywords( ["previous", "next", "first", "last"])) { arguments, _ in
    .focusFloating(try parseDirection(arguments, label: "direction"))
  },
  layout("move-column", .column, .keywords( ["left", "right", "first", "last"])) { arguments, _ in
    let direction = try parseDirection(arguments, label: "direction")
    guard [.left, .right, .first, .last].contains(direction) else { throw invalidDirection(arguments) }
    return .moveColumn(direction)
  },
  layout("move-column-or-to-monitor", .monitor, .keywords( ["left", "right"])) { arguments, _ in
    .moveColumnOrToMonitor(try horizontalDirection(arguments))
  },
  layout("move-window", .window, .keywords( ["up", "down"])) { arguments, _ in
    .moveWindow(try verticalDirection(arguments))
  },
  layout("move-column-to-monitor", .monitor, .keywords( ["left", "right", "up", "down"])) { arguments, _ in
    .moveColumnToMonitor(try spatialDirection(arguments))
  },
  layout("move-window-to-monitor", .monitor, .keywords( ["left", "right", "up", "down"])) { arguments, _ in
    .moveWindowToMonitor(try spatialDirection(arguments))
  },
  layout("focus-window", .window, .keywords( ["previous", "next", "first", "last"])) { arguments, _ in
    .focusWindow(try parseDirection(arguments, label: "direction"))
  },
  layout("focus-window-or-workspace", .workspace, .keywords( ["up", "down"])) { arguments, _ in
    .focusWindowOrWorkspace(try verticalDirection(arguments))
  },
  layout("focus-window-previous", .workspace) { _, _ in .focusWindowPrevious },
  layout(
    "recent-windows", .workspace, .keywords(["next", "previous"])
  ) { arguments, _ in
    let value = try argument(arguments, label: "action")
    guard let action = RecentWindowsAction(rawValue: value == "prev" ? "previous" : value) else {
      throw CommandParseError.invalidDirection(value)
    }
    return .recentWindows(action)
  },
  layout(
    "move-window-to-workspace", .workspace, .workspaceOrRelative
  ) { arguments, _ in
    let value = try argument(arguments, label: "workspace")
    if value == "up" || value == "down" {
      return .moveWindowToWorkspaceTarget(try relativeWorkspace(arguments), follow: true)
    }
    return .moveWindowToWorkspace(WorkspaceID(rawValue: value))
  },
  layout(
    "send-window-to-workspace", .workspace, .workspaceOrRelative
  ) { arguments, _ in
    let value = try argument(arguments, label: "workspace")
    if value == "up" || value == "down" {
      return .moveWindowToWorkspaceTarget(try relativeWorkspace(arguments), follow: false)
    }
    return .sendWindowToWorkspace(WorkspaceID(rawValue: value))
  },
  layout(
    "move-column-to-workspace", .workspace, .workspaceOrRelative
  ) { arguments, _ in
    let value = try argument(arguments, label: "workspace")
    if value == "up" || value == "down" {
      return .moveColumnToWorkspace(try relativeWorkspace(arguments), follow: true)
    }
    return .moveColumnToWorkspace(.named(value), follow: true)
  },
  layout(
    "move-column-to-workspace-name", .workspace, .workspaceName
  ) { arguments, _ in
    .moveColumnToWorkspace(.named(try argument(arguments, label: "workspace")), follow: true)
  },
  layout(
    "send-column-to-workspace", .workspace, .workspaceOrRelative
  ) { arguments, _ in
    let value = try argument(arguments, label: "workspace")
    if value == "up" || value == "down" {
      return .moveColumnToWorkspace(try relativeWorkspace(arguments), follow: false)
    }
    return .moveColumnToWorkspace(.named(value), follow: false)
  },
  layout(
    "send-column-to-workspace-name", .workspace, .workspaceName
  ) { arguments, _ in
    .moveColumnToWorkspace(.named(try argument(arguments, label: "workspace")), follow: false)
  },
  layout(
    "move-column-to-workspace-position", .workspace, .workspacePosition
  ) { arguments, _ in
    .moveColumnToWorkspace(try workspacePosition(arguments), follow: true)
  },
  layout(
    "move-window-to-workspace-position", .workspace, .workspacePosition
  ) { arguments, _ in
    .moveWindowToWorkspaceTarget(try workspacePosition(arguments), follow: true)
  },
  layout(
    "send-window-to-workspace-position", .workspace, .workspacePosition
  ) { arguments, _ in
    .moveWindowToWorkspaceTarget(try workspacePosition(arguments), follow: false)
  },
  layout(
    "move-window-to-workspace-name", .workspace, .workspaceName
  ) { arguments, _ in
    .moveWindowToWorkspaceTarget(.named(try argument(arguments, label: "workspace")), follow: true)
  },
  layout(
    "send-window-to-workspace-name", .workspace, .workspaceName
  ) { arguments, _ in
    .moveWindowToWorkspaceTarget(.named(try argument(arguments, label: "workspace")), follow: false)
  },
  layout("workspace", .workspace, .workspaceName) { arguments, _ in
    .switchWorkspace(WorkspaceID(rawValue: try argument(arguments, label: "workspace")))
  },
  layout("focus-workspace", .workspace, .keywords( ["up", "down"])) { arguments, _ in
    .focusWorkspace(try relativeWorkspace(arguments))
  },
  layout("focus-workspace-position", .workspace, .workspacePosition) { arguments, _ in
    .focusWorkspace(try workspacePosition(arguments))
  },
  layout("focus-workspace-name", .workspace, .workspaceName) { arguments, _ in
    .focusWorkspace(.named(try argument(arguments, label: "workspace")))
  },
  layout("focus-workspace-previous", .workspace) { _, _ in
    .focusWorkspace(.lastActive)
  },
  layout("reorder-workspace", .workspace, .keywords( ["up", "down"])) { arguments, _ in
    .reorderWorkspace(try verticalDirection(arguments))
  },
  layout("move-workspace-to-monitor", .monitor, .keywords( ["left", "right", "up", "down"])) { arguments, _ in
    .moveWorkspaceToMonitor(try spatialDirection(arguments))
  },
  layout("focus-monitor", .monitor, .keywords( ["left", "right", "up", "down"])) { arguments, _ in
    .focusMonitor(try spatialDirection(arguments))
  },
  layout("cycle-width", .size, .keywords( ["previous", "next"])) { arguments, _ in
    .cycleWidth(try parseDirection(arguments, label: "direction"))
  },
  layout("maximize-column", .size) { _, _ in .maximizeColumn },
  layout("set-column-width", .size, .text(suggestions: ["-10%", "+10%"])) { arguments, _ in
    .setColumnWidth(try parseColumnWidthChange(try argument(arguments, label: "width")))
  },
  layout("expand-column-to-available-width", .size) { _, _ in .expandColumnToAvailableWidth },
  layout("set-window-height", .size, .text(suggestions: ["-10%", "+10%"])) { arguments, _ in
    .setWindowHeight(try parseWindowHeight(try argument(arguments, label: "height")))
  },
  layout("switch-preset-window-height", .size) { _, _ in .switchPresetWindowHeight },
  layout("reset-window-height", .size) { _, _ in .resetWindowHeight },
  layout("center-column", .column) { _, _ in .centerColumn },
  layout("center-visible-columns", .column) { _, _ in .centerVisibleColumns },
  layout("toggle-floating", .floating) { _, _ in .toggleFloating },
  layout("activate-floating", .floating) { _, _ in .activateFloating },
  layout("activate-window", .workspace) { _, _ in .activateWindow },
  layout("join-window", .window, .keywords( ["left", "right"])) { arguments, _ in
    .joinWindow(try parseDirection(arguments, label: "direction"))
  },
  layout("unjoin-windows", .window) { _, _ in .unjoinWindows },
  layout("consume-or-expel-window", .window, .keywords( ["left", "right"])) { arguments, _ in
    .consumeOrExpelWindow(try horizontalDirection(arguments))
  },
  layout("swap-window", .window, .keywords( ["left", "right"])) { arguments, _ in
    .swapWindow(try horizontalDirection(arguments))
  },
  layout("toggle-cheatsheet", .other) { _, _ in .toggleCheatsheet },
  layout("toggle-overview", .workspace) { _, _ in .toggleOverview },
  layout("open-settings", .other) { _, _ in .openSettings },
  layout(
    "focus-window-id", .window, .text(suggestions: []), isConfigurable: false
  ) { arguments, _ in
    let value = try argument(arguments, label: "window-id")
    guard let rawValue = UInt64(value) else { throw CommandParseError.invalidWindowID(value) }
    return .focusWindowID(WindowID(rawValue: rawValue))
  },
  layout("spawn-sh", .other, .text(suggestions: []), isConfigurable: false) {
    arguments, remainder in
    guard !remainder.isEmpty else { throw CommandParseError.missingArgument("command") }
    return .spawnShell(remainder)
  },
]

/// Every verb the daemon answers itself, without the layout reducer.
public let daemonVerbSpecs: [CommandSpec] = [
  daemon("list-workspaces", .workspace) { arguments, _ in
    .listWorkspaces(json: try jsonOption(arguments))
  },
  daemon("list-windows", .window) { arguments, _ in
    .listWindows(json: try jsonOption(arguments))
  },
  daemon("status", .other) { arguments, _ in try onlyNoArguments(arguments, "status"); return .status },
  daemon("trace", .other) { arguments, _ in try onlyNoArguments(arguments, "trace"); return .trace },
  daemon("border-audit", .other) { arguments, _ in
    try onlyNoArguments(arguments, "border-audit")
    return .borderAudit
  },
  daemon("restore", .other) { arguments, _ in try onlyNoArguments(arguments, "restore"); return .restore },
  daemon("quit", .other) { arguments, _ in
    try onlyNoArguments(arguments, "quit")
    return .stop(handsOffWindows: false)
  },
  daemon("handoff", .other) { arguments, _ in
    try onlyNoArguments(arguments, "handoff")
    return .stop(handsOffWindows: true)
  },
  daemon(
    "set-reserved-area", .size, .keywords(["top", "bottom"])
  ) { arguments, _ in
    guard arguments.count == 2, let points = Double(arguments[1]), points.isFinite,
      (0...512).contains(points), let edge = ReservedEdge(rawValue: arguments[0])
    else { throw CommandParseError.missingArgument("top|bottom <0...512>") }
    return .setReservedArea(edge: edge, points: points)
  },
  daemon("clear-reserved-area", .size) { arguments, _ in
    guard arguments.isEmpty else { throw CommandParseError.missingArgument("clear-reserved-area") }
    return .clearReservedArea
  },
  clientVerb("diagnostic-mark", .other) { arguments, _ in
    try onlyNoArguments(arguments, "diagnostic-mark")
    return .diagnosticMark
  },
]

/// Every verb Defi accepts, layout and daemon alike.
public let verbSpecs: [CommandSpec] = commandSpecs + daemonVerbSpecs

private let commandSpecsByName = Dictionary(uniqueKeysWithValues: commandSpecs.map { ($0.name, $0) })
private let verbSpecsByName = Dictionary(uniqueKeysWithValues: verbSpecs.map { ($0.name, $0) })

public func commandSpec(named name: String) -> CommandSpec? {
  commandSpecsByName[name]
}

public func verbSpec(named name: String) -> CommandSpec? {
  verbSpecsByName[name]
}

/// Whether a key binding may name this command line verbatim, although it is not a
/// layout command. The whole line must match, so `diagnostic-mark extra` is not one.
public func isClientVerb(_ input: String) -> Bool {
  verbSpec(named: input)?.isClientVerb == true
}

public func parseVerb(_ input: String) throws -> Verb {
  let body = input.drop { $0.isWhitespace }
  guard body.first != nil else {
    throw CommandParseError.empty
  }
  let name = String(body.prefix { !$0.isWhitespace })
  guard let spec = verbSpec(named: name) else {
    throw CommandParseError.unknownCommand(name)
  }
  let arguments = body.split(whereSeparator: \.isWhitespace).map(String.init).dropFirst()
  let remainder = String(body.dropFirst(name.count)).trimmingCharacters(in: .whitespacesAndNewlines)
  return try spec.build(Array(arguments), remainder)
}

/// The key a recent answer for this command line is cached under; nil when it changes state
/// or is not a verb at all.
public func verbCacheKey(_ rawCommand: String) -> String? {
  (try? parseVerb(rawCommand))?.cacheKey
}

/// False for a verb that runs a shell with Defi's own grants.
public func verbIsAllowedOverIPC(_ rawCommand: String) -> Bool {
  (try? parseVerb(rawCommand))?.isAllowedOverIPC ?? true
}

public func parseCommand(_ input: String) throws -> Command {
  guard case .layout(let command) = try parseVerb(input) else {
    throw CommandParseError.unknownCommand(String(input.prefix { !$0.isWhitespace }))
  }
  return command
}

private func layout(
  _ name: String,
  _ category: CommandCategory,
  _ argument: CommandArgument = .none,
  isConfigurable: Bool = true,
  build: @escaping @Sendable ([String], String) throws -> Command
) -> CommandSpec {
  spec(name, category, argument, isConfigurable: isConfigurable, isClientVerb: false) {
    .layout(try build($0, $1))
  }
}

private func daemon(
  _ name: String,
  _ category: CommandCategory,
  _ argument: CommandArgument = .none,
  build: @escaping @Sendable ([String], String) throws -> DaemonVerb
) -> CommandSpec {
  spec(name, category, argument, isConfigurable: false, isClientVerb: false) {
    .daemon(try build($0, $1))
  }
}

private func clientVerb(
  _ name: String,
  _ category: CommandCategory,
  build: @escaping @Sendable ([String], String) throws -> DaemonVerb
) -> CommandSpec {
  spec(name, category, .none, isConfigurable: true, isClientVerb: true) {
    .daemon(try build($0, $1))
  }
}

private func spec(
  _ name: String,
  _ category: CommandCategory,
  _ argument: CommandArgument = .none,
  isConfigurable: Bool,
  isClientVerb: Bool,
  build: @escaping @Sendable ([String], String) throws -> Verb
) -> CommandSpec {
  CommandSpec(
    name: name, category: category, argument: argument, isConfigurable: isConfigurable,
    isClientVerb: isClientVerb, build: build)
}

/// Verbs that take no argument accept none, as their exact-match readers did.
private func onlyNoArguments(_ arguments: [String], _ name: String) throws {
  guard arguments.isEmpty else { throw CommandParseError.missingArgument(name) }
}

/// `list-windows --json`, or the plain listing.
private func jsonOption(_ arguments: [String]) throws -> Bool {
  switch arguments {
  case []: return false
  case ["--json"]: return true
  default: throw CommandParseError.missingArgument("--json")
  }
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
