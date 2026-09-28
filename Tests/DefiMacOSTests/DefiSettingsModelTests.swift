import AppKit
import DefiConfig
import DefiModel
import Foundation
import Testing

@testable import DefiMacOS

@MainActor
struct DefiSettingsModelTests {
  @Test(arguments: ["up", "down", "1"])
  func workspaceRenamePreservesDirectionalAndPositionalShortcuts(name: String) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "config.toml")
    let relative = name == "1" ? "move-window-to-workspace-position 1" : "move-window-to-workspace \(name)"
    try Data("""
      [workspaces]
      names = ["\(name)"]
      [keys]
      ctrl-alt-a = "\(relative)"
      ctrl-alt-b = "focus-workspace-name \(name)"
      """.utf8).write(to: url)
    let model = DefiSettingsModel(configURL: url)
    model.renameWorkspace(name, to: "renamed")
    #expect(model.message == nil)
    #expect(model.config.keyOverrides["ctrl-alt-a"] == relative)
    #expect(model.config.keyOverrides["ctrl-alt-b"] == "focus-workspace-name renamed")
  }

  @Test
  func disabledGeneratedShortcutCanRestoreItsDefault() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = DefiSettingsModel(configURL: directory.appending(path: "config.toml"))
    let row = try #require(model.shortcutRows.first { $0.accelerator == "alt-left" })
    model.removeShortcut(row)
    let disabled = try #require(model.shortcutRows.first { $0.accelerator == row.accelerator })
    #expect(disabled.isEnabled == false)
    #expect(disabled.canRestore)
    model.restoreShortcut(disabled)
    #expect(model.config.keys[row.accelerator] == row.command)
    #expect(model.config.keyOverrides.isEmpty)
  }

  @Test
  func workspaceIconsPersistAndFollowRenameAndDeletion() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "config.toml")
    try Data("[workspaces]\nnames = [\"dev\"]\n".utf8).write(to: url)
    let model = DefiSettingsModel(configURL: url)
    #expect(model.config.menuBar.workspaceStyle == .name)
    model.setWorkspaceIcon("dev", symbol: "terminal")
    model.set(table: "menu_bar", key: "workspace_style", value: "\"icon_and_name\"")
    let reloaded = DefiSettingsModel(configURL: url)
    #expect(reloaded.config.workspaces.icons["dev"] == "terminal")
    #expect(reloaded.config.menuBar.workspaceStyle == .iconAndName)
    model.renameWorkspace("dev", to: "code")
    #expect(model.config.workspaces.icons == ["code": "terminal"])
    model.removeWorkspace("code", clearingRuleAssignments: true)
    #expect(model.config.workspaces.icons.isEmpty)
    #expect(model.message == nil)
  }

  @Test
  func shortcutActionCatalogContainsValidUnassignedActionsAndNamedWorkspaces() throws {
    let commands = SettingsShortcutActions.availableCommands(workspaces: ["dev", "web"])
    #expect(commands.contains("focus-column first"))
    #expect(commands.contains("focus-workspace-name dev"))
    #expect(commands.contains("send-window-to-workspace-name web"))
    #expect(commands.contains("focus-workspace-position 9"))
    #expect(commands.contains("toggle-overview"))
    for command in commands { _ = try parseCommand(command) }
    let unnamed = SettingsShortcutActions.availableCommands(workspaces: [])
    #expect(!unnamed.contains("focus-workspace-name dev"))
    #expect(unnamed.contains("focus-workspace down"))
  }

  @Test
  func dragReorderingPreservesRulesAndWorkspaceAssignments() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "config.toml")
    try Data("""
      [workspaces]
      names = ["dev", "web", "tools"]
      monitors = { dev = 2 }
      [[rules]]
      app_id = "first" # keep first comment
      workspace = "dev"
      [[rules]]
      app_id = "second" # keep second comment
      floating = true
      [[rules]]
      app_id = "third"
      force_tiling = true
      """.utf8).write(to: url)
    let model = DefiSettingsModel(configURL: url)
    let ids = model.ruleRows.map(\.id)

    model.reorderRules([ids[0]], before: nil)
    #expect(model.config.rules.map(\.appID) == ["second", "third", "first"])
    #expect(model.ruleRows.map(\.id) == [ids[1], ids[2], ids[0]])
    model.reorderRules([ids[2], ids[0]], before: ids[1])
    #expect(model.ruleRows.map(\.id) == [ids[2], ids[0], ids[1]])
    let source = try String(contentsOf: url, encoding: .utf8)
    #expect(source.contains("app_id = \"first\" # keep first comment"))
    #expect(source.contains("app_id = \"second\" # keep second comment"))

    model.reorderWorkspaces(["dev"], before: nil)
    #expect(model.config.workspaces.names == ["web", "tools", "dev"])
    #expect(model.config.workspaces.monitors["dev"] == 2)
    #expect(model.config.rules[1].workspace == "dev")
    model.reorderWorkspaces(["tools", "dev"], before: "web")
    #expect(model.config.workspaces.names == ["tools", "dev", "web"])
    let saved = try Data(contentsOf: url)
    model.reorderWorkspaces(["missing"], before: "web")
    model.reorderRules([UUID()], before: ids[0])
    #expect(try Data(contentsOf: url) == saved)
    #expect(model.message == nil)
  }

  @Test
  func hyperDisplayDoesNotChangeShortcutMeaning() {
    let aliases = ["hyper": "Ctrl + Alt + Cmd"]
    #expect(shortcutKeyLabel("hyper-shift-k", aliases: aliases) == "✦⇧K")
    #expect(shortcutKeyLabel("ctrl-alt-cmd-k", aliases: [:]) == "✦K")
    #expect(shortcutKeyLabel("hyper-k", aliases: aliases, displayHyper: false) == "⌃⌥⌘K")
    #expect(shortcutKeyLabel("hyper-k", aliases: aliases, hyperIncludesShift: true) == "⌃⌥⌘K")
    #expect(shortcutKeyLabel("hyper-shift-k", aliases: aliases, hyperIncludesShift: true) == "✦K")
    #expect(shortcutKeyLabel("alt-k", aliases: [:]) == "⌥K")
  }

  @Test
  func recordedKeysMatchHotkeyEngine() throws {
    for code in acceleratorKeyCodes.values {
      let accelerator = try #require(
        recordedAccelerator(
          keyCode: code, modifiers: [.control, .option, .shift, .command, .capsLock]
        ))
      let key = try Key(accelerator: accelerator, aliases: [:])
      #expect(key.code == code)
      #expect(
        key.modifierBits
          == hotKeyModifierBits([
            .maskControl, .maskAlternate, .maskShift, .maskCommand,
          ]))
    }
    #expect(recordedAccelerator(keyCode: 0, modifiers: []) == nil)
    #expect(recordedAccelerator(keyCode: 0, modifiers: [.shift]) == nil)
    #expect(recordedAccelerator(keyCode: 53, modifiers: [.command]) == nil)
  }

  @Test
  func recordingRejectsOccupiedShortcutAndPreservesFile() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "config.toml")
    let original = Data("# Keep my settings\n".utf8)
    try original.write(to: url)
    let model = DefiSettingsModel(configURL: url)
    let rows = model.shortcutRows
    let first = try #require(rows.first)
    let other = try #require(rows.dropFirst().first)
    model.moveShortcut(first, to: other.accelerator)
    #expect(try Data(contentsOf: url) == original)
    #expect(model.message?.contains("already used") == true)

    let recorded = try #require(recordedAccelerator(keyCode: 7, modifiers: [.control, .option]))
    model.moveShortcut(first, to: recorded)
    #expect(model.config.keys[recorded] == first.command)
    #expect(model.config.keys[first.accelerator] == nil)
    let moved = try #require(model.shortcutRows.first { $0.accelerator == recorded })
    model.restoreShortcut(moved)
    #expect(model.config.keys[first.accelerator] == first.command)
    #expect(model.config.keys[recorded] == nil)
  }

  @Test
  func recordingEveryExistingCombinationKeepsItsBinding() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "config.toml")
    let original = Data("default_key_modifier = \"hyper\"\n[modifier_combinations]\nhyper = \"Alt + Cmd + Ctrl\"\n".utf8)
    try original.write(to: url)
    let model = DefiSettingsModel(configURL: url)
    for row in model.shortcutRows {
      let key = try Key(accelerator: row.accelerator, aliases: model.config.modifierCombinations)
      let recorded = try #require(recordedAccelerator(
        keyCode: key.code, modifiers: NSEvent.ModifierFlags(rawValue: UInt(key.modifierBits))))
      model.moveShortcut(row, to: recorded)
      #expect(model.message == nil, "Re-recording \(row.command): \(row.accelerator)")
      #expect(try Data(contentsOf: url) == original)
    }
  }

  @Test
  func recordingSameShortcutAgainIsIdempotent() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "config.toml")
    let model = DefiSettingsModel(configURL: url)
    let original = try #require(model.shortcutRows.first)
    model.moveShortcut(original, to: "ctrl-alt-x")
    let saved = try Data(contentsOf: url)
    model.moveShortcut(original, to: "option-control-x")
    #expect(model.message == nil)
    #expect(try Data(contentsOf: url) == saved)
    let current = try #require(model.shortcutRows.first { $0.accelerator == "alt-ctrl-x" })
    model.moveShortcut(current, to: "ctrl-alt-x")
    #expect(model.message == nil)
    #expect(try Data(contentsOf: url) == saved)
    model.moveShortcut(current, to: original.accelerator)
    #expect(model.message == nil)
    #expect(model.config.keys[original.accelerator] == original.command)
  }

  @Test
  func firstEditCreatesMissingConfiguration() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "config.toml")
    let model = DefiSettingsModel(configURL: url)

    model.set(table: "layout", key: "gaps", value: "16")

    #expect(try Config.load(from: url).layout.gaps == 16)
  }

  @Test
  func invalidEditKeepsOriginalFile() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "config.toml")
    let original = Data("[layout]\ngaps = 8 # keep\n".utf8)
    try original.write(to: url)
    let model = DefiSettingsModel(configURL: url)

    model.set(table: "layout", key: "gaps", value: "300")

    #expect(try Data(contentsOf: url) == original)
    #expect(model.message != nil)
  }

  @Test
  func externalEditWinsOverPendingSettingsWrite() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "config.toml")
    try Data("[layout]\ngaps = 8\n".utf8).write(to: url)
    let model = DefiSettingsModel(configURL: url)
    let external = Data("[layout]\ngaps = 12\n".utf8)
    try external.write(to: url, options: .atomic)

    model.set(table: "layout", key: "outer_top_gap", value: "20")

    #expect(try Data(contentsOf: url) == external)
    #expect(model.config.layout.gaps == 12)
    #expect(model.message?.contains("changed outside Settings") == true)
  }

  @Test
  func externalAtomicReplacementRefreshesSettings() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "config.toml")
    try Data("[layout]\ngaps = 8\n".utf8).write(to: url)
    let model = DefiSettingsModel(configURL: url)
    try Data("[layout]\ngaps = 12\n".utf8).write(to: url, options: .atomic)

    model.refreshExternalChanges()

    #expect(model.config.layout.gaps == 12)
  }
}
