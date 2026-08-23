import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing
import XCTest

struct RuntimeMinimumWidthTests {
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
      learnTiledWindowMinimumWidth(
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
}

final class RuntimeWidthLearningTests: XCTestCase {
  private let monitorID = MonitorID(rawValue: 1)

  func testMouseResizeLearnsRealColumnWidth() throws {
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

    XCTAssertTrue(learned)
    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns[0].width,
      .pixels(600)
    )
  }

  func testMouseResizeDoesNotOverwriteIntrinsicWidth() throws {
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

    XCTAssertFalse(
      learnTiledWindowWidth(
        window.id,
        actualFrame: Rect(x: 8, y: 8, width: 404, height: 684),
        state: &state,
        viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
      )
    )
  }

  func testMaximizedWidthCannotBeLearnedFromAXDrift() throws {
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

    XCTAssertFalse(
      learnTiledWindowWidth(
        window.id,
        actualFrame: Rect(x: 8, y: 8, width: 784, height: 684),
        state: &state,
        viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
      )
    )
    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns[0].width,
      .fraction(1)
    )
    XCTAssertEqual(
      state.monitors[0].workspaces[0].columns[0].preMaximizedWidth,
      .fraction(0.8)
    )
  }

}
