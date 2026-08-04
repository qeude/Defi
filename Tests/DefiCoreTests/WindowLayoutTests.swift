import DefiCore
import DefiModel
import XCTest

final class WindowLayoutTests: XCTestCase {
  private let settings = LayoutSettings()

  func testIntrinsicSizeWindowStaysCenteredInTile() {
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    insertNewWindow(
      WindowID(rawValue: 1),
      width: .pixels(500),
      into: &workspace,
      settings: settings
    )
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "Simulator",
      title: "iPhone",
      frame: Rect(x: 0, y: 0, width: 320, height: 640),
      intrinsicSize: true
    )

    let diff = computeLayout(
      workspace: workspace,
      viewport: Rect(x: 0, y: 0, width: 1_000, height: 800),
      windows: [window],
      settings: settings
    )

    XCTAssertEqual(
      diff.frames[0],
      FrameAssignment(
        windowID: WindowID(rawValue: 1),
        frame: Rect(x: 8, y: 88, width: 304, height: 624)
      )
    )
  }

  func testFrameBatchSkipsUnchangedAssignments() {
    let first = FrameAssignment(
      windowID: WindowID(rawValue: 1),
      frame: Rect(x: 0, y: 0, width: 500, height: 800)
    )
    let second = FrameAssignment(
      windowID: WindowID(rawValue: 2),
      frame: Rect(x: 500, y: 0, width: 500, height: 800)
    )
    let moved = FrameAssignment(
      windowID: WindowID(rawValue: 2),
      frame: Rect(x: 600, y: 0, width: 500, height: 800)
    )

    let batch = planFrameBatch(previous: [first, second], next: [first, moved])

    XCTAssertEqual(batch.frames, [moved])
    XCTAssertEqual(batch.stats.plannedWrites, 1)
    XCTAssertEqual(batch.stats.skippedUnchanged, 1)
  }

  func testEachViewportProducesItsOwnMonitorSizedLayout() {
    let noGaps = LayoutSettings(
      defaultColumnWidth: 0.8,
      innerHorizontalGap: 0,
      innerVerticalGap: 0,
      outerTopGap: 0,
      outerRightGap: 0,
      outerBottomGap: 0,
      outerLeftGap: 0
    )
    let workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [Column(window: WindowID(rawValue: 1), width: .fraction(0.8))]
    )

    let laptop = computeLayout(
      workspace: workspace,
      viewport: Rect(x: 0, y: 0, width: 1_500, height: 900),
      settings: noGaps
    ).frames[0].frame
    let external = computeLayout(
      workspace: workspace,
      viewport: Rect(x: 1_500, y: 30, width: 2_560, height: 1_362),
      settings: noGaps
    ).frames[0].frame

    XCTAssertEqual(laptop, Rect(x: 0, y: 0, width: 1_200, height: 900))
    XCTAssertEqual(
      external,
      Rect(x: 1_500, y: 30, width: 2_048, height: 1_362)
    )
  }

}
