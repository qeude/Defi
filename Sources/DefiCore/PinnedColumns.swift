import DefiModel

/// The pinned column, keyed by its edge: the first column that claims a pin. One pin at most,
/// so the strip has a single inner edge to clear; a later claim stays in the strip until
/// `normalizeColumnPins` clears it.
public func pinnedColumnIndices(_ columns: [Column]) -> [ColumnPin: Int] {
  guard let index = columns.firstIndex(where: { $0.pin != nil }) else { return [:] }
  return [columns[index].pin!: index]
}

/// True when the workspace holds nothing but its pinned column, which belongs to the monitor
/// and rides whichever workspace is active: the lifecycle counts such a workspace as empty.
public func holdsOnlyPinnedColumn(_ workspace: Workspace) -> Bool {
  workspace.floatingWindows.isEmpty && workspace.columns.allSatisfy { $0.pin != nil }
}

/// Removes the pinned column, keeping the focused column where it is when possible.
public func removePinnedColumn(from workspace: inout Workspace) -> Column? {
  guard let index = pinnedColumnIndices(workspace.columns).values.first else { return nil }
  let column = workspace.columns.remove(at: index)
  if workspace.focusedColumn > index { workspace.focusedColumn -= 1 }
  workspace.focusedColumn = min(workspace.focusedColumn, max(workspace.columns.count - 1, 0))
  return column
}

/// `clearingPinnedEdge` for an offset chosen outside the layout, such as an Overview scroll.
public func clearingPinnedEdge(
  _ offset: Double,
  in workspace: Workspace,
  viewport: Rect,
  windowsByID: [WindowID: Window],
  settings: LayoutSettings
) -> Double {
  clearingPinnedEdge(
    offset, columns: workspace.columns,
    widths: columnWidthsInViewports(
      workspace.columns, viewport: viewport, windowsByID: windowsByID, settings: settings))
}

/// Adds a pinned column at its edge, keeping the focused column, and settles the strip
/// beside it at once so no column straddles its edge.
public func insertPinnedColumn(
  _ column: Column,
  into workspace: inout Workspace,
  settings: LayoutSettings,
  excludingWindowIDs: Set<WindowID> = []
) {
  if column.pin == .left {
    workspace.columns.insert(column, at: 0)
    if workspace.columns.count > 1 { workspace.focusedColumn += 1 }
  } else {
    workspace.columns.append(column)
  }
  repairWorkspaceScroll(&workspace, settings: settings, excludingWindowIDs: excludingWindowIDs)
  workspace.scrollOffset = workspace.targetScrollOffset
}

/// `offset` moved, if needed, so no scrolling column straddles the pinned column's inner
/// edge: macOS cannot clip a window, so one there would cover the pinned column or, parked,
/// leave a hole. The straddling column leaves the view; `keeping` never does.
public func clearingPinnedEdge(
  _ offset: Double,
  columns: [Column],
  widths: [Double],
  keeping: Int? = nil
) -> Double {
  guard let edge = pinnedColumnIndices(columns).keys.first else { return offset }
  let lefts = widths.indices.map { widths.prefix($0).reduce(0, +) }
  let boundary = edge == .left ? offset : offset + 1
  let tolerance = 1e-4
  guard let straddler = widths.indices.first(where: {
    $0 != keeping && widths[$0] > 0
      && lefts[$0] < boundary - tolerance && lefts[$0] + widths[$0] > boundary + tolerance
  }) else { return offset }
  return edge == .left ? lefts[straddler] + widths[straddler] : lefts[straddler] - 1
}

/// The windows of the pinned column, which stay put while the strip scrolls.
public func pinnedWindowIDs(_ columns: [Column]) -> Set<WindowID> {
  Set(pinnedColumnIndices(columns).values.flatMap { columns[$0].windows })
}

/// The widest a pinned column gets, in whole-strip widths, so the strip keeps room to scroll.
public let maximumPinnedColumnFraction = 0.5

/// Each pinned column's width, gaps included. A pinned column resolves its width against the
/// whole strip, up to `maximumPinnedColumnFraction`; the scrolling columns share what it leaves.
func pinnedColumnWidths(
  _ columns: [Column],
  viewport: Rect,
  windowsByID: [WindowID: Window],
  settings: LayoutSettings
) -> [ColumnPin: Double] {
  let limit = stripViewport(viewport, settings: settings).width * maximumPinnedColumnFraction
  return pinnedColumnIndices(columns).mapValues {
    min(
      columnLayoutWidths(
        [columns[$0]], viewport: viewport, windowsByID: windowsByID, settings: settings)[0],
      max(limit, minimumSlotWidth(columns[$0], windowsByID: windowsByID, settings: settings)))
  }
}

