import AppKit
import DefiConfig
import DefiCore
import DefiModel
import QuartzCore

private struct OverviewViewportAnimation {
  let from: OverviewViewport
  let to: OverviewViewport
  let startedAt: TimeInterval
  let duration: TimeInterval
}

private struct OverviewProjectionAnimation {
  let from: OverviewProjection
  let to: OverviewProjection
  let startedAt: TimeInterval
  let duration: TimeInterval
}

private struct RememberedOverviewPreview {
  let image: NSImage
  let appID: String
  let processID: pid_t
}

enum OverviewScrollAxis: Equatable {
  case horizontal
  case vertical
}

func overviewScrollAxis(for delta: NSPoint) -> OverviewScrollAxis? {
  guard delta.x != 0 || delta.y != 0 else { return nil }
  return abs(delta.y) >= abs(delta.x) ? .vertical : .horizontal
}

func overviewUsesWorkspaceParking(
  windowPreviewsEnabled: Bool,
  screenCaptureAccessGranted: Bool
) -> Bool {
  !windowPreviewsEnabled || !screenCaptureAccessGranted
}

func overviewViewportAfterScroll(
  _ viewport: OverviewViewport,
  delta: NSPoint,
  hasPreciseScrollingDeltas: Bool,
  viewSize: NSSize,
  zoom: Double = 0.5,
  activeWorkspaceIndex: Int,
  workspaceCount: Int,
  horizontalWorkspaceID: WorkspaceID?,
  maximumHorizontalOffset: Double?
) -> OverviewViewport {
  var viewport = viewport
  let deltaScale = hasPreciseScrollingDeltas ? 1.0 : 16.0
  switch overviewScrollAxis(for: delta) {
  case .vertical:
    let stride = overviewWorkspaceStride(boundsHeight: viewSize.height, zoom: zoom)
    viewport.workspaceOffset = min(
      max(
        viewport.workspaceOffset - delta.y * deltaScale / max(stride, 1),
        Double(-activeWorkspaceIndex)
      ),
      Double(workspaceCount - activeWorkspaceIndex - 1)
    )
  case .horizontal:
    guard let horizontalWorkspaceID, let maximumHorizontalOffset else {
      return viewport
    }
    let workspaceHeight = overviewWorkspaceStride(
      boundsHeight: viewSize.height,
      zoom: zoom
    ) - 28
    let contentScale = workspaceHeight / max(viewSize.height, 1)
    let projectedPointsPerScrollUnit = viewSize.width * contentScale
    let offset = viewport.horizontalOffsets[horizontalWorkspaceID, default: 0]
      - delta.x * deltaScale / max(projectedPointsPerScrollUnit, 1)
    viewport.horizontalOffsets[horizontalWorkspaceID] = min(
      max(offset, 0),
      maximumHorizontalOffset
    )
  case nil:
    break
  }
  return viewport
}

func overviewViewportTransitionAfterSelectionAlignment(
  current: OverviewViewport,
  pendingTarget: OverviewViewport?,
  animationTarget: OverviewViewport?,
  workspaceID: WorkspaceID,
  scrollOffset: Double,
  sourceWorkspaceID: WorkspaceID?,
  sourceMaximumHorizontalOffset: Double?,
  movedSelection: Bool
) -> (current: OverviewViewport, target: OverviewViewport?) {
  var aligned = pendingTarget ?? animationTarget ?? current
  aligned.horizontalOffsets[workspaceID] = scrollOffset
  if let sourceWorkspaceID, let sourceMaximumHorizontalOffset {
    aligned.horizontalOffsets[sourceWorkspaceID] = min(
      max(aligned.horizontalOffsets[sourceWorkspaceID, default: 0], 0),
      sourceMaximumHorizontalOffset
    )
  }
  return movedSelection
    ? (current: aligned, target: nil)
    : (current: current, target: aligned)
}

@MainActor
public final class OverviewController: NSObject {
  private static let rememberedPreviewByteLimit = 16 * 1_024 * 1_024

  public typealias WindowHandler = @MainActor @Sendable (
    WindowID, String, MonitorID, WorkspaceID
  ) -> Void
  public typealias WorkspaceHandler = @MainActor @Sendable (
    MonitorID, WorkspaceID
  ) -> Void
  public typealias DropHandler = @MainActor @Sendable (
    WindowID, String, MonitorID, WorkspaceID, OverviewDropTarget
  ) -> Void
  public typealias MonitorHandler = @MainActor @Sendable (MonitorID) -> Void
  public typealias OpenStateHandler = @MainActor @Sendable (Bool) -> Void

  private let focusWindowHandler: WindowHandler
  private let focusWorkspaceHandler: WorkspaceHandler
  private let dropHandler: DropHandler
  private let activateMonitorHandler: MonitorHandler
  private let openStateHandler: OpenStateHandler
  private var panels: [MonitorID: OverviewPanel] = [:]
  private var snapshot: OverviewSnapshot?
  private var layout = LayoutSettings()
  private var borderStyle = WindowBorderStyle(config: BordersConfig())
  private var viewports: [MonitorID: OverviewViewport] = [:]
  private var projections: [MonitorID: OverviewProjection] = [:]
  private var activeWorkspaceByMonitor: [MonitorID: WorkspaceID] = [:]
  private var selection: OverviewSelection?
  private var drag: OverviewDrag?
  private var edgeScrollTimer: Timer?
  private var edgeScrollDirection: Double?
  private var sessionGeneration: UInt64 = 0
  private var expectedActivationProcessID: pid_t?
  private var expectedActivationGeneration: UInt64 = 0
  private var windowPreviewsEnabled = false
  private var previewTask: Task<Void, Never>?
  private var previewCache: [WindowID: NSImage] = [:]
  private var rememberedPreviews: [WindowID: RememberedOverviewPreview] = [:]
  private var rememberedPreviewByteCosts: [WindowID: Int] = [:]
  private var previewRevealStartedAt: [WindowID: TimeInterval] = [:]
  private var previewFadeTimer: Timer?
  private var attemptedPreviewWindowIDs = Set<WindowID>()
  private var capturedDesktopMonitorIDs = Set<MonitorID>()
  private var hasRequestedPreviewPermission = false
  private var previewPendingCount = 0
  private var alignSelectionOnNextUpdate = false
  private var animationsEnabled = true
  private var overviewZoom = 0.5
  private var windowCornerRadius = 12.0
  private var viewportAnimations: [MonitorID: OverviewViewportAnimation] = [:]
  private var projectionAnimations: [MonitorID: OverviewProjectionAnimation] = [:]
  private var viewportDisplayLinks: [MonitorID: CADisplayLink] = [:]
  private var displayLinkMonitorIDs: [ObjectIdentifier: MonitorID] = [:]

  public private(set) var isOpen = false
  public private(set) var usesWorkspaceParking = false
  public var panelCount: Int { isOpen ? panels.count : 0 }
  public private(set) var previewPermissionState: OverviewPreviewPermissionState = .disabled
  public private(set) var previewFailureCount = 0
  public var previewCacheCount: Int { previewCache.count }
  public var rememberedPreviewMemoryBytes: Int {
    rememberedPreviewByteCosts.values.reduce(0, +)
  }
  public var inFlightPreviewCount: Int {
    previewTask == nil ? 0 : min(previewPendingCount, 2)
  }

  public init(
    focusWindow: @escaping WindowHandler,
    focusWorkspace: @escaping WorkspaceHandler,
    drop: @escaping DropHandler,
    activateMonitor: @escaping MonitorHandler,
    openStateChanged: @escaping OpenStateHandler
  ) {
    focusWindowHandler = focusWindow
    focusWorkspaceHandler = focusWorkspace
    dropHandler = drop
    activateMonitorHandler = activateMonitor
    openStateHandler = openStateChanged
    super.init()
    let center = NSWorkspace.shared.notificationCenter
    center.addObserver(
      self,
      selector: #selector(applicationActivated(_:)),
      name: NSWorkspace.didActivateApplicationNotification,
      object: nil
    )
    for name in [
      NSWorkspace.screensDidSleepNotification,
      NSWorkspace.sessionDidResignActiveNotification,
      NSWorkspace.willSleepNotification,
    ] {
      center.addObserver(
        self,
        selector: #selector(closeForSystemTransition(_:)),
        name: name,
        object: nil
      )
    }
  }

