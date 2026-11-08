enum SettingsShortcutActions {
  static let actions = [
    "focus-column", "focus-column-or-monitor", "focus-floating", "move-column",
    "move-column-or-to-monitor", "move-window", "move-column-to-monitor",
    "move-window-to-monitor", "focus-window",
    "focus-window-or-workspace", "focus-window-previous",
    "move-window-to-workspace", "send-window-to-workspace",
    "move-column-to-workspace", "move-column-to-workspace-name",
    "send-column-to-workspace", "send-column-to-workspace-name",
    "move-column-to-workspace-position", "move-window-to-workspace-position",
    "send-window-to-workspace-position", "move-window-to-workspace-name",
    "send-window-to-workspace-name", "workspace", "focus-workspace",
    "focus-workspace-position", "focus-workspace-name", "focus-workspace-previous",
    "reorder-workspace",
    "move-workspace-to-monitor", "focus-monitor", "cycle-width", "maximize-column",
    "set-column-width", "expand-column-to-available-width",
    "set-window-height", "switch-preset-window-height", "reset-window-height",
    "center-column", "center-visible-columns",
    "toggle-floating", "activate-floating", "join-window", "unjoin-windows",
    "consume-or-expel-window", "swap-window",
    "toggle-cheatsheet", "toggle-overview", "open-settings", "run-startup-commands",
  ]
  static let noArgumentActions: Set<String> = [
    "maximize-column", "expand-column-to-available-width", "center-column", "center-visible-columns",
    "focus-workspace-previous", "focus-window-previous", "toggle-floating",
    "switch-preset-window-height", "reset-window-height",
    "activate-floating", "unjoin-windows",
    "toggle-cheatsheet", "toggle-overview", "open-settings", "run-startup-commands",
  ]
  static let relativeWorkspaceActions: Set<String> = [
    "move-window-to-workspace", "send-window-to-workspace", "move-column-to-workspace",
    "send-column-to-workspace",
  ]
  static let namedWorkspaceActions: Set<String> = [
    "move-column-to-workspace-name", "send-column-to-workspace-name",
    "move-window-to-workspace-name", "send-window-to-workspace-name",
    "workspace", "focus-workspace-name",
  ]
  static let positionActions: Set<String> = [
    "move-column-to-workspace-position", "move-window-to-workspace-position",
    "send-window-to-workspace-position", "focus-workspace-position",
  ]

  static func availableCommands(workspaces: [String]) -> [String] {
    actions.flatMap { action -> [String] in
      if noArgumentActions.contains(action) { return [action] }
      let arguments: [String]
      if relativeWorkspaceActions.contains(action) {
        arguments = ["up", "down"] + workspaces
      } else if namedWorkspaceActions.contains(action) {
        arguments = workspaces
      } else if positionActions.contains(action) {
        arguments = (1...9).map(String.init)
      } else {
        arguments = argumentOptions[action] ?? argumentSuggestions[action] ?? []
      }
      return arguments.map { "\(action) \($0)" }
    }
  }

  static func commands(workspaces: [String], rows: [SettingsShortcutRow]) -> [String] {
    Set(availableCommands(workspaces: workspaces) + rows.map(\.command)).sorted()
  }

  /// Listed unbound rows for actions whose argument is free text.
  static let argumentSuggestions: [String: [String]] = [
    "set-column-width": ["-10%", "+10%"], "set-window-height": ["-10%", "+10%"],
  ]

  static let argumentOptions: [String: [String]] = [
    "focus-column": ["left", "right", "first", "last"],
    "focus-floating": ["previous", "next", "first", "last"],
    "move-column": ["left", "right", "first", "last"],
    "move-window": ["up", "down"],
    "move-column-to-monitor": ["left", "right", "up", "down"],
    "focus-column-or-monitor": ["left", "right"],
    "move-column-or-to-monitor": ["left", "right"],
    "move-window-to-monitor": ["left", "right", "up", "down"],
    "focus-window": ["previous", "next", "first", "last"],
    "focus-window-or-workspace": ["up", "down"],
    "focus-workspace": ["up", "down"],
    "reorder-workspace": ["up", "down"],
    "move-workspace-to-monitor": ["left", "right", "up", "down"],
    "focus-monitor": ["left", "right", "up", "down"],
    "cycle-width": ["previous", "next"],
    "join-window": ["left", "right"],
    "consume-or-expel-window": ["left", "right"],
    "swap-window": ["left", "right"],
  ]

}
