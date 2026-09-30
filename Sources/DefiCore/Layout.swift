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

  for (columnIndex, column) in workspace.columns.enumerated() {
    let preferredWidth = preferredColumnLayoutWidth(
      column, viewport: viewport, windowsByID: windowsByID
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
    let width = effectiveColumnLayoutWidth(
      column,
      preferredWidth: preferredWidth,
      acceptedSizes: acceptedSizes,
      windowsByID: windowsByID
    )
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
      } else if let window = windowsByID[windowID] {
        let constrainedWidth = max(
          min(width, window.maximumTiledWidth ?? width),
          window.minimumTiledWidth ?? 0
        )
        frame = Rect(
          x: x + (width - constrainedWidth) / 2,
          y: slot.y,
          width: constrainedWidth,
          height: height
        )
      } else {
        frame = slot
      }

      var target = applyGaps(
        frame,
        columnIndex: columnIndex,
        columnCount: workspace.columns.count,
        windowIndex: windowIndex,
        windowCount: column.windows.count,
        settings: settings
      )
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

func columnLayoutWidth(
  _ column: Column,
  viewport: Rect,
  windowsByID: [WindowID: Window],
  settings: LayoutSettings,
  columnIndex: Int,
  columnCount: Int
) -> Double {
  let preferredWidth = preferredColumnLayoutWidth(
    column, viewport: viewport, windowsByID: windowsByID
  )
  let acceptedSizes = acceptedTiledSizes(
    column,
    preferredWidth: preferredWidth,
    columnIndex: columnIndex,
    columnCount: columnCount,
    viewport: viewport,
    windowsByID: windowsByID,
    settings: settings
  )
  return effectiveColumnLayoutWidth(
    column,
    preferredWidth: preferredWidth,
    acceptedSizes: acceptedSizes,
    windowsByID: windowsByID
  )
}

private func preferredColumnLayoutWidth(
  _ column: Column,
  viewport: Rect,
  windowsByID: [WindowID: Window]
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
    .max() ?? 0
  let maximumTiledWidths = column.windows
    .compactMap { windowsByID[$0]?.maximumTiledWidth }
  let maximumTiledWidth = maximumTiledWidths.count == column.windows.count
    ? maximumTiledWidths.max()
    : nil
  let requestedWidth: Double
  switch column.width {
  case .fraction(let fraction):
    requestedWidth = viewport.width * fraction
  case .pixels(let width):
    requestedWidth = width
  }
  return max(min(requestedWidth, maximumTiledWidth ?? requestedWidth), minimumTiledWidth)
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
  let height = viewport.height / Double(max(column.windows.count, 1))
  return Dictionary(
    uniqueKeysWithValues: column.windows.enumerated().compactMap { windowIndex, windowID in
      guard let window = windowsByID[windowID], !window.intrinsicSize,
        window.maximumTiledHeight != nil,
        let acceptance = window.tiledSizeAcceptance
      else {
        return nil
      }
      let constrainedWidth = max(
        min(preferredWidth, window.maximumTiledWidth ?? preferredWidth),
        window.minimumTiledWidth ?? 0
      )
      let frame = Rect(
        x: (preferredWidth - constrainedWidth) / 2,
        y: viewport.y + height * Double(windowIndex),
        width: constrainedWidth,
        height: height
      )
      let requested = applyGaps(
        frame,
        columnIndex: columnIndex,
        columnCount: columnCount,
        windowIndex: windowIndex,
        windowCount: column.windows.count,
        settings: settings
      )
      guard abs(requested.width - acceptance.requested.width) < 1,
        abs(requested.height - acceptance.requested.height) < 1
      else {
        return nil
      }
      return (windowID, acceptance)
    }
  )
}

private func effectiveColumnLayoutWidth(
  _ column: Column,
  preferredWidth: Double,
  acceptedSizes: [WindowID: TiledSizeAcceptance],
  windowsByID: [WindowID: Window]
) -> Double {
  guard !column.windows.isEmpty,
    acceptedSizes.count == column.windows.count
  else {
    return preferredWidth
  }
  let minimumTiledWidth = column.windows.lazy
    .compactMap { windowsByID[$0]?.minimumTiledWidth }
    .max() ?? 0
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
