import DefiMacOS
import DefiConfig
import DefiModel
import DefiRuntime
import Foundation
import SwiftUI
import DefiUI

@main
struct DefiDaemonMain: App {
  private let daemon: Daemon
  private let menuBarController: MenuBarController

  init() {
    Self.migrateLegacyPreferences()
    do {
      let options = try DaemonOptions(arguments: Array(CommandLine.arguments.dropFirst()))
      let menuBar = MenuBarState()
      let (daemon, menuBarEnabled, config) = try NavigationActor.shared.queue.sync {
        try NavigationActor.assumeIsolated {
          let daemon = try Daemon(options: options, menuBar: menuBar)
          return (daemon, daemon.config.menuBar.enabled, daemon.config)
        }
      }
      menuBar.isInserted = menuBarEnabled
      self.daemon = daemon
      menuBarController = MenuBarController(
        state: menuBar,
        commandHandler: { command in NavigationActor.enqueue { daemon.handleMenuCommand(command) } }
      )
      DefiSettingsRuntimeStatus.shared.updateConfiguration(config)
      NavigationActor.enqueue { daemon.start() }
      MainActor.assumeIsolated {
        AppUpdater.shared.start { NavigationActor.enqueue { daemon.handleMenuCommand("quit") } }
        SupportPrompt.showAfterUpdate()
      }
    } catch DaemonInstanceLockError.alreadyRunning {
      exit(0)
    } catch {
      presentDefiStartupError(error)
      FileHandle.standardError.write(Data("defi-daemon: \(error)\n".utf8))
      exit(1)
    }
  }

  /// Copies settings stored under the pre-0.5 bundle identifier without overwriting new ones.
  private static func migrateLegacyPreferences() {
    let current = UserDefaults.standard
    for (key, value) in current.persistentDomain(forName: "com.quentin.defi") ?? [:]
    where current.object(forKey: key) == nil {
      current.set(value, forKey: key)
    }
  }

  var body: some Scene {
    Settings {
      DefiSettingsView(configURL: daemon.configURL)
    }
    .defaultSize(width: 920, height: 680)
  }
}
