import DefiConfig
import DefiCore
import DefiModel
import Darwin

public func discoverWindow(
  _ original: Window,
  decision: RuleDecision,
  placement: WindowPlacementPreference? = nil,
  isNativelyFocused: Bool = false,
  isFrontmostAppSpawn: Bool = false,
  isNativeFullscreen: Bool = false,
  state: inout RuntimeState
) throws {
  guard !state.monitors.isEmpty else {
    throw ReducerError.noMonitor
  }
  if state.windows[original.id] != nil {
    state.windows[original.id] = original
    return
  }

  var window = original
  window.floating =
    ((original.floating && !isNativeFullscreen) || decision.floating)
    && !decision.forceTiling
  if decision.forceTiling {
    window.floatingOrigin = nil
  } else if decision.floating {
    window.floatingOrigin = .configured
  }
  window.forceTiling = decision.forceTiling
  window.intrinsicSize = decision.intrinsicSize
  let effectivePlacement = window.floatingOrigin == .automatic ? nil : placement
  let transientLocation = transientPlacementLocation(for: window, state: state)
  let followFocusIntent = decision.followFocus && isNativelyFocused
  let ruleLocation = decision.workspace.flatMap { state.workspaceLocation(for: $0) }
  let placementLocation = effectivePlacement.flatMap {
    state.workspaceLocation(for: $0.workspaceID)
  }
  let preferredMonitorID = effectivePlacement?.monitorID.flatMap { preferred in
    state.monitors.contains(where: { $0.id == preferred }) ? preferred : nil
  }
  let monitorID =
    transientLocation?.monitorID
    ?? ruleLocation.map { state.monitors[$0.monitorIndex].id }
    ?? placementLocation.map { state.monitors[$0.monitorIndex].id }
    ?? preferredMonitorID
    ?? window.monitorID
    ?? state.monitors[0].id
  let monitorIndex = state.monitors.firstIndex(where: { $0.id == monitorID }) ?? 0
  let workspaceID =
    transientLocation?.workspaceID
    ?? decision.workspace
    ?? placementLocation.map {
      state.monitors[$0.monitorIndex].workspaces[$0.workspaceIndex].id
    }
    ?? state.monitors[monitorIndex].activeWorkspace
  guard
    let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
      where: { $0.id == workspaceID }
    )
  else {
    throw ReducerError.unknownWorkspace(workspaceID)
  }
  // Policy: a managed window spawned by the frontmost application follows
  // its assigned workspace and takes focus. The native focused-window event
  // can legitimately lag window creation, so it alone must not gate this.
  let followsFocus =
    followFocusIntent
    || (isFrontmostAppSpawn && !window.floating)

  if window.floating && !window.forceTiling {
    state.monitors[monitorIndex].workspaces[workspaceIndex].floatingWindows.append(window.id)
    if followsFocus {
      state.monitors[monitorIndex].workspaces[workspaceIndex].focusedFloatingWindow =
        state.monitors[monitorIndex].workspaces[workspaceIndex].floatingWindows.count - 1
      state.monitors[monitorIndex].workspaces[workspaceIndex].focusedLayer = .floating
    }
  } else {
    insertNewWindow(
      window.id,
      into: &state.monitors[monitorIndex].workspaces[workspaceIndex],
      settings: state.layout,
      focusInsertedWindow: followsFocus
    )
    if followsFocus {
      state.monitors[monitorIndex].workspaces[workspaceIndex].focusedLayer = .tiled
    }
  }
  if followsFocus {
    state.monitors[monitorIndex].activeWorkspace = workspaceID
  }
  state.windows[window.id] = window
  state.maintainWorkspaceLifecycle()
}

