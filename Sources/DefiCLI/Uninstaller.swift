import DefiIPC
import Foundation

enum Uninstaller {
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

  static func purgeTargets() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var targets = [
      home.appending(path: ".config/defi"),
      home.appending(path: "Library/Application Support/Defi"),
      home.appending(path: "Library/Caches/com.quentin.defi"),
      home.appending(path: "Library/Logs/Defi"),
      home.appending(path: "Library/Logs/Defi.log"),
      home.appending(path: "Library/Preferences/com.quentin.defi.plist"),
      home.appending(path: "Library/Saved Application State/com.quentin.defi.savedState"),
      ServiceManager.legacyPlistURL,
      SocketPath.defaultURL,
      DaemonLockPath.defaultURL,
    ]
    if let executableURL = Bundle.main.executableURL,
       let currentApp = appBundleURL(from: executableURL)
    {
      targets.append(currentApp)
    }
    targets.append(URL(filePath: "/Applications/Defi.app"))
    targets.append(home.appending(path: "Applications/Defi.app"))
    return targets
  }

  private static func resetPrivacyPermissions() {
    for service in ["Accessibility", "ScreenCapture"] {
      let process = Process()
      process.executableURL = URL(filePath: "/usr/bin/tccutil")
      process.arguments = ["reset", service, "com.quentin.defi"]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      if (try? process.run()) != nil {
        process.waitUntilExit()
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
