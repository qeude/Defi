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
  let widths = columnWidthsInViewports(
    workspace.columns, viewport: viewport, windowsByID: windowsByID, settings: settings
  )
  let focusedLeft = widths.prefix(workspace.focusedColumn).reduce(0, +)
  let totalWidth = widths.reduce(0, +)
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
  let widths = columnWidthsInViewports(
    workspace.columns, viewport: viewport, windowsByID: windowsByID, settings: settings
  )
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
  // A pin belongs to its column, so selecting another column drops it.
  let pinned =
    recordedFocus.map { $0.pinned == true && selectedColumn?.windows.contains($0.windowID) == true }
    ?? false
  let free =
    recordedFocus.map { $0.free == true && selectedColumn?.windows.contains($0.windowID) == true }
    ?? false
  // Exact centering may leave edge space; an oversized column stays left-aligned.
  let exactCenter =
    widths.indices.contains(workspace.focusedColumn) && focusedWidth <= 1 + 1e-9
    ? focusedLeft + focusedWidth / 2 - 0.5 : focusedLeft
  let offset: Double
  if free {
    offset = revealed
  } else if pinned || settings.centerFocusedColumn == .always
    || (settings.alwaysCenterSingleColumn && workspace.columns.count == 1)
  {
    offset = exactCenter
  } else if settings.centerFocusedColumn == .onOverflow, overflows {
    offset = centered
  } else {
    offset = revealed
  }
  return (
    offset,
    selectedWindowID.map {
      ScrollFocus(windowID: $0, centered: overflows, pinned: pinned ? true : nil, free: free ? true : nil)
    }
  )
}

/// The width, in strip widths, that gives the selected column the space the other fully
/// visible columns leave free, and the offset that keeps those columns in view: the first
/// stays put and the ones after the selected column slide right by its growth.
/// A verified `maximumWidth` caps it. Nil when the selected column is not fully in view
/// or it would grow less than a point.
public func focusedColumnAvailableWidth(
  workspace: Workspace,
  viewport: Rect,
  windows: [Window] = [],
  settings: LayoutSettings,
  excludingWindowIDs: Set<WindowID> = [],
  maximumWidth: Double? = nil
) -> (width: Double, offset: Double)? {
  let workspace = workspaceForLayout(workspace, excludingWindowIDs: excludingWindowIDs)
  guard workspace.columns.indices.contains(workspace.focusedColumn) else { return nil }
  let widths = columnWidthsInViewports(
    workspace.columns, viewport: viewport,
    windowsByID: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) }), settings: settings)
  let point = 1 / stripViewport(viewport, settings: settings).width
  let lefts = widths.indices.map { widths.prefix($0).reduce(0, +) }
  // Where the strip is heading, so a resize right after navigation sees the new view.
  let start = workspace.targetScrollOffset
  let visible = widths.indices.filter {
    lefts[$0] >= start - point && lefts[$0] + widths[$0] <= start + 1 + point
  }
  guard visible.contains(workspace.focusedColumn), let first = visible.first else { return nil }
  let current = widths[workspace.focusedColumn]
  let width = min(current + 1 - visible.map { widths[$0] }.reduce(0, +), maximumWidth ?? 1)
  guard width >= current + point else { return nil }
  return (width, lefts[first])
}