public func transientPlacementLocation(
  for window: Window,
  state: RuntimeState,
  locations: WindowLocationMap? = nil
) -> (monitorID: MonitorID, workspaceID: WorkspaceID)? {
  func location(containing windowID: WindowID) -> (monitorID: MonitorID, workspaceID: WorkspaceID)? {
    locations?[windowID] ?? state.location(containing: windowID)
  }
  guard window.isModal || window.floatingOrigin == .automatic else { return nil }
  if let ownerID = window.transientOwnerID,
    let ownerLocation = location(containing: ownerID)
  {
    return ownerLocation
  }
  let sameApplicationSelections = state.monitors.compactMap { monitor -> WindowID? in
    guard let selected = state.selectedWindowID(on: monitor.id),
      let selectedWindow = state.windows[selected],
      selectedWindow.appID == window.appID,
      window.processID.map({ selectedWindow.processID == $0 }) ?? true
    else { return nil }
    return selected
  }
  guard sameApplicationSelections.count == 1 else { return nil }
  return location(containing: sameApplicationSelections[0])
}

@discardableResult
public func moveFloatingWindow(
  _ windowID: WindowID,
  to targetMonitorID: MonitorID,
  state: inout RuntimeState
) -> Bool {
  guard
    let sourceMonitorIndex = state.monitors.firstIndex(where: { monitor in
      monitor.workspaces.contains(where: { $0.floatingWindows.contains(windowID) })
    }),
    state.monitors[sourceMonitorIndex].id != targetMonitorID,
    let sourceWorkspaceIndex = state.monitors[sourceMonitorIndex].workspaces.firstIndex(
      where: { $0.floatingWindows.contains(windowID) }
    ),
    let targetMonitorIndex = state.monitors.firstIndex(where: {
      $0.id == targetMonitorID
    }),
    let targetWorkspaceIndex = state.monitors[targetMonitorIndex].workspaces.firstIndex(
      where: { $0.id == state.monitors[targetMonitorIndex].activeWorkspace }
    )
  else {
    return false
  }

  state.suspendedTiledPlacements[windowID] = nil
  removeWindow(
    windowID,
    from: &state.monitors[sourceMonitorIndex].workspaces[sourceWorkspaceIndex],
    settings: state.layout
  )
  state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex].floatingWindows.append(
    windowID
  )
  state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex].focusedFloatingWindow =
    state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex].floatingWindows.count - 1
  state.monitors[targetMonitorIndex].workspaces[targetWorkspaceIndex].focusedLayer = .floating
  state.windows[windowID]?.monitorID = targetMonitorID
  return true
}