  isolated deinit {
    previewFadeTimer?.invalidate()
    for link in viewportDisplayLinks.values { link.invalidate() }
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  public func toggle(
    snapshot: OverviewSnapshot,
    layout: LayoutSettings,
    borders: BordersConfig = BordersConfig(),
    animation: AnimationConfig = AnimationConfig(),
    zoom: Double = 0.5,
    windowCornerRadius: Double = 12,
    windowPreviewsEnabled: Bool = false
  ) {
    if isOpen {
      close()
    } else {
      open(
        snapshot: snapshot,
        layout: layout,
        borders: borders,
        animation: animation,
        zoom: zoom,
        windowCornerRadius: windowCornerRadius,
        windowPreviewsEnabled: windowPreviewsEnabled
      )
    }
  }

  public func open(
    snapshot: OverviewSnapshot,
    layout: LayoutSettings,
    borders: BordersConfig = BordersConfig(),
    animation: AnimationConfig = AnimationConfig(),
    zoom: Double = 0.5,
    windowCornerRadius: Double = 12,
    windowPreviewsEnabled: Bool = false
  ) {
    sessionGeneration &+= 1
    self.snapshot = snapshot
    self.layout = layout
    borderStyle = WindowBorderStyle(config: borders)
    animationsEnabled = animation.enabled
    overviewZoom = zoom
    self.windowCornerRadius = windowCornerRadius
    self.windowPreviewsEnabled = windowPreviewsEnabled
    usesWorkspaceParking = overviewUsesWorkspaceParking(
      windowPreviewsEnabled: windowPreviewsEnabled,
      screenCaptureAccessGranted: CGPreflightScreenCaptureAccess()
    )
    let monitorIDs = Set(snapshot.monitors.map(\.id))
    let canReusePanels = Set(panels.keys) == monitorIDs
      && panels.allSatisfy { monitorID, panel in
        screen(for: monitorID)?.frame == panel.window.frame
          && panel.usesCapturedDesktop == !usesWorkspaceParking
      }
    if !canReusePanels { closePanelsImmediately() }
    previewTask?.cancel()
    previewTask = nil
    previewCache.removeAll(keepingCapacity: true)
    restoreRememberedPreviews(for: snapshot)
    resetPreviewFadeAnimation()
    attemptedPreviewWindowIDs.removeAll(keepingCapacity: true)
    capturedDesktopMonitorIDs.removeAll(keepingCapacity: true)
    previewPendingCount = 0
    previewPermissionState = windowPreviewsEnabled ? .notDetermined : .disabled
    selection = initialSelection(in: snapshot)
    activeWorkspaceByMonitor = Dictionary(
      uniqueKeysWithValues: snapshot.monitors.map { ($0.id, $0.activeWorkspace) }
    )
    viewports = Dictionary(uniqueKeysWithValues: snapshot.monitors.map { monitor in
      (
        monitor.id,
        OverviewViewport(
          horizontalOffsets: Dictionary(
            uniqueKeysWithValues: monitor.workspaces.map {
              ($0.id, $0.scrollOffset)
            }
          )
        )
      )
    })
    for monitor in snapshot.monitors {
      guard panels[monitor.id] == nil,
        let screen = screen(for: monitor.id)
      else { continue }
      panels[monitor.id] = OverviewPanel(
        monitorID: monitor.id,
        screen: screen,
        usesCapturedDesktop: !usesWorkspaceParking,
        delegate: self
      )
    }
    isOpen = true
    updatePanels()
    openStateHandler(true)
    let animated = animationsEnabled
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    for panel in panels.values {
      panel.show(animated: animated)
    }
  }

  public func update(
    snapshot: OverviewSnapshot,
    layout: LayoutSettings,
    borders: BordersConfig = BordersConfig(),
    animation: AnimationConfig = AnimationConfig(),
    zoom: Double = 0.5,
    windowCornerRadius: Double = 12,
    windowPreviewsEnabled: Bool? = nil
  ) {
    guard isOpen else { return }
    let previousSnapshot = self.snapshot
    let previousProjections = projections
    if let windowPreviewsEnabled,
      self.windowPreviewsEnabled != windowPreviewsEnabled
    {
      self.windowPreviewsEnabled = windowPreviewsEnabled
      previewTask?.cancel()
      previewTask = nil
      previewCache.removeAll(keepingCapacity: true)
      if windowPreviewsEnabled {
        restoreRememberedPreviews(for: snapshot)
      } else {
        removeAllRememberedPreviews()
      }
      resetPreviewFadeAnimation()
      attemptedPreviewWindowIDs.removeAll(keepingCapacity: true)
      previewPendingCount = 0
      previewPermissionState = windowPreviewsEnabled ? .notDetermined : .disabled
    }
    self.snapshot = snapshot
    pruneRememberedPreviews(for: snapshot)
    self.layout = layout
    borderStyle = WindowBorderStyle(config: borders)
    animationsEnabled = animation.enabled
    overviewZoom = zoom
    self.windowCornerRadius = windowCornerRadius
    var movedSelectionPositions: (
      previous: OverviewTiledPosition,
      next: OverviewTiledPosition
    )?
    if drag == nil {
      let focusedSelection = initialSelection(in: snapshot)
      if focusedSelection != selection {
        selection = focusedSelection
        alignSelectionOnNextUpdate = true
      } else if let windowID = selection?.windowID,
        let previousPosition = previousSnapshot?.tiledPosition(of: windowID),
        let nextPosition = snapshot.tiledPosition(of: windowID),
        previousPosition != nextPosition
      {
        alignSelectionOnNextUpdate = true
        movedSelectionPositions = (previousPosition, nextPosition)
      }
    } else if let drag,
      snapshot.windows[drag.windowID]?.appID != drag.appID
        || snapshot.location(of: drag.windowID)
          != OverviewLocation(
            monitorID: drag.sourceMonitorID,
            workspaceID: drag.sourceWorkspaceID
          )
    {
      self.drag = nil
      edgeScrollTimer?.invalidate()
      edgeScrollTimer = nil
      edgeScrollDirection = nil
    }
    var viewportTargets: [MonitorID: OverviewViewport] = [:]
    for monitor in snapshot.monitors {
      if viewports[monitor.id] == nil {
        viewports[monitor.id] = OverviewViewport()
      }
      for workspace in monitor.workspaces
      where viewports[monitor.id]?.horizontalOffsets[workspace.id] == nil {
        viewports[monitor.id]?.horizontalOffsets[workspace.id] = workspace.scrollOffset
      }
      if let previousWorkspaceID = activeWorkspaceByMonitor[monitor.id],
        previousWorkspaceID != monitor.activeWorkspace,
        let previousIndex = monitor.workspaces.firstIndex(where: {
          $0.id == previousWorkspaceID
        }),
        let activeIndex = monitor.workspaces.firstIndex(where: {
          $0.id == monitor.activeWorkspace
        }),
        var viewport = viewports[monitor.id]
      {
        cancelAnimations(on: monitor.id)
        viewport.workspaceOffset += Double(previousIndex - activeIndex)
        viewports[monitor.id] = viewport
        viewport.workspaceOffset = 0
        viewportTargets[monitor.id] = viewport
      }
      activeWorkspaceByMonitor[monitor.id] = monitor.activeWorkspace
    }
    if alignSelectionOnNextUpdate,
      let location = selection?.location,
      let monitor = snapshot.monitors.first(where: {
        $0.id == location.monitorID
      }),
      let workspace = monitor.workspaces.first(where: {
        $0.id == location.workspaceID
      })
    {
      let movedSelection = movedSelectionPositions?.next.monitorID == location.monitorID
      let sourceWorkspaceID = movedSelectionPositions?.previous.monitorID == location.monitorID
        ? movedSelectionPositions?.previous.workspaceID
        : nil
      let transition = overviewViewportTransitionAfterSelectionAlignment(
        current: viewports[location.monitorID] ?? OverviewViewport(),
        pendingTarget: viewportTargets[location.monitorID],
        animationTarget: viewportAnimations[location.monitorID]?.to,
        workspaceID: location.workspaceID,
        scrollOffset: workspace.scrollOffset,
        sourceWorkspaceID: sourceWorkspaceID,
        sourceMaximumHorizontalOffset: sourceWorkspaceID.flatMap {
          maximumHorizontalOffset(for: $0, on: monitor)
        },
        movedSelection: movedSelection
      )
      if movedSelection {
        cancelAnimations(on: location.monitorID)
      }
      viewports[location.monitorID] = transition.current
      viewportTargets[location.monitorID] = transition.target
      alignSelectionOnNextUpdate = false
    }
    let monitorIDs = Set(snapshot.monitors.map(\.id))
    guard Set(panels.keys) == monitorIDs,
      snapshot.monitors.allSatisfy({ screen(for: $0.id) != nil })
    else {
      close()
      return
    }
    if let selection, !selection.isValid(in: snapshot) {
      self.selection = initialSelection(in: snapshot)
      drag = nil
    }
    for (monitorID, viewport) in viewportTargets {
      animateViewport(on: monitorID, to: viewport)
    }
    if let movedSelectionMonitorID = movedSelectionPositions?.next.monitorID {
      animateProjection(
        on: movedSelectionMonitorID,
        from: previousProjections[movedSelectionMonitorID]
      )
    }
    updatePanels()
  }

  public func close() {
    guard isOpen else { return }
    isOpen = false
    sessionGeneration &+= 1
    edgeScrollTimer?.invalidate()
    edgeScrollTimer = nil
    edgeScrollDirection = nil
    drag = nil
    alignSelectionOnNextUpdate = false
    expectedActivationProcessID = nil
    previewTask?.cancel()
    previewTask = nil
    previewCache.removeAll(keepingCapacity: true)
    resetPreviewFadeAnimation()
    attemptedPreviewWindowIDs.removeAll(keepingCapacity: true)
    capturedDesktopMonitorIDs.removeAll(keepingCapacity: true)
    previewPendingCount = 0
    stopOverviewAnimations()
    openStateHandler(false)
    let closingPanels = Array(panels.values)
    for panel in closingPanels {
      panel.hide()
    }
  }

  public func handleKey(_ action: OverviewKeyAction) {
    guard isOpen else { return }
    switch action {
    case .cancel:
      close()
    case .select:
      chooseSelection()
    case .left, .right, .up, .down:
      navigate(action)
    case .moveUp, .moveDown:
      moveSelectionVertically(action)
    }
  }

  @objc private func applicationActivated(_ notification: Notification) {
    guard isOpen else { return }
    let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
      as? NSRunningApplication
    if application?.processIdentifier == expectedActivationProcessID {
      expectedActivationProcessID = nil
      return
    }
    if let processID = application?.processIdentifier,
      let snapshot,
      let selectedWindowID = selection?.windowID,
      snapshot.windows[selectedWindowID]?.processID == processID
    {
      return
    }
    close()
  }

  @objc private func closeForSystemTransition(_ notification: Notification) {
    close()
  }

  private func chooseSelection() {
    guard let snapshot, let selection else { return }
    switch selection {
    case .window(let windowID, let monitorID, let workspaceID):
      guard let window = snapshot.windows[windowID] else { return }
      close()
      focusWindowHandler(windowID, window.appID, monitorID, workspaceID)
    case .workspace(let monitorID, let workspaceID):
      close()
      focusWorkspaceHandler(monitorID, workspaceID)
    }
  }

  private func navigate(_ action: OverviewKeyAction) {
    guard let snapshot,
      let target = navigationTarget(
        from: selection ?? initialSelection(in: snapshot),
        action: action,
        snapshot: snapshot
      )
    else { return }
    selection = target
    alignSelectionOnNextUpdate = true
    switch target {
    case .window(let windowID, let monitorID, let workspaceID):
      guard let window = snapshot.windows[windowID] else { return }
      expectActivation(of: window.processID)
      focusWindowHandler(windowID, window.appID, monitorID, workspaceID)
    case .workspace(let monitorID, let workspaceID):
      focusWorkspaceHandler(monitorID, workspaceID)
    }
    updatePanels()
  }

  private func moveSelectionVertically(_ action: OverviewKeyAction) {
    guard let snapshot,
      case .window(let windowID, let monitorID, let workspaceID) = selection,
      let window = snapshot.windows[windowID],
      window.transientOwnerID == nil,
      snapshot.nativeFullscreenWindowIDs.contains(windowID) == false,
      let monitor = snapshot.monitors.first(where: { $0.id == monitorID }),
      let workspaceIndex = monitor.workspaces.firstIndex(where: {
        $0.id == workspaceID
      })
    else { return }
    let workspace = monitor.workspaces[workspaceIndex]
    let delta = action == .moveUp ? -1 : 1
    let target: OverviewDropTarget
    if let columnIndex = workspace.columns.firstIndex(where: {
      $0.windows.contains(windowID)
    }),
      let windowIndex = workspace.columns[columnIndex].windows.firstIndex(of: windowID),
      workspace.columns[columnIndex].windows.indices.contains(windowIndex + delta)
    {
      target = .stack(
        monitorID: monitorID,
        workspaceID: workspaceID,
        columnIndex: columnIndex,
        windowIndex: delta < 0 ? windowIndex - 1 : windowIndex + 2
      )
    } else {
      let targetWorkspaceIndex = workspaceIndex + delta
      guard monitor.workspaces.indices.contains(targetWorkspaceIndex) else { return }
      let targetWorkspace = monitor.workspaces[targetWorkspaceIndex]
      if let columnIndex = workspace.columns.firstIndex(where: {
        $0.windows.contains(windowID)
      }) {
        target = .newColumn(
          monitorID: monitorID,
          workspaceID: targetWorkspace.id,
          columnIndex: min(columnIndex, targetWorkspace.columns.count)
        )
      } else {
        guard workspace.floatingWindows.contains(windowID),
          let monitorFrame = snapshot.monitorFrames[monitorID],
          let frame = snapshot.floatingFrames[windowID],
          monitorFrame.width > 0,
          monitorFrame.height > 0
        else { return }
        target = .floating(
          monitorID: monitorID,
          workspaceID: targetWorkspace.id,
          relativeFrame: Rect(
            x: (frame.x - monitorFrame.x) / monitorFrame.width,
            y: (frame.y - monitorFrame.y) / monitorFrame.height,
            width: frame.width / monitorFrame.width,
            height: frame.height / monitorFrame.height
          )
        )
      }
    }
    commitOverviewDrop(
      windowID: windowID,
      appID: window.appID,
      sourceMonitorID: monitorID,
      sourceWorkspaceID: workspaceID,
      target: target
    )
  }

  private func expectActivation(of processID: Int32?) {
    guard let processID else { return }
    expectedActivationGeneration &+= 1
    let generation = expectedActivationGeneration
    expectedActivationProcessID = pid_t(processID)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      guard let self, self.expectedActivationGeneration == generation else { return }
      self.expectedActivationProcessID = nil
    }
  }

