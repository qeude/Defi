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
}
