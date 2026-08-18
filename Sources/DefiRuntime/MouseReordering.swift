import DefiCore
import DefiModel

public struct WorkspaceScrollAnchor: Equatable, Sendable {
  public let monitorID: MonitorID
  public let workspaceID: WorkspaceID
  public let scrollOffset: Double

  public init(
    monitorID: MonitorID,
    workspaceID: WorkspaceID,
    scrollOffset: Double
  ) {
    self.monitorID = monitorID
    self.workspaceID = workspaceID
    self.scrollOffset = scrollOffset
  }
}

public struct MouseGestureSettlement: Equatable, Sendable {
  public let generation: UInt64
  public let windowID: WindowID
  public let initialFrame: Rect
  public var lastObservedFrame: Rect
  public var observedPostReleaseChange: Bool
  public var stableSince: Double?
  public var nextCheckAt: Double
  public let expiresAt: Double

  public init(
    generation: UInt64,
    windowID: WindowID,
    initialFrame: Rect,
    releasedFrame: Rect,
    now: Double,
    maximumDuration: Double,
    pollInterval: Double = 0.05
  ) {
    self.generation = generation
    self.windowID = windowID
    self.initialFrame = initialFrame
    lastObservedFrame = releasedFrame
    observedPostReleaseChange = false
    stableSince = nil
    nextCheckAt = now + pollInterval
    expiresAt = now + maximumDuration
  }
}

public struct MouseGestureSettlementUpdate: Equatable, Sendable {
  public let settlement: MouseGestureSettlement
  public let shouldFinish: Bool

  public init(
    settlement: MouseGestureSettlement,
    shouldFinish: Bool
  ) {
    self.settlement = settlement
    self.shouldFinish = shouldFinish
  }
}

public func mouseGestureAnimationCancellationIsNeeded(
  mouseReorderAnimationActive: Bool,
  scrollAnimationActive: Bool,
  animatedWritesPending: Bool
) -> Bool {
  !mouseReorderAnimationActive
    && (scrollAnimationActive || animatedWritesPending)
}

public func mouseGestureSettlementMaximumDuration(
  latencySensitive: Bool
) -> Double {
  latencySensitive ? 0.8 : 0.25
}

public func mouseGestureWidthLearningFrame(
  externallyChangedFrame: Rect?,
  actualFrame: Rect?,
  postReleaseSettlementActive: Bool
) -> Rect? {
  externallyChangedFrame
    ?? (postReleaseSettlementActive ? actualFrame : nil)
}

public func advanceMouseGestureSettlement(
  _ current: MouseGestureSettlement,
  actualFrame: Rect,
  now: Double,
  animationPending: Bool,
  frameTolerance: Double = 1,
  pollInterval: Double = 0.05,
  quietDuration: Double = 0.05
) -> MouseGestureSettlementUpdate {
  var next = current
  let frameChanged =
    abs(actualFrame.x - current.lastObservedFrame.x) > frameTolerance
    || abs(actualFrame.y - current.lastObservedFrame.y) > frameTolerance
    || abs(actualFrame.width - current.lastObservedFrame.width) > frameTolerance
    || abs(actualFrame.height - current.lastObservedFrame.height) > frameTolerance
  if frameChanged {
    next.lastObservedFrame = actualFrame
    next.observedPostReleaseChange = true
    next.stableSince = now
  }
  let converged = next.observedPostReleaseChange
    && now >= (next.stableSince ?? now) + quietDuration
  let timedOut = now >= next.expiresAt
  let shouldFinish = (converged || timedOut) && !animationPending
  if shouldFinish {
    next.nextCheckAt = now
  } else if animationPending && (converged || timedOut) {
    next.nextCheckAt = now + pollInterval
  } else if let stableSince = next.stableSince {
    next.nextCheckAt = min(stableSince + quietDuration, next.expiresAt)
  } else {
    next.nextCheckAt = min(now + pollInterval, next.expiresAt)
  }
  return MouseGestureSettlementUpdate(
    settlement: next,
    shouldFinish: shouldFinish
  )
}

