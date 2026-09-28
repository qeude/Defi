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
}
