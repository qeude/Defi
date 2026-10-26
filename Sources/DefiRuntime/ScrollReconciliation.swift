import DefiCore
import DefiModel

@discardableResult
public func applyOverviewScrollOffsets(
  _ offsets: [MonitorID: [WorkspaceID: Double]],
  state: inout RuntimeState
) -> Set<MonitorID> {
  var changedMonitorIDs = Set<MonitorID>()
  for monitorIndex in state.monitors.indices {
    let monitorID = state.monitors[monitorIndex].id
    guard let workspaceOffsets = offsets[monitorID] else { continue }
    for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
      let workspaceID = state.monitors[monitorIndex].workspaces[workspaceIndex].id
      guard let offset = workspaceOffsets[workspaceID], offset.isFinite else { continue }
      let workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
      guard workspace.scrollOffset != offset || workspace.targetScrollOffset != offset else {
        continue
      }
      state.monitors[monitorIndex].workspaces[workspaceIndex].scrollOffset = offset
      state.monitors[monitorIndex].workspaces[workspaceIndex].targetScrollOffset = offset
      changedMonitorIDs.insert(monitorID)
    }
  }
  return changedMonitorIDs
}

/// Splits stacks that no longer fit their monitor; a no-op when all fit.
@discardableResult
public func separateInfeasibleStacks(
  state: inout RuntimeState,
  viewports: [MonitorID: Rect]
) -> Bool {
  var changed = false
  for monitorIndex in state.monitors.indices {
    let monitorID = state.monitors[monitorIndex].id
    guard let viewport = viewports[monitorID] else { continue }
    // A workspace migrated after display loss keeps its stacks for when it returns.
    for workspaceIndex in state.monitors[monitorIndex].workspaces.indices
    where state.monitors[monitorIndex].workspaces[workspaceIndex].affinity.map({ $0 == monitorID }) ?? true {
      changed =
        separateInfeasibleStacks(
          in: &state.monitors[monitorIndex].workspaces[workspaceIndex],
          viewport: viewport,
          windowsByID: state.windows,
          settings: state.layout,
          excludingWindowIDs: state.nativeFullscreenWindowIDs
        ) || changed
    }
  }
  return changed
}

public func synchronizeScrollOffsets(
  state: inout RuntimeState,
  viewports: [MonitorID: Rect]
) {
  // Every command, snapshot, display and config reconciliation passes here, so
  // stacks converge everywhere without touching each caller.
  separateInfeasibleStacks(state: &state, viewports: viewports)
  for monitorIndex in state.monitors.indices {
    let monitorID = state.monitors[monitorIndex].id
    guard let viewport = viewports[monitorID] else { continue }
    for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
      let workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
      let windows = workspace.columns
        .flatMap(\.windows)
        .compactMap { state.windows[$0] }
      let target = focusedColumnScrollTarget(
        workspace: workspace,
        viewport: viewport,
        windows: windows,
        settings: state.layout
      )
      state.monitors[monitorIndex].workspaces[workspaceIndex].targetScrollOffset =
        target.offset
      state.monitors[monitorIndex].workspaces[workspaceIndex].scrollFocus = target.focus
    }
  }
}

@discardableResult
public func learnTiledWindowWidth(
  _ windowID: WindowID,
  actualFrame: Rect,
  state: inout RuntimeState,
  viewports: [MonitorID: Rect]
) -> Bool {
  // A frame that already matches its bounded target carries no user width.
  guard let bounded = tiledWindowWidthLearning(
    windowID,
    actualFrame: actualFrame,
    state: state,
    viewports: viewports
  ) else { return false }
  // The real frame proves the window accepts this width; drop only contradicted bounds,
  // even when the column already has this width.
  // Bounds are the window's own width; the layout adds its column's gaps.
  if let minimum = state.windows[windowID]?.minimumTiledWidth, actualFrame.width < minimum - 0.5 {
    state.windows[windowID]?.minimumTiledWidth = nil
  }
  if let maximum = state.windows[windowID]?.maximumTiledWidth, actualFrame.width > maximum + 0.5 {
    state.windows[windowID]?.maximumTiledWidth = nil
  }
  // Ignore the window's own bounds so the gap allowance maps the observed frame to its slot.
  var unbounded = state
  unbounded.monitors[bounded.monitorIndex].workspaces[bounded.workspaceIndex]
    .columns[bounded.columnIndex].width = .pixels(bounded.requestedWidth)
  unbounded.windows[windowID]?.minimumTiledWidth = nil
  unbounded.windows[windowID]?.maximumTiledWidth = nil
  // The user chose this width: a settled snap is stale, and an app that does snap
  // settles again after the next write.
  unbounded.windows[windowID]?.tiledSizeAcceptance = nil
  guard let learned = tiledWindowWidthLearning(
    windowID,
    actualFrame: actualFrame,
    state: unbounded,
    viewports: viewports
  ) else { return false }
  state.windows[windowID]?.tiledSizeAcceptance = nil
  state.monitors[learned.monitorIndex].workspaces[learned.workspaceIndex]
    .columns[learned.columnIndex].width = .pixels(learned.width)
  // A dragged left edge keeps the window where it was released: the ribbon before it
  // scrolls by the same amount, as the overlay showed during the drag.
  let leftEdgeShift = learned.targetX - actualFrame.x
  if abs(leftEdgeShift) >= 1,
    let viewport = viewports[state.monitors[learned.monitorIndex].id]
  {
    state.monitors[learned.monitorIndex].workspaces[learned.workspaceIndex].scrollOffset +=
      leftEdgeShift / stripViewport(viewport, settings: state.layout).width
  }
  synchronizeScrollOffsets(state: &state, viewports: viewports)
  return true
}

