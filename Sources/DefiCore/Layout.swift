import DefiModel
import Foundation

public func computeLayout(
  workspace: Workspace,
  viewport: Rect,
  windows: [Window] = [],
  settings: LayoutSettings,
  excludingWindowIDs: Set<WindowID> = []
) -> [FrameAssignment] {
  let workspace = workspaceForLayout(
    workspace,
    excludingWindowIDs: excludingWindowIDs
  )
  let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
  var x = viewport.x - workspace.scrollOffset * viewport.width
  var frames: [FrameAssignment] = []
  let widths = columnLayoutWidths(
    workspace.columns, viewport: viewport, windowsByID: windowsByID, settings: settings
  )

  for (columnIndex, column) in workspace.columns.enumerated() {
    let gaps = horizontalGaps(columnIndex: columnIndex, columnCount: workspace.columns.count, settings: settings)
    let preferredWidth = preferredColumnLayoutWidth(
      column, viewport: viewport, windowsByID: windowsByID, gaps: gaps
    )
    let acceptedSizes = acceptedTiledSizes(
      column,
      preferredWidth: preferredWidth,
      columnIndex: columnIndex,
      columnCount: workspace.columns.count,
      viewport: viewport,
      windowsByID: windowsByID,
      settings: settings
    )
    let width = widths[columnIndex]
    let heights = stackSlotHeights(
      column.windows, windowsByID: windowsByID, viewport: viewport, settings: settings
    )
    var slotY = viewport.y

    for (windowIndex, windowID) in column.windows.enumerated() {
      let height = heights[windowIndex]
      let slot = Rect(x: x, y: slotY, width: width, height: height)
      slotY += height
      let frame: Rect
      if let window = windowsByID[windowID], window.intrinsicSize {
        let intrinsicWidth = min(max(window.frame.width, 1), width)
        let intrinsicHeight = min(max(window.frame.height, 1), height)
        frame = Rect(
          x: x + (width - intrinsicWidth) / 2,
          y: slot.y + (height - intrinsicHeight) / 2,
          width: intrinsicWidth,
          height: intrinsicHeight
        )
      } else if let window = windowsByID[windowID] {
        let constrainedWidth = max(
          min(width, window.maximumTiledWidth.map { $0 + gaps } ?? width),
          effectiveMinimumTiledWidth(window.minimumTiledWidth.map { $0 + gaps }, requested: width)
        )
        let constrainedHeight = constrainedStackWindowHeight(
          slotHeight: height, window: window, windowIndex: windowIndex,
          windowCount: column.windows.count, settings: settings
        )
        frame = Rect(
          x: x + (width - constrainedWidth) / 2,
          y: slot.y + max(height - constrainedHeight, 0) / 2,
          width: constrainedWidth,
          height: constrainedHeight
        )
      } else {
        frame = slot
      }

      var target = cappedStackFrame(applyGaps(
        frame,
        columnIndex: columnIndex,
        columnCount: workspace.columns.count,
        windowIndex: windowIndex,
        windowCount: column.windows.count,
        settings: settings
      ), window: windowsByID[windowID])
      if let acceptance = acceptedSizes[windowID] {
        target.x += (target.width - acceptance.accepted.width) / 2
        target.y += (target.height - acceptance.accepted.height) / 2
        target.width = acceptance.accepted.width
        target.height = acceptance.accepted.height
      }
      frames.append(FrameAssignment(windowID: windowID, frame: target))
    }
    x += width
  }

  return frames
}

func workspaceForLayout(
  _ workspace: Workspace,
  excludingWindowIDs: Set<WindowID>
) -> Workspace {
  guard !excludingWindowIDs.isEmpty else { return workspace }
  var result = workspace
  var columns: [Column] = []
  var focusedColumn: Int?
  var visibleColumnsBeforeFocus = 0
  for (columnIndex, column) in workspace.columns.enumerated() {
    let windows = column.windows.filter { !excludingWindowIDs.contains($0) }
    guard !windows.isEmpty else { continue }
    if columnIndex < workspace.focusedColumn {
      visibleColumnsBeforeFocus += 1
    }
    var visible = column
    let focusedWindowID =
      column.windows.indices.contains(column.focusedWindow)
      ? column.windows[column.focusedWindow]
      : nil
    visible.windows = windows
    visible.focusedWindow =
      focusedWindowID.flatMap(windows.firstIndex(of:))
      ?? min(
        column.windows.prefix(column.focusedWindow).filter {
          !excludingWindowIDs.contains($0)
        }.count,
        windows.count - 1
      )
    if columnIndex == workspace.focusedColumn {
      focusedColumn = columns.count
    }
    columns.append(visible)
  }
  result.columns = columns
  result.focusedColumn =
    columns.isEmpty
    ? 0
    : min(focusedColumn ?? visibleColumnsBeforeFocus, columns.count - 1)
  return result
}

