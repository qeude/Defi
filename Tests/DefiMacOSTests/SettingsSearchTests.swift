import DefiConfig
import Foundation
import Testing

@testable import DefiMacOS

struct SettingsSearchTests {
  @Test(arguments: ["version", "github", "updates", "release notes"])
  func aboutSearchOpensDedicatedPage(query: String) throws {
    let results = SettingsSearchCatalog.results(matching: query, config: Config(), shortcuts: [])
    let result = try #require(results.first { $0.destination == .option(.about) })
    #expect(result.destination.page == .about)
    #expect(result.destination.anchor == .option(.about))
  }

  @Test(arguments: ["  RESERVED_TOP \n", "Layout.reserved_top", "reserved top area"])
  func findsAdvancedOptionByLabelAndConfigKey(query: String) throws {
    let results = SettingsSearchCatalog.results(matching: query, config: Config(), shortcuts: [])
    let result = try #require(results.first)
    #expect(result.destination == .option(.reservedTop))
    #expect(result.title == "Reserved top area")
    #expect(result.context == "Layout · Advanced")
    #expect(result.destination.anchor == .option(.reservedTop))
    #expect(result.destination.isAdvanced)
  }

  @Test
  func whitespaceAndUnknownQueriesDoNotReplacePageNavigation() {
    #expect(SettingsSearchCatalog.results(matching: " \n ", config: Config(), shortcuts: []).isEmpty)
    #expect(SettingsSearchCatalog.results(matching: "unfindable-value", config: Config(), shortcuts: []).isEmpty)
    let results = SettingsSearchCatalog.results(matching: "animation duration", config: Config(), shortcuts: [])
    #expect(results.map(\.destination) == [.option(.animationDuration)])
  }

  @Test(arguments: ["---", "___", "+++", " -_+ \n"])
  func separatorOnlyQueriesDoNotMatchResultsOrShortcuts(query: String) {
    #expect(SettingsSearchCatalog.results(matching: query, config: Config(), shortcuts: []).isEmpty)
    let filter = SettingsShortcutFilter.query(query)
    #expect(!filter.includes("focus-column left"))
  }

  @Test(arguments: ["", " \n \t"])
  func blankQueriesKeepAllShortcutsWithoutSearchResults(query: String) {
    #expect(SettingsSearchCatalog.results(matching: query, config: Config(), shortcuts: []).isEmpty)
    let commands = ["focus-column left", "focus-column right", "reload"]
    let filter = SettingsShortcutFilter.query(query)
    #expect(commands.filter(filter.includes) == ["focus-column left", "focus-column right", "reload"])
  }

  @Test(arguments: ["hyper-left", "control+option+command+left", "⌃⌥⌘←", "✦←"])
  func findsConfiguredCombinationAndAliases(query: String) throws {
    var config = Config()
    config.modifierCombinations["hyper"] = "ctrl+alt+cmd"
    let rows = [binding("hyper-left", "focus-column left")]
    let results = SettingsSearchCatalog.results(matching: query, config: config, shortcuts: rows)
    let result = try #require(results.first)
    #expect(result.destination == .shortcut("focus-column left"))
    #expect(result.title == "Focus Column Left")
    #expect(result.detail == "⌃⌥⌘←")
    #expect(result.destination.anchor == .keyboardShortcuts)
  }

  @Test
  func includesUnassignedCustomAndWorkspaceCommandsWithoutDuplicateActions() throws {
    var config = Config()
    config.workspaces.names = ["design"]
    let rows = [
      binding("ctrl-a", "focus-column left"), binding("ctrl-b", "focus-column left"),
      binding("ctrl-c", "focus-workspace-position 12"), binding("ctrl-d", "reload"),
    ]
    let commands = SettingsSearchCatalog.shortcutResults(config: config, shortcuts: rows)
    let left = try #require(commands.first { $0.destination == .shortcut("focus-column left") })
    #expect(commands.filter { $0.destination == .shortcut("focus-column left") }.count == 1)
    #expect(left.detail == "⌃A · ⌃B")
    #expect(commands.contains { $0.destination == .shortcut("reload") })
    #expect(commands.contains { $0.destination == .shortcut("focus-workspace-position 12") })
    let workspace = SettingsSearchCatalog.results(matching: "focus workspace name design", config: config, shortcuts: rows)
    #expect(workspace.map(\.destination) == [.shortcut("focus-workspace-name design")])
    let unassigned = try #require(commands.first { $0.destination == .shortcut("toggle-overview") })
    #expect(unassigned.detail == "Not assigned")
  }

