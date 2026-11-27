import AppKit
import DefiConfig
import DefiModel
import SwiftUI
import DefiMacOS

@MainActor
public struct DefiSettingsView: View {
  private let configURL: URL
  @State private var holder = Holder()

  /// Built once, when the window first shows: the menu bar's App body rebuilds this view value
  /// on every workspace change, and a model per value parsed the whole config each time.
  private final class Holder {
    var model: DefiSettingsModel?
  }

  public init(configURL: URL = Config.defaultURL) {
    self.configURL = configURL
  }

  public var body: some View {
    DefiSettingsPane(model: holder.model ?? {
      let model = DefiSettingsModel(configURL: configURL)
      model.followKeyboardLayout()
      holder.model = model
      return model
    }())
  }
}

@MainActor
private struct DefiSettingsPane: View {
  @State private var model: DefiSettingsModel
  @State private var selection = SettingsRevealRequest(destination: .page(.general))
  @State private var sidebarQuery = ""
  /// What the results show; follows the field a beat later, so a keystroke draws before the list changes.
  @State private var appliedQuery = ""
  @FocusState private var resultsFocused: Bool

  init(model: DefiSettingsModel) {
    _model = State(initialValue: model)
  }

  var body: some View {
    let query = appliedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let results = query.isEmpty ? [] : SettingsSearchCatalog.results(
      matching: query, config: model.config, shortcuts: model.shortcutRows, resolution: model.shortcutResolution)

    NavigationSplitView(columnVisibility: .constant(.all)) {
      List(selection: Binding<SettingsDestination?>(
        get: { query.isEmpty ? .page(selection.destination.page) : selection.destination },
        set: { if let destination = $0 { select(destination) } }
      )) {
        if query.isEmpty {
          ForEach(SettingsPage.sidebarGroups, id: \.pages) { group in
            if let title = group.title {
              Section(title) { sidebarRows(group.pages) }
            } else {
              sidebarRows(group.pages)
            }
          }
        } else {
          ForEach(results) { result in
            Button {
              select(result.destination)
            } label: {
              VStack(alignment: .leading, spacing: 3) {
                Text(result.title).lineLimit(2)
                Text(result.context).font(.caption).foregroundStyle(.secondary)
                if !result.detail.isEmpty {
                  Text(result.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tag(result.destination)
            .help([result.title, result.context, result.detail].filter { !$0.isEmpty }.joined(separator: " · "))
          }
        }
      }
      .listStyle(.sidebar)
      .background(SidebarSlidingSelection(revision: AnyHashable([query, "\(selection.destination)"])))
      .focused($resultsFocused)
      .safeAreaInset(edge: .top, spacing: 0) {
        SettingsSearchField(text: $sidebarQuery, moveToResults: results.first.map { result in
          {
            select(result.destination)
            resultsFocused = true
          }
        })
        .frame(height: 24)
        .padding(8)
      }
      .overlay {
        if !query.isEmpty && results.isEmpty {
          VStack(spacing: 6) {
            Text("No matching settings")
              .font(.headline)
            Text("Try another term or clear Search.")
              .foregroundStyle(.secondary)
          }
          .multilineTextAlignment(.center)
          .padding()
        }
      }
      .navigationTitle("Settings")
      .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
      // The column width alone leaves the sidebar too narrow for "Mouse & Trackpad".
      .frame(minWidth: 190)
      .toolbar(removing: .sidebarToggle)
    } detail: {
      SettingsPageView(request: selection, model: model)
        .navigationTitle(selection.destination.page.rawValue)
    }
    // System Settings floats the traffic lights over a sidebar that runs to the
    // window's top edge, with no title bar of its own.
    .toolbar(removing: .title)
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    // The desktop tints the whole window through its glass, as in the sidebar.
    .containerBackground(.regularMaterial, for: .window)
    .task(id: sidebarQuery) {
      if !sidebarQuery.isEmpty { try? await Task.sleep(for: .milliseconds(30)) }
      guard !Task.isCancelled else { return }
      appliedQuery = sidebarQuery
    }
    .onChange(of: query) { _, query in
      if query.isEmpty {
        selection = SettingsRevealRequest(destination: .page(selection.destination.page))
      }
    }
    .onChange(of: model.config) { _, config in
      if !SettingsSearchCatalog.contains(selection.destination, config: config, shortcuts: model.shortcutRows) {
        select(.page(selection.destination.page))
      }
    }
    .frame(minWidth: 860, idealWidth: 920, minHeight: 620, idealHeight: 680)
    .background(ResizableSettingsWindow())
    .task {
      model.startWatching()
    }
    .onAppear {
      NSApplication.shared.setActivationPolicy(.regular)
      NotificationCenter.default.post(name: defiActivationPolicyDidChange, object: nil)
      NSApplication.shared.activate()
    }
    .onDisappear {
      model.stopWatching()
      NSApplication.shared.setActivationPolicy(.accessory)
      NotificationCenter.default.post(name: defiActivationPolicyDidChange, object: nil)
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
    ) { _ in
      model.refreshDisplays()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      model.refreshSystemStatusInBackground()
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

  private func sidebarRows(_ pages: [SettingsPage]) -> some View {
    ForEach(pages) { page in
      Label {
        Text(page.rawValue)
      } icon: {
        SettingsPageIcon(page: page, size: 24)
      }
      .padding(.vertical, 4)
      .tag(SettingsDestination.page(page))
    }
  }

  private func select(_ destination: SettingsDestination) {
    let exists = SettingsSearchCatalog.contains(destination, config: model.config, shortcuts: model.shortcutRows)
    selection = SettingsRevealRequest(destination: exists ? destination : .page(destination.page))
  }
}

/// SwiftUI keeps the Settings window fixed-size; resizable, Defi tiles it as a column.
private struct ResizableSettingsWindow: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { WindowView() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  final class WindowView: NSView {
    private var styleObservation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      // The Settings scene's preference style centers toolbar items; the title belongs at the leading edge.
      window?.toolbarStyle = .unified
      keepResizable()
      // The scene reapplies its fixed-size style mask whenever its toolbar updates.
      styleObservation = window?.observe(\.styleMask) { [weak self] _, _ in
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.keepResizable() } }
      }
    }

    private func keepResizable() {
      guard let window, !window.styleMask.contains(.resizable) else { return }
      window.styleMask.insert(.resizable)
    }
  }
}

extension SettingsPage {
  /// The page's row in the sidebar, counting group titles.
  static func sidebarRowIndex(of page: SettingsPage) -> Int? {
    var row = 0
    for group in sidebarGroups {
      if group.title != nil { row += 1 }
      if let index = group.pages.firstIndex(of: page) { return row + index }
      row += group.pages.count
    }
    return nil
  }

  /// Sidebar sections in page order; the first has no title.
  static let sidebarGroups: [(title: String?, pages: [SettingsPage])] = [
    (nil, [.general, .layout]),
    ("Input", [.keyboard, .input]),
    ("Interface", [.appearance, .menuBar]),
    ("Windows", [.workspaces, .appRules]),
    ("Defi", [.about]),
  ]
}

private extension SettingsPage {
  var color: Color {
    switch self {
    case .general: .gray
    case .layout: .teal
    case .keyboard: .gray
    case .input: .blue
    case .appearance: .purple
    case .menuBar: .cyan
    case .workspaces: .indigo
    case .appRules: .orange
    case .about: .gray
    }
  }
  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .layout: "rectangle.split.2x1"
    case .keyboard: "keyboard"
    case .input: "computermouse"
    case .appearance: "paintpalette"
    case .menuBar: "menubar.rectangle"
    case .workspaces: "rectangle.3.group"
    case .appRules: "app"
    case .about: "info.circle"
    }
  }
}

private struct SettingsPageIcon: View {
  let page: SettingsPage
  let size: CGFloat

