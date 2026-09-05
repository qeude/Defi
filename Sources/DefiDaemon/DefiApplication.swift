import DefiMacOS
import Foundation
import SwiftUI

@main
struct DefiDaemonMain: App {
  private let daemon: Daemon
  @State private var menuBar: MenuBarState

  init() {
    do {
      let options = try DaemonOptions(arguments: Array(CommandLine.arguments.dropFirst()))
      let daemon = try Daemon(options: options)
      self.daemon = daemon
      daemon.menuBar.isInserted = daemon.config.menuBar.enabled
      _menuBar = State(initialValue: daemon.menuBar)
      Task { @MainActor in daemon.start() }
    } catch {
      FileHandle.standardError.write(Data("defi-daemon: \(error)\n".utf8))
      exit(1)
    }
  }

  var body: some Scene {
    MenuBarExtra(isInserted: $menuBar.isInserted) {
      MenuBarContent(
        activeWorkspace: menuBar.activeWorkspace,
        workspaces: menuBar.workspaces,
        commandHandler: daemon.handleMenuCommand
      )
    } label: {
      Text(menuBar.activeLabel)
        .font(.system(.body, weight: .semibold))
        .monospacedDigit()
        .help("Defi workspace \(menuBar.activeLabel)")
        .accessibilityLabel("Defi workspace")
    }
    .menuBarExtraStyle(.menu)
  }
}
