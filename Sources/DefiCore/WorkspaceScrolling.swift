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
  return min(max(focusedLeft, 0), max(totalWidth - 1, 0))
}

public func focusedColumnTargetScrollOffset(
  workspace: Workspace,
  viewport: Rect = Rect(x: 0, y: 0, width: 1_000, height: 1),
  windows: [Window] = [],
  settings: LayoutSettings,
  excludingWindowIDs: Set<WindowID> = []
) -> Double {
  focusedColumnScrollTarget(
    workspace: workspace,
    viewport: viewport,
    windows: windows,
    settings: settings,
    excludingWindowIDs: excludingWindowIDs
  ).offset
}

/// The target scroll offset and the scroll focus to record with it. On-overflow
/// decides once, when the selected window changes, so later recomputation keeps
/// that decision.
public func focusedColumnScrollTarget(
  workspace: Workspace,
  viewport: Rect = Rect(x: 0, y: 0, width: 1_000, height: 1),
  windows: [Window] = [],
  settings: LayoutSettings,
  excludingWindowIDs: Set<WindowID> = []
) -> (offset: Double, focus: ScrollFocus?) {
  let selectedColumn = workspace.columns.indices.contains(workspace.focusedColumn)
    ? workspace.columns[workspace.focusedColumn] : nil
  let selectedWindowID = selectedColumn.flatMap {
    $0.windows.indices.contains($0.focusedWindow) ? $0.windows[$0.focusedWindow] : nil
  }
  let recordedFocus = workspace.scrollFocus
  let workspace = workspaceForLayout(
    workspace,
    excludingWindowIDs: excludingWindowIDs
  )
  let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
  let widths = workspace.columns.indices.map {
    columnWidthInViewports(
      workspace.columns[$0],
      columnIndex: $0,
      columnCount: workspace.columns.count,
      viewport: viewport,
      windowsByID: windowsByID,
      settings: settings
    )
  }
  let left = { (index: Int) in widths.prefix(index).reduce(0, +) }
  let focusedLeft = left(workspace.focusedColumn)
  let focusedWidth =
    widths.indices.contains(workspace.focusedColumn) ? widths[workspace.focusedColumn] : 0
  let focusedRight = focusedLeft + focusedWidth
  let maxContentScroll = max(widths.reduce(0, +) - 1, 0)
  let minimumScroll = max(focusedRight - 1, 0)
  let maximumScroll = min(focusedLeft, maxContentScroll)
  let centered = min(
    max(focusedLeft + focusedWidth / 2 - 0.5, minimumScroll),
    maximumScroll
  )
  let revealed =
    minimumScroll > maximumScroll
    ? maximumScroll
    : min(max(workspace.scrollOffset, minimumScroll), maximumScroll)

  // The on-overflow decision is recorded in every mode, so switching modes keeps it.
  let overflows: Bool
  if let recordedFocus, recordedFocus.windowID == selectedWindowID {
    overflows = recordedFocus.centered
  } else if let previousWindowID = recordedFocus?.windowID,
    let previous = workspace.columns.firstIndex(where: {
      $0.windows.contains(previousWindowID)
    })
  {
    // Column slots include their gaps, so slots spanning exactly one viewport fit.
    let span =
      max(left(previous) + widths[previous], focusedRight)
      - min(left(previous), focusedLeft)
    overflows = span > 1 + 1e-9
  } else {
    overflows = false
  }
  let centers: Bool
  switch settings.centerFocusedColumn {
  case .never: centers = false
  case .always: centers = true
  case .onOverflow: centers = overflows
  }
  return (
    centers ? centered : revealed,
    selectedWindowID.map { ScrollFocus(windowID: $0, centered: overflows) }
  )
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

