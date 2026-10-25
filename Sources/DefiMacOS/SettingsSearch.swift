import DefiConfig
import Foundation

enum SettingsPage: String, CaseIterable, Identifiable, Sendable {
  case general = "General"
  case layout = "Layout"
  case input = "Input"
  case appearance = "Appearance"
  case workspaces = "Workspaces"
  case appRules = "App Rules"
  case about = "About"

  var id: Self { self }
}

enum SettingsOption: String, CaseIterable, Sendable {
  case accessibility
  case launchAtLogin
  case menuBar
  case workspaceDisplay
  case configurationFile
  case configurationGuide
  case logs
  case about
  case defaultColumnWidth
  case focusedColumn
  case widthPresets
  case screenMargins
  case animations
  case reservedTop
  case reservedBottom
  case hyperSymbol
  case hyperShift
  case focusFollowsPointer
  case pointerFollowsFocus
  case pointerFocusScroll
  case pointerFocusDelay
  case defaultModifier
  case modifierAliases
  case customShortcut
  case shortcutGuide
  case keyboardShortcuts
  case focusedBorder
  case borderWidth
  case focusedBorderColor
  case unfocusedBorders
  case unfocusedBorderColor
  case captureBorders
  case borderPlacement
  case overviewScale
  case overviewCornerRadius
  case windowPreviews
  case namedWorkspaces
  case defaultWorkspace
  case addAppRule
  case appRules

  private var metadata: (page: SettingsPage, title: String, terms: String) {
    switch self {
    case .accessibility: (.general, "Accessibility", "permissions accessibility settings")
    case .launchAtLogin: (.general, "Launch Defi at login", "startup launch login")
    case .menuBar: (.general, "Show Defi in the menu bar", "menu_bar.enabled")
    case .workspaceDisplay: (.general, "Named workspace display", "menu_bar.workspace_style icon only icon and name name only")
    case .configurationFile: (.general, "Open Configuration File…", "configuration file config toml path")
    case .configurationGuide: (.general, "Configuration Guide…", "documentation configuration guide")
    case .logs: (.general, "Open Logs Folder…", "diagnostics logs")
    case .about: (.about, "About Defi", "version build github repository releases release notes updates documentation issues")
    case .defaultColumnWidth: (.layout, "Default column width", "layout.default_column_width")
    case .focusedColumn: (.layout, "Focused column", "layout.center_focused_column reveal as needed always center on overflow")
    case .widthPresets: (.layout, "Width presets", "layout.preset_column_widths cycle width preset add remove")
    case .screenMargins: (
      .layout, "Spacing",
      "layout.gaps default gap outer_top_gap outer_right_gap outer_bottom_gap outer_left_gap between windows screen margins edges"
    )
    case .animations: (.appearance, "Enable animations", "animation.enabled")
    case .reservedTop: (.layout, "Reserved top area", "layout.reserved_top")
    case .reservedBottom: (.layout, "Reserved bottom area", "layout.reserved_bottom")
    case .hyperSymbol: (.input, "Show Hyper as ✧", "displayHyperSymbol hyper shortcut display")
    case .hyperShift: (.input, "Include Shift in Hyper", "displayHyperIncludesShift shortcut display")
    case .focusFollowsPointer: (.input, "Focus follows pointer", "input.focus_follows_mouse mouse")
    case .pointerFollowsFocus: (.input, "Move pointer to keyboard focus", "input.mouse_follows_focus mouse")
    case .pointerFocusScroll: (.input, "Maximum pointer-focus scroll", "input.focus_follows_mouse_max_scroll_amount mouse")
    case .pointerFocusDelay: (.input, "Pointer-focus delay", "input.focus_follows_mouse_delay_ms mouse")
    case .defaultModifier: (.input, "Default key modifier", "default_key_modifier keyboard")
    case .modifierAliases: (.input, "Modifier aliases", "modifier_combinations alias modifiers")
    case .customShortcut: (.input, "Add Custom Shortcut…", "custom command keybinding keyboard binding")
    case .shortcutGuide: (.input, "Show guide when holding the main modifier", "show_cheatsheet_on_modifier_hold shortcut guide cheatsheet")
    case .keyboardShortcuts: (.input, "Keyboard shortcuts", "keys keybinding bindings record reset actions")
    case .focusedBorder: (.appearance, "Show focused window border", "decorations.borders.enabled")
    case .borderWidth: (.appearance, "Border width", "decorations.borders.width")
    case .focusedBorderColor: (.appearance, "Focused border color", "decorations.borders.color")
    case .unfocusedBorders: (.appearance, "Show unfocused window borders", "decorations.borders.inactive_enabled")
    case .unfocusedBorderColor: (.appearance, "Unfocused border color", "decorations.borders.inactive_color")
    case .captureBorders: (.appearance, "Include borders in screenshots", "decorations.borders.capture_enabled")
    case .borderPlacement: (.appearance, "Border placement", "decorations.borders.placement inside window outside window")
    case .overviewScale: (.appearance, "Scale", "overview.zoom scale")
    case .overviewCornerRadius: (.appearance, "Corner radius", "overview.window_corner_radius")
    case .windowPreviews: (.appearance, "Show optional window previews", "overview.window_previews screen recording")
    case .namedWorkspaces: (.workspaces, "Named workspaces", "workspaces.names workspace name rename reorder add delete")
    case .defaultWorkspace: (.workspaces, "Default workspace", "workspaces.default startup workspace")
    case .addAppRule: (.appRules, "Add App Rule…", "rules application rule add")
    case .appRules: (.appRules, "Application rules", "rules app rules add edit reorder remove")
    }
  }

