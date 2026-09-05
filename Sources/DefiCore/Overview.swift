import DefiModel

public struct OverviewPoint: Equatable, Sendable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

public struct OverviewSnapshot: Equatable, Sendable {
  public let monitors: [Monitor]
  public let monitorFrames: [MonitorID: Rect]
  public let windows: [WindowID: Window]
  public let floatingFrames: [WindowID: Rect]
  public let activeMonitorID: MonitorID?
  public let nativeFullscreenWindowIDs: Set<WindowID>

  public init(
    monitors: [Monitor],
    monitorFrames: [MonitorID: Rect],
    windows: [WindowID: Window],
    floatingFrames: [WindowID: Rect] = [:],
    activeMonitorID: MonitorID? = nil,
    nativeFullscreenWindowIDs: Set<WindowID> = []
  ) {
    self.monitors = monitors
    self.monitorFrames = monitorFrames
    self.windows = windows
    self.floatingFrames = floatingFrames
    self.activeMonitorID = activeMonitorID
    self.nativeFullscreenWindowIDs = nativeFullscreenWindowIDs
  }
}

public struct OverviewViewport: Equatable, Sendable {
  public var workspaceOffset: Double
  public var horizontalOffsets: [WorkspaceID: Double]

  public init(
    workspaceOffset: Double = 0,
    horizontalOffsets: [WorkspaceID: Double] = [:]
  ) {
    self.workspaceOffset = workspaceOffset
    self.horizontalOffsets = horizontalOffsets
  }
}

public func overviewWorkspaceStride(
  boundsHeight: Double,
  zoom: Double = 0.5,
  workspaceGap: Double = 28
) -> Double {
  max((boundsHeight - workspaceGap * 2) * zoom, 1) + workspaceGap
}

public func interpolateOverviewViewport(
  from: OverviewViewport,
  to: OverviewViewport,
  progress: Double
) -> OverviewViewport {
  let progress = min(max(progress, 0), 1)
  let workspaceOffset = from.workspaceOffset
    + (to.workspaceOffset - from.workspaceOffset) * progress
  var horizontalOffsets: [WorkspaceID: Double] = [:]
  for workspaceID in Set(from.horizontalOffsets.keys).union(to.horizontalOffsets.keys) {
    let start = from.horizontalOffsets[workspaceID] ?? to.horizontalOffsets[workspaceID] ?? 0
    let end = to.horizontalOffsets[workspaceID] ?? start
    horizontalOffsets[workspaceID] = start + (end - start) * progress
  }
  return OverviewViewport(
    workspaceOffset: workspaceOffset,
    horizontalOffsets: horizontalOffsets
  )
}

public func overviewProjectionResizesExistingCards(
  from: OverviewProjection, to: OverviewProjection
) -> Bool {
  guard from.monitorID == to.monitorID else { return false }
  let previous = Dictionary(uniqueKeysWithValues:
    from.workspaces.flatMap(\.windows).map { ($0.windowID, $0.frame) })
  return to.workspaces.flatMap(\.windows).contains { card in
    guard let frame = previous[card.windowID] else { return false }
    return frame.width != card.frame.width || frame.height != card.frame.height
  }
}

