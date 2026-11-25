import DefiCore
import DefiConfig
import DefiModel
import DefiRuntime
import Testing

struct WindowLifecycleTests {
  private let monitorID = MonitorID(rawValue: 1)

  @Test
  func `Discovery uses rule workspace and follow focus`() throws {
    let config = Config(
      workspaces: WorkspacesConfig(names: ["dev", "web"]),
      rules: [Rule(appID: "browser", workspace: "web", followFocus: true)]
    )
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "browser",
      title: "Web",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )

    try discoverWindow(
      window,
      decision: config.decision(for: window),
      isNativelyFocused: true,
      state: &state
    )

    #expect(state.monitors[0].activeWorkspace == WorkspaceID(rawValue: "web"))
    #expect(state.monitors[0].workspaces[1].columns[0].windows == [window.id])
  }

  @Test
  func `A known window discovery has not read yet keeps its column`() {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let windows = (1...3).map {
      Window(
        id: WindowID(rawValue: $0), appID: "app\($0)", title: "",
        frame: Rect(x: 0, y: 0, width: 600, height: 800), processID: Int32($0), monitorID: monitorID)
    }
    reconcileWindows(windows, config: config, appliesOpenFocus: false, state: &state)
    let order = state.monitors[0].workspaces[0].columns.map(\.windows)

    reconcileWindows(
      [windows[0], windows[2]], config: config, pendingWindowIDs: [windows[1].id], state: &state)
    reconcileWindows(windows, config: config, state: &state)

    #expect(state.monitors[0].workspaces[0].columns.map(\.windows) == order)
  }

  private func lateTitleFixture() -> (Config, RuntimeState, (String) -> Window) {
    let config = Config(
      workspaces: WorkspacesConfig(names: ["dev", "web"]),
      rules: [Rule(title: "Inspector", workspace: "web", window: .forceFloating)]
    )
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    reconcileWindows([], config: config, appliesOpenFocus: false, state: &state)
    let window = { (title: String) in
      Window(
        id: WindowID(rawValue: 1), appID: "browser", title: title,
        frame: Rect(x: 0, y: 0, width: 600, height: 800), processID: 7, monitorID: self.monitorID
      )
    }
    return (config, state, window)
  }

  @Test
  func `A title set right after opening applies its rules`() throws {
    var (config, state, window) = lateTitleFixture()
    reconcileWindows([window("")], config: config, frontmostProcessID: 7, state: &state)
    #expect(state.location(containing: window("").id)?.workspaceID == WorkspaceID(rawValue: "dev"))

    reconcileWindows([window("Web Inspector")], config: config, frontmostProcessID: 7, state: &state)

    let web = WorkspaceID(rawValue: "web")
    #expect(state.location(containing: window("").id)?.workspaceID == web)
    #expect(state.windows[window("").id]?.floating == true)
    #expect(state.monitors[0].activeWorkspace == web)
  }

  @Test(arguments: [
    // Too late: the title arrives after the grace.
    (lateTitleRuleGrace + 0.1, nil, false),
    // The user floated or moved the window before its title arrived.
    (0.1, Command.toggleFloating, false),
    (0.1, Command.moveColumn(.left), false),
    (0.1, nil, true),
  ] as [(Double, Command?, Bool)])
  func `A late title never overrides the user or a window in use`(
    titleAt: Double, userCommand: Command?, titleChangedTwice: Bool
  ) throws {
    var (config, state, window) = lateTitleFixture()
    let editor = Window(
      id: WindowID(rawValue: 2), appID: "editor", title: "Code",
      frame: Rect(x: 0, y: 0, width: 600, height: 800), monitorID: monitorID
    )
    reconcileWindows([editor], config: config, appliesOpenFocus: false, state: &state)
    reconcileWindows([editor, window("")], config: config, frontmostProcessID: 7, now: 10, state: &state)
    if let userCommand {
      try reduce(userCommand, on: monitorID, state: &state)
    }
    if titleChangedTwice {
      // A first title that matches nothing uses up the one re-evaluation.
      reconcileWindows([editor, window("New Tab")], config: config, now: 10.05, state: &state)
    }
    let placement = state.monitors[0].workspaces.first { $0.id == WorkspaceID(rawValue: "dev") }

    reconcileWindows([editor, window("Web Inspector")], config: config, now: 10 + titleAt, state: &state)

    #expect(state.location(containing: window("").id)?.workspaceID == WorkspaceID(rawValue: "dev"))
    #expect(state.monitors[0].workspaces.first { $0.id == WorkspaceID(rawValue: "dev") } == placement)
  }

  @Test
  func `A late rule without a destination keeps the window on its workspace`() throws {
    let config = Config(rules: [Rule(title: "Inspector", initialColumnWidth: 0.5)])
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = { (title: String) in
      Window(
        id: WindowID(rawValue: 1), appID: "browser", title: title,
        frame: Rect(x: 0, y: 0, width: 600, height: 800), processID: 7, monitorID: self.monitorID
      )
    }
    reconcileWindows([], config: config, appliesOpenFocus: false, state: &state)
    reconcileWindows([window("")], config: config, frontmostProcessID: 7, state: &state)
    let opened = try #require(state.location(containing: window("").id)?.workspaceID)
    try reduce(.focusWorkspace(.relative(.down)), on: monitorID, state: &state)
    #expect(state.monitors[0].activeWorkspace != opened)

    reconcileWindows([window("Web Inspector")], config: config, state: &state)

    #expect(state.location(containing: window("").id)?.workspaceID == opened)
    #expect(state.monitors[0].workspaces.flatMap(\.columns).first { $0.windows == [window("").id] }?.width == .fraction(0.5))
  }

  @Test
  func `A late title never moves a floating window the user moved`() {
    var (config, state, window) = lateTitleFixture()
    var dialog = window("")
    dialog.floating = true
    reconcileWindows([dialog], config: config, frontmostProcessID: 7, now: 10, state: &state)
    #expect(state.location(containing: dialog.id)?.workspaceID == WorkspaceID(rawValue: "dev"))
    dialog.frame.x += 200
    reconcileWindows(
      [dialog], config: config, externallyChangedWindowIDs: [dialog.id], now: 10.1, state: &state
    )
    dialog.title = "Web Inspector"

    reconcileWindows([dialog], config: config, now: 10.2, state: &state)

    #expect(state.location(containing: dialog.id)?.workspaceID == WorkspaceID(rawValue: "dev"))
  }

  @Test
  func `A late title leaves a native fullscreen window where it is`() {
    var (config, state, window) = lateTitleFixture()
    reconcileWindows([window("")], config: config, frontmostProcessID: 7, state: &state)
    reconcileWindows([window("")], config: config, nativeFullscreenWindowIDs: [window("").id], state: &state)

    reconcileWindows(
      [window("Web Inspector")], config: config, nativeFullscreenWindowIDs: [window("").id], state: &state
    )
    reconcileWindows([window("Web Inspector")], config: config, state: &state)

    let workspaces = state.monitors[0].workspaces.filter {
      $0.columns.contains { $0.windows.contains(window("").id) } || $0.floatingWindows.contains(window("").id)
    }
    #expect(workspaces.map(\.id) == [WorkspaceID(rawValue: "dev")])
  }

  @Test
  func `A late title rule on the same workspace keeps the window's column`() throws {
    let config = Config(rules: [Rule(title: "Inspector", initialColumnWidth: 0.5)])
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = { (id: UInt64, title: String) in
      Window(
        id: WindowID(rawValue: id), appID: "browser", title: title,
        frame: Rect(x: 0, y: 0, width: 600, height: 800), processID: 7, monitorID: self.monitorID
      )
    }
    let left = window(1, "Left"), right = window(2, "Right")
    reconcileWindows([left, right], config: config, appliesOpenFocus: false, state: &state)
    focusWindow(left.id, state: &state)
    reconcileWindows([left, right, window(3, "")], config: config, frontmostProcessID: 7, state: &state)
    #expect(state.monitors[0].workspaces[0].columns.map(\.windows) == [[left.id], [WindowID(rawValue: 3)], [right.id]])

    reconcileWindows([left, right, window(3, "Web Inspector")], config: config, state: &state)

    let workspace = state.monitors[0].workspaces[0]
    #expect(workspace.columns.map(\.windows) == [[left.id], [WindowID(rawValue: 3)], [right.id]])
    #expect(workspace.columns[1].width == .fraction(0.5))
    #expect(state.selectedWindowID(on: monitorID) == WindowID(rawValue: 3))
  }

  @Test
  func `Rule monitor and open focus place a new window`() throws {
    let second = MonitorID(rawValue: 2)
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    state.attachMonitor(second)
    let displays: [(id: MonitorID, name: String?)] = [(monitorID, "Built-in"), (second, "DELL")]
    #expect(ruleMonitorID("dell", displays: displays) == second)
    #expect(ruleMonitorID("Studio Display", displays: displays) == nil)
    let existing = Window(
      id: WindowID(rawValue: 1), appID: "editor", title: "Code",
      frame: Rect(x: 0, y: 0, width: 600, height: 800), monitorID: monitorID
    )
    try discoverWindow(existing, decision: RuleDecision(), isFrontmostAppSpawn: true, state: &state)
    let chat = Window(
      id: WindowID(rawValue: 2), appID: "chat", title: "General",
      frame: Rect(x: 0, y: 0, width: 600, height: 800), monitorID: monitorID
    )

    try discoverWindow(
      chat, decision: RuleDecision(monitor: "DELL", openFocused: false),
      ruleMonitorID: second, isNativelyFocused: true, isFrontmostAppSpawn: true, state: &state
    )

    #expect(state.monitorID(containing: chat.id) == second)
    #expect(state.selectedWindowID(on: monitorID) == existing.id)

    // A missing display falls back to the window's own monitor; `true` forces focus.
    let note = Window(
      id: WindowID(rawValue: 3), appID: "notes", title: "Note",
      frame: Rect(x: 0, y: 0, width: 600, height: 800), monitorID: monitorID
    )
    try discoverWindow(note, decision: RuleDecision(openFocused: true), state: &state)
    #expect(state.monitorID(containing: note.id) == monitorID)
    #expect(state.selectedWindowID(on: monitorID) == note.id)
  }

  @Test
  func `Open focus applies only to windows opened after the first sync`() {
    let config = Config(rules: [Rule(appID: "notes", openFocused: true)])
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    func window(_ id: UInt64, _ appID: String) -> Window {
      Window(
        id: WindowID(rawValue: id), appID: appID, title: appID,
        frame: Rect(x: 0, y: 0, width: 600, height: 800), monitorID: monitorID
      )
    }
    let existing = [window(1, "editor"), window(2, "notes")]

    reconcileWindows(existing, config: config, appliesOpenFocus: false, state: &state)
    #expect(state.selectedWindowID(on: monitorID) != WindowID(rawValue: 2))

    reconcileWindows(existing + [window(3, "notes")], config: config, state: &state)
    #expect(state.selectedWindowID(on: monitorID) == WindowID(rawValue: 3))
  }

  @Test
  func `Only a floating window the app in use opens appears on the active monitor`() {
    let second = MonitorID(rawValue: 2)
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    state.attachMonitor(second)
    func window(
      _ id: UInt64, app: Int32? = nil, floating: Bool = true, subrole: String? = nil, on monitor: MonitorID? = nil
    ) -> Window {
      Window(
        id: WindowID(rawValue: id), appID: "app-\(app ?? Int32(id))", title: "Window \(id)",
        frame: Rect(x: 0, y: 0, width: 400, height: 300), subrole: subrole, processID: app ?? Int32(id),
        monitorID: monitor ?? monitorID, floating: floating, floatingOrigin: floating ? .automatic : nil
      )
    }
    func open(_ windows: [Window], frontmost: Int32? = nil) {
      reconcileWindows(
        windows, config: config, frontmostProcessID: frontmost ?? windows.last?.processID,
        activeMonitorID: second, state: &state)
    }
    func monitor(_ id: UInt64) -> MonitorID? { state.monitorID(containing: WindowID(rawValue: id)) }

    let present = window(1)
    reconcileWindows([present], config: config, appliesOpenFocus: false, activeMonitorID: second, state: &state)
    #expect(monitor(1) == monitorID)

    var windows = [present, window(2)]
    open(windows)
    #expect(monitor(2) == second)
    windows.append(window(3, floating: false))
    open(windows)
    #expect(monitor(3) == monitorID)
    // A background app's window, such as one macOS reopens at login, stays where it opens.
    windows.append(window(4))
    open(windows, frontmost: 3)
    #expect(monitor(4) == monitorID)

    // Minimizing removes a window from the snapshot; it returns with the same ID, even after a restart.
    open(windows.filter { $0.id.rawValue != 1 })
    state = RuntimeState(config: config, topology: WorkspaceTopology(state: state))
    open(windows, frontmost: 1)
    #expect(monitor(1) == monitorID)

    // An app restoring a document with its palette keeps them together, whatever the discovery order.
    windows += [window(5, app: 9), window(6, app: 9, floating: false)]
    open(windows, frontmost: 9)
    #expect(monitor(5) == monitorID)
    #expect(monitor(6) == monitorID)
    // An app that already shows a window on the active monitor opens its new floating window there.
    windows.append(window(7, app: 9, floating: false, on: second))
    open(windows)
    windows.append(window(8, app: 9))
    open(windows)
    #expect(monitor(8) == second)
    // A palette that shows before its document never crosses displays on its own.
    windows.append(window(9, app: 10, subrole: "AXFloatingWindow"))
    open(windows)
    #expect(monitor(9) == monitorID)
    windows.append(window(10, app: 10, floating: false))
    open(windows)
    #expect(monitor(9) == monitorID)
    #expect(monitor(10) == monitorID)
  }

  @Test
  func `Transient inherits owners workspace without activating it`() throws {
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let owner = Window(
      id: WindowID(rawValue: 1),
      appID: "finder",
      title: "Trash",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )
    try discoverWindow(
      owner,
      decision: RuleDecision(workspace: WorkspaceID(rawValue: "web")),
      state: &state
    )
    let dialog = Window(
      id: WindowID(rawValue: 2),
      appID: "finder",
      title: "Empty Trash?",
      frame: Rect(x: 100, y: 100, width: 300, height: 200),
      transientOwnerID: owner.id,
      isModal: true,
      monitorID: monitorID,
      floating: true,
      floatingOrigin: .automatic
    )

    try discoverWindow(dialog, decision: RuleDecision(), state: &state)

    #expect(state.monitors[0].activeWorkspace == WorkspaceID(rawValue: "dev"))
    #expect(state.location(containing: dialog.id)?.workspaceID == WorkspaceID(rawValue: "web"))
  }

  @Test
  func `Background transient ignores follow focus rule`() throws {
    let web = WorkspaceID(rawValue: "web")
    let config = Config(
      workspaces: WorkspacesConfig(names: ["dev", web.rawValue]),
      rules: [Rule(appID: "finder", followFocus: true)]
    )
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let owner = Window(
      id: WindowID(rawValue: 1),
      appID: "finder",
      title: "Trash",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )
    try discoverWindow(owner, decision: RuleDecision(workspace: web), state: &state)
    let dialog = Window(
      id: WindowID(rawValue: 2),
      appID: "finder",
      title: "Empty Trash?",
      frame: Rect(x: 100, y: 100, width: 300, height: 200),
      transientOwnerID: owner.id,
      isModal: true,
      monitorID: monitorID,
      floating: true,
      floatingOrigin: .automatic
    )

    reconcileWindows([owner, dialog], config: config, state: &state)

    #expect(state.monitors[0].activeWorkspace == WorkspaceID(rawValue: "dev"))
    #expect(state.location(containing: dialog.id)?.workspaceID == web)

    reconcileWindows([owner], config: config, state: &state)
    reconcileWindows(
      [owner, dialog],
      config: config,
      nativeFocusedWindowID: dialog.id,
      state: &state
    )

    #expect(state.monitors[0].activeWorkspace == web)
  }

  @Test
  func `Move window to workspace follows`() throws {
    let config = Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "Editor",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )
    try discoverWindow(window, decision: RuleDecision(), state: &state)

    try reduce(
      .moveWindowToWorkspace(WorkspaceID(rawValue: "web")),
      on: monitorID,
      state: &state
    )

    #expect(state.monitors[0].activeWorkspace == WorkspaceID(rawValue: "web"))
    #expect(state.monitors[0].workspaces[1].columns[0].windows == [window.id])
    #expect(state.monitors[0].workspaces[0].columns.isEmpty)
  }

  @Test
  func `Reconcile removes closed window`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "Editor",
      frame: Rect(x: 0, y: 0, width: 600, height: 800),
      monitorID: monitorID
    )
    try discoverWindow(window, decision: RuleDecision(), state: &state)

    reconcileWindows([], config: config, state: &state)

    #expect(state.windows.isEmpty)
    #expect(state.monitors[0].workspaces[0].columns.isEmpty)
  }

  @Test(arguments: [nil, 700.0])
  func `Closing a column left of the view keeps the visible columns in place`(firstMinimumWidth: Double?) throws {
    let config = Config(layout: LayoutConfig(defaultColumnWidth: 0.5))
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)
    var windows = (1...5).map {
      Window(
        id: WindowID(rawValue: UInt64($0)), appID: "app", title: "\($0)",
        frame: Rect(x: 0, y: 0, width: 500, height: 700), monitorID: monitorID)
    }
    windows[0].minimumTiledWidth = firstMinimumWidth
    func settle() {
      synchronizeScrollOffsets(state: &state, viewports: [monitorID: viewport])
      state.monitors[0].workspaces[0].scrollOffset = state.monitors[0].workspaces[0].targetScrollOffset
    }
    for window in windows {
      try discoverWindow(window, decision: RuleDecision(), isFrontmostAppSpawn: true, state: &state)
      settle()
    }
    for direction in [Direction.left, .left, .right] {
      try reduce(.focusColumn(direction), on: monitorID, state: &state, viewports: [monitorID: viewport])
      settle()
    }
    // Columns 3 and 4 show, column 4 selected; a minimum width also counts its gaps.
    let firstWidth = (firstMinimumWidth ?? 500) / 1_000
    #expect(abs(state.monitors[0].workspaces[0].targetScrollOffset - firstWidth - 0.5) < 0.05)

    reconcileWindows(Array(windows.dropFirst()), config: config, viewports: [monitorID: viewport], state: &state)
    settle()

    // Column 1 left the strip off screen: columns 3 and 4 stay where they were.
    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 0.5)
    #expect(state.monitors[0].workspaces[0].scrollOffset == 0.5)
  }

  @Test
  func `Reconcile preserves layout when a native tab replaces the window ID`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let original = Window(
      id: WindowID(rawValue: 1),
      appID: "terminal",
      title: "First",
      frame: Rect(x: 0, y: 0, width: 1_200, height: 800),
      monitorID: monitorID,
      maximumTiledHeight: 900
    )
    try discoverWindow(original, decision: RuleDecision(), state: &state)
    state.monitors[0].workspaces[0].columns[0].width = .fraction(0.8)
    state.monitors[0].workspaces[0].targetScrollOffset = 240
    let replacement = Window(
      id: WindowID(rawValue: 2),
      appID: original.appID,
      title: "Second",
      frame: original.frame,
      monitorID: monitorID
    )

    reconcileWindows(
      [replacement, replacement],
      config: config,
      windowIDReplacements: [original.id: replacement.id],
      state: &state
    )

    let workspace = state.monitors[0].workspaces[0]
    #expect(workspace.columns.count == 1)
    #expect(workspace.columns[0].windows == [replacement.id])
    #expect(workspace.columns[0].width == .fraction(0.8))
    #expect(workspace.targetScrollOffset == 240)
    #expect(state.selectedWindowID(on: monitorID) == replacement.id)
    #expect(state.windows[original.id] == nil)
    #expect(state.windows[replacement.id]?.maximumTiledHeight == nil)
  }

  @Test
  func `Unbounded windows keep full height after repeated short native frames`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1), appID: "resizable-app", title: "Window",
      frame: Rect(x: 0, y: 0, width: 800, height: 738), monitorID: monitorID
    )
    try discoverWindow(window, decision: RuleDecision(), state: &state)
    let viewport = Rect(x: 0, y: 0, width: 2560, height: 1371)
    func layout(_ state: RuntimeState) -> Rect {
      computeLayout(
        workspace: state.monitors[0].workspaces[0], viewport: viewport,
        windows: Array(state.windows.values), settings: state.layout
      )[0].frame
    }
    let requested = layout(state)
    var provisional = requested
    provisional.height = 738
    for _ in 0..<3 {
      state.acceptTiledWindowFrame(
        provisional, requested: requested, for: window.id, settled: false
      )
      var observed = window
      observed.frame = provisional
      reconcileWindows([observed], config: config, state: &state)
      #expect(state.windows[window.id]?.frame == provisional)
      #expect(state.windows[window.id]?.tiledSizeAcceptance == nil)
      #expect(layout(state) == requested)
    }

    state.acceptTiledWindowFrame(provisional, requested: requested, for: window.id, settled: true)
    #expect(layout(state) == requested)
    #expect(state.windows[window.id]?.tiledSizeAcceptance == nil)
  }

  @Test
  func `A width a few points off the request is kept only once settled`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1), appID: "com.mitchellh.ghostty", title: "Terminal",
      frame: Rect(x: 0, y: 0, width: 800, height: 738), monitorID: monitorID
    )
    try discoverWindow(window, decision: RuleDecision(), state: &state)
    let requested = Rect(x: 4, y: 34, width: 1270, height: 1356)
    let snapped = Rect(x: 6, y: 34, width: 1268, height: 1356)
    state.acceptTiledWindowFrame(snapped, requested: requested, for: window.id, settled: false)
    #expect(state.windows[window.id]?.tiledSizeAcceptance == nil)

    state.acceptTiledWindowFrame(snapped, requested: requested, for: window.id, settled: true)
    #expect(state.windows[window.id]?.tiledSizeAcceptance
      == TiledSizeAcceptance(requested: requested, accepted: snapped))
    var observed = window
    observed.frame = snapped
    reconcileWindows([observed], config: config, state: &state)
    #expect(state.windows[window.id]?.tiledSizeAcceptance?.accepted == snapped)
  }

  @Test
  func `A settled width far from the request is a bound, not a snap`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1), appID: "com.apple.mail", title: "Mail",
      frame: Rect(x: 0, y: 0, width: 800, height: 738), monitorID: monitorID
    )
    try discoverWindow(window, decision: RuleDecision(), state: &state)
    state.acceptTiledWindowFrame(
      Rect(x: 4, y: 34, width: 1200, height: 1356),
      requested: Rect(x: 4, y: 34, width: 1270, height: 1356), for: window.id, settled: true)
    #expect(state.windows[window.id]?.tiledSizeAcceptance == nil)
  }

  @Test
  func `Native bounded tile size settles and mode changes retry the preferred tile`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    var window = Window(
      id: WindowID(rawValue: 1), appID: "resizable-app", title: "Panel",
      frame: Rect(x: 0, y: 0, width: 344, height: 738), monitorID: monitorID,
      maximumTiledHeight: 1371
    )
    try discoverWindow(window, decision: RuleDecision(), state: &state)
    let viewport = Rect(x: 0, y: 0, width: 2560, height: 1371)
    func layout(_ state: RuntimeState, viewport: Rect) -> Rect {
      computeLayout(
        workspace: state.monitors[0].workspaces[0], viewport: viewport,
        windows: Array(state.windows.values), settings: state.layout
      )[0].frame
    }
    let requested = layout(state, viewport: viewport)
    let preferredWidth = state.monitors[0].workspaces[0].columns[0].width
    window.frame = Rect(x: requested.x, y: requested.y, width: 344, height: 738)
    state.acceptTiledWindowFrame(window.frame, requested: requested, for: window.id, settled: false)
    var cachedBeforeWrite = window
    cachedBeforeWrite.frame = requested
    reconcileWindows([cachedBeforeWrite], config: config, state: &state)
    #expect(state.windows[window.id]?.tiledSizeAcceptance?.accepted == window.frame)
    for _ in 0..<3 {
      reconcileWindows([window], config: config, state: &state)
      let settled = layout(state, viewport: viewport)
      #expect(settled.width == window.frame.width)
      #expect(settled.height == window.frame.height)
      state.acceptTiledWindowFrame(window.frame, requested: settled, for: window.id, settled: false)
    }
    #expect(state.monitors[0].workspaces[0].columns[0].width == preferredWidth)
    // A new layout target must also get a chance to resize the window.
    let smallerViewport = Rect(x: 0, y: 0, width: 1200, height: 900)
    #expect(layout(state, viewport: smallerViewport).height != 738)
    window.frame.height = 900
    reconcileWindows(
      [window], config: config,
      externallyChangedWindowIDs: [window.id], state: &state
    )
    #expect(layout(state, viewport: viewport) == requested)

    window.frame.height = 738
    state.acceptTiledWindowFrame(window.frame, requested: requested, for: window.id, settled: false)
    window.maximumTiledHeight = nil
    reconcileWindows([window], config: config, state: &state)
    #expect(state.windows[window.id]?.maximumTiledHeight == nil)
    #expect(state.windows[window.id]?.tiledSizeAcceptance == nil)
    #expect(layout(state, viewport: viewport).height == requested.height)
  }

  @Test
  func `Reconcile preserves intrinsic dimensions after applied gaps`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let initial = Window(
      id: WindowID(rawValue: 1),
      appID: "simulator",
      title: "Phone",
      frame: Rect(x: 0, y: 0, width: 320, height: 640),
      monitorID: monitorID,
      intrinsicSize: true
    )
    try discoverWindow(
      initial,
      decision: RuleDecision(intrinsicSize: true),
      state: &state
    )
    let observedAfterLayout = Window(
      id: initial.id,
      appID: initial.appID,
      title: initial.title,
      frame: Rect(x: 8, y: 8, width: 304, height: 624),
      monitorID: monitorID
    )

    reconcileWindows([observedAfterLayout], config: config, state: &state)

    #expect(state.windows[initial.id]?.frame.width == 320)
    #expect(state.windows[initial.id]?.frame.height == 640)
  }

  @Test
  func `Reconcile adopts external intrinsic resize`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let initial = Window(
      id: WindowID(rawValue: 1),
      appID: "simulator",
      title: "Phone",
      frame: Rect(x: 0, y: 0, width: 320, height: 640),
      monitorID: monitorID,
      intrinsicSize: true
    )
    try discoverWindow(
      initial,
      decision: RuleDecision(intrinsicSize: true),
      state: &state
    )
    let resized = Window(
      id: initial.id,
      appID: initial.appID,
      title: initial.title,
      frame: Rect(x: 0, y: 0, width: 430, height: 860),
      monitorID: monitorID
    )

    reconcileWindows(
      [resized],
      config: config,
      externallyChangedWindowIDs: [initial.id],
      state: &state
    )

    #expect(state.windows[initial.id]?.frame.width == 430)
    #expect(state.windows[initial.id]?.frame.height == 860)
  }

}