  private func navigationTarget(
    from selection: OverviewSelection?,
    action: OverviewKeyAction,
    snapshot: OverviewSnapshot
  ) -> OverviewSelection? {
    guard let selection,
      let location = selection.location,
      let monitor = snapshot.monitors.first(where: { $0.id == location.monitorID }),
      let workspaceIndex = monitor.workspaces.firstIndex(where: {
        $0.id == location.workspaceID
      })
    else { return initialSelection(in: snapshot) }
    let workspace = monitor.workspaces[workspaceIndex]

    switch action {
    case .left, .right:
      let delta = action == .left ? -1 : 1
      if case .window(let windowID, _, _) = selection,
        let columnIndex = workspace.columns.firstIndex(where: {
          $0.windows.contains(windowID)
        })
      {
        let targetColumnIndex = columnIndex + delta
        guard workspace.columns.indices.contains(targetColumnIndex) else { return selection }
        let targetColumn = workspace.columns[targetColumnIndex]
        guard !targetColumn.windows.isEmpty else { return selection }
        let sourceWindowIndex = workspace.columns[columnIndex].windows.firstIndex(
          of: windowID
        ) ?? 0
        let targetWindowID = targetColumn.windows[
          min(sourceWindowIndex, targetColumn.windows.count - 1)
        ]
        return .window(
          windowID: targetWindowID,
          monitorID: monitor.id,
          workspaceID: workspace.id
        )
      }
      return firstSelection(in: workspace, monitorID: monitor.id) ?? selection
    case .up, .down:
      let delta = action == .up ? -1 : 1
      if case .window(let windowID, _, _) = selection,
        let columnIndex = workspace.columns.firstIndex(where: {
          $0.windows.contains(windowID)
        }),
        let windowIndex = workspace.columns[columnIndex].windows.firstIndex(of: windowID)
      {
        let targetWindowIndex = windowIndex + delta
        if workspace.columns[columnIndex].windows.indices.contains(targetWindowIndex) {
          return .window(
            windowID: workspace.columns[columnIndex].windows[targetWindowIndex],
            monitorID: monitor.id,
            workspaceID: workspace.id
          )
        }
      }
      let adjacentIndex = workspaceIndex + delta
      guard monitor.workspaces.indices.contains(adjacentIndex) else { return selection }
      return firstSelection(
        in: monitor.workspaces[adjacentIndex],
        monitorID: monitor.id
      ) ?? .workspace(
        monitorID: monitor.id,
        workspaceID: monitor.workspaces[adjacentIndex].id
      )
    case .moveUp, .moveDown, .select, .cancel:
      return selection
    }
  }

  private func firstSelection(
    in workspace: Workspace,
    monitorID: MonitorID
  ) -> OverviewSelection? {
    if workspace.focusedLayer == .floating,
      workspace.floatingWindows.indices.contains(workspace.focusedFloatingWindow)
    {
      return .window(
        windowID: workspace.floatingWindows[workspace.focusedFloatingWindow],
        monitorID: monitorID,
        workspaceID: workspace.id
      )
    }
    if workspace.columns.indices.contains(workspace.focusedColumn) {
      let column = workspace.columns[workspace.focusedColumn]
      if column.windows.indices.contains(column.focusedWindow) {
        return .window(
          windowID: column.windows[column.focusedWindow],
          monitorID: monitorID,
          workspaceID: workspace.id
        )
      }
    }
    if let windowID = workspace.columns.first?.windows.first
      ?? workspace.floatingWindows.first
    {
      return .window(
        windowID: windowID,
        monitorID: monitorID,
        workspaceID: workspace.id
      )
    }
    return nil
  }

  private func initialSelection(in snapshot: OverviewSnapshot) -> OverviewSelection? {
    guard let monitor = snapshot.activeMonitorID.flatMap({ activeID in
      snapshot.monitors.first(where: { $0.id == activeID })
    }) ?? snapshot.monitors.first,
      let workspace = monitor.workspaces.first(where: {
        $0.id == monitor.activeWorkspace
      })
    else { return nil }
    return firstSelection(in: workspace, monitorID: monitor.id)
      ?? .workspace(monitorID: monitor.id, workspaceID: workspace.id)
  }

  private func updatePanels(scheduleCaptures: Bool = true) {
    guard let snapshot else { return }
    var projections: [MonitorID: OverviewProjection] = [:]
    let now = CACurrentMediaTime()
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let previewOpacities = Dictionary(
      uniqueKeysWithValues: previewCache.keys.map { windowID in
        (
          windowID,
          overviewPreviewOpacity(
            startedAt: previewRevealStartedAt[windowID],
            now: now,
            reduceMotion: reduceMotion
          )
        )
      }
    )
    for (monitorID, panel) in panels {
      let target = projection(for: panel, snapshot: snapshot)
      let projection = displayedProjection(
        target: target,
        on: monitorID,
        now: now,
        reduceMotion: reduceMotion
      )
      projections[monitorID] = projection
      panel.view.update(
        snapshot: snapshot,
        projection: projection,
        selection: selection,
        drag: drag?.presentation(on: monitorID, panel: panel),
        borderStyle: borderStyle,
        windowCornerRadius: windowCornerRadius,
        previews: previewCache,
        previewOpacities: previewOpacities
      )
    }
    self.projections = projections
    if scheduleCaptures { schedulePreviewsIfNeeded() }
  }

  private func projection(
    for panel: OverviewPanel,
    snapshot: OverviewSnapshot
  ) -> OverviewProjection {
    projectOverview(
      snapshot: snapshot,
      monitorID: panel.monitorID,
      bounds: Rect(
        x: 0,
        y: 0,
        width: panel.view.bounds.width,
        height: panel.view.bounds.height
      ),
      viewport: viewports[panel.monitorID] ?? OverviewViewport(),
      layout: layout,
      zoom: overviewZoom
    )
  }

  private func displayedProjection(
    target: OverviewProjection,
    on monitorID: MonitorID,
    now: TimeInterval,
    reduceMotion: Bool
  ) -> OverviewProjection {
    guard animationsEnabled, !reduceMotion,
      let animation = projectionAnimations[monitorID]
    else {
      projectionAnimations[monitorID] = nil
      return target
    }
    let elapsed = now - animation.startedAt
    guard elapsed < animation.duration else {
      projectionAnimations[monitorID] = nil
      return target
    }
    return interpolateOverviewProjection(
      from: animation.from,
      to: animation.to,
      progress: animatedScalar(
        from: 0,
        to: 1,
        elapsed: elapsed,
        duration: animation.duration
      ),
      foregroundWindowID: selection?.windowID
    )
  }

  private func schedulePreviewsIfNeeded() {
    guard windowPreviewsEnabled, isOpen, previewTask == nil,
      previewPermissionState != .denied
    else { return }
    let requests = visiblePreviewRequests().filter {
      !attemptedPreviewWindowIDs.contains($0.windowID)
    }
    let hasPendingDesktopCapture = panels.keys.contains {
      !capturedDesktopMonitorIDs.contains($0)
    }
    guard overviewCaptureBatchNeeded(
      previewRequestCount: requests.count,
      hasPendingDesktopCapture: hasPendingDesktopCapture
    ) else { return }
    attemptedPreviewWindowIDs.formUnion(requests.map(\.windowID))
    previewPendingCount = requests.count
    let generation = sessionGeneration
    previewTask = Task { @MainActor [weak self] in
      await Task.yield()
      await self?.capturePreviewBatch(
        requests,
        generation: generation
      )
    }
  }