public func workspaceScrollAnchor(
  containing windowID: WindowID,
  state: RuntimeState
) -> WorkspaceScrollAnchor? {
  guard let location = state.location(containing: windowID),
    let monitor = state.monitors.first(where: { $0.id == location.monitorID }),
    let workspace = monitor.workspaces.first(where: {
      $0.id == location.workspaceID
    })
  else {
    return nil
  }
  return WorkspaceScrollAnchor(
    monitorID: location.monitorID,
    workspaceID: location.workspaceID,
    scrollOffset: workspace.scrollOffset
  )
}

public func restoreWorkspaceScroll(
  _ anchor: WorkspaceScrollAnchor,
  state: inout RuntimeState
) {
  guard
    let monitorIndex = state.monitors.firstIndex(where: {
      $0.id == anchor.monitorID
    }),
    let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
      where: { $0.id == anchor.workspaceID }
    )
  else {
    return
  }
  state.monitors[monitorIndex].workspaces[workspaceIndex].scrollOffset =
    anchor.scrollOffset
  state.monitors[monitorIndex].workspaces[workspaceIndex].targetScrollOffset =
    anchor.scrollOffset
}

public func resolvedMouseGestureScrollAnchor(
  current: WorkspaceScrollAnchor?,
  gestureWindowID: WindowID?,
  mouseGestureActive: Bool,
  state: RuntimeState
) -> WorkspaceScrollAnchor? {
  guard mouseGestureActive else { return nil }
  return current ?? gestureWindowID.flatMap {
    workspaceScrollAnchor(containing: $0, state: state)
  }
}

public func mouseGestureTiledWindowID(
  translatedWindowID: WindowID?,
  activeWindowID: WindowID?,
  mouseFocusIntentWindowID: WindowID?,
  focusedWindowID: WindowID?,
  state: RuntimeState
) -> WindowID? {
  for candidate in [
    activeWindowID,
    mouseFocusIntentWindowID,
    translatedWindowID,
    focusedWindowID,
  ] {
    guard let candidate,
      state.windows[candidate]?.floating == false,
      let location = state.location(containing: candidate),
      state.monitors.first(where: { $0.id == location.monitorID })?
        .activeWorkspace == location.workspaceID
    else {
      continue
    }
    return candidate
  }
  return nil
}

public func resolvedMouseGestureInitialFrame(
  currentInitialFrame: Rect?,
  gestureWindowID: WindowID?,
  activeWindowID: WindowID?,
  translatedWindowID: WindowID?,
  leftMouseButtonDown: Bool,
  previousObservedFrames: [WindowID: Rect],
  actualFrame: Rect?
) -> Rect? {
  let startsMouseGesture =
    leftMouseButtonDown
    && gestureWindowID != activeWindowID
  let recoversReleaseOnlyGesture =
    currentInitialFrame == nil
    && gestureWindowID == translatedWindowID
  guard startsMouseGesture || recoversReleaseOnlyGesture,
    let gestureWindowID
  else {
    return currentInitialFrame
  }
  return previousObservedFrames[gestureWindowID] ?? actualFrame
}

public func resolvedMouseGestureOriginFrame(
  observedFrame: Rect,
  displayedX: Double?,
  displayedY: Double?,
  displayedWidth: Double? = nil,
  displayedHeight: Double? = nil
) -> Rect {
  return Rect(
    x: displayedX ?? observedFrame.x,
    y: displayedY ?? observedFrame.y,
    width: displayedWidth ?? observedFrame.width,
    height: displayedHeight ?? observedFrame.height
  )
}

