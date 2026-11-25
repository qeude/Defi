import DefiCore
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation

/// A scroll gesture moving one monitor's strip (sideways) or workspace stack (vertical),
/// as Niri's touchpad swipes do. Shifts are in points along the axis, in global
/// coordinates: positive moves content right, or down.
struct ScrollPan {
  let id: UInt64
  let vertical: Bool
  let monitorID: MonitorID
  let workspaceID: WorkspaceID
  let viewport: Rect
  /// Where the overlay drew the content when the gesture began, from rest.
  let start: Double
  let scale: Double
  let bounds: ClosedRange<Double>
  let dimension: Double
  let stiffness: Double
  /// Sideways: the resting offset, and the strip width offsets are measured in.
  let rest: Double
  let stripWidth: Double
  /// Vertical: the workspace index the gesture started on, and the height of one step.
  let workspaceHeight: Double
  /// Vertical: how many workspaces up (negative) or down it may reach.
  let steps: ClosedRange<Int>

  func shift(travel: Double) -> Double {
    rubberBanded(start + travel * scale, bounds: bounds, dimension: dimension, stiffness: stiffness)
  }

  /// Vertical: the workspace step a release lands on, Niri's projected position rounded to the
  /// nearest workspace in reach.
  func step(travel: Double, momentum: Double = 0) -> Int {
    min(max(Int(((start + (travel + momentum) * scale) / -workspaceHeight).rounded()), steps.lowerBound),
      steps.upperBound)
  }

  /// Sideways: where a release at `travel` settles, carrying on by `momentum` travel.
  func landing(travel: Double, momentum: Double = 0, workspace: Workspace, windows: [Window],
    settings: LayoutSettings, snaps: Bool) -> (column: Int, offset: Double, focus: ScrollFocus?)? {
    let current = rest - shift(travel: travel) / stripWidth
    let projected = rest - (start + (travel + momentum) * scale) / stripWidth
    return snaps
      ? scrollGestureSnap(workspace: workspace, viewport: viewport, windows: windows, settings: settings,
        rest: rest, current: current, projected: projected)
      : scrollGestureFreeRest(workspace: workspace, viewport: viewport, windows: windows, settings: settings,
        current: current, projected: projected)
  }
}

/// How far a released flick carries, as seconds of its speed: Niri's deceleration (0.997/ms).
let scrollPanProjection = -1 / (1_000 * log(0.997))

/// The display under the pointer when the gesture starts, as Niri's output under the cursor.
func scrollPanMonitorID(at location: CGPoint, displays: [(MonitorID, Rect)]) -> MonitorID? {
  let point = Rect(x: Double(location.x), y: Double(location.y), width: 0, height: 0)
  return displays.first { $0.1.contains(centerOf: point) }?.0
}

@NavigationActor
extension Daemon {
  func handleScrollGesture(_ action: ScrollGestureAction) {
    guard desktopSessionActive, !shouldShutdown, !restorationInFlight, !overviewState.isOpen else {
      cancelScrollPan()
      return
    }
    switch action {
    case .panBegan(let id, let vertical, let location, _):
      beginScrollPan(id, vertical: vertical, at: location)
    case .panEnded(let id, let travel, let velocity, let timestamp):
      endScrollPan(id, travel: travel, velocity: velocity, timestamp: timestamp)
    case .focusColumn(let direction, let timestamp):
      _ = handle("focus-column \(direction.rawValue)", inputTimestamp: timestamp)
    case .focusWorkspace(let direction, let timestamp):
      _ = handle("focus-workspace \(direction.rawValue)", inputTimestamp: timestamp)
    }
  }

  /// Another input took over: the windows show where they really are.
  func cancelScrollPan() {
    guard scrollPan != nil else { return }
    scrollPan = nil
    platform.cancelScrollPan()
  }