  private func capturePreviewBatch(
    _ requests: [OverviewPreviewRequest],
    generation: UInt64
  ) async {
    guard windowPreviewsEnabled, isOpen, generation == sessionGeneration,
      !Task.isCancelled
    else {
      finishPreviewBatch(generation: generation)
      return
    }
    let permissionGranted: Bool
    if CGPreflightScreenCaptureAccess() {
      permissionGranted = true
    } else if hasRequestedPreviewPermission {
      permissionGranted = false
    } else {
      hasRequestedPreviewPermission = true
      permissionGranted = await Task.detached(priority: .userInitiated) {
        CGRequestScreenCaptureAccess()
      }.value
    }
    guard windowPreviewsEnabled, isOpen, generation == sessionGeneration,
      !Task.isCancelled
    else {
      finishPreviewBatch(generation: generation)
      return
    }
    previewPermissionState = permissionGranted ? .granted : .denied
    guard permissionGranted, !Task.isCancelled else {
      finishPreviewBatch(generation: generation)
      return
    }

    let desktopRequests = desktopCaptureRequests()
    let results = await captureOverviewImages(
      previews: requests,
      desktops: desktopRequests
    )
    guard windowPreviewsEnabled, isOpen, generation == sessionGeneration,
      !Task.isCancelled
    else {
      finishPreviewBatch(generation: generation)
      return
    }
    capturedDesktopMonitorIDs = overviewRecordedDesktopCaptureMonitorIDs(
      existing: capturedDesktopMonitorIDs,
      requested: Set(desktopRequests.map(\.monitorID)),
      captured: Set(results.desktops.keys)
    )
    let currentRequests = Dictionary(
      uniqueKeysWithValues: visiblePreviewRequests().map { ($0.windowID, $0) }
    )
    let revealStartedAt = CACurrentMediaTime()
    var didAddPreview = false
    for (monitorID, image) in results.desktops {
      panels[monitorID]?.setDesktopImage(
        NSImage(cgImage: image, size: panels[monitorID]?.window.frame.size ?? .zero)
      )
    }
    for result in results.previews {
      let isCurrent = overviewPreviewRequestIsCurrent(
        result.request,
        generation: generation,
        currentGeneration: sessionGeneration,
        currentRequest: currentRequests[result.request.windowID],
        currentAppID: snapshot?.windows[result.request.windowID]?.appID
      )
      guard isCurrent else {
        previewFailureCount += 1
        continue
      }
      guard let image = result.image, image.width > 1, image.height > 1 else {
        previewCache[result.request.windowID] = nil
        forgetRememberedPreview(for: result.request.windowID)
        previewFailureCount += 1
        continue
      }
      let preview = NSImage(
        cgImage: image,
        size: NSSize(width: result.request.width, height: result.request.height)
      )
      let hadPreview = previewCache[result.request.windowID] != nil
      previewCache[result.request.windowID] = preview
      if let window = snapshot?.windows[result.request.windowID] {
        rememberPreview(
          preview,
          cgImage: image,
          for: window
        )
      }
      if !hadPreview {
        previewRevealStartedAt[result.request.windowID] = revealStartedAt
        didAddPreview = true
      }
    }
    finishPreviewBatch(generation: generation)
    if didAddPreview { startPreviewFadeAnimation() }
    updatePanels(scheduleCaptures: false)
  }

  private func finishPreviewBatch(generation: UInt64) {
    guard generation == sessionGeneration else { return }
    previewTask = nil
    previewPendingCount = 0
  }

  private func startPreviewFadeAnimation() {
    previewFadeTimer?.invalidate()
    guard animationsEnabled,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    else {
      previewFadeTimer = nil
      previewRevealStartedAt.removeAll(keepingCapacity: true)
      return
    }
    let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        guard self.isOpen else { return self.resetPreviewFadeAnimation() }
        let now = CACurrentMediaTime()
        let isAnimating = self.previewRevealStartedAt.values.contains {
          overviewPreviewOpacity(startedAt: $0, now: now, reduceMotion: false) < 1
        }
        if !isAnimating {
          self.resetPreviewFadeAnimation()
        }
        self.updatePanels()
      }
    }
    previewFadeTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func resetPreviewFadeAnimation() {
    previewFadeTimer?.invalidate()
    previewFadeTimer = nil
    previewRevealStartedAt.removeAll(keepingCapacity: true)
  }

  private func restoreRememberedPreviews(for snapshot: OverviewSnapshot) {
    guard windowPreviewsEnabled, CGPreflightScreenCaptureAccess() else {
      removeAllRememberedPreviews()
      return
    }
    pruneRememberedPreviews(for: snapshot)
    for (windowID, remembered) in rememberedPreviews {
      previewCache[windowID] = remembered.image
    }
  }

  private func pruneRememberedPreviews(for snapshot: OverviewSnapshot) {
    for (windowID, remembered) in rememberedPreviews {
      guard let window = snapshot.windows[windowID],
        window.appID == remembered.appID,
        window.processID == remembered.processID
      else {
        previewCache[windowID] = nil
        forgetRememberedPreview(for: windowID)
        continue
      }
    }
  }

  private func rememberPreview(
    _ image: NSImage,
    cgImage: CGImage,
    for window: Window
  ) {
    guard let processID = window.processID else {
      forgetRememberedPreview(for: window.id)
      return
    }
    let byteCost = cgImage.bytesPerRow * cgImage.height
    let canStore = overviewPreviewCacheCanStore(
      windowID: window.id,
      byteCost: byteCost,
      currentByteCosts: rememberedPreviewByteCosts,
      maximumBytes: Self.rememberedPreviewByteLimit
    )
    forgetRememberedPreview(for: window.id)
    guard canStore else { return }
    rememberedPreviews[window.id] = RememberedOverviewPreview(
      image: image,
      appID: window.appID,
      processID: processID
    )
    rememberedPreviewByteCosts[window.id] = byteCost
  }

  private func forgetRememberedPreview(for windowID: WindowID) {
    rememberedPreviews[windowID] = nil
    rememberedPreviewByteCosts[windowID] = nil
  }

  private func removeAllRememberedPreviews() {
    rememberedPreviews.removeAll(keepingCapacity: true)
    rememberedPreviewByteCosts.removeAll(keepingCapacity: true)
  }

  private func visiblePreviewRequests() -> [OverviewPreviewRequest] {
    guard let snapshot else { return [] }
    var requests: [OverviewPreviewRequest] = []
    for (monitorID, projection) in projections {
      let scale = min(panels[monitorID]?.window.backingScaleFactor ?? 1, 1)
      for card in projection.workspaces.flatMap(\.windows) {
        guard let window = snapshot.windows[card.windowID] else { continue }
        let width = min(max(Int((card.frame.width * scale).rounded(.up)), 32), 1_600)
        let height = min(max(Int((card.frame.height * scale).rounded(.up)), 24), 1_200)
        let titleBandHeight = overviewWindowTitleBandHeight(
          iconSize: overviewWindowTitleIconSize(cardHeight: card.frame.height)
        )
        requests.append(
          OverviewPreviewRequest(
            windowID: card.windowID,
            expectedAppID: window.appID,
            width: width,
            height: height,
            blurFadeHeight: Int(
              overviewPreviewBlurFadeHeight(
                titleBandHeight: titleBandHeight,
                imageScale: CGFloat(height) / card.frame.height,
                imageHeight: CGFloat(height)
              ).rounded(.up)
            )
          )
        )
      }
    }
    if let selectedWindowID = selection?.windowID,
      let index = requests.firstIndex(where: { $0.windowID == selectedWindowID })
    {
      requests.insert(requests.remove(at: index), at: 0)
    }
    var seen = Set<WindowID>()
    return requests.filter { seen.insert($0.windowID).inserted }
  }

  private func desktopCaptureRequests() -> [OverviewDesktopCaptureRequest] {
    panels.compactMap { monitorID, panel in
      guard !capturedDesktopMonitorIDs.contains(monitorID),
        let displayID = CGDirectDisplayID(exactly: monitorID.rawValue)
      else { return nil }
      return OverviewDesktopCaptureRequest(
        monitorID: monitorID,
        displayID: displayID,
        width: max(Int(panel.window.frame.width.rounded(.up)), 1),
        height: max(Int(panel.window.frame.height.rounded(.up)), 1)
      )
    }
  }

  private func screen(for monitorID: MonitorID) -> NSScreen? {
    NSScreen.screens.first { screen in
      (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? NSNumber)?.uint64Value == monitorID.rawValue
    }
  }

  private func animateViewport(
    on monitorID: MonitorID,
    to target: OverviewViewport
  ) {
    let current = viewports[monitorID] ?? target
    guard current != target else { return }
    guard animationsEnabled,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      let link = displayLink(on: monitorID)
    else {
      cancelAnimations(on: monitorID)
      viewports[monitorID] = target
      updatePanels()
      return
    }
    viewportAnimations[monitorID] = OverviewViewportAnimation(
      from: current,
      to: target,
      startedAt: CACurrentMediaTime(),
      duration: 0.16
    )
    projectionAnimations[monitorID] = nil
    link.isPaused = false
  }

  private func animateProjection(
    on monitorID: MonitorID,
    from source: OverviewProjection?
  ) {
    guard let source, let snapshot, let panel = panels[monitorID] else { return }
    let target = projection(for: panel, snapshot: snapshot)
    guard source != target,
      animationsEnabled,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      let link = displayLink(on: monitorID)
    else {
      projectionAnimations[monitorID] = nil
      return
    }
    projectionAnimations[monitorID] = OverviewProjectionAnimation(
      from: source,
      to: target,
      startedAt: CACurrentMediaTime(),
      duration: 0.16
    )
    link.isPaused = false
  }

  private func displayLink(on monitorID: MonitorID) -> CADisplayLink? {
    if let existing = viewportDisplayLinks[monitorID] { return existing }
    guard let screen = screen(for: monitorID) else { return nil }
    let link = screen.displayLink(
      target: self,
      selector: #selector(viewportDisplayLinkDidFire(_:))
    )
    link.add(to: .main, forMode: .common)
    viewportDisplayLinks[monitorID] = link
    displayLinkMonitorIDs[ObjectIdentifier(link)] = monitorID
    return link
  }

  @objc private func viewportDisplayLinkDidFire(_ link: CADisplayLink) {
    guard let monitorID = displayLinkMonitorIDs[ObjectIdentifier(link)] else {
      link.isPaused = true
      return
    }
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if let animation = viewportAnimations[monitorID] {
      let elapsed = CACurrentMediaTime() - animation.startedAt
      if !animationsEnabled || reduceMotion || elapsed >= animation.duration {
        viewports[monitorID] = animation.to
        viewportAnimations[monitorID] = nil
      } else {
        let progress = animatedScalar(
          from: 0,
          to: 1,
          elapsed: elapsed,
          duration: animation.duration
        )
        viewports[monitorID] = interpolateOverviewViewport(
          from: animation.from,
          to: animation.to,
          progress: progress
        )
      }
    }
    updatePanels()
    if viewportAnimations[monitorID] == nil,
      projectionAnimations[monitorID] == nil
    {
      link.isPaused = true
    }
  }

  private func cancelAnimations(on monitorID: MonitorID) {
    viewportAnimations[monitorID] = nil
    projectionAnimations[monitorID] = nil
    viewportDisplayLinks[monitorID]?.isPaused = true
  }

  private func stopOverviewAnimations() {
    viewportAnimations.removeAll(keepingCapacity: true)
    projectionAnimations.removeAll(keepingCapacity: true)
    for link in viewportDisplayLinks.values { link.invalidate() }
    viewportDisplayLinks.removeAll(keepingCapacity: true)
    displayLinkMonitorIDs.removeAll(keepingCapacity: true)
  }

  private func closePanelsImmediately() {
    stopOverviewAnimations()
    for panel in panels.values { panel.close() }
    panels.removeAll(keepingCapacity: true)
    isOpen = false
  }

  private func panelAndPoint(at screenPoint: NSPoint) -> (OverviewPanel, OverviewPoint)? {
    for panel in panels.values where panel.window.frame.contains(screenPoint) {
      let point = panel.localPoint(fromScreen: screenPoint)
      return (panel, OverviewPoint(x: point.x, y: point.y))
    }
    return nil
  }

  private func maximumHorizontalOffset(
    for workspaceID: WorkspaceID,
    on monitor: Monitor
  ) -> Double? {
    guard let snapshot,
      let monitorFrame = snapshot.monitorFrames[monitor.id],
      var workspace = monitor.workspaces.first(where: { $0.id == workspaceID })
    else { return nil }
    workspace.focusedColumn = max(workspace.columns.count - 1, 0)
    return focusedColumnLeftScrollOffset(
      workspace: workspace,
      viewport: Rect(x: 0, y: 0, width: monitorFrame.width, height: monitorFrame.height),
      windows: Array(snapshot.windows.values),
      settings: layout
    )
  }
}

