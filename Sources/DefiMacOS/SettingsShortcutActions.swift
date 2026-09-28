enum SettingsShortcutActions {
  static let actions = [
    "focus-column", "focus-floating", "move-column", "move-window",
    "move-column-to-monitor", "move-window-to-monitor", "focus-window",
    "move-window-to-workspace", "send-window-to-workspace",
    "move-column-to-workspace", "move-column-to-workspace-name",
    "send-column-to-workspace", "send-column-to-workspace-name",
    "move-column-to-workspace-position", "move-window-to-workspace-position",
    "send-window-to-workspace-position", "move-window-to-workspace-name",
    "send-window-to-workspace-name", "workspace", "focus-workspace",
    "focus-workspace-position", "focus-workspace-name", "reorder-workspace",
    "move-workspace-to-monitor", "focus-monitor", "cycle-width", "maximize-column",
    "toggle-floating", "activate-floating", "join-window", "unjoin-windows",
    "toggle-cheatsheet", "toggle-overview", "run-startup-commands",
  ]
  static let noArgumentActions: Set<String> = [
    "maximize-column", "toggle-floating", "activate-floating", "unjoin-windows",
    "toggle-cheatsheet", "toggle-overview", "run-startup-commands",
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
        arguments = argumentOptions[action] ?? []
      }
      return arguments.map { "\(action) \($0)" }
    }
  }

  static let argumentOptions: [String: [String]] = [
    "focus-column": ["left", "right", "first", "last"],
    "focus-floating": ["previous", "next", "first", "last"],
    "move-column": ["left", "right", "first", "last"],
    "move-window": ["up", "down"],
    "move-column-to-monitor": ["left", "right", "up", "down"],
    "move-window-to-monitor": ["left", "right", "up", "down"],
    "focus-window": ["previous", "next", "first", "last"],
    "focus-workspace": ["up", "down"],
    "reorder-workspace": ["up", "down"],
    "move-workspace-to-monitor": ["left", "right", "up", "down"],
    "focus-monitor": ["left", "right", "up", "down"],
    "cycle-width": ["previous", "next"],
    "join-window": ["left", "right"],
  ]

}
