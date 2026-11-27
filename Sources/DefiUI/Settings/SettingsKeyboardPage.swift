import AppKit
import DefiConfig
import DefiModel
import SwiftUI
import DefiMacOS

@MainActor
struct KeyboardSettingsView: View {
  let model: DefiSettingsModel
  let request: SettingsRevealRequest
  @AppStorage(displayModDefaultsKey) private var displayMod = false
  @State private var shortcutSheet: ShortcutSheet?
  @State private var search = ShortcutSearch()
  @State private var slotsCache = SettingsShortcutSlotsCache()

  var body: some View {
    let commands = SettingsShortcutActions.commands(workspaces: model.config.workspaces.names, rows: model.shortcutRows)
    let slots = slotsCache.slots(model: model, displayMod: displayMod)
    let active = search.active

    // The full list is built once and only hidden while results show: rebuilding hundreds of rows on
    // every search or scroll dropped frames. Only the field and the results read the search, so a
    // keystroke never evaluates this page.
    return VStack(spacing: 0) {
      ShortcutSearchBar(search: search)
      ZStack {
        // Its own hosting view, which AppKit skips while hidden: in the page's view graph its rows
        // weighed on every keystroke's update.
        SettingsIsolatedHost(hidden: active, content: SettingsShortcutListForm(
          model: model, commands: commands, slots: slots, request: request,
          onAdd: { shortcutSheet = ShortcutSheet(row: nil) }
        ).equatable())
        ShortcutSearchResults(model: model, commands: commands, slots: slots, search: search)
          .opacity(active ? 1 : 0)
          .allowsHitTesting(active)
          .accessibilityHidden(!active)
          // The shown list sits on top, so scroll events reach it.
          .zIndex(active ? 1 : -1)
      }
    }
    .modifier(SettingsRevealModifier(request: request, ready: revealReady, prepare: prepareReveal))
    .onChange(of: commands) { _, commands in
      if case .command(let command) = search.filter, !commands.contains(command) {
        search.set(.query(""))
      }
    }
    .settingsSubpage(item: $shortcutSheet, title: { $0.row == nil ? "New Shortcut" : "Edit Shortcut" }) { sheet in
      SettingsShortcutEditor(model: model, row: sheet.row)
    }
  }

  private var revealReady: Bool {
    // Reads the filter only for a shortcut reveal, so typing a search leaves this page alone.
    if case .shortcut(let command) = request.destination {
      return search.filter == .command(command)
        && SettingsShortcutActions.commands(workspaces: model.config.workspaces.names, rows: model.shortcutRows).contains(command)
    }
    return true
  }

  private func prepareReveal() {
    if case .shortcut(let command) = request.destination,
      SettingsShortcutActions.commands(workspaces: model.config.workspaces.names, rows: model.shortcutRows).contains(command)
    {
      search.set(.command(command))
    } else if case .command = search.filter {
      search.set(.query(""))
    } else if case .option = request.destination, search.filter.isActive {
      // A typed shortcut search hides the full list that holds the option; a plain page switch keeps it.
      search.set(.query(""))
    }
  }
}

/// The shortcut search, apart from the page: the field writes the text, the results read the filter,
/// and the page reads only whether a search is showing.
@MainActor
@Observable
final class ShortcutSearch {
  var query = ""
  private(set) var filter = SettingsShortcutFilter.query("")
  private(set) var active = false

  func filter(_ filter: SettingsShortcutFilter) {
    self.filter = filter
    if active != filter.isActive { active = filter.isActive }
  }

  /// Shows `filter` and puts its text in the field.
  func set(_ filter: SettingsShortcutFilter) {
    self.filter(filter)
    if query != filter.text { query = filter.text }
  }
}

/// Pinned above the list, so a search is one click away however far the list scrolled. Native: a
/// SwiftUI text field dropped a frame on every keystroke.
@MainActor
struct ShortcutSearchBar: View {
  let search: ShortcutSearch