  private func beginScrollPan(_ id: UInt64, vertical: Bool, at location: CGPoint) {
    cancelScrollPan()
    guard
      let monitorID = scrollPanMonitorID(at: location, displays: latestMonitors.map { ($0.id, $0.physicalFrame) })
        ?? activeMonitorID,
      let display = latestMonitors.first(where: { $0.id == monitorID })?.physicalFrame,
      let viewport = viewportsByMonitor[monitorID]
    else { return }
    // The gesture overrides any motion or focus still on its way.
    commandGeneration &+= 1
    focus.queueCommand(nil)
    invalidateSubmittedCommandFocus()
    preemptMouseGesture()
    snapScrollOffsetsToTargets()
    guard let monitor = state.monitors.first(where: { $0.id == monitorID }),
      let index = monitor.workspaces.firstIndex(where: { $0.id == monitor.activeWorkspace })
    else { return }
    let workspace = monitor.workspaces[index]
    let stripWidth = scrollingStripWidth(
      workspace.columns, viewport: viewport, windowsByID: state.windows, settings: state.layout)
    let tiled = workspace.columns.flatMap(\.windows)
    // The pinned column holds its edge while the strip scrolls and stays for every workspace.
    var moving = Set(tiled).subtracting(pinnedWindowIDs(workspace.columns))
    var neighbors: [WindowID: Rect] = [:]
    let resting: ClosedRange<Double>, scale: Double, dimension: Double, stiffness: Double
    var steps = 0...0
    if vertical {
      // Niri's switch: one workspace either way, past which a stiff rubber band holds.
      let height = display.height
      let lowest = max(index - 1, 0), highest = min(index + 1, monitor.workspaces.count - 1)
      resting = Double(index - highest) * height...Double(index - lowest) * height
      steps = (lowest - index)...(highest - index)
      scale = height / scrollPanWorkspaceTravel * config.input.scrollGestureSpeed
      dimension = 0.05 * height
      stiffness = 0.5
      moving.formUnion(workspace.floatingWindows)
      let pinned = pinnedColumnIndices(workspace.columns).values.first.map { workspace.columns[$0] }
      for neighbor in [lowest, highest] where neighbor != index {
        var other = monitor.workspaces[neighbor]
        // Laid out as it will show, beside the pinned column that stays put.
        if let pinned {
          insertPinnedColumn(
            pinned, into: &other, settings: state.layout,
            excludingWindowIDs: state.nativeFullscreenWindowIDs)
        }
        let shift = Double(neighbor - index) * height
        let frames = computeLayout(workspace: other, viewport: viewport,
          windows: other.columns.flatMap(\.windows).compactMap { state.windows[$0] },
          settings: state.layout, excludingWindowIDs: state.nativeFullscreenWindowIDs)
          + floatingAssignments(in: other)
        for assignment in frames where !(pinned?.windows.contains(assignment.windowID) ?? false) {
          var frame = assignment.frame
          frame.y += shift
          neighbors[assignment.windowID] = frame
        }
      }
      moving.formUnion(neighbors.keys)
    } else {
      guard !workspace.columns.isEmpty else { return }
      // The native fullscreen placeholders end the strip, as for key presses.
      let extents = scrollGestureExtents(workspace: workspace, viewport: viewport,
        windows: tiled.compactMap { state.windows[$0] }, settings: state.layout)
      guard let lowest = extents.map(\.lowerBound).min(), let highest = extents.map(\.upperBound).max()
      else { return }
      let rest = workspace.targetScrollOffset
      resting = min((rest - highest) * stripWidth, 0)...max((rest - lowest) * stripWidth, 0)
      scale = viewport.width / scrollPanWidthTravel * config.input.scrollGestureSpeed
      dimension = viewport.width
      stiffness = 0.55
    }
    let start = platform.beginScrollPan(id, viewport: viewport, vertical: vertical, moving: moving,
      neighbors: neighbors, scale: scale, bounds: resting, dimension: dimension, stiffness: stiffness)
    scrollPan = ScrollPan(id: id, vertical: vertical, monitorID: monitorID, workspaceID: workspace.id,
      viewport: viewport, start: start ?? 0, scale: scale,
      bounds: ribbonPanBounds(resting, start: start ?? 0), dimension: dimension, stiffness: stiffness,
      rest: workspace.targetScrollOffset, stripWidth: stripWidth, workspaceHeight: display.height,
      steps: steps)
    if let pan = scrollPan {
      let windows = tiled.compactMap { state.windows[$0] }, settings = state.layout
      let snaps = config.input.scrollGestureSnap
      platform.beginScrollPanDetents(id) { travel in
        vertical ? pan.step(travel: travel)
          : pan.landing(travel: travel, workspace: workspace, windows: windows, settings: settings, snaps: snaps)?.column
      }
    }
    platform.recordPerformanceTrace(
      "scroll-pan-begin id=\(id) vertical=\(vertical) monitor=\(monitorID.rawValue) overlay=\(start != nil)")
  }

