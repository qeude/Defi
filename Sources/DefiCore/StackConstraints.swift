import DefiModel
import Foundation

/// Why a vertical stack cannot honour its windows' verified minimum heights.
public struct StackRejection: Error, Equatable, CustomStringConvertible, Sendable {
  public let requiredHeight: Double
  public let availableHeight: Double

  public init(requiredHeight: Double, availableHeight: Double) {
    self.requiredHeight = requiredHeight
    self.availableHeight = availableHeight
  }

  public var description: String {
    // Formatted as Double: a finite minimum read from an app may exceed Int's range.
    "stack needs \(requiredHeight.rounded(.up).formatted(.number.grouping(.never)))pt but only "
      + "\(availableHeight.rounded(.down).formatted(.number.grouping(.never)))pt is available"
  }
}

public enum StackFit: Equatable, Sendable {
  case fits
  case rejected(StackRejection)
}

/// Decides whether `windowIDs` can share one column. A single window always fits:
/// one oversized window keeps the whole viewport and is reported by
/// `oversizedStackWindowIDs` instead of being rejected or split.
public func stackFit(
  _ windowIDs: [WindowID],
  windowsByID: [WindowID: Window],
  viewport: Rect,
  settings: LayoutSettings
) -> StackFit {
  guard windowIDs.count > 1 else { return .fits }
  let required = stackBounds(windowIDs, windowsByID: windowsByID, settings: settings)
    .reduce(0) { $0 + $1.lower }
  return required <= viewport.height + 0.001
    ? .fits
    : .rejected(StackRejection(requiredHeight: required, availableHeight: viewport.height))
}

/// Single-window columns whose verified minimum height exceeds the viewport.
public func oversizedStackWindowIDs(
  in workspace: Workspace,
  windowsByID: [WindowID: Window],
  viewport: Rect,
  settings: LayoutSettings
) -> [WindowID] {
  workspace.columns.compactMap { column in
    guard column.windows.count == 1,
      let bounds = stackBounds(column.windows, windowsByID: windowsByID, settings: settings).first,
      bounds.lower > viewport.height + 0.001
    else { return nil }
    return column.windows[0]
  }
}

/// Slot heights, top to bottom, that sum to `viewport.height`.
///
/// Water-filling: every slot gets the same level, clamped into its window's
/// `[minimum + gaps, maximum + gaps]`; the clamped slots hand their surplus or
/// shortfall to the rest. Without constraints this is exactly `height / count`.
/// When every slot is capped, the surplus is spread evenly (the window is
/// centred in its slot). An infeasible stack falls back to slots proportional
/// to the required heights.
public func stackSlotHeights(
  _ windowIDs: [WindowID],
  windowsByID: [WindowID: Window],
  viewport: Rect,
  settings: LayoutSettings
) -> [Double] {
  let count = windowIDs.count
  guard count > 1 else { return [viewport.height] }
  let bounds = stackBounds(windowIDs, windowsByID: windowsByID, settings: settings)
  let totalLower = bounds.reduce(0) { $0 + $1.lower }
  if totalLower > viewport.height {
    let weights = bounds.map { max($0.lower, 1) }
    let total = weights.reduce(0, +)
    return weights.map { viewport.height * $0 / total }
  }

  var heights = [Double?](repeating: nil, count: count)
  var remaining = viewport.height
  while true {
    let free = heights.indices.filter { heights[$0] == nil }
    guard !free.isEmpty else { break }
    let level = remaining / Double(free.count)
    let tooSmall = free.filter { bounds[$0].lower > level }
    let tooLarge = free.filter { bounds[$0].upper < level }
    if tooSmall.isEmpty, tooLarge.isEmpty {
      free.forEach { heights[$0] = level }
      break
    }
    let shortfall = tooSmall.reduce(0) { $0 + bounds[$1].lower - level }
    let excess = tooLarge.reduce(0) { $0 + level - bounds[$1].upper }
    for index in shortfall > excess ? tooSmall : tooLarge {
      heights[index] = shortfall > excess ? bounds[index].lower : bounds[index].upper
      remaining -= heights[index] ?? 0
    }
  }
  let slots = heights.map { $0 ?? 0 }
  let surplus = (viewport.height - slots.reduce(0, +)) / Double(count)
  return surplus > 0.001 ? slots.map { $0 + surplus } : slots
}

/// Height a non-intrinsic window occupies in its slot: capped at its verified
/// maximum (centred in the surplus) and raised to its verified minimum (top-aligned
/// overflow), so the target matches what the app accepts instead of being retried.
func constrainedStackWindowHeight(
  slotHeight: Double,
  window: Window?,
  windowIndex: Int,
  windowCount: Int,
  settings: LayoutSettings
) -> Double {
  guard let window, !window.intrinsicSize else { return slotHeight }
  let gaps = stackVerticalGaps(windowIndex: windowIndex, windowCount: windowCount, settings: settings)
  let capped = window.maximumTiledHeight.map { min(slotHeight, $0 + gaps) } ?? slotHeight
  return window.minimumTiledHeight.map { max(capped, $0 + gaps) } ?? capped
}