/// The part of `viewport` the scrolling columns keep beside the pinned ones. Their
/// fractions and the scroll offset count in its strip.
public func scrollingViewport(
  _ columns: [Column],
  viewport: Rect,
  windowsByID: [WindowID: Window] = [:],
  settings: LayoutSettings
) -> Rect {
  let widths = pinnedColumnWidths(
    columns, viewport: viewport, windowsByID: windowsByID, settings: settings)
  let left = widths[.left] ?? 0
  var scrolling = viewport
  scrolling.x += left
  scrolling.width = max(viewport.width - left - (widths[.right] ?? 0), 1)
  return scrolling
}

/// The width of the strip the columns scroll in, in which scroll offsets count.
public func scrollingStripWidth(
  _ columns: [Column],
  viewport: Rect,
  windowsByID: [WindowID: Window] = [:],
  settings: LayoutSettings
) -> Double {
  stripViewport(
    scrollingViewport(columns, viewport: viewport, windowsByID: windowsByID, settings: settings),
    settings: settings
  ).width
}

/// Each column's slot, gaps included, at the workspace's scroll offset: the pinned column at
/// its edge of the whole strip, the others scrolling beside it.
public func columnSlots(
  _ workspace: Workspace,
  viewport: Rect,
  windowsByID: [WindowID: Window],
  settings: LayoutSettings
) -> [(x: Double, width: Double)] {
  let pins = pinnedColumnIndices(workspace.columns)
  let pinnedWidths = pinnedColumnWidths(
    workspace.columns, viewport: viewport, windowsByID: windowsByID, settings: settings)
  var stripWidths = scrollingColumnWidths(
    workspace.columns, viewport: viewport, windowsByID: windowsByID, settings: settings
  ).makeIterator()
  let wholeStrip = stripViewport(viewport, settings: settings)
  let strip = stripViewport(
    scrollingViewport(workspace.columns, viewport: viewport, windowsByID: windowsByID, settings: settings),
    settings: settings)
  var stripX = strip.x - workspace.scrollOffset * strip.width
  return workspace.columns.indices.map { index in
    if pins[.left] == index, let width = pinnedWidths[.left] { return (wholeStrip.x, width) }
    if pins[.right] == index, let width = pinnedWidths[.right] {
      return (wholeStrip.x + wholeStrip.width - width, width)
    }
    let width = stripWidths.next()!
    defer { stripX += width }
    return (stripX, width)
  }
}

/// The scrolling columns' widths in points, gaps included: their fractions count in the whole
/// strip, as without a pin, and none grows past the room the pinned column leaves.
func scrollingColumnWidths(
  _ columns: [Column],
  viewport: Rect,
  windowsByID: [WindowID: Window],
  settings: LayoutSettings
) -> [Double] {
  let pinned = Set(pinnedColumnIndices(columns).values)
  let room = scrollingStripWidth(columns, viewport: viewport, windowsByID: windowsByID, settings: settings)
  let strip = columns.indices.filter { !pinned.contains($0) }.map { columns[$0] }
  return zip(strip, columnLayoutWidths(strip, viewport: viewport, windowsByID: windowsByID, settings: settings))
    .map { min($1, max(room, minimumSlotWidth($0, windowsByID: windowsByID, settings: settings))) }
}

/// The narrowest slot a column's windows accept, gaps included: a cap never goes below it,
/// or the window would overflow its slot onto its neighbour.
private func minimumSlotWidth(
  _ column: Column, windowsByID: [WindowID: Window], settings: LayoutSettings
) -> Double {
  column.windows.compactMap { windowsByID[$0]?.minimumTiledWidth }.max()
    .map { $0 + horizontalGaps(settings: settings) } ?? 0
}

/// Moves the pinned column to its end of the columns and returns any other claim to the
/// strip, keeping the focused column.
public func normalizeColumnPins(_ workspace: inout Workspace) {
  let pins = pinnedColumnIndices(workspace.columns)
  let order =
    (pins[.left].map { [$0] } ?? [])
    + workspace.columns.indices.filter { !pins.values.contains($0) }
    + (pins[.right].map { [$0] } ?? [])
  let pinned = Set(pins.values)
  guard order != Array(workspace.columns.indices)
    || workspace.columns.indices.contains(where: {
      workspace.columns[$0].pin != nil && !pinned.contains($0)
    })
  else { return }
  workspace.columns = order.map {
    var column = workspace.columns[$0]
    if !pinned.contains($0) { column.pin = nil }
    return column
  }
  workspace.focusedColumn = order.firstIndex(of: workspace.focusedColumn) ?? 0
}