private func columnWidthsInViewports(
  _ columns: [Column],
  viewport: Rect,
  windowsByID: [WindowID: Window],
  settings: LayoutSettings
) -> [Double] {
  let stripWidth = stripViewport(viewport, settings: settings).width
  return columnLayoutWidths(columns, viewport: viewport, windowsByID: windowsByID, settings: settings)
    .map { $0 / stripWidth }
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


/// Where a scroll gesture released at `projected` settles: on the column whose resting
/// place lies nearest, each placed as key presses stepping to it from the view before the
/// gesture (`rest`) would place it under the centring policy. A flick reaches the next
/// resting place at most. Offsets are in strip widths.
public func scrollGestureSnap(
  workspace: Workspace,
  viewport: Rect,
  windows: [Window] = [],
  settings: LayoutSettings,
  excludingWindowIDs: Set<WindowID> = [],
  rest: Double,
  current: Double,
  projected: Double
) -> (column: Int, offset: Double, focus: ScrollFocus?)? {
  // Each column as successive key presses from the selected one would leave it. Starting
  // from the released view instead would leave any column already fully in view where the
  // fingers stopped, half-cut neighbours included.
  guard workspace.columns.indices.contains(workspace.focusedColumn) else { return nil }
  var rests: [(column: Int, offset: Double, focus: ScrollFocus?)] = []
  for direction in [-1, 1] {
    var stepped = workspace
    stepped.focusedLayer = .tiled
    stepped.scrollOffset = rest
    var column = workspace.focusedColumn
    if direction == 1 {
      let target = focusedColumnScrollTarget(
        workspace: stepped, viewport: viewport, windows: windows,
        settings: settings, excludingWindowIDs: excludingWindowIDs)
      rests.append((column, target.offset, target.focus))
    }
    while workspace.columns.indices.contains(column + direction) {
      column += direction
      stepped.focusedColumn = column
      let target = focusedColumnScrollTarget(
        workspace: stepped, viewport: viewport, windows: windows,
        settings: settings, excludingWindowIDs: excludingWindowIDs)
      stepped.scrollOffset = target.offset
      stepped.scrollFocus = target.focus
      rests.append((column, target.offset, target.focus))
    }
  }
  // A native fullscreen column rests where its neighbour does; it is never the landing.
  rests.removeAll { isOutOfLayout(workspace.columns[$0.column], excludingWindowIDs) }
  rests.sort { $0.column < $1.column }
  let offsets = rests.map(\.offset).sorted()
  // A flick carries to the next resting place at most, never several columns at once:
  // macOS's accelerated scroll speeds would otherwise make the landing hard to predict.
  let forward = projected >= current
  let limit = forward
    ? offsets.first { $0 > current + 1e-6 } ?? offsets.last
    : offsets.last { $0 < current - 1e-6 } ?? offsets.first
  let projected = limit.map { forward ? min(projected, $0) : max(projected, $0) } ?? projected
  guard let nearest = rests.min(by: { abs($0.offset - projected) < abs($1.offset - projected) - 1e-9 })
  else { return nil }
  // Columns resting at the same place are all in view there. Springing back keeps the
  // selection; otherwise the furthest in the gesture's direction takes focus, as in Niri.
  let tied = rests.filter { abs($0.offset - nearest.offset) < 1e-6 }
  let towards = abs(projected - current) > 1e-6 ? forward : current >= rest
  guard let chosen = tied.first(where: { $0.column == workspace.focusedColumn })
    ?? (towards ? tied.last : tied.first) else { return nil }
  return (chosen.column, chosen.offset, chosen.focus)
}

/// Where an unsnapped scroll gesture released at `projected` rests: there, within the strip,
/// with focus on the column fully in view nearest the middle, the one further in the
/// gesture's direction (from `current`) on a tie. When none is fully in view, the strip
/// slides just enough to show the nearest one. Offsets are in strip widths.
public func scrollGestureFreeRest(
  workspace: Workspace,
  viewport: Rect,
  windows: [Window] = [],
  settings: LayoutSettings,
  excludingWindowIDs: Set<WindowID> = [],
  current: Double,
  projected: Double
) -> (column: Int, offset: Double, focus: ScrollFocus?)? {
  // Where each column is fully in view, whatever the centring policy.
  var revealing = settings
  revealing.centerFocusedColumn = .never
  revealing.alwaysCenterSingleColumn = false
  let extents = scrollGestureExtents(workspace: workspace, viewport: viewport, windows: windows,
    settings: revealing, excludingWindowIDs: excludingWindowIDs)
  // Columns in the layout, with their centres in strip widths.
  let shown = workspace.columns.indices.filter { !isOutOfLayout(workspace.columns[$0], excludingWindowIDs) }
  guard let lowest = shown.map({ extents[$0].lowerBound }).min(),
    let highest = shown.map({ extents[$0].upperBound }).max()
  else { return nil }
  let wanted = min(max(projected, lowest), highest)
  let forward = projected >= current
  let widths = columnWidthsInViewports(
    workspaceForLayout(workspace, excludingWindowIDs: excludingWindowIDs).columns, viewport: viewport,
    windowsByID: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) }), settings: settings)
  guard shown.count == widths.count else { return nil }
  let centers = Dictionary(uniqueKeysWithValues: shown.indices.map {
    (shown[$0], widths.prefix($0).reduce(0, +) + widths[$0] / 2)
  })
  let distance = { (column: Int) in
    (max(extents[column].lowerBound - wanted, wanted - extents[column].upperBound, 0),
      abs(centers[column]! - (wanted + 0.5)), forward ? -column : column)
  }
  guard let column = shown.min(by: { distance($0) < distance($1) }) else { return nil }
  let extent = extents[column]
  let rows = workspace.columns[column]
  let windowID = rows.windows.indices.contains(rows.focusedWindow) ? rows.windows[rows.focusedWindow] : nil
  return (column, min(max(wanted, extent.lowerBound), extent.upperBound),
    windowID.map { ScrollFocus(windowID: $0, centered: false, free: true) })
}

/// Whether layout leaves the column out: every window in it is excluded (native fullscreen).
private func isOutOfLayout(_ column: Column, _ excludingWindowIDs: Set<WindowID>) -> Bool {
  column.windows.allSatisfy(excludingWindowIDs.contains)
}

/// Each column's resting offsets: the focus policy pushed from the right, then from the
/// left. The column is fully in view anywhere between them.
public func scrollGestureExtents(
  workspace: Workspace,
  viewport: Rect,
  windows: [Window] = [],
  settings: LayoutSettings,
  excludingWindowIDs: Set<WindowID> = []
) -> [ClosedRange<Double>] {
  workspace.columns.indices.map { column in
    var candidate = workspace
    candidate.focusedColumn = column
    candidate.focusedLayer = .tiled
    candidate.scrollFocus = nil
    let offsets = [-1e9, 1e9].map { start in
      candidate.scrollOffset = start
      return focusedColumnScrollTarget(
        workspace: candidate, viewport: viewport, windows: windows,
        settings: settings, excludingWindowIDs: excludingWindowIDs
      ).offset
    }
    return min(offsets[0], offsets[1])...max(offsets[0], offsets[1])
  }
}

/// A rubber band: past `bounds`, travel meets growing resistance and never exceeds
/// `dimension`. macOS's stiffness by default.
public func rubberBanded(
  _ value: Double, bounds: ClosedRange<Double>, dimension: Double, stiffness: Double = 0.55
) -> Double {
  func resist(_ overshoot: Double) -> Double {
    (1 - 1 / (overshoot * stiffness / dimension + 1)) * dimension
  }
  if value < bounds.lowerBound { return bounds.lowerBound - resist(bounds.lowerBound - value) }
  if value > bounds.upperBound { return bounds.upperBound + resist(value - bounds.upperBound) }
  return value
}