@MainActor
extension OverviewController: OverviewViewDelegate {
  fileprivate func overviewView(
    _ view: OverviewView,
    clickedAt point: NSPoint
  ) {
    guard let projection = projections[view.monitorID],
      let hit = projection.hitTest(OverviewPoint(x: point.x, y: point.y)),
      let snapshot
    else { return }
    activateMonitorHandler(view.monitorID)
    switch hit {
    case .window(let windowID, let monitorID, let workspaceID):
      guard let window = snapshot.windows[windowID] else { return }
      close()
      focusWindowHandler(windowID, window.appID, monitorID, workspaceID)
    case .workspace(let monitorID, let workspaceID):
      close()
      focusWorkspaceHandler(monitorID, workspaceID)
    }
  }

  fileprivate func overviewView(
    _ view: OverviewView,
    beganDragging windowID: WindowID,
    at screenPoint: NSPoint
  ) {
    guard let snapshot,
      let window = snapshot.windows[windowID],
      let location = snapshot.location(of: windowID),
      let sourceProjection = projections[view.monitorID],
      let sourceCard = sourceProjection.workspaces.flatMap(\.windows).first(
        where: { $0.windowID == windowID && $0.canDrag }
      )
    else { return }
    cancelAnimations(on: view.monitorID)
    drag = OverviewDrag(
      windowID: windowID,
      appID: window.appID,
      sourceMonitorID: location.monitorID,
      sourceWorkspaceID: location.workspaceID,
      screenPoint: screenPoint,
      cardSize: NSSize(width: sourceCard.frame.width, height: sourceCard.frame.height),
      target: nil,
      targetMonitorID: nil
    )
    updateDrag(at: screenPoint)
  }

  fileprivate func overviewView(
    _ view: OverviewView,
    draggedTo screenPoint: NSPoint
  ) {
    updateDrag(at: screenPoint)
  }

  fileprivate func overviewView(
    _ view: OverviewView,
    endedDraggingAt screenPoint: NSPoint
  ) {
    guard let drag else { return }
    edgeScrollTimer?.invalidate()
    edgeScrollTimer = nil
    self.drag = nil
    updatePanels()
    guard let target = drag.target else { return }
    commitOverviewDrop(
      windowID: drag.windowID,
      appID: drag.appID,
      sourceMonitorID: drag.sourceMonitorID,
      sourceWorkspaceID: drag.sourceWorkspaceID,
      target: target
    )
  }

  fileprivate func overviewView(
    _ view: OverviewView,
    scrolled delta: NSPoint,
    hasPreciseScrollingDeltas: Bool,
    at point: NSPoint
  ) {
    guard let snapshot,
      let monitor = snapshot.monitors.first(where: { $0.id == view.monitorID })
    else { return }
    activateMonitorHandler(view.monitorID)
    let scrollAxis = overviewScrollAxis(for: delta)
    let workspaceID = scrollAxis == .horizontal
      ? projections[view.monitorID]?.hitTest(
        OverviewPoint(x: point.x, y: point.y)
      )?.workspaceID
      : nil
    let activeIndex = monitor.workspaces.firstIndex(where: {
      $0.id == monitor.activeWorkspace
    }) ?? 0
    let viewport: OverviewViewport
    if hasPreciseScrollingDeltas {
      cancelAnimations(on: view.monitorID)
      viewport = viewports[view.monitorID] ?? OverviewViewport()
    } else {
      viewport = viewportAnimations[view.monitorID]?.to
        ?? viewports[view.monitorID]
        ?? OverviewViewport()
    }
    let target = overviewViewportAfterScroll(
      viewport,
      delta: delta,
      hasPreciseScrollingDeltas: hasPreciseScrollingDeltas,
      viewSize: view.bounds.size,
      zoom: overviewZoom,
      activeWorkspaceIndex: activeIndex,
      workspaceCount: monitor.workspaces.count,
      horizontalWorkspaceID: workspaceID,
      maximumHorizontalOffset: workspaceID.flatMap {
        maximumHorizontalOffset(for: $0, on: monitor)
      }
    )
    if hasPreciseScrollingDeltas {
      guard target != viewport else { return }
      viewports[view.monitorID] = target
      updatePanels()
    } else {
      animateViewport(on: view.monitorID, to: target)
    }
  }

  fileprivate func overviewView(
    _ view: OverviewView,
    rightDraggedBy deltaX: Double,
    at point: NSPoint
  ) {
    guard let snapshot,
      let monitor = snapshot.monitors.first(where: { $0.id == view.monitorID }),
      let viewport = viewports[view.monitorID],
      let workspaceID = projections[view.monitorID]?.hitTest(
        OverviewPoint(x: point.x, y: point.y)
      )?.workspaceID,
      let maximumOffset = maximumHorizontalOffset(for: workspaceID, on: monitor)
    else { return }
    activateMonitorHandler(view.monitorID)
    cancelAnimations(on: view.monitorID)
    let activeIndex = monitor.workspaces.firstIndex(where: {
      $0.id == monitor.activeWorkspace
    }) ?? 0
    viewports[view.monitorID] = overviewViewportAfterScroll(
      viewport,
      delta: NSPoint(x: deltaX, y: 0),
      hasPreciseScrollingDeltas: true,
      viewSize: view.bounds.size,
      zoom: overviewZoom,
      activeWorkspaceIndex: activeIndex,
      workspaceCount: monitor.workspaces.count,
      horizontalWorkspaceID: workspaceID,
      maximumHorizontalOffset: maximumOffset
    )
    updatePanels()
  }

  fileprivate func overviewView(
    _ view: OverviewView,
    pageWorkspace workspaceID: WorkspaceID,
    direction: Int
  ) {
    guard let snapshot,
      let monitor = snapshot.monitors.first(where: { $0.id == view.monitorID }),
      let maximumOffset = maximumHorizontalOffset(for: workspaceID, on: monitor)
    else { return }
    var viewport = viewportAnimations[view.monitorID]?.to
      ?? viewports[view.monitorID]
      ?? OverviewViewport()
    activateMonitorHandler(view.monitorID)
    let currentOffset = viewport.horizontalOffsets[workspaceID] ?? 0
    viewport.horizontalOffsets[workspaceID] = min(
      max(currentOffset + Double(direction), 0),
      maximumOffset
    )
    animateViewport(on: view.monitorID, to: viewport)
  }

  private func updateDrag(at screenPoint: NSPoint) {
    guard var drag, let snapshot else { return }
    drag.screenPoint = screenPoint
    if let (panel, point) = panelAndPoint(at: screenPoint),
      let projection = projections[panel.monitorID]
    {
      drag.target = overviewDropTarget(
        at: point,
        sourceWindowID: drag.windowID,
        projection: projection,
        snapshot: snapshot
      )
      drag.targetMonitorID = panel.monitorID
      activateEdgeScroll(for: panel, localY: point.y)
    } else {
      drag.target = nil
      drag.targetMonitorID = nil
      edgeScrollTimer?.invalidate()
      edgeScrollTimer = nil
      edgeScrollDirection = nil
    }
    self.drag = drag
    updatePanels()
  }

  private func commitOverviewDrop(
    windowID: WindowID,
    appID: String,
    sourceMonitorID: MonitorID,
    sourceWorkspaceID: WorkspaceID,
    target: OverviewDropTarget
  ) {
    let location = target.location
    selection = .window(
      windowID: windowID,
      monitorID: location.monitorID,
      workspaceID: location.workspaceID
    )
    alignSelectionOnNextUpdate = true
    expectActivation(of: snapshot?.windows[windowID]?.processID)
    activateMonitorHandler(location.monitorID)
    dropHandler(
      windowID,
      appID,
      sourceMonitorID,
      sourceWorkspaceID,
      target
    )
  }

