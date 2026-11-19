import DefiModel
import Testing

@testable import DefiDaemon

struct SpawnShellTests {
  @Test
  func socketClientsCannotSpawnShells() {
    #expect(!verbIsAllowedOverIPC("spawn-sh open -a Terminal"))
    #expect(verbIsAllowedOverIPC("focus-column left"))
    #expect(verbIsAllowedOverIPC("not-a-command"))
  }
}
