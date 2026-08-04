import DefiCore
import DefiModel

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
          centerFocusedColumn: state.layout.centerFocusedColumn
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
      windows: windows
    )
}

@discardableResult
public func learnTiledWindowWidth(
  _ windowID: WindowID,
  actualFrame: Rect,
  state: inout RuntimeState,
  viewports: [MonitorID: Rect]
) -> Bool {
  guard state.windows[windowID]?.intrinsicSize != true else { return false }

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
        workspace.columns[columnIndex].fullscreenPreviousWidth == nil
      else {
        return false
      }

      let windows = workspace.columns
        .flatMap(\.windows)
        .compactMap { state.windows[$0] }
      let target = computeLayout(
        workspace: workspace,
        viewport: viewport,
        windows: windows,
        settings: state.layout
      ).frames.first(where: { $0.windowID == windowID })?.frame
      guard let target else { return false }

      let currentSlotWidth: Double
      switch workspace.columns[columnIndex].width {
      case .fraction(let fraction):
        currentSlotWidth = viewport.width * fraction
      case .pixels(let width):
        currentSlotWidth = width
      }
      let learnedWidth = max(currentSlotWidth + actualFrame.width - target.width, 80)
      guard abs(learnedWidth - currentSlotWidth) >= 1 else { return false }

      state.monitors[monitorIndex].workspaces[workspaceIndex]
        .columns[columnIndex].width = .pixels(learnedWidth)
      synchronizeScrollOffsets(state: &state, viewports: viewports)
      return true
    }
  }
  return false
}