  var body: some View {
    SettingsIcon(symbol: page.symbol, color: page.color, size: size)
  }
}

struct SettingsIcon: View {
  let symbol: String
  let color: Color
  let size: CGFloat

  var body: some View {
    Image(systemName: symbol)
      .resizable()
      .scaledToFit()
      .foregroundStyle(.white)
      .frame(width: size * 0.62, height: size * 0.62)
      .frame(width: size, height: size)
      .background(color.gradient, in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
  }
}

@MainActor
private struct SettingsPageView: View {
  let request: SettingsRevealRequest
  let model: DefiSettingsModel
  @State private var navigator = SettingsSubpageNavigator()

  var body: some View {
    let page = request.destination.page
    // Pages stay alive once built, so going back to one shows it at once; only the selection slides.
    SettingsPageStack(page: page, request: request) { page, request, visibility in
      AnyView(content(page, request: request)
        .scrollContentBackground(.hidden)
        .environment(navigator)
        .environment(visibility))
    }
    // The title sits in the toolbar beside the traffic lights: content under the toolbar gets no clicks.
    .toolbar { pageTitle(page) }
    .onChange(of: request) { navigator.pop() }
  }

  @ToolbarContentBuilder private func pageTitle(_ page: SettingsPage) -> some ToolbarContent {
    if #available(macOS 26, *) {
      ToolbarItem(placement: .navigation) { header(page) }
        .sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: .navigation) { header(page) }
    }
  }

  /// The page title, which shrinks to its icon followed by the subpage title while one is open.
  private func header(_ page: SettingsPage) -> some View {
    HStack(spacing: 8) {
      Button { navigator.pop() } label: {
        SettingsPageIcon(page: page, size: 30)
      }
      .buttonStyle(.plain)
      .allowsHitTesting(navigator.title != nil)
      .help(navigator.title == nil ? "" : "Back to \(page.rawValue)")
      .accessibilityLabel(navigator.title == nil ? page.rawValue : "Back to \(page.rawValue)")
      if let title = navigator.title {
        Image(systemName: "chevron.forward")
          .font(.headline)
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
        Text(title)
          .font(.title2.bold())
          .lineLimit(1)
          .accessibilityAddTraits(.isHeader)
      } else {
        Text(page.rawValue)
          .font(.title2.bold())
          .accessibilityAddTraits(.isHeader)
      }
    }
    // Lines the title's icon up with the cards' edge below it.
    .padding(.leading, 15)
    // Animating a toolbar item relays out the whole toolbar every frame; only the content slides.
    .transaction { $0.animation = nil }
  }

  @ViewBuilder private func content(_ page: SettingsPage, request: SettingsRevealRequest) -> some View {
    switch page {
    case .general: GeneralSettingsView(model: model, request: request)
    case .layout: LayoutSettingsView(model: model, request: request)
    case .keyboard: KeyboardSettingsView(model: model, request: request)
    case .input: PointerSettingsView(model: model, request: request)
    case .appearance: AppearanceSettingsView(model: model, request: request)
    case .menuBar: MenuBarSettingsView(model: model, request: request)
    case .workspaces: WorkspaceSettingsView(model: model, request: request)
    case .appRules: AppRulesSettingsView(model: model, request: request)
    case .about: AboutSettingsView(request: request)
    }
  }
}

/// False while a page sits built but hidden behind another, so its demos stop animating. An object
/// rather than an environment value, so showing a page updates only the views that read it.
@MainActor @Observable
final class SettingsPageVisibility {
  var visible: Bool

  init(visible: Bool) { self.visible = visible }
}

/// One hosting view per page, built the first time it shows or while the window idles, then only hidden.
/// Rebuilding a page on every switch cost 50 to 150 ms of layout before the new page could draw.
private struct SettingsPageStack: NSViewRepresentable {
  let page: SettingsPage
  let request: SettingsRevealRequest
  let content: (SettingsPage, SettingsRevealRequest, SettingsPageVisibility) -> AnyView

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.container = view
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.content = content
    context.coordinator.show(page, request: request)
    context.coordinator.prebuildSoon()
  }

  @MainActor final class Coordinator {
    weak var container: NSView?
    var content: ((SettingsPage, SettingsRevealRequest, SettingsPageVisibility) -> AnyView)?
    private var pages: [SettingsPage: (host: NSHostingView<AnyView>, request: SettingsRevealRequest,
      visibility: SettingsPageVisibility)] = [:]
    private var current: SettingsPage?
    private var prebuild: Task<Void, Never>?

    func show(_ page: SettingsPage, request: SettingsRevealRequest) {
      if let built = pages[page], built.request != request {
        // Only a new request for this page, such as a search result, changes its content.
        built.host.rootView = content?(page, request, built.visibility) ?? AnyView(EmptyView())
        pages[page]?.request = request
      } else if pages[page] == nil {
        build(page, request: request, visible: true)
      }
      guard current != page else { return }
      if let current, let old = pages[current] {
        old.host.isHidden = true
        old.visibility.visible = false
      }
      if let shown = pages[page] {
        shown.host.isHidden = false
        shown.visibility.visible = true
      }
      current = page
    }

    @discardableResult
    private func build(_ page: SettingsPage, request: SettingsRevealRequest, visible: Bool) -> NSHostingView<AnyView> {
      let visibility = SettingsPageVisibility(visible: visible)
      let host = NSHostingView(rootView: content?(page, request, visibility) ?? AnyView(EmptyView()))
      host.sizingOptions = []
      host.isHidden = !visible
      if let container {
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
      }
      pages[page] = (host, request, visibility)
      return host
    }

    /// Builds the remaining pages one at a time while the window idles.
    func prebuildSoon() {
      guard prebuild == nil else { return }
      prebuild = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(600))
        for page in SettingsPage.allCases {
          guard let self, !Task.isCancelled else { return }
          guard self.pages[page] == nil else { continue }
          self.build(page, request: SettingsRevealRequest(destination: .page(page)), visible: false)
            .layoutSubtreeIfNeeded()
          try? await Task.sleep(for: .milliseconds(120))
        }
      }
    }

    deinit { prebuild?.cancel() }
  }
}