  var page: SettingsPage { metadata.page }
  var title: String { metadata.title }
  var terms: String { metadata.terms }
}

enum SettingsWorkspaceField: CaseIterable, Sendable {
  case name, icon, display, displayNumber

  var title: String {
    switch self {
    case .name: "Workspace name"
    case .icon: "Workspace icon"
    case .display: "Workspace display"
    case .displayNumber: "Display number"
    }
  }

  var terms: String {
    switch self {
    case .name: "workspaces.names rename"
    case .icon: "workspaces.icons SF Symbol"
    case .display: "workspaces.monitor_ids workspaces.monitors monitor affinity"
    case .displayNumber: "workspaces.monitors display position"
    }
  }
}

enum SettingsSearchAnchor: Hashable {
  case option(SettingsOption)
  case keyboardShortcuts
  case workspace(String)
}

enum SettingsDestination: Hashable {
  case page(SettingsPage)
  case option(SettingsOption)
  case shortcut(String)
  case workspace(name: String, field: SettingsWorkspaceField)

  var page: SettingsPage {
    switch self {
    case .page(let page): page
    case .option(let option): option.page
    case .shortcut: .input
    case .workspace: .workspaces
    }
  }

  var anchor: SettingsSearchAnchor? {
    switch self {
    case .page: nil
    case .option(let option): option == .keyboardShortcuts ? .keyboardShortcuts : .option(option)
    case .shortcut: .keyboardShortcuts
    case .workspace(let name, _): .workspace(name)
    }
  }
}

struct SettingsRevealRequest: Equatable {
  let destination: SettingsDestination
  let id = UUID()
}

struct SettingsSearchResult: Identifiable {
  let destination: SettingsDestination
  let title: String
  let context: String
  var detail: String = ""
  var terms: String = ""

  var id: SettingsDestination { destination }

  func matches(_ query: String) -> Bool {
    SettingsSearchCatalog.matches(query, in: [title, context, detail, terms].joined(separator: " "))
  }
}

