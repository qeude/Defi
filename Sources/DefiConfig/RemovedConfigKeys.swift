import TOMLDecoder

/// Keys whose migration Defi no longer ships, as dotted paths mapped to what replaces them.
/// A path through an array of tables, such as `rules.floating`, matches any of its entries.
/// Empty the table at the first stable release. See CONTRIBUTING.md.
public let removedConfigKeys: [String: String] = [:]

/// The first removed key the document sets, in path order.
func firstRemovedKey(in root: TOMLTable, removed: [String: String]) -> (key: String, replacement: String)? {
  removed.keys.sorted().first { contains(root, path: $0.split(separator: ".").map(String.init)) }
    .map { ($0, removed[$0] ?? "") }
}

private func contains(_ table: TOMLTable, path: [String]) -> Bool {
  guard let key = path.first else { return false }
  guard table.contains(key: key) else { return false }
  let rest = Array(path.dropFirst())
  if rest.isEmpty { return true }
  if let child = try? table.table(forKey: key) { return contains(child, path: rest) }
  guard let array = try? table.array(forKey: key) else { return false }
  return (0..<array.count).contains { index in
    guard let entry = try? array.table(atIndex: index) else { return false }
    return contains(entry, path: rest)
  }
}