public func interpolateOverviewProjection(
  from: OverviewProjection,
  to: OverviewProjection,
  progress: Double,
  foregroundWindowID: WindowID? = nil
) -> OverviewProjection {
  guard from.monitorID == to.monitorID else { return to }
  let progress = min(max(progress, 0), 1)
  let sourceWorkspaces = Dictionary(
    uniqueKeysWithValues: from.workspaces.map { ($0.workspaceID, $0) }
  )
  let sourceWindows = Dictionary(
    uniqueKeysWithValues: from.workspaces.flatMap(\.windows).map { ($0.windowID, $0) }
  )
  let sourceWorkspaceID = from.workspaces.first(where: { workspace in
    workspace.windows.contains(where: { $0.windowID == foregroundWindowID })
  })?.workspaceID
  let targetWorkspaceID = to.workspaces.first(where: { workspace in
    workspace.windows.contains(where: { $0.windowID == foregroundWindowID })
  })?.workspaceID
  let overlayWindowID = sourceWorkspaceID != targetWorkspaceID
    ? foregroundWindowID
    : nil
  return OverviewProjection(
    monitorID: to.monitorID,
    workspaces: to.workspaces.map { targetWorkspace in
      guard let sourceWorkspace = sourceWorkspaces[targetWorkspace.workspaceID]
      else { return targetWorkspace }
      var windows = targetWorkspace.windows.map { targetWindow in
        guard let sourceWindow = sourceWindows[targetWindow.windowID]
        else { return targetWindow }
        return OverviewWindowProjection(
          windowID: targetWindow.windowID,
          frame: interpolateOverviewRect(
            from: sourceWindow.frame,
            to: targetWindow.frame,
            progress: progress
          ),
          layer: targetWindow.layer,
          isNativeFullscreen: targetWindow.isNativeFullscreen,
          canDrag: targetWindow.canDrag
        )
      }
      if let foregroundWindowID,
        let index = windows.firstIndex(where: { $0.windowID == foregroundWindowID })
      {
        windows.append(windows.remove(at: index))
      }
      return OverviewWorkspaceProjection(
        workspaceID: targetWorkspace.workspaceID,
        label: targetWorkspace.label,
        frame: interpolateOverviewRect(
          from: sourceWorkspace.frame,
          to: targetWorkspace.frame,
          progress: progress
        ),
        visibleFrame: interpolateOverviewRect(
          from: sourceWorkspace.visibleFrame,
          to: targetWorkspace.visibleFrame,
          progress: progress
        ),
        windows: windows,
        hiddenTiledWindowCountBefore: targetWorkspace.hiddenTiledWindowCountBefore,
        hiddenTiledWindowCountAfter: targetWorkspace.hiddenTiledWindowCountAfter
      )
    },
    overlayWindowID: overlayWindowID
  )
}

private func interpolateOverviewRect(
  from: Rect,
  to: Rect,
  progress: Double
) -> Rect {
  Rect(
    x: from.x + (to.x - from.x) * progress,
    y: from.y + (to.y - from.y) * progress,
    width: from.width + (to.width - from.width) * progress,
    height: from.height + (to.height - from.height) * progress
  )
}

public struct OverviewProjection: Equatable, Sendable {
  public let monitorID: MonitorID
  public let workspaces: [OverviewWorkspaceProjection]
  public let overlayWindowID: WindowID?

  public init(
    monitorID: MonitorID,
    workspaces: [OverviewWorkspaceProjection],
    overlayWindowID: WindowID? = nil
  ) {
    self.monitorID = monitorID
    self.workspaces = workspaces
    self.overlayWindowID = overlayWindowID
  }

  public func hitTest(_ point: OverviewPoint) -> OverviewHit? {
    if let overlayWindowID,
      let workspace = workspaces.first(where: { workspace in
        workspace.windows.contains(where: { $0.windowID == overlayWindowID })
      }),
      let window = workspace.windows.first(where: {
        $0.windowID == overlayWindowID && $0.frame.contains(point)
      })
    {
      return .window(
        windowID: window.windowID,
        monitorID: monitorID,
        workspaceID: workspace.workspaceID
      )
    }
    for workspace in workspaces.reversed() {
      for window in workspace.windows.reversed()
      where window.frame.contains(point) && workspace.frame.contains(point) {
        return .window(
          windowID: window.windowID,
          monitorID: monitorID,
          workspaceID: workspace.workspaceID
        )
      }
      if workspace.frame.contains(point) {
        return .workspace(monitorID: monitorID, workspaceID: workspace.workspaceID)
      }
    }
    return nil
  }
}

public struct OverviewWorkspaceProjection: Equatable, Sendable {
  public let workspaceID: WorkspaceID
  public let label: String
  public let frame: Rect
  public let visibleFrame: Rect
  public let windows: [OverviewWindowProjection]
  public let hiddenTiledWindowCountBefore: Int
  public let hiddenTiledWindowCountAfter: Int

  public init(
    workspaceID: WorkspaceID,
    label: String? = nil,
    frame: Rect,
    visibleFrame: Rect? = nil,
    windows: [OverviewWindowProjection],
    hiddenTiledWindowCountBefore: Int = 0,
    hiddenTiledWindowCountAfter: Int = 0
  ) {
    self.workspaceID = workspaceID
    self.label = label ?? workspaceID.rawValue
    self.frame = frame
    self.visibleFrame = visibleFrame ?? frame
    self.windows = windows
    self.hiddenTiledWindowCountBefore = hiddenTiledWindowCountBefore
    self.hiddenTiledWindowCountAfter = hiddenTiledWindowCountAfter
  }
}

