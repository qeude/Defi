import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing

struct RuntimeWidthConstraintTests {
  @Test
  func initialWidthCyclingIsOptInAndUsesOnlyTheFocusedWindowRules() throws {
    let monitorID = MonitorID(rawValue: 1)
    let deviceID = WindowID(rawValue: 1)
    let otherID = WindowID(rawValue: 2)
    var config = Config(rules: [Rule(appID: "device", initialColumnWidth: 0.44)])
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    for (id, appID) in [(deviceID, "device"), (otherID, "other")] {
      state.windows[id] = Window(
        id: id, appID: appID, title: appID,
        frame: Rect(x: 0, y: 0, width: 824, height: 800)
      )
    }
    state.monitors[0].workspaces[0].columns = [
      Column(window: deviceID, width: .fraction(0.33))
    ]
    try reduce(.cycleWidth(.next), on: monitorID, state: &state)
    #expect(state.monitors[0].workspaces[0].columns[0].width == .fraction(0.5))

    config.rules[0].includeInitialWidthInCycle = true
    let optInReflows = state.applyConfiguration(config)
    #expect(!optInReflows)
    try reduce(.cycleWidth(.previous), on: monitorID, state: &state)
    #expect(state.monitors[0].workspaces[0].columns[0].width == .fraction(0.44))
    try reduce(.cycleWidth(.next), on: monitorID, state: &state)
    #expect(state.monitors[0].workspaces[0].columns[0].width == .fraction(0.5))
    #expect(state.layout.presetColumnWidths == [0.33, 0.5, 0.66, 0.8])

    state.monitors[0].workspaces[0].columns[0].windows.append(otherID)
    state.monitors[0].workspaces[0].columns[0].focusedWindow = 1
    try reduce(.cycleWidth(.previous), on: monitorID, state: &state)
    #expect(state.monitors[0].workspaces[0].columns[0].width == .fraction(0.33))

    state.monitors[0].workspaces[0].columns[0].focusedWindow = 0
    config.rules[0].initialColumnWidth = 0.5
    let widthReflows = state.applyConfiguration(config)
    #expect(!widthReflows)
    try reduce(.cycleWidth(.next), on: monitorID, state: &state)
    try reduce(.cycleWidth(.next), on: monitorID, state: &state)
    #expect(state.monitors[0].workspaces[0].columns[0].width == .fraction(0.66))

    config.rules[0].initialColumnWidth = nil
    config.layout.defaultColumnWidth = 0.44
    _ = state.applyConfiguration(config)
    state.monitors[0].workspaces[0].columns[0].width = .fraction(0.33)
    try reduce(.cycleWidth(.next), on: monitorID, state: &state)
    #expect(state.monitors[0].workspaces[0].columns[0].width == .fraction(0.5))

    config.layout.presetColumnWidths = [0.8, 0.33, 0.5]
    config.rules[0].initialColumnWidth = 0.44
    _ = state.applyConfiguration(config)
    state = RuntimeState(config: config, topology: state.topology)
    state.monitors[0].workspaces[0].columns[0].width = .fraction(0.44)
    try reduce(.cycleWidth(.next), on: monitorID, state: &state)
    #expect(state.monitors[0].workspaces[0].columns[0].width == .fraction(0.8))
    try reduce(.cycleWidth(.previous), on: monitorID, state: &state)
    #expect(state.monitors[0].workspaces[0].columns[0].width == .fraction(0.44))
  }

  @Test
  func discoveredNativeConstraintsReplaceLearnedBounds() {
    let monitorID = MonitorID(rawValue: 1)
    let windowID = WindowID(rawValue: 1)
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    state.windows[windowID] = Window(
      id: windowID,
      appID: "editor",
      title: "Editor",
      frame: Rect(x: 0, y: 0, width: 900, height: 700),
      monitorID: monitorID,
      minimumTiledWidth: 700,
      maximumTiledWidth: 1_000
    )
    state.monitors[0].workspaces[0].columns = [
      Column(window: windowID, width: .fraction(0.5))
    ]
    let observed = Window(
      id: windowID,
      appID: "editor",
      title: "Editor",
      frame: Rect(x: 0, y: 0, width: 900, height: 700),
      monitorID: monitorID,
      minimumTiledWidth: 840
    )

    reconcileWindows([observed], config: Config(), state: &state)

    #expect(state.windows[windowID]?.minimumTiledWidth == 840)
    #expect(state.windows[windowID]?.maximumTiledWidth == nil)

    state.windows[windowID]?.maximumTiledWidth = 1_000
    var heightOnly = observed
    heightOnly.minimumTiledWidth = nil
    heightOnly.maximumTiledHeight = 850
    reconcileWindows([heightOnly], config: Config(), state: &state)
    #expect(state.windows[windowID]?.minimumTiledWidth == 840)
    #expect(state.windows[windowID]?.maximumTiledWidth == 1_000)
    #expect(state.windows[windowID]?.maximumTiledHeight == 850)
  }