extension SettingsRevealRequest {
  /// A search result points at one of these options, so it must show even where its switch hides it.
  func reveals(_ options: SettingsOption...) -> Bool {
    if case .option(let option) = destination { return options.contains(option) }
    return false
  }
}

@MainActor
struct SettingsRevealModifier: ViewModifier {
  let request: SettingsRevealRequest
  var ready = true
  var prepare: () -> Void = {}

  private struct RenderRequest: Equatable {
    let request: SettingsRevealRequest
    let ready: Bool
  }

  func body(content: Content) -> some View {
    ScrollViewReader { proxy in
      content
        .onChange(of: request, initial: true) { _, _ in prepare() }
        .task(id: RenderRequest(request: request, ready: ready)) {
          guard ready, let anchor = request.destination.anchor else { return }
          await Task.yield()
          guard !Task.isCancelled else { return }
          let alignment: UnitPoint
          switch anchor {
          case .keyboardShortcuts, .option(.widthPresets), .option(.heightPresets), .option(.namedWorkspaces),
            .option(.appRules):
            alignment = .top
          default:
            alignment = .center
          }
          proxy.scrollTo(anchor, anchor: alignment)
        }
    }
  }
}

private extension View {
  func settingsSearchTarget(_ option: SettingsOption) -> some View {
    id(SettingsSearchAnchor.option(option))
  }
}

@MainActor
private struct GeneralSettingsView: View {
  let model: DefiSettingsModel
  let request: SettingsRevealRequest

  var body: some View {
    Form {
      Section("Permissions", symbol: "lock.shield", color: .green) {
        HStack(spacing: 10) {
          PermissionTile(
            title: SettingsOption.accessibility.title, symbol: "accessibility", purpose: "Moves and focuses windows",
            granted: model.accessibilityGranted, grant: model.openAccessibilitySettings)
            .settingsSearchTarget(.accessibility)
          PermissionTile(
            title: SettingsOption.screenRecording.title, symbol: "record.circle", purpose: "Animations and previews",
            granted: model.screenCaptureAvailable, grant: model.openScreenRecordingSettings)
            .settingsSearchTarget(.screenRecording)
        }
      }
      Section("Startup", symbol: "power", color: .green) {
        Toggle(
          SettingsOption.launchAtLogin.title,
          isOn: Binding(
            get: { model.launchAtLoginEnabled },
            set: { model.setLaunchAtLogin($0) }
          ))
          .settingsSearchTarget(.launchAtLogin)
        if let notice = model.launchAtLoginNotice {
          Text(notice)
            .settingsNote()
        }
        AutomaticUpdatesToggle()
          .settingsSearchTarget(.automaticUpdates)
      }
      Section("Configuration", symbol: "doc.text", color: .blue) {
        HStack(spacing: 10) {
          Image(nsImage: NSWorkspace.shared.icon(forFile: model.configurationPath))
            .resizable()
            .frame(width: 32, height: 32)
          VStack(alignment: .leading, spacing: 1) {
            Text(URL(filePath: model.configurationPath).lastPathComponent).fontWeight(.medium)
            Text((model.configurationPath as NSString).abbreviatingWithTildeInPath)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
          }
          Spacer(minLength: 8)
          Button("Open") { model.openConfiguration() }
            .help(SettingsOption.configurationFile.title)
            .settingsSearchTarget(.configurationFile)
          Button("Guide") { model.openDocumentation() }
            .help(SettingsOption.configurationGuide.title)
            .settingsSearchTarget(.configurationGuide)
        }
      }
      Section("Diagnostics", symbol: "stethoscope", color: .red) {
        HStack(spacing: 8) {
          Button { model.openLogs() } label: { Label("Logs", systemImage: "folder") }
            .help(SettingsOption.logs.title)
            .settingsSearchTarget(.logs)
          TriageButton()
          Spacer(minLength: 0)
        }
      }
    }
    .formStyle(.settingsCards)
    .modifier(SettingsRevealModifier(request: request))
  }
}

@MainActor
private struct MenuBarSettingsView: View {
  let model: DefiSettingsModel
  let request: SettingsRevealRequest

  var body: some View {
    let menuBar = model.config.menuBar
    Form {
      Section {
        SettingsMenuBarPreview(config: model.config, displayCount: model.displays.count)
        Toggle(
          SettingsOption.menuBar.title,
          isOn: Binding(
            get: { model.config.menuBar.enabled },
            set: { model.set(table: "menu_bar", key: "enabled", value: $0 ? "true" : "false") }
          ))
          .settingsSearchTarget(.menuBar)
        if menuBar.enabled || request.reveals(.workspaceDisplay, .menuBarIndicator, .menuBarInactiveStyle,
          .menuBarEqualWidth, .menuBarDisplays) {
          Picker(SettingsOption.workspaceDisplay.title, selection: Binding(
            get: { model.config.menuBar.workspaceStyle },
            set: { model.set(table: "menu_bar", key: "workspace_style", value: tomlString($0.rawValue)) }
          )) {
            Text("Name only").tag(WorkspaceLabelStyle.name)
            Text("Icon only").tag(WorkspaceLabelStyle.icon)
            Text("Icon and name").tag(WorkspaceLabelStyle.iconAndName)
            Text("Number").tag(WorkspaceLabelStyle.number)
            Text("None").tag(WorkspaceLabelStyle.none)
          }
          .settingsSearchTarget(.workspaceDisplay)
          Picker(SettingsOption.menuBarIndicator.title, selection: Binding(
            get: { model.config.menuBar.indicator },
            set: { model.set(table: "menu_bar", key: "indicator", value: tomlString($0.rawValue)) }
          )) {
            Text("Dots").tag(MenuBarIndicator.dot)
            Text("Pills").tag(MenuBarIndicator.pill)
            Text("Boxes").tag(MenuBarIndicator.box)
            Text("Circles").tag(MenuBarIndicator.circle)
          }
          .settingsSearchTarget(.menuBarIndicator)
          Picker(SettingsOption.menuBarInactiveStyle.title, selection: Binding(
            get: { model.config.menuBar.inactiveStyle },
            set: { model.set(table: "menu_bar", key: "inactive_style", value: tomlString($0.rawValue)) }
          )) {
            Text("Filled").tag(MenuBarInactiveStyle.filled)
            Text("Outlined").tag(MenuBarInactiveStyle.outlined)
          }
          .settingsSearchTarget(.menuBarInactiveStyle)
          Toggle(
            SettingsOption.menuBarEqualWidth.title,
            isOn: Binding(
              get: { model.config.menuBar.equalWidth },
              set: { model.set(table: "menu_bar", key: "equal_width", value: $0 ? "true" : "false") }
            ))
            .settingsSearchTarget(.menuBarEqualWidth)
          Picker(SettingsOption.menuBarDisplays.title, selection: Binding(
            get: { model.config.menuBar.show },
            set: { model.set(table: "menu_bar", key: "show", value: tomlString($0.rawValue)) }
          )) {
            Text("All displays").tag(MenuBarDisplays.all)
            Text("Focused display").tag(MenuBarDisplays.current)
            Text("Active workspace").tag(MenuBarDisplays.active)
          }
          .settingsSearchTarget(.menuBarDisplays)
        }
        Toggle(
          SettingsOption.menuBarColumns.title,
          isOn: Binding(
            get: { model.config.menuBar.columns },
            set: { model.set(table: "menu_bar", key: "columns", value: $0 ? "true" : "false") }
          ))
          .settingsSearchTarget(.menuBarColumns)
        if menuBar.columns || request.reveals(.menuBarColumnsWidth) {
          SettingsNumberRow(
            title: SettingsOption.menuBarColumnsWidth.title, value: menuBar.columnsWidth,
            range: 30...300, step: 10, unit: "pt",
            onChange: { model.set(table: "menu_bar", key: "columns_width", value: String($0)) }
          )
            .settingsSearchTarget(.menuBarColumnsWidth)
        }
      }
    }
    .formStyle(.settingsCards)
    .animation(.smooth(duration: 0.3), value: menuBar.enabled)
    .animation(.smooth(duration: 0.3), value: menuBar.columns)
    .modifier(SettingsRevealModifier(request: request))
  }
}

