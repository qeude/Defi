import Testing

@testable import DefiDaemon

struct SpawnShellTests {
  @Test
  func searchPathPutsDefiAndHomebrewFirstWithoutDuplicates() {
    #expect(
      spawnSearchPath(inherited: "/usr/bin:/opt/homebrew/bin:/bin", executableDirectory: "/Apps/Defi.app/Contents/MacOS")
        == "/Apps/Defi.app/Contents/MacOS:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    #expect(
      spawnSearchPath(inherited: nil, executableDirectory: nil)
        == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
  }
}
