import DefiModel

public func focusedColumnScrollOffset(
  workspace: Workspace,
  viewport: Rect = Rect(x: 0, y: 0, width: 1_000, height: 1),
  windows: [Window] = [],
  settings: LayoutSettings = LayoutSettings()
) -> Double {
  focusedColumnTargetScrollOffset(
    workspace: workspace,
    viewport: viewport,
    windows: windows,
    settings: settings,
    centerFocusedColumn: .never
  )
}

public func focusedColumnLeftScrollOffset(
  workspace: Workspace,
  viewport: Rect = Rect(x: 0, y: 0, width: 1_000, height: 1),
  windows: [Window] = [],
  settings: LayoutSettings = LayoutSettings()
) -> Double {
  let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
  let focusedLeft = columnsWidth(
    Array(workspace.columns.prefix(workspace.focusedColumn)),
    viewport: viewport,
    windowsByID: windowsByID
  )
  let totalWidth = columnsWidth(workspace.columns, viewport: viewport, windowsByID: windowsByID)
  let leftGap = workspace.focusedColumn == 0
    ? settings.outerLeftGap
    : settings.innerHorizontalGap
  let leftPadding = max(settings.horizontalViewportPadding - max(leftGap, 0), 0)
    / max(viewport.width, 1)
  return min(max(focusedLeft - leftPadding, 0), max(totalWidth - 1, 0))
}

public func focusedColumnRevealScrollOffset(
  workspace: Workspace,
  viewport: Rect = Rect(x: 0, y: 0, width: 1_000, height: 1),
  windows: [Window] = [],
  settings: LayoutSettings = LayoutSettings()
) -> Double {
  let minimumReveal = focusedColumnTargetScrollOffset(
    workspace: workspace,
    viewport: viewport,
    windows: windows,
    settings: settings,
    centerFocusedColumn: .never
  )
  let pixelTolerance = 1 / max(viewport.width, 1)
  guard abs(minimumReveal - workspace.scrollOffset) > pixelTolerance else {
    return minimumReveal
  }
  return focusedColumnLeftScrollOffset(
    workspace: workspace,
    viewport: viewport,
    windows: windows,
    settings: settings
  )
}

public func focusedColumnTargetScrollOffset(
  workspace: Workspace,
  viewport: Rect = Rect(x: 0, y: 0, width: 1_000, height: 1),
  windows: [Window] = [],
  settings: LayoutSettings,
  centerFocusedColumn: CenterFocusedColumn? = nil
) -> Double {
  let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
  let focusedLeft = columnsWidth(
    Array(workspace.columns.prefix(workspace.focusedColumn)),
    viewport: viewport,
    windowsByID: windowsByID
  )
  let focusedWidth =
    workspace.columns.indices.contains(workspace.focusedColumn)
    ? columnWidthInViewports(
      workspace.columns[workspace.focusedColumn],
      viewport: viewport,
      windowsByID: windowsByID
    )
    : 0
  let focusedRight = focusedLeft + focusedWidth
  let totalWidth = columnsWidth(workspace.columns, viewport: viewport, windowsByID: windowsByID)
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

  switch centerFocusedColumn ?? settings.centerFocusedColumn {
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
  windowsByID: [WindowID: Window]
) -> Double {
  columns.reduce(0) {
    $0 + columnWidthInViewports($1, viewport: viewport, windowsByID: windowsByID)
  }
}

private func columnWidthInViewports(
  _ column: Column,
  viewport: Rect,
  windowsByID: [WindowID: Window]
) -> Double {
  columnLayoutWidth(column, viewport: viewport, windowsByID: windowsByID)
    / max(viewport.width, 1)
}

public func repairWorkspaceScroll(_ workspace: inout Workspace, settings: LayoutSettings) {
  workspace.targetScrollOffset = focusedColumnTargetScrollOffset(
    workspace: workspace,
    settings: settings
  )
}

func nearestPresetIndex(current: Double, presets: [Double]) -> Int {
  presets.indices.min {
    abs(presets[$0] - current) < abs(presets[$1] - current)
  } ?? 0
}
