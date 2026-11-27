import AppKit
import DefiConfig
import DefiModel
import SwiftUI
import DefiMacOS

@MainActor
struct WorkspaceSettingsView: View {
  let model: DefiSettingsModel
  let request: SettingsRevealRequest
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
          SettingsSectionTitle("Named workspaces", symbol: "tag", color: .indigo)
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
      .settingsSearchTarget(.namedWorkspaces)
      Section("Startup workspace", symbol: "power", color: .green) {
        Picker(
          SettingsOption.defaultWorkspace.title,
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
        .settingsSearchTarget(.defaultWorkspace)
      }
      if model.displays.isEmpty {
        Section("Displays", symbol: "display", color: .cyan) {
          Text("No display identity is available. Display affinity remains unchanged.")
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.settingsCards)
    .modifier(SettingsRevealModifier(
      request: request,
      ready: SettingsSearchCatalog.contains(request.destination, config: model.config, shortcuts: [])
    ))
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
        if !references.isEmpty {
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
    .id(SettingsSearchAnchor.workspace(name))
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
struct WorkspaceIconPicker: View {
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
struct WorkspaceNameEditor: View {
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
struct WorkspacePositionField: View {
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
