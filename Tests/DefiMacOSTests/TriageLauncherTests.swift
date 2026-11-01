import Foundation
import Testing

@testable import DefiMacOS

struct TriageLauncherTests {
  @Test func launcherRunsTriageOnQuotedPathAndDeletesItself() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "triage-launcher-\(UUID().uuidString)/it's here", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let cli = directory.appending(path: "defi")
    let output = directory.appending(path: "arguments")
    try "#!/bin/sh\necho \"$*\" > '\(output.path.replacingOccurrences(of: "'", with: "'\\''"))'\n"
      .write(to: cli, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)

    let launcher = try writeTriageLauncher(cli: cli, directory: directory)
    #expect(launcher.pathExtension == "command")
    let attributes = try FileManager.default.attributesOfItem(atPath: launcher.path)
    #expect(attributes[.posixPermissions] as? Int == 0o700)

    let process = Process()
    process.executableURL = launcher
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    #expect(try String(contentsOf: output, encoding: .utf8) == "triage\n")
    #expect(!FileManager.default.fileExists(atPath: launcher.path))
  }
}
