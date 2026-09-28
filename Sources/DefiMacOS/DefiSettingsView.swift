import AppKit
import DefiConfig
import SwiftUI

@MainActor
public struct DefiSettingsView: View {
  @State private var model: DefiSettingsModel
  @State private var selection: SettingsPage? = .general

  public init(configURL: URL = Config.defaultURL) {
    _model = State(initialValue: DefiSettingsModel(configURL: configURL))
  }

  public var body: some View {
    NavigationSplitView(columnVisibility: .constant(.all)) {
      List(SettingsPage.allCases, selection: $selection) { page in
        Label {
          Text(page.rawValue)
        } icon: {
          Image(systemName: page.symbol)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
            .frame(width: 20, height: 20)
            .background(page.color, in: RoundedRectangle(cornerRadius: 4))
        }
        .tag(page)
      }
      .listStyle(.sidebar)
      .navigationTitle("Settings")
      .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
      .toolbar(removing: .sidebarToggle)
    } detail: {
      SettingsPageView(page: selection ?? .general, model: model)
        .navigationTitle((selection ?? .general).rawValue)
    }
    .frame(minWidth: 860, idealWidth: 920, minHeight: 620, idealHeight: 680)
    .task {
      model.refreshSystemStatus()
      model.startWatching()
    }
    .onAppear {
      NSApplication.shared.setActivationPolicy(.regular)
      NSApplication.shared.activate()
    }
    .onDisappear {
      model.stopWatching()
      NSApplication.shared.setActivationPolicy(.accessory)
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
    ) { _ in
      model.refreshDisplays()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      model.refreshSystemStatus()
    }
    .alert(
      "Defi Settings",
      isPresented: Binding(
        get: { model.message != nil },
        set: { if !$0 { model.dismissMessage() } }
      )
    ) {
      Button("Open Configuration File") { model.openConfiguration() }
      Button("OK", role: .cancel) { model.dismissMessage() }
    } message: {
      Text(model.message ?? "")
    }
  }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
  case general = "General"
  case layout = "Layout"
  case input = "Input"
  case appearance = "Appearance"
  case workspaces = "Workspaces"
  case appRules = "App Rules"

  var id: Self { self }
  var color: Color {
    switch self {
    case .general: .gray
    case .layout: .teal
    case .input: .blue
    case .appearance: .purple
    case .workspaces: .indigo
    case .appRules: .orange
    }
  }
  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .layout: "rectangle.split.2x1"
    case .input: "keyboard"
    case .appearance: "paintpalette"
    case .workspaces: "rectangle.3.group"
    case .appRules: "app"
    }
  }
}

@MainActor
private struct SettingsPageView: View {
  let page: SettingsPage
  let model: DefiSettingsModel

  var body: some View {
    switch page {
    case .general: GeneralSettingsView(model: model)
    case .layout: LayoutSettingsView(model: model)
    case .input: InputSettingsView(model: model)
    case .appearance: AppearanceSettingsView(model: model)
    case .workspaces: WorkspaceSettingsView(model: model)
    case .appRules: AppRulesSettingsView(model: model)
    }
  }
}

@MainActor
private struct GeneralSettingsView: View {
  let model: DefiSettingsModel

  var body: some View {
    Form {
      Section("Permissions") {
        LabeledContent(
          "Accessibility", value: model.accessibilityGranted ? "Granted" : "Not granted")
        if !model.accessibilityGranted {
          Button("Open Accessibility Settings…") { model.openAccessibilitySettings() }
        }
      }
      Section("General") {
        Toggle(
          "Launch Defi at login",
          isOn: Binding(
            get: { model.launchAtLoginEnabled },
            set: { model.setLaunchAtLogin($0) }
          ))
        if let notice = model.launchAtLoginNotice {
          Text(notice)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Toggle(
          "Show Defi in the menu bar",
          isOn: Binding(
            get: { model.config.menuBar.enabled },
            set: { model.set(table: "menu_bar", key: "enabled", value: $0 ? "true" : "false") }
          ))
        Picker("Named workspace display", selection: Binding(
          get: { model.config.menuBar.workspaceStyle },
          set: { model.set(table: "menu_bar", key: "workspace_style", value: tomlString($0.rawValue)) }
        )) {
          Text("Name only").tag(WorkspaceLabelStyle.name)
          Text("Icon only").tag(WorkspaceLabelStyle.icon)
          Text("Icon and name").tag(WorkspaceLabelStyle.iconAndName)
        }
      }
      Section("Configuration") {
        LabeledContent("File", value: model.configurationPath)
          .textSelection(.enabled)
        HStack {
          Button("Open Configuration File…") { model.openConfiguration() }
          Button("Configuration Guide…") { model.openDocumentation() }
        }
      }
      Section("Diagnostics") {
        Button("Open Logs Folder…") { model.openLogs() }
      }
      AboutSettingsSection()
    }
    .formStyle(.grouped)
  }
}

private struct AboutSettingsSection: View {
  var body: some View {
    Section("About") {
      LabeledContent(
        "Defi",
        value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
          ?? "Development build")
      if let repositoryURL = URL(string: "https://github.com/qeude/Defi") {
        Link(destination: repositoryURL) {
          Label("View on GitHub", systemImage: "arrow.up.right.square")
        }
      }
    }
  }
}

@MainActor
private struct LayoutSettingsView: View {
  let model: DefiSettingsModel
  @State private var advancedExpanded = false

  var body: some View {
    Form {
      Section("Columns") {
        SettingsNumberRow(
          title: "Default column width", value: model.config.layout.defaultColumnWidth * 100,
          range: 5...100, step: 5, unit: "%",

          onChange: { model.set(table: "layout", key: "default_column_width", value: String($0 / 100)) }
        )
        Picker(
          "Focused column",
          selection: stringBinding(
            "layout", "center_focused_column", model.config.layout.centerFocusedColumn.rawValue)
        ) {
          Text("Reveal as needed").tag("never")
          Text("Always center").tag("always")
        }
      }
      WidthPresetsSettings(model: model)
      Section("Spacing") {
        SettingsNumberRow(
          title: "Default gap", value: model.config.layout.gaps, range: 0...256, step: 1,
          unit: "px",
          onChange: { model.set(table: "layout", key: "gaps", value: String($0)) }
        )
        marginRow("Top", key: "outer_top_gap", value: model.config.layout.outerTopGap)
        marginRow("Right", key: "outer_right_gap", value: model.config.layout.outerRightGap)
        marginRow("Bottom", key: "outer_bottom_gap", value: model.config.layout.outerBottomGap)
        marginRow("Left", key: "outer_left_gap", value: model.config.layout.outerLeftGap)
      }
      Section("Animation") {
        settingsToggle(
          model, title: "Enable animations", table: "animation", key: "enabled",
          value: model.config.animation.enabled
        )
        SettingsNumberRow(
          title: "Animation duration", value: Double(model.config.animation.durationMS),
          range: 0...2_000, step: 5, unit: "ms",

          onChange: { model.set(table: "animation", key: "duration_ms", value: String(Int($0.rounded()))) }
        )
      }
      Section("Advanced", isExpanded: $advancedExpanded) {
        SettingsNumberRow(
          title: "Reserved top area", value: model.config.layout.reservedTop,
          range: 0...512, step: 1, unit: "px",

          onChange: { model.set(table: "layout", key: "reserved_top", value: String($0)) }
        )
        SettingsNumberRow(
          title: "Reserved bottom area", value: model.config.layout.reservedBottom,
          range: 0...512, step: 1, unit: "px",

          onChange: { model.set(table: "layout", key: "reserved_bottom", value: String($0)) }
        )
      }
    }
    .formStyle(.grouped)
  }