  @Test
  func cycleSkipsPresetWithTheSameEffectiveMinimumWidth() throws {
    let monitorID = MonitorID(rawValue: 1)
    let windowID = WindowID(rawValue: 1)
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    state.windows[windowID] = Window(
      id: windowID,
      appID: "editor",
      title: "Editor",
      frame: Rect(x: 0, y: 0, width: 560, height: 700),
      minimumTiledWidth: 560
    )
    state.monitors[0].workspaces[0].columns = [
      Column(window: windowID, width: .fraction(0.33))
    ]

    try reduce(
      .cycleWidth(.next),
      on: monitorID,
      state: &state,
      viewports: [
        monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)
      ]
    )

    #expect(
      state.monitors[0].workspaces[0].columns[0].width
        == .fraction(0.66)
    )
  }

  @Test
  func acceptedMinimumWidthReflowsFollowingColumnWithoutReplacingPreset() throws {
    let monitorID = MonitorID(rawValue: 1)
    let constrainedID = WindowID(rawValue: 1)
    let followingID = WindowID(rawValue: 2)
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    state.layout = LayoutSettings(
      innerHorizontalGap: 0,
      innerVerticalGap: 0,
      outerTopGap: 0,
      outerRightGap: 0,
      outerBottomGap: 0,
      outerLeftGap: 0
    )
    state.windows = [
      constrainedID: Window(
        id: constrainedID,
        appID: "editor",
        title: "Editor",
        frame: Rect(x: 0, y: 0, width: 800, height: 700)
      ),
      followingID: Window(
        id: followingID,
        appID: "calendar",
        title: "Calendar",
        frame: Rect(x: 800, y: 0, width: 500, height: 700)
      ),
    ]
    state.monitors[0].workspaces[0].columns = [
      Column(window: constrainedID, width: .fraction(0.33)),
      Column(window: followingID, width: .fraction(0.5)),
    ]

    #expect(
      learnTiledWindowWidthConstraint(
        constrainedID,
        actualFrame: Rect(x: 0, y: 0, width: 560, height: 700),
        state: &state,
        viewports: [
          monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)
        ]
      )
    )
    #expect(
      state.monitors[0].workspaces[0].columns[0].width
        == .fraction(0.33)
    )

    let layout = computeLayout(
      workspace: state.monitors[0].workspaces[0],
      viewport: Rect(x: 0, y: 0, width: 1_000, height: 700),
      windows: Array(state.windows.values),
      settings: state.layout
    )
    let constrained = try #require(
      layout.first { $0.windowID == constrainedID }
    )
    let following = try #require(
      layout.first { $0.windowID == followingID }
    )
    #expect(constrained.frame.width == 560)
    #expect(following.frame.x == 560)
  }

  @Test
  func learnedWidthBoundsAreTheWindowsOwnWidthBetweenGaps() throws {
    let monitorID = MonitorID(rawValue: 1)
    let narrowID = WindowID(rawValue: 1)
    let wideID = WindowID(rawValue: 2)
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    state.layout = LayoutSettings()
    state.windows = [
      narrowID: Window(id: narrowID, appID: "settings", title: "Settings",
        frame: Rect(x: 0, y: 0, width: 800, height: 700)),
      wideID: Window(id: wideID, appID: "editor", title: "Editor",
        frame: Rect(x: 800, y: 0, width: 500, height: 700)),
    ]
    state.monitors[0].workspaces[0].columns = [
      Column(window: narrowID, width: .fraction(0.8)),
      Column(window: wideID, width: .fraction(0.33)),
    ]
    let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)
    #expect(learnTiledWindowWidthConstraint(narrowID, actualFrame: Rect(x: 8, y: 8, width: 560, height: 684),
      state: &state, viewports: [monitorID: viewport]))
    #expect(learnTiledWindowWidthConstraint(wideID, actualFrame: Rect(x: 576, y: 8, width: 400, height: 684),
      state: &state, viewports: [monitorID: viewport]))
    #expect(state.windows[narrowID]?.maximumTiledWidth == 560)
    #expect(state.windows[wideID]?.minimumTiledWidth == 400)
    state.monitors[0].workspaces[0].columns.swapAt(0, 1)
    let frames = computeLayout(workspace: state.monitors[0].workspaces[0], viewport: viewport,
      windows: Array(state.windows.values), settings: state.layout)
    #expect(frames == [
      FrameAssignment(windowID: wideID, frame: Rect(x: 8, y: 8, width: 400, height: 684)),
      FrameAssignment(windowID: narrowID, frame: Rect(x: 416, y: 8, width: 560, height: 684)),
    ])
  }

  @Test
  func acceptedMaximumWidthReflowsAndSkipsEquivalentPresets() throws {
    let monitorID = MonitorID(rawValue: 1)
    let constrainedID = WindowID(rawValue: 1)
    let followingID = WindowID(rawValue: 2)
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    state.layout = LayoutSettings(
      innerHorizontalGap: 0,
      innerVerticalGap: 0,
      outerTopGap: 0,
      outerRightGap: 0,
      outerBottomGap: 0,
      outerLeftGap: 0
    )
    state.windows = [
      constrainedID: Window(
        id: constrainedID,
        appID: "settings",
        title: "Settings",
        frame: Rect(x: 0, y: 0, width: 800, height: 700)
      ),
      followingID: Window(
        id: followingID,
        appID: "editor",
        title: "Editor",
        frame: Rect(x: 800, y: 0, width: 500, height: 700)
      ),
    ]
    state.monitors[0].workspaces[0].columns = [
      Column(window: constrainedID, width: .fraction(0.8)),
      Column(window: followingID, width: .fraction(0.5)),
    ]
    let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)

    #expect(
      learnTiledWindowWidthConstraint(
        constrainedID,
        actualFrame: Rect(x: 0, y: 0, width: 560, height: 700),
        state: &state,
        viewports: [monitorID: viewport]
      )
    )

    let layout = computeLayout(
      workspace: state.monitors[0].workspaces[0],
      viewport: viewport,
      windows: Array(state.windows.values),
      settings: state.layout
    )
    let constrained = try #require(
      layout.first { $0.windowID == constrainedID }
    )
    let following = try #require(
      layout.first { $0.windowID == followingID }
    )
    #expect(constrained.frame.width == 560)
    #expect(following.frame.x == 560)

    try reduce(
      .cycleWidth(.previous),
      on: monitorID,
      state: &state,
      viewports: [monitorID: viewport]
    )
    #expect(state.monitors[0].workspaces[0].columns[0].width == .fraction(0.5))

    #expect(
      learnTiledWindowWidthConstraint(
        constrainedID,
        actualFrame: Rect(x: 0, y: 0, width: 560, height: 700),
        state: &state,
        viewports: [monitorID: viewport]
      )
    )
    try reduce(
      .cycleWidth(.next),
      on: monitorID,
      state: &state,
      viewports: [monitorID: viewport]
    )
    #expect(state.monitors[0].workspaces[0].columns[0].width == .fraction(0.5))
  }

  @Test
  func stackedWindowsKeepIndependentWidthConstraints() throws {
    let monitorID = MonitorID(rawValue: 1)
    let fixedID = WindowID(rawValue: 1)
    let wideID = WindowID(rawValue: 2)
    let followingID = WindowID(rawValue: 3)
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    state.layout = LayoutSettings(
      innerHorizontalGap: 0,
      innerVerticalGap: 0,
      outerTopGap: 0,
      outerRightGap: 0,
      outerBottomGap: 0,
      outerLeftGap: 0
    )
    state.windows = [
      fixedID: Window(
        id: fixedID,
        appID: "fixed",
        title: "Fixed",
        frame: Rect(x: 0, y: 0, width: 500, height: 350),
        maximumTiledWidth: 500
      ),
      wideID: Window(
        id: wideID,
        appID: "wide",
        title: "Wide",
        frame: Rect(x: 0, y: 350, width: 600, height: 350),
        minimumTiledWidth: 600
      ),
      followingID: Window(
        id: followingID,
        appID: "following",
        title: "Following",
        frame: Rect(x: 800, y: 0, width: 500, height: 700)
      ),
    ]
    state.monitors[0].workspaces[0].columns = [
      Column(windows: [fixedID, wideID], focusedWindow: 0, width: .fraction(0.8)),
      Column(window: followingID, width: .fraction(0.5)),
    ]
    let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)

    try reduce(
      .cycleWidth(.previous),
      on: monitorID,
      state: &state,
      viewports: [monitorID: viewport]
    )

    #expect(state.monitors[0].workspaces[0].columns[0].width == .fraction(0.66))
    let frames = computeLayout(
      workspace: state.monitors[0].workspaces[0],
      viewport: viewport,
      windows: Array(state.windows.values),
      settings: state.layout
    )
    #expect(frames.first { $0.windowID == fixedID }?.frame.width == 500)
    #expect(frames.first { $0.windowID == wideID }?.frame.width == 660)
    #expect(frames.first { $0.windowID == followingID }?.frame.x == 660)
  }
}

