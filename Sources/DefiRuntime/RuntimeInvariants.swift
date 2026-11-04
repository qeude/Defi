import DefiCore
import DefiModel

/// One broken runtime rule. `code` is stable so test reports, suspect lists and diagnostics
/// can match violations without parsing the message.
public struct InvariantViolation: Equatable, Hashable, Sendable, CustomStringConvertible {
  public let code: String
  public let message: String

  public init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }

  public var description: String { "\(code): \(message)" }
}

extension RuntimeState {
  /// The structural rules of AGENTS.md that hold after every reducer step: workspace
  /// ownership and lifecycle, window placement, and focus bookkeeping.
  public func validate() -> [InvariantViolation] {
    var violations: [InvariantViolation] = []
    var workspaceOwners: [WorkspaceID: MonitorID] = [:]
    var windowPlacements: [WindowID: WorkspaceID] = [:]

    func place(_ windowID: WindowID, in workspace: WorkspaceID) {
      if let previous = windowPlacements.updateValue(workspace, forKey: windowID) {
        violations.append(.init(
          "window-placed-twice",
          "window \(windowID) is in workspace \(previous) and \(workspace)"
        ))
      }
      if windows[windowID] == nil {
        violations.append(.init(
          "placed-window-unknown", "workspace \(workspace) holds unknown window \(windowID)"
        ))
      }
    }

    for monitor in monitors {
      for workspace in monitor.workspaces {
        if let owner = workspaceOwners.updateValue(monitor.id, forKey: workspace.id) {
          violations.append(.init(
            "workspace-not-unique",
            "workspace \(workspace.id) belongs to monitors \(owner) and \(monitor.id)"
          ))
        }
        for column in workspace.columns {
          if column.windows.isEmpty {
            violations.append(.init(
              "empty-column", "workspace \(workspace.id) keeps an empty column"
            ))
          } else if !column.windows.indices.contains(column.focusedWindow) {
            violations.append(.init(
              "focus-index-out-of-range",
              "a column of workspace \(workspace.id) focuses row \(column.focusedWindow) of \(column.windows.count)"
            ))
          }
          column.windows.forEach { place($0, in: workspace.id) }
        }
        workspace.floatingWindows.forEach { place($0, in: workspace.id) }
        if !workspace.columns.isEmpty, !workspace.columns.indices.contains(workspace.focusedColumn) {
          violations.append(.init(
            "focus-index-out-of-range",
            "workspace \(workspace.id) focuses column \(workspace.focusedColumn) of \(workspace.columns.count)"
          ))
        }
        if !workspace.floatingWindows.isEmpty,
          !workspace.floatingWindows.indices.contains(workspace.focusedFloatingWindow)
        {
          violations.append(.init(
            "focus-index-out-of-range",
            "workspace \(workspace.id) focuses floating window \(workspace.focusedFloatingWindow) of \(workspace.floatingWindows.count)"
          ))
        }
      }

      if !monitor.workspaces.contains(where: { $0.id == monitor.activeWorkspace }) {
        violations.append(.init(
          "active-workspace-missing",
          "monitor \(monitor.id) shows \(monitor.activeWorkspace), which it does not own"
        ))
      }
      let trailing = monitor.workspaces.filter { $0.kind == .trailing }
      if trailing.count != 1 || monitor.workspaces.last?.kind != .trailing {
        violations.append(.init(
          "trailing-workspace",
          "monitor \(monitor.id) has \(trailing.count) trailing workspaces, last is \(monitor.workspaces.last.map { "\($0.kind)" } ?? "none")"
        ))
      }
      if let last = monitor.workspaces.last, last.kind == .trailing, !last.isEmpty {
        violations.append(.init(
          "trailing-workspace", "monitor \(monitor.id) trailing workspace \(last.id) holds windows"
        ))
      }
      for workspace in monitor.workspaces
      where workspace.kind == .ordinary && workspace.isEmpty && workspace.id != monitor.activeWorkspace
      {
        violations.append(.init(
          "stale-empty-workspace",
          "monitor \(monitor.id) keeps inactive empty workspace \(workspace.id)"
        ))
      }
      if let active = monitor.workspaces.first(where: { $0.id == monitor.activeWorkspace }),
        active.isEmpty, let selected = selectedWindowID(on: monitor.id)
      {
        violations.append(.init(
          "empty-workspace-focus",
          "empty active workspace \(active.id) on monitor \(monitor.id) selects window \(selected)"
        ))
      }
    }

    if !monitors.isEmpty {
      for name in workspaceNames where workspaceOwners[name] == nil {
        violations.append(.init("named-workspace-missing", "named workspace \(name) is gone"))
      }
    }
    return violations
  }
}
