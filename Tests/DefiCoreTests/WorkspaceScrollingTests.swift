import DefiCore
import DefiModel
import Testing

struct WorkspaceScrollingTests {
  private let settings = LayoutSettings()

  @Test
  func `Focus scrolls only enough for overflow`() throws {
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

    #expect(abs((workspace.targetScrollOffset) - (0.44)) <= 0.001)
    #expect(abs((diff[1].frame.x) - (407.2)) <= 0.001)
  }

  @Test
  func `Never centering preserves visible column`() {
    let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)
    let columns = (1...4).map {
      Column(window: WindowID(rawValue: UInt64($0)), width: .fraction(0.5))
    }

    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: columns,
      focusedColumn: 1
    )
    #expect(abs((focusedColumnTargetScrollOffset(
        workspace: workspace, viewport: viewport, settings: LayoutSettings(),
        centerFocusedColumn: .never
      )) - (0)) <= 0.001)

    workspace.focusedColumn = 2
    #expect(abs((focusedColumnTargetScrollOffset(
        workspace: workspace, viewport: viewport, settings: LayoutSettings(),
        centerFocusedColumn: .never
      )) - (0.5)) <= 0.001)

    workspace.focusedColumn = 3
    workspace.scrollOffset = 0.5
    #expect(abs((focusedColumnTargetScrollOffset(
        workspace: workspace, viewport: viewport, settings: LayoutSettings(),
        centerFocusedColumn: .never
      )) - (1)) <= 0.001)
  }

  @Test
  func `Always centering centers target`() throws {
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

    #expect(abs((workspace.targetScrollOffset) - (0.25)) <= 0.001)
    #expect(abs((diff[1].frame.x) - (250)) <= 0.001)
  }

}
