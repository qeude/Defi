import DefiModel
import SwiftUI
import DefiMacOS

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

/// Shortcut actions in the cheatsheet's sections, each a card on the Keyboard page.
struct SettingsShortcutGroup {
  let title: String
  let symbol: String
  let color: Color
  let commands: [String]

  static func groups(_ commands: [String]) -> [SettingsShortcutGroup] {
    let byCategory = Dictionary(grouping: commands) { command in
      commandSpec(named: String(command.split(separator: " ").first ?? ""))?.category
    }
    return (CommandCategory.allCases.map(Optional.some) + [nil]).compactMap { category in
      guard let commands = byCategory[category], !commands.isEmpty else { return nil }
      let style = style(category)
      return SettingsShortcutGroup(
        title: shortcutSectionTitle(for: category), symbol: style.symbol, color: style.color, commands: commands)
    }
  }

  private static func style(_ category: CommandCategory?) -> (symbol: String, color: Color) {
    switch category {
    case .column: ("rectangle.split.3x1", .teal)
    case .window: ("rectangle.split.1x2", .blue)
    case .workspace: ("rectangle.3.group", .indigo)
    case .monitor: ("display.2", .cyan)
    case .size: ("arrow.up.left.and.arrow.down.right", .orange)
    case .floating: ("macwindow.on.rectangle", .pink)
    case .other, nil: ("ellipsis.circle", .gray)
    }
  }
}
