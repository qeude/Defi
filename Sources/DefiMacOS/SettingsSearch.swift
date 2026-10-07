import DefiConfig
import Foundation

enum SettingsPage: String, CaseIterable, Identifiable, Sendable {
  case general = "General"
  case layout = "Layout"
  case input = "Input"
  case appearance = "Appearance"
  case workspaces = "Workspaces"
  case appRules = "App Rules"

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
  case defaultGap
  case topMargin
  case rightMargin
  case bottomMargin
  case leftMargin
  case animations
  case animationDuration
  case reservedTop
  case reservedBottom
  case hyperSymbol
  case hyperShift
  case focusFollowsPointer
  case pointerFollowsFocus
  case pointerFocusScroll
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

  private var metadata: (page: SettingsPage, title: String, terms: String, advanced: Bool) {
    switch self {
    case .accessibility: (.general, "Accessibility", "permissions accessibility settings", false)
    case .launchAtLogin: (.general, "Launch Defi at login", "startup launch login", false)
    case .menuBar: (.general, "Show Defi in the menu bar", "menu_bar.enabled", false)
    case .workspaceDisplay: (.general, "Named workspace display", "menu_bar.workspace_style icon only icon and name name only", false)
    case .configurationFile: (.general, "Open Configuration File…", "configuration file config toml path", false)
    case .configurationGuide: (.general, "Configuration Guide…", "documentation configuration guide", false)
    case .logs: (.general, "Open Logs Folder…", "diagnostics logs", false)
    case .about: (.general, "About Defi", "version github repository", false)
    case .defaultColumnWidth: (.layout, "Default column width", "layout.default_column_width", false)
    case .focusedColumn: (.layout, "Focused column", "layout.center_focused_column reveal as needed always center", false)
    case .widthPresets: (.layout, "Width presets", "layout.preset_column_widths cycle width preset add remove", false)
    case .defaultGap: (.layout, "Default gap", "layout.gaps spacing", false)
    case .topMargin: (.layout, "Top margin", "layout.outer_top_gap spacing", false)
    case .rightMargin: (.layout, "Right margin", "layout.outer_right_gap spacing", false)
    case .bottomMargin: (.layout, "Bottom margin", "layout.outer_bottom_gap spacing", false)
    case .leftMargin: (.layout, "Left margin", "layout.outer_left_gap spacing", false)
    case .animations: (.layout, "Enable animations", "animation.enabled", false)
    case .animationDuration: (.layout, "Animation duration", "animation.duration_ms", false)
    case .reservedTop: (.layout, "Reserved top area", "layout.reserved_top", true)
    case .reservedBottom: (.layout, "Reserved bottom area", "layout.reserved_bottom", true)
    case .hyperSymbol: (.input, "Show Hyper as ✦", "displayHyperSymbol hyper shortcut display", false)
    case .hyperShift: (.input, "Include Shift in Hyper", "displayHyperIncludesShift shortcut display", false)
    case .focusFollowsPointer: (.input, "Focus follows pointer", "input.focus_follows_mouse mouse", false)
    case .pointerFollowsFocus: (.input, "Move pointer to keyboard focus", "input.mouse_follows_focus mouse", false)
    case .pointerFocusScroll: (.input, "Maximum pointer-focus scroll", "input.focus_follows_mouse_max_scroll_amount mouse", true)
    case .defaultModifier: (.input, "Default key modifier", "default_key_modifier keyboard", true)
    case .modifierAliases: (.input, "Modifier aliases", "modifier_combinations alias modifiers", true)
    case .customShortcut: (.input, "Add Custom Shortcut…", "custom command keybinding keyboard binding", true)
    case .shortcutGuide: (.input, "Show guide when holding the main modifier", "show_cheatsheet_on_modifier_hold shortcut guide cheatsheet", false)
    case .keyboardShortcuts: (.input, "Keyboard shortcuts", "keys keybinding bindings record reset actions", false)
    case .focusedBorder: (.appearance, "Show focused window border", "decorations.borders.enabled", false)
    case .borderWidth: (.appearance, "Border width", "decorations.borders.width", false)
    case .focusedBorderColor: (.appearance, "Focused border color", "decorations.borders.color", false)
    case .unfocusedBorders: (.appearance, "Show unfocused window borders", "decorations.borders.inactive_enabled", true)
    case .unfocusedBorderColor: (.appearance, "Unfocused border color", "decorations.borders.inactive_color", true)
    case .captureBorders: (.appearance, "Include borders in screenshots", "decorations.borders.capture_enabled", true)
    case .borderPlacement: (.appearance, "Border placement", "decorations.borders.placement inside window outside window", true)
    case .overviewScale: (.appearance, "Scale", "overview.zoom scale", false)
    case .overviewCornerRadius: (.appearance, "Corner radius", "overview.window_corner_radius", false)
    case .windowPreviews: (.appearance, "Show optional window previews", "overview.window_previews screen recording", false)
    case .namedWorkspaces: (.workspaces, "Named workspaces", "workspaces.names workspace name rename reorder add delete", false)
    case .defaultWorkspace: (.workspaces, "Default workspace", "workspaces.default startup workspace", false)
    case .addAppRule: (.appRules, "Add App Rule…", "rules application rule add", false)
    case .appRules: (.appRules, "Application rules", "rules app rules add edit reorder remove", false)
    }
  }

  var page: SettingsPage { metadata.page }
  var title: String { metadata.title }
  var terms: String { metadata.terms }
  var isAdvanced: Bool { metadata.advanced }
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

  var isAdvanced: Bool {
    if case .option(let option) = self { return option.isAdvanced }
    return false
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
        context: $0.page.rawValue + ($0.isAdvanced ? " · Advanced" : ""), terms: $0.terms)
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
    let query = normalizedSearchText(query).split(whereSeparator: \.isWhitespace)
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
