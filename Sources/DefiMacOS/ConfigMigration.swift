import Foundation

/// Rewrites rule keys that `window` replaced, keeping comments and layout, or nil when none remain.
/// shortcut: remove once configurations from before `window` are gone, at the first stable release.
func migratingLegacyRuleKeys(in source: String) -> String? {
  var document = LosslessTOMLDocument(source)
  var changed = false
  for index in 0..<document.count(ofArrayTable: "rules") {
    let floating = document.value(table: "rules", key: "floating", occurrence: index)
    let forceTiling = document.value(table: "rules", key: "force_tiling", occurrence: index)
    guard floating != nil || forceTiling != nil else { continue }
    changed = true
    document.set(table: "rules", key: "floating", value: nil, occurrence: index)
    document.set(table: "rules", key: "force_tiling", value: nil, occurrence: index)
    // force_tiling took precedence over floating.
    let window = forceTiling == "true" ? "force-tiled" : floating == "true" ? "force-floating" : nil
    if let window, !document.contains(table: "rules", key: "window", occurrence: index) {
      document.set(table: "rules", key: "window", value: "\"\(window)\"", occurrence: index)
    }
  }
  return changed ? document.render() : nil
}

/// Migrates the configuration file in place before it loads; failures leave it unchanged.
public func migrateLegacyConfiguration(at url: URL) {
  let target = url.resolvingSymlinksInPath()
  guard let data = try? Data(contentsOf: target),
    let source = String(data: data, encoding: .utf8),
    let migrated = migratingLegacyRuleKeys(in: source)
  else { return }
  do {
    try Data(migrated.utf8).write(to: target, options: .atomic)
  } catch {
    FileHandle.standardError.write(Data("defi: could not migrate \(target.path): \(error)\n".utf8))
  }
}
