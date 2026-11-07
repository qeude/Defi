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
      if state.needsAccessibilityPermission {
        Button("Grant Accessibility Permission…") {
          openDefiAccessibilitySettings()
        }
      }
      if !state.workspaces.isEmpty {
        Menu("Workspaces") {
          ForEach(state.workspaces, id: \.id) { workspace in
            Toggle(
              workspace.label,
              isOn: Binding(
                get: { workspace.id == state.activeWorkspace },
                set: { _ in commandHandler("workspace \(workspace.id)") }
              )
            )
          }
        }
      }
      SettingsLink {
        Text("Settings…")
      }
      .keyboardShortcut(",", modifiers: .command)
      if let version = AppUpdater.shared.availableVersion {
        Divider()
        Button("Update to Defi \(version)") {
          AppUpdater.shared.install()
        }
        .disabled(AppUpdater.shared.status == .installing)
      } else if AppUpdater.shared.isEligible {
        Divider()
        Button("Check for Updates…") {
          Task { await AppUpdater.shared.check() }
        }
        .disabled(AppUpdater.shared.status == .checking)
      }
      Divider()
      Link("Support Defi…", destination: defiSponsorsURL)
      Divider()
      Button("Quit Defi") {
        commandHandler("quit")
      }
      .keyboardShortcut("q")
    }
    .onAppear {
      state.refreshAccessibilityPermission()
    }
  }

}
