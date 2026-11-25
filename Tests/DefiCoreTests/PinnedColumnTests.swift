import DefiCore
import DefiModel
import Testing

struct PinnedColumnTests {
  private let settings = LayoutSettings()
  private let viewport = Rect(x: 0, y: 0, width: 1_000, height: 800)

  private func column(_ raw: UInt64, _ width: Double, pin: ColumnPin? = nil) -> Column {
    var column = Column(window: WindowID(rawValue: raw), width: .fraction(width))
    column.pin = pin
    return column
  }

  private func frames(_ workspace: Workspace) -> [UInt64: Rect] {
    Dictionary(uniqueKeysWithValues: computeLayout(
      workspace: workspace, viewport: viewport, settings: settings
    ).map { ($0.windowID.rawValue, $0.frame) })
  }

  @Test
  func `Pinning moves the other columns without resizing them`() {
    let columns = [column(2, 0.5), column(3, 0.3), column(4, 1)]
    let unpinned = frames(Workspace(id: WorkspaceID(rawValue: "1"), columns: columns))
    let pinned = frames(Workspace(
      id: WorkspaceID(rawValue: "1"), columns: [column(1, 0.25, pin: .left)] + columns))
    #expect(pinned[1] == Rect(x: 8, y: 8, width: 240, height: 784))
    #expect(pinned[2]!.width == unpinned[2]!.width)
    #expect(pinned[3]!.width == unpinned[3]!.width)
    #expect(pinned[2]!.x == 256)
    // A full-width column fills the room the pinned column leaves.
    #expect(pinned[4]!.width == 992 - 248 - 8)
  }

