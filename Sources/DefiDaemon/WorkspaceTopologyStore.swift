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
