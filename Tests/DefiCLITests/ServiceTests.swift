import Foundation
import Testing

@testable import DefiCLI

struct ServiceTests {
  @Test(
    "An unloaded service refreshes its plist before bootstrap",
    arguments: [false, true]
  )
  func unloadedServiceRefreshesPlist(plistExists: Bool) {
    #expect(
      serviceStartActions(
        plistExists: plistExists,
        isLoaded: false
      ) == [.install, .bootstrap]
    )
  }

  @Test
  func loadedServiceOnlyKickstartsExistingJob() {
    #expect(
      serviceStartActions(
        plistExists: true,
        isLoaded: true
    ) == [.kickstart]
    )
  }

  @Test
  func resolvesApplicationBundleFromInstalledCLIPath() {
    #expect(
      appBundleURL(
        from: URL(filePath: "/Applications/Defi.app/Contents/MacOS/defi")
      )?.path == "/Applications/Defi.app"
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
}