/// Column widths, gaps included. A column whose windows settled a few points off
/// their request keeps their real width, and the next column, else the previous one,
/// absorbs the difference when it got its own request: gaps stay exact and the
/// columns still span their fractions. Only a column at its preferred width absorbs,
/// so what an absorbing window settles at never feeds back into the layout.
public func columnLayoutWidths(
  _ columns: [Column],
  viewport: Rect,
  windowsByID: [WindowID: Window],
  settings: LayoutSettings
) -> [Double] {
  let sizes = columns.indices.map { columnIndex -> (preferred: Double, width: Double) in
    let gaps = horizontalGaps(columnIndex: columnIndex, columnCount: columns.count, settings: settings)
    let preferredWidth = preferredColumnLayoutWidth(
      columns[columnIndex], viewport: viewport, windowsByID: windowsByID, gaps: gaps
    )
    let acceptedSizes = acceptedTiledSizes(
      columns[columnIndex],
      preferredWidth: preferredWidth,
      columnIndex: columnIndex,
      columnCount: columns.count,
      viewport: viewport,
      windowsByID: windowsByID,
      settings: settings
    )
    return (preferredWidth, effectiveColumnLayoutWidth(
      columns[columnIndex],
      preferredWidth: preferredWidth,
      acceptedSizes: acceptedSizes,
      windowsByID: windowsByID,
      gaps: gaps
    ))
  }
  let absorbs = columns.indices.map { columnIndex in
    sizes[columnIndex].width == sizes[columnIndex].preferred
      && columns[columnIndex].windows.allSatisfy { windowID in
        windowsByID[windowID].map { !$0.intrinsicSize && $0.maximumTiledWidth == nil } ?? true
      }
  }
  var widths = sizes.map(\.width)
  for columnIndex in columns.indices {
    let deviation = sizes[columnIndex].width - sizes[columnIndex].preferred
    guard deviation != 0, abs(deviation) <= tiledWidthRoundingLimit,
      let absorber = [columnIndex + 1, columnIndex - 1].first(where: {
        columns.indices.contains($0) && absorbs[$0]
      })
    else { continue }
    widths[absorber] -= deviation
  }
  return widths
}

private func preferredColumnLayoutWidth(
  _ column: Column,
  viewport: Rect,
  windowsByID: [WindowID: Window],
  gaps: Double
) -> Double {
  let intrinsicWidth = column.windows.lazy
    .compactMap { windowsByID[$0] }
    .filter(\.intrinsicSize)
    .map { max($0.frame.width, 1) }
    .max()

  if let intrinsicWidth {
    return intrinsicWidth
  }

  let minimumTiledWidth = column.windows.lazy
    .compactMap { windowsByID[$0]?.minimumTiledWidth }
    .max().map { $0 + gaps } ?? 0
  let maximumTiledWidths = column.windows
    .compactMap { windowsByID[$0]?.maximumTiledWidth }
  let maximumTiledWidth = maximumTiledWidths.count == column.windows.count
    ? maximumTiledWidths.max().map { $0 + gaps }
    : nil
  let requestedWidth: Double
  switch column.width {
  case .fraction(let fraction):
    requestedWidth = viewport.width * fraction
  case .pixels(let width):
    requestedWidth = width
  }
  return max(min(requestedWidth, maximumTiledWidth ?? requestedWidth),
    effectiveMinimumTiledWidth(minimumTiledWidth, requested: requestedWidth))
}

private func acceptedTiledSizes(
  _ column: Column,
  preferredWidth: Double,
  columnIndex: Int,
  columnCount: Int,
  viewport: Rect,
  windowsByID: [WindowID: Window],
  settings: LayoutSettings
) -> [WindowID: TiledSizeAcceptance] {
  let heights = stackSlotHeights(
    column.windows, windowsByID: windowsByID, viewport: viewport, settings: settings
  )
  let offsets = heights.reduce(into: [0.0]) { $0.append($0.last! + $1) }
  let gaps = horizontalGaps(columnIndex: columnIndex, columnCount: columnCount, settings: settings)
  return Dictionary(
    uniqueKeysWithValues: column.windows.enumerated().compactMap { windowIndex, windowID in
      guard let window = windowsByID[windowID], !window.intrinsicSize,
        let acceptance = window.tiledSizeAcceptance,
        window.maximumTiledHeight != nil || isTiledSizeSnap(acceptance)
      else {
        return nil
      }
      let constrainedWidth = max(
        min(preferredWidth, window.maximumTiledWidth.map { $0 + gaps } ?? preferredWidth),
        effectiveMinimumTiledWidth(window.minimumTiledWidth.map { $0 + gaps }, requested: preferredWidth)
      )
      let frame = Rect(
        x: (preferredWidth - constrainedWidth) / 2,
        y: viewport.y + offsets[windowIndex],
        width: constrainedWidth,
        height: constrainedStackWindowHeight(
          slotHeight: heights[windowIndex], window: window, windowIndex: windowIndex,
          windowCount: column.windows.count, settings: settings
        )
      )
      let requested = cappedStackFrame(applyGaps(
        frame,
        columnIndex: columnIndex,
        columnCount: columnCount,
        windowIndex: windowIndex,
        windowCount: column.windows.count,
        settings: settings
      ), window: window)
      // Moving a column across a gap edge shifts the request by exactly an
      // outer/inner gap difference; the app's clamp is unchanged, so its accepted
      // size still applies. Any other change is a new request.
      let horizontalInner = max(settings.innerHorizontalGap, 0)
      let verticalInner = max(settings.innerVerticalGap, 0)
      let widthShifts = gapEdgeShifts(
        max(settings.outerLeftGap, 0) - horizontalInner,
        max(settings.outerRightGap, 0) - horizontalInner)
      let heightShifts = gapEdgeShifts(
        max(settings.outerTopGap, 0) - verticalInner,
        max(settings.outerBottomGap, 0) - verticalInner)
      let widthDelta = requested.width - acceptance.requested.width
      let heightDelta = requested.height - acceptance.requested.height
      guard widthShifts.contains(where: { abs(widthDelta - $0) < 1 }),
        heightShifts.contains(where: { abs(heightDelta - $0) < 1 })
      else {
        return nil
      }
      return (windowID, TiledSizeAcceptance(requested: requested, accepted: acceptance.accepted))
    }
  )
}

