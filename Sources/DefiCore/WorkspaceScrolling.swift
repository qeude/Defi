import DefiModel

public func focusedColumnLeftScrollOffset(
  workspace: Workspace,
  viewport: Rect = Rect(x: 0, y: 0, width: 1_000, height: 1),
  windows: [Window] = [],
  settings: LayoutSettings = LayoutSettings(),
  excludingWindowIDs: Set<WindowID> = []
) -> Double {
  let workspace = workspaceForLayout(
    workspace,
    excludingWindowIDs: excludingWindowIDs
  )
  let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
  let focusedLeft = columnsWidth(
    Array(workspace.columns.prefix(workspace.focusedColumn)),
    viewport: viewport,
    windowsByID: windowsByID,
    settings: settings,
    totalColumnCount: workspace.columns.count
  )
  let totalWidth = columnsWidth(
    workspace.columns,
    viewport: viewport,
    windowsByID: windowsByID,
    settings: settings,
    totalColumnCount: workspace.columns.count
  )
  let leftGap = workspace.focusedColumn == 0
    ? settings.outerLeftGap
    : settings.innerHorizontalGap
  let leftPadding = max(settings.horizontalViewportPadding - max(leftGap, 0), 0)
    / max(viewport.width, 1)
  return min(max(focusedLeft - leftPadding, 0), max(totalWidth - 1, 0))
}

public func focusedColumnTargetScrollOffset(
  workspace: Workspace,
  viewport: Rect = Rect(x: 0, y: 0, width: 1_000, height: 1),
  windows: [Window] = [],
  settings: LayoutSettings,
  excludingWindowIDs: Set<WindowID> = []
) -> Double {
  let workspace = workspaceForLayout(
    workspace,
    excludingWindowIDs: excludingWindowIDs
  )
  let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
  let focusedLeft = columnsWidth(
    Array(workspace.columns.prefix(workspace.focusedColumn)),
    viewport: viewport,
    windowsByID: windowsByID,
    settings: settings,
    totalColumnCount: workspace.columns.count
  )
  let focusedWidth =
    workspace.columns.indices.contains(workspace.focusedColumn)
    ? columnWidthInViewports(
      workspace.columns[workspace.focusedColumn],
      columnIndex: workspace.focusedColumn,
      columnCount: workspace.columns.count,
      viewport: viewport,
      windowsByID: windowsByID,
      settings: settings
    )
    : 0
  let focusedRight = focusedLeft + focusedWidth
  let totalWidth = columnsWidth(
    workspace.columns,
    viewport: viewport,
    windowsByID: windowsByID,
    settings: settings,
    totalColumnCount: workspace.columns.count
  )
  let maxContentScroll = max(totalWidth - 1, 0)
  let leftGap = workspace.focusedColumn == 0
    ? settings.outerLeftGap
    : settings.innerHorizontalGap
  let rightGap = workspace.focusedColumn + 1 == workspace.columns.count
    ? settings.outerRightGap
    : settings.innerHorizontalGap
  let viewportWidth = max(viewport.width, 1)
  let leftPadding = max(settings.horizontalViewportPadding - max(leftGap, 0), 0)
    / viewportWidth
  let rightPadding = max(settings.horizontalViewportPadding - max(rightGap, 0), 0)
    / viewportWidth
  let minimumScroll = max(focusedRight - 1 + rightPadding, 0)
  let maximumScroll = min(focusedLeft - leftPadding, maxContentScroll)

  switch settings.centerFocusedColumn {
  case .always:
    return min(
      max(focusedLeft + focusedWidth / 2 - 0.5, minimumScroll),
      maximumScroll
    )
  case .never:
    return minimumScroll > maximumScroll
      ? maximumScroll
      : min(max(workspace.scrollOffset, minimumScroll), maximumScroll)
  }
}

private func columnsWidth(
  _ columns: [Column],
  viewport: Rect,
  windowsByID: [WindowID: Window],
  settings: LayoutSettings,
  totalColumnCount: Int
) -> Double {
  columns.enumerated().reduce(0) { total, entry in
    total + columnWidthInViewports(
      entry.element,
      columnIndex: entry.offset,
      columnCount: totalColumnCount,
      viewport: viewport,
      windowsByID: windowsByID,
      settings: settings
    )
  }
}

private func columnWidthInViewports(
  _ column: Column,
  columnIndex: Int,
  columnCount: Int,
  viewport: Rect,
  windowsByID: [WindowID: Window],
  settings: LayoutSettings
) -> Double {
  columnLayoutWidth(
    column,
    viewport: viewport,
    windowsByID: windowsByID,
    settings: settings,
    columnIndex: columnIndex,
    columnCount: columnCount
  )
    / max(viewport.width, 1)
}

public func repairWorkspaceScroll(
  _ workspace: inout Workspace,
  settings: LayoutSettings,
  excludingWindowIDs: Set<WindowID> = []
) {
  workspace.targetScrollOffset = focusedColumnTargetScrollOffset(
    workspace: workspace,
    settings: settings,
    excludingWindowIDs: excludingWindowIDs
  )
}

func nearestPresetIndex(current: Double, presets: [Double]) -> Int {
  presets.indices.min {
    abs(presets[$0] - current) < abs(presets[$1] - current)
  } ?? 0
}
