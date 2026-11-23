import AppKit
import DefiCore
import DefiIPC
import DefiModel
import DefiRuntime
import Foundation

let workspaceStateNotification = Notification.Name(
  "com.qeude.defi.workspaceChanged"
)

@MainActor private let workspaceStateNotificationThrottle = LatestWinsThrottle<Data>(
  interval: 0.05,
  schedule: { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) },
  deliver: { data in
    guard let userInfo = try? JSONSerialization.jsonObject(with: data)
      as? [AnyHashable: Any] else { return }
    DistributedNotificationCenter.default().postNotificationName(
      workspaceStateNotification,
      object: nil,
      userInfo: userInfo,
      deliverImmediately: true
    )
  }
)

func postWorkspaceStateNotification(_ data: Data) {
  DispatchQueue.main.async {
    MainActor.assumeIsolated { workspaceStateNotificationThrottle.submit(data) }
  }
}

/// Delivers the first value at once, then at most one per interval, always ending on the latest.
@MainActor
final class LatestWinsThrottle<Value> {
  private let interval: TimeInterval
  private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
  private let deliver: (Value) -> Void
  private var pending: Value?
  private var coolingDown = false

  init(
    interval: TimeInterval,
    schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void,
    deliver: @escaping (Value) -> Void
  ) {
    self.interval = interval
    self.schedule = schedule
    self.deliver = deliver
  }

  func submit(_ value: Value) {
    guard !coolingDown else {
      pending = value
      return
    }
    send(value)
  }

  private func send(_ value: Value) {
    deliver(value)
    coolingDown = true
    schedule(interval) { [self] in
      coolingDown = false
      if let value = pending {
        pending = nil
        send(value)
      }
    }
  }
}

@NavigationActor
extension Daemon {
  func currentWorkspaceState() -> WorkspaceStateSnapshot {
    makeWorkspaceStateSnapshot(
      monitors: state.monitors,
      windows: state.windows,
      displayOrder: latestMonitors.map(\.id),
      focusedMonitorID: activeMonitorID,
      workspaceIcons: config.workspaces.icons,
      nativeFullscreenWindowIDs: state.nativeFullscreenWindowIDs
    )
  }

  func currentWindowList() -> WindowListSnapshot {
    makeWindowListSnapshot(
      monitors: state.monitors,
      windows: state.windows,
      displayOrder: latestMonitors.map(\.id),
      focusedMonitorID: activeMonitorID,
      appName: { [self] window in
        guard let processID = window.processID else { return nil }
        if let name = applicationNames[processID] { return name }
        let name = NSRunningApplication(processIdentifier: processID)?.localizedName
        applicationNames[processID] = name
        return name
      }
    )
  }

  func workspaceStateJSON() throws -> String {
    try sortedJSON(currentWorkspaceState())
  }

  func sortedJSON(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  func publishWorkspaceStateIfNeeded() {
    let displayOrder = latestMonitors.map(\.id)
    if lastPublishedWorkspaceState != nil,
      lastWorkspacePublishState == state,
      lastWorkspacePublishDisplayOrder == displayOrder,
      lastWorkspacePublishFocusedMonitorID == activeMonitorID,
      lastWorkspacePublishIcons == config.workspaces.icons
    {
      return
    }
    lastWorkspacePublishState = state
    lastWorkspacePublishDisplayOrder = displayOrder
    lastWorkspacePublishFocusedMonitorID = activeMonitorID
    lastWorkspacePublishIcons = config.workspaces.icons
    let snapshot = currentWorkspaceState()
    eventStreamHub.publish(
      EventStreamState(workspaces: snapshot, windows: currentWindowList().windows)
    )
    guard snapshot != lastPublishedWorkspaceState else { return }
    do {
      let data = try JSONEncoder().encode(snapshot)
      workspaceStatePublisher(data)
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

  /// Nil when the command needs no reply of its own.
  func handleDaemonVerb(
    _ verb: DaemonVerb,
    monitorIndex: Int?,
    deferredResponse: DeferredCommandReply?
  ) -> CommandResponse? {
    switch verb {
    case .listWorkspaces(let json):
      guard json else { return .success(handleListWorkspaces()) }
      do {
        return .success(try workspaceStateJSON())
      } catch {
        return .failure(String(describing: error))
      }
    case .listWindows(let json):
      guard json else { return .success(handleListWindows()) }
      do {
        return .success(try sortedJSON(currentWindowList()))
      } catch {
        return .failure(String(describing: error))
      }
    case .setReservedArea(let edge, let points):
      return applyReservedArea(.set(edge, points), monitorIndex: monitorIndex)
    case .clearReservedArea:
      return applyReservedArea(.clear, monitorIndex: monitorIndex)
    case .status:
      return .success(status())
    case .trace:
      return .success(platform.frameCoordinatorTrace)
    case .borderAudit:
      guard let deferredResponse else { return .failure("border-audit requires a client") }
      deferredResponse.deferResponse()
      DispatchQueue.main.async { [platform] in
        let report = platform.auditWindowBorderGeometry()
        NavigationActor.enqueue { deferredResponse.perform { .success(report) } }
      }
      return .success("deferred")
    case .diagnosticMark:
      diagnostics.mark(status: status(), trace: platform.frameCoordinatorTrace)
      return .success("marked \(diagnostics.currentFileURL.path)")
    case .restore:
      // A shutdown already under way wins over this request.
      guard !shouldShutdown else { return nil }
      guard beginWindowRestoration() else { return .failure("window restoration in progress") }
      Task { await restoreAllWindows(alreadyClaimed: true) }
      return .success("restoration scheduled")
    case .stop(let handsOff):
      shouldShutdown = true
      handsOffWindows = handsOff
      return .success("stopping")
    }
  }

  private func handleListWorkspaces() -> String {
    currentWorkspaceState().monitors.map { monitor in
      let labels = monitor.workspaces.map { $0.name ?? String($0.position) }
      return "\(monitor.display): \(labels.joined(separator: " "))"
    }.joined(separator: "\n")
  }

  private func handleListWindows() -> String {
    currentWindowList().windows.map { window in
      "\(window.id)\t\(window.appName ?? window.appID)\t\(window.title)"
    }.joined(separator: "\n")
  }

  private enum ReservedAreaRequest {
    case set(ReservedEdge, Double)
    case clear
  }

  private func applyReservedArea(
    _ request: ReservedAreaRequest,
    monitorIndex: Int?
  ) -> CommandResponse {
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
    switch request {
    case .clear:
      runtimeCommand = .clearReservedEdges(targetMonitorIDs)
    case .set(let edge, let points):
      var edgesByMonitor: [MonitorID: ReservedEdges] = [:]
      for monitorID in targetMonitorIDs {
        var edges = effectiveReservedEdges(for: monitorID)
        switch edge {
        case .top: edges.top = points
        case .bottom: edges.bottom = points
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