/// Request changes a window sees only by gaining or losing outer gap edges.
private func gapEdgeShifts(_ first: Double, _ second: Double) -> [Double] {
  [0, first, second, first + second, first - second].flatMap { [$0, -$0] }
}

private func effectiveColumnLayoutWidth(
  _ column: Column,
  preferredWidth: Double,
  acceptedSizes: [WindowID: TiledSizeAcceptance],
  windowsByID: [WindowID: Window],
  gaps: Double
) -> Double {
  guard !column.windows.isEmpty,
    acceptedSizes.count == column.windows.count
  else {
    return preferredWidth
  }
  let minimumTiledWidth = effectiveMinimumTiledWidth(
    column.windows.lazy.compactMap { windowsByID[$0]?.minimumTiledWidth }.max().map { $0 + gaps },
    requested: preferredWidth)
  let contraction = column.windows.compactMap { acceptedSizes[$0] }
    .map { $0.requested.width - $0.accepted.width }
    .min() ?? 0
  return max(preferredWidth - contraction, minimumTiledWidth)
}

private func applyGaps(
  _ rect: Rect,
  columnIndex: Int,
  columnCount: Int,
  windowIndex: Int,
  windowCount: Int,
  settings: LayoutSettings
) -> Rect {
  let horizontalInner = max(settings.innerHorizontalGap, 0)
  let verticalInner = max(settings.innerVerticalGap, 0)
  let left = columnIndex == 0 ? max(settings.outerLeftGap, 0) : horizontalInner
  let right = columnIndex + 1 == columnCount ? max(settings.outerRightGap, 0) : horizontalInner
  let top = windowIndex == 0 ? max(settings.outerTopGap, 0) : verticalInner
  let bottom = windowIndex + 1 == windowCount ? max(settings.outerBottomGap, 0) : verticalInner

  let maxHorizontal = max((rect.width - 1) / 2, 0)
  let maxVertical = max((rect.height - 1) / 2, 0)
  let clampedLeft = min(left, maxHorizontal)
  let clampedRight = min(right, maxHorizontal)
  let clampedTop = min(top, maxVertical)
  let clampedBottom = min(bottom, maxVertical)

  return Rect(
    x: rect.x + clampedLeft,
    y: rect.y + clampedTop,
    width: max(rect.width - clampedLeft - clampedRight, 1),
    height: max(rect.height - clampedTop - clampedBottom, 1)
  )
}

/// Width bounds are the window's own; its column also holds the gaps beside it.
public func horizontalGaps(columnIndex: Int, columnCount: Int, settings: LayoutSettings) -> Double {
  let inner = max(settings.innerHorizontalGap, 0)
  return (columnIndex == 0 ? max(settings.outerLeftGap, 0) : inner)
    + (columnIndex + 1 == columnCount ? max(settings.outerRightGap, 0) : inner)
}

/// Up to this many points off its request is an app snapping its size, never a width
/// constraint: its column takes the real width and a neighbour absorbs the difference.
public let tiledWidthRoundingLimit = 16.0

/// Whether an app settled a few points off its request, as when snapping to whole cells.
public func isTiledSizeSnap(_ acceptance: TiledSizeAcceptance) -> Bool {
  abs(acceptance.accepted.width - acceptance.requested.width) <= tiledWidthRoundingLimit
    && abs(acceptance.accepted.height - acceptance.requested.height) <= tiledWidthRoundingLimit
}

/// A learned minimum width only binds beyond rounding: a window that merely rounds a
/// request up must not widen its column past the share it was given.
public func effectiveMinimumTiledWidth(_ minimum: Double?, requested: Double) -> Double {
  guard let minimum, minimum > requested + tiledWidthRoundingLimit else { return 0 }
  return minimum
}