enum SettingsSearchCatalog {
  static func contains(_ destination: SettingsDestination, config: Config, shortcuts: [SettingsShortcutRow]) -> Bool {
    switch destination {
    case .page, .option:
      true
    case .shortcut(let command):
      SettingsShortcutActions.commands(workspaces: config.workspaces.names, rows: shortcuts).contains(command)
    case .workspace(let name, let field):
      config.workspaces.names.contains(name)
        && (field != .displayNumber || config.workspaces.monitors[name] != nil)
    }
  }

  static func results(matching query: String, config: Config, shortcuts: [SettingsShortcutRow]) -> [SettingsSearchResult] {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    let pages = SettingsPage.allCases.map {
      SettingsSearchResult(destination: .page($0), title: $0.rawValue, context: "Settings page")
    }
    let options = SettingsOption.allCases.map {
      SettingsSearchResult(destination: .option($0), title: $0.title,
        context: $0.page.rawValue, terms: $0.terms)
    }
    let workspaces = config.workspaces.names.flatMap { name in
      SettingsWorkspaceField.allCases.compactMap { field -> SettingsSearchResult? in
        if field == .displayNumber && config.workspaces.monitors[name] == nil { return nil }
        return SettingsSearchResult(destination: .workspace(name: name, field: field),
          title: "\(field.title) · \(name)", context: "Workspaces · Named workspaces", terms: field.terms)
      }
    }
    return (pages + options + workspaces + shortcutResults(config: config, shortcuts: shortcuts))
      .filter { $0.matches(query) }
  }

  static func shortcutResults(config: Config, shortcuts: [SettingsShortcutRow]) -> [SettingsSearchResult] {
    let bindings = Dictionary(grouping: shortcuts, by: \.command)
    return SettingsShortcutActions.commands(workspaces: config.workspaces.names, rows: shortcuts).map { command in
      let rows = bindings[command] ?? []
      let labels = rows.map { row in
        let label = shortcutKeyLabel(row.accelerator, aliases: config.modifierCombinations, displayHyper: false)
        return label + (row.isEnabled ? "" : " (Disabled)")
      }
      let keys = rows.flatMap { row -> [String] in
        let normalized = normalizedAccelerator(row.accelerator, aliases: config.modifierCombinations) ?? row.accelerator
        let words = normalized.replacingOccurrences(of: "alt", with: "option")
          .replacingOccurrences(of: "ctrl", with: "control")
          .replacingOccurrences(of: "cmd", with: "command")
        return [row.accelerator, normalized, words,
          shortcutKeyLabel(row.accelerator, aliases: config.modifierCombinations, displayHyper: false),
          shortcutKeyLabel(row.accelerator, aliases: config.modifierCombinations),
          shortcutKeyLabel(row.accelerator, aliases: config.modifierCombinations, hyperIncludesShift: true)]
      }
      return SettingsSearchResult(destination: .shortcut(command), title: commandTitle(command),
        context: "Input · Keyboard shortcuts", detail: labels.isEmpty ? "Not assigned" : labels.joined(separator: " · "),
        terms: ([command, "keys keybinding binding shortcut"] + keys).joined(separator: " "))
    }
  }

  static func commandTitle(_ command: String) -> String {
    command.replacingOccurrences(of: "-", with: " ").capitalized
  }

  static func matches(_ query: String, in text: String) -> Bool {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
    let query = normalizedSearchText(query).split(whereSeparator: \.isWhitespace)
    guard !query.isEmpty else { return false }
    let text = normalizedSearchText(text)
    return query.allSatisfy { text.localizedCaseInsensitiveContains(String($0)) }
  }

  private static func normalizedSearchText(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "+", with: " ")
  }
}

enum SettingsShortcutFilter: Equatable {
  case query(String)
  case command(String)

  var text: String {
    switch self {
    case .query(let text), .command(let text): text
    }
  }

  func includes(_ command: String) -> Bool {
    switch self {
    case .query(let query): SettingsSearchCatalog.matches(query, in: command)
    case .command(let target): command == target
    }
  }
}
