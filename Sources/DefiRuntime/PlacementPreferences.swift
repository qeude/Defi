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
  public var suppressedWindowIDs: Set<WindowID>

  public init(
    version: Int = 1,
    applications: [String: WindowPlacementPreference] = [:],
    suppressedWindowIDs: Set<WindowID> = []
  ) {
    self.version = version
    self.applications = applications
    self.suppressedWindowIDs = suppressedWindowIDs
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case applications
    case suppressedWindowIDs
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
    applications = try values.decodeIfPresent(
      [String: WindowPlacementPreference].self,
      forKey: .applications
    ) ?? [:]
    suppressedWindowIDs = try values.decodeIfPresent(
      Set<WindowID>.self,
      forKey: .suppressedWindowIDs
    ) ?? []
  }

  public func preference(for window: Window) -> WindowPlacementPreference? {
    guard !suppressedWindowIDs.contains(window.id) else { return nil }
    return applications[Self.applicationKey(window.appID)]
  }

  @discardableResult
  public mutating func invalidatePreference(for window: Window) -> String {
    let key = Self.applicationKey(window.appID)
    applications[key] = nil
    suppressedWindowIDs.insert(window.id)
    return key
  }

  public mutating func recordPlacements(from state: RuntimeState) {
    let automaticWindowIDs = Set<WindowID>(
      state.windows.values.compactMap { window in
        guard window.floatingOrigin == .automatic else { return nil }
        return window.id
      }
    )
    suppressedWindowIDs.formIntersection(automaticWindowIDs)
    let locationsByWindow = state.windowLocationMap()
    var locationsByApplication: [String: Set<PlacementLocation>] = [:]
    for window in state.windows.values {
      guard window.floatingOrigin != .automatic else { continue }
      guard !suppressedWindowIDs.contains(window.id) else {
        continue
      }
      guard let location = locationsByWindow[window.id] else { continue }
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