public enum OverviewWindowLayer: Equatable, Sendable {
  case tiled(columnIndex: Int, windowIndex: Int)
  case floating
}

public struct OverviewWindowProjection: Equatable, Sendable {
  public let windowID: WindowID
  public let frame: Rect
  public let layer: OverviewWindowLayer
  public let isNativeFullscreen: Bool
  public let canDrag: Bool

  public init(
    windowID: WindowID,
    frame: Rect,
    layer: OverviewWindowLayer,
    isNativeFullscreen: Bool,
    canDrag: Bool
  ) {
    self.windowID = windowID
    self.frame = frame
    self.layer = layer
    self.isNativeFullscreen = isNativeFullscreen
    self.canDrag = canDrag
  }
}

public enum OverviewHit: Equatable, Sendable {
  case window(windowID: WindowID, monitorID: MonitorID, workspaceID: WorkspaceID)
  case workspace(monitorID: MonitorID, workspaceID: WorkspaceID)
}

public enum OverviewDropTarget: Equatable, Sendable {
  case newColumn(
    monitorID: MonitorID,
    workspaceID: WorkspaceID,
    columnIndex: Int
  )
  case stack(
    monitorID: MonitorID,
    workspaceID: WorkspaceID,
    columnIndex: Int,
    windowIndex: Int
  )
  case floating(
    monitorID: MonitorID,
    workspaceID: WorkspaceID,
    relativeFrame: Rect
  )
}

