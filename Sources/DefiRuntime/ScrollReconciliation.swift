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

public func synchronizeScrollOffsets(
  state: inout RuntimeState,
  viewports: [MonitorID: Rect]
) {
  for monitorIndex in state.monitors.indices {
    let monitorID = state.monitors[monitorIndex].id
    guard let viewport = viewports[monitorID] else { continue }
    for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
      let workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
      let windows = workspace.columns
        .flatMap(\.windows)
        .compactMap { state.windows[$0] }
      state.monitors[monitorIndex].workspaces[workspaceIndex].targetScrollOffset =
        focusedColumnTargetScrollOffset(
          workspace: workspace,
          viewport: viewport,
          windows: windows,
          settings: state.layout
        )
    }
  }
}

public func alignFocusedColumnLeft(
  on monitorID: MonitorID,
  state: inout RuntimeState,
  viewports: [MonitorID: Rect]
) {
  guard let monitorIndex = state.monitors.firstIndex(where: { $0.id == monitorID }),
    let viewport = viewports[monitorID],
    let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
      where: { $0.id == state.monitors[monitorIndex].activeWorkspace }
    )
  else {
    return
  }
  let workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
  let windows = workspace.columns
    .flatMap(\.windows)
    .compactMap { state.windows[$0] }
  state.monitors[monitorIndex].workspaces[workspaceIndex].targetScrollOffset =
    focusedColumnRevealScrollOffset(
      workspace: workspace,
      viewport: viewport,
      windows: windows,
      settings: state.layout
    )
}

@discardableResult
public func learnTiledWindowWidth(
  _ windowID: WindowID,
  actualFrame: Rect,
  state: inout RuntimeState,
  viewports: [MonitorID: Rect]
) -> Bool {
  let previousMinimum = state.windows[windowID]?.minimumTiledWidth
  let previousMaximum = state.windows[windowID]?.maximumTiledWidth
  state.windows[windowID]?.minimumTiledWidth = nil
  state.windows[windowID]?.maximumTiledWidth = nil
  guard let learned = tiledWindowWidthLearning(
    windowID,
    actualFrame: actualFrame,
    state: state,
    viewports: viewports
  ) else {
    state.windows[windowID]?.minimumTiledWidth = previousMinimum
    state.windows[windowID]?.maximumTiledWidth = previousMaximum
    return false
  }
  state.monitors[learned.monitorIndex].workspaces[learned.workspaceIndex]
    .columns[learned.columnIndex].width = .pixels(learned.width)
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
  if learned.width > learned.requestedWidth + 0.5,
    learned.width > (state.windows[windowID]?.minimumTiledWidth ?? 0) + 0.5
  {
    state.windows[windowID]?.minimumTiledWidth = learned.width
    if let maximum = state.windows[windowID]?.maximumTiledWidth,
      maximum < learned.width
    {
      state.windows[windowID]?.maximumTiledWidth = nil
    }
  } else if learned.width < learned.requestedWidth - 0.5,
    learned.width < (state.windows[windowID]?.maximumTiledWidth ?? .infinity) - 0.5
  {
    state.windows[windowID]?.maximumTiledWidth = learned.width
    if let minimum = state.windows[windowID]?.minimumTiledWidth,
      minimum > learned.width
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
  width: Double
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
        configuredSlotWidth = viewport.width * fraction
      case .pixels(let width):
        configuredSlotWidth = width
      }
      let minimumTiledWidth = workspace.columns[columnIndex].windows.compactMap {
        state.windows[$0]?.minimumTiledWidth
      }.max() ?? 0
      let maximumTiledWidths = workspace.columns[columnIndex].windows.compactMap {
        state.windows[$0]?.maximumTiledWidth
      }
      let maximumTiledWidth =
        maximumTiledWidths.count == workspace.columns[columnIndex].windows.count
        ? maximumTiledWidths.max()
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
        learnedWidth
      )
    }
  }
  return nil
}
