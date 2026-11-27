import AppKit
import DefiConfig
import DefiModel
import SwiftUI
import DefiMacOS

@MainActor
struct AppRulesSettingsView: View {
  let model: DefiSettingsModel
  let request: SettingsRevealRequest
  @State private var editor: RuleSheet?
  @State private var search = ""
  @State private var uninstalledToRemove: [String]?
  @Environment(SettingsPageVisibility.self) private var visibility: SettingsPageVisibility?

  var body: some View {
    Form {
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
        Button { editor = RuleSheet(rule: nil, index: nil) } label: {
          SettingsAddLabel(title: SettingsOption.addAppRule.title, iconWidth: 28)
        }
          .buttonStyle(.settingsNavigation)
          .settingsSearchTarget(.addAppRule)
      } header: {
        HStack {
          SettingsSectionTitle("Application rules", symbol: "app.badge", color: .orange,
            info: "Rules apply only to new windows when an app opens them. Saving a rule does not change existing windows. Matching rules combine in list order: the last workspace or display, window placement, opening focus, or initial width wins, while enabled behavior flags accumulate.")
          Spacer()
          let uninstalled = uninstalledRuleIndices(model.config.rules, known: model.applications.map(\.bundleIdentifier),
            isInstalled: applicationIsInstalled)
          if !uninstalled.isEmpty {
            Button { uninstalledToRemove = uninstalled.compactMap { model.config.rules[$0].appID } } label: {
              Label("\(uninstalled.count) uninstalled", systemImage: "trash")
                .font(.callout)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove the rules of apps that are no longer installed")
          }
          TextField("Search rules", text: $search, prompt: Text("Search rules"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(.body)
            .frame(width: 220)
        }
      }
      .settingsSearchTarget(.appRules)
    }
    .formStyle(.settingsCards)
    .confirmationDialog(
      uninstalledToRemove?.count == 1 ? "Remove the rule for an uninstalled app?" : "Remove rules for uninstalled apps?",
      isPresented: Binding(get: { uninstalledToRemove != nil }, set: { if !$0 { uninstalledToRemove = nil } })
    ) {
      Button("Remove", role: .destructive) {
        // The config can reload while the dialog is open: remove what is still uninstalled now, never stale indices.
        if let shown = uninstalledToRemove {
          model.removeRules(at: uninstalledRuleIndices(model.config.rules, known: model.applications.map(\.bundleIdentifier)) {
            !shown.contains($0) || applicationIsInstalled($0)
          })
        }
        uninstalledToRemove = nil
      }
    } message: {
      Text((uninstalledToRemove ?? []).joined(separator: ", "))
    }
    .modifier(SettingsRevealModifier(request: request, prepare: { search = "" }))
    .modifier(SettingsReorderContainer(itemID: \SettingsRuleRow.id, move: model.reorderRules))
    // The page is built hidden while the window idles; scan apps only once it shows.
    .onChange(of: visibility?.visible ?? true, initial: true) { _, visible in
      if visible { model.refreshApplications() }
    }
    .settingsSubpage(item: $editor, title: { sheet in
      sheet.rule.map { model.ruleName($0, index: sheet.index ?? 0) } ?? "New Rule"
    }) { sheet in
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
        }) ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID).map {
          // Apps outside the scanned folders, such as one inside Xcode, still have an icon.
          SettingsApplicationOption(id: appID, bundleIdentifier: appID, name: $0.deletingPathExtension().lastPathComponent,
            path: $0.path, openWindowCount: 0)
        }
      },
      fallbackLabel: "Custom application rule"
    )
  }

  private func ruleSummary(_ rule: Rule) -> String {
    var conditions: [String] = []
    if let title = rule.title { conditions.append("title contains ‘\(title)’") }
    if let pattern = rule.titleRegex { conditions.append("title matches ‘\(pattern)’") }
    if let role = rule.role { conditions.append("role \(role)") }
    var actions: [String] = []
    if let workspace = rule.workspace { actions.append("workspace \(workspace)") }
    if let monitor = rule.monitor { actions.append("display \(ruleDisplayTitle(monitor))") }
    if rule.followFocus { actions.append("follow focus") }
    if let openFocused = rule.openFocused { actions.append(openFocused ? "open focused" : "open unfocused") }
    if let window = rule.window { actions.append(window.settingsTitle.lowercased()) }
    if rule.intrinsicSize { actions.append("intrinsic size") }
    if let width = rule.initialColumnWidth { actions.append("initial width \(percent(width))") }
    if rule.includeInitialWidthInCycle { actions.append("include width in cycle") }
    if let pin = rule.pin { actions.append("pin to the \(pin.rawValue)") }
    let conditionText = conditions.isEmpty ? "any matching window" : conditions.joined(separator: " · ")
    return "\(conditionText)  →  \(actions.joined(separator: ", "))"
  }
}

