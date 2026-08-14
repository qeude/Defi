import DefiModel
import Foundation

public struct WindowPlacementPreference: Codable, Equatable, Sendable {
  public var workspaceID: WorkspaceID
  public var monitorID: MonitorID?

  public init(workspaceID: WorkspaceID, monitorID: MonitorID? = nil) {
    self.workspaceID = workspaceID
    self.monitorID = monitorID
  }
}

public struct PlacementPreferences: Codable, Equatable, Sendable {
  public var version: Int
  public var applications: [String: WindowPlacementPreference]

  public init(
    version: Int = 1,
    applications: [String: WindowPlacementPreference] = [:]
  ) {
    self.version = version
    self.applications = applications
  }

  public func preference(for window: Window) -> WindowPlacementPreference? {
    applications[Self.applicationKey(window.appID)]
  }

  public mutating func invalidatePreference(for window: Window) {
    applications[Self.applicationKey(window.appID)] = nil
  }

  public mutating func recordPlacements(from state: RuntimeState) {
    var locationsByApplication: [String: Set<PlacementLocation>] = [:]
    for window in state.windows.values {
      guard window.floatingOrigin != .automatic else { continue }
      guard let location = state.location(containing: window.id) else { continue }
      locationsByApplication[Self.applicationKey(window.appID), default: []].insert(
        PlacementLocation(
          monitorID: location.monitorID,
          workspaceID: location.workspaceID
        )
      )
    }

    for (application, locations) in locationsByApplication {
      let workspaceIDs = Set(locations.map(\.workspaceID))
      guard workspaceIDs.count == 1, let workspaceID = workspaceIDs.first else {
        applications[application] = nil
        continue
      }
      let availableMonitorIDs = Set(state.monitors.map(\.id))
      let existingMonitorID = applications[application]?.monitorID
      let observedMonitorIDs = Set(locations.map(\.monitorID))
      let monitorID: MonitorID?
      if let existingMonitorID,
        !availableMonitorIDs.contains(existingMonitorID)
      {
        monitorID = existingMonitorID
      } else {
        monitorID = observedMonitorIDs.count == 1 ? observedMonitorIDs.first : nil
      }
      applications[application] = WindowPlacementPreference(
        workspaceID: workspaceID,
        monitorID: monitorID
      )
    }
  }

  private static func applicationKey(_ appID: String) -> String {
    appID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

private struct PlacementLocation: Hashable {
  let monitorID: MonitorID
  let workspaceID: WorkspaceID
}
