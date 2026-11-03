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
}
