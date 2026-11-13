import Foundation
import Testing

@testable import DefiMacOS

struct ConfigMigrationTests {
  @Test
  func `Migrations apply in order and report an already current source`() {
    let migrations = [
      ConfigMigration(id: "a", introducedIn: "0.1.0", removeIn: "0.3.0") { $0.replacingOccurrences(of: "old", with: "mid") },
      ConfigMigration(id: "b", introducedIn: "0.2.0", removeIn: "0.4.0") { $0.replacingOccurrences(of: "mid", with: "new") },
    ]
    #expect(migratingLegacyConfiguration(in: "key = \"old\"", migrations: migrations) == "key = \"new\"")
    #expect(migratingLegacyConfiguration(in: "key = \"new\"", migrations: migrations) == nil)
  }

  /// Fails on the release that must delete a migration; move its keys to `removedConfigKeys`.
  @Test(arguments: configMigrations.map(\.id))
  func `Each migration is removed when its release arrives`(id: String) throws {
    let plist = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "Support/Defi-Info.plist")
    let info = try #require(NSDictionary(contentsOf: plist))
    let version = try #require(info["CFBundleShortVersionString"] as? String)
    let migration = try #require(configMigrations.first { $0.id == id })
    #expect(isNewerVersion(migration.introducedIn, than: migration.removeIn) == false)
    #expect(
      isNewerVersion(migration.removeIn, than: version),
      "Defi \(version) must delete the \(id) migration and list its keys in removedConfigKeys"
    )
  }
}
