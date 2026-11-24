import DefiIPC
import Foundation
import Testing

@testable import DefiCLI

struct ServiceTests {
  @Test(arguments: [
    ("/Applications/Defi.app/Contents/MacOS/defi", "/Applications/Defi.app"),
    ("/Applications/Defi 2.app/Contents/MacOS/defi", "/Applications/Defi 2.app"),
    ("/Users/test/Defi/.build/debug/defi", nil),
  ] as [(String, String?)])
  func resolvesTheApplicationBundleOfAnInstalledCLI(executable: String, bundle: String?) {
    #expect(appBundleURL(from: URL(filePath: executable))?.path == bundle)
  }

  @Test
  func purgeIncludesAllPersistentState() {
    let paths = Set(Uninstaller.purgeTargets().map(\.path))

    #expect(paths.contains(SocketPath.defaultURL.path))
    #expect(paths.contains(DaemonLockPath.defaultURL.path))
    #expect(paths.contains(where: { $0.hasSuffix("/.config/defi") }))
    #expect(paths.contains(where: { $0.hasSuffix("/Library/Application Support/Defi") }))
    #expect(paths.contains(where: { $0.hasSuffix("/Library/Logs/Defi") }))
    #expect(paths.contains(where: { $0.hasSuffix("/Library/Caches/Defi") }))
    for id in ["com.qeude.defi", "com.quentin.defi"] {
      #expect(paths.contains(where: { $0.hasSuffix("/Library/Preferences/\(id).plist") }))
      #expect(paths.contains(where: { $0.hasSuffix("/Library/Caches/\(id)") }))
      #expect(paths.contains(where: { $0.hasSuffix("/Library/Saved Application State/\(id).savedState") }))
    }
  }

  @Test(arguments: [
    ("/Applications/Defi.app/Contents/MacOS/defi", ["/Applications/Defi.app"]),
    ("/Users/test/Applications/Defi.app/Contents/MacOS/defi", ["/Users/test/Applications/Defi.app"]),
    ("/Users/test/Applications/Defi Development.app/Contents/MacOS/defi",
      ["/Users/test/Applications/Defi Development.app"]),
    ("/tmp/defi-build/debug/defi", []),
    (nil, []),
  ] as [(String?, [String])])
  func purgeTargetsOnlyTheInvokingBundle(executable: String?, apps: [String]) {
    #expect(Uninstaller.purgeTargets(executableURL: executable.map { URL(filePath: $0) })
      .filter { $0.pathExtension == "app" }.map(\.path) == apps)
  }

  @Test
  func stopWaitsUntilTheStoppingDaemonReleasesItsInstanceLock() throws {
    let lockURL = FileManager.default.temporaryDirectory.appending(path: "defi-test-\(UUID()).lock")
    defer { try? FileManager.default.removeItem(at: lockURL) }
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    var sleeps = 0
    try ServiceManager.waitForDaemonToStop(lockURL: lockURL) { _ in
      sleeps += 1
      if sleeps == 3 { close(descriptor) }
    }
    #expect(sleeps == 3)
  }

  @Test
  func stopFailsWhileTheInstanceLockStaysHeld() throws {
    let lockURL = FileManager.default.temporaryDirectory.appending(path: "defi-test-\(UUID()).lock")
    defer { try? FileManager.default.removeItem(at: lockURL) }
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    defer { close(descriptor) }
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    #expect(throws: ServiceError.self) {
      try ServiceManager.waitForDaemonToStop(lockURL: lockURL, attempts: 2) { _ in }
    }
  }

  @Test
  func startRetriesWhileLaunchServicesStillSeesTheOldDaemon() throws {
    var statuses: [Int32] = [1, 1, 0]
    var sleeps = 0
    try ServiceManager.launch(sleep: { _ in sleeps += 1 }) { _ in statuses.removeFirst() }
    #expect(statuses.isEmpty)
    #expect(sleeps == 2)
  }

  @Test
  func startFailsAfterItsLaunchAttempts() {
    var calls = 0
    #expect(throws: ServiceError.self) {
      try ServiceManager.launch(attempts: 3, sleep: { _ in }) { _ in calls += 1; return 1 }
    }
    #expect(calls == 3)
  }
}
