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

  @Test(arguments: [
    (CenterFocusedColumn.never, UInt64?.none, 2, 0.5),
    (.never, 1, 2, 0.5),
    (.always, 2, 2, 0.75),
    (.always, nil, 1, 0.25),
    (.onOverflow, nil, 2, 0.5),
    (.onOverflow, 2, 2, 0.5),
    (.onOverflow, 1, 2, 0.75),
    (.onOverflow, 4, 1, 0.25),
  ])
  func `Centering follows the prior and new selected columns`(
    mode: CenterFocusedColumn, previousWindow: UInt64?, focusedColumn: Int, expected: Double
  ) {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: (1...4).map {
        Column(window: WindowID(rawValue: UInt64($0)), width: .fraction(0.5))
      },
      focusedColumn: focusedColumn
    )
    workspace.scrollFocus = previousWindow.map {
      ScrollFocus(windowID: WindowID(rawValue: $0), centered: false)
    }

    #expect(
      focusedColumnTargetScrollOffset(
        workspace: workspace,
        viewport: Rect(x: 0, y: 0, width: 1_000, height: 700),
        settings: LayoutSettings(centerFocusedColumn: mode)
      ) == expected
    )
  }

  @Test
  func `On-overflow left-aligns an oversized column`() {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [
        Column(window: WindowID(rawValue: 1), width: .fraction(0.5)),
        Column(window: WindowID(rawValue: 2), width: .pixels(1_500)),
        Column(window: WindowID(rawValue: 3), width: .fraction(0.5)),
      ],
      focusedColumn: 1
    )
    workspace.scrollFocus = ScrollFocus(windowID: WindowID(rawValue: 1), centered: false)

    #expect(
      focusedColumnTargetScrollOffset(
        workspace: workspace,
        viewport: Rect(x: 0, y: 0, width: 1_000, height: 700),
        settings: LayoutSettings(centerFocusedColumn: .onOverflow)
      ) == 0.5
    )
  }

  @Test
  func `Switching centering modes keeps the on-overflow decision`() {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: (1...4).map {
        Column(window: WindowID(rawValue: UInt64($0)), width: .fraction(0.5))
      },
      focusedColumn: 2
    )
    workspace.scrollFocus = ScrollFocus(windowID: WindowID(rawValue: 1), centered: false)
    let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)
    let modes: [CenterFocusedColumn] = [.never, .onOverflow]
    let targets = modes.map { mode in
      let target = focusedColumnScrollTarget(
        workspace: workspace, viewport: viewport,
        settings: LayoutSettings(centerFocusedColumn: mode)
      )
      workspace.scrollFocus = target.focus
      return target.offset
    }

    #expect(targets == [0.5, 0.75])
    #expect(workspace.scrollFocus == ScrollFocus(windowID: WindowID(rawValue: 3), centered: true))
  }
}