public func mouseTranslatedTiledWindowID(
  candidateWindowIDs: [WindowID],
  externallyChangedFrames: [WindowID: Rect],
  state: RuntimeState,
  viewports: [MonitorID: Rect],
  sizeTolerance: Double = 2,
  positionTolerance: Double = 2
) -> WindowID? {
  for windowID in candidateWindowIDs {
    guard let location = state.location(containing: windowID),
      let monitor = state.monitors.first(where: { $0.id == location.monitorID }),
      location.workspaceID == monitor.activeWorkspace,
      let viewport = viewports[monitor.id],
      let workspace = monitor.workspaces.first(where: {
        $0.id == location.workspaceID
      }),
      workspace.columns.contains(where: { $0.windows.contains(windowID) })
    else {
      continue
    }
    let windows = workspace.columns
      .flatMap(\.windows)
      .compactMap { state.windows[$0] }
    let targets = Dictionary(
      uniqueKeysWithValues: computeLayout(
        workspace: workspace,
        viewport: viewport,
        windows: windows,
        settings: state.layout
      ).frames.map { ($0.windowID, $0.frame) }
    )
    guard let actual = externallyChangedFrames[windowID],
      let target = targets[windowID],
      abs(actual.width - target.width) <= sizeTolerance,
      abs(actual.height - target.height) <= sizeTolerance,
      abs(actual.x - target.x) > positionTolerance
        || abs(actual.y - target.y) > positionTolerance
    else {
      continue
    }
    return windowID
  }
  return nil
}

public func mouseFrameWasTranslated(
  from initialFrame: Rect,
  to actualFrame: Rect,
  sizeTolerance: Double = 2,
  positionTolerance: Double = 2
) -> Bool {
  abs(actualFrame.width - initialFrame.width) <= sizeTolerance
    && abs(actualFrame.height - initialFrame.height) <= sizeTolerance
    && (abs(actualFrame.x - initialFrame.x) > positionTolerance
      || abs(actualFrame.y - initialFrame.y) > positionTolerance)
}

@discardableResult
public func reorderTiledWindowAfterMouseDrag(
  _ windowID: WindowID,
  actualFrame: Rect,
  initialFrame: Rect? = nil,
  state: inout RuntimeState,
  viewports: [MonitorID: Rect]
) -> Bool {
  guard
    let monitorIndex = state.monitors.firstIndex(where: { monitor in
      monitor.workspaces.contains(where: { workspace in
        workspace.id == monitor.activeWorkspace
          && workspace.columns.contains(where: { $0.windows.contains(windowID) })
      })
    }),
    let viewport = viewports[state.monitors[monitorIndex].id],
    let workspaceIndex = state.monitors[monitorIndex].workspaces.firstIndex(
      where: { $0.id == state.monitors[monitorIndex].activeWorkspace }
    ),
    let sourceColumnIndex = state.monitors[monitorIndex].workspaces[workspaceIndex]
      .columns.firstIndex(where: { $0.windows.contains(windowID) })
  else {
    return false
  }

  var workspace = state.monitors[monitorIndex].workspaces[workspaceIndex]
  let windows = workspace.columns
    .flatMap(\.windows)
    .compactMap { state.windows[$0] }
  let frames = Dictionary(
    uniqueKeysWithValues: computeLayout(
      workspace: workspace,
      viewport: viewport,
      windows: windows,
      settings: state.layout
    ).frames.map { ($0.windowID, $0.frame) }
  )

  guard let sourceFrame = frames[windowID]
  else {
    return false
  }
  let sizeReferenceFrame = initialFrame ?? sourceFrame
  guard abs(actualFrame.width - sizeReferenceFrame.width) <= 2,
    abs(actualFrame.height - sizeReferenceFrame.height) <= 2
  else {
    return false
  }
  let draggedCenterX = actualFrame.x + actualFrame.width / 2
  var horizontalTargetIndex = sourceColumnIndex
  if sourceColumnIndex + 1 < workspace.columns.count,
    let nextCenterX = centerX(
      for: workspace.columns[sourceColumnIndex + 1],
      frames: frames
    ),
    draggedCenterX > nextCenterX
  {
    horizontalTargetIndex += 1
  } else if sourceColumnIndex > 0,
    let previousCenterX = centerX(
      for: workspace.columns[sourceColumnIndex - 1],
      frames: frames
    ),
    draggedCenterX < previousCenterX
  {
    horizontalTargetIndex -= 1
  }
  if horizontalTargetIndex != sourceColumnIndex {
    var column = workspace.columns.remove(at: sourceColumnIndex)
    if let focusedWindow = column.windows.firstIndex(of: windowID) {
      column.focusedWindow = focusedWindow
    }
    workspace.columns.insert(column, at: horizontalTargetIndex)
    workspace.focusedColumn = horizontalTargetIndex
    workspace.focusedLayer = .tiled
    state.monitors[monitorIndex].workspaces[workspaceIndex] = workspace
    synchronizeScrollOffsets(state: &state, viewports: viewports)
    return true
  }

  guard
    let sourceWindowIndex = workspace.columns[sourceColumnIndex]
      .windows.firstIndex(of: windowID),
    workspace.columns[sourceColumnIndex].windows.count > 1
  else {
    return false
  }
  let draggedCenterY = actualFrame.y + actualFrame.height / 2
  let remainingWindows = workspace.columns[sourceColumnIndex].windows.enumerated().filter {
    $0.offset != sourceWindowIndex
  }
  let verticalInsertionIndex = insertionIndex(
    coordinate: draggedCenterY,
    centers: remainingWindows.compactMap { _, candidateID in
      frames[candidateID].map { $0.y + $0.height / 2 }
    }
  )
  guard verticalInsertionIndex != sourceWindowIndex else { return false }

  workspace.columns[sourceColumnIndex].windows.remove(at: sourceWindowIndex)
  workspace.columns[sourceColumnIndex].windows.insert(
    windowID,
    at: verticalInsertionIndex
  )
  workspace.columns[sourceColumnIndex].focusedWindow = verticalInsertionIndex
  workspace.focusedColumn = sourceColumnIndex
  workspace.focusedLayer = .tiled
  state.monitors[monitorIndex].workspaces[workspaceIndex] = workspace
  synchronizeScrollOffsets(state: &state, viewports: viewports)
  return true
}