/// Pins the focused column to `edge`, or returns it to the strip when it is already there.
/// A column already at that edge takes the focused column's place in the strip; an
/// unpinned column returns at the edge of the view it was pinned to. The strip keeps
/// its first visible column in place.
public func togglePinnedColumn(
  _ edge: ColumnPin,
  in workspace: inout Workspace,
  viewport: Rect = Rect(x: 0, y: 0, width: 1_000, height: 1),
  windows: [Window] = [],
  settings: LayoutSettings
) throws {
  guard workspace.columns.indices.contains(workspace.focusedColumn) else {
    throw LayoutError.emptyWorkspace
  }
  normalizeColumnPins(&workspace)
  let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
  let visible = visibleStripColumns(workspace, viewport: viewport, windowsByID: windowsByID, settings: settings)
  let pins = pinnedColumnIndices(workspace.columns)
  var slots: [ColumnPin: Column] = pins.mapValues { workspace.columns[$0] }
  var strip = workspace.columns.indices.filter { !pins.values.contains($0) }.map { workspace.columns[$0] }
  // Strip positions of the first and last visible columns.
  let firstVisible = visible.map { visible in strip.firstIndex { $0 == workspace.columns[visible.first] }! }
  let lastVisible = visible.map { visible in strip.firstIndex { $0 == workspace.columns[visible.last] }! }
  var anchor = firstVisible ?? 0
  func insert(_ column: Column, at index: Int) {
    var column = column
    column.pin = nil
    strip.insert(column, at: index)
    if index < anchor { anchor += 1 }
  }
  func returnToStrip(_ column: Column, from pin: ColumnPin) {
    insert(column, at: pin == .left ? anchor : min((lastVisible ?? strip.count - 1) + 1, strip.count))
  }

  var focused = workspace.columns[workspace.focusedColumn]
  if let pin = focused.pin {
    slots[pin] = nil
    if pin == edge {
      returnToStrip(focused, from: pin)
    } else {
      focused.pin = edge
      slots[edge] = focused
    }
  } else {
    let position = strip.firstIndex(of: focused)!
    strip.remove(at: position)
    if position < anchor { anchor -= 1 }
    // The column pinned so far, at either edge, takes the focused column's place.
    for (_, occupant) in slots { insert(occupant, at: position) }
    slots = [:]
    focused.pin = edge
    slots[edge] = focused
  }

  let focusedWindows = focused.windows
  workspace.columns = (slots[.left].map { [$0] } ?? []) + strip + (slots[.right].map { [$0] } ?? [])
  workspace.focusedColumn = workspace.columns.firstIndex { $0.windows == focusedWindows } ?? 0
  let widths = columnWidthsInViewports(
    workspace.columns, viewport: viewport, windowsByID: windowsByID, settings: settings)
  let anchorLeft = strip.indices.contains(anchor)
    ? widths.prefix(workspace.columns.firstIndex(of: strip[anchor])!).reduce(0, +) : 0
  let offset = min(anchorLeft, max(widths.reduce(0, +) - 1, 0))
  workspace.scrollOffset = offset
  workspace.targetScrollOffset = offset
  workspace.targetScrollOffset = focusedColumnTargetScrollOffset(
    workspace: workspace, viewport: viewport, windows: windows, settings: settings)
}

/// The first and last scrolling columns in view at the target offset: fully in view when
/// any is, else partly.
func visibleStripColumns(
  _ workspace: Workspace,
  viewport: Rect,
  windowsByID: [WindowID: Window],
  settings: LayoutSettings
) -> (first: Int, last: Int)? {
  let pinned = Set(pinnedColumnIndices(workspace.columns).values)
  let widths = columnWidthsInViewports(
    workspace.columns, viewport: viewport, windowsByID: windowsByID, settings: settings)
  let offset = workspace.targetScrollOffset
  let lefts = widths.indices.map { widths.prefix($0).reduce(0, +) }
  let strip = workspace.columns.indices.filter { !pinned.contains($0) }
  let full = strip.filter { lefts[$0] >= offset - 1e-9 && lefts[$0] + widths[$0] <= offset + 1 + 1e-9 }
  let partial = strip.filter { lefts[$0] + widths[$0] > offset + 1e-9 && lefts[$0] < offset + 1 - 1e-9 }
  let inView = full.isEmpty ? partial : full
  guard let first = inView.first, let last = inView.last else { return nil }
  return (first, last)
}