@MainActor
private struct LayoutSettingsView: View {
  let model: DefiSettingsModel
  let request: SettingsRevealRequest
  @State private var editingDisplay: DisplayLayoutSheet?

  var body: some View {
    Form {
      Section("Columns", symbol: "rectangle.split.3x1", color: .teal) {
        SettingsColumnsPreview(layout: model.config.layout)
        SettingsNumberRow(
          title: SettingsOption.defaultColumnWidth.title, value: model.config.layout.defaultColumnWidth * 100,
          range: 5...100, step: 5, unit: "%",

          onChange: { model.set(table: "layout", key: "default_column_width", value: String($0 / 100)) }
        )
          .settingsSearchTarget(.defaultColumnWidth)
        Picker(
          SettingsOption.focusedColumn.title,
          selection: stringBinding(
            "layout", "center_focused_column", model.config.layout.centerFocusedColumn.rawValue)
        ) {
          Text("Reveal as needed").tag(CenterFocusedColumn.never.rawValue)
          Text("Always center").tag(CenterFocusedColumn.always.rawValue)
          Text("Center on overflow").tag(CenterFocusedColumn.onOverflow.rawValue)
        }
        .settingsSearchTarget(.focusedColumn)
        settingsToggle(
          model, title: SettingsOption.centerLoneColumn.title, table: "layout",
          key: "always_center_single_column", value: model.config.layout.alwaysCenterSingleColumn
        )
          .settingsSearchTarget(.centerLoneColumn)
      }
      PresetsSettings(
        title: "Width presets", footer: "Cycle Width switches between these sizes in list order.",
        kind: .width, values: model.config.layout.presetColumnWidths,
        centering: model.config.layout.centerFocusedColumn
      ) {
        model.set(table: "layout", key: "preset_column_widths", value: tomlArray($0))
      }
        .settingsSearchTarget(.widthPresets)
      PresetsSettings(
        title: "Height presets",
        footer: "Switch Preset Window Height gives a stacked window these shares of its column in list order.",
        kind: .height, values: model.config.layout.presetWindowHeights,
        centering: model.config.layout.centerFocusedColumn
      ) {
        model.set(table: "layout", key: "preset_window_heights", value: tomlArray($0))
      }
        .settingsSearchTarget(.heightPresets)
      DisplayLayoutsSection(model: model, editing: $editingDisplay)
        .settingsSearchTarget(.displayLayouts)
      Section("Spacing", symbol: "square.dashed", color: .mint,
        info: "Margins at each screen edge, the gap between windows, and the areas kept free at the top and bottom of the screen.") {
        SpacingEditor(model: model)
          .settingsEdgeToEdge()
          .settingsSearchTarget(.screenMargins)
      }
    }
    .formStyle(.settingsCards)
    .modifier(SettingsRevealModifier(request: request))
    .settingsSubpage(item: $editingDisplay, title: \.id) { DisplayLayoutEditor(model: model, name: $0.id) }
  }

  private func stringBinding(_ table: String, _ key: String, _ value: String) -> Binding<String> {
    Binding(get: { value }, set: { model.set(table: table, key: key, value: tomlString($0)) })
  }
}

enum PresetKind {
  case width, height

  var name: String { self == .width ? "width" : "height" }
  /// Matches the validation in DefiConfig: a stacked window never takes the whole column.
  var maximum: Double { self == .width ? 100 : 95 }

  /// Percentages the add menu offers.
  func addableChoices(to values: [Double]) -> [Int] {
    [25, 33, 50, 67, 75, 100].filter { Double($0) <= maximum && !Self.duplicates(Double($0), in: values) }
  }

  /// A duplicate preset would stop the preset cycle on its first copy.
  static func duplicates(_ percentage: Double, in values: [Double], except index: Int? = nil) -> Bool {
    values.indices.contains { $0 != index && abs(values[$0] * 100 - percentage) < 0.5 }
  }
}

@MainActor
private struct PresetsSettings: View {
  let title: String
  let footer: String
  let kind: PresetKind
  let values: [Double]
  let centering: CenterFocusedColumn
  let save: ([Double]) -> Void
  @State private var hovered: Int?

  var body: some View {
    Section {
      SettingsPresetsPreview(kind: kind, values: values, held: hovered, centering: centering)
      PresetChips(kind: kind, values: values, save: save, hovered: $hovered)
    } header: {
      HStack {
        SettingsSectionTitle(title, symbol: kind == .width ? "arrow.left.and.right" : "arrow.up.and.down",
          color: kind == .width ? .blue : .indigo, info: footer)
        Spacer()
        AddPresetMenu(kind: kind, values: values, save: save)
      }
    }
  }
}

@MainActor
private struct AddPresetMenu: View {
  let kind: PresetKind
  let values: [Double]
  let save: ([Double]) -> Void

