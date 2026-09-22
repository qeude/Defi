import DefiMacOS
import DefiRuntime
import Foundation
import SwiftUI

@main
struct DefiDaemonMain: App {
  private let daemon: Daemon
  @State private var menuBar: MenuBarState

  init() {
    do {
      let options = try DaemonOptions(arguments: Array(CommandLine.arguments.dropFirst()))
      let menuBar = MenuBarState()
      let daemon = try NavigationActor.shared.queue.sync {
        try NavigationActor.assumeIsolated { try Daemon(options: options, menuBar: menuBar) }
      }
      self.daemon = daemon
      _menuBar = State(initialValue: menuBar)
      NavigationActor.enqueue { daemon.start() }
    } catch DaemonInstanceLockError.alreadyRunning {
      exit(0)
    } catch {
      presentDefiStartupError(error)
      FileHandle.standardError.write(Data("defi-daemon: \(error)\n".utf8))
      exit(1)
    }
  }

  var body: some Scene {
    MenuBarExtra(isInserted: $menuBar.isInserted) {
      MenuBarContent(
        state: menuBar,
        commandHandler: { command in NavigationActor.enqueue { daemon.handleMenuCommand(command) } }
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
