import DefiCore
import DefiModel

@testable import DefiRuntime

/// Frame rules of AGENTS.md checked on the pure layout of every connected display.
// shortcut: composes DefiCore's computeLayout, continuous strip and parkedFrame the way
// DaemonDesktop.applyCurrentLayout does for tiled windows, without floating frames, overview
// parking or transitions; the simulated daemon checks the frames it really writes.
func layoutViolations(
  state: RuntimeState,
  displays: [(id: MonitorID, frame: Rect, visible: Rect)]
) -> [InvariantViolation] {
  var violations: [InvariantViolation] = []
  let epsilon = 0.5
  for display in displays {
    guard let monitor = state.monitors.first(where: { $0.id == display.id }) else { continue }
    let viewport = viewportByApplyingReservedEdges(
      display.visible, edges: state.reservedEdgesByMonitor[display.id] ?? ReservedEdges()
    )
    let others = displays.filter { $0.id != display.id }.map(\.frame)
    let park = { (assignment: FrameAssignment) -> Rect in
      var frame = assignment.frame
      if let size = state.windows[assignment.windowID]?.frame {
        frame.width = size.width
        frame.height = size.height
      }
      return parkedFrame(frame, display: display.frame, visibleFrame: display.visible, otherDisplays: others)
    }
    func checkParked(_ windowID: WindowID, _ frame: Rect) {
      let own = overlap(frame, display.visible)
      if own.width > parkedSliverWidth + epsilon, own.height > epsilon {
        violations.append(.init(
          "parked-window-visible",
          "hidden window \(windowID) shows \(Int(own.width)) pt of display \(display.id)"
        ))
      }
      for other in others {
        let shared = overlap(frame, other)
        if shared.width > epsilon, shared.height > epsilon {
          violations.append(.init(
            "parked-window-on-other-display",
            "hidden window \(windowID) of display \(display.id) overlaps another display by \(Int(shared.width))x\(Int(shared.height))"
          ))
        }
      }
    }
    // Each column and row is inset by half the configured gap on every inner side.
    func checkGaps(_ strip: ContinuousStripPlan, workspace: Workspace, viewport: Rect) {
      let settings = state.layout
      let frames = Dictionary(strip.frames.map { ($0.windowID, $0.frame) }) { first, _ in first }
      let visibleColumns: [[Rect]] = workspace.columns.compactMap { column in
        let rows = column.windows.filter {
          strip.visibilityByWindowID[$0] == .visible && state.windows[$0]?.intrinsicSize != true
        }.compactMap { frames[$0] }
        return rows.count == column.windows.count ? rows : nil
      }
      for rows in visibleColumns {
        let left = rows.map(\.x).min()!, right = rows.map { $0.x + $0.width }.max()!
        if left >= viewport.x - epsilon, left < viewport.x + settings.outerLeftGap - epsilon {
          violations.append(.init("tiled-gap", "column at x \(left) is inside the left outer gap of \(viewport)"))
        }
        if right <= viewport.x + viewport.width + epsilon,
          right > viewport.x + viewport.width - settings.outerRightGap + epsilon
        {
          violations.append(.init("tiled-gap", "column ending at x \(right) is inside the right outer gap of \(viewport)"))
        }
        // Rows held at their maximum height cannot fill the column, so their gaps grow.
        let capped = workspace.columns.first { column in
          column.windows.compactMap { frames[$0] }.contains { rows.contains($0) }
        }?.windows.contains { id in
          guard let maximum = state.windows[id]?.maximumTiledHeight, let frame = frames[id] else { return false }
          return frame.height >= maximum - epsilon
        } ?? false
        let sorted = capped ? [] : rows.sorted { $0.y < $1.y }
        for (upper, lower) in zip(sorted, sorted.dropFirst())
        where abs(lower.y - (upper.y + upper.height) - 2 * settings.innerVerticalGap) > 1 {
          violations.append(.init(
            "tiled-gap", "rows at y \(upper.y + upper.height) and \(lower.y) are not \(2 * settings.innerVerticalGap) apart"
          ))
        }
      }
      for (leading, trailing) in zip(visibleColumns, visibleColumns.dropFirst()) {
        let end = leading.map { $0.x + $0.width }.max()!, start = trailing.map(\.x).min()!
        if abs(start - end - 2 * settings.innerHorizontalGap) > 1 {
          violations.append(.init(
            "tiled-gap", "columns at x \(end) and \(start) are not \(2 * settings.innerHorizontalGap) apart"
          ))
        }
      }
    }

    for workspace in monitor.workspaces {
      for column in workspace.columns where column.windows.count > 1 {
        if case .rejected(let rejection) = stackFit(
          column.windows, windowsByID: state.windows, viewport: viewport, settings: state.layout
        ) {
          violations.append(.init(
            "stack-does-not-fit", "stack \(column.windows) in \(workspace.id) cannot fit: \(rejection)"
          ))
        }
      }
      let windows = workspace.columns.flatMap(\.windows).compactMap { state.windows[$0] }
      let layout = computeLayout(
        workspace: workspace, viewport: viewport, windows: windows, settings: state.layout,
        excludingWindowIDs: state.nativeFullscreenWindowIDs
      )
      guard workspace.id == monitor.activeWorkspace else {
        for assignment in layout { checkParked(assignment.windowID, park(assignment)) }
        continue
      }
      let strip = continuousStripFramesForActiveWorkspace(layout, viewport: viewport, park: park)
      checkGaps(strip, workspace: workspace, viewport: viewport)
      for assignment in strip.frames {
        guard strip.visibilityByWindowID[assignment.windowID] == .visible else {
          checkParked(assignment.windowID, assignment.frame)
          continue
        }
        let frame = assignment.frame
        let window = state.windows[assignment.windowID]
        if window?.intrinsicSize != true {
          if frame.y < viewport.y + state.layout.outerTopGap - epsilon
            || frame.y + frame.height > viewport.y + viewport.height - state.layout.outerBottomGap + epsilon
          {
            violations.append(.init(
              "tiled-gap", "window \(assignment.windowID) spans y \(frame.y)...\(frame.y + frame.height) in viewport \(viewport)"
            ))
          }
        }
        if let maximum = window?.maximumTiledWidth, frame.width > maximum + epsilon {
          violations.append(.init(
            "tiled-maximum-width", "window \(assignment.windowID) is \(frame.width) wide, its maximum is \(maximum)"
          ))
        }
        if let minimum = window?.minimumTiledWidth, minimum <= viewport.width,
          frame.width < minimum - epsilon
        {
          violations.append(.init(
            "tiled-minimum-width", "window \(assignment.windowID) is \(frame.width) wide, its minimum is \(minimum)"
          ))
        }
        if let maximum = window?.maximumTiledHeight, frame.height > maximum + epsilon {
          violations.append(.init(
            "tiled-maximum-height", "window \(assignment.windowID) is \(frame.height) tall, its maximum is \(maximum)"
          ))
        }
      }
    }
  }
  return violations
}

private func overlap(_ a: Rect, _ b: Rect) -> (width: Double, height: Double) {
  (max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x)),
   max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y)))
}
