import AppKit
import DefiConfig
import DefiModel
import XCTest

@testable import DefiMacOS

@MainActor
final class DesktopFocusFixturePair {
  enum Failure: Error {
    case unsupported(String)
  }

  let tiledProcess = Process()
  let floatingProcess = Process()
  let tiledAppID: String
  let floatingAppID: String
  let tiledWindowID: WindowID
  let floatingWindowID: WindowID
  private let directory: URL
  private let inputs = [Pipe(), Pipe()]
  private let pump: (() -> Bool, TimeInterval) -> Bool

  init(platform: MacOSPlatform, pump: @escaping (() -> Bool, TimeInterval) -> Bool) throws {
    guard let binary = ProcessInfo.processInfo.environment["DEFI_DESKTOP_FIXTURE_BINARY"],
      binary.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: binary)
    else { throw Failure.unsupported("DEFI_DESKTOP_FIXTURE_BINARY must name an executable absolute path") }
    let token = UUID().uuidString.lowercased()
    tiledAppID = "com.quentin.defi.desktop-fixture.tiled.\(token)"
    floatingAppID = "com.quentin.defi.desktop-fixture.floating.\(token)"
    directory = FileManager.default.temporaryDirectory.appending(path: "DefiFocusFixtures-\(token)")
    self.pump = pump
    let processes = [tiledProcess, floatingProcess]
    let appIDs = [tiledAppID, floatingAppID]
    let titles = ["Defi tiled fixture \(token)", "Defi floating fixture \(token)"]
    do {
      for index in processes.indices {
        let contents = directory.appending(path: "\(index).app/Contents")
        let executable = contents.appending(path: "MacOS/DefiDesktopFocusFixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
          withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: binary), to: executable)
        let info = ["CFBundleIdentifier": appIDs[index], "CFBundlePackageType": "APPL",
          "CFBundleExecutable": "DefiDesktopFocusFixture", "NSPrincipalClass": "NSApplication"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
          .write(to: contents.appending(path: "Info.plist"))
        processes[index].executableURL = executable
        processes[index].arguments = [titles[index]]
        processes[index].standardInput = inputs[index]
        try processes[index].run()
      }
      var discovered: [Window] = []
      let ready = pump({
        let snapshot = platform.snapshot(config: Config())
        discovered = processes.indices.compactMap { index in
          snapshot.windows.first {
            $0.processID == processes[index].processIdentifier
              && $0.appID == appIDs[index] && $0.title == titles[index]
          }
        }
        return discovered.count == 2
      }, 2)
      guard ready, tiledProcess.isRunning, floatingProcess.isRunning,
        tiledProcess.processIdentifier != floatingProcess.processIdentifier,
        discovered[0].id != discovered[1].id,
        processes.allSatisfy({
          NSRunningApplication(processIdentifier: $0.processIdentifier)?.activationPolicy == .regular
        })
      else { throw Failure.unsupported("Ordinary AppKit fixture windows were not discovered with distinct native identities") }
      tiledWindowID = discovered[0].id
      floatingWindowID = discovered[1].id
    } catch {
      XCTAssertTrue(Self.stop(processes, inputs: inputs, pump: pump), "Fixture setup must reap its children")
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  func close() throws {
    guard Self.stop([tiledProcess, floatingProcess], inputs: inputs, pump: pump) else {
      throw Failure.unsupported("Fixture children did not exit after EOF, SIGTERM, and SIGKILL")
    }
    try FileManager.default.removeItem(at: directory)
  }

  private static func stop(_ processes: [Process], inputs: [Pipe],
    pump: (() -> Bool, TimeInterval) -> Bool) -> Bool {
    for input in inputs { try? input.fileHandleForWriting.close() }
    if !pump({ processes.allSatisfy { !$0.isRunning } }, 1) {
      for process in processes where process.isRunning { process.terminate() }
      if !pump({ processes.allSatisfy { !$0.isRunning } }, 1) {
        for process in processes where process.isRunning { kill(process.processIdentifier, SIGKILL) }
        _ = pump({ processes.allSatisfy { !$0.isRunning } }, 1)
      }
    }
    for process in processes where process.processIdentifier > 0 && !process.isRunning {
      process.waitUntilExit()
    }
    return processes.allSatisfy { !$0.isRunning }
  }
}
