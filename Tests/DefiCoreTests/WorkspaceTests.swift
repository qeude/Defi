import DefiCore
import DefiModel
import Testing

struct WorkspaceTests {
  private let settings = LayoutSettings()

  @Test
  func `New window inserts after focused column`() {
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    insertNewWindow(WindowID(rawValue: 1), into: &workspace, settings: settings)
    insertNewWindow(WindowID(rawValue: 2), into: &workspace, settings: settings)
    workspace.focusedColumn = 0
    insertNewWindow(WindowID(rawValue: 3), into: &workspace, settings: settings)

    #expect(
      workspace.columns.map(\.windows[0]) == [
        WindowID(rawValue: 1), WindowID(rawValue: 3), WindowID(rawValue: 2),
      ])
    #expect(workspace.focusedColumn == 1)
  }

  @Test
  func `Move focused window swaps columns`() throws {
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    insertNewWindow(WindowID(rawValue: 1), into: &workspace, settings: settings)
    insertNewWindow(WindowID(rawValue: 2), into: &workspace, settings: settings)

    try moveFocusedWindow(.left, in: &workspace, settings: settings)

    #expect(workspace.columns.map(\.windows[0]) == [WindowID(rawValue: 2), WindowID(rawValue: 1)])
    #expect(workspace.focusedColumn == 0)
  }

  @Test
  func `Removing last window repairs focus`() {
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    insertNewWindow(WindowID(rawValue: 1), into: &workspace, settings: settings)
    insertNewWindow(WindowID(rawValue: 2), into: &workspace, settings: settings)

    #expect(removeWindow(WindowID(rawValue: 2), from: &workspace, settings: settings))
    #expect(workspace.columns.count == 1)
    #expect(workspace.focusedColumn == 0)
  }

  @Test
  func `Join and unjoin round trip`() throws {
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    insertNewWindow(WindowID(rawValue: 1), into: &workspace, settings: settings)
    insertNewWindow(WindowID(rawValue: 2), into: &workspace, settings: settings)

    try joinFocusedWindow(.left, in: &workspace, settings: settings)
    #expect(workspace.columns.count == 1)
    #expect(workspace.columns[0].windows == [WindowID(rawValue: 1), WindowID(rawValue: 2)])
    #expect(workspace.columns[0].focusedWindow == 1)

    try unjoinFocusedWindow(in: &workspace, settings: settings)
    #expect(workspace.columns.count == 2)
    #expect(workspace.columns[1].windows == [WindowID(rawValue: 2)])
    #expect(workspace.focusedColumn == 1)
  }

  @Test
  func `Maximized column restores pixel width`() {
    var column = Column(window: WindowID(rawValue: 1), width: .pixels(420))

    maximizeColumn(&column, defaultWidth: 0.8)
    #expect(column.width == .fraction(1))
    #expect(column.preMaximizedWidth == .pixels(420))

    maximizeColumn(&column, defaultWidth: 0.8)
    #expect(column.width == .pixels(420))
    #expect(column.preMaximizedWidth == nil)
  }

  @Test(arguments: [
    (
      Direction.next,
      [1.0, 0.33, 0.5, 0.66, 0.8],
      ColumnWidth.fraction(0.33),
      nil
    ),
    (
      Direction.previous,
      [0.33, 0.5, 0.66, 0.8, 1.0],
      ColumnWidth.fraction(0.8),
      nil
    ),
    (
      Direction.previous,
      [1.0],
      ColumnWidth.fraction(1),
      ColumnWidth.fraction(0.5)
    ),
  ])
  func `Cycling from maximized selects the expected preset`(
    testCase: (
      direction: Direction,
      presets: [Double],
      expectedWidth: ColumnWidth,
      expectedPreviousWidth: ColumnWidth?
    )
  ) {
    var column = Column(window: WindowID(rawValue: 1), width: .fraction(0.5))

    maximizeColumn(&column, defaultWidth: 0.8)
    cycleWidth(
      of: &column,
      direction: testCase.direction,
      presets: testCase.presets
    )

    #expect(column.width == testCase.expectedWidth)
    #expect(column.preMaximizedWidth == testCase.expectedPreviousWidth)
  }
}