  var body: some View {
    Menu {
      ForEach(kind.addableChoices(to: values), id: \.self) { percentage in
        Button("\(percentage)%") {
          save(values + [Double(percentage) / 100])
        }
      }
    } label: {
      Image(systemName: "plus")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityLabel("Add \(kind.name) preset")
  }
}

private func tomlArray(_ widths: [Double]) -> String {
  "[\(widths.map { String($0) }.joined(separator: ", "))]"
}

private func percentage(_ width: Double) -> String { "\(Int((width * 100).rounded())) %" }

private func percentages(_ widths: [Double]) -> String {
  widths.map { "\(Int(($0 * 100).rounded()))" }.joined(separator: ", ") + " %"
}

private struct DisplayLayoutSheet: Identifiable {
  let id: String
}

/// One row per display; its widths open in a sheet so the page stays short with many displays.
@MainActor
private struct DisplayLayoutsSection: View {
  let model: DefiSettingsModel
  @Binding var editing: DisplayLayoutSheet?

  var body: some View {
    Section {
      ForEach(Array(model.monitorLayoutNames.enumerated()), id: \.offset) { _, name in
        Button { editing = DisplayLayoutSheet(id: name) } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(name)
            Text(summary(name)).font(.caption).foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.settingsNavigation)
        .accessibilityHint("Customize widths on this display")
      }
    } header: {
      SettingsSectionTitle("Displays", symbol: "display", color: .cyan,
        info: "Give a display its own column widths. Other displays use the values above.")
    }
  }

  private func summary(_ name: String) -> String {
    let connection = model.displayNames.contains(name) ? "" : "Not connected · "
    guard let override = model.monitorLayout(name) else { return connection + "Same as all displays" }
    let width = override.defaultColumnWidth.map(percentage) ?? "same width"
    let presets = override.presetColumnWidths.map { "presets \(percentages($0))" } ?? "same presets"
    return connection + "\(width) · \(presets)"
  }
}

/// Each value inherits the global one until customized; inheriting both removes the display's table.
@MainActor
private struct DisplayLayoutEditor: View {
  let model: DefiSettingsModel
  let name: String
  @Environment(\.closeSettingsSubpage) private var dismiss

  var body: some View {
    let override = model.monitorLayout(name)
    let layout = model.config.layout
    Form {
        Section {
          Toggle("Same as all displays", isOn: Binding(
            get: { override?.defaultColumnWidth == nil },
            set: { model.setMonitorLayout(name, key: "default_column_width", value: $0 ? nil : String(layout.defaultColumnWidth)) }
          ))
          if let width = override?.defaultColumnWidth {
            SettingsNumberRow(
              title: "Width", value: width * 100, range: 5...100, step: 5, unit: "%",
              onChange: { model.setMonitorLayout(name, key: "default_column_width", value: String($0 / 100)) }
            )
          } else {
            LabeledContent("Width", value: percentage(layout.defaultColumnWidth))
              .foregroundStyle(.secondary)
          }
        } header: {
          SettingsInfoLabel(SettingsOption.defaultColumnWidth.title, "New windows on \(name) open at this width.")
        }
        Section {
          Toggle("Same as all displays", isOn: Binding(
            get: { override?.presetColumnWidths == nil },
            set: {
              model.setMonitorLayout(
                name, key: "preset_column_widths", value: $0 ? nil : tomlArray(layout.presetColumnWidths))
            }
          ))
          if let presets = override?.presetColumnWidths {
            let save = { model.setMonitorLayout(name, key: "preset_column_widths", value: tomlArray($0)) }
            PresetChips(kind: .width, values: presets, save: save, hovered: .constant(nil))
            LabeledContent("Add preset") { AddPresetMenu(kind: .width, values: presets, save: save) }
          } else {
            LabeledContent("Presets", value: percentages(layout.presetColumnWidths))
              .foregroundStyle(.secondary)
          }
        } header: {
          SettingsInfoLabel("Width presets", "Cycle Width steps through these on \(name). Spacing stays the same on every display.")
        }
    }
    .formStyle(.settingsCards)
    .safeAreaInset(edge: .bottom) {
      SettingsSubpageActions { Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
    }
  }
}

@MainActor
private struct PointerSettingsView: View {
  let model: DefiSettingsModel
  let request: SettingsRevealRequest
  @State private var gestureDemo = SettingsPointerDemo.swipe

  var body: some View {
    let input = model.config.input
    Form {
      Section("Pointer", symbol: "cursorarrow", color: .blue) {
        Toggle(isOn: boolBinding("input", "focus_follows_mouse", input.focusFollowsMouse)) {
          SettingsInfoLabel(SettingsOption.focusFollowsPointer.title,
            "Moving the pointer onto a window focuses it, without a click.")
        }
          .settingsSearchTarget(.focusFollowsPointer)
        if input.focusFollowsMouse || request.reveals(.pointerFocusDelay, .pointerFocusScroll) {
          SettingsNumberRow(
            title: SettingsOption.pointerFocusDelay.title,
            value: Double(input.focusFollowsMouseDelayMS),
            range: 0...1_000, step: 10, unit: "ms",
            info: "How long the pointer must rest on a window before it takes focus. 0 ms focuses at once.",
            onChange: { model.set(table: "input", key: "focus_follows_mouse_delay_ms", value: String(Int($0.rounded()))) }
          )
            .settingsSearchTarget(.pointerFocusDelay)
          SettingsNumberRow(
            title: SettingsOption.pointerFocusScroll.title,
            value: (input.focusFollowsMouseMaxScrollAmount ?? 0) * 100,
            range: 0...100, step: 1, unit: "%",
            info: "How far the strip may scroll to focus a window under the pointer, as a share of the screen width. 0 % focuses only windows already fully in view.",
            onChange: { model.set(table: "input", key: "focus_follows_mouse_max_scroll_amount", value: String($0 / 100)) }
          )
            .settingsSearchTarget(.pointerFocusScroll)
        }
        Toggle(isOn: boolBinding("input", "mouse_follows_focus", input.mouseFollowsFocus)) {
          SettingsInfoLabel(SettingsOption.pointerFollowsFocus.title,
            "Moves the pointer to the center of a window you focus with the keyboard, unless it is already inside.")
        }
          .settingsSearchTarget(.pointerFollowsFocus)
      }
      Section("Trackpad", symbol: "hand.draw", color: .teal) {
        SettingsPointerDemoView(demo: gestureDemo, input: input)
        ScrollGestureSettings(model: model, request: request)
          .onHover { if $0 { gestureDemo = .swipe } }
        if input.scrollGestures || request.reveals(.scrollGestureSpeed, .scrollGestureSnap) {
          SettingsNumberRow(
            title: SettingsOption.scrollGestureSpeed.title,
            value: input.scrollGestureSpeed * 100,
            range: 25...400, step: 5, unit: "%",
            onChange: { model.set(table: "input", key: "scroll_gesture_speed", value: String($0 / 100)) }
          )
            .settingsSearchTarget(.scrollGestureSpeed)
            .onHover { if $0 { gestureDemo = .swipe } }
          Toggle(isOn: boolBinding("input", "scroll_gesture_snap", input.scrollGestureSnap)) {
            SettingsInfoLabel(SettingsOption.scrollGestureSnap.title, input.scrollGestureSnap
              ? "The strip lands on the nearest column."
              : "The strip stops where you let go. The column in the middle gets focus.")
          }
            .settingsSearchTarget(.scrollGestureSnap)
            .onHover { if $0 { gestureDemo = .swipe } }
        }
        OverviewGestureSettings(model: model)
          .onHover { if $0 { gestureDemo = .overview } }
        WindowTilingConflict()
      }
    }
    .formStyle(.settingsCards)
    .animation(.smooth(duration: 0.3), value: input.focusFollowsMouse)
    .animation(.smooth(duration: 0.3), value: input.scrollGestures)
    .modifier(SettingsRevealModifier(request: request))
  }

