import Foundation

public struct Monitor: Equatable, Codable, Sendable {
  public let id: MonitorID
  public var workspaces: [Workspace]
  public var activeWorkspace: WorkspaceID

  public init(id: MonitorID, workspaces: [Workspace], activeWorkspace: WorkspaceID) {
    self.id = id
    self.workspaces = workspaces
    self.activeWorkspace = activeWorkspace
  }
}
