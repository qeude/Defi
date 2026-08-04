import DefiCore
import DefiModel
import XCTest

final class WorkspaceScrollingTests: XCTestCase {
  private let settings = LayoutSettings()

  func testFocusScrollsOnlyEnoughForOverflow() throws {
    let compact = LayoutSettings(defaultColumnWidth: 0.72)
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    insertNewWindow(WindowID(rawValue: 1), into: &workspace, settings: compact)
    insertNewWindow(WindowID(rawValue: 2), into: &workspace, settings: compact)

    try focusColumn(.right, in: &workspace, settings: compact)
    workspace.scrollOffset = workspace.targetScrollOffset
    let diff = computeLayout(
      workspace: workspace,
      viewport: Rect(x: 0, y: 0, width: 1_440, height: 900),
      settings: compact
    )

    XCTAssertEqual(workspace.targetScrollOffset, 0.44, accuracy: 0.001)
    XCTAssertEqual(diff.frames[1].frame.x, 407.2, accuracy: 0.001)
  }

  func testNeverCenteringPreservesVisibleColumn() {
    let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)
    let columns = (1...4).map {
      Column(window: WindowID(rawValue: UInt64($0)), width: .fraction(0.5))
    }

    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: columns,
      focusedColumn: 1
    )
    XCTAssertEqual(
      focusedColumnScrollOffset(workspace: workspace, viewport: viewport),
      0,
      accuracy: 0.001
    )

    workspace.focusedColumn = 2
    XCTAssertEqual(
      focusedColumnScrollOffset(workspace: workspace, viewport: viewport),
      0.5,
      accuracy: 0.001
    )

    workspace.focusedColumn = 3
    workspace.scrollOffset = 0.5
    XCTAssertEqual(
      focusedColumnScrollOffset(workspace: workspace, viewport: viewport),
      1,
      accuracy: 0.001
    )
  }

  func testAlwaysCenteringCentersTarget() throws {
    let centered = LayoutSettings(
      defaultColumnWidth: 0.5,
      centerFocusedColumn: .always,
      innerHorizontalGap: 0,
      innerVerticalGap: 0,
      outerTopGap: 0,
      outerRightGap: 0,
      outerBottomGap: 0,
      outerLeftGap: 0
    )
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    insertNewWindow(WindowID(rawValue: 1), into: &workspace, settings: centered)
    insertNewWindow(WindowID(rawValue: 2), into: &workspace, settings: centered)
    insertNewWindow(WindowID(rawValue: 3), into: &workspace, settings: centered)
    workspace.focusedColumn = 0

    try focusColumn(.right, in: &workspace, settings: centered)
    workspace.scrollOffset = workspace.targetScrollOffset
    let diff = computeLayout(
      workspace: workspace,
      viewport: Rect(x: 0, y: 0, width: 1_000, height: 900),
      settings: centered
    )

    XCTAssertEqual(workspace.targetScrollOffset, 0.25, accuracy: 0.001)
    XCTAssertEqual(diff.frames[1].frame.x, 250, accuracy: 0.001)
  }

}