@discardableResult
public func reconcileWindows(
  _ discovered: [Window],
  config: Config,
  placementPreferences: PlacementPreferences = PlacementPreferences(),
  windowIDReplacements: [WindowID: WindowID] = [:],
  externallyChangedWindowIDs: Set<WindowID> = [],
  nativeFullscreenWindowIDs: Set<WindowID> = [],
  viewports: [MonitorID: Rect] = [:],
  nativeFocusedWindowID: WindowID? = nil,
  frontmostProcessID: pid_t? = nil,
  state: inout RuntimeState
) -> Set<WindowID> {
  var relocatedTransientIDs = Set<WindowID>()
  let discoveredIDs = Set(discovered.map(\.id))
  applyWindowIDReplacements(
    windowIDReplacements,
    discoveredWindows: Dictionary(
      discovered.map { ($0.id, $0) },
      uniquingKeysWith: { _, latest in latest }
    ),
    state: &state
  )
  let fullscreenSpaceHidesOtherWindows =
    !nativeFullscreenWindowIDs.isEmpty || !state.nativeFullscreenWindowIDs.isEmpty
  for existingID in Array(state.windows.keys)
  where !discoveredIDs.contains(existingID) && !fullscreenSpaceHidesOtherWindows {
    removeWindowFromEveryWorkspace(existingID, state: &state)
    state.windows[existingID] = nil
    state.nativeFullscreenFloatingWindowIDs.remove(existingID)
    state.nativeFullscreenTiledPlacements[existingID] = nil
    state.pendingNativeFullscreenWidthResetWindowIDs.remove(existingID)
    state.suspendedTiledPlacements[existingID] = nil
  }

  for window in discovered {
    if state.windows[window.id] == nil {
      try? discoverWindow(
        window,
        decision: config.decision(for: window),
        placement: placementPreferences.preference(for: window),
        isNativelyFocused: window.id == nativeFocusedWindowID,
        isFrontmostAppSpawn: window.processID != nil
          && window.processID == frontmostProcessID,
        isNativeFullscreen: nativeFullscreenWindowIDs.contains(window.id),
        state: &state
      )
    } else {
      var updated = window
      if let existing = state.windows[window.id] {
        if existing.floatingOrigin == .automatic,
          !nativeFullscreenWindowIDs.contains(window.id)
        {
          reclassifyAutomaticWindow(
            window.id,
            observedFloating: updated.floating,
            preferredPlacement: config.decision(for: window).workspace == nil
              ? placementPreferences.preference(for: window)
              : nil,
            state: &state
          )
        } else if existing.floatingOrigin == nil,
          !existing.forceTiling,
          updated.floatingOrigin == .automatic,
          updated.floating,
          !nativeFullscreenWindowIDs.contains(window.id)
        {
          reclassifyTiledWindowAsAutomaticFloater(
            window.id,
            state: &state
          )
        } else {
          updated.floating = existing.floating
          updated.floatingOrigin = existing.floatingOrigin
        }
        updated.forceTiling = existing.forceTiling
        updated.intrinsicSize = existing.intrinsicSize
        if nativeFullscreenWindowIDs.contains(window.id) {
          updated.minimumTiledWidth = nil
          updated.maximumTiledWidth = nil
        } else if window.minimumTiledWidth != nil
          || window.maximumTiledWidth != nil
        {
          updated.minimumTiledWidth = window.minimumTiledWidth
          updated.maximumTiledWidth = window.maximumTiledWidth
        } else {
          updated.minimumTiledWidth = existing.minimumTiledWidth
          updated.maximumTiledWidth = existing.maximumTiledWidth
        }
        if existing.intrinsicSize,
          !externallyChangedWindowIDs.contains(window.id)
        {
          updated.frame.width = existing.frame.width
          updated.frame.height = existing.frame.height
        }
      }
      state.windows[window.id] = updated
    }
  }
  // ponytail: bounded convergence scan; owner-ordering can replace it if deep chains become common.
  for _ in discovered.indices {
    var relocatedInPass = false
    var locations = state.windowLocationMap()
    for window in discovered where relocateTransientIfNeeded(
      window.id,
      viewports: viewports,
      locations: &locations,
      state: &state
    ) {
      relocatedTransientIDs.insert(window.id)
      relocatedInPass = true
    }
    if relocatedInPass == false { break }
  }
  reconcileNativeFullscreenWindows(nativeFullscreenWindowIDs, state: &state)
  state.maintainWorkspaceLifecycle()
  return relocatedTransientIDs
}