  private func marginRow(_ title: String, key: String, value: Double?) -> some View {
    SettingsNumberRow(
      title: "\(title) margin", value: value ?? model.config.layout.gaps,
      range: 0...256, step: 1, unit: "px",

      onChange: { model.set(table: "layout", key: key, value: String($0)) }
    )
  }

  private func stringBinding(_ table: String, _ key: String, _ value: String) -> Binding<String> {
    Binding(get: { value }, set: { model.set(table: table, key: key, value: tomlString($0)) })
  }
}

@MainActor
private struct WidthPresetsSettings: View {
  let model: DefiSettingsModel

  var body: some View {
    Section {
      ForEach(model.config.layout.presetColumnWidths.indices, id: \.self) { index in
        HStack {
          Text("Preset \(index + 1)")
          Slider(value: Binding(
            get: { model.config.layout.presetColumnWidths[index] * 100 },
            set: { update(index, percentage: $0) }
          ), in: 5...100, step: 5)
          .accessibilityLabel("Preset \(index + 1) width")
          TextField("Width", value: Binding(
            get: { model.config.layout.presetColumnWidths[index] * 100 },
            set: { update(index, percentage: $0) }
          ), format: .number.precision(.fractionLength(0...2)))
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .frame(width: 65)
          Text("%").foregroundStyle(.secondary)
          Button {
            var widths = model.config.layout.presetColumnWidths
            widths.remove(at: index)
            save(widths)
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .disabled(model.config.layout.presetColumnWidths.count == 1)
          .accessibilityLabel("Remove preset \(index + 1)")
        }
      }
    } header: {
      HStack {
        Text("Width presets")
        Spacer()
        Menu {
          ForEach([25, 33, 50, 67, 75, 100], id: \.self) { percentage in
            Button("\(percentage)%") {
              save(model.config.layout.presetColumnWidths + [Double(percentage) / 100])
            }
          }
        } label: {
          Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Add width preset")
      }
    } footer: {
      Text("Cycle Width switches between these sizes in list order.")
    }
  }

  private func update(_ index: Int, percentage: Double) {
    var widths = model.config.layout.presetColumnWidths
    widths[index] = percentage / 100
    save(widths)
  }

  private func save(_ widths: [Double]) {
    model.set(table: "layout", key: "preset_column_widths",
      value: "[\(widths.map { String($0) }.joined(separator: ", "))]")
  }
}

@MainActor
private struct InputSettingsView: View {
  let model: DefiSettingsModel
  @AppStorage("displayHyperSymbol") private var displayHyper = true
  @AppStorage("displayHyperIncludesShift") private var hyperIncludesShift = false
  @State private var shortcutSheet: ShortcutSheet?
  @State private var shortcutSearch = ""
  @State private var advancedExpanded = false

  var body: some View {
    Form {
      Section {
        Text(DefiSettingsRuntimeStatus.shared.keyboardMessage)
          .foregroundStyle(.secondary)
      }
      Section("Shortcut display") {
        Toggle("Show Hyper (\(hyperIncludesShift ? "⌃⌥⇧⌘" : "⌃⌥⌘")) as ✦", isOn: $displayHyper)
        Toggle("Include Shift in Hyper", isOn: $hyperIncludesShift)
          .disabled(!displayHyper)
      }
      Section("Pointer") {
        Toggle("Focus follows pointer", isOn: boolBinding("input", "focus_follows_mouse", model.config.input.focusFollowsMouse))
        Toggle("Move pointer to keyboard focus", isOn: boolBinding("input", "mouse_follows_focus", model.config.input.mouseFollowsFocus))
      }
      Section("Advanced", isExpanded: $advancedExpanded) {
        SettingsNumberRow(
          title: "Maximum pointer-focus scroll",
          value: (model.config.input.focusFollowsMouseMaxScrollAmount ?? 0) * 100,
          range: 0...100, step: 1, unit: "%",

          onChange: { model.set(table: "input", key: "focus_follows_mouse_max_scroll_amount", value: String($0 / 100)) }
        )
        DefaultModifierField(model: model)
        ModifierAliasesSettings(model: model)
        Button("Add Custom Shortcut…") { shortcutSheet = ShortcutSheet(row: nil) }
      }
      Section("Shortcut guide") {
        Toggle("Show guide when holding the main modifier", isOn: Binding(
          get: { model.config.showCheatsheetOnModifierHold },
          set: { model.set(table: "", key: "show_cheatsheet_on_modifier_hold", value: $0 ? "true" : "false") }
        ))
      }
      Section {
        ForEach(shortcutCommands, id: \.self) { command in
          SettingsShortcutActionRow(
            command: command, model: model,
            displayHyper: displayHyper, hyperIncludesShift: hyperIncludesShift
          )
        }
        if shortcutCommands.isEmpty {
          Text("No matching actions.").foregroundStyle(.secondary)
        }
      } header: {
        HStack {
          Text("Keyboard shortcuts")
          Spacer()
          TextField("Search actions", text: $shortcutSearch, prompt: Text("Search actions"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(.body)
            .frame(width: 220)
        }
      }
    }
    .formStyle(.grouped)
    .sheet(item: $shortcutSheet) { sheet in
      SettingsShortcutEditor(model: model, row: sheet.row)
    }
  }

  private var shortcutCommands: [String] {
    let commands = Set(SettingsShortcutActions.availableCommands(workspaces: model.config.workspaces.names)
      + model.shortcutRows.map(\.command))
    return commands.sorted().filter {
      shortcutSearch.isEmpty || $0.replacingOccurrences(of: "-", with: " ")
        .localizedCaseInsensitiveContains(shortcutSearch.replacingOccurrences(of: "-", with: " "))
    }
  }

  private func boolBinding(_ table: String, _ key: String, _ value: Bool) -> Binding<Bool> {
    Binding(
      get: { valueForField(table, key) ?? value },
      set: {
        model.set(table: table, key: key, value: $0 ? "true" : "false")
      })
  }

  private func valueForField(_ table: String, _ key: String) -> Bool? {
    switch (table, key) {
    case ("input", "focus_follows_mouse"): model.config.input.focusFollowsMouse
    case ("input", "mouse_follows_focus"): model.config.input.mouseFollowsFocus
    default: nil
    }
  }
}

@MainActor
private struct SettingsShortcutActionRow: View {
  let command: String
  let model: DefiSettingsModel
  let displayHyper: Bool
  let hyperIncludesShift: Bool

  var body: some View {
    HStack {
      Text(command.replacingOccurrences(of: "-", with: " ").capitalized)
        .frame(maxWidth: .infinity, alignment: .leading)
      let bindings = model.shortcutRows.filter { $0.command == command }
      if bindings.isEmpty {
        recorder(nil)
      } else {
        VStack(alignment: .trailing) {
          ForEach(bindings) { row in
            HStack {
              if row.isEnabled {
                recorder(row)
              } else {
                Text("Disabled").foregroundStyle(.secondary)
                Button("Reset to Default") { model.restoreShortcut(row) }
              }
              Button { model.removeShortcut(row) } label: {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.borderless)
              .accessibilityLabel("Remove shortcut for \(command)")
              .disabled(!row.isEnabled)
            }
          }
        }
      }
    }
  }

  private func recorder(_ row: SettingsShortcutRow?) -> some View {
    SettingsShortcutRecorder(
      label: row.map {
        shortcutKeyLabel($0.accelerator, aliases: model.config.modifierCombinations,
          displayHyper: displayHyper, hyperIncludesShift: hyperIncludesShift)
      } ?? "Record Shortcut…",
      command: command,
      onRecord: { model.saveShortcut(row, accelerator: $0, command: command) }
    )
    .frame(width: 170, height: 28)
    .contextMenu {
      if let row, row.canRestore {
        Button("Reset to Default") { model.restoreShortcut(row) }
      }
    }
  }
}

@MainActor
private struct AppearanceSettingsView: View {
  let model: DefiSettingsModel
  var body: some View {
    Form {
      Section("Window borders") {
        settingsToggle(
          model, title: "Show focused window border", table: "decorations.borders",
          key: "enabled", value: model.config.decorations.borders.enabled
        )
        SettingsNumberRow(
          title: "Border width", value: model.config.decorations.borders.width,
          range: 0...64, step: 1, unit: "px",

          onChange: { model.set(table: "decorations.borders", key: "width", value: String($0)) }
        )
        ColorPicker("Focused border color", selection: colorBinding("color"), supportsOpacity: true)
        DisclosureGroup("Advanced") {
          settingsToggle(
            model, title: "Show unfocused window borders", table: "decorations.borders",
            key: "inactive_enabled", value: model.config.decorations.borders.inactiveEnabled
          )
          ColorPicker("Unfocused border color", selection: colorBinding("inactive_color"), supportsOpacity: true)
          settingsToggle(
            model, title: "Include borders in screenshots", table: "decorations.borders",
            key: "capture_enabled", value: model.config.decorations.borders.captureEnabled
          )
          Picker("Border placement", selection: stringBinding(
            model, table: "decorations.borders", key: "placement", value: model.config.decorations.borders.placement
          )) {
            Text("Inside window").tag("inside")
            Text("Outside window").tag("outside")
          }
        }
      }
      Section("Overview") {
        SettingsNumberRow(
          title: "Scale", value: model.config.overview.zoom * 100,
          range: 0...75, step: 5, unit: "%",

          onChange: { model.set(table: "overview", key: "zoom", value: String($0 / 100)) }
        )
        SettingsNumberRow(
          title: "Corner radius", value: model.config.overview.windowCornerRadius,
          range: 0...64, step: 1, unit: "px",

          onChange: { model.set(table: "overview", key: "window_corner_radius", value: String($0)) }
        )
        settingsToggle(
          model, title: "Show optional window previews", table: "overview",
          key: "window_previews", value: model.config.overview.windowPreviews
        )
        if model.config.overview.windowPreviews && !model.screenCaptureAvailable {
          Text("Screen Recording permission is required for previews. Overview still works without them.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func colorBinding(_ key: String) -> Binding<Color> {
    Binding(
      get: { settingsColor(key == "color" ? model.config.decorations.borders.color : model.config.decorations.borders.inactiveColor) },
      set: { model.set(table: "decorations.borders", key: key, value: tomlString(settingsHexColor($0))) }
    )
  }
}

@MainActor
private struct WorkspaceSettingsView: View {
  let model: DefiSettingsModel
  @State private var newName = ""
  @State private var isAddingWorkspace = false
  @State private var workspaceToDelete: String?

  var body: some View {
    Form {
      Section {
        if model.config.workspaces.names.isEmpty {
          Text("No named workspaces are configured.")
            .foregroundStyle(.secondary)
        }
        ForEach(model.config.workspaces.names, id: \.self) { name in
          let index = model.config.workspaces.names.firstIndex(of: name) ?? 0
          workspaceRow(name, index: index)
        }
        .settingsReorderable()
      } header: {
        HStack {
          Text("Named workspaces")
          Spacer()
          Button {
            newName = ""
            isAddingWorkspace = true
          } label: {
            Image(systemName: "plus")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Add workspace")
          .help("Add workspace")
        }
      }
      Section("Startup workspace") {
        Picker(
          "Default workspace",
          selection: Binding(
            get: { model.config.workspaces.defaultName ?? "" },
            set: {
              model.set(
                table: "workspaces", key: "default", value: $0.isEmpty ? nil : tomlString($0))
            }
          )
        ) {
          Text("First declared workspace").tag("")
          ForEach(model.config.workspaces.names, id: \.self) { name in Text(name).tag(name) }
        }
      }
      if model.displays.isEmpty {
        Section("Displays") {
          Text("No display identity is available. Display affinity remains unchanged.")
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .modifier(SettingsReorderContainer(itemID: \String.self, move: model.reorderWorkspaces))
    .alert("Add Workspace", isPresented: $isAddingWorkspace) {
      TextField("Workspace name", text: $newName, prompt: Text("e.g. design"))
      Button("Cancel", role: .cancel) {}
      Button("Add") { addWorkspace() }
        .keyboardShortcut(.defaultAction)
        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .confirmationDialog(
      "Delete workspace ‘\(workspaceToDelete ?? "")’?",
      isPresented: Binding(
        get: { workspaceToDelete != nil },
        set: { if !$0 { workspaceToDelete = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Workspace", role: .destructive) {
        if let workspaceToDelete { model.removeWorkspace(workspaceToDelete, clearingRuleAssignments: true) }
        workspaceToDelete = nil
      }
      Button("Cancel", role: .cancel) { workspaceToDelete = nil }
    } message: {
      if let workspaceToDelete {
        let references = model.rulesReferencingWorkspace(workspaceToDelete)
        if references.isEmpty {
          Text("This removes the named workspace configuration.")
        } else {
          Text("Workspace assignments will be removed from these rules. Their other actions will be kept: \(references.joined(separator: ", ")).")
        }
      }
    }
  }

  private func workspaceRow(_ name: String, index: Int) -> some View {
    HStack {
      if #available(macOS 27, *) {
        Image(systemName: "line.3.horizontal")
          .foregroundStyle(.tertiary)
          .help("Drag to reorder")
          .accessibilityHidden(true)
      }
      WorkspaceIconPicker(name: name, model: model)
      WorkspaceNameEditor(name: name, model: model)
        .frame(maxWidth: .infinity, alignment: .leading)
      Picker(
        "Display",
        selection: Binding(
          get: { model.workspaceMonitorSelection(name) },
          set: { model.setWorkspaceMonitor(name, identifier: $0) }
        )
      ) {
        Text("Automatic").tag("")
        ForEach(model.displays) { display in Text(display.label).tag(display.id) }
        ForEach(1...max(8, model.displays.count), id: \.self) { position in
          Text("Display position \(position)").tag("legacy-position:\(position)")
        }
        if let offline = model.disconnectedMonitorOption(for: name) {
          Text(offline.label).tag(offline.id)
        }
        let legacy = model.workspaceMonitorSelection(name)
        if let position = model.workspaceMonitorPosition(name), position > max(8, model.displays.count) {
          Text("Display position \(position)").tag(legacy)
        }
      }
      .labelsHidden()
      if model.workspaceMonitorPosition(name) != nil {
        WorkspacePositionField(name: name, model: model)
      }
      if #available(macOS 27, *) {
        EmptyView()
      } else {
        Button { model.moveWorkspace(from: index, to: max(index - 1, 0)) } label: {
          Image(systemName: "chevron.up")
        }
        .buttonStyle(.borderless)
        .disabled(index == 0)
        .help("Move workspace earlier")
        Button { model.moveWorkspace(from: index, to: min(index + 1, model.config.workspaces.names.count - 1)) } label: {
          Image(systemName: "chevron.down")
        }
        .buttonStyle(.borderless)
        .disabled(index == model.config.workspaces.names.count - 1)
        .help("Move workspace later")
      }
      Button(role: .destructive) { workspaceToDelete = name } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("Delete named workspace")
    }
    .accessibilityAction(named: Text("Move workspace earlier")) {
      model.moveWorkspace(from: index, to: max(index - 1, 0))
    }
    .accessibilityAction(named: Text("Move workspace later")) {
      model.moveWorkspace(from: index, to: min(index + 1, model.config.workspaces.names.count - 1))
    }
  }

  private func addWorkspace() {
    model.addWorkspace(newName)
    if model.config.workspaces.names.contains(
      newName.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      newName = ""
    }
  }
}

@MainActor
private struct WorkspaceIconPicker: View {
  let name: String
  let model: DefiSettingsModel
  @State private var isPresented = false
  @State private var customSymbol = ""
  private let symbols = [
    "square.grid.2x2", "house", "desktopcomputer", "laptopcomputer", "terminal", "curlybraces",
    "globe", "safari", "hammer", "wrench.and.screwdriver", "folder", "doc", "book", "pencil",
    "paintbrush", "photo", "camera", "film", "music.note", "headphones", "gamecontroller",
    "message", "envelope", "calendar", "checklist", "chart.bar", "briefcase", "cup.and.saucer",
    "star", "heart", "bolt", "moon",
  ]

  var body: some View {
    Button {
      customSymbol = model.config.workspaces.icons[name] ?? ""
      isPresented = true
    } label: {
      Image(systemName: model.config.workspaces.icons[name].flatMap {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0
      } ?? "square.grid.2x2")
      .frame(width: 20, height: 20)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel("Choose icon for \(name)")
    .popover(isPresented: $isPresented) {
      VStack(alignment: .leading, spacing: 16) {
        Text("Workspace icon").font(.headline)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(32)), count: 8), spacing: 8) {
          ForEach(symbols, id: \.self) { symbol in
            Button {
              model.setWorkspaceIcon(name, symbol: symbol)
              isPresented = false
            } label: {
              Image(systemName: symbol).frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help(symbol)
            .accessibilityLabel(symbol)
          }
        }
        TextField("SF Symbol name", text: $customSymbol, prompt: Text("e.g. airplane"))
          .textFieldStyle(.roundedBorder)
          .onSubmit(saveCustomSymbol)
        HStack {
          Button("No custom icon") {
            model.setWorkspaceIcon(name, symbol: nil)
            isPresented = false
          }
          Spacer()
          Button("Use Symbol", action: saveCustomSymbol)
            .disabled(NSImage(systemSymbolName: customSymbol, accessibilityDescription: nil) == nil)
        }
      }
      .padding()
    }
  }

  private func saveCustomSymbol() {
    guard NSImage(systemSymbolName: customSymbol, accessibilityDescription: nil) != nil else { return }
    model.setWorkspaceIcon(name, symbol: customSymbol)
    isPresented = false
  }
}

@MainActor
private struct WorkspaceNameEditor: View {
  let name: String
  let model: DefiSettingsModel
  @State private var isEditing = false
  @State private var draft: String
  @FocusState private var focused: Bool

  init(name: String, model: DefiSettingsModel) {
    self.name = name
    self.model = model
    _draft = State(initialValue: name)
  }

  var body: some View {
    HStack {
      if isEditing {
        TextField("Workspace name", text: $draft)
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .focused($focused)
          .task {
            await Task.yield()
            focused = true
          }
          .onSubmit(commit)
          .onExitCommand { draft = name; isEditing = false }
      } else {
        Text(name)
          .onTapGesture(count: 2) { draft = name; isEditing = true }
          .accessibilityAction(named: Text("Rename workspace")) {
            draft = name
            isEditing = true
          }
          .contextMenu {
            Button("Rename…") { draft = name; isEditing = true }
          }
          .help("Double-click to rename")
      }
    }
    .onChange(of: name) { _, value in draft = value }
  }

  private func commit() {
    model.dismissMessage()
    model.renameWorkspace(name, to: draft)
    if model.message == nil { isEditing = false }
  }
}

@MainActor
private struct WorkspacePositionField: View {
  let name: String
  let model: DefiSettingsModel
  @State private var draft: String
  @FocusState private var focused: Bool

  init(name: String, model: DefiSettingsModel) {
    self.name = name
    self.model = model
    _draft = State(initialValue: model.workspaceMonitorPosition(name).map { String($0) } ?? "")
  }

  var body: some View {
    LabeledContent("Display number") {
      TextField("Display number", text: $draft)
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .frame(width: 56)
        .focused($focused)
        .onSubmit(commit)
    }
    .help("One-based display position; this can change when displays are rearranged.")
    .onChange(of: model.config.workspaces.monitors[name]) { _, position in
      guard !focused else { return }
      draft = position.map { String($0) } ?? ""
    }
  }

  private func commit() {
    guard let value = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
      model.presentMessage("Display position must be a positive whole number.")
      draft = model.workspaceMonitorPosition(name).map { String($0) } ?? ""
      return
    }
    model.setWorkspaceMonitorPosition(name, position: value)
    focused = false
  }
}

@MainActor
private struct AppRulesSettingsView: View {
  let model: DefiSettingsModel
  @State private var editor: RuleSheet?
  @State private var search = ""

  var body: some View {
    Form {
      Section {
        Text("Rules apply only to new windows when an app opens them. Saving a rule does not change existing windows. Matching rules combine in list order: the last workspace or initial width wins, while enabled behavior flags accumulate.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("Add App Rule…") { editor = RuleSheet(rule: nil, index: nil) }
      }
      Section {
        if model.config.rules.isEmpty {
          Text("No application rules are configured.")
            .foregroundStyle(.secondary)
        }
        if !model.config.rules.isEmpty && filteredRules.isEmpty {
          Text("No matching rules.").foregroundStyle(.secondary)
        }
        ForEach(filteredRules) { row in
          let index = model.ruleRows.firstIndex(where: { $0.id == row.id }) ?? 0
          appRuleRow(row.rule, index: index)
        }
        .settingsReorderable()
      } header: {
        HStack {
          Text("Application rules")
          Spacer()
          TextField("Search rules", text: $search, prompt: Text("Search rules"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(.body)
            .frame(width: 220)
        }
      }
    }
    .formStyle(.grouped)
    .modifier(SettingsReorderContainer(itemID: \SettingsRuleRow.id, move: model.reorderRules))
    .onAppear { model.refreshApplications() }
    .sheet(item: $editor) { sheet in
      SettingsRuleEditor(model: model, rule: sheet.rule, index: sheet.index)
    }
  }

  private var filteredRules: [SettingsRuleRow] {
    model.ruleRows.filter { row in
      let index = model.ruleRows.firstIndex(where: { $0.id == row.id }) ?? 0
      let text = [model.ruleName(row.rule, index: index), ruleSummary(row.rule), row.rule.appID ?? ""]
        .joined(separator: " ")
      return search.isEmpty || text.localizedCaseInsensitiveContains(search)
    }
  }

  private func appRuleRow(_ rule: Rule, index: Int) -> some View {
    HStack(spacing: 12) {
      if #available(macOS 27, *) {
        Image(systemName: "line.3.horizontal")
          .foregroundStyle(.tertiary)
          .help("Drag to reorder")
          .accessibilityHidden(true)
      }
      appIcon(for: rule)
      VStack(alignment: .leading, spacing: 3) {
        Text(model.ruleName(rule, index: index))
        Text(ruleSummary(rule))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if #available(macOS 27, *) {
        EmptyView()
      } else {
        Button { model.moveRule(from: index, to: max(index - 1, 0)) } label: {
          Image(systemName: "chevron.up")
        }
        .buttonStyle(.borderless)
        .disabled(index == 0)
        .help("Move rule earlier")
        Button { model.moveRule(from: index, to: min(index + 1, model.config.rules.count - 1)) } label: {
          Image(systemName: "chevron.down")
        }
        .buttonStyle(.borderless)
        .disabled(index == model.config.rules.count - 1)
        .help("Move rule later")
      }
      Button("Edit…") { editor = RuleSheet(rule: rule, index: index) }
        .buttonStyle(.borderless)
      Button(role: .destructive) { model.removeRule(at: index) } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .help("Remove application rule")
    }
    .padding(.vertical, 4)
    .accessibilityAction(named: Text("Move rule earlier")) {
      model.moveRule(from: index, to: max(index - 1, 0))
    }
    .accessibilityAction(named: Text("Move rule later")) {
      model.moveRule(from: index, to: min(index + 1, model.config.rules.count - 1))
    }
  }

  @ViewBuilder
  private func appIcon(for rule: Rule) -> some View {
    SettingsApplicationIcon(
      application: rule.appID.flatMap { appID in
        model.applications.first(where: {
          $0.bundleIdentifier.caseInsensitiveCompare(appID) == .orderedSame
        })
      },
      fallbackLabel: "Custom application rule"
    )
  }

  private func ruleSummary(_ rule: Rule) -> String {
    var conditions: [String] = []
    if let title = rule.title { conditions.append("title contains ‘\(title)’") }
    if let role = rule.role { conditions.append("role \(role)") }
    var actions: [String] = []
    if let workspace = rule.workspace { actions.append("workspace \(workspace)") }
    if rule.followFocus { actions.append("follow focus") }
    if rule.floating { actions.append("floating") }
    if rule.forceTiling { actions.append("force tiling") }
    if rule.intrinsicSize { actions.append("intrinsic size") }
    if let width = rule.initialColumnWidth { actions.append("initial width \(percent(width))") }
    if rule.includeInitialWidthInCycle { actions.append("include width in cycle") }
    let conditionText = conditions.isEmpty ? "any matching window" : conditions.joined(separator: " · ")
    return "\(conditionText)  →  \(actions.joined(separator: ", "))"
  }
}

@MainActor
private struct SettingsApplicationIcon: View {
  let application: SettingsApplicationOption?
  let fallbackLabel: String

  var body: some View {
    Group {
      if let application {
        Image(nsImage: NSWorkspace.shared.icon(forFile: application.path))
          .resizable()
      } else {
        Image(systemName: "app.dashed")
          .font(.system(size: 23))
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: 28, height: 28)
    .accessibilityLabel(application?.name ?? fallbackLabel)
  }
}

private struct RuleSheet: Identifiable {
  let id = UUID()
  let rule: Rule?
  let index: Int?
}

@MainActor
private struct SettingsRuleEditor: View {
  let model: DefiSettingsModel
  @State private var original: Rule?
  @State private var originalIndex: Int?
  @State private var draft: Rule
  @State private var customApplication = false
  @State private var applicationPickerPresented = false
  @State private var conditionsExpanded = false
  @State private var saveError: String?
  @State private var originalRuleCount: Int
  @State private var originalWasRemoved = false
  @Environment(\.dismiss) private var dismiss

  init(model: DefiSettingsModel, rule: Rule?, index: Int?) {
    self.model = model
    _original = State(initialValue: rule)
    _originalIndex = State(initialValue: index)
    _draft = State(initialValue: rule ?? Rule())
    _customApplication = State(initialValue: false)
    _conditionsExpanded = State(initialValue: rule?.title != nil || rule?.role != nil)
    _originalRuleCount = State(initialValue: model.config.rules.count)
    _originalWasRemoved = State(initialValue: false)
  }

  private var selectedApplicationName: String {
    guard let appID = draft.appID else { return "Any application" }
    if appID.isEmpty { return "Custom bundle identifier" }
    return selectedApplication?.name ?? appID
  }

  private var selectedApplication: SettingsApplicationOption? {
    guard let appID = draft.appID, !appID.isEmpty else { return nil }
    return model.applications.first {
      $0.bundleIdentifier.caseInsensitiveCompare(appID) == .orderedSame
    }
  }

  private var isValid: Bool {
    let hasMatcher = !(draft.appID?.isEmpty ?? true) || !(draft.title?.isEmpty ?? true) || !(draft.role?.isEmpty ?? true)
    let hasAction = draft.workspace != nil || draft.followFocus || draft.floating || draft.forceTiling
      || draft.intrinsicSize || draft.initialColumnWidth != nil || draft.includeInitialWidthInCycle
    return hasMatcher && hasAction && (!customApplication || !(draft.appID?.isEmpty ?? true))
  }

  var body: some View {
    Form {
      Section("Application") {
        HStack {
          SettingsApplicationIcon(
            application: selectedApplication,
            fallbackLabel: draft.appID == nil ? "Any application" : "Custom application"
          )
          Text(selectedApplicationName)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button("Choose Application…") { applicationPickerPresented = true }
          if draft.appID != nil {
            Button("Clear") { draft.appID = nil; customApplication = false }
              .buttonStyle(.borderless)
          }
        }
        if customApplication {
          TextField("Bundle identifier or suffix", text: optionalStringBinding(\.appID))
            .help("Matches a bundle identifier by case-insensitive exact or suffix comparison.")
        }
      }
      Section("Window conditions") {
        DisclosureGroup("Advanced conditions", isExpanded: $conditionsExpanded) {
          TextField("Title contains", text: optionalStringBinding(\.title))
            .help("Case-insensitive substring match.")
          TextField("Accessibility role", text: optionalStringBinding(\.role))
            .help("Exact, case-sensitive role match.")
        }
      }
      Section("Actions") {
        Picker("Move to workspace", selection: Binding(
          get: { draft.workspace ?? "" },
          set: { draft.workspace = $0.isEmpty ? nil : $0 }
        )) {
          Text("Leave workspace unchanged").tag("")
          ForEach(model.config.workspaces.names, id: \.self) { Text($0).tag($0) }
        }
        settingsDraftToggle("Follow focus", value: \Rule.followFocus)
        settingsDraftToggle("Float window", value: \Rule.floating)
        settingsDraftToggle("Force tiling", value: \Rule.forceTiling)
        settingsDraftToggle("Use intrinsic window size", value: \Rule.intrinsicSize)
        Toggle("Set initial column width", isOn: Binding(
          get: { draft.initialColumnWidth != nil },
          set: { draft.initialColumnWidth = $0 ? model.config.layout.defaultColumnWidth : nil }
        ))
        if let width = draft.initialColumnWidth {
          SettingsNumberRow(
            title: "Initial width", value: width * 100, range: 5...100, step: 5, unit: "%",

            onChange: { draft.initialColumnWidth = $0 / 100 }
          )
          Toggle("Include this width in Cycle Width", isOn: Binding(
            get: { draft.includeInitialWidthInCycle },
            set: { draft.includeInitialWidthInCycle = $0 }
          ))
        }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 620, minHeight: 600)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save Rule") { save() }.disabled(!isValid || originalWasRemoved)
      }
    }
    .sheet(isPresented: $applicationPickerPresented) {
      ApplicationPickerView(applications: model.applications) { application in
        if let application {
          draft.appID = application.bundleIdentifier
          customApplication = false
        } else {
          draft.appID = ""
          customApplication = true
        }
      }
    }
    .alert("Couldn’t Save Rule", isPresented: Binding(
      get: { saveError != nil }, set: { if !$0 { saveError = nil } }
    )) {
      Button("OK", role: .cancel) { saveError = nil }
    } message: {
      Text(saveError ?? "")
    }
    .onChange(of: model.config.rules) { _, rules in
      guard let original, let originalIndex else { return }
      let matchingIndices = rules.indices.filter { index in
        rules[index].appID == original.appID
          && rules[index].title == original.title
          && rules[index].role == original.role
      }
      let currentIndex: Int?
      if let exactIndex = rules.firstIndex(of: original) {
        currentIndex = exactIndex
      } else if matchingIndices.count == 1 {
        currentIndex = matchingIndices[0]
      } else if rules.count == originalRuleCount, rules.indices.contains(originalIndex) {
        // Rules have no persistent IDs. Keep the selected table occurrence when its matchers
        // changed in place and the rule list itself did not change size.
        currentIndex = originalIndex
      } else {
        currentIndex = nil
      }
      if let currentIndex {
        self.originalIndex = currentIndex
        self.original = rules[currentIndex]
        self.originalRuleCount = rules.count
        originalWasRemoved = false
        draft = rules[currentIndex]
        customApplication = draft.appID.map { appID in
          !appID.isEmpty && !model.applications.contains { $0.bundleIdentifier == appID }
        } ?? false
        saveError = nil
      } else {
        self.originalIndex = nil
        self.original = nil
        originalWasRemoved = true
        saveError = "This rule changed or was removed by an external configuration edit. Close it and reopen the latest rule."
      }
    }
    .onAppear {
      model.refreshApplications()
      if let appID = draft.appID {
        customApplication = !model.applications.contains(where: { $0.bundleIdentifier == appID })
      }
    }
  }

  private func optionalStringBinding(_ keyPath: WritableKeyPath<Rule, String?>) -> Binding<String> {
    Binding(
      get: { draft[keyPath: keyPath] ?? "" },
      set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
    )
  }

  private func settingsDraftToggle(_ title: String, value keyPath: WritableKeyPath<Rule, Bool>) -> some View {
    Toggle(title, isOn: Binding(get: { draft[keyPath: keyPath] }, set: { draft[keyPath: keyPath] = $0 }))
  }

  private func save() {
    guard !originalWasRemoved else { return }
    model.dismissMessage()
    if let original, let originalIndex {
      model.updateRule(draft, original: original, originalIndex: originalIndex)
    } else {
      model.addRule(draft)
    }
    if model.message == nil { dismiss() } else { saveError = model.message }
  }
}

@MainActor
private struct ApplicationPickerView: View {
  let applications: [SettingsApplicationOption]
  let select: (SettingsApplicationOption?) -> Void
  @State private var search = ""
  @Environment(\.dismiss) private var dismiss

  private var openApplications: [SettingsApplicationOption] {
    applications.filter { $0.openWindowCount > 0 && matches($0) }
  }

  private var installedApplications: [SettingsApplicationOption] {
    applications.filter { $0.openWindowCount == 0 && matches($0) }
  }

  var body: some View {
    NavigationStack {
      List {
        if !openApplications.isEmpty {
          Section("Open windows") {
            ForEach(openApplications) { row($0) }
          }
        }
        Section("Installed applications") {
          ForEach(installedApplications) { row($0) }
        }
        Section {
          Button {
            select(nil)
            dismiss()
          } label: {
            Label("Use a custom bundle identifier…", systemImage: "pencil")
          }
        }
      }
      .searchable(text: $search, prompt: "Search applications")
      .navigationTitle("Choose Application")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      }
    }
    .frame(minWidth: 440, minHeight: 520)
  }

  private func row(_ application: SettingsApplicationOption) -> some View {
    Button {
      select(application)
      dismiss()
    } label: {
      HStack(spacing: 10) {
        Image(nsImage: NSWorkspace.shared.icon(forFile: application.path))
          .resizable()
          .frame(width: 28, height: 28)
        VStack(alignment: .leading) {
          Text(application.name)
          Text(application.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if application.openWindowCount > 0 {
          Text("\(application.openWindowCount) open")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func matches(_ application: SettingsApplicationOption) -> Bool {
    search.isEmpty || application.name.localizedCaseInsensitiveContains(search)
      || application.bundleIdentifier.localizedCaseInsensitiveContains(search)
  }
}

private struct ShortcutSheet: Identifiable {
  let id = UUID()
  let row: SettingsShortcutRow?
}

@MainActor
private struct SettingsShortcutEditor: View {
  @AppStorage("displayHyperSymbol") private var displayHyper = true
  @AppStorage("displayHyperIncludesShift") private var hyperIncludesShift = false
  let model: DefiSettingsModel
  @Environment(\.dismiss) private var dismiss
  @State private var sourceRow: SettingsShortcutRow?
  @State private var sourceWasRemoved = false
  @State private var accelerator: String
  @State private var action: String
  @State private var argument: String
  @State private var customCommand: String
  @State private var usesCustomCommand: Bool

  private var isArgumentValid: Bool {
    if SettingsShortcutActions.noArgumentActions.contains(action) { return true }
    if SettingsShortcutActions.relativeWorkspaceActions.contains(action) {
      return ["up", "down"].contains(argument) || model.config.workspaces.names.contains(argument)
    }
    if SettingsShortcutActions.namedWorkspaceActions.contains(action) { return model.config.workspaces.names.contains(argument) }
    if SettingsShortcutActions.positionActions.contains(action) {
      return Int(argument).map { $0 > 0 } ?? false
    }
    if let options = SettingsShortcutActions.argumentOptions[action] { return options.contains(argument) }
    return !argument.isEmpty
  }

  init(model: DefiSettingsModel, row: SettingsShortcutRow?) {
    self.model = model
    _sourceRow = State(initialValue: row)
    _sourceWasRemoved = State(initialValue: false)
    let command = row?.command ?? "focus-column left"
    let parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
    let isKnown = parts.first.map(SettingsShortcutActions.actions.contains) ?? false
    _accelerator = State(initialValue: row?.accelerator ?? "")
    _action = State(initialValue: isKnown ? parts[0] : SettingsShortcutActions.actions[0])
    _argument = State(initialValue: isKnown && parts.count > 1 ? parts[1] : "left")
    _customCommand = State(initialValue: command)
    _usesCustomCommand = State(initialValue: !isKnown)
  }

  var body: some View {
    Form {
      Section("Shortcut") {
        SettingsShortcutRecorder(
          label: accelerator.isEmpty
            ? "Record Shortcut…"
            : shortcutKeyLabel(accelerator, aliases: model.config.modifierCombinations,
              displayHyper: displayHyper, hyperIncludesShift: hyperIncludesShift),
          command: sourceRow?.command ?? "New shortcut",
          onRecord: { accelerator = $0 }
        )
        .frame(width: 190, height: 30)
        Text("Use Control, Option, or Command with a supported key.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("Action") {
        Toggle("Custom command…", isOn: $usesCustomCommand)
        if usesCustomCommand {
          TextField("Command", text: $customCommand)
            .font(.body.monospaced())
          Text("Use any command documented in the configuration guide.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Picker("Action", selection: $action) {
            ForEach(SettingsShortcutActions.actions, id: \.self) { value in
              Text(value.replacingOccurrences(of: "-", with: " ").capitalized).tag(value)
            }
          }
          if !SettingsShortcutActions.noArgumentActions.contains(action) {
            if SettingsShortcutActions.relativeWorkspaceActions.contains(action) {
              Picker("Workspace target", selection: $argument) {
                Text("Up").tag("up")
                Text("Down").tag("down")
                ForEach(model.config.workspaces.names, id: \.self) { name in Text(name).tag(name) }
              }
            } else if SettingsShortcutActions.namedWorkspaceActions.contains(action) {
              Picker("Workspace", selection: $argument) {
                ForEach(model.config.workspaces.names, id: \.self) { name in Text(name).tag(name) }
              }
            } else if let options = SettingsShortcutActions.argumentOptions[action] {
              Picker("Argument", selection: $argument) {
                if !options.contains(argument) { Text(argument).tag(argument) }
                ForEach(options, id: \.self) { Text($0.capitalized).tag($0) }
              }
            } else {
              TextField(SettingsShortcutActions.positionActions.contains(action) ? "Position" : "Argument", text: $argument)
                .help(SettingsShortcutActions.positionActions.contains(action) ? "Enter a 1-based workspace position." : "Enter the argument accepted by this action.")
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 520, minHeight: 380)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          model.dismissMessage()
          let command = usesCustomCommand
            ? customCommand
            : SettingsShortcutActions.noArgumentActions.contains(action) ? action : "\(action) \(argument)"
          model.saveShortcut(sourceRow, accelerator: accelerator, command: command)
          if model.message == nil { dismiss() }
        }
        .disabled(sourceWasRemoved || accelerator.isEmpty || (usesCustomCommand ? customCommand.isEmpty : !isArgumentValid))
      }
    }
    .onChange(of: action) { _, newAction in
      if let options = SettingsShortcutActions.argumentOptions[newAction], !options.contains(argument) {
        argument = options[0]
      } else if SettingsShortcutActions.namedWorkspaceActions.contains(newAction),
        !model.config.workspaces.names.contains(argument)
      {
        argument = model.config.workspaces.names.first ?? ""
      } else if SettingsShortcutActions.relativeWorkspaceActions.contains(newAction),
        !["up", "down"].contains(argument), !model.config.workspaces.names.contains(argument) {
        argument = model.config.workspaces.names.first ?? "up"
      } else if SettingsShortcutActions.positionActions.contains(newAction), !(Int(argument).map { $0 > 0 } ?? false) {
        argument = "1"
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
    let isKnown = parts.first.map(SettingsShortcutActions.actions.contains) ?? false
    action = isKnown ? parts[0] : SettingsShortcutActions.actions[0]
    argument = isKnown && parts.count > 1 ? parts[1] : "left"
    customCommand = matchingRow.command
    usesCustomCommand = !isKnown
  }
}

@MainActor
private struct ModifierAliasesSettings: View {
  let model: DefiSettingsModel
  @State private var alias = ""
  @State private var combination = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Modifier aliases").font(.headline)
      ForEach(model.config.modifierCombinations.keys.sorted(), id: \.self) { name in
        ModifierAliasRow(name: name, value: model.config.modifierCombinations[name] ?? "", model: model)
      }
      HStack {
        TextField("Alias", text: $alias)
          .frame(width: 130)
        TextField("Modifiers, e.g. ctrl+alt", text: $combination)
        Button("Add") {
          let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          guard !trimmed.isEmpty, model.config.modifierCombinations[trimmed] == nil else { return }
          model.set(table: "modifier_combinations", key: trimmed, value: tomlString(combination))
          if model.message == nil { alias = ""; combination = "" }
        }
        .disabled(alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || combination.isEmpty)
      }
    }
    .padding(.vertical, 4)
  }
}

@MainActor
private struct DefaultModifierField: View {
  let model: DefiSettingsModel
  @State private var draft: String
  @FocusState private var focused: Bool

  init(model: DefiSettingsModel) {
    self.model = model
    _draft = State(initialValue: model.config.defaultKeyModifier)
  }

  var body: some View {
    HStack {
      TextField("Default key modifier", text: $draft)
        .focused($focused)
        .onSubmit(commit)
    }
    .onChange(of: model.config.defaultKeyModifier) { _, value in
      draft = value
    }
  }

  private func commit() {
    model.set(table: "", key: "default_key_modifier", value: tomlString(draft))
    focused = false
  }
}

@MainActor
private struct ModifierAliasRow: View {
  let name: String
  let value: String
  let model: DefiSettingsModel
  @State private var draft: String

  init(name: String, value: String, model: DefiSettingsModel) {
    self.name = name
    self.value = value
    self.model = model
    _draft = State(initialValue: value)
  }

  var body: some View {
    HStack {
      Text(name).font(.body.monospaced()).frame(width: 130, alignment: .leading)
      TextField("Modifiers", text: $draft)
        .onSubmit { model.set(table: "modifier_combinations", key: name, value: tomlString(draft)) }
      Button(role: .destructive) {
        model.set(table: "modifier_combinations", key: name, value: nil)
      } label: { Image(systemName: "minus.circle") }
        .buttonStyle(.borderless)
        .help("Remove modifier alias")
    }
    .onChange(of: value) { _, newValue in draft = newValue }
  }
}

private struct SettingsNumberRow: View {
  let title: String
  let value: Double
  let range: ClosedRange<Double>
  let step: Double
  let unit: String
  let onChange: (Double) -> Void

  private var valueBinding: Binding<Double> {
    Binding(get: { value }, set: { onChange($0) })
  }

  var body: some View {
    HStack(spacing: 8) {
      Text(title)
      Spacer()
      TextField(title, value: valueBinding, format: .number.precision(.fractionLength(0...2)))
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(width: 88)
      Text(unit).foregroundStyle(.secondary).frame(width: 25, alignment: .leading)
      Stepper(title, value: valueBinding, in: range, step: step)
        .labelsHidden()
    }
  }
}

@MainActor
private func settingsToggle(
  _ model: DefiSettingsModel,
  title: String,
  table: String,
  key: String,
  value: Bool
) -> some View {
  Toggle(title, isOn: Binding(
    get: { value },
    set: { model.set(table: table, key: key, value: $0 ? "true" : "false") }
  ))
}

@MainActor
private func stringBinding(
  _ model: DefiSettingsModel,
  table: String,
  key: String,
  value: String
) -> Binding<String> {
  Binding(get: { value }, set: { model.set(table: table, key: key, value: tomlString($0)) })
}

private func percent(_ value: Double) -> String {
  "\(Int((value * 100).rounded()))%"
}

private func settingsColor(_ value: String) -> Color {
  let bits = parseBorderColor(value) ?? 0xFFFF_C099
  return Color(
    .sRGB,
    red: Double((bits >> 16) & 0xFF) / 255,
    green: Double((bits >> 8) & 0xFF) / 255,
    blue: Double(bits & 0xFF) / 255,
    opacity: Double((bits >> 24) & 0xFF) / 255
  )
}

private func settingsHexColor(_ color: Color) -> String {
  let value = (NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color))
  return String(
    format: "#%02X%02X%02X%02X",
    Int((value.alphaComponent * 255).rounded()),
    Int((value.redComponent * 255).rounded()),
    Int((value.greenComponent * 255).rounded()),
    Int((value.blueComponent * 255).rounded())
  )
}

private extension DynamicViewContent {
  @ViewBuilder
  func settingsReorderable() -> some View {
    #if canImport(SwiftUI, _version: 8.0)
    if #available(macOS 27, *) {
      reorderable()
    } else {
      self
    }
    #else
    self
    #endif
  }
}

private struct SettingsReorderContainer<Item, ID: Hashable & Sendable>: ViewModifier {
  let itemID: KeyPath<Item, ID>
  let move: ([ID], ID?) -> Void

  @ViewBuilder
  func body(content: Content) -> some View {
    #if canImport(SwiftUI, _version: 8.0)
    if #available(macOS 27, *) {
      content.reorderContainer(for: Item.self, itemID: itemID) { difference in
        switch difference.destination.position {
        case .before(let id): move(difference.sources, id)
        case .end: move(difference.sources, nil)
        }
      }
    } else {
      content
    }
    #else
    content
    #endif
  }
}
