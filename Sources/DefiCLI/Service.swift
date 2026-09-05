import DefiIPC
import Foundation

enum ServiceManager {
  private static let label = "com.quentin.defi"

  static func run(_ command: String) throws {
    switch command {
    case "install":
      try install()
    case "uninstall":
      try stop(ignoreFailure: true)
      try? FileManager.default.removeItem(at: plistURL)
      print("uninstalled")
    case "start":
      for action in serviceStartActions(
        isLoaded: isLoaded()
      ) {
        switch action {
        case .install:
          try install()
        case .bootstrap:
          try bootstrapWithRetry()
        case .kickstart:
          try launchctl(["kickstart", "\(domain)/\(label)"])
        }
      }
      print("started")
    case "stop":
      try stop(ignoreFailure: false)
      print("stopped")
    case "restart":
      try stop(ignoreFailure: true)
      _ = try? sendCommand("quit")
      try waitForDaemonToStop()
      try install()
      try bootstrapWithRetry()
      print("restarted")
    case "status":
      try launchctl(["print", "\(domain)/\(label)"])
    default:
      throw ServiceError.invalidCommand(command)
    }
  }

  private static func install() throws {
    let daemonURL = installedAppURL.appending(path: "Contents/MacOS/defi-daemon")
    guard FileManager.default.isExecutableFile(atPath: daemonURL.path) else {
      throw ServiceError.daemonMissing(daemonURL.path)
    }
    try FileManager.default.createDirectory(
      at: plistURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let plist: [String: Any] = [
      "Label": label,
      "ProgramArguments": [daemonURL.path],
      "RunAtLoad": true,
      "KeepAlive": ["SuccessfulExit": false],
      "StandardOutPath": logURL.path,
      "StandardErrorPath": logURL.path,
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
    try data.write(to: plistURL, options: .atomic)
    print("installed \(plistURL.path)")
  }

  private static func stop(ignoreFailure: Bool) throws {
    _ = try? sendCommand("restore")
    do {
      try launchctl(["bootout", "\(domain)/\(label)"])
    } catch  where ignoreFailure {}
  }

  private static func bootstrapWithRetry() throws {
    var lastError: Error?
    for attempt in 0..<20 {
      do {
        try launchctl(["bootstrap", domain, plistURL.path])
        return
      } catch {
        lastError = error
        if attempt + 1 < 20 {
          Thread.sleep(forTimeInterval: 0.1)
        }
      }
    }
    throw lastError ?? ServiceError.launchctl(-1)
  }

  private static func waitForDaemonToStop() throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      do {
        _ = try sendCommand("status")
        Thread.sleep(forTimeInterval: 0.1)
      } catch {
        return
      }
    }
    throw ServiceError.daemonDidNotStop
  }

  private static func isLoaded() -> Bool {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/launchctl")
    process.arguments = ["print", "\(domain)/\(label)"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

  private static func launchctl(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/launchctl")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw ServiceError.launchctl(process.terminationStatus)
    }
  }

  private static var domain: String { "gui/\(getuid())" }

  private static var installedAppURL: URL {
    if let executableURL = Bundle.main.executableURL,
      let appURL = appBundleURL(from: executableURL)
    {
      return appURL
    }

    let candidates = [
      FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Applications/Defi.app"),
      URL(filePath: "/Applications/Defi.app"),
    ]
    if let existing = candidates.first(where: {
      FileManager.default.fileExists(atPath: $0.path)
    }) {
      return existing
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Applications/Defi.app")
  }

  private static var plistURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/LaunchAgents/\(label).plist")
  }

  private static var logURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Logs/Defi.log")
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

enum ServiceStartAction: Equatable, Sendable {
  case install
  case bootstrap
  case kickstart
}

func serviceStartActions(
  isLoaded: Bool
) -> [ServiceStartAction] {
  isLoaded ? [.kickstart] : [.install, .bootstrap]
}

enum ServiceError: Error, CustomStringConvertible {
  case invalidCommand(String)
  case daemonMissing(String)
  case daemonDidNotStop
  case launchctl(Int32)

  var description: String {
    switch self {
    case .invalidCommand(let command): "unknown service command: \(command)"
    case .daemonMissing(let path): "defi-daemon missing beside CLI: \(path)"
    case .daemonDidNotStop: "defi-daemon did not stop before restart"
    case .launchctl(let status): "launchctl exited with status \(status)"
    }
  }
}