struct RuntimeWidthLearningTests {
  private let monitorID = MonitorID(rawValue: 1)

  @Test
  func `Mouse resize learns real column width`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "Editor",
      frame: Rect(x: 12, y: 12, width: 476, height: 676),
      monitorID: monitorID
    )
    try discoverWindow(window, decision: RuleDecision(), state: &state)
    state.monitors[0].workspaces[0].columns[0].width = .fraction(0.5)

    let learned = learnTiledWindowWidth(
      window.id,
      actualFrame: Rect(x: 12, y: 12, width: 576, height: 676),
      state: &state,
      viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
    )

    #expect(learned)
    #expect(state.monitors[0].workspaces[0].columns[0].width == .pixels(592))
  }

  @Test
  func `Mouse resize does not overwrite intrinsic width`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "simulator",
      title: "Phone",
      frame: Rect(x: 8, y: 8, width: 304, height: 684),
      monitorID: monitorID
    )
    try discoverWindow(
      window,
      decision: RuleDecision(intrinsicSize: true),
      state: &state
    )

    #expect(
      learnTiledWindowWidth(
        window.id,
        actualFrame: Rect(x: 8, y: 8, width: 404, height: 684),
        state: &state,
        viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
      ) == false)
  }

  @Test
  func `Maximized width cannot be learned from AX drift`() throws {
    let config = Config()
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "Editor",
      frame: Rect(x: 8, y: 8, width: 784, height: 684),
      monitorID: monitorID
    )
    try discoverWindow(window, decision: RuleDecision(), state: &state)
    try reduce(.maximizeColumn, on: monitorID, state: &state)

    #expect(
      learnTiledWindowWidth(
        window.id,
        actualFrame: Rect(x: 8, y: 8, width: 784, height: 684),
        state: &state,
        viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
      ) == false)
    #expect(state.monitors[0].workspaces[0].columns[0].width == .fraction(1))
    #expect(state.monitors[0].workspaces[0].columns[0].preMaximizedWidth == .fraction(0.8))
  }

  private let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)

  private func singleWindowState(
    minimum: Double? = nil,
    maximum: Double? = nil,
    width: ColumnWidth = .fraction(0.5)
  ) throws -> (RuntimeState, WindowID) {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "editor",
      title: "Editor",
      frame: Rect(x: 12, y: 12, width: 476, height: 676),
      monitorID: monitorID
    )
    try discoverWindow(window, decision: RuleDecision(), state: &state)
    state.windows[window.id]?.minimumTiledWidth = minimum
    state.windows[window.id]?.maximumTiledWidth = maximum
    state.monitors[0].workspaces[0].columns[0].width = width
    return (state, window.id)
  }

  private func targets(_ state: RuntimeState) -> [WindowID: Rect] {
    Dictionary(uniqueKeysWithValues: computeLayout(
      workspace: state.monitors[0].workspaces[0],
      viewport: viewport,
      windows: Array(state.windows.values),
      settings: state.layout
    ).map { ($0.windowID, $0.frame) })
  }

  @Test
  func `Mouse resize keeps bounds the observed frame does not contradict`() throws {
    var (state, id) = try singleWindowState(minimum: 300, maximum: 900)

    #expect(learnTiledWindowWidth(
      id,
      actualFrame: Rect(x: 12, y: 12, width: 576, height: 676),
      state: &state,
      viewports: [monitorID: viewport]
    ))

    #expect(state.monitors[0].workspaces[0].columns[0].width == .pixels(592))
    #expect(state.windows[id]?.minimumTiledWidth == 300)
    #expect(state.windows[id]?.maximumTiledWidth == 900)
    #expect(targets(state)[id]?.width == 576)
  }

  @Test
  func `Mouse resize below a minimum drops only the minimum`() throws {
    var (state, id) = try singleWindowState(minimum: 550, maximum: 900)

    #expect(learnTiledWindowWidth(
      id,
      actualFrame: Rect(x: 12, y: 12, width: 476, height: 676),
      state: &state,
      viewports: [monitorID: viewport]
    ))

    #expect(state.monitors[0].workspaces[0].columns[0].width == .pixels(492))
    #expect(state.windows[id]?.minimumTiledWidth == nil)
    #expect(state.windows[id]?.maximumTiledWidth == 900)
    #expect(targets(state)[id]?.width == 476)
  }

  @Test
  func `Mouse resize above a maximum drops only the maximum`() throws {
    var (state, id) = try singleWindowState(minimum: 300, maximum: 550, width: .fraction(0.8))

    #expect(learnTiledWindowWidth(
      id,
      actualFrame: Rect(x: 12, y: 12, width: 676, height: 676),
      state: &state,
      viewports: [monitorID: viewport]
    ))

    #expect(state.monitors[0].workspaces[0].columns[0].width == .pixels(692))
    #expect(state.windows[id]?.minimumTiledWidth == 300)
    #expect(state.windows[id]?.maximumTiledWidth == nil)
    #expect(targets(state)[id]?.width == 676)
  }

  @Test
  func `Mouse resize clamped by the app minimum learns that minimum and keeps it`() throws {
    var (state, id) = try singleWindowState(minimum: 376)

    #expect(learnTiledWindowWidth(
      id,
      actualFrame: Rect(x: 12, y: 12, width: 376, height: 676),
      state: &state,
      viewports: [monitorID: viewport]
    ))

    #expect(state.monitors[0].workspaces[0].columns[0].width == .pixels(392))
    #expect(state.windows[id]?.minimumTiledWidth == 376)
    #expect(targets(state)[id]?.width == 376)
  }

  @Test
  func `Frame already at its bounded target is not learned as a user width`() throws {
    var (state, id) = try singleWindowState(minimum: 576)

    #expect(!learnTiledWindowWidth(
      id,
      actualFrame: Rect(x: 12, y: 12, width: 576, height: 676),
      state: &state,
      viewports: [monitorID: viewport]
    ))

    #expect(state.monitors[0].workspaces[0].columns[0].width == .fraction(0.5))
    #expect(state.windows[id]?.minimumTiledWidth == 576)
  }

  @Test
  func `Height only resize learns nothing and keeps automatic heights`() throws {
    var (state, id) = try singleWindowState(minimum: 300)

    #expect(!learnTiledWindowWidth(
      id,
      actualFrame: Rect(x: 12, y: 12, width: 480, height: 400),
      state: &state,
      viewports: [monitorID: viewport]
    ))

    #expect(state.monitors[0].workspaces[0].columns[0].width == .fraction(0.5))
    #expect(state.windows[id]?.minimumTiledWidth == 300)
    #expect(state.windows[id]?.maximumTiledWidth == nil)
    #expect(targets(state)[id] == Rect(x: 12, y: 12, width: 480, height: 676))
  }

  @Test
  func `Dragged left edge keeps the window where it was released`() throws {
    var (state, _) = try singleWindowState()
    let sibling = Window(
      id: WindowID(rawValue: 2),
      appID: "terminal",
      title: "Terminal",
      frame: Rect(x: 512, y: 12, width: 476, height: 676),
      monitorID: monitorID
    )
    try discoverWindow(sibling, decision: RuleDecision(), state: &state)
    state.monitors[0].workspaces[0].focusedColumn = 1
    let before = try #require(targets(state)[sibling.id])

    #expect(learnTiledWindowWidth(
      sibling.id,
      actualFrame: Rect(x: before.x - 100, y: before.y, width: before.width + 100, height: before.height),
      state: &state,
      viewports: [monitorID: viewport]
    ))

    let after = try #require(targets(state)[sibling.id])
    #expect(after.x == before.x - 100)
    #expect(after.width == before.width + 100)
  }

  @Test
  func `Stacked column applies the learned width to siblings within their bounds`() throws {
    var (state, id) = try singleWindowState()
    let sibling = Window(
      id: WindowID(rawValue: 2),
      appID: "terminal",
      title: "Terminal",
      frame: Rect(x: 512, y: 12, width: 476, height: 676),
      monitorID: monitorID
    )
    try discoverWindow(sibling, decision: RuleDecision(), state: &state)
    state.monitors[0].workspaces[0].columns.removeLast()
    state.monitors[0].workspaces[0].columns[0].windows.append(sibling.id)
    state.windows[sibling.id]?.maximumTiledWidth = 426

    #expect(learnTiledWindowWidth(
      id,
      actualFrame: Rect(x: 12, y: 12, width: 576, height: 332),
      state: &state,
      viewports: [monitorID: viewport]
    ))

    #expect(state.monitors[0].workspaces[0].columns[0].width == .pixels(592))
    #expect(state.windows[sibling.id]?.maximumTiledWidth == 426)
    let frames = targets(state)
    #expect(frames[id]?.width == 576)
    #expect(frames[sibling.id]?.width == 426)

    state.windows[sibling.id]?.maximumTiledWidth = nil
    state.windows[sibling.id]?.minimumTiledWidth = 676
    #expect(learnTiledWindowWidth(
      id,
      actualFrame: Rect(x: 12, y: 12, width: 476, height: 332),
      state: &state,
      viewports: [monitorID: viewport]
    ))
    #expect(state.monitors[0].workspaces[0].columns[0].width == .pixels(492))
    #expect(targets(state)[id]?.width == 676)
  }

  @Test
  func `Mouse resize forgets the settled snap`() throws {
    var (state, id) = try singleWindowState()
    state.windows[id]?.tiledSizeAcceptance = TiledSizeAcceptance(
      requested: Rect(x: 12, y: 12, width: 576, height: 676),
      accepted: Rect(x: 12, y: 12, width: 572, height: 676))

    #expect(learnTiledWindowWidth(
      id,
      actualFrame: Rect(x: 12, y: 12, width: 576, height: 676),
      state: &state,
      viewports: [monitorID: viewport]
    ))

    #expect(state.windows[id]?.tiledSizeAcceptance == nil)
    #expect(state.monitors[0].workspaces[0].columns[0].width == .pixels(592))
    #expect(targets(state)[id]?.width == 576)
  }

  @Test
  func `Stacked window resized past its maximum to the column width drops the maximum`() throws {
    var (state, id) = try singleWindowState()
    let sibling = Window(
      id: WindowID(rawValue: 2),
      appID: "terminal",
      title: "Terminal",
      frame: Rect(x: 512, y: 12, width: 476, height: 676),
      monitorID: monitorID
    )
    try discoverWindow(sibling, decision: RuleDecision(), state: &state)
    state.monitors[0].workspaces[0].columns.removeLast()
    state.monitors[0].workspaces[0].columns[0].windows.append(sibling.id)
    state.windows[id]?.maximumTiledWidth = 426
    #expect(targets(state)[id]?.width == 426)

    // The column already has this width, so only the contradicted bound changes.
    #expect(!learnTiledWindowWidth(
      id,
      actualFrame: Rect(x: 12, y: 12, width: 480, height: 332),
      state: &state,
      viewports: [monitorID: viewport]
    ))

    #expect(state.windows[id]?.maximumTiledWidth == nil)
    #expect(targets(state)[id]?.width == 480)
  }
}