  var body: some View {
    SettingsSearchField(text: Bindable(search).query, prompt: "Search shortcuts", large: true)
      .padding(.horizontal, 20)
      .padding(.top, 10)
      .padding(.bottom, 4)
      // The filter follows the text a beat later, so a keystroke draws before the rows change.
      .task(id: search.query) {
        guard search.query != search.filter.text else { return }
        try? await Task.sleep(for: .milliseconds(30))
        guard !Task.isCancelled else { return }
        search.filter(.query(search.query))
      }
  }
}

/// Kept alive while empty, so the first keystroke fills a list instead of building one. One card whose
/// rows sit directly in the scroll view's lazy stack: a card stack nested in it measured every row.
@MainActor
struct ShortcutSearchResults: View {
  let model: DefiSettingsModel
  let commands: [String]
  let slots: SettingsShortcutSlots
  let search: ShortcutSearch

  var body: some View {
    let filter = search.filter
    let visible = filter.isActive ? commands.filter(filter.includes) : []
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(visible, id: \.self) { command in
          VStack(spacing: 0) {
            if command != visible.first { Divider().padding(.leading, 12) }
            SettingsShortcutActionRow(command: command, slots: slots[command], live: filter == .command(command), model: model)
              .equatable()
              .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
          }
        }
        if filter.isActive && visible.isEmpty {
          Text("No matching actions.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
      }
      .background(SettingsCardBackground())
      .id(SettingsSearchAnchor.keyboardShortcuts)
      .padding(.horizontal, 20)
      .padding(.vertical, 14)
    }
  }
}

/// One action's shortcuts, read once for the whole page: each row filtering every binding made a long
/// page slow to scroll and to search.
struct SettingsShortcutSlots: Equatable {
  struct Slot: Equatable {
    let row: SettingsShortcutRow?
    let label: String
  }

  private let byCommand: [String: [Slot]]

  @MainActor init(model: DefiSettingsModel, displayMod: Bool) {
    let aliases = model.config.modifierAliases
    let resolution = model.shortcutResolution
    byCommand = Dictionary(grouping: model.shortcutRows, by: \.command).mapValues { rows in
      rows.map { Slot(row: $0, label: shortcutKeyLabel($0.accelerator, aliases: aliases, displayMod: displayMod,
        resolved: resolution)) }
    }
  }

  subscript(command: String) -> [Slot] { byCommand[command] ?? [Slot(row: nil, label: "Record Shortcut…")] }
}

/// Every action in its group's card, built once: a search only hides it, and typing never rebuilds it.
@MainActor
struct SettingsShortcutListForm: View, Equatable {
  let model: DefiSettingsModel
  let commands: [String]
  let slots: SettingsShortcutSlots
  /// Scrolls this list to a revealed option, as the page's own reader cannot reach into its host.
  let request: SettingsRevealRequest
  let onAdd: () -> Void
  @AppStorage(displayModDefaultsKey) private var displayMod = false

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.commands == rhs.commands && lhs.slots == rhs.slots && lhs.request == rhs.request
  }

  var body: some View {
    Form {
      if let keyboardMessage = DefiSettingsRuntimeStatus.shared.keyboardMessage {
        Section {
          Text(keyboardMessage)
            .foregroundStyle(.secondary)
        }
      }
      Section("Modifier key", symbol: "command", color: .gray) {
        ModKeyRow(model: model)
          .settingsSearchTarget(.modKey)
        Toggle(
          "Show mod (\(shortcutKeyLabel("mod-a", aliases: model.config.modifierAliases).dropLast())) as ✧",
          isOn: $displayMod
        )
          .settingsSearchTarget(.modSymbol)
        Toggle(SettingsOption.cheatsheet.title, isOn: Binding(
          get: { model.config.showCheatsheetOnModifierHold },
          set: { model.set(table: "", key: "show_cheatsheet_on_modifier_hold", value: $0 ? "true" : "false") }
        ))
        .settingsSearchTarget(.cheatsheet)
      }
      Section("Keyboard shortcuts", symbol: "keyboard", color: .indigo) {
        Button(action: onAdd) {
          SettingsAddLabel(title: SettingsOption.customShortcut.title)
        }
          .buttonStyle(.settingsNavigation)
          .settingsSearchTarget(.customShortcut)
      }
      .id(SettingsSearchAnchor.keyboardShortcuts)
      ForEach(SettingsShortcutGroup.groups(commands), id: \.title) { group in
        Section(group.title, symbol: group.symbol, color: group.color) {
          ForEach(group.commands, id: \.self) { command in
            SettingsShortcutActionRow(command: command, slots: slots[command], live: false, model: model)
              .equatable()
          }
        }
      }
    }
    .formStyle(.settingsCards)
    .modifier(SettingsRevealModifier(request: request))
  }
}

