import DefiConfig
import Foundation
import Testing

@testable import DefiMacOS

struct ConfigMigrationTests {
  @Test
  func `Legacy rule keys become window placements and keep comments`() {
    let source = """
      # my rules
      [[rules]]
      app_id = "float" # keep
      floating = true

      [[rules]]
      app_id = "both"
      floating = true
      force_tiling = true

      [[rules]]
      app_id = "off"
      floating = false
      workspace = "dev"

      [[rules]]
      app_id = "untouched"
      window = "force-tiled"

      """
    #expect(migratingLegacyRuleKeys(in: source) == """
      # my rules
      [[rules]]
      app_id = "float" # keep
      window = "force-floating"

      [[rules]]
      app_id = "both"
      window = "force-tiled"

      [[rules]]
      app_id = "off"
      workspace = "dev"

      [[rules]]
      app_id = "untouched"
      window = "force-tiled"

      """)
    #expect(migratingLegacyRuleKeys(in: "[[rules]]\napp_id = \"a\"\nwindow = \"floating\"\n") == nil)
  }

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

  @Test
  func `Default modifier and aliases become mod and keep comments`() {
    let source = """
      default_key_modifier = "hyper" # my prefix
      disabled_keys = ["hyper-left", "ctrl-alt-x"]

      [workspaces]
      names = ["dev"]

      # aliases
      [modifier_combinations]
      hyper = "Alt + Cmd + Ctrl"
      meh = "Ctrl + Alt + Shift"

      [keys]
      "hyper-d" = "diagnostic-mark" # mark
      "meh-k" = "toggle-cheatsheet"
      "cmd-j" = "center-column"

      """
    #expect(migratingLegacyModifierKeys(in: source) == """
      mod = "ctrl+alt+cmd" # my prefix
      disabled_keys = ["mod-left", "ctrl-alt-x"]

      [workspaces]
      names = ["dev"]

      [keys]
      "mod-d" = "diagnostic-mark" # mark
      "ctrl-alt-shift-k" = "toggle-cheatsheet"
      "cmd-j" = "center-column"

      """)
  }

  @Test
  func `A default modifier written out keeps the default mod`() throws {
    #expect(migratingLegacyModifierKeys(in: "default_key_modifier = \"ctrl-alt\"\n") == "\n")
    #expect(migratingLegacyModifierKeys(in: "default_key_modifier = \"cmd-shift\"\n") == "mod = \"shift+cmd\"\n")
    #expect(migratingLegacyModifierKeys(in: "mod = \"alt\"\n") == nil)
    #expect(migratingLegacyModifierKeys(in: "mod = \"alt\"\ndefault_key_modifier = \"cmd\"\n") == "mod = \"alt\"\n")
    let migrated = try #require(migratingLegacyModifierKeys(in: "default_key_modifier = \"cmd-shift\"\n"))
    #expect(try Config.decode(Data(migrated.utf8)).keys["mod-left"] == "focus-column left")
  }
}