  @Test
  func disabledBindingsRemainFindableAndAreLabelledDisabled() throws {
    let rows = [binding("alt-left", "focus-column left", enabled: false)]
    let results = SettingsSearchCatalog.results(matching: "alt-left", config: Config(), shortcuts: rows)
    let result = try #require(results.first)
    #expect(result.destination == .shortcut("focus-column left"))
    #expect(result.detail == "⌥← (Disabled)")
  }

  @Test
  func shortcutRevealUsesExactCommandUntilLocalSearchIsEdited() {
    let commands = ["focus-column left", "focus-column left extra", "focus-column right"]
    let exact = SettingsShortcutFilter.command("focus-column left")
    #expect(commands.filter(exact.includes) == ["focus-column left"])
    #expect(exact.text == "focus-column left")
    let query = SettingsShortcutFilter.query("  FOCUS-COLUMN  ")
    #expect(commands.filter(query.includes) == commands)
  }

  @Test
  func workspaceFieldsAndActionsFollowCurrentConfiguration() {
    var config = Config()
    config.workspaces.names = ["design"]
    config.workspaces.monitors["design"] = 2
    let results = SettingsSearchCatalog.results(matching: "workspace icon design", config: config, shortcuts: [])
    #expect(results.map(\.destination) == [.workspace(name: "design", field: .icon)])
    let number = SettingsSearchCatalog.results(matching: "display number design", config: config, shortcuts: [])
    #expect(number.map(\.destination) == [.workspace(name: "design", field: .displayNumber)])
    config.workspaces.names = ["code"]
    config.workspaces.monitors = [:]
    #expect(SettingsSearchCatalog.results(matching: "workspace icon design", config: config, shortcuts: []).isEmpty)
    #expect(SettingsSearchCatalog.results(matching: "display number code", config: config, shortcuts: []).isEmpty)
    let renamed = SettingsSearchCatalog.results(matching: "workspace icon code", config: config, shortcuts: [])
    #expect(renamed.map(\.destination) == [.workspace(name: "code", field: .icon)])
    let shortcut = SettingsSearchCatalog.results(matching: "focus workspace name code", config: config, shortcuts: [])
    #expect(shortcut.map(\.destination) == [.shortcut("focus-workspace-name code")])
  }

  @Test
  func removedDynamicDestinationsFallBackToTheirPage() {
    var config = Config()
    config.workspaces.names = ["design"]
    config.workspaces.monitors["design"] = 2
    let target = SettingsDestination.workspace(name: "design", field: .displayNumber)
    #expect(SettingsSearchCatalog.contains(target, config: config, shortcuts: []))
    config.workspaces.monitors = [:]
    #expect(!SettingsSearchCatalog.contains(target, config: config, shortcuts: []))
    #expect(target.page == .workspaces)
    let custom = SettingsDestination.shortcut("focus-workspace-position 12")
    #expect(SettingsSearchCatalog.contains(custom, config: config,
      shortcuts: [binding("ctrl-a", "focus-workspace-position 12")]))
    #expect(!SettingsSearchCatalog.contains(custom, config: config, shortcuts: []))
    #expect(custom.page == .input)
  }

  private func binding(_ accelerator: String, _ command: String, enabled: Bool = true) -> SettingsShortcutRow {
    SettingsShortcutRow(accelerator: accelerator, command: command, defaultAccelerator: nil,
      canRestore: !enabled, isEnabled: enabled)
  }
}