/// A view in a hosting view of its own, hidden by AppKit rather than by opacity.
struct SettingsIsolatedHost<Content: View>: NSViewRepresentable {
  let hidden: Bool
  let content: Content

  func makeNSView(context: Context) -> NSHostingView<Content> {
    let host = NSHostingView(rootView: content)
    host.sizingOptions = []
    return host
  }

  func updateNSView(_ host: NSHostingView<Content>, context: Context) {
    host.rootView = content
    host.isHidden = hidden
  }
}

/// Keeps the slots between keystrokes of a search: labels are parsed once per change of the shortcuts.
@MainActor
final class SettingsShortcutSlotsCache {
  private var key: (config: Config, rows: [SettingsShortcutRow], resolution: Int, displayMod: Bool)?
  private var slots: SettingsShortcutSlots?

  func slots(model: DefiSettingsModel, displayMod: Bool) -> SettingsShortcutSlots {
    if let key, let slots, key.config == model.config, key.rows == model.shortcutRows,
      key.resolution == model.shortcutResolutionVersion, key.displayMod == displayMod {
      return slots
    }
    let slots = SettingsShortcutSlots(model: model, displayMod: displayMod)
    key = (model.config, model.shortcutRows, model.shortcutResolutionVersion, displayMod)
    self.slots = slots
    return slots
  }
}

@MainActor
struct SettingsShortcutActionRow: View, Equatable {
  let command: String
  let slots: [SettingsShortcutSlots.Slot]
  let live: Bool
  let model: DefiSettingsModel

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.command == rhs.command && lhs.slots == rhs.slots && lhs.live == rhs.live
  }

  var body: some View {
    HStack {
      Text(SettingsSearchCatalog.commandTitle(command))
        .frame(maxWidth: .infinity, alignment: .leading)
      // Keyed by position, not by keys: a new shortcut morphs the same pill instead of replacing it.
      VStack(alignment: .trailing) {
        ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
          HStack {
            if let row = slot.row, !row.isEnabled {
              Text("Disabled").foregroundStyle(.secondary)
              Button("Reset to Default") { model.restoreShortcut(row) }
            } else {
              recorder(slot)
            }
            Button { if let row = slot.row { model.removeShortcut(row) } } label: {
              Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
            // Plain, not borderless: a borderless button is an AppKit control, costly in every row.
            .buttonStyle(.plain)
            .accessibilityLabel("Remove shortcut for \(command)")
            .disabled(slot.row?.isEnabled != true)
            .opacity(slot.row == nil ? 0 : 1)
          }
        }
      }
    }
  }

  private func recorder(_ slot: SettingsShortcutSlots.Slot) -> some View {
    SettingsShortcutField(
      label: slot.label, command: command, live: live, unset: slot.row == nil,
      onRecord: { model.saveShortcut(slot.row, accelerator: $0, command: command) }
    )
    .frame(width: 170, height: 28)
    // One branch whatever the row: a new shortcut becomes restorable, and swapping views lost the morph.
    .contextMenu {
      if let row = slot.row, row.canRestore {
        Button("Reset to Default") { model.restoreShortcut(row) }
      }
    }
  }
}

struct ShortcutSheet: Identifiable {
  let id = UUID()
  let row: SettingsShortcutRow?
}

@MainActor
struct SettingsShortcutEditor: View {
  @AppStorage(displayModDefaultsKey) private var displayMod = false
  let model: DefiSettingsModel
  @Environment(\.closeSettingsSubpage) private var dismiss
  @State private var sourceRow: SettingsShortcutRow?
  @State private var sourceWasRemoved = false
  @State private var accelerator: String
  @State private var action: String
  @State private var argument: String
  @State private var customCommand: String
  @State private var usesCustomCommand: Bool

