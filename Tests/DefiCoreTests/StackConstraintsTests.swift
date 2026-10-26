import DefiCore
import DefiModel
import Testing

struct StackConstraintsTests {
  private let noGaps = LayoutSettings(
    innerHorizontalGap: 0, innerVerticalGap: 0,
    outerTopGap: 0, outerRightGap: 0, outerBottomGap: 0, outerLeftGap: 0
  )
  private let viewport = Rect(x: 0, y: 0, width: 1_000, height: 1_000)

  private func id(_ value: UInt64) -> WindowID { WindowID(rawValue: value) }

  private func window(
    _ value: UInt64, minimumHeight: Double? = nil, maximumHeight: Double? = nil
  ) -> Window {
    Window(
      id: id(value), appID: "test", title: "Window \(value)",
      frame: Rect(x: 0, y: 0, width: 500, height: 500),
      maximumTiledHeight: maximumHeight, minimumTiledHeight: minimumHeight
    )
  }

  private func stack(_ values: [UInt64], focusedWindow: Int = 0) -> Column {
    Column(windows: values.map(id), focusedWindow: focusedWindow, width: .fraction(0.5))
  }

  private func heights(
    _ values: [UInt64], windows: [Window] = [], settings: LayoutSettings? = nil,
    viewport: Rect? = nil
  ) -> [Double] {
    let workspace = Workspace(id: WorkspaceID(rawValue: "1"), columns: [stack(values)])
    return computeLayout(
      workspace: workspace, viewport: viewport ?? self.viewport, windows: windows,
      settings: settings ?? noGaps
    ).map(\.frame.height)
  }

  @Test
  func `Unconstrained stacks of two, three and four windows stay balanced`() {
    #expect(heights([1, 2]) == [500, 500])
    #expect(heights([1, 2, 3], viewport: Rect(x: 0, y: 0, width: 1_000, height: 900)) == [300, 300, 300])
    #expect(heights([1, 2, 3, 4]) == [250, 250, 250, 250])
  }

  @Test
  func `A minimum height window gets its minimum and the rest share evenly`() {
    #expect(heights([1, 2, 3], windows: [window(2, minimumHeight: 500)]) == [250, 500, 250])
  }

