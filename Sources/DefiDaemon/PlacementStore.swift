import DefiRuntime
import Foundation

struct PlacementStore {
  let url: URL

  init(url: URL = PlacementStore.defaultURL) {
    self.url = url
  }

  func load() throws -> PlacementPreferences {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return PlacementPreferences()
    }
    return try JSONDecoder().decode(
      PlacementPreferences.self,
      from: Data(contentsOf: url)
    )
  }

  func save(_ preferences: PlacementPreferences) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(preferences).write(to: url, options: .atomic)
  }

  static var defaultURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support/Defi/placements.json")
  }
}
