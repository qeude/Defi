import DefiIPC
import Foundation
import Testing

@testable import DefiCLI

struct ServiceTests {
  @Test
  func resolvesApplicationBundleFromInstalledCLIPath() {
    #expect(
      appBundleURL(
        from: URL(filePath: "/Applications/Defi.app/Contents/MacOS/defi")
      )?.path == "/Applications/Defi.app"
    )
    #expect(
      appBundleURL(
        from: URL(filePath: "/Applications/Defi 2.app/Contents/MacOS/defi")
      )?.path == "/Applications/Defi 2.app"
    )
  }

  @Test
  func rejectsExecutableOutsideApplicationBundle() {
    #expect(
      appBundleURL(
        from: URL(filePath: "/Users/test/Defi/.build/debug/defi")
      ) == nil
    )
  }

  @Test
  func purgeIncludesAllPersistentState() {
    let paths = Set(Uninstaller.purgeTargets().map(\.path))

    #expect(paths.contains(SocketPath.defaultURL.path))
    #expect(paths.contains(DaemonLockPath.defaultURL.path))
    #expect(paths.contains(where: { $0.hasSuffix("/.config/defi") }))
    #expect(paths.contains(where: { $0.hasSuffix("/Library/Application Support/Defi") }))
    #expect(paths.contains(where: { $0.hasSuffix("/Library/Logs/Defi") }))
    #expect(paths.contains("/Applications/Defi.app"))
  }
}
