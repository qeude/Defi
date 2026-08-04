import DefiConfig
import DefiModel
import DefiRuntime
import XCTest

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

  func testFullscreenWidthCannotBeLearnedFromAXDrift() throws {
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
    try reduce(.toggleFullscreen, on: monitorID, state: &state)

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
      state.monitors[0].workspaces[0].columns[0].fullscreenPreviousWidth,
      .fraction(0.8)
    )
  }

}
