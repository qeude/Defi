import Darwin
import DefiConfig
import DefiModel
import DefiRuntime
import Foundation
import Testing

@testable import DefiDaemon

struct WorkspaceTopologyStoreTests {
  @Test
  func `Session identity uses the boot UUID and audit session ID`() throws {
    var audit = auditinfo_addr_t()
    #expect(getaudit_addr(&audit, Int32(MemoryLayout.size(ofValue: audit))) == 0)
    let command = Process()
    command.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
    command.arguments = ["-n", "kern.bootsessionuuid"]
    let output = Pipe()
    command.standardOutput = output
    try command.run()
    let bootID = String(
      decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    command.waitUntilExit()
    #expect(command.terminationStatus == 0)
    #expect(WorkspaceTopologyStore.currentSessionID() == "\(bootID):\(audit.ai_asid)")
  }

  @Test
  func `Store restores only the current login session`() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
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
