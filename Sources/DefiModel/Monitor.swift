import Foundation

public struct Monitor: Equatable, Codable, Sendable {
  public let id: MonitorID
  public var workspaces: [Workspace]
  public var activeWorkspace: WorkspaceID {
    didSet {
      guard activeWorkspace != oldValue else { return }
      previousWorkspace = oldValue
    }
  }
  /// The workspace this monitor showed before the active one. It may name a workspace
  /// that is gone or lives on another monitor; `resolveWorkspaceTarget` checks.
  public private(set) var previousWorkspace: WorkspaceID? = nil

  public init(id: MonitorID, workspaces: [Workspace], activeWorkspace: WorkspaceID) {
    self.id = id
    self.workspaces = workspaces
    self.activeWorkspace = activeWorkspace
  }
}
