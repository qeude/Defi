import DefiCore
import DefiModel
import XCTest

final class WorkspaceTests: XCTestCase {
  private let settings = LayoutSettings()

  func testNewWindowInsertsAfterFocusedColumn() {
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    insertNewWindow(WindowID(rawValue: 1), into: &workspace, settings: settings)
    insertNewWindow(WindowID(rawValue: 2), into: &workspace, settings: settings)
    workspace.focusedColumn = 0
    insertNewWindow(WindowID(rawValue: 3), into: &workspace, settings: settings)

    XCTAssertEqual(
      workspace.columns.map(\.windows[0]),
      [WindowID(rawValue: 1), WindowID(rawValue: 3), WindowID(rawValue: 2)]
    )
    XCTAssertEqual(workspace.focusedColumn, 1)
  }

  func testMoveFocusedWindowSwapsColumns() throws {
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    insertNewWindow(WindowID(rawValue: 1), into: &workspace, settings: settings)
    insertNewWindow(WindowID(rawValue: 2), into: &workspace, settings: settings)

    try moveFocusedWindow(.left, in: &workspace, settings: settings)

    XCTAssertEqual(
      workspace.columns.map(\.windows[0]),
      [WindowID(rawValue: 2), WindowID(rawValue: 1)]
    )
    XCTAssertEqual(workspace.focusedColumn, 0)
  }

  func testRemovingLastWindowRepairsFocus() {
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    insertNewWindow(WindowID(rawValue: 1), into: &workspace, settings: settings)
    insertNewWindow(WindowID(rawValue: 2), into: &workspace, settings: settings)

    XCTAssertTrue(
      removeWindow(WindowID(rawValue: 2), from: &workspace, settings: settings)
    )
    XCTAssertEqual(workspace.columns.count, 1)
    XCTAssertEqual(workspace.focusedColumn, 0)
  }

  func testJoinAndUnjoinRoundTrip() throws {
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    insertNewWindow(WindowID(rawValue: 1), into: &workspace, settings: settings)
    insertNewWindow(WindowID(rawValue: 2), into: &workspace, settings: settings)

    try joinFocusedWindow(.left, in: &workspace, settings: settings)
    XCTAssertEqual(workspace.columns.count, 1)
    XCTAssertEqual(
      workspace.columns[0].windows,
      [WindowID(rawValue: 1), WindowID(rawValue: 2)]
    )
    XCTAssertEqual(workspace.columns[0].focusedWindow, 1)

    try unjoinFocusedWindow(in: &workspace, settings: settings)
    XCTAssertEqual(workspace.columns.count, 2)
    XCTAssertEqual(workspace.columns[1].windows, [WindowID(rawValue: 2)])
    XCTAssertEqual(workspace.focusedColumn, 1)
  }

  func testMaximizedColumnRestoresPixelWidth() {
    var column = Column(window: WindowID(rawValue: 1), width: .pixels(420))

    maximizeColumn(&column, defaultWidth: 0.8)
    XCTAssertEqual(column.width, .fraction(1))
    XCTAssertEqual(column.preMaximizedWidth, .pixels(420))

    maximizeColumn(&column, defaultWidth: 0.8)
    XCTAssertEqual(column.width, .pixels(420))
    XCTAssertNil(column.preMaximizedWidth)
  }

  func testCyclingForwardFromMaximizedUsesFirstPreset() {
    var column = Column(window: WindowID(rawValue: 1), width: .fraction(0.5))
    let presets = [1.0, 0.33, 0.5, 0.66, 0.8]

    maximizeColumn(&column, defaultWidth: 0.8)
    cycleWidth(of: &column, direction: .next, presets: presets)

    XCTAssertEqual(column.width, .fraction(0.33))
    XCTAssertNil(column.preMaximizedWidth)
  }

  func testCyclingBackwardFromMaximizedUsesLastPreset() {
    var column = Column(window: WindowID(rawValue: 1), width: .fraction(0.5))
    let presets = [0.33, 0.5, 0.66, 0.8, 1.0]

    maximizeColumn(&column, defaultWidth: 0.8)
    cycleWidth(of: &column, direction: .previous, presets: presets)

    XCTAssertEqual(column.width, .fraction(0.8))
    XCTAssertNil(column.preMaximizedWidth)
  }

  func testCyclingFromMaximizedWithOnlyFullWidthPresetDoesNothing() {
    var column = Column(window: WindowID(rawValue: 1), width: .fraction(0.5))

    maximizeColumn(&column, defaultWidth: 0.8)
    cycleWidth(of: &column, direction: .previous, presets: [1.0])

    XCTAssertEqual(column.width, .fraction(1))
    XCTAssertEqual(column.preMaximizedWidth, .fraction(0.5))
  }

}
