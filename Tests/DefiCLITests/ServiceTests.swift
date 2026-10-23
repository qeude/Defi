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

}
