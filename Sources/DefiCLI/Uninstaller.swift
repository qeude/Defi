import DefiIPC
import Foundation

enum Uninstaller {
  /// Bundle identifiers that Defi has used; the first is current.
  private static let bundleIdentifiers = ["com.qeude.defi", "com.quentin.defi"]

  static func purge() throws {
    try ServiceManager.stop(ignoreFailure: true)
    try? ServiceManager.disableLaunchAtLogin()
    resetPrivacyPermissions()

    var failures: [String] = []
    for url in purgeTargets() where FileManager.default.fileExists(atPath: url.path) {
      do {
        try FileManager.default.removeItem(at: url)
        print("removed \(url.path)")
      } catch {
        failures.append("\(url.path): \(error.localizedDescription)")
      }
    }
    guard failures.isEmpty else {
      throw UninstallError.removalFailed(failures)
    }
    print("Defi was completely uninstalled")
  }

  static func purgeTargets(executableURL: URL? = Bundle.main.executableURL) -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var targets = [
      home.appending(path: ".config/defi"),
      home.appending(path: "Library/Application Support/Defi"),
      home.appending(path: "Library/Logs/Defi"),
      home.appending(path: "Library/Logs/Defi.log"),
      ServiceManager.legacyPlistURL,
      SocketPath.defaultURL,
      DaemonLockPath.defaultURL,
    ]
    for id in bundleIdentifiers {
      targets += [
        home.appending(path: "Library/Caches/\(id)"),
        home.appending(path: "Library/Preferences/\(id).plist"),
        home.appending(path: "Library/Saved Application State/\(id).savedState"),
      ]
    }
    if let executableURL,
       let currentApp = appBundleURL(from: executableURL)
    {
      targets.append(currentApp)
    }
    return targets
  }

  private static func resetPrivacyPermissions() {
    for service in ["Accessibility", "ScreenCapture"] {
      for id in bundleIdentifiers {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, id]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
          process.waitUntilExit()
        }
      }
    }
  }
}

enum UninstallError: Error, CustomStringConvertible {
  case removalFailed([String])

  var description: String {
    switch self {
    case let .removalFailed(failures):
      "could not remove:\n\(failures.joined(separator: "\n"))"
    }
  }
}