public func projectOverview(
  snapshot: OverviewSnapshot,
  monitorID: MonitorID,
  bounds: Rect,
  viewport: OverviewViewport,
  layout: LayoutSettings,
  zoom: Double = 0.5,
  workspaceGap: Double = 28
) -> OverviewProjection {
  guard let monitor = snapshot.monitors.first(where: { $0.id == monitorID }),
    let monitorFrame = snapshot.monitorFrames[monitorID],
    monitorFrame.width > 0,
    monitorFrame.height > 0,
    let activeIndex = monitor.workspaces.firstIndex(where: {
      $0.id == monitor.activeWorkspace
    })
  else {
    return OverviewProjection(monitorID: monitorID, workspaces: [])
  }

  let workspaceWidth = bounds.width
  let stride = overviewWorkspaceStride(
    boundsHeight: bounds.height,
    zoom: zoom,
    workspaceGap: workspaceGap
  )
  let workspaceHeight = stride - workspaceGap
  let contentScale = workspaceHeight / monitorFrame.height
  let projectionBounds = Rect(
    x: bounds.x,
    y: bounds.y - stride,
    width: bounds.width,
    height: bounds.height + stride * 2
  )
  let windows = Array(snapshot.windows.values)
  var projected: [OverviewWorkspaceProjection] = []

  for (workspaceIndex, originalWorkspace) in monitor.workspaces.enumerated() {
    let centerY = bounds.y + bounds.height / 2
      + (Double(workspaceIndex - activeIndex) - viewport.workspaceOffset) * stride
    let workspaceFrame = Rect(
      x: bounds.x,
      y: centerY - workspaceHeight / 2,
      width: workspaceWidth,
      height: workspaceHeight
    )
    guard workspaceFrame.intersects(projectionBounds) else { continue }

    var workspace = originalWorkspace
    workspace.scrollOffset = viewport.horizontalOffsets[workspace.id]
      ?? originalWorkspace.scrollOffset
    let sourceViewport = Rect(
      x: 0,
      y: 0,
      width: monitorFrame.width,
      height: monitorFrame.height
    )
    let tiledFrames = Dictionary(
      uniqueKeysWithValues: computeLayout(
        workspace: workspace,
        viewport: sourceViewport,
        windows: windows,
        settings: layout
      ).map { ($0.windowID, $0.frame) }
    )
    let visibleFrame = Rect(
      x: workspaceFrame.x
        + (workspaceFrame.width - monitorFrame.width * contentScale) / 2,
      y: workspaceFrame.y,
      width: monitorFrame.width * contentScale,
      height: workspaceFrame.height
    )
    let tiledTarget = Rect(
      x: visibleFrame.x,
      y: visibleFrame.y,
      width: workspaceFrame.width,
      height: workspaceFrame.height
    )
    var projectedWindows: [OverviewWindowProjection] = []
    var hiddenTiledWindowCountBefore = 0
    var hiddenTiledWindowCountAfter = 0

    for (columnIndex, column) in originalWorkspace.columns.enumerated() {
      for (windowIndex, windowID) in column.windows.enumerated() {
        guard let frame = tiledFrames[windowID] else { continue }
        let projectedFrame = transform(
          frame,
          from: sourceViewport,
          to: tiledTarget,
          scale: contentScale
        )
        if projectedFrame.x + projectedFrame.width <= workspaceFrame.x {
          hiddenTiledWindowCountBefore += 1
          continue
        }
        if projectedFrame.x >= workspaceFrame.x + workspaceFrame.width {
          hiddenTiledWindowCountAfter += 1
          continue
        }
        guard projectedFrame.intersects(workspaceFrame) else { continue }
        let isFullscreen = snapshot.nativeFullscreenWindowIDs.contains(windowID)
        projectedWindows.append(
          OverviewWindowProjection(
            windowID: windowID,
            frame: projectedFrame,
            layer: .tiled(columnIndex: columnIndex, windowIndex: windowIndex),
            isNativeFullscreen: isFullscreen,
            canDrag: !isFullscreen && snapshot.windows[windowID]?.transientOwnerID == nil
          )
        )
      }
    }

    for windowID in originalWorkspace.floatingWindows {
      guard let frame = snapshot.floatingFrames[windowID] ?? snapshot.windows[windowID]?.frame
      else { continue }
      let localFrame = Rect(
        x: frame.x - monitorFrame.x,
        y: frame.y - monitorFrame.y,
        width: frame.width,
        height: frame.height
      )
      let projectedFrame = Rect(
        x: visibleFrame.x + localFrame.x * contentScale,
        y: visibleFrame.y + localFrame.y * contentScale,
        width: localFrame.width * contentScale,
        height: localFrame.height * contentScale
      )
      guard projectedFrame.intersects(workspaceFrame) else { continue }
      let isFullscreen = snapshot.nativeFullscreenWindowIDs.contains(windowID)
      projectedWindows.append(
        OverviewWindowProjection(
          windowID: windowID,
          frame: projectedFrame,
          layer: .floating,
          isNativeFullscreen: isFullscreen,
          canDrag: !isFullscreen && snapshot.windows[windowID]?.transientOwnerID == nil
        )
      )
    }

    projected.append(
      OverviewWorkspaceProjection(
        workspaceID: originalWorkspace.id,
        label: originalWorkspace.name
          ?? (originalWorkspace.kind == .trailing ? "+" : String(workspaceIndex + 1)),
        frame: workspaceFrame,
        visibleFrame: visibleFrame,
        windows: projectedWindows,
        hiddenTiledWindowCountBefore: hiddenTiledWindowCountBefore,
        hiddenTiledWindowCountAfter: hiddenTiledWindowCountAfter
      )
    )
  }

  return OverviewProjection(monitorID: monitorID, workspaces: projected)
}

