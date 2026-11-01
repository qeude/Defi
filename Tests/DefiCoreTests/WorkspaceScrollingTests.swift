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
    // The 1432-wide strip starts 4 before the screen, so the window ends 8 before its edge.
    #expect(abs((diff[1].frame.x) - (408.96)) <= 0.001)
    #expect(abs(diff[1].frame.x + diff[1].frame.width - 1_432) <= 0.001)
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

  private static let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)

  private static func fractions(_ width: Double, count: Int) -> [Column] {
    (1...count).map { Column(window: WindowID(rawValue: UInt64($0)), width: .fraction(width)) }
  }

  @Test(arguments: [
    (CenterFocusedColumn.always, 0, -0.25),
    (.always, 1, 0.25),
    (.always, 2, 0.75),
    (.always, 3, 1.25),
  ])
  func `Always centers every column, including the first and last`(
    mode: CenterFocusedColumn, focusedColumn: Int, expected: Double
  ) {
    let workspace = Workspace(
      id: WorkspaceID(rawValue: "1"), columns: Self.fractions(0.5, count: 4),
      focusedColumn: focusedColumn
    )

    #expect(
      focusedColumnTargetScrollOffset(
        workspace: workspace, viewport: Self.viewport,
        settings: LayoutSettings(centerFocusedColumn: mode)
      ) == expected
    )
  }

  @Test(arguments: [
    (0, UInt64(4), 0.0),
    (3, UInt64(1), 1.0),
  ])
  func `On-overflow keeps edge columns clamped`(
    focusedColumn: Int, previousWindow: UInt64, expected: Double
  ) {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"), columns: Self.fractions(0.5, count: 4),
      focusedColumn: focusedColumn
    )
    workspace.scrollFocus = ScrollFocus(windowID: WindowID(rawValue: previousWindow), centered: false)

    #expect(
      focusedColumnTargetScrollOffset(
        workspace: workspace, viewport: Self.viewport,
        settings: LayoutSettings(centerFocusedColumn: .onOverflow)
      ) == expected
    )
  }

  @Test(arguments: [
    (Column(window: WindowID(rawValue: 1), width: .fraction(0.5)), CenterFocusedColumn.never, true, -0.25),
    (Column(window: WindowID(rawValue: 1), width: .fraction(0.5)), .never, false, 0.0),
    (Column(window: WindowID(rawValue: 1), width: .fraction(0.5)), .always, false, -0.25),
    (Column(window: WindowID(rawValue: 1), width: .fraction(0.5)), .onOverflow, true, -0.25),
    (Column(window: WindowID(rawValue: 1), width: .fraction(1)), .never, true, 0.0),
    (Column(window: WindowID(rawValue: 1), width: .pixels(1_500)), .never, true, 0.0),
    (Column(window: WindowID(rawValue: 1), width: .pixels(1_500)), .always, false, 0.0),
  ])
  func `A lone column centers by the single-column setting or by always`(
    testCase: (column: Column, mode: CenterFocusedColumn, single: Bool, expected: Double)
  ) {
    let workspace = Workspace(id: WorkspaceID(rawValue: "1"), columns: [testCase.column])

    #expect(
      focusedColumnTargetScrollOffset(
        workspace: workspace, viewport: Self.viewport,
        settings: LayoutSettings(
          centerFocusedColumn: testCase.mode, alwaysCenterSingleColumn: testCase.single
        )
      ) == testCase.expected
    )
  }

  @Test
  func `A lone 0.8 column centers with a tenth of edge space`() {
    let workspace = Workspace(
      id: WorkspaceID(rawValue: "1"), columns: Self.fractions(0.8, count: 1)
    )

    let offset = focusedColumnTargetScrollOffset(
      workspace: workspace, viewport: Self.viewport,
      settings: LayoutSettings(alwaysCenterSingleColumn: true)
    )

    #expect(abs(offset - -0.1) <= 0.001)
  }

  @Test
  func `A lone centered column sits in the middle of the viewport`() {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"), columns: Self.fractions(0.5, count: 1)
    )
    workspace.scrollOffset = -0.25

    let frames = computeLayout(
      workspace: workspace, viewport: Self.viewport,
      settings: LayoutSettings(innerHorizontalGap: 0, outerRightGap: 0, outerLeftGap: 0)
    )

    #expect(abs(frames[0].frame.x + frames[0].frame.width / 2 - 500) <= 0.001)
  }

  @Test
  func `A second column ends the single-column centering`() {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"), columns: Self.fractions(0.5, count: 2),
      focusedColumn: 1
    )
    workspace.scrollOffset = -0.25
    workspace.scrollFocus = ScrollFocus(windowID: WindowID(rawValue: 1), centered: false)

    #expect(
      focusedColumnTargetScrollOffset(
        workspace: workspace, viewport: Self.viewport,
        settings: LayoutSettings(alwaysCenterSingleColumn: true)
      ) == 0.0
    )
  }

  @Test(arguments: [
    (CenterFocusedColumn.never, 0, UInt64(1), -0.25),
    (.never, 1, 2, 0.25),
    (.never, 3, 4, 1.25),
    (.onOverflow, 0, 1, -0.25),
  ])
  func `A pinned column is centered in every mode`(
    testCase: (mode: CenterFocusedColumn, column: Int, window: UInt64, expected: Double)
  ) {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"), columns: Self.fractions(0.5, count: 4),
      focusedColumn: testCase.column
    )
    workspace.scrollFocus = ScrollFocus(
      windowID: WindowID(rawValue: testCase.window), centered: false, pinned: true
    )

    #expect(
      focusedColumnTargetScrollOffset(
        workspace: workspace, viewport: Self.viewport,
        settings: LayoutSettings(centerFocusedColumn: testCase.mode)
      ) == testCase.expected
    )
  }

  @Test
  func `A pinned oversized column stays left-aligned`() {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [
        Column(window: WindowID(rawValue: 1), width: .fraction(0.5)),
        Column(window: WindowID(rawValue: 2), width: .pixels(1_500)),
        Column(window: WindowID(rawValue: 3), width: .fraction(0.5)),
      ],
      focusedColumn: 1
    )
    workspace.scrollFocus = ScrollFocus(windowID: WindowID(rawValue: 2), centered: false, pinned: true)

    #expect(
      focusedColumnTargetScrollOffset(
        workspace: workspace, viewport: Self.viewport,
        settings: LayoutSettings(centerFocusedColumn: .never)
      ) == 0.5
    )
  }

  @Test
  func `A pin persists while recomputed and drops when selection leaves the column`() {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"), columns: Self.fractions(0.5, count: 4)
    )
    workspace.scrollFocus = ScrollFocus(windowID: WindowID(rawValue: 1), centered: false, pinned: true)
    let settings = LayoutSettings(centerFocusedColumn: .never)

    for _ in 0..<2 {
      let target = focusedColumnScrollTarget(
        workspace: workspace, viewport: Self.viewport, settings: settings
      )
      workspace.scrollFocus = target.focus
      #expect(target.offset == -0.25)
      #expect(target.focus?.pinned == true)
    }

    workspace.focusedColumn = 1
    workspace.scrollOffset = -0.25
    let left = focusedColumnScrollTarget(
      workspace: workspace, viewport: Self.viewport, settings: settings
    )
    #expect(left.offset == 0.0)
    #expect(left.focus?.pinned == nil)

    workspace.focusedColumn = 0
    workspace.scrollFocus = left.focus
    workspace.scrollOffset = 0
    #expect(
      focusedColumnTargetScrollOffset(
        workspace: workspace, viewport: Self.viewport, settings: settings
      ) == 0.0
    )
  }

  @Test
  func `A pin survives stack focus inside its column`() {
    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [
        Column(windows: [WindowID(rawValue: 1), WindowID(rawValue: 2)], focusedWindow: 1, width: .fraction(0.5)),
        Column(window: WindowID(rawValue: 3), width: .fraction(0.5)),
        Column(window: WindowID(rawValue: 4), width: .fraction(0.5)),
        Column(window: WindowID(rawValue: 5), width: .fraction(0.5)),
      ]
    )
    workspace.scrollFocus = ScrollFocus(windowID: WindowID(rawValue: 1), centered: false, pinned: true)

    let target = focusedColumnScrollTarget(
      workspace: workspace, viewport: Self.viewport,
      settings: LayoutSettings(centerFocusedColumn: .never)
    )

    #expect(target.offset == -0.25)
    #expect(target.focus == ScrollFocus(windowID: WindowID(rawValue: 2), centered: false, pinned: true))
  }

  @Test
  func `An empty workspace stays at zero`() {
    let target = focusedColumnScrollTarget(
      workspace: Workspace(id: WorkspaceID(rawValue: "1")), viewport: Self.viewport,
      settings: LayoutSettings(centerFocusedColumn: .always, alwaysCenterSingleColumn: true)
    )

    #expect(target.offset == 0.0)
    #expect(target.focus == nil)
  }
}