  private func boolBinding(_ table: String, _ key: String, _ value: Bool) -> Binding<Bool> {
    Binding(get: { value }, set: { model.set(table: table, key: key, value: $0 ? "true" : "false") })
  }
}

@MainActor
private struct KeyboardSettingsView: View {
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
private final class ShortcutSearch {
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
private struct ShortcutSearchBar: View {
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
private struct ShortcutSearchResults: View {
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
private struct SettingsShortcutSlots: Equatable {
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
private struct SettingsShortcutListForm: View, Equatable {
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
private struct SettingsIsolatedHost<Content: View>: NSViewRepresentable {
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
private final class SettingsShortcutSlotsCache {
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
private struct SettingsShortcutActionRow: View, Equatable {
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

@MainActor
private struct AppearanceSettingsView: View {
  let model: DefiSettingsModel
  let request: SettingsRevealRequest
  @AppStorage(settingsShowAdvancedKey) private var advanced = false

  var body: some View {
    let borders = model.config.decorations.borders
    Form {
      Section {
        SettingsBorderPreview(config: model.config)
          .settingsEdgeToEdge()
      }
      Section("Window borders", symbol: "square.dashed.inset.filled", color: .purple) {
        settingsToggle(
          model, title: SettingsOption.focusedBorder.title, table: "decorations.borders",
          key: "enabled", value: borders.enabled
        )
          .settingsSearchTarget(.focusedBorder)
        if borders.enabled || request.reveals(.borderWidth, .focusedBorderColor, .borderPlacement, .captureBorders) {
          SettingsNumberRow(
            title: SettingsOption.borderWidth.title, value: borders.width,
            range: 0...64, step: 1, unit: "px",
            onChange: { model.set(table: "decorations.borders", key: "width", value: String($0)) }
          )
            .settingsSearchTarget(.borderWidth)
          ColorPicker(SettingsOption.focusedBorderColor.title, selection: colorBinding("color"), supportsOpacity: true)
            .settingsSearchTarget(.focusedBorderColor)
          Picker(SettingsOption.borderPlacement.title, selection: stringBinding(
            model, table: "decorations.borders", key: "placement", value: borders.placement
          )) {
            Text("Inside window").tag("inside")
            Text("Outside window").tag("outside")
          }
          .settingsSearchTarget(.borderPlacement)
          settingsToggle(
            model, title: SettingsOption.captureBorders.title, table: "decorations.borders",
            key: "capture_enabled", value: borders.captureEnabled
          )
            .settingsSearchTarget(.captureBorders)
        }
      }
      Section("Unfocused windows", symbol: "circle.lefthalf.filled", color: .gray) {
        SettingsNumberRow(
          title: SettingsOption.unfocusedDim.title, value: borders.inactiveDim * 100,
          range: 0...90, step: 5, unit: "%",
          onChange: { model.set(table: "decorations.borders", key: "inactive_dim", value: String($0 / 100)) }
        )
          .settingsSearchTarget(.unfocusedDim)
        settingsToggle(
          model, title: SettingsOption.unfocusedBorders.title, table: "decorations.borders",
          key: "inactive_enabled", value: borders.inactiveEnabled
        )
          .settingsSearchTarget(.unfocusedBorders)
        if borders.inactiveEnabled || request.reveals(.unfocusedBorderColor) {
          ColorPicker(SettingsOption.unfocusedBorderColor.title, selection: colorBinding("inactive_color"), supportsOpacity: true)
            .settingsSearchTarget(.unfocusedBorderColor)
        }
      }
      Section("Animation", symbol: "wand.and.stars", color: .pink) {
        settingsToggle(
          model, title: SettingsOption.animations.title, table: "animation", key: "enabled",
          value: model.config.animation.enabled
        )
          .settingsSearchTarget(.animations)
        if model.config.animation.enabled || request.reveals(.animationStiffness, .animationDamping) {
          SettingsAdvancedButton(expanded: $advanced)
          if advanced || request.reveals(.animationStiffness, .animationDamping) {
            SettingsNumberRow(
              title: SettingsOption.animationStiffness.title, value: model.config.animation.stiffness,
              range: 100...2_000, step: 50, unit: "",
              info: "Spring stiffness of every motion. Higher is faster.",
              onChange: { model.set(table: "animation", key: "stiffness", value: String($0)) }
            )
              .settingsSearchTarget(.animationStiffness)
            SettingsNumberRow(
              title: SettingsOption.animationDamping.title, value: model.config.animation.dampingRatio,
              range: 0.5...1, step: 0.05, unit: "",
              info: "1 never overshoots. Lower values arrive sooner and overshoot slightly.",
              onChange: { model.set(table: "animation", key: "damping_ratio", value: String($0)) }
            )
              .settingsSearchTarget(.animationDamping)
          }
        }
      }
      Section("Overview", symbol: "square.grid.2x2", color: .blue) {
        settingsToggle(
          model, title: SettingsOption.windowPreviews.title, table: "overview",
          key: "window_previews", value: model.config.overview.windowPreviews
        )
          .settingsSearchTarget(.windowPreviews)
        settingsToggle(
          model, title: SettingsOption.overviewSearchBar.title, table: "overview",
          key: "search_bar", value: model.config.overview.searchBar
        )
          .settingsSearchTarget(.overviewSearchBar)
        SettingsAdvancedButton(expanded: $advanced)
        if advanced || request.reveals(.overviewScale, .overviewCornerRadius) {
          SettingsNumberRow(
            title: SettingsOption.overviewScale.title, value: model.config.overview.zoom * 100,
            range: 0...75, step: 5, unit: "%",
            onChange: { model.set(table: "overview", key: "zoom", value: String($0 / 100)) }
          )
            .settingsSearchTarget(.overviewScale)
          SettingsNumberRow(
            title: SettingsOption.overviewCornerRadius.title, value: model.config.overview.windowCornerRadius,
            range: 0...64, step: 1, unit: "px",
            onChange: { model.set(table: "overview", key: "window_corner_radius", value: String($0)) }
          )
            .settingsSearchTarget(.overviewCornerRadius)
        }
      }
    }
    .formStyle(.settingsCards)
    .animation(.smooth(duration: 0.3), value: borders.enabled)
    .animation(.smooth(duration: 0.3), value: borders.inactiveEnabled)
    .animation(.smooth(duration: 0.3), value: model.config.animation.enabled)
    .animation(.smooth(duration: 0.3), value: advanced)
    .modifier(SettingsRevealModifier(request: request))
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
private let modifierOrder: [(name: String, symbol: String, title: String)] = [
  ("ctrl", "⌃", "Control"), ("alt", "⌥", "Option"), ("shift", "⇧", "Shift"), ("cmd", "⌘", "Command"),
]

@MainActor
private struct ModKeyRow: View {
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

private struct SettingsNumberRow: View {
  let title: String
  let value: Double
  let range: ClosedRange<Double>
  let step: Double
  let unit: String
  var info: String?
  let onChange: (Double) -> Void

  private var valueBinding: Binding<Double> {
    Binding(get: { value }, set: { onChange($0) })
  }

  var body: some View {
    HStack(spacing: 8) {
      if let info { SettingsInfoLabel(title, info) } else { Text(title) }
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

/// Which fingers swipe the strip, whether the modifier must be held, and what macOS
/// already does with those swipes.
@MainActor
private struct ScrollGestureSettings: View {
  let model: DefiSettingsModel
  let request: SettingsRevealRequest

  var body: some View {
    let input = model.config.input
    let fingers = input.scrollGestureFingers
    let modifier = model.config.scrollGestureModifier
    let system = systemTrackpadSwipes(fingers: fingers)
    let overviewFingers = input.overviewGesture ? input.overviewGestureFingers : nil
    let activationBlocked = !input.scrollGestures && fingers == overviewFingers
    Group {
      Toggle(SettingsOption.scrollGestures.title, isOn: Binding(
        get: { input.scrollGestures },
        set: { model.setScrollGesturesEnabled($0) }
      ))
        .settingsSearchTarget(.scrollGestures)
        .disabled(activationBlocked)
      if activationBlocked {
        Text("The Overview uses this gesture. Choose a different number of fingers to enable scrolling.")
          .settingsNote()
      }
      if input.scrollGestures || activationBlocked || request.reveals(.scrollGestureFingers, .scrollGestureModifier) {
        details(input: input, fingers: fingers, modifier: modifier, system: system, overviewFingers: overviewFingers)
      }
    }
  }

  @ViewBuilder private func details(
    input: InputConfig, fingers: Int, modifier: String, system: (horizontal: Bool, vertical: Bool), overviewFingers: Int?
  ) -> some View {
      GestureFingersMenu(
        title: SettingsOption.scrollGestureFingers.title,
        choices: [(2, "Two"), (3, "Three"), (4, "Four")],
        selection: fingers, reservedFingers: overviewFingers, reservation: "used by the Overview",
        select: model.setScrollGestureFingers
      )
        .settingsSearchTarget(.scrollGestureFingers)
      Toggle(isOn: Binding(
        get: { modifier != "none" },
        set: { held in
          if held {
            model.reset(table: "input", key: "scroll_gesture_modifier")
          } else {
            model.set(table: "input", key: "scroll_gesture_modifier", value: tomlString("none"))
          }
        }
      )) {
        SettingsInfoLabel(SettingsOption.scrollGestureModifier.title, caption(fingers: fingers, modifier: modifier, system: system))
      }
        .settingsSearchTarget(.scrollGestureModifier)
        .disabled(!input.scrollGestures || fingers == 2)
      if let conflict = conflict(fingers: fingers, system: system) {
        HStack(alignment: .firstTextBaseline) {
          Label(conflict, systemImage: "exclamationmark.triangle")
            .font(.caption)
          Spacer()
          MoreGesturesButton()
        }
      }
  }

  private func caption(fingers: Int, modifier: String, system: (horizontal: Bool, vertical: Bool)) -> String {
    let hand = (fingers == 2 ? "Two" : fingers == 3 ? "Three" : "Four") + " fingers"
      + (modifier == "none" ? "" : " with \(modifier) held")
    // Only the directions macOS leaves to Defi.
    let axes = [system.horizontal ? nil : "left or right for columns",
      system.vertical ? nil : "up or down for workspaces"].compactMap { $0 }
    let wheel = modifier == "none" ? "" : " The mouse wheel works too."
    return axes.isEmpty ? wheel.trimmingCharacters(in: .whitespaces)
      : "\(hand): \(axes.joined(separator: ", ")).\(wheel)"
  }

  private func conflict(fingers: Int, system: (horizontal: Bool, vertical: Bool)) -> String? {
    let direction: String
    switch (system.horizontal, system.vertical) {
    case (true, true): direction = ""
    case (false, true): direction = " up or down"
    case (true, false): direction = " left or right"
    case (false, false): return nil
    }
    let count = fingers == 3 ? "three" : "four"
    return "macOS already uses \(count)-finger swipes\(direction). Change them in More Gestures to use them here."
  }
}

/// macOS tiling takes a window released where a title-bar drag drops it at an edge.
private struct WindowTilingConflict: View {
  @State private var tiling = systemWindowTilingByEdgeDrag()

  var body: some View {
    Group {
      if let places = places {
        HStack(alignment: .firstTextBaseline) {
          Label("macOS also tiles a window you drag to \(places), then Defi puts it back. "
            + "Turn off its tiling in Desktop & Dock to drag there smoothly.", systemImage: "exclamationmark.triangle")
            .font(.caption)
          Spacer()
          Button("Desktop & Dock…") { openDesktopAndDockSettings() }
        }
      }
    }
    // Picks up a change made in System Settings on the way back.
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      tiling = systemWindowTilingByEdgeDrag()
    }
  }

  private var places: String? {
    switch (tiling.sides, tiling.top) {
    case (true, true): "a screen edge or the menu bar"
    case (true, false): "a screen's side edge"
    case (false, true): "the menu bar"
    case (false, false): nil
    }
  }
}

/// Opens the More Gestures tab of the Trackpad settings, where macOS assigns swipes.
private struct MoreGesturesButton: View {
  var body: some View {
    Button("More Gestures…") {
      NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension?MoreGestures")!)
    }
  }
}

/// Which fingers swipe the Overview open, and what keeps that swipe from working.
@MainActor
private struct OverviewGestureSettings: View {
  let model: DefiSettingsModel

  var body: some View {
    let input = model.config.input
    let scrollFingers = input.scrollGestures ? input.scrollGestureFingers : nil
    GestureFingersMenu(
      title: SettingsOption.overviewGesture.title,
      choices: [(0, "Off"), (3, "Three fingers"), (4, "Four fingers")],
      selection: input.overviewGesture ? input.overviewGestureFingers : 0,
      reservedFingers: scrollFingers, reservation: "used by scrolling",
      select: { model.setOverviewGestureFingers($0 == 0 ? nil : $0) }
    )
      .settingsSearchTarget(.overviewGesture)
    if input.overviewGesture, input.overviewSwipesMoveStrip || systemTrackpadSwipes(fingers: input.overviewGestureFingers).vertical {
      caption(input)
    }
  }

  @ViewBuilder
  private func caption(_ input: InputConfig) -> some View {
    let count = input.overviewGestureFingers == 3 ? "Three" : "Four"
    if input.overviewSwipesMoveStrip {
      Label("\(count)-finger swipes move the strip. Choose another number of fingers for one of them.",
        systemImage: "exclamationmark.triangle")
        .font(.caption)
    } else if systemTrackpadSwipes(fingers: input.overviewGestureFingers).vertical {
      HStack(alignment: .firstTextBaseline) {
        Label("macOS already uses \(count.lowercased())-finger swipes up and down. Set Mission Control's gesture to Off or another number of fingers in More Gestures; Mission Control stays on its key.",
          systemImage: "exclamationmark.triangle")
          .font(.caption)
        Spacer()
        MoreGesturesButton()
      }
    }
  }
}

private struct GestureFingersMenu: View {
  let title: String
  let choices: [(fingers: Int, title: String)]
  let selection: Int
  let reservedFingers: Int?
  let reservation: String
  let select: (Int) -> Void

  var body: some View {
    let selectedTitle = choices.first { $0.fingers == selection }?.title ?? ""
    LabeledContent(title) {
      // A macOS menu-style Picker ignores disabled modifiers on individual choices.
      Menu {
        ForEach(choices, id: \.fingers) { choice in
          let label = choice.fingers == reservedFingers ? "\(choice.title) · \(reservation)" : choice.title
          Button {
            select(choice.fingers)
          } label: {
            if choice.fingers == selection {
              Label(label, systemImage: "checkmark")
            } else {
              Text(label)
            }
          }
          .disabled(choice.fingers == reservedFingers)
        }
      } label: {
        Text(selectedTitle)
      }
      .accessibilityLabel(title)
      .accessibilityValue(selectedTitle)
    }
  }
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

/// The borders default, parsed so it keeps the `#AARRGGBB` order `settingsColor` reads.
private let defaultBorderColor = parseBorderColor(BordersConfig().color) ?? 0

func settingsColor(_ value: String) -> Color {
  let bits = parseBorderColor(value) ?? defaultBorderColor
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

/// Shows fine-tuning a card keeps folded by default. One preference for every card, so opening it once
/// keeps it open everywhere.
let settingsShowAdvancedKey = "DefiSettingsShowAdvanced"

struct SettingsAdvancedButton: View {
  @Binding var expanded: Bool

  var body: some View {
    Button { expanded.toggle() } label: {
      HStack {
        Text("Advanced").foregroundStyle(.secondary)
        Spacer()
        Image(systemName: "chevron.forward")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(expanded ? 90 : 0))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(expanded ? "Hide advanced settings" : "Show advanced settings")
  }
}

struct SettingsInfoLabel: View {
  let title: String
  let text: String
  let note: String?
  @State private var isPresented = false

  init(_ title: String, _ text: String, note: String? = nil) {
    self.title = title
    self.text = text
    self.note = note
  }

  var body: some View {
    HStack(spacing: 4) {
      if !title.isEmpty { Text(title) }
      Button { isPresented = true } label: { Image(systemName: "info.circle") }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel(title.isEmpty ? "More information" : "About \(title)")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
          VStack(alignment: .leading, spacing: 8) {
            Text(text)
            if let note { Text(note).foregroundStyle(.secondary) }
          }
          .fixedSize(horizontal: false, vertical: true)
          .frame(width: 280, alignment: .leading)
          .padding()
        }
    }
  }
}

private extension RuleWindow {
  var settingsTitle: String {
    switch self {
    case .forceFloating: "Force floating"
    case .forceTiled: "Force tiled"
    }
  }
}

@MainActor
private struct AutomaticUpdatesToggle: View {
  @AppStorage(AppUpdater.automaticChecksKey) private var automaticChecks = true

  var body: some View {
    if AppUpdater.shared.isEligible {
      Toggle(SettingsOption.automaticUpdates.title, isOn: $automaticChecks)
    }
  }
}

@MainActor
private struct TriageButton: View {
  @State private var failure: String?

  private var cliURL: URL? {
    Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "defi")
  }

  var body: some View {
    if let cliURL, FileManager.default.isExecutableFile(atPath: cliURL.path) {
      HStack(spacing: 6) {
        Button {
          do {
            let launcher = try writeTriageLauncher(
              cli: cliURL, directory: FileManager.default.temporaryDirectory)
            if NSWorkspace.shared.open(launcher) {
              failure = nil
            } else {
              try? FileManager.default.removeItem(at: launcher)
              failure = "Could not open a terminal. Run defi triage from one instead."
            }
          } catch {
            failure = "Could not start triage: \(error.localizedDescription)"
          }
        } label: {
          Label("Start Triage", systemImage: "sparkle.magnifyingglass")
        }
        SettingsInfoLabel("", failure ?? "Your own coding agent investigates a problem in Terminal and drafts an issue. It asks before it fixes or posts anything.")
        if let failure {
          Text(failure).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
      }
    }
  }
}

/// One permission at a glance: what it is for, and a check or a way to grant it.
private struct PermissionTile: View {
  let title: String
  let symbol: String
  let purpose: String
  let granted: Bool
  let grant: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.title2)
        .foregroundStyle(granted ? Color.green : .orange)
        .frame(width: 30)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).fontWeight(.medium)
        Text(purpose).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 6)
      if granted {
        Image(systemName: "checkmark.circle.fill")
          .font(.title3)
          .foregroundStyle(.green)
          .accessibilityLabel("Granted")
      } else {
        Button("Grant…", action: grant)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

/// Opening a `.command` file runs it in the user's terminal, with their login PATH, and needs no
/// Automation permission.
func writeTriageLauncher(cli: URL, directory: URL) throws -> URL {
  let quoted = "'" + cli.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  let url = directory.appending(path: "defi-triage-\(UUID().uuidString).command")
  try "#!/bin/sh\nrm -f \"$0\"\nexec \(quoted) triage\n".write(to: url, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  return url
}

/// A rule's display as Settings shows it, marked when no connected display matches.
@MainActor
private func ruleDisplayTitle(_ name: String) -> String {
  let connected = NSScreen.screens.contains { $0.localizedName.caseInsensitiveCompare(name) == .orderedSame }
  return connected ? name : "\(name) (not connected)"
}