@MainActor
struct SettingsApplicationIcon: View {
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

struct RuleSheet: Identifiable {
  let id = UUID()
  let rule: Rule?
  let index: Int?
}

@MainActor
struct SettingsRuleEditor: View {
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
  @Environment(\.closeSettingsSubpage) private var dismiss

  init(model: DefiSettingsModel, rule: Rule?, index: Int?) {
    self.model = model
    _original = State(initialValue: rule)
    _originalIndex = State(initialValue: index)
    _draft = State(initialValue: rule ?? Rule())
    _customApplication = State(initialValue: false)
    _conditionsExpanded = State(initialValue: rule?.title != nil || rule?.titleRegex != nil || rule?.role != nil)
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
    let hasMatcher = !(draft.appID?.isEmpty ?? true) || !(draft.title?.isEmpty ?? true)
      || !(draft.titleRegex?.isEmpty ?? true) || !(draft.role?.isEmpty ?? true)
    let hasAction = draft.workspace != nil || draft.monitor != nil || draft.followFocus
      || draft.openFocused != nil || draft.window != nil
      || draft.intrinsicSize || draft.initialColumnWidth != nil || draft.includeInitialWidthInCycle
      || draft.pin != nil
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
          TextField(text: optionalStringBinding(\.appID), prompt: nil) {
            SettingsInfoLabel("Bundle identifier or suffix",
              "Matches the app’s bundle identifier, or its end, in any case. For example, “com.apple.Notes” or “Notes”.")
          }
        }
      }
      Section("Window conditions") {
        DisclosureGroup("Advanced conditions", isExpanded: $conditionsExpanded) {
          TextField(text: optionalStringBinding(\.title), prompt: nil) {
            SettingsInfoLabel("Title contains",
              "Matches windows whose title contains this text, in any case. For example, “picture-in-picture” for a browser’s floating video.",
              note: "Match the app alone when you can: titles change with the system language and some appear late.")
          }
          TextField(text: optionalStringBinding(\.titleRegex), prompt: nil) {
            SettingsInfoLabel("Title matches pattern",
              "Matches windows whose title matches this regular expression, in any case. For example, “^note-[0-9]+$”.")
          }
          TextField(text: optionalStringBinding(\.role), prompt: nil) {
            SettingsInfoLabel("Accessibility role",
              "Matches the window’s accessibility role exactly, such as “AXWindow”. Rarely needed.")
          }
        }
      }
      Section("Actions") {
        Picker(selection: Binding(
          get: { draft.workspace ?? "" },
          set: {
            draft.workspace = $0.isEmpty ? nil : $0
            if draft.workspace != nil { draft.monitor = nil }
          }
        )) {
          Text("Leave workspace unchanged").tag("")
          ForEach(model.config.workspaces.names, id: \.self) { Text($0).tag($0) }
        } label: {
          SettingsInfoLabel("Move to workspace", "Opens new matching windows on this named workspace.")
        }
        Picker(selection: Binding(
          get: { draft.monitor },
          set: {
            draft.monitor = $0
            if $0 != nil { draft.workspace = nil }
          }
        )) {
          Text("Leave display unchanged").tag(String?.none)
          ForEach(displayOptions, id: \.self) { Text(ruleDisplayTitle($0)).tag(Optional($0)) }
        } label: {
          SettingsInfoLabel("Move to display",
            "Opens new matching windows on this display’s active workspace.",
            note: "While the display is disconnected, windows open where they would without this rule.")
        }
        settingsDraftToggle("Follow focus", "Switches to that workspace when the new window takes focus.",
          value: \Rule.followFocus)
        Picker(selection: $draft.openFocused) {
          Text("Default").tag(Bool?.none)
          Text("Focus the window").tag(Optional(true))
          Text("Keep current focus").tag(Optional(false))
        } label: {
          SettingsInfoLabel("When the window opens",
            "Default focuses a window opened from the app you are using. Keep current focus opens it in the background without scrolling.")
        }
        Picker(selection: $draft.window) {
          Text("Automatic").tag(RuleWindow?.none)
          ForEach(RuleWindow.allCases, id: \.self) { Text($0.settingsTitle).tag(Optional($0)) }
        } label: {
          SettingsInfoLabel("Window",
            "Automatic suits most apps: app windows tile, while dialogs, progress, and fixed-size windows float.",
            note: "Force only for a window Defi gets wrong. Force tiled also tiles the app’s dialogs; add a title to target one window.")
        }
        settingsDraftToggle("Use intrinsic window size",
          "Keeps the window’s own size inside its column instead of filling it.", value: \Rule.intrinsicSize)
        Toggle(isOn: Binding(
          get: { draft.initialColumnWidth != nil },
          set: { draft.initialColumnWidth = $0 ? model.config.layout.defaultColumnWidth : nil }
        )) {
          SettingsInfoLabel("Set initial column width", "Opens the window’s column at this width instead of the default.")
        }
        if let width = draft.initialColumnWidth {
          SettingsNumberRow(
            title: "Initial width", value: width * 100, range: 5...100, step: 5, unit: "%",

            onChange: { draft.initialColumnWidth = $0 / 100 }
          )
          settingsDraftToggle("Include this width in Cycle Width",
            "Adds this width to the sizes Cycle Width steps through.", value: \Rule.includeInitialWidthInCycle)
        }
        Picker(selection: $draft.pin) {
          Text("Scroll with the strip").tag(ColumnPin?.none)
          Text("Pin to the left").tag(Optional(ColumnPin.left))
          Text("Pin to the right").tag(Optional(ColumnPin.right))
        } label: {
          SettingsInfoLabel("Pin column",
            "Keeps the window’s column at this edge of the screen, on every workspace, while the other columns scroll beside it.",
            note: "Applies only while the screen has no pinned column.")
        }
      }
    }
    .formStyle(.settingsCards)
    .safeAreaInset(edge: .bottom) {
      SettingsSubpageActions {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save Rule") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(!isValid || originalWasRemoved)
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

  /// Connected displays by name, plus the rule's own display when it is not connected, so editing never drops it.
  private var displayOptions: [String] {
    var options = NSScreen.screens.map(\.localizedName)
    guard let monitor = draft.monitor else { return options }
    if let i = options.firstIndex(where: { $0.caseInsensitiveCompare(monitor) == .orderedSame }) {
      options[i] = monitor  // keep the rule's own spelling selected
    } else {
      options.append(monitor)
    }
    return options
  }

  private func optionalStringBinding(_ keyPath: WritableKeyPath<Rule, String?>) -> Binding<String> {
    Binding(
      get: { draft[keyPath: keyPath] ?? "" },
      set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
    )
  }

  private func settingsDraftToggle(_ title: String, _ info: String, value keyPath: WritableKeyPath<Rule, Bool>) -> some View {
    Toggle(isOn: Binding(get: { draft[keyPath: keyPath] }, set: { draft[keyPath: keyPath] = $0 })) {
      SettingsInfoLabel(title, info)
    }
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
struct ApplicationPickerView: View {
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

extension RuleWindow {
  var settingsTitle: String {
    switch self {
    case .forceFloating: "Force floating"
    case .forceTiled: "Force tiled"
    }
  }
}

@MainActor
func ruleDisplayTitle(_ name: String) -> String {
  let connected = NSScreen.screens.contains { $0.localizedName.caseInsensitiveCompare(name) == .orderedSame }
  return connected ? name : "\(name) (not connected)"
}