  private func endScrollPan(_ id: UInt64, travel: Double, velocity: Double, timestamp: TimeInterval) {
    guard let pan = scrollPan, pan.id == id else { return }
    scrollPan = nil
    guard viewportsByMonitor[pan.monitorID] == pan.viewport,
      let monitor = state.monitors.first(where: { $0.id == pan.monitorID }),
      monitor.activeWorkspace == pan.workspaceID,
      let workspace = monitor.workspaces.first(where: { $0.id == pan.workspaceID })
    else {
      platform.cancelScrollPan()
      return
    }
    let shift = pan.shift(travel: travel)
    // Past the ends the rubber band absorbs the flick.
    let speed = pan.bounds.contains(shift) ? min(max(velocity * pan.scale, -10_000), 10_000) : 0
    let momentum = velocity * scrollPanProjection
    if pan.vertical {
      let target = pan.step(travel: travel, momentum: momentum)
      platform.recordPerformanceTrace("scroll-pan-end id=\(id) vertical=true shift=\(Int(shift)) speed=\(Int(speed)) step=\(target)")
      platform.endScrollPan(velocity: speed, vertical: true)
      if target != 0 {
        // The command acts on the active display: make it the one the swipe moved.
        activeMonitorID = pan.monitorID
        _ = handle("focus-workspace \(target > 0 ? "down" : "up")", inputTimestamp: timestamp)
      } else {
        settleScrollPan(on: pan.monitorID)
      }
      return
    }
    let previouslySelectedWindowID = state.selectedWindowID(on: pan.monitorID)
    let offset = pan.rest - shift / pan.stripWidth
    let windows = workspace.columns.flatMap(\.windows).compactMap { state.windows[$0] }
    guard let snap = pan.landing(travel: travel, momentum: momentum, workspace: workspace, windows: windows,
        settings: state.layout, snaps: config.input.scrollGestureSnap),
      settleScrollGesture(monitorID: pan.monitorID, workspaceID: pan.workspaceID,
        column: snap.column, offset: snap.offset, focus: snap.focus, state: &state)
    else {
      platform.cancelScrollPan()
      return
    }
    synchronizeScrollOffsets(state: &state, viewports: viewportsByMonitor)
    platform.recordPerformanceTrace(
      "scroll-pan-end id=\(id) offset=\(offset) speed=\(Int(speed)) column=\(snap.column) target=\(snap.offset)")
    platform.endScrollPan(velocity: speed, vertical: false)
    commandGeneration &+= 1
    activeMonitorID = pan.monitorID
    settleScrollPan(on: pan.monitorID)
    // A swipe only selects a placeholder: focusing its window would switch to its Space.
    if let selected = state.selectedWindowID(on: pan.monitorID),
      !state.nativeFullscreenWindowIDs.contains(selected)
    {
      focus.queueCommand(PendingAnimatedFocus(
        windowID: selected,
        previousSelectedWindowID: previouslySelectedWindowID,
        monitorID: pan.monitorID,
        sourceWorkspaceID: pan.workspaceID,
        commandGeneration: commandGeneration,
        focusInputTimestamp: timestamp,
        cursorWarpInputTimestamp: nil
      ))
    }
    persistTopology()
    updateMenuBar()
  }

  /// The released content glides from where it is drawn to the layout's resting place.
  private func settleScrollPan(on monitorID: MonitorID) {
    beginFrameAnimationActivity()
    applyCurrentLayout(
      monitorIDs: [monitorID],
      asynchronousPositions: true,
      updateVisibility: true,
      positionTimeoutSeconds: 0.05,
      animated: true,
      positionsOnly: true,
      source: "command-animation"
    )
    needsDesktopSync = true
    scheduleTick()
  }
}