  private func activateEdgeScroll(for panel: OverviewPanel, localY: Double) {
    let margin = 56.0
    let direction: Double
    if localY < margin {
      direction = -1
    } else if localY > panel.view.bounds.height - margin {
      direction = 1
    } else {
      edgeScrollTimer?.invalidate()
      edgeScrollTimer = nil
      edgeScrollDirection = nil
      return
    }
    if edgeScrollDirection == direction { return }
    edgeScrollTimer?.invalidate()
    edgeScrollDirection = direction
    edgeScrollTimer = Timer.scheduledTimer(
      withTimeInterval: 0.15,
      repeats: true
    ) { [weak self, weak panel] _ in
      MainActor.assumeIsolated {
        guard let self, let panel,
          var viewport = self.viewports[panel.monitorID],
          let monitor = self.snapshot?.monitors.first(where: {
            $0.id == panel.monitorID
          })
        else { return }
        self.cancelAnimations(on: panel.monitorID)
        let activeIndex = monitor.workspaces.firstIndex(where: {
          $0.id == monitor.activeWorkspace
        }) ?? 0
        viewport.workspaceOffset = min(
          max(viewport.workspaceOffset + direction * 0.2, Double(-activeIndex)),
          Double(monitor.workspaces.count - activeIndex - 1)
        )
        self.viewports[panel.monitorID] = viewport
        self.updatePanels()
      }
    }
  }
}

private enum OverviewSelection: Equatable {
  case window(windowID: WindowID, monitorID: MonitorID, workspaceID: WorkspaceID)
  case workspace(monitorID: MonitorID, workspaceID: WorkspaceID)

  var location: (monitorID: MonitorID, workspaceID: WorkspaceID)? {
    switch self {
    case .window(_, let monitorID, let workspaceID),
      .workspace(let monitorID, let workspaceID):
      (monitorID, workspaceID)
    }
  }

  var windowID: WindowID? {
    if case .window(let windowID, _, _) = self { return windowID }
    return nil
  }

  func isValid(in snapshot: OverviewSnapshot) -> Bool {
    guard let location,
      let workspace = snapshot.monitors.first(where: {
        $0.id == location.monitorID
      })?.workspaces.first(where: { $0.id == location.workspaceID })
    else { return false }
    switch self {
    case .window(let windowID, _, _):
      return snapshot.windows[windowID] != nil
        && (workspace.columns.contains(where: { $0.windows.contains(windowID) })
          || workspace.floatingWindows.contains(windowID))
    case .workspace:
      return true
    }
  }
}

private struct OverviewLocation: Equatable {
  let monitorID: MonitorID
  let workspaceID: WorkspaceID
}

private struct OverviewTiledPosition: Equatable {
  let monitorID: MonitorID
  let workspaceID: WorkspaceID
  let columnIndex: Int
  let windowIndex: Int
}

private extension OverviewSnapshot {
  func location(of windowID: WindowID) -> OverviewLocation? {
    for monitor in monitors {
      for workspace in monitor.workspaces
      where workspace.columns.contains(where: { $0.windows.contains(windowID) })
        || workspace.floatingWindows.contains(windowID)
      {
        return OverviewLocation(monitorID: monitor.id, workspaceID: workspace.id)
      }
    }
    return nil
  }

  func tiledPosition(of windowID: WindowID) -> OverviewTiledPosition? {
    for monitor in monitors {
      for workspace in monitor.workspaces {
        for (columnIndex, column) in workspace.columns.enumerated() {
          guard let windowIndex = column.windows.firstIndex(of: windowID) else { continue }
          return OverviewTiledPosition(
            monitorID: monitor.id,
            workspaceID: workspace.id,
            columnIndex: columnIndex,
            windowIndex: windowIndex
          )
        }
      }
    }
    return nil
  }
}

private struct OverviewDrag {
  let windowID: WindowID
  let appID: String
  let sourceMonitorID: MonitorID
  let sourceWorkspaceID: WorkspaceID
  var screenPoint: NSPoint
  let cardSize: NSSize
  var target: OverviewDropTarget?
  var targetMonitorID: MonitorID?

  @MainActor
  func presentation(
    on monitorID: MonitorID,
    panel: OverviewPanel
  ) -> OverviewDragPresentation {
    let localPoint = targetMonitorID == monitorID
      ? panel.localPoint(fromScreen: screenPoint)
      : nil
    return OverviewDragPresentation(
      windowID: windowID,
      localPoint: localPoint,
      cardSize: cardSize,
      target: targetMonitorID == monitorID ? target : nil
    )
  }
}

private struct OverviewDragPresentation {
  let windowID: WindowID
  let localPoint: NSPoint?
  let cardSize: NSSize
  let target: OverviewDropTarget?
}

private extension OverviewHit {
  var workspaceID: WorkspaceID {
    switch self {
    case .window(_, _, let workspaceID), .workspace(_, let workspaceID):
      workspaceID
    }
  }
}

private extension OverviewDropTarget {
  var location: (monitorID: MonitorID, workspaceID: WorkspaceID) {
    switch self {
    case .newColumn(let monitorID, let workspaceID, _),
      .stack(let monitorID, let workspaceID, _, _),
      .floating(let monitorID, let workspaceID, _):
      (monitorID, workspaceID)
    }
  }
}

@MainActor
private protocol OverviewViewDelegate: AnyObject {
  func overviewView(_ view: OverviewView, clickedAt point: NSPoint)
  func overviewView(_ view: OverviewView, beganDragging windowID: WindowID, at: NSPoint)
  func overviewView(_ view: OverviewView, draggedTo: NSPoint)
  func overviewView(_ view: OverviewView, endedDraggingAt: NSPoint)
  func overviewView(
    _ view: OverviewView,
    scrolled delta: NSPoint,
    hasPreciseScrollingDeltas: Bool,
    at: NSPoint
  )
  func overviewView(_ view: OverviewView, rightDraggedBy deltaX: Double, at: NSPoint)
  func overviewView(_ view: OverviewView, pageWorkspace: WorkspaceID, direction: Int)
}

@MainActor
private final class OverviewPanel {
  let monitorID: MonitorID
  let usesCapturedDesktop: Bool
  let window: NSPanel
  let view: OverviewView
  private let desktopView: NSView

  init(
    monitorID: MonitorID,
    screen: NSScreen,
    usesCapturedDesktop: Bool,
    delegate: OverviewViewDelegate
  ) {
    self.monitorID = monitorID
    self.usesCapturedDesktop = usesCapturedDesktop
    view = OverviewView(monitorID: monitorID, delegate: delegate)
    desktopView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
    window = NSPanel(
      contentRect: screen.frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false,
      screen: screen
    )
    window.setFrame(screen.frame, display: false)
    window.title = "Defi Overview"
    window.setAccessibilityLabel("Defi Overview")
    window.isOpaque = usesCapturedDesktop
    window.backgroundColor = usesCapturedDesktop ? .black : .clear
    window.hasShadow = false
    window.hidesOnDeactivate = false
    window.isReleasedWhenClosed = false
    window.isExcludedFromWindowsMenu = true
    window.animationBehavior = .none
    window.level = .statusBar
    window.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .stationary,
      .ignoresCycle,
    ]
    window.sharingType = .readOnly
    let rootView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
    rootView.wantsLayer = true
    rootView.layer?.backgroundColor = usesCapturedDesktop
      ? NSColor.black.cgColor
      : NSColor.clear.cgColor
    rootView.autoresizingMask = [.width, .height]
    desktopView.wantsLayer = true
    desktopView.layer?.backgroundColor = usesCapturedDesktop
      ? NSColor.black.cgColor
      : NSColor.clear.cgColor
    desktopView.layer?.contentsGravity = .resizeAspectFill
    desktopView.layer?.contentsScale = screen.backingScaleFactor
    desktopView.layer?.masksToBounds = true
    desktopView.autoresizingMask = [.width, .height]
    if let url = NSWorkspace.shared.desktopImageURL(for: screen),
      let image = NSImage(contentsOf: url)
    {
      if usesCapturedDesktop {
        desktopView.layer?.contents = image
      }
      view.setDesktopImage(image)
    }
    let glassView = NSGlassEffectView(
      frame: NSRect(origin: .zero, size: screen.frame.size)
    )
    glassView.style = .regular
    glassView.appearance = NSAppearance(named: .darkAqua)
    glassView.autoresizingMask = [.width, .height]
    view.frame = glassView.bounds
    view.autoresizingMask = [.width, .height]
    glassView.contentView = view
    rootView.addSubview(desktopView)
    rootView.addSubview(glassView)
    window.contentView = rootView
  }

  func setDesktopImage(_ image: NSImage) {
    desktopView.layer?.contents = image
    view.setDesktopImage(image)
  }

  func show(animated: Bool) {
    window.alphaValue = animated ? 0.001 : 1
    view.wantsLayer = true
    view.layer?.setAffineTransform(animated ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity)
    window.orderFrontRegardless()
    guard animated else { return }
    window.displayIfNeeded()
    let displayInterval = 1 / Double(max(window.screen?.maximumFramesPerSecond ?? 60, 60))
    DispatchQueue.main.asyncAfter(deadline: .now() + displayInterval) { [weak self] in
      guard let self else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.16
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        self.window.animator().alphaValue = 1
        self.view.layer?.setAffineTransform(.identity)
      }
    }
  }

  func hide() {
    orderOut()
  }

  func localPoint(fromScreen point: NSPoint) -> NSPoint {
    let windowPoint = window.convertPoint(fromScreen: point)
    return view.convert(windowPoint, from: nil)
  }

  func close() {
    orderOut()
    desktopView.layer?.contents = nil
    window.close()
  }

  private func orderOut() {
    view.discardPreviewImages()
    window.orderOut(nil)
  }
}

@MainActor
private final class OverviewView: NSView {
  let monitorID: MonitorID
  private weak var delegate: OverviewViewDelegate?
  private var snapshot: OverviewSnapshot?
  private var projection: OverviewProjection?
  private var selection: OverviewSelection?
  private var drag: OverviewDragPresentation?
  private var borderStyle = WindowBorderStyle(config: BordersConfig())
  private var windowCornerRadius = 12.0
  private var desktopImage: NSImage?
  private var previews: [WindowID: NSImage] = [:]
  private var previewOpacities: [WindowID: Double] = [:]
  private var mouseDownPoint: NSPoint?
  private var mouseDownWindowID: WindowID?
  private var mouseDownOverflow: (workspaceID: WorkspaceID, direction: Int)?
  private var leftDragStarted = false
  private var rightDragPoint: NSPoint?
  private var iconCache: [String: NSImage] = [:]

  override var isFlipped: Bool { true }

