import AppKit
import DefiCore
import DefiIPC
import DefiModel
import DefiRuntime
import Foundation

let workspaceStateNotification = Notification.Name(
  "com.quentin.defi.workspaceChanged"
)

@MainActor
extension Daemon {
  func currentWorkspaceState() -> WorkspaceStateSnapshot {
    makeWorkspaceStateSnapshot(
      monitors: state.monitors,
      windows: state.windows,
      displayOrder: latestMonitors.map(\.id),
      focusedMonitorID: activeMonitorID
    )
  }

  func workspaceStateJSON() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(
      decoding: try encoder.encode(currentWorkspaceState()),
      as: UTF8.self
    )
  }

  func publishWorkspaceStateIfNeeded() {
    let snapshot = currentWorkspaceState()
    guard snapshot != lastPublishedWorkspaceState else { return }
    do {
      let data = try JSONEncoder().encode(snapshot)
      guard
        let userInfo = try JSONSerialization.jsonObject(with: data)
          as? [AnyHashable: Any]
      else {
        return
      }
      DistributedNotificationCenter.default().postNotificationName(
        workspaceStateNotification,
        object: nil,
        userInfo: userInfo,
        deliverImmediately: true
      )
      lastPublishedWorkspaceState = snapshot
    } catch {
      log("workspace state publication failed: \(error)")
    }
  }

  func monitorID(atAppKitIndex index: Int?) -> MonitorID? {
    guard let index else { return activeMonitorID ?? state.monitors.first?.id }
    guard index > 0 else { return nil }
    guard latestMonitors.indices.contains(index - 1) else { return nil }
    return latestMonitors[index - 1].id
  }

  func effectiveReservedEdges(for monitorID: MonitorID) -> ReservedEdges {
    state.reservedEdgesByMonitor[monitorID]
      ?? ReservedEdges(
        top: config.layout.reservedTop,
        bottom: config.layout.reservedBottom
      )
  }

  func handleReservedAreaCommand(
    _ rawCommand: String,
    monitorIndex: Int?
  ) -> CommandResponse? {
    let parts = rawCommand.split(whereSeparator: \.isWhitespace).map(String.init)
    guard parts.first == "set-reserved-area" || parts.first == "clear-reserved-area"
    else {
      return nil
    }
    let targetMonitorIDs: [MonitorID]
    if let monitorIndex {
      guard let monitorID = monitorID(atAppKitIndex: monitorIndex) else {
        return .failure("unknown monitor index: \(monitorIndex)")
      }
      targetMonitorIDs = [monitorID]
    } else {
      targetMonitorIDs = latestMonitors.map(\.id)
    }
    guard targetMonitorIDs.isEmpty == false else {
      return .failure("no monitors available")
    }

    let previousViewports = viewportsByMonitor
    let previousMonitorIDs = Dictionary(
      uniqueKeysWithValues: floatingWindowFrames.keys.compactMap { windowID in
        state.monitorID(containing: windowID).map { (windowID, $0) }
      }
    )
    let runtimeCommand: RuntimeCommand
    if parts[0] == "clear-reserved-area" {
      guard parts.count == 1 else {
        return .failure("usage: clear-reserved-area")
      }
      runtimeCommand = .clearReservedEdges(targetMonitorIDs)
    } else {
      guard parts.count == 3,
        let points = Double(parts[2]), points.isFinite,
        (0...512).contains(points)
      else {
        return .failure("usage: set-reserved-area top|bottom <0...512>")
      }
      guard parts[1] == "top" || parts[1] == "bottom" else {
        return .failure("usage: set-reserved-area top|bottom <0...512>")
      }
      var edgesByMonitor: [MonitorID: ReservedEdges] = [:]
      for monitorID in targetMonitorIDs {
        var edges = effectiveReservedEdges(for: monitorID)
        if parts[1] == "top" {
          edges.top = points
        } else {
          edges.bottom = points
        }
        edgesByMonitor[monitorID] = edges
      }
      runtimeCommand = .setReservedEdges(edgesByMonitor)
    }
    do {
      try reduce(runtimeCommand, state: &state)
    } catch {
      return .failure(String(describing: error))
    }

    let nextViewports = viewportsByMonitor
    guard nextViewports != previousViewports else {
      return .success("reserved area unchanged")
    }
    rebaseFloatingWindowFrames(
      previousViewports: previousViewports,
      nextViewports: nextViewports,
      previousMonitorIDs: previousMonitorIDs
    )
    synchronizeScrollOffsets(state: &state, viewports: nextViewports)
    snapScrollOffsetsToTargets()
    applyCurrentLayout(
      asynchronousPositions: true,
      updateVisibility: true,
      positionTimeoutSeconds: 0.05,
      forceFloatingFrameWrites: true,
      source: "reserved-area"
    )
    updateMenuBar()
    return .success("reserved area updated")
  }
}