  @Test(arguments: [ColumnPin.left, .right])
  func `A pinned column stays at its edge while the strip scrolls`(edge: ColumnPin) {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [column(2, 0.5), column(3, 0.5), column(4, 0.5)])
    insertPinnedColumn(column(1, 0.25, pin: edge), into: &workspace, settings: settings)
    workspace.scrollOffset = 0
    let still = frames(workspace)
    // One column's width, in scrolling strip widths.
    workspace.scrollOffset = (still[3]!.x - still[2]!.x)
      / scrollingStripWidth(workspace.columns, viewport: viewport, settings: settings)
    let scrolled = frames(workspace)
    #expect(scrolled[1] == still[1])
    #expect(edge == .left ? still[1]!.x == 8 : still[1]!.x + still[1]!.width == 992)
    #expect(abs(scrolled[3]!.x - still[2]!.x) < 0.001)
  }

  @Test(arguments: [ColumnPin.left, .right])
  func `No strip column ever rests across the pinned column's edge`(edge: ColumnPin) throws {
    for center in [CenterFocusedColumn.never, .onOverflow, .always] {
      var settings = settings
      settings.centerFocusedColumn = center
      var workspace = Workspace(
        id: WorkspaceID(rawValue: "1"),
        columns: [column(2, 0.4), column(3, 0.7), column(4, 0.4), column(5, 0.6), column(6, 0.3)])
      insertPinnedColumn(column(1, 0.3, pin: edge), into: &workspace, settings: settings)
      for direction in [Direction.right, .right, .right, .right, .left, .left, .left, .first, .last] {
        try focusColumn(direction, in: &workspace, settings: settings)
        repairWorkspaceScroll(&workspace, settings: settings)
        workspace.scrollOffset = workspace.targetScrollOffset
        let all = frames(workspace)
        let pinned = all[1]!
        let inner = edge == .left ? pinned.x + pinned.width : pinned.x
        for (id, frame) in all where id != 1 {
          #expect(!(frame.x < inner - 1 && frame.x + frame.width > inner + 1),
            "column \(id) straddles the pinned edge (\(center), \(direction))")
        }
        let focused = all[workspace.columns[workspace.focusedColumn].windows[0].rawValue]!
        #expect(focused.x >= 0 && focused.x + focused.width <= 1_000)
      }
    }
  }

  @Test(arguments: [ColumnPin.left, .right])
  func `A swipe never rests with a strip column across the pinned column's edge`(edge: ColumnPin) throws {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [column(2, 0.4), column(3, 0.7), column(4, 0.4), column(5, 0.6), column(6, 0.3)],
      focusedColumn: 2)
    insertPinnedColumn(column(1, 0.3, pin: edge), into: &workspace, settings: settings)
    let rest = workspace.targetScrollOffset
    for projected in stride(from: -0.6, through: 2.4, by: 0.05) {
      let snapped = scrollGestureSnap(
        workspace: workspace, viewport: viewport, settings: settings, rest: rest, current: rest,
        projected: projected)
      let free = scrollGestureFreeRest(
        workspace: workspace, viewport: viewport, settings: settings, current: rest,
        projected: projected)
      for landing in [snapped, free].compactMap({ $0 }) {
        var landed = workspace
        landed.focusedColumn = landing.column
        landed.scrollOffset = landing.offset
        let all = frames(landed)
        let pinned = all[1]!
        let inner = edge == .left ? pinned.x + pinned.width : pinned.x
        for (id, frame) in all where id != 1 {
          #expect(!(frame.x < inner - 1 && frame.x + frame.width > inner + 1),
            "column \(id) straddles the pinned edge after a swipe to \(projected)")
        }
      }
    }
  }

  @Test
  func `Without a pinned column the scrolling viewport is the screen`() {
    #expect(
      scrollingViewport([column(1, 0.5), column(2, 0.5)], viewport: viewport, settings: settings)
        == viewport)
  }

  @Test
  func `Widening a pinned column keeps the scrolling columns' width while they fit`() {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"), columns: [column(1, 0.25, pin: .left), column(2, 0.4)])
    let width = frames(workspace)[2]!.width
    workspace.columns[0].width = .fraction(0.5)
    #expect(frames(workspace)[2]!.width == width)
    workspace.columns[1].width = .fraction(0.8)
    #expect(frames(workspace)[2]!.width == 992 - 496 - 8)
  }

  @Test
  func `Selecting a pinned column leaves the strip where it is`() throws {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [column(1, 0.25, pin: .left), column(2, 0.6), column(3, 0.6), column(4, 0.6)],
      focusedColumn: 3)
    repairWorkspaceScroll(&workspace, settings: settings)
    let offset = workspace.targetScrollOffset
    #expect(offset > 0)
    workspace.focusedColumn = 0
    repairWorkspaceScroll(&workspace, settings: settings)
    #expect(workspace.targetScrollOffset == offset)
  }

  @Test
  func `Leaving a pinned column focuses the strip column next to it on screen`() throws {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [column(1, 0.25, pin: .left), column(2, 0.6), column(3, 0.6), column(4, 0.6)],
      focusedColumn: 3)
    repairWorkspaceScroll(&workspace, settings: settings)
    workspace.scrollOffset = workspace.targetScrollOffset
    try focusColumn(.first, in: &workspace, settings: settings)
    #expect(workspace.focusedColumn == 0)
    try focusColumn(.right, in: &workspace, settings: settings)
    #expect(workspace.focusedColumn == 3)
    // From the strip's own end, focus reaches the pinned column.
    workspace.focusedColumn = 1
    try focusColumn(.left, in: &workspace, settings: settings)
    #expect(workspace.focusedColumn == 0)
  }

  @Test
  func `Pinning and unpinning keep the strip in view`() throws {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [column(1, 0.5), column(2, 0.5), column(3, 0.5), column(4, 0.5)],
      focusedColumn: 2)
    workspace.scrollOffset = 1
    workspace.targetScrollOffset = 1
    try togglePinnedColumn(.left, in: &workspace, settings: settings)
    #expect(workspace.columns.map(\.windows[0].rawValue) == [3, 1, 2, 4])
    #expect(workspace.columns.map(\.pin) == [.left, nil, nil, nil])
    #expect(workspace.focusedColumn == 0)
    // Column 4 was the next one on screen and stays in view at the strip's end.
    #expect(workspace.scrollOffset == workspace.targetScrollOffset)
    #expect(frames(workspace)[4].map { $0.x + $0.width } == 992)

    // Unpinned, the column returns at the left of the view, here where it was.
    try togglePinnedColumn(.left, in: &workspace, settings: settings)
    #expect(workspace.columns.map(\.windows[0].rawValue) == [1, 2, 3, 4])
    #expect(workspace.columns.allSatisfy { $0.pin == nil })
    #expect(workspace.focusedColumn == 2)
    #expect(frames(workspace)[3]?.x == 8)
  }

  @Test(arguments: [ColumnPin.left, .right])
  func `Pinning another column returns the pinned one to the strip`(edge: ColumnPin) throws {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [column(1, 0.25, pin: .left), column(2, 0.5), column(3, 0.5)],
      focusedColumn: 2)
    try togglePinnedColumn(edge, in: &workspace, settings: settings)
    #expect(workspace.columns.filter { $0.pin != nil }.map(\.windows[0].rawValue) == [3])
    #expect(workspace.columns.map(\.windows[0].rawValue).contains(1))
    #expect(workspace.columns.filter { $0.pin != nil }.count == 1)
  }

  @Test
  func `Moving refuses the pinned column and keeps strip columns beside it`() throws {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [column(1, 0.25, pin: .left), column(2, 0.5), column(3, 0.5)])
    let before = workspace.columns
    try moveFocusedWindow(.right, in: &workspace, settings: settings)
    #expect(workspace.columns == before)
    workspace.focusedColumn = 1
    try moveFocusedWindow(.left, in: &workspace, settings: settings)
    #expect(workspace.columns == before)
    try moveFocusedWindow(.last, in: &workspace, settings: settings)
    #expect(workspace.columns.map(\.windows[0].rawValue) == [1, 3, 2])
    #expect(workspace.focusedColumn == 2)
  }

  @Test(arguments: [true, false])
  func `A new window joins the strip before the right pinned column`(focuses: Bool) {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [column(1, 0.5), column(2, 0.25, pin: .right)], focusedColumn: 1)
    insertNewWindow(WindowID(rawValue: 3), into: &workspace, settings: settings, focusInsertedWindow: focuses)
    #expect(workspace.columns.map(\.windows[0].rawValue) == [1, 3, 2])
    // Opened without focus, the selection stays on the pinned column.
    #expect(workspace.focusedColumn == (focuses ? 1 : 2))
  }

  @Test
  func `A pinned window wider than half the screen keeps its minimum and the strip starts beside it`() {
    let workspace = Workspace(
      id: WorkspaceID(rawValue: "1"), columns: [column(1, 0.5, pin: .left), column(2, 0.3)])
    let windows = [
      Window(id: WindowID(rawValue: 1), appID: "a", title: "", frame: viewport, minimumTiledWidth: 700),
      Window(id: WindowID(rawValue: 2), appID: "b", title: "", frame: viewport),
    ]
    let frames = Dictionary(uniqueKeysWithValues: computeLayout(
      workspace: workspace, viewport: viewport, windows: windows, settings: settings
    ).map { ($0.windowID.rawValue, $0.frame) })
    #expect(frames[1]!.width >= 700)
    #expect(frames[2]!.x >= frames[1]!.x + frames[1]!.width)
  }

  @Test
  func `Normalizing keeps the first pin only and moves it to its end`() {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [column(1, 0.5), column(2, 0.25, pin: .right), column(3, 0.5, pin: .left),
        column(4, 0.5, pin: .left)],
      focusedColumn: 1)
    normalizeColumnPins(&workspace)
    #expect(workspace.columns.map(\.windows[0].rawValue) == [1, 3, 4, 2])
    #expect(workspace.columns.map(\.pin) == [nil, nil, nil, .right])
    #expect(workspace.focusedColumn == 3)
  }

  @Test(arguments: [0.5, 0.25])
  func `A strip column reaching under a pinned column parks and the pinned one stays`(
    offset: Double
  ) {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [column(1, 0.25, pin: .left), column(2, 0.5), column(3, 0.5), column(4, 0.5)])
    // Column 2 sits wholly under the pinned column at 0.5, half under it at 0.25.
    workspace.scrollOffset = offset
    let plan = continuousStripFramesForActiveWorkspace(
      computeLayout(workspace: workspace, viewport: viewport, settings: settings),
      viewport: scrollingViewport(workspace.columns, viewport: viewport, settings: settings),
      pinned: pinnedWindowIDs(workspace.columns),
      park: { _ in Rect(x: -999, y: 0, width: 1, height: 1) })
    #expect(plan.parkedWindowIDs.contains(WindowID(rawValue: 2)))
    #expect(plan.parkedWindowIDs.isDisjoint(with: [WindowID(rawValue: 1), WindowID(rawValue: 3)]))
  }
}