@discardableResult
public func reorderTiledWindowAfterCompletedMouseDrag(
  _ windowID: WindowID,
  actualFrame: Rect,
  initialFrame: Rect? = nil,
  state: inout RuntimeState,
  viewports: [MonitorID: Rect]
) -> Bool {
  let maximumReorders = state.monitors.lazy
    .flatMap(\.workspaces)
    .map(\.columns.count)
    .max() ?? 0
  var reordered = false
  for _ in 0..<maximumReorders {
    let sourceColumnIndex = activeColumnIndex(containing: windowID, state: state)
    guard reorderTiledWindowAfterMouseDrag(
      windowID,
      actualFrame: actualFrame,
      initialFrame: initialFrame,
      state: &state,
      viewports: viewports
    ) else {
      break
    }
    reordered = true
    if activeColumnIndex(containing: windowID, state: state) == sourceColumnIndex {
      break
    }
  }
  return reordered
}

public func desktopSynchronizationIsReady(
  scrollAnimationActive: Bool,
  animatedWritesPending: Bool,
  mouseGestureSyncPending: Bool,
  needsDesktopSync: Bool,
  periodicSyncDue: Bool,
  commandQuietPeriodElapsed: Bool,
  nativeFocusSyncPending: Bool = false,
  frameDebtPending: Bool = false
) -> Bool {
  guard !scrollAnimationActive || nativeFocusSyncPending,
    commandQuietPeriodElapsed || mouseGestureSyncPending || nativeFocusSyncPending
      || frameDebtPending,
    needsDesktopSync || periodicSyncDue
  else {
    return false
  }
  return !animatedWritesPending
    || nativeFocusSyncPending
    || (mouseGestureSyncPending && needsDesktopSync)
}

private func activeColumnIndex(
  containing windowID: WindowID,
  state: RuntimeState
) -> Int? {
  for monitor in state.monitors {
    guard let workspace = monitor.workspaces.first(where: {
      $0.id == monitor.activeWorkspace
    }) else {
      continue
    }
    if let index = workspace.columns.firstIndex(where: {
      $0.windows.contains(windowID)
    }) {
      return index
    }
  }
  return nil
}

private func insertionIndex(coordinate: Double, centers: [Double]) -> Int {
  centers.firstIndex(where: { coordinate < $0 }) ?? centers.count
}

private func centerX(
  for column: Column,
  frames: [WindowID: Rect]
) -> Double? {
  column.windows.compactMap { windowID in
    frames[windowID].map { $0.x + $0.width / 2 }
  }.first
}
