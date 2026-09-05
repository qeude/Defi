import ApplicationServices
import Observation

public struct MenuWorkspace: Equatable, Sendable {
  public let id: String
  public let label: String

  public init(id: String, label: String) {
    self.id = id
    self.label = label
  }
}

@MainActor
@Observable
public final class MenuBarState {
  public var isInserted = true
  public private(set) var workspaces: [MenuWorkspace] = []
  public private(set) var activeWorkspace = ""
  public private(set) var needsAccessibilityPermission: Bool
  private let accessibilityTrusted: () -> Bool

  public init(accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
    self.accessibilityTrusted = accessibilityTrusted
    needsAccessibilityPermission = !accessibilityTrusted()
  }

  public func refreshAccessibilityPermission() {
    needsAccessibilityPermission = !accessibilityTrusted()
  }

  public var activeLabel: String {
    workspaces.first { $0.id == activeWorkspace }?.label ?? "–"
  }

  public func update(activeWorkspace: String, workspaces: [MenuWorkspace]) {
    if self.activeWorkspace != activeWorkspace { self.activeWorkspace = activeWorkspace }
    if self.workspaces != workspaces { self.workspaces = workspaces }
  }
}