  init(monitorID: MonitorID, delegate: OverviewViewDelegate) {
    self.monitorID = monitorID
    self.delegate = delegate
    super.init(frame: .zero)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Defi Overview")
  }

  func discardPreviewImages() {
    previews.removeAll(keepingCapacity: false)
  }

  func setDesktopImage(_ image: NSImage) {
    desktopImage = image
    needsDisplay = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  func update(
    snapshot: OverviewSnapshot,
    projection: OverviewProjection,
    selection: OverviewSelection?,
    drag: OverviewDragPresentation?,
    borderStyle: WindowBorderStyle,
    windowCornerRadius: Double,
    previews: [WindowID: NSImage],
    previewOpacities: [WindowID: Double]
  ) {
    self.snapshot = snapshot
    self.projection = projection
    self.selection = selection
    self.drag = drag
    self.borderStyle = borderStyle
    self.windowCornerRadius = windowCornerRadius
    self.previews = previews
    self.previewOpacities = previewOpacities
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let projection, let snapshot else { return }
    for workspace in projection.workspaces {
      drawWorkspace(workspace, snapshot: snapshot)
    }
    if let overlayWindowID = projection.overlayWindowID,
      let workspace = projection.workspaces.first(where: {
        $0.windows.contains { $0.windowID == overlayWindowID }
      }),
      let overlay = workspace.windows.first(where: { $0.windowID == overlayWindowID })
    {
      drawWindow(overlay, snapshot: snapshot)
      drawWindowBorder(overlay, scale: contentScale(for: workspace, snapshot: snapshot))
    }
    drawDraggedCard(snapshot: snapshot)
    drawDropTarget()
  }

  override func accessibilityChildren() -> [Any]? {
    guard let projection, let snapshot, let window else { return [] }
    return projection.workspaces.flatMap { workspace -> [NSAccessibilityElement] in
      let workspaceElement = NSAccessibilityElement()
      workspaceElement.setAccessibilityParent(self)
      workspaceElement.setAccessibilityRole(.group)
      workspaceElement.setAccessibilityEnabled(true)
      workspaceElement.setAccessibilityLabel("Workspace \(workspace.label)")
      workspaceElement.setAccessibilityFrame(
        window.convertToScreen(convert(nsRect(workspace.frame), to: nil))
      )
      let windowElements = workspace.windows.compactMap { card -> NSAccessibilityElement? in
        guard let managedWindow = snapshot.windows[card.windowID] else { return nil }
        let visibleFrame = nsRect(card.frame).intersection(nsRect(workspace.frame))
        guard !visibleFrame.isEmpty else { return nil }
        let element = OverviewAccessibilityElement { [weak self] in
          guard let self else { return }
          self.delegate?.overviewView(
            self,
            clickedAt: NSPoint(x: visibleFrame.midX, y: visibleFrame.midY)
          )
        }
        element.setAccessibilityParent(self)
        element.setAccessibilityRole(.button)
        element.setAccessibilityEnabled(true)
        element.setAccessibilityLabel(
          managedWindow.title.isEmpty ? managedWindow.appID : managedWindow.title
        )
        element.setAccessibilityHelp("Workspace \(workspace.label)")
        element.setAccessibilitySelected(selection?.windowID == card.windowID)
        element.setAccessibilityFrame(
          window.convertToScreen(convert(visibleFrame, to: nil))
        )
        return element
      }
      return [workspaceElement] + windowElements
    }
  }

  private func drawWorkspace(
    _ workspace: OverviewWorkspaceProjection,
    snapshot: OverviewSnapshot
  ) {
    let frame = nsRect(workspace.frame)
    let scale = contentScale(for: workspace, snapshot: snapshot)
    drawVisibleDesktop(for: workspace)
    NSGraphicsContext.saveGraphicsState()
    frame.clip()
    for window in workspace.windows
    where window.layer != .floating
      && drag?.windowID != window.windowID
      && projection?.overlayWindowID != window.windowID
    {
      drawWindow(window, snapshot: snapshot)
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    nsRect(workspace.visibleFrame).clip()
    for window in workspace.windows
    where window.layer == .floating
      && drag?.windowID != window.windowID
      && projection?.overlayWindowID != window.windowID
    {
      drawWindow(window, snapshot: snapshot)
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    let borderWidth = borderStyle.width * scale
    frame.insetBy(dx: -borderWidth, dy: -borderWidth).clip()
    for window in workspace.windows
    where window.layer != .floating
      && drag?.windowID != window.windowID
      && projection?.overlayWindowID != window.windowID
    {
      drawWindowBorder(window, scale: scale)
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    nsRect(workspace.visibleFrame).insetBy(
      dx: -borderWidth,
      dy: -borderWidth
    ).clip()
    for window in workspace.windows
    where window.layer == .floating
      && drag?.windowID != window.windowID
      && projection?.overlayWindowID != window.windowID
    {
      drawWindowBorder(window, scale: scale)
    }
    NSGraphicsContext.restoreGraphicsState()
    drawHorizontalOverflowIndicators(for: workspace)
  }

  private func drawVisibleDesktop(for workspace: OverviewWorkspaceProjection) {
    let frame = nsRect(workspace.visibleFrame)
    let path = NSBezierPath(
      roundedRect: frame,
      xRadius: windowCornerRadius,
      yRadius: windowCornerRadius
    )
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    if let desktopImage {
      desktopImage.draw(
        in: frame,
        from: aspectFillSourceRect(for: desktopImage, in: frame),
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
      )
    } else {
      NSColor.windowBackgroundColor.setFill()
      path.fill()
    }
    NSColor.black.withAlphaComponent(0.12).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
  }

  private func aspectFillSourceRect(for image: NSImage, in frame: NSRect) -> NSRect {
    guard image.size.width > 0, image.size.height > 0, frame.width > 0, frame.height > 0
    else { return .zero }
    let imageRatio = image.size.width / image.size.height
    let frameRatio = frame.width / frame.height
    if imageRatio > frameRatio {
      let width = image.size.height * frameRatio
      return NSRect(
        x: (image.size.width - width) / 2,
        y: 0,
        width: width,
        height: image.size.height
      )
    }
    let height = image.size.width / frameRatio
    return NSRect(
      x: 0,
      y: (image.size.height - height) / 2,
      width: image.size.width,
      height: height
    )
  }

  private func drawWindow(
    _ card: OverviewWindowProjection,
    snapshot: OverviewSnapshot
  ) {
    guard let window = snapshot.windows[card.windowID] else { return }
    let frame = nsRect(card.frame)
    let path = NSBezierPath(
      roundedRect: frame,
      xRadius: windowCornerRadius,
      yRadius: windowCornerRadius
    )
    NSColor(calibratedWhite: card.isNativeFullscreen ? 0.19 : 0.15, alpha: 1).setFill()
    path.fill()
    let iconSize = overviewWindowTitleIconSize(cardHeight: frame.height)
    let titleBandHeight = overviewWindowTitleBandHeight(iconSize: iconSize)
    let titleFadeHeight = overviewPreviewBlurFadeHeight(
      titleBandHeight: titleBandHeight,
      imageScale: 1,
      imageHeight: frame.height
    )
    if let preview = previews[card.windowID] {
      let opacity = previewOpacities[card.windowID] ?? 1
      NSGraphicsContext.saveGraphicsState()
      path.addClip()
      preview.draw(
        in: frame,
        from: .zero,
        operation: .sourceOver,
        fraction: opacity,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
      )
      NSGradient(
        colorsAndLocations:
          (NSColor.black.withAlphaComponent(
            overviewTitleScrimAlpha(progress: 0, opacity: CGFloat(opacity))
          ), 0),
          (NSColor.black.withAlphaComponent(
            overviewTitleScrimAlpha(progress: 0.25, opacity: CGFloat(opacity))
          ), 0.25),
          (NSColor.black.withAlphaComponent(
            overviewTitleScrimAlpha(progress: 0.5, opacity: CGFloat(opacity))
          ), 0.5),
          (NSColor.black.withAlphaComponent(
            overviewTitleScrimAlpha(progress: 0.75, opacity: CGFloat(opacity))
          ), 0.75),
          (NSColor.black.withAlphaComponent(
            overviewTitleScrimAlpha(progress: 0.9, opacity: CGFloat(opacity))
          ), 0.9),
          (NSColor.black.withAlphaComponent(
            overviewTitleScrimAlpha(progress: 0.97, opacity: CGFloat(opacity))
          ), 0.97),
          (NSColor.clear, 1)
      )?.draw(
        from: NSPoint(x: frame.midX, y: frame.minY),
        to: NSPoint(x: frame.midX, y: frame.minY + titleFadeHeight),
        options: []
      )
      NSGraphicsContext.restoreGraphicsState()
    }
    let title = (window.title.isEmpty ? window.appID : window.title) as NSString
    let titleAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: min(13, max(frame.height * 0.09, 10)), weight: .medium),
      .foregroundColor: NSColor.white.withAlphaComponent(0.9),
    ]
    let titleLayout = overviewWindowTitleLayout(
      cardFrame: frame,
      iconSize: iconSize,
      titleSize: title.size(withAttributes: titleAttributes),
      blurHeight: titleBandHeight
    )
    let icon = icon(for: window)
    icon.draw(in: titleLayout.iconFrame)
    title.draw(in: titleLayout.titleFrame, withAttributes: titleAttributes)
    if card.isNativeFullscreen {
      let label = "Full Screen" as NSString
      label.draw(
        at: NSPoint(x: frame.minX + 10, y: frame.maxY - 26),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
          .foregroundColor: NSColor.white.withAlphaComponent(0.58),
        ]
      )
    }
  }

  private func drawWindowBorder(_ card: OverviewWindowProjection, scale: Double) {
    let selected = selection == .window(
      windowID: card.windowID,
      monitorID: monitorID,
      workspaceID: selection?.location?.workspaceID ?? WorkspaceID(rawValue: "")
    )
    if let border = overviewWindowBorderAppearance(
      isSelected: selected,
      style: borderStyle,
      scale: scale
    ) {
      overviewBorderColor(border.color).setStroke()
      let geometry = overviewWindowBorderGeometry(
        cardFrame: card.frame,
        cardRadius: windowCornerRadius,
        width: border.width,
        placement: borderStyle.placement
      )
      let borderPath = NSBezierPath(
        roundedRect: nsRect(geometry.frame),
        xRadius: geometry.radius,
        yRadius: geometry.radius
      )
      borderPath.lineWidth = border.width
      borderPath.stroke()
    }
  }

  private func contentScale(
    for workspace: OverviewWorkspaceProjection,
    snapshot: OverviewSnapshot
  ) -> Double {
    guard let monitorFrame = snapshot.monitorFrames[monitorID], monitorFrame.height > 0 else {
      return 1
    }
    return workspace.frame.height / monitorFrame.height
  }

  private func drawHorizontalOverflowIndicators(
    for workspace: OverviewWorkspaceProjection
  ) {
    if workspace.hiddenTiledWindowCountBefore > 0 {
      drawHorizontalOverflowIndicator(
        "\u{2190} \(workspace.hiddenTiledWindowCountBefore)",
        leading: true,
        in: nsRect(workspace.frame)
      )
    }
    if workspace.hiddenTiledWindowCountAfter > 0 {
      drawHorizontalOverflowIndicator(
        "\(workspace.hiddenTiledWindowCountAfter) \u{2192}",
        leading: false,
        in: nsRect(workspace.frame)
      )
    }
  }

  private func drawHorizontalOverflowIndicator(
    _ label: String,
    leading: Bool,
    in frame: NSRect
  ) {
    let indicatorFrame = horizontalOverflowIndicatorFrame(leading: leading, in: frame)
    let path = NSBezierPath(roundedRect: indicatorFrame, xRadius: 15, yRadius: 15)
    NSColor.black.withAlphaComponent(0.72).setFill()
    path.fill()
    (label as NSString).draw(
      in: indicatorFrame.insetBy(dx: 8, dy: 6),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        .paragraphStyle: centeredParagraphStyle,
      ]
    )
  }

