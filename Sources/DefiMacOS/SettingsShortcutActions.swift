import DefiModel

/// The shortcut recorder's view of the command catalogue. The catalogue owns the names,
/// argument grammars and suggestions; this only expands workspace arguments.
enum SettingsShortcutActions {
  static let actions: [String] = commandSpecs.filter(\.isConfigurable).map(\.name)

  static func argumentKind(for action: String) -> CommandArgument {
    commandSpec(named: action)?.argument ?? .none
  }

  static func defaultArgument(workspaces: [String]) -> String {
    guard let action = actions.first else { return "" }
    return argumentKind(for: action).suggestions(workspaces: workspaces).first ?? ""
  }

  static func isKnown(_ action: String) -> Bool {
    actions.contains(action)
  }

  static func accepted(_ argument: String, for action: String, workspaces: [String]) -> Bool {
    switch argumentKind(for: action) {
    case .none:
      return true
    case .keywords(let values):
      return values.contains(argument)
    case .workspaceName:
      return workspaces.contains(argument)
    case .workspaceOrRelative:
      return ["up", "down"].contains(argument) || workspaces.contains(argument)
    case .workspacePosition:
      return Int(argument).map { $0 > 0 } ?? false
    case .text:
      return (try? parseCommand("\(action) \(argument)")) != nil
    }
  }

  static func availableCommands(workspaces: [String]) -> [String] {
    actions.flatMap { action -> [String] in
      switch argumentKind(for: action) {
      case .none:
        return [action]
      default:
        return argumentKind(for: action).suggestions(workspaces: workspaces)
          .map { "\(action) \($0)" }
      }
    }
  }

  static func commands(workspaces: [String], rows: [SettingsShortcutRow]) -> [String] {
    Set(availableCommands(workspaces: workspaces) + rows.map(\.command)).sorted()
  }
}
