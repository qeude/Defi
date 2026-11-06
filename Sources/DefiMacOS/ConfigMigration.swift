import Foundation

/// One in-place rewrite of an obsolete configuration format.
///
/// A migration ships from `introducedIn` until the release before `removeIn`. The release that
/// reaches `removeIn` deletes it and moves each obsolete key into `removedConfigKeys`, so a file
/// that skipped those releases fails loudly instead of losing settings. See CONTRIBUTING.md.
struct ConfigMigration: Sendable {
  let id: String
  let introducedIn: String
  let removeIn: String
  /// The rewritten source, or nil when nothing needs migrating.
  let migrate: @Sendable (String) -> String?
}

/// Applied in order, oldest first.
let configMigrations: [ConfigMigration] = [
  ConfigMigration(
    id: "rules-window", introducedIn: "0.8.0", removeIn: "0.10.0", migrate: migratingLegacyRuleKeys
  ),
]

/// Every migration applied in order, or nil when the source is already current.
func migratingLegacyConfiguration(
  in source: String, migrations: [ConfigMigration] = configMigrations
) -> String? {
  let migrated = migrations.reduce(source) { $1.migrate($0) ?? $0 }
  return migrated == source ? nil : migrated
}

/// Rewrites rule keys that `window` replaced, keeping comments and layout, or nil when none remain.
/// On removal, `rules.floating` and `rules.force_tiling` become removed keys pointing to `window`.
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
    let migrated = migratingLegacyConfiguration(in: source)
  else { return }
  do {
    try Data(migrated.utf8).write(to: target, options: .atomic)
  } catch {
    FileHandle.standardError.write(Data("defi: could not migrate \(target.path): \(error)\n".utf8))
  }
}