  private var centeredParagraphStyle: NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    return style
  }

  private func icon(for window: Window) -> NSImage {
    if let cached = iconCache[window.appID] { return cached }
    let icon = window.processID.flatMap {
      NSRunningApplication(processIdentifier: pid_t($0))?.icon
    } ?? NSImage(systemSymbolName: "app", accessibilityDescription: window.appID)
      ?? NSImage(size: NSSize(width: 24, height: 24))
    iconCache[window.appID] = icon
    return icon
  }

  private func overviewBorderColor(_ value: UInt32) -> NSColor {
    NSColor(
      srgbRed: CGFloat((value >> 16) & 0xff) / 255,
      green: CGFloat((value >> 8) & 0xff) / 255,
      blue: CGFloat(value & 0xff) / 255,
      alpha: CGFloat(windowBorderAlpha(of: value)) / 255
    )
  }

  private func drawDropTarget() {
    guard let target = drag?.target, let projection else { return }
    NSColor.controlAccentColor.setStroke()
    switch target {
    case .newColumn(_, let workspaceID, let columnIndex):
      guard let workspace = projection.workspaces.first(where: {
        $0.workspaceID == workspaceID
      }) else { return }
      let columns = workspace.windows.compactMap { window -> (Int, Rect)? in
        guard case .tiled(let index, _) = window.layer else { return nil }
        return (index, window.frame)
      }
      let x = columns.filter { $0.0 == columnIndex }.map(\.1.x).min()
        ?? columns.map { $0.1.x + $0.1.width }.max()
        ?? workspace.frame.x + 8
      let band = NSBezierPath(
        roundedRect: NSRect(
          x: x - 10,
          y: workspace.frame.y + 8,
          width: 20,
          height: workspace.frame.height - 16
        ),
        xRadius: 10,
        yRadius: 10
      )
      NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
      band.fill()
      NSColor.controlAccentColor.setStroke()
      let path = NSBezierPath()
      path.move(to: NSPoint(x: x, y: workspace.frame.y + 12))
      path.line(to: NSPoint(x: x, y: workspace.frame.y + workspace.frame.height - 12))
      path.lineWidth = 3
      path.stroke()
    case .stack(_, let workspaceID, let columnIndex, let windowIndex):
      let cards = projection.workspaces.first(where: {
        $0.workspaceID == workspaceID
      })?.windows.filter {
        if case .tiled(let index, _) = $0.layer { return index == columnIndex }
        return false
      }.sorted { $0.frame.y < $1.frame.y } ?? []
      guard let first = cards.first, let last = cards.last else { return }
      let y = windowIndex < cards.count
        ? cards[windowIndex].frame.y
        : last.frame.y + last.frame.height
      let path = NSBezierPath()
      path.move(to: NSPoint(x: first.frame.x + 8, y: y))
      path.line(to: NSPoint(x: first.frame.x + first.frame.width - 8, y: y))
      path.lineWidth = 4
      path.stroke()
    case .floating:
      break
    }
  }

  private func drawDraggedCard(snapshot: OverviewSnapshot) {
    guard let drag, let point = drag.localPoint,
      let window = snapshot.windows[drag.windowID]
    else { return }
    let frame = NSRect(
      x: point.x - drag.cardSize.width / 2,
      y: point.y - drag.cardSize.height / 2,
      width: drag.cardSize.width,
      height: drag.cardSize.height
    )
    let path = NSBezierPath(
      roundedRect: frame,
      xRadius: windowCornerRadius,
      yRadius: windowCornerRadius
    )
    NSColor(calibratedWhite: 0.18, alpha: 0.94).setFill()
    path.fill()
    NSColor.controlAccentColor.setStroke()
    path.lineWidth = 3
    path.stroke()
    ((window.title.isEmpty ? window.appID : window.title) as NSString).draw(
      in: frame.insetBy(dx: 12, dy: 10),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: NSColor.white,
      ]
    )
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    mouseDownPoint = point
    mouseDownOverflow = horizontalOverflowAction(at: point)
    if mouseDownOverflow == nil {
      mouseDownWindowID = projection?.hitTest(
        OverviewPoint(x: point.x, y: point.y)
      ).flatMap { hit in
        if case .window(let windowID, _, _) = hit { return windowID }
        return nil
      }
    } else {
      mouseDownWindowID = nil
    }
    leftDragStarted = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = mouseDownPoint, let windowID = mouseDownWindowID else { return }
    let point = convert(event.locationInWindow, from: nil)
    let screenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
    if !leftDragStarted, hypot(point.x - start.x, point.y - start.y) >= 5 {
      leftDragStarted = true
      delegate?.overviewView(self, beganDragging: windowID, at: screenPoint)
    }
    if leftDragStarted {
      delegate?.overviewView(self, draggedTo: screenPoint)
    }
  }

  override func mouseUp(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if leftDragStarted {
      let screenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
      delegate?.overviewView(self, endedDraggingAt: screenPoint)
    } else if let pressed = mouseDownOverflow,
      let released = horizontalOverflowAction(at: point),
      pressed.workspaceID == released.workspaceID,
      pressed.direction == released.direction
    {
      delegate?.overviewView(
        self,
        pageWorkspace: released.workspaceID,
        direction: released.direction
      )
    } else {
      delegate?.overviewView(self, clickedAt: point)
    }
    mouseDownPoint = nil
    mouseDownWindowID = nil
    mouseDownOverflow = nil
    leftDragStarted = false
  }

  override func rightMouseDown(with event: NSEvent) {
    rightDragPoint = convert(event.locationInWindow, from: nil)
  }

  override func rightMouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let previous = rightDragPoint else { return }
    delegate?.overviewView(self, rightDraggedBy: point.x - previous.x, at: point)
    rightDragPoint = point
  }

  override func rightMouseUp(with event: NSEvent) {
    rightDragPoint = nil
  }

  override func scrollWheel(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    delegate?.overviewView(
      self,
      scrolled: NSPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY),
      hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
      at: point
    )
  }

  private func nsRect(_ rect: Rect) -> NSRect {
    NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
  }

  private func horizontalOverflowAction(
    at point: NSPoint
  ) -> (workspaceID: WorkspaceID, direction: Int)? {
    guard let projection else { return nil }
    for workspace in projection.workspaces.reversed() {
      let frame = nsRect(workspace.frame)
      if workspace.hiddenTiledWindowCountBefore > 0,
        horizontalOverflowIndicatorFrame(leading: true, in: frame).contains(point)
      {
        return (workspace.workspaceID, -1)
      }
      if workspace.hiddenTiledWindowCountAfter > 0,
        horizontalOverflowIndicatorFrame(leading: false, in: frame).contains(point)
      {
        return (workspace.workspaceID, 1)
      }
    }
    return nil
  }

  private func horizontalOverflowIndicatorFrame(
    leading: Bool,
    in frame: NSRect
  ) -> NSRect {
    let size = NSSize(width: 46, height: 30)
    return NSRect(
      x: leading ? frame.minX + 12 : frame.maxX - size.width - 12,
      y: frame.midY - size.height / 2,
      width: size.width,
      height: size.height
    )
  }
}

func overviewWindowTitleIconSize(cardHeight: CGFloat) -> CGFloat {
  min(24, max(cardHeight * 0.16, 14))
}

func overviewWindowTitleBandHeight(iconSize: CGFloat) -> CGFloat {
  iconSize + 20
}

func overviewTitleScrimAlpha(progress: CGFloat, opacity: CGFloat) -> CGFloat {
  let remaining = 1 - min(max(progress, 0), 1)
  return 0.48 * opacity * remaining * remaining
}

func overviewWindowTitleLayout(
  cardFrame: CGRect,
  iconSize: CGFloat,
  titleSize: CGSize,
  blurHeight: CGFloat
) -> (iconFrame: CGRect, titleFrame: CGRect) {
  let spacing = 8.0
  let titleWidth = min(titleSize.width, max(cardFrame.width - iconSize - spacing - 20, 1))
  let iconX = cardFrame.minX + 10
  let centerY = cardFrame.minY + blurHeight / 2
  return (
    CGRect(
      x: iconX,
      y: centerY - iconSize / 2,
      width: iconSize,
      height: iconSize
    ),
    CGRect(
      x: iconX + iconSize + spacing,
      y: centerY - titleSize.height / 2,
      width: titleWidth,
      height: titleSize.height
    )
  )
}

@MainActor
private final class OverviewAccessibilityElement: NSAccessibilityElement {
  private nonisolated let press: @MainActor @Sendable () -> Void

  init(press: @escaping @MainActor @Sendable () -> Void) {
    self.press = press
    super.init()
  }

  nonisolated override func accessibilityPerformPress() -> Bool {
    let press = press
    Task { @MainActor in press() }
    return true
  }
}
