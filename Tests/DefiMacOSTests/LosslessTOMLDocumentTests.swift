import Foundation
import Testing

@testable import DefiMacOS

struct LosslessTOMLDocumentTests {
  @Test
  func targetedUpdatesKeepCommentsAndUnknownTables() {
    let source =
      "# config comment\n[layout]\ngaps = 8 # keep this\nunknown_option = 4\n[custom]\nvalue = \"keep\"\n[[rules]]\napp_id = \"example\"\n"
    var document = LosslessTOMLDocument(source)
    document.set(table: "", key: "disabled_keys", value: "[\"alt-left\"]")
    document.set(table: "layout", key: "gaps", value: "12")
    document.set(table: "input", key: "focus_follows_mouse", value: "true")
    let result = document.render()

    #expect(result.contains("# config comment\ndisabled_keys = [\"alt-left\"]\n[layout]"))
    #expect(result.contains("gaps = 12 # keep this"))
    #expect(result.contains("unknown_option = 4\n[custom]\nvalue = \"keep\""))
    #expect(result.hasSuffix("[input]\nfocus_follows_mouse = true\n"))
  }

  @Test
  func removingAnOverrideKeepsItsInlineComment() {
    var document = LosslessTOMLDocument(
      "[keys]\n\"alt-left\" = \"focus-column left\" # keep note\n")
    document.set(table: "keys", key: "alt-left", value: nil)
    #expect(document.render() == "[keys]\n # keep note\n")
  }

  @Test
  func updatesOnlyTopLevelAssignmentsAfterMultilineValues() {
    var document = LosslessTOMLDocument(
      "[custom]\ntext = \"\"\"\ngaps = 99\n\"\"\"\ngaps = 8\n")

    document.set(table: "custom", key: "gaps", value: "12")

    #expect(document.render() == "[custom]\ntext = \"\"\"\ngaps = 99\n\"\"\"\ngaps = 12\n")
  }

  @Test
  func tableHeaderCommentsAndLiteralKeysRemainParseable() {
    var document = LosslessTOMLDocument(
      "[\"custom#name\"] # keep header comment\n'alt#key' = \"old\" # keep value comment\n")

    document.set(table: "custom#name", key: "alt#key", value: "\"new\"")

    #expect(
      document.render()
        == "[\"custom#name\"] # keep header comment\n'alt#key' = \"new\" # keep value comment\n"
    )
  }

  @Test
  func arrayTableOperationsKeepLeadingCommentsWithTheirRules() {
    var document = LosslessTOMLDocument(
      """
      # first rule
      [[rules]]
      app_id = "first"

      # second rule
      [[rules]] # header note
      app_id = "second"
      title = "before" # inline note
      """)

    document.set(table: "rules", key: "title", value: "\"updated # title\"", occurrence: 1)
    document.moveArrayTable("rules", from: 1, to: 0)
    document.appendArrayTable("rules", values: [("app_id", "\"third\"")])
    document.removeArrayTable("rules", occurrence: 1)
    let result = document.render()

    #expect(
      result.contains(
        "# second rule\n[[rules]] # header note\napp_id = \"second\"\ntitle = \"updated # title\" # inline note\n"
      )
    )
    #expect(result.contains("# first rule") == false)
    #expect(result.contains("[[rules]]\napp_id = \"third\""))
  }
}
