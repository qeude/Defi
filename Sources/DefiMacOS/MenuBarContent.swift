import SwiftUI

public struct MenuBarContent: View {
  let activeWorkspace: String
  let workspaces: [MenuWorkspace]
  let commandHandler: (String) -> Void

  public init(
    activeWorkspace: String,
    workspaces: [MenuWorkspace],
    commandHandler: @escaping (String) -> Void
  ) {
    self.activeWorkspace = activeWorkspace
    self.workspaces = workspaces
    self.commandHandler = commandHandler
  }

  public var body: some View {
    ForEach(workspaces, id: \.id) { workspace in
      Button(workspace.id == activeWorkspace ? "✓ \(workspace.label)" : workspace.label) {
        commandHandler("workspace \(workspace.id)")
      }
    }
    if !workspaces.isEmpty {
      Divider()
    }
    Button("Quit Defi") {
      commandHandler("quit")
    }
  }
}
