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

extension View {
  func settingsSearchTarget(_ option: SettingsOption) -> some View {
    id(SettingsSearchAnchor.option(option))
  }
}