  @Test
  func `Gaps count toward the minimum height and the shared slots`() {
    let workspace = Workspace(id: WorkspaceID(rawValue: "1"), columns: [stack([1, 2, 3])])
    let frames = computeLayout(
      workspace: workspace,
      viewport: Rect(x: 0, y: 0, width: 1_000, height: 900),
      windows: [window(2, minimumHeight: 500)],
      settings: LayoutSettings()
    ).map(\.frame)

    #expect(frames == [
      Rect(x: 8, y: 8, width: 488, height: 184),
      Rect(x: 8, y: 200, width: 488, height: 500),
      Rect(x: 8, y: 708, width: 488, height: 184),
    ])
  }

  @Test
  func `A maximum height window hands its surplus to the others`() {
    #expect(heights([1, 2], windows: [window(1, maximumHeight: 300)]) == [300, 700])
  }

  @Test
  func `A stack whose windows are all capped centres each window in its slot`() {
    let workspace = Workspace(id: WorkspaceID(rawValue: "1"), columns: [stack([1, 2])])
    let frames = computeLayout(
      workspace: workspace, viewport: viewport,
      windows: [window(1, maximumHeight: 300), window(2, maximumHeight: 300)],
      settings: noGaps
    ).map(\.frame)

    #expect(frames.map(\.y) == [100, 600])
    #expect(frames.map(\.height) == [300, 300])
  }

  @Test
  func `An infeasible stack starts proportional slots and keeps each window at its minimum`() {
    let frames = computeLayout(
      workspace: Workspace(id: WorkspaceID(rawValue: "1"), columns: [stack([1, 2])]),
      viewport: Rect(x: 0, y: 0, width: 1_000, height: 500),
      windows: [window(1, minimumHeight: 600), window(2, minimumHeight: 400)],
      settings: noGaps
    ).map(\.frame)
    #expect(frames.map(\.y) == [0, 300])
    #expect(frames.map(\.height) == [600, 400])
  }

  @Test
  func `Stack fit rejects windows whose minimums exceed the viewport`() {
    let windows = Dictionary(uniqueKeysWithValues: [
      window(1, minimumHeight: 500), window(2, minimumHeight: 600), window(3),
    ].map { ($0.id, $0) })

    #expect(
      stackFit([id(1), id(3)], windowsByID: windows, viewport: viewport, settings: noGaps) == .fits)
    let fit = stackFit([id(1), id(2)], windowsByID: windows, viewport: viewport, settings: noGaps)
    #expect(fit == .rejected(StackRejection(requiredHeight: 1_100, availableHeight: 1_000)))
    #expect(StackRejection(requiredHeight: 1_100, availableHeight: 1_000).description
      == "stack needs 1100pt but only 1000pt is available")
  }

  @Test
  func `Stack fit includes the gaps the stack position implies`() {
    let windows = Dictionary(uniqueKeysWithValues: [
      window(1, minimumHeight: 450), window(2, minimumHeight: 450),
    ].map { ($0.id, $0) })
    let fit = stackFit(
      [id(1), id(2)], windowsByID: windows,
      viewport: Rect(x: 0, y: 0, width: 1_000, height: 900), settings: LayoutSettings())

    #expect(fit == .rejected(StackRejection(requiredHeight: 924, availableHeight: 900)))
  }

  @Test
  func `A single window always fits even when taller than the viewport`() {
    let windows = [id(1): window(1, minimumHeight: 5_000)]

    #expect(stackFit([id(1)], windowsByID: windows, viewport: viewport, settings: noGaps) == .fits)
    #expect(heights([1], windows: Array(windows.values)) == [5_000])
  }

  private func shrunkWorkspace(
    columns: [Column], focusedColumn: Int, scrollOffset: Double = 0
  ) -> (Workspace, [WindowID: Window]) {
    let windows = Dictionary(
      uniqueKeysWithValues: (1...9).map { value in
        let window = window(UInt64(value), minimumHeight: value <= 5 ? 400 : nil)
        return (window.id, window)
      })
    return (
      Workspace(
        id: WorkspaceID(rawValue: "1"), columns: columns, focusedColumn: focusedColumn,
        scrollOffset: scrollOffset, targetScrollOffset: scrollOffset),
      windows
    )
  }

  @Test
  func `A shrunken viewport splits a stack into adjacent columns keeping order and focus`() {
    var (workspace, windows) = shrunkWorkspace(
      columns: [stack([1, 2, 3], focusedWindow: 2)], focusedColumn: 0)

    let changed = separateInfeasibleStacks(
      in: &workspace, viewport: viewport, windowsByID: windows, settings: noGaps)

    #expect(changed)
    #expect(workspace.columns.map(\.windows) == [[id(1), id(2)], [id(3)]])
    #expect(workspace.columns.map(\.focusedWindow) == [1, 0])
    #expect(workspace.columns.map(\.width) == [.fraction(0.5), .fraction(0.5)])
    #expect(workspace.focusedColumn == 1)
    #expect(workspace.scrollOffset == 0)
  }

  @Test
  func `Greedy runs split five windows into two, two and one`() {
    var (workspace, windows) = shrunkWorkspace(
      columns: [stack([1, 2, 3, 4, 5])], focusedColumn: 0)

    separateInfeasibleStacks(
      in: &workspace, viewport: viewport, windowsByID: windows, settings: noGaps)

    #expect(workspace.columns.map(\.windows) == [[id(1), id(2)], [id(3), id(4)], [id(5)]])
    #expect(workspace.focusedColumn == 0)
  }

  @Test
  func `Columns inserted left of the focused column move the scroll anchor`() {
    var (workspace, windows) = shrunkWorkspace(
      columns: [stack([1, 2, 3]), stack([6])], focusedColumn: 1, scrollOffset: 0.5)

    separateInfeasibleStacks(
      in: &workspace, viewport: viewport, windowsByID: windows, settings: noGaps)

    #expect(workspace.columns.map(\.windows) == [[id(1), id(2)], [id(3)], [id(6)]])
    #expect(workspace.focusedColumn == 2)
    #expect(workspace.scrollOffset == 1)
    #expect(workspace.targetScrollOffset == 1)
  }

  @Test
  func `Separation is idempotent and growing the viewport neither merges nor unbalances`() {
    var (workspace, windows) = shrunkWorkspace(
      columns: [stack([1, 2, 3])], focusedColumn: 0)
    separateInfeasibleStacks(
      in: &workspace, viewport: viewport, windowsByID: windows, settings: noGaps)
    let separated = workspace

    #expect(!separateInfeasibleStacks(
      in: &workspace, viewport: viewport, windowsByID: windows, settings: noGaps))
    #expect(workspace == separated)

    let tall = Rect(x: 0, y: 0, width: 1_000, height: 1_800)
    #expect(!separateInfeasibleStacks(
      in: &workspace, viewport: tall, windowsByID: windows, settings: noGaps))
    #expect(workspace.columns.map(\.windows) == [[id(1), id(2)], [id(3)]])
    let frames = computeLayout(
      workspace: workspace, viewport: tall, windows: Array(windows.values), settings: noGaps)
    #expect(frames.prefix(2).map(\.frame.height) == [900, 900])
  }

  @Test
  func `A single window taller than the viewport is never split and is diagnosed`() {
    var (workspace, windows) = shrunkWorkspace(
      columns: [stack([1]), stack([2, 3])], focusedColumn: 0)
    windows[id(1)]?.minimumTiledHeight = 5_000
    let before = workspace

    #expect(!separateInfeasibleStacks(
      in: &workspace, viewport: viewport, windowsByID: windows, settings: noGaps))
    #expect(workspace == before)
    #expect(
      oversizedStackWindowIDs(
        in: workspace, windowsByID: windows, viewport: viewport, settings: noGaps) == [id(1)])
  }

  @Test
  func `Columns holding excluded windows are left alone`() {
    var (workspace, windows) = shrunkWorkspace(
      columns: [stack([1, 2, 3])], focusedColumn: 0)

    #expect(!separateInfeasibleStacks(
      in: &workspace, viewport: viewport, windowsByID: windows, settings: noGaps,
      excludingWindowIDs: [id(2)]))
    #expect(workspace.columns.map(\.windows) == [[id(1), id(2), id(3)]])
  }

  @Test
  func `An oversized single window is targeted at its minimum height so it is not retried`() {
    let frames = computeLayout(
      workspace: Workspace(id: WorkspaceID(rawValue: "1"), columns: [stack([1])]),
      viewport: viewport, windows: [window(1, minimumHeight: 1_200)], settings: LayoutSettings()
    ).map(\.frame)
    #expect(frames.map(\.y) == [8])
    #expect(frames.map(\.height) == [1_200])
  }

  @Test
  func `Stack fit reserves gaps and a drawable point for unconstrained windows`() {
    let windows = [id(1): window(1, minimumHeight: 880), id(2): window(2)]
    let fit = stackFit(
      [id(1), id(2)], windowsByID: windows,
      viewport: Rect(x: 0, y: 0, width: 1_000, height: 900), settings: LayoutSettings())

    #expect(fit == .rejected(StackRejection(requiredHeight: 905, availableHeight: 900)))
  }

  @Test
  func `A maximum holds even when applyGaps clamps an oversized gap`() {
    let frames = computeLayout(
      workspace: Workspace(id: WorkspaceID(rawValue: "1"), columns: [stack([1, 2])]),
      viewport: viewport, windows: [window(1, maximumHeight: 100)],
      settings: LayoutSettings(innerVerticalGap: 0, outerTopGap: 200, outerBottomGap: 0)
    ).map(\.frame)
    #expect(frames[0].height == 100)
  }
}