  private var argumentKind: CommandArgument {
    SettingsShortcutActions.argumentKind(for: action)
  }

  private var isArgumentValid: Bool {
    SettingsShortcutActions.accepted(
      argument, for: action, workspaces: model.config.workspaces.names)
  }

  init(model: DefiSettingsModel, row: SettingsShortcutRow?) {
    self.model = model
    _sourceRow = State(initialValue: row)
    _sourceWasRemoved = State(initialValue: false)
    let command = row?.command ?? "focus-column left"
    let parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
    let isKnown = SettingsShortcutActions.isKnown(parts.first ?? "")
    _accelerator = State(initialValue: row?.accelerator ?? "")
    _action = State(initialValue: isKnown ? parts[0] : SettingsShortcutActions.actions[0])
    _argument = State(initialValue: isKnown && parts.count > 1
      ? parts[1] : SettingsShortcutActions.defaultArgument(workspaces: model.config.workspaces.names))
    _customCommand = State(initialValue: command)
    _usesCustomCommand = State(initialValue: !isKnown)
  }

  var body: some View {
    Form {
      Section("Shortcut") {
        SettingsShortcutField(
          label: accelerator.isEmpty
            ? "Record Shortcut…"
            : shortcutKeyLabel(accelerator, aliases: model.config.modifierAliases,
              displayMod: displayMod,
              resolved: model.shortcutResolution),
          command: sourceRow?.command ?? "New shortcut",
          unset: accelerator.isEmpty,
          onRecord: { accelerator = $0 }
        )
        Text("Use Control, Option, or Command with a supported key.")
          .settingsNote()
      }
      Section("Action") {
        Toggle("Custom command…", isOn: $usesCustomCommand)
        if usesCustomCommand {
          TextField("Command", text: $customCommand)
            .font(.body.monospaced())
          Text("Use any command documented in the configuration guide.")
            .settingsNote()
        } else {
          Picker("Action", selection: $action) {
            ForEach(SettingsShortcutActions.actions, id: \.self) { value in
              Text(value.replacingOccurrences(of: "-", with: " ").capitalized).tag(value)
            }
          }
          if argumentKind != .none {
            switch argumentKind {
            case .workspaceOrRelative:
              Picker("Workspace target", selection: $argument) {
                Text("Up").tag("up")
                Text("Down").tag("down")
                ForEach(model.config.workspaces.names, id: \.self) { name in Text(name).tag(name) }
              }
            case .workspaceName:
              Picker("Workspace", selection: $argument) {
                ForEach(model.config.workspaces.names, id: \.self) { name in Text(name).tag(name) }
              }
            case .keywords(let options):
              Picker("Argument", selection: $argument) {
                if !options.contains(argument) { Text(argument).tag(argument) }
                ForEach(options, id: \.self) { Text($0.capitalized).tag($0) }
              }
            case .workspacePosition:
              TextField("Position", text: $argument)
                .help("Enter a 1-based workspace position.")
            case .text, .none:
              TextField("Argument", text: $argument)
                .help("Enter the argument accepted by this action.")
            }
          }
        }
      }
    }
    .formStyle(.settingsCards)
    .safeAreaInset(edge: .bottom) {
      SettingsSubpageActions {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save") {
          model.dismissMessage()
          let command = usesCustomCommand
            ? customCommand
            : argumentKind == .none ? action : "\(action) \(argument)"
          model.saveShortcut(sourceRow, accelerator: accelerator, command: command)
          if model.message == nil { dismiss() }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(sourceWasRemoved || accelerator.isEmpty || (usesCustomCommand ? customCommand.isEmpty : !isArgumentValid))
      }
    }
    .onChange(of: action) { _, newAction in
      let kind = SettingsShortcutActions.argumentKind(for: newAction)
      switch kind {
      case .keywords(let options):
        if !options.contains(argument) { argument = options[0] }
      case .workspaceName:
        if !model.config.workspaces.names.contains(argument) {
          argument = model.config.workspaces.names.first ?? ""
        }
      case .workspaceOrRelative:
        if !["up", "down"].contains(argument), !model.config.workspaces.names.contains(argument) {
          argument = model.config.workspaces.names.first ?? "up"
        }
      case .workspacePosition:
        if !(Int(argument).map { $0 > 0 } ?? false) { argument = "1" }
      case .text, .none:
        break
      }
    }
    .onChange(of: model.shortcutRows) { _, rows in
      refreshEditedShortcut(from: rows)
    }
    .onAppear { refreshEditedShortcut(from: model.shortcutRows) }
    .overlay(alignment: .bottom) {
      if sourceWasRemoved {
        Text("This shortcut was removed in the configuration file. Close this editor and choose another shortcut.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.bottom, 12)
      }
    }
  }

  private func refreshEditedShortcut(from rows: [SettingsShortcutRow]) {
    guard let sourceRow else { return }
    let matches = rows.filter { $0.accelerator == sourceRow.accelerator }
    let matchingRow = matches.first ?? {
      if let defaultAccelerator = sourceRow.defaultAccelerator {
        let defaultMatches = rows.filter { $0.defaultAccelerator == defaultAccelerator }
        if defaultMatches.count == 1 { return defaultMatches.first }
      }
      let commandMatches = rows.filter { $0.command == sourceRow.command }
      return commandMatches.count == 1 ? commandMatches.first : nil
    }()
    guard let matchingRow else {
      sourceWasRemoved = true
      return
    }
    guard matchingRow != sourceRow else { return }
    self.sourceRow = matchingRow
    sourceWasRemoved = false
    accelerator = matchingRow.accelerator
    let parts = matchingRow.command.split(whereSeparator: \.isWhitespace).map(String.init)
    let isKnown = SettingsShortcutActions.isKnown(parts.first ?? "")
    action = isKnown ? parts[0] : SettingsShortcutActions.actions[0]
    argument = isKnown && parts.count > 1
      ? parts[1] : SettingsShortcutActions.defaultArgument(workspaces: model.config.workspaces.names)
    customCommand = matchingRow.command
    usesCustomCommand = !isKnown
  }
}

/// Modifiers in macOS display order: config name, symbol, and spoken name.
let modifierOrder: [(name: String, symbol: String, title: String)] = [
  ("ctrl", "⌃", "Control"), ("alt", "⌥", "Option"), ("shift", "⇧", "Shift"), ("cmd", "⌘", "Command"),
]

@MainActor
struct ModKeyRow: View {
  let model: DefiSettingsModel

