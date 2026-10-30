import Foundation
import Testing
@testable import DefiMacOS

struct AppUpdaterTests {
  private func payload(tag: String = "v0.6.0", asset: String = "Defi-v0.6.0.zip", url: String) -> Data {
    Data(#"{"tag_name":"\#(tag)","assets":[{"name":"\#(asset)","browser_download_url":"\#(url)"}]}"#.utf8)
  }

  private let archiveURL = "https://github.com/qeude/Defi/releases/download/v0.6.0/Defi-v0.6.0.zip"

  @Test
  func acceptsOnlyThisRepositoryArchiveForItsTag() {
    #expect(AppUpdateRelease(json: payload(url: archiveURL))?.version == "0.6.0")
    #expect(AppUpdateRelease(json: payload(url: "https://evil.example/qeude/Defi/releases/download/a.zip")) == nil)
    #expect(AppUpdateRelease(json: payload(url: "https://github.com/evil/Defi/releases/download/a.zip")) == nil)
    #expect(AppUpdateRelease(json: payload(url: "http://github.com/qeude/Defi/releases/download/a.zip")) == nil)
    #expect(AppUpdateRelease(json: payload(asset: "Defi-v0.5.0.zip", url: archiveURL)) == nil)
    #expect(AppUpdateRelease(json: Data("{}".utf8)) == nil)
  }

  @Test
  func offersOnlyStrictlyNewerVersions() {
    #expect(isNewerVersion("0.5.10", than: "0.5.9"))
    #expect(!isNewerVersion("0.5.1", than: "0.5.1"))
    // A local build can be ahead of the latest release.
    #expect(!isNewerVersion("0.5.0", than: "0.5.1"))
  }

  @Test
  func stagesOnlyASignedAppWithTheAnnouncedVersion() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try signedAppArchive(in: root, version: "0.6.0")

    func stage(version: String, requirement: String) throws -> URL {
      try stageAppUpdate(
        archive: archive, into: try temporaryDirectory(in: root),
        version: version, requirement: requirement)
    }
    let good = #"identifier "com.qeude.defi""#
    #expect(try stage(version: "0.6.0", requirement: good).lastPathComponent == "Defi.app")
    #expect(throws: AppUpdateError.self) {
      try stage(version: "0.6.0", requirement: defiReleaseRequirement)
    }
    #expect(throws: AppUpdateError.self) { try stage(version: "0.7.0", requirement: good) }

    let garbage = root.appending(path: "garbage.zip")
    try Data("not a zip".utf8).write(to: garbage)
    #expect(throws: AppUpdateError.self) {
      try stageAppUpdate(
        archive: garbage, into: try temporaryDirectory(in: root),
        version: "0.6.0", requirement: good)
    }
  }

  @Test
  func swapWaitsForTheDaemonThenReplacesTheApp() throws {
    let (root, installed, staged, staging) = try swapFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let daemon = try run("/bin/sleep", ["1"], wait: false)

    let swap = try runSwap(pid: daemon.processIdentifier, installed, staged, staging)
    #expect(try marker(in: installed) == "old")
    swap.waitUntilExit()

    #expect(!daemon.isRunning)
    #expect(try marker(in: installed) == "new")
    #expect(!FileManager.default.fileExists(atPath: staging.path))
  }

  @Test
  func swapRestoresTheInstalledAppWhenTheStagedAppIsMissing() throws {
    let (root, installed, staged, staging) = try swapFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(at: staged)

    let swap = try runSwap(pid: 999_999, installed, staged, staging)
    swap.waitUntilExit()

    #expect(try marker(in: installed) == "old")
  }

  private func swapFixture() throws -> (URL, URL, URL, URL) {
    let root = try temporaryDirectory()
    let installed = root.appending(path: "Defi.app")
    let staging = root.appending(path: "staging")
    let staged = staging.appending(path: "Defi.app")
    for (app, value) in [(installed, "old"), (staged, "new")] {
      try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
      try Data(value.utf8).write(to: app.appending(path: "marker"))
    }
    return (root, installed, staged, staging)
  }

  private func runSwap(pid: Int32, _ installed: URL, _ staged: URL, _ staging: URL) throws -> Process {
    try run("/bin/sh", [
      "-c", appUpdateSwapScript, "defi-update", String(pid), installed.path, staged.path,
      staging.path, "/usr/bin/true",
    ], wait: false)
  }

  private func marker(in app: URL) throws -> String {
    try String(contentsOf: app.appending(path: "marker"), encoding: .utf8)
  }

  private func signedAppArchive(in root: URL, version: String) throws -> URL {
    let app = root.appending(path: "Defi.app")
    let macOS = app.appending(path: "Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appending(path: "Defi").path)
    let info: [String: Any] = [
      "CFBundleIdentifier": "com.qeude.defi", "CFBundleExecutable": "Defi",
      "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: app.appending(path: "Contents/Info.plist"))
    try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
    let archive = root.appending(path: "Defi.zip")
    try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path])
    return archive
  }

  private func temporaryDirectory(in parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
    let url = parent.appending(path: "defi-update-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @discardableResult
  private func run(_ tool: String, _ arguments: [String], wait: Bool = true) throws -> Process {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    if wait {
      process.waitUntilExit()
      #expect(process.terminationStatus == 0)
    }
    return process
  }
}
