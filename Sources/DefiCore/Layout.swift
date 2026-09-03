import DefiModel
import Foundation

public func computeLayout(
  workspace: Workspace,
  viewport: Rect,
  windows: [Window] = [],
  settings: LayoutSettings,
  excludingWindowIDs: Set<WindowID> = []
) -> LayoutDiff {
  let workspace = workspaceForLayout(
    workspace,
    excludingWindowIDs: excludingWindowIDs
  )
  let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
  var x = viewport.x - workspace.scrollOffset * viewport.width
  var frames: [FrameAssignment] = []

  for (columnIndex, column) in workspace.columns.enumerated() {
    let width = columnLayoutWidth(column, viewport: viewport, windowsByID: windowsByID)
    let height = viewport.height / Double(max(column.windows.count, 1))

    for (windowIndex, windowID) in column.windows.enumerated() {
      let slot = Rect(
        x: x,
        y: viewport.y + height * Double(windowIndex),
        width: width,
        height: height
      )
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
      } else {
        frame = slot
      }

      frames.append(
        FrameAssignment(
          windowID: windowID,
          frame: applyGaps(
            frame,
            columnIndex: columnIndex,
            columnCount: workspace.columns.count,
            windowIndex: windowIndex,
            windowCount: column.windows.count,
            settings: settings
          )
        )
      )
    }
    x += width
  }

  return LayoutDiff(frames: frames)
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

public func diffLayout(
  previous: [FrameAssignment],
  next: [FrameAssignment]
) -> LayoutDiff {
  let previousByWindow = Dictionary(uniqueKeysWithValues: previous.map { ($0.windowID, $0.frame) })
  return LayoutDiff(frames: next.filter { previousByWindow[$0.windowID] != $0.frame })
}

public func planFrameBatch(
  previous: [FrameAssignment],
  next: [FrameAssignment]
) -> FrameBatch {
  let diff = diffLayout(previous: previous, next: next)
  return FrameBatch(
    frames: diff.frames,
    stats: FrameBatchStats(
      plannedWrites: diff.frames.count,
      skippedUnchanged: max(next.count - diff.frames.count, 0)
    )
  )
}

public func snapshotLayout(_ diff: LayoutDiff) -> String {
  diff.frames.map {
    String(
      format: "%llu:%.1f,%.1f,%.1f,%.1f",
      $0.windowID.rawValue,
      $0.frame.x,
      $0.frame.y,
      $0.frame.width,
      $0.frame.height
    )
  }.joined(separator: "\n")
}

func columnLayoutWidth(
  _ column: Column,
  viewport: Rect,
  windowsByID: [WindowID: Window]
) -> Double {
  let intrinsicWidth = column.windows
    .compactMap { windowsByID[$0] }
    .filter(\.intrinsicSize)
    .map { max($0.frame.width, 1) }
    .max()

  if let intrinsicWidth {
    return intrinsicWidth
  }

  let minimumTiledWidth = column.windows
    .compactMap { windowsByID[$0]?.minimumTiledWidth }
    .max() ?? 0
  let maximumTiledWidth = column.windows
    .compactMap { windowsByID[$0]?.maximumTiledWidth }
    .min()
  let requestedWidth: Double
  switch column.width {
  case .fraction(let fraction):
    requestedWidth = viewport.width * fraction
  case .pixels(let width):
    requestedWidth = width
  }
  return max(min(requestedWidth, maximumTiledWidth ?? requestedWidth), minimumTiledWidth)
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