public func overviewDropTarget(
  at point: OverviewPoint,
  sourceWindowID: WindowID,
  projection: OverviewProjection,
  snapshot: OverviewSnapshot
) -> OverviewDropTarget? {
  guard let workspaceProjection = projection.workspaces.last(where: {
    $0.frame.contains(point)
  }),
    let monitor = snapshot.monitors.first(where: {
      $0.id == projection.monitorID
    }),
    let workspace = monitor.workspaces.first(where: {
      $0.id == workspaceProjection.workspaceID
    }),
    let sourceWindow = snapshot.windows[sourceWindowID]
  else { return nil }

  let sourceIsFloating = snapshot.monitors.contains { monitor in
    monitor.workspaces.contains { $0.floatingWindows.contains(sourceWindowID) }
  }
  if sourceIsFloating {
    guard let monitorFrame = snapshot.monitorFrames[projection.monitorID],
      workspaceProjection.frame.width > 0,
      workspaceProjection.frame.height > 0
    else { return nil }
    let sourceFrame = snapshot.floatingFrames[sourceWindowID] ?? sourceWindow.frame
    let scale = workspaceProjection.frame.height / monitorFrame.height
    let width = max(sourceFrame.width * scale, 1)
    let height = max(sourceFrame.height * scale, 1)
    let horizontalRange = max(workspaceProjection.visibleFrame.width - width, 1)
    let verticalRange = max(workspaceProjection.visibleFrame.height - height, 1)
    let relativeWidth = min(sourceFrame.width / monitorFrame.width, 1)
    let relativeHeight = min(sourceFrame.height / monitorFrame.height, 1)
    return .floating(
      monitorID: projection.monitorID,
      workspaceID: workspace.id,
      relativeFrame: Rect(
        x: min(max(
          (point.x - workspaceProjection.visibleFrame.x - width / 2) / horizontalRange,
          0
        ), 1) * (1 - relativeWidth),
        y: min(max(
          (point.y - workspaceProjection.visibleFrame.y - height / 2) / verticalRange,
          0
        ), 1) * (1 - relativeHeight),
        width: relativeWidth,
        height: relativeHeight
      )
    )
  }

  let tiled = workspaceProjection.windows.filter {
    if case .tiled = $0.layer { return true }
    return false
  }
  var columnFrames: [Int: Rect] = [:]
  for window in tiled {
    guard case .tiled(let columnIndex, _) = window.layer else { continue }
    columnFrames[columnIndex] = columnFrames[columnIndex].map {
      union($0, window.frame)
    } ?? window.frame
  }

  guard !columnFrames.isEmpty else {
    return .newColumn(
      monitorID: projection.monitorID,
      workspaceID: workspace.id,
      columnIndex: 0
    )
  }

  for columnIndex in workspace.columns.indices {
    guard let frame = columnFrames[columnIndex] else { continue }
    if point.x < frame.x {
      return .newColumn(
        monitorID: projection.monitorID,
        workspaceID: workspace.id,
        columnIndex: columnIndex
      )
    }
    if point.x <= frame.x + frame.width {
      let newColumnZoneWidth = frame.width / 4
      if point.x <= frame.x + newColumnZoneWidth {
        return .newColumn(
          monitorID: projection.monitorID,
          workspaceID: workspace.id,
          columnIndex: columnIndex
        )
      }
      if point.x >= frame.x + frame.width - newColumnZoneWidth {
        return .newColumn(
          monitorID: projection.monitorID,
          workspaceID: workspace.id,
          columnIndex: columnIndex + 1
        )
      }
      let windows = tiled.filter {
        if case .tiled(let index, _) = $0.layer { return index == columnIndex }
        return false
      }.sorted { $0.frame.y < $1.frame.y }
      let insertionIndex = windows.firstIndex {
        point.y < $0.frame.y + $0.frame.height / 2
      } ?? windows.count
      return .stack(
        monitorID: projection.monitorID,
        workspaceID: workspace.id,
        columnIndex: columnIndex,
        windowIndex: insertionIndex
      )
    }
  }

  return .newColumn(
    monitorID: projection.monitorID,
    workspaceID: workspace.id,
    columnIndex: workspace.columns.count
  )
}

private func transform(
  _ frame: Rect,
  from source: Rect,
  to target: Rect,
  scale: Double
) -> Rect {
  Rect(
    x: target.x + (frame.x - source.x) * scale,
    y: target.y + (frame.y - source.y) * scale,
    width: frame.width * scale,
    height: frame.height * scale
  )
}

private func union(_ lhs: Rect, _ rhs: Rect) -> Rect {
  let minX = min(lhs.x, rhs.x)
  let minY = min(lhs.y, rhs.y)
  let maxX = max(lhs.x + lhs.width, rhs.x + rhs.width)
  let maxY = max(lhs.y + lhs.height, rhs.y + rhs.height)
  return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

private extension Rect {
  func contains(_ point: OverviewPoint) -> Bool {
    point.x >= x && point.x <= x + width
      && point.y >= y && point.y <= y + height
  }

  func intersects(_ other: Rect) -> Bool {
    x < other.x + other.width && x + width > other.x
      && y < other.y + other.height && y + height > other.y
  }
}
