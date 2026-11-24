import DefiIPC
import Foundation
import ServiceManagement

enum ServiceManager {
  /// Label of the pre-0.5 LaunchAgent, removed on migration.
  private static let label = "com.quentin.defi"

  static func run(_ command: String) throws {
    switch command {
    case "enable":
      try enableLaunchAtLogin()
      print("launch at login enabled")
    case "disable":
      try disableLaunchAtLogin()
      print("launch at login disabled")
    case "start":
      try start()
      print("started")
    case "stop":
      try stop()
      print("stopped")
    case "restart":
      try stop(ignoreFailure: true, handoff: true)
      do {
        try start()
      } catch {
        // The windows were left in place for the new daemon; parked ones stay offscreen until one runs.
        FileHandle.standardError.write(Data("Defi did not start again: run `defi service start`.\n".utf8))
        throw error
      }
      print("restarted")
    case "status":
      let runtime = (try? sendCommand("status")) == nil ? "stopped" : "running"
      print("launch-at-login=\(launchAtLoginStatus()) runtime=\(runtime)")
    default:
      throw ServiceError.invalidCommand(command)
    }
  }

  static func enableLaunchAtLogin() throws {
    try removeLegacyLaunchAgent()
    switch SMAppService.mainApp.status {
    case .enabled:
      return
    case .requiresApproval:
      SMAppService.openSystemSettingsLoginItems()
      throw ServiceError.approvalRequired
    default:
      try SMAppService.mainApp.register()
    }
  }

  static func disableLaunchAtLogin() throws {
    try removeLegacyLaunchAgent()
    guard SMAppService.mainApp.status != .notRegistered else { return }
    try SMAppService.mainApp.unregister()
  }

  static func stop(ignoreFailure: Bool = false, handoff: Bool = false) throws {
    let running = (try? sendCommand("status")) != nil
    // A restart leaves the windows in place for the next daemon; an older daemon restores them.
    if running, !handoff || (try? sendCommand("handoff"))?.ok != true {
      _ = try? sendCommand("restore")
      _ = try? sendCommand("quit")
    }
    do {
      try waitForDaemonToStop()
    } catch where ignoreFailure {}
  }

  static var installedAppURL: URL {
    if let executableURL = Bundle.main.executableURL,
       let appURL = appBundleURL(from: executableURL)
    {
      return appURL
    }

    let candidates = [
      URL(filePath: "/Applications/Defi.app"),
      FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Applications/Defi.app"),
    ]
    return candidates.first(where: {
      FileManager.default.fileExists(atPath: $0.path)
    }) ?? candidates[0]
  }

  static var legacyPlistURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/LaunchAgents/\(label).plist")
  }

  private static func start() throws {
    let daemonURL = installedAppURL.appending(path: "Contents/MacOS/defi-daemon")
    guard FileManager.default.isExecutableFile(atPath: daemonURL.path) else {
      throw ServiceError.daemonMissing(daemonURL.path)
    }
    try launch { isLastAttempt in
      let process = Process()
      process.executableURL = URL(filePath: "/usr/bin/open")
      process.arguments = [installedAppURL.path]
      if !isLastAttempt { process.standardError = FileHandle.nullDevice }
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus
    }
  }

  /// Right after the old daemon exits, LaunchServices can still count it as running and
  /// fail the launch with error -600.
  static func launch(
    attempts: Int = 5,
    sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
    open: (_ isLastAttempt: Bool) throws -> Int32
  ) throws {
    var status: Int32 = 0
    for attempt in 1...attempts {
      status = try open(attempt == attempts)
      if status == 0 { return }
      if attempt < attempts { sleep(0.2) }
    }
    throw ServiceError.openFailed(status)
  }

  /// A daemon launched while the old one still holds the lock exits at once.
  static func waitForDaemonToStop(
    lockURL: URL = DaemonLockPath.defaultURL,
    attempts: Int = 250,
    sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
  ) throws {
    for _ in 0..<attempts {
      if !DaemonLockPath.isHeld(at: lockURL) { return }
      sleep(0.02)
    }
    throw ServiceError.daemonDidNotStop
  }

  private static func removeLegacyLaunchAgent() throws {
    guard FileManager.default.fileExists(atPath: legacyPlistURL.path) else { return }
    let process = Process()
    process.executableURL = URL(filePath: "/bin/launchctl")
    process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    if (try? process.run()) != nil {
      process.waitUntilExit()
    }
    try FileManager.default.removeItem(at: legacyPlistURL)
  }

  private static func launchAtLoginStatus() -> String {
    switch SMAppService.mainApp.status {
    case .enabled: "enabled"
    case .requiresApproval: "requires-approval"
    case .notFound: "not-found"
    default: "disabled"
    }
  }
}

func appBundleURL(from executableURL: URL) -> URL? {
  let executableURL = executableURL.resolvingSymlinksInPath().standardizedFileURL
  let appURL = executableURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  guard appURL.pathExtension == "app" else {
    return nil
  }
  let expectedExecutableDirectory = appURL
    .appending(path: "Contents/MacOS")
    .standardizedFileURL
  guard
    executableURL.deletingLastPathComponent().path
    == expectedExecutableDirectory.path
  else {
    return nil
  }
  return appURL
}

enum ServiceError: Error, CustomStringConvertible {
  case invalidCommand(String)
  case daemonMissing(String)
  case daemonDidNotStop
  case approvalRequired
  case openFailed(Int32)

  var description: String {
    switch self {
    case let .invalidCommand(command): "unknown service command: \(command)"
    case let .daemonMissing(path): "defi-daemon missing beside CLI: \(path)"
    case .daemonDidNotStop: "defi-daemon did not stop"
    case .approvalRequired:
      "launch at login requires approval in System Settings"
    case let .openFailed(status): "open exited with status \(status)"
    }
  }
}