/// `applyGaps` shrinks gaps that exceed half a frame, so the gapped frame can
/// outgrow the slot-level cap; enforce the verified maximum on the final frame.
func cappedStackFrame(_ frame: Rect, window: Window?) -> Rect {
  guard let window, !window.intrinsicSize, let maximum = window.maximumTiledHeight,
    frame.height > maximum
  else { return frame }
  var capped = frame
  capped.y += (frame.height - maximum) / 2
  capped.height = maximum
  return capped
}

private func stackBounds(
  _ windowIDs: [WindowID],
  windowsByID: [WindowID: Window],
  settings: LayoutSettings
) -> [(lower: Double, upper: Double)] {
  windowIDs.enumerated().map { index, windowID in
    let gaps = stackVerticalGaps(windowIndex: index, windowCount: windowIDs.count, settings: settings)
    // `applyGaps` never emits a frame below 1pt, so every slot needs its gaps plus that.
    let floor = 1 + gaps
    guard let window = windowsByID[windowID], !window.intrinsicSize else {
      return (floor, .infinity)
    }
    let lower = window.minimumTiledHeight.map { max($0 + gaps, floor) } ?? floor
    let upper = window.maximumTiledHeight.map { max($0 + gaps, lower) } ?? .infinity
    return (lower, upper)
  }
}

/// Gap space `applyGaps` removes from a slot of this position.
private func stackVerticalGaps(windowIndex: Int, windowCount: Int, settings: LayoutSettings) -> Double {
  let inner = max(settings.innerVerticalGap, 0)
  let top = windowIndex == 0 ? max(settings.outerTopGap, 0) : inner
  let bottom = windowIndex + 1 == windowCount ? max(settings.outerBottomGap, 0) : inner
  return top + bottom
}

/// Splits columns whose windows can no longer share the viewport height.
///
/// Policy: walk each column top to bottom, keep the longest prefix that fits and
/// move the rest, order preserved, into a new column inserted directly to its
/// right; repeat on that column. Greedy contiguous runs give the fewest columns
/// and keep reading order. New columns copy the source width. Focus follows the
/// focused window. When columns are inserted left of the focused column,
/// `scrollOffset` and `targetScrollOffset` grow by their width so visible
/// content stays put. Stacks are never merged back, so growth cannot oscillate,
/// and single windows are never split. Columns holding `excludingWindowIDs`
/// (native fullscreen) are skipped. Callers recompute the scroll target.
@discardableResult
public func separateInfeasibleStacks(
  in workspace: inout Workspace,
  viewport: Rect,
  windowsByID: [WindowID: Window],
  settings: LayoutSettings,
  excludingWindowIDs: Set<WindowID> = []
) -> Bool {
  func fits(_ windowIDs: ArraySlice<WindowID>) -> Bool {
    stackFit(Array(windowIDs), windowsByID: windowsByID, viewport: viewport, settings: settings)
      == .fits
  }

  var insertedLeftOfFocus: [Int] = []
  var changed = false
  var columnIndex = 0
  while columnIndex < workspace.columns.count {
    defer { columnIndex += 1 }
    var column = workspace.columns[columnIndex]
    guard column.windows.count > 1,
      excludingWindowIDs.isDisjoint(with: column.windows),
      !fits(column.windows[...])
    else { continue }

    var runLength = 1
    while runLength < column.windows.count, fits(column.windows[...runLength]) {
      runLength += 1
    }
    var rest = column
    rest.windows.removeFirst(runLength)
    rest.focusedWindow = max(column.focusedWindow - runLength, 0)
    column.windows.removeLast(rest.windows.count)
    column.focusedWindow = min(column.focusedWindow, runLength - 1)

    if columnIndex < workspace.focusedColumn {
      workspace.focusedColumn += 1
      // Later insertions land right of this one, so the index stays final.
      insertedLeftOfFocus.append(columnIndex + 1)
    } else if columnIndex == workspace.focusedColumn,
      workspace.columns[columnIndex].focusedWindow >= runLength
    {
      workspace.focusedColumn += 1
    }
    workspace.columns[columnIndex] = column
    workspace.columns.insert(rest, at: columnIndex + 1)
    changed = true
  }
  guard changed else { return false }

  let shift = insertedLeftOfFocus.reduce(0.0) { total, index in
    total + columnLayoutWidth(
      workspace.columns[index],
      viewport: viewport,
      windowsByID: windowsByID,
      settings: settings,
      columnIndex: index,
      columnCount: workspace.columns.count
    ) / max(viewport.width, 1)
  }
  workspace.scrollOffset += shift
  workspace.targetScrollOffset += shift
  return true
}
