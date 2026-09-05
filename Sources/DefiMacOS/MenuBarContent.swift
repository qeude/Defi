import AppKit
import ServiceManagement
import SwiftUI

public struct MenuBarContent: View {
  let state: MenuBarState
  let commandHandler: (String) -> Void
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

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
      Toggle("Launch at Login", systemImage: "power.circle", isOn: Binding(
        get: { launchAtLogin },
        set: { _ in toggleLaunchAtLogin() }
      ))
      if state.needsAccessibilityPermission {
        Button("Grant Accessibility Permission…", systemImage: "accessibility") {
          openDefiAccessibilitySettings()
        }
      }
      Button("Configuration Guide…", systemImage: "book.closed") {
        if let url = URL(string: "https://github.com/qeude/Defi/blob/main/CONFIGURATION.md") {
          NSWorkspace.shared.open(url)
        }
      }
      Divider()
      Button("About Defi", systemImage: "info.circle") {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
      }
      Button("Quit Defi", systemImage: "power") {
        commandHandler("quit")
      }
      .keyboardShortcut("q")
    }
    .onAppear {
      state.refreshAccessibilityPermission()
      launchAtLogin = SMAppService.mainApp.status == .enabled
    }
  }

  private func toggleLaunchAtLogin() {
    do {
      switch SMAppService.mainApp.status {
      case .enabled:
        try SMAppService.mainApp.unregister()
      case .requiresApproval:
        SMAppService.openSystemSettingsLoginItems()
      default:
        try SMAppService.mainApp.register()
      }
    } catch {
      presentDefiAlert(title: "Launch at Login", message: String(describing: error))
    }
    launchAtLogin = SMAppService.mainApp.status == .enabled
  }
}
