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
        plistExists: FileManager.default.fileExists(atPath: plistURL.path),
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
      if !FileManager.default.fileExists(atPath: plistURL.path) {
        try install()
      }
      try launchctl(["kickstart", "-k", "\(domain)/\(label)"])
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
    FileManager.default.homeDirectoryForCurrentUser
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

enum ServiceStartAction: Equatable, Sendable {
  case install
  case bootstrap
  case kickstart
}

func serviceStartActions(
  plistExists _: Bool,
  isLoaded: Bool
) -> [ServiceStartAction] {
  isLoaded ? [.kickstart] : [.install, .bootstrap]
}

enum ServiceError: Error, CustomStringConvertible {
  case invalidCommand(String)
  case daemonMissing(String)
  case launchctl(Int32)

  var description: String {
    switch self {
    case .invalidCommand(let command): "unknown service command: \(command)"
    case .daemonMissing(let path): "defi-daemon missing beside CLI: \(path)"
    case .launchctl(let status): "launchctl exited with status \(status)"
    }
  }
}