@discardableResult
public func learnTiledWindowWidthConstraint(
  _ windowID: WindowID,
  actualFrame: Rect,
  state: inout RuntimeState,
  viewports: [MonitorID: Rect]
) -> Bool {
  guard let learned = tiledWindowWidthLearning(
    windowID,
    actualFrame: actualFrame,
    state: state,
    viewports: viewports
  ) else { return false }
  // Bounds are the window's own width; the layout adds its column's gaps.
  let width = actualFrame.width
  if learned.width > learned.requestedWidth + 0.5,
    width > (state.windows[windowID]?.minimumTiledWidth ?? 0) + 0.5
  {
    state.windows[windowID]?.minimumTiledWidth = width
    if let maximum = state.windows[windowID]?.maximumTiledWidth,
      maximum < width
    {
      state.windows[windowID]?.maximumTiledWidth = nil
    }
  } else if learned.width < learned.requestedWidth - 0.5,
    width < (state.windows[windowID]?.maximumTiledWidth ?? .infinity) - 0.5
  {
    state.windows[windowID]?.maximumTiledWidth = width
    if let minimum = state.windows[windowID]?.minimumTiledWidth,
      minimum > width
    {
      state.windows[windowID]?.minimumTiledWidth = nil
    }
  } else {
    return false
  }
  synchronizeScrollOffsets(state: &state, viewports: viewports)
  return true
}

private func tiledWindowWidthLearning(
  _ windowID: WindowID,
  actualFrame: Rect,
  state: RuntimeState,
  viewports: [MonitorID: Rect]
) -> (
  monitorIndex: Int,
  workspaceIndex: Int,
  columnIndex: Int,
  requestedWidth: Double,
  width: Double,
  targetX: Double
)? {
  guard state.windows[windowID]?.intrinsicSize != true else { return nil }
  for monitorIndex in state.monitors.indices {
    let monitorID = state.monitors[monitorIndex].id
    guard let viewport = viewports[monitorID] else { continue }
    for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
      let workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
      guard
        let columnIndex = workspace.columns.firstIndex(
          where: { $0.windows.contains(windowID) }
        )
      else {
        continue
      }
      guard workspace.id == state.monitors[monitorIndex].activeWorkspace,
        workspace.columns[columnIndex].preMaximizedWidth == nil
      else {
        return nil
      }

      let windows = workspace.columns
        .flatMap(\.windows)
        .compactMap { state.windows[$0] }
      let target = computeLayout(
        workspace: workspace,
        viewport: viewport,
        windows: windows,
        settings: state.layout,
        excludingWindowIDs: state.nativeFullscreenWindowIDs
      ).first(where: { $0.windowID == windowID })?.frame
      guard let target else { return nil }

      let configuredSlotWidth: Double
      switch workspace.columns[columnIndex].width {
      case .fraction(let fraction):
        configuredSlotWidth = stripViewport(viewport, settings: state.layout).width * fraction
      case .pixels(let width):
        configuredSlotWidth = width
      }
      let gaps = horizontalGaps(settings: state.layout)
      let minimumTiledWidth = workspace.columns[columnIndex].windows.compactMap {
        state.windows[$0]?.minimumTiledWidth
      }.max().map { $0 + gaps } ?? 0
      let maximumTiledWidths = workspace.columns[columnIndex].windows.compactMap {
        state.windows[$0]?.maximumTiledWidth
      }
      let maximumTiledWidth =
        maximumTiledWidths.count == workspace.columns[columnIndex].windows.count
        ? maximumTiledWidths.max().map { $0 + gaps }
        : nil
      let currentSlotWidth = max(
        min(configuredSlotWidth, maximumTiledWidth ?? configuredSlotWidth),
        minimumTiledWidth
      )
      let learnedWidth = max(currentSlotWidth + actualFrame.width - target.width, 80)
      guard abs(learnedWidth - currentSlotWidth) >= 1 else { return nil }
      return (
        monitorIndex,
        workspaceIndex,
        columnIndex,
        currentSlotWidth,
        learnedWidth,
        target.x
      )
    }
  }
  return nil
}