private func applyWindowIDReplacements(
  _ replacements: [WindowID: WindowID],
  discoveredWindows: [WindowID: Window],
  state: inout RuntimeState
) {
  for (previousID, replacementID) in replacements.sorted(by: {
    $0.key.rawValue < $1.key.rawValue
  }) {
    guard previousID != replacementID,
      state.windows[replacementID] == nil,
      var replacement = discoveredWindows[replacementID],
      let previous = state.windows.removeValue(forKey: previousID)
    else { continue }

    replacement.floating = previous.floating
    replacement.floatingOrigin = previous.floatingOrigin
    replacement.forceTiling = previous.forceTiling
    replacement.intrinsicSize = previous.intrinsicSize
    replacement.minimumTiledWidth = previous.minimumTiledWidth
    replacement.maximumTiledWidth = previous.maximumTiledWidth
    if previous.intrinsicSize {
      replacement.frame.width = previous.frame.width
      replacement.frame.height = previous.frame.height
    }
    state.windows[replacementID] = replacement

    for monitorIndex in state.monitors.indices {
      for workspaceIndex in state.monitors[monitorIndex].workspaces.indices {
        for columnIndex in state.monitors[monitorIndex].workspaces[workspaceIndex]
          .columns.indices
        {
          state.monitors[monitorIndex].workspaces[workspaceIndex].columns[columnIndex]
            .windows = state.monitors[monitorIndex].workspaces[workspaceIndex]
            .columns[columnIndex].windows.map {
              $0 == previousID ? replacementID : $0
            }
        }
        state.monitors[monitorIndex].workspaces[workspaceIndex].floatingWindows =
          state.monitors[monitorIndex].workspaces[workspaceIndex].floatingWindows.map {
            $0 == previousID ? replacementID : $0
          }
      }
    }
    for windowID in state.windows.keys
    where state.windows[windowID]?.transientOwnerID == previousID {
      state.windows[windowID]?.transientOwnerID = replacementID
    }
    replace(previousID, with: replacementID, in: &state.nativeFullscreenWindowIDs)
    replace(
      previousID,
      with: replacementID,
      in: &state.nativeFullscreenFloatingWindowIDs
    )
    replace(
      previousID,
      with: replacementID,
      in: &state.pendingNativeFullscreenWidthResetWindowIDs
    )
    replace(
      previousID,
      with: replacementID,
      in: &state.nativeFullscreenTiledPlacements
    )
    replace(
      previousID,
      with: replacementID,
      in: &state.suspendedTiledPlacements
    )
  }
}

private func replace(
  _ previousID: WindowID,
  with replacementID: WindowID,
  in windowIDs: inout Set<WindowID>
) {
  guard windowIDs.remove(previousID) != nil else { return }
  windowIDs.insert(replacementID)
}

private func replace(
  _ previousID: WindowID,
  with replacementID: WindowID,
  in placements: inout [WindowID: SuspendedTiledPlacement]
) {
  var replaced: [WindowID: SuspendedTiledPlacement] = [:]
  replaced.reserveCapacity(placements.count)
  for (windowID, placement) in placements {
    var column = placement.column
    column.windows = column.windows.map {
      $0 == previousID ? replacementID : $0
    }
    replaced[windowID == previousID ? replacementID : windowID] =
      SuspendedTiledPlacement(
        monitorID: placement.monitorID,
        workspaceID: placement.workspaceID,
        columnIndex: placement.columnIndex,
        windowIndex: placement.windowIndex,
        column: column
      )
  }
  placements = replaced
}

func selectedWindowID(in workspace: Workspace) -> WindowID? {
  if workspace.focusedLayer == .floating,
    workspace.floatingWindows.indices.contains(workspace.focusedFloatingWindow)
  {
    return workspace.floatingWindows[workspace.focusedFloatingWindow]
  }
  guard workspace.columns.indices.contains(workspace.focusedColumn) else { return nil }
  let column = workspace.columns[workspace.focusedColumn]
  guard column.windows.indices.contains(column.focusedWindow) else { return nil }
  return column.windows[column.focusedWindow]
}

func restoreSelection(
  _ windowID: WindowID?,
  in workspace: inout Workspace
) {
  guard let windowID else { return }
  if let floatingIndex = workspace.floatingWindows.firstIndex(of: windowID) {
    workspace.focusedFloatingWindow = floatingIndex
    workspace.focusedLayer = .floating
    return
  }
  guard
    let columnIndex = workspace.columns.firstIndex(where: {
      $0.windows.contains(windowID)
    }),
    let windowIndex = workspace.columns[columnIndex].windows.firstIndex(of: windowID)
  else { return }
  workspace.focusedColumn = columnIndex
  workspace.columns[columnIndex].focusedWindow = windowIndex
  workspace.focusedLayer = .tiled
}
