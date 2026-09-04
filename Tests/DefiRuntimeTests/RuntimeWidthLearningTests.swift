import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing

struct RuntimeWidthConstraintTests {
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
      layout.frames.first { $0.windowID == constrainedID }
    )
    let following = try #require(
      layout.frames.first { $0.windowID == followingID }
    )
    #expect(constrained.frame.width == 560)
    #expect(following.frame.x == 560)
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
      layout.frames.first { $0.windowID == constrainedID }
    )
    let following = try #require(
      layout.frames.first { $0.windowID == followingID }
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
    ).frames
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
      frame: Rect(x: 8, y: 8, width: 484, height: 684),
      monitorID: monitorID
    )
    try discoverWindow(window, decision: RuleDecision(), state: &state)
    state.monitors[0].workspaces[0].columns[0].width = .fraction(0.5)

    let learned = learnTiledWindowWidth(
      window.id,
      actualFrame: Rect(x: 8, y: 8, width: 584, height: 684),
      state: &state,
      viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
    )

    #expect(learned)
    #expect(state.monitors[0].workspaces[0].columns[0].width == .pixels(600))
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

}
