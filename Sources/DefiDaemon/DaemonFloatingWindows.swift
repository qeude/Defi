import AppKit
import DefiConfig
import DefiCore
import DefiIPC
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation
import OSLog

@MainActor
extension Daemon {
func updateFloatingWindowFrames(
    from windows: [Window],
    externallyChangedFrames: [WindowID: Rect],
    displayGeometryChanged: Bool,
    mouseResizeGestureActive: Bool
  ) -> [WindowID: MonitorID] {
    var reassignedMonitorIDs: [WindowID: MonitorID] = [:]
    let trackedFloatingIDs = Set(
      state.monitors.flatMap(\.workspaces).flatMap(\.floatingWindows)
    )
    floatingWindowFrames = floatingWindowFrames.filter {
      trackedFloatingIDs.contains($0.key)
    }
    for window in windows where trackedFloatingIDs.contains(window.id) {
      if !displayGeometryChanged,
        mouseResizeGestureActive,
        !platform.isWindowHidden(window.id),
        let targetMonitorID = window.monitorID,
        moveFloatingWindow(window.id, to: targetMonitorID, state: &state)
      {
        if let movedWindow = state.windows[window.id],
          movedWindow.floatingOrigin == .automatic
        {
          invalidatePlacementPreference(for: movedWindow)
        }
        reassignedMonitorIDs[window.id] = targetMonitorID
      }
      if displayGeometryChanged {
        if floatingWindowFrames[window.id] == nil,
          let monitorID = state.monitorID(containing: window.id),
          let viewport = viewportsByMonitor[monitorID]
        {
          floatingWindowFrames[window.id] = constrainedFloatingFrame(
            window.frame,
            to: viewport
          )
        }
        continue
      }
      if let externalFrame = externallyChangedFrames[window.id] {
        floatingWindowFrames[window.id] = externalFrame
        platform.acceptObservedFrame(externalFrame, for: window.id)
        continue
      }
      guard floatingWindowFrames[window.id] != nil else {
        floatingWindowFrames[window.id] = window.frame
        continue
      }
      guard !platform.isWindowHidden(window.id),
        !platform.hasPendingFrameTransition(window.id)
      else {
        continue
      }
      floatingWindowFrames[window.id] = window.frame
    }
    return reassignedMonitorIDs
  }

  func rebaseFloatingWindowFrames(
    previousViewports: [MonitorID: Rect],
    nextViewports: [MonitorID: Rect],
    previousMonitorIDs: [WindowID: MonitorID],
    windowIDs: Set<WindowID>? = nil
  ) {
    let frames = windowIDs.map { windowIDs in
      floatingWindowFrames.filter { windowIDs.contains($0.key) }
    } ?? floatingWindowFrames
    let nextMonitorIDs = Dictionary(
      uniqueKeysWithValues: frames.keys.compactMap { windowID in
        state.monitorID(containing: windowID).map { (windowID, $0) }
      }
    )
    let rebasedFrames = rebasedFloatingWindowFrames(
      frames,
      previousViewports: previousViewports,
      nextViewports: nextViewports,
      previousMonitorIDs: previousMonitorIDs,
      nextMonitorIDs: nextMonitorIDs
    )
    for windowID in frames.keys {
      floatingWindowFrames[windowID] = rebasedFrames[windowID]
    }
  }

  func floatingAssignments(in workspace: Workspace) -> [FrameAssignment] {
    workspace.floatingWindows.compactMap { windowID in
      guard let frame = floatingFrame(for: windowID) else { return nil }
      return FrameAssignment(windowID: windowID, frame: frame)
    }
  }

  func refreshFloatingWindowFramesBeforeWorkspaceMutation() {
    guard
      let monitorID = activeMonitorID ?? state.monitors.first?.id,
      let monitor = state.monitors.first(where: { $0.id == monitorID }),
      let workspace = monitor.workspaces.first(where: {
        $0.id == monitor.activeWorkspace
      })
    else {
      return
    }
    for (windowID, frame) in platform.userAdjustedFrames(
      for: Set(workspace.floatingWindows)
    ) {
      floatingWindowFrames[windowID] = frame
      platform.acceptObservedFrame(frame, for: windowID)
    }
  }

  private func floatingFrame(for windowID: WindowID) -> Rect? {
    if let frame = floatingWindowFrames[windowID] {
      return frame
    }
    guard let frame = state.windows[windowID]?.frame else { return nil }
    floatingWindowFrames[windowID] = frame
    return frame
  }

  func roundAnimatedPosition(
    _ assignment: FrameAssignment
  ) -> FrameAssignment {
    FrameAssignment(
      windowID: assignment.windowID,
      frame: Rect(
        x: assignment.frame.x.rounded(),
        y: assignment.frame.y.rounded(),
        width: assignment.frame.width,
        height: assignment.frame.height
      )
    )
  }

  func preserveIntrinsicSize(_ assignment: FrameAssignment) -> FrameAssignment {
    guard let window = state.windows[assignment.windowID], window.intrinsicSize else {
      return assignment
    }
    let width = window.frame.width
    let height = window.frame.height
    return FrameAssignment(
      windowID: assignment.windowID,
      frame: Rect(
        x: assignment.frame.x + (assignment.frame.width - width) / 2,
        y: assignment.frame.y + (assignment.frame.height - height) / 2,
        width: width,
        height: height
      )
    )
  }

  func horizontalIntersection(_ frame: Rect, _ viewport: Rect) -> Double {
    max(
      min(frame.x + frame.width, viewport.x + viewport.width)
        - max(frame.x, viewport.x),
      0
    )
  }
}

func rebasedFloatingWindowFrames(
  _ frames: [WindowID: Rect],
  previousViewports: [MonitorID: Rect],
  nextViewports: [MonitorID: Rect],
  previousMonitorIDs: [WindowID: MonitorID],
  nextMonitorIDs: [WindowID: MonitorID]
) -> [WindowID: Rect] {
  Dictionary(uniqueKeysWithValues: frames.compactMap { windowID, frame in
    guard let previousMonitorID = previousMonitorIDs[windowID],
      let previousViewport = previousViewports[previousMonitorID],
      let nextMonitorID = nextMonitorIDs[windowID],
      let nextViewport = nextViewports[nextMonitorID]
    else { return nil }
    return (
      windowID,
      rebasedFloatingFrame(frame, from: previousViewport, to: nextViewport)
    )
  })
}

private func constrainedFloatingFrame(_ frame: Rect, to viewport: Rect) -> Rect {
  let width = min(frame.width, viewport.width)
  let height = min(frame.height, viewport.height)
  return Rect(
    x: min(max(frame.x, viewport.x), viewport.x + viewport.width - width),
    y: min(max(frame.y, viewport.y), viewport.y + viewport.height - height),
    width: width,
    height: height
  )
}
