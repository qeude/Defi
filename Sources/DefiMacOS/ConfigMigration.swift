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
let configMigrations: [ConfigMigration] = []

/// Every migration applied in order, or nil when the source is already current.
func migratingLegacyConfiguration(
  in source: String, migrations: [ConfigMigration] = configMigrations
) -> String? {
  let migrated = migrations.reduce(source) { $1.migrate($0) ?? $0 }
  return migrated == source ? nil : migrated
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
