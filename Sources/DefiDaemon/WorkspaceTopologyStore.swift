import Darwin
import DefiRuntime
import Foundation

struct WorkspaceTopologyStore {
  let url: URL

  init(url: URL = WorkspaceTopologyStore.defaultURL) {
    self.url = url
  }

  func load(sessionID: String) throws -> WorkspaceTopology? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let stored = try JSONDecoder().decode(
      StoredWorkspaceTopology.self,
      from: Data(contentsOf: url)
    )
    return stored.version == 1 && stored.sessionID == sessionID
      ? stored.topology
      : nil
  }

  func save(_ topology: WorkspaceTopology, sessionID: String) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(
      StoredWorkspaceTopology(sessionID: sessionID, topology: topology)
    ).write(to: url, options: .atomic)
  }

  static func currentSessionID() -> String? {
    // audit_session_self() returns a process-local Mach port, not an audit session ID.
    var audit = auditinfo_addr_t()
    guard getaudit_addr(&audit, Int32(MemoryLayout.size(ofValue: audit))) == 0 else {
      return nil
    }
    var bootID = [UInt8](repeating: 0, count: 128)
    var size = bootID.count
    guard sysctlbyname("kern.bootsessionuuid", &bootID, &size, nil, 0) == 0,
      size > 1, size <= bootID.count, bootID[size - 1] == 0
    else {
      return nil
    }
    return "\(String(decoding: bootID.prefix(size - 1), as: UTF8.self)):\(audit.ai_asid)"
  }

  static var defaultURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support/Defi/workspace-topology.json")
  }
}

private struct StoredWorkspaceTopology: Codable {
  let version = 1
  let sessionID: String
  let topology: WorkspaceTopology

  private enum CodingKeys: String, CodingKey {
    case version
    case sessionID
    case topology
  }
}
