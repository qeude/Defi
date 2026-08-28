import DefiConfig
import DefiModel
import DefiRuntime
import Foundation
import Testing

@testable import DefiDaemon

struct WorkspaceTopologyStoreTests {
  @Test
  func `Store restores only the current login session`() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString)
    let store = WorkspaceTopologyStore(url: directory.appending(path: "topology.json"))
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev"]))
    )
    state.attachMonitor(MonitorID(rawValue: 1))

    try store.save(state.topology, sessionID: "session-a")

    #expect(try store.load(sessionID: "session-a") == state.topology)
    #expect(try store.load(sessionID: "session-b") == nil)
  }
}