  /// Names in `mod`; the config already rejects anything else.
  private var selection: Set<String> {
    let names = (normalizedAccelerator("mod-a", aliases: model.config.modifierAliases) ?? "").split(separator: "-")
    return Set(names.dropLast().map(String.init))
  }

  private func save(_ names: Set<String>) {
    let value = modifierOrder.filter { names.contains($0.name) }.map(\.name).joined(separator: "+")
    model.set(table: "", key: "mod", value: value == Config.defaultMod ? nil : tomlString(value))
  }

  var body: some View {
    HStack {
      SettingsInfoLabel(SettingsOption.modKey.title,
        "Every built-in shortcut and each mod- shortcut you write uses these modifiers.")
      Spacer()
      HStack(spacing: 4) {
        ForEach(modifierOrder, id: \.name) { modifier in
          Toggle(modifier.symbol, isOn: Binding(
            get: { selection.contains(modifier.name) },
            set: { on in
              var names = selection
              if on { names.insert(modifier.name) } else { names.remove(modifier.name) }
              if !names.isEmpty { save(names) }
            }
          ))
          .toggleStyle(.button)
          .help(modifier.title)
          .accessibilityLabel(modifier.title)
        }
      }
      Button("Reset") { model.set(table: "", key: "mod", value: nil) }
        .disabled(model.config.mod == Config.defaultMod)
        .help("Use Control–Option")
    }
  }
}
