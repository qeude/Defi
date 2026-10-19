import DefiMacOS
import DefiConfig
import DefiRuntime
import Foundation
import SwiftUI

@main
struct DefiDaemonMain: App {
  private let daemon: Daemon
  @State private var menuBar: MenuBarState

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
      _menuBar = State(initialValue: menuBar)
      DefiSettingsRuntimeStatus.shared.updateConfiguration(config)
      NavigationActor.enqueue { daemon.start() }
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
    MenuBarExtra(isInserted: $menuBar.isInserted) {
      MenuBarContent(
        state: menuBar,
        commandHandler: { command in NavigationActor.enqueue { daemon.handleMenuCommand(command) } }
      )
    } label: {
      HStack(spacing: 4) {
        if menuBar.workspaceStyle != .name, let icon = menuBar.activeIconImage {
          Image(nsImage: icon).renderingMode(.template)
        }
        if menuBar.workspaceStyle != .icon || menuBar.activeIcon == nil {
          Text(menuBar.activeLabel)
        }
      }
        .font(.system(.body, weight: .semibold))
        .monospacedDigit()
        .help("Defi workspace \(menuBar.activeLabel)")
        .accessibilityLabel("Defi workspace \(menuBar.activeLabel)")
    }
    .menuBarExtraStyle(.menu)

    Settings {
      DefiSettingsView(configURL: daemon.configURL)
    }
    .defaultSize(width: 920, height: 680)
  }
}
