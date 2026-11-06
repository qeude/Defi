import DefiConfig
import Foundation
import TOMLDecoder

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
  ConfigMigration(
    id: "mod-key", introducedIn: "0.8.0", removeIn: "0.10.0", migrate: migratingLegacyModifierKeys
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

/// Replaces `default_key_modifier` and `[modifier_combinations]` with `mod`, or nil when neither is set.
/// Accelerators that used an alias spell `mod` when the alias matched it, else its modifiers.
/// On removal, both keys become removed keys pointing to `mod`.
func migratingLegacyModifierKeys(in source: String) -> String? {
  guard let root = try? TOMLTable(source: source),
    root.contains(key: "default_key_modifier") || root.contains(key: "modifier_combinations")
  else { return nil }
  var aliases: [String: String] = [:]
  if let table = try? root.table(forKey: "modifier_combinations") {
    for key in table.keys { aliases[key.lowercased()] = try? table.string(forKey: key) }
  }
  // Modifier names in display order, or nil for an invalid prefix.
  func modifiers(_ prefix: String) -> [String]? {
    guard let normalized = normalizedAccelerator("\(prefix)-a", aliases: aliases) else { return nil }
    let names = Set(normalized.split(separator: "-").dropLast().map(String.init))
    return ["ctrl", "alt", "shift", "cmd"].filter(names.contains)
  }
  let oldDefault = (try? root.string(forKey: "default_key_modifier")) ?? "ctrl-alt"
  // A `mod` the user already wrote wins over the old prefix.
  let writtenMod = try? root.string(forKey: "mod")
  let mod = modifiers(writtenMod ?? oldDefault)
  func rewritten(_ accelerator: String) -> String {
    let parts = accelerator.lowercased().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
    guard parts.dropLast().contains(where: { aliases[$0] != nil }) else { return accelerator }
    return parts.enumerated().map { index, part in
      guard index < parts.count - 1, aliases[part] != nil, let names = modifiers(part) else { return part }
      return names == mod ? "mod" : names.joined(separator: "-")
    }.joined(separator: "-")
  }

  var document = LosslessTOMLDocument(source)
  document.removeTable("modifier_combinations")
  let modValue = mod?.joined(separator: "+") ?? oldDefault
  if modValue == Config.defaultMod || writtenMod != nil {
    document.set(table: "", key: "default_key_modifier", value: nil)
  } else {
    // Keep the line and its comment where the user wrote the old prefix.
    if document.contains(table: "", key: "default_key_modifier") {
      document.renameKey(table: "", from: "default_key_modifier", to: "mod")
    }
    document.set(table: "", key: "mod", value: tomlString(modValue))
  }
  if let keys = try? root.table(forKey: "keys") {
    for accelerator in keys.keys.sorted() {
      let replacement = rewritten(accelerator)
      if replacement != accelerator {
        document.renameKey(table: "keys", from: accelerator, to: replacement)
      }
    }
  }
  if let disabled = try? root.array(forKey: "disabled_keys") {
    let accelerators = (0..<disabled.count).compactMap { try? disabled.string(atIndex: $0) }
    let replaced = accelerators.map(rewritten)
    if replaced != accelerators {
      document.set(table: "", key: "disabled_keys", value: tomlStrings(replaced))
    }
  }
  return document.render()
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
