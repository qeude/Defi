import SwiftUI

public struct MenuBarContent: View {
  let state: MenuBarState
  let commandHandler: (String) -> Void

  public init(state: MenuBarState, commandHandler: @escaping (String) -> Void) {
    self.state = state
    self.commandHandler = commandHandler
  }

  public var body: some View {
    Group {
      if !state.workspaces.isEmpty {
        Menu("Workspaces", systemImage: "rectangle.3.group") {
          ForEach(state.workspaces, id: \.id) { workspace in
            Toggle(
              workspace.label == "+" ? "New Workspace" : workspace.label,
              isOn: Binding(
                get: { workspace.id == state.activeWorkspace },
                set: { _ in commandHandler("workspace \(workspace.id)") }
              )
            )
          }
        }
        Divider()
      }
      if state.needsAccessibilityPermission {
        Button("Grant Accessibility Permission…", systemImage: "accessibility") {
          openDefiAccessibilitySettings()
        }
      }
      SettingsLink {
        Text("Settings…")
      }
      .keyboardShortcut(",", modifiers: .command)
      Divider()
      Button("Quit Defi", systemImage: "power") {
        commandHandler("quit")
      }
      .keyboardShortcut("q")
    }
    .onAppear {
      state.refreshAccessibilityPermission()
    }
  }

}
