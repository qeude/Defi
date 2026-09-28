import AppKit
import ApplicationServices
import CoreGraphics
import DefiConfig
import DefiModel
import Darwin
import Foundation
import Observation
import ServiceManagement

public struct SettingsDisplayOption: Identifiable, Equatable, Sendable {
  public let id: String
  public let label: String
  public let position: Int
}

public struct SettingsShortcutRow: Identifiable, Equatable, Sendable {
  public var id: String { accelerator }
  public let accelerator: String
  public let command: String
  public let defaultAccelerator: String?
  public let canRestore: Bool
  public let isEnabled: Bool
}

public struct SettingsApplicationOption: Identifiable, Equatable, Sendable {
  public let id: String
  public let bundleIdentifier: String
  public let name: String
  public let path: String
  public let openWindowCount: Int
}

public struct SettingsRuleRow: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let rule: Rule
}

private enum SettingsTOMLOperation {
  case set(table: String, key: String, value: String?, occurrence: Int = 0)
  case appendRule(Rule)
  case removeRule(Int)
  case moveRule(from: Int, to: Int)
}

@MainActor
@Observable
public final class DefiSettingsRuntimeStatus {
  public static let shared = DefiSettingsRuntimeStatus()
  public private(set) var keyboardMessage = "Checking keyboard shortcuts…"
  public private(set) var lastValidConfig: Config?

  private init() {}

  public func updateKeyboardStatus(_ message: String) {
    keyboardMessage = message
  }

  public func updateConfiguration(_ config: Config) {
    lastValidConfig = config
  }
}

@MainActor
@Observable
public final class DefiSettingsModel {
  public private(set) var config: Config {
    didSet { refreshRuleRows() }
  }
  public private(set) var ruleRows: [SettingsRuleRow] = []
  public private(set) var displays: [SettingsDisplayOption] = []
  public private(set) var message: String?
  public private(set) var accessibilityGranted = false
  public private(set) var launchAtLoginEnabled = false
  public private(set) var launchAtLoginNotice: String?
  public private(set) var screenCaptureAvailable = false
  public private(set) var applications: [SettingsApplicationOption] = []
  @ObservationIgnored private let configURL: URL
  @ObservationIgnored private var lastWrittenData: Data?
  @ObservationIgnored private var watcherTask: Task<Void, Never>?
  @ObservationIgnored private var directoryWatcher: DispatchSourceFileSystemObject?

  public init(configURL: URL = Config.defaultURL) {
    self.configURL = configURL
    lastWrittenData = try? Data(contentsOf: configURL)
    do {
      config = try lastWrittenData.map(Config.decode) ?? Config()
    } catch {
      config = DefiSettingsRuntimeStatus.shared.lastValidConfig ?? Config()
      message = "The configuration file is invalid. Defi keeps its last valid settings. \(error)"
    }
    refreshRuleRows()
    refreshSystemStatus()
    refreshDisplays()
  }

  public var configurationPath: String { configURL.path }

  public func refreshSystemStatus() {
    accessibilityGranted = AXIsProcessTrusted()
    screenCaptureAvailable = CGPreflightScreenCaptureAccess()
    switch SMAppService.mainApp.status {
    case .enabled:
      launchAtLoginEnabled = true
      launchAtLoginNotice = nil
    case .requiresApproval:
      launchAtLoginEnabled = false
      launchAtLoginNotice = "Approval required in System Settings"
    case .notRegistered:
      launchAtLoginEnabled = false
      launchAtLoginNotice = nil
    case .notFound:
      launchAtLoginEnabled = false
      launchAtLoginNotice = "Unavailable for this app build"
    @unknown default:
      launchAtLoginEnabled = false
      launchAtLoginNotice = "Unavailable"
    }
  }

  public var shortcutRows: [SettingsShortcutRow] {
    let inherited = inheritedBindings
    var rows = config.keys.sorted { $0.key < $1.key }.map { accelerator, command in
      let defaultAccelerator = inherited.keys.sorted().first { inherited[$0] == command }
      let isOverride = config.keyOverrides[accelerator] != nil
      return SettingsShortcutRow(
        accelerator: accelerator,
        command: command,
        defaultAccelerator: defaultAccelerator,
        canRestore: isOverride || (defaultAccelerator.map(isDisabledKey) ?? false),
        isEnabled: true
      )
    }
    for accelerator in config.disabledKeys {
      guard let binding = inherited.first(where: { sameAccelerator($0.key, accelerator) }),
        !rows.contains(where: { sameAccelerator($0.accelerator, accelerator) })
      else { continue }
      rows.append(SettingsShortcutRow(
        accelerator: binding.key,
        command: binding.value,
        defaultAccelerator: binding.key,
        canRestore: true,
        isEnabled: false
      ))
    }
    return rows.sorted { $0.accelerator < $1.accelerator }
  }

  public func startWatching() {
    guard watcherTask == nil, directoryWatcher == nil else { return }
    refreshExternalChanges()
    let directoryURL = configURL.deletingLastPathComponent()
    let descriptor = open(directoryURL.path, O_EVTONLY)
    if descriptor >= 0 {
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor,
        eventMask: [.write, .rename, .delete],
        queue: .main
      )
      source.setEventHandler { [weak self] in
        MainActor.assumeIsolated { self?.refreshExternalChanges() }
      }
      source.setCancelHandler { close(descriptor) }
      directoryWatcher = source
      source.resume()
    } else {
      watcherTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(500))
          guard !Task.isCancelled else { break }
          self?.refreshExternalChanges()
        }
      }
    }
  }

  public func stopWatching() {
    watcherTask?.cancel()
    watcherTask = nil
    directoryWatcher?.cancel()
    directoryWatcher = nil
  }

  public func refreshDisplays() {
    displays = NSScreen.screens.enumerated().compactMap { index, screen in
      guard
        let number = screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber,
        let stableID = stableDisplayIdentifier(CGDirectDisplayID(number.uint32Value))
      else { return nil }
      return SettingsDisplayOption(
        id: stableID,
        label: "Display \(index + 1) · \(screen.localizedName)",
        position: index + 1
      )
    }
  }

  public func refreshApplications() {
    let counts = visibleWindowCounts()
    var values: [String: SettingsApplicationOption] = [:]
    for application in NSWorkspace.shared.runningApplications {
      guard let identifier = application.bundleIdentifier,
        let name = application.localizedName,
        let path = application.bundleURL?.path
      else { continue }
      values[identifier] = SettingsApplicationOption(
        id: identifier,
        bundleIdentifier: identifier,
        name: name,
        path: path,
        openWindowCount: counts[application.processIdentifier, default: 0]
      )
    }
    for url in installedApplicationURLs() {
      guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
        values[identifier] == nil
      else { continue }
      let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary ?? [:]
      values[identifier] = SettingsApplicationOption(
        id: identifier,
        bundleIdentifier: identifier,
        name: info["CFBundleDisplayName"] as? String
          ?? info["CFBundleName"] as? String
          ?? url.deletingPathExtension().lastPathComponent,
        path: url.path,
        openWindowCount: 0
      )
    }
    applications = values.values.sorted {
      if ($0.openWindowCount > 0) != ($1.openWindowCount > 0) {
        return $0.openWindowCount > 0
      }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  public func set(table: String, key: String, value: String?) {
    save([.set(table: table, key: key, value: value)])
  }

  public func isExplicitlySet(table: String, key: String, occurrence: Int = 0) -> Bool {
    guard let lastWrittenData,
      let source = String(data: lastWrittenData, encoding: .utf8)
    else { return false }
    return LosslessTOMLDocument(source).contains(table: table, key: key, occurrence: occurrence)
  }

  public func reset(table: String, key: String) {
    set(table: table, key: key, value: nil)
  }

  public func ruleName(_ rule: Rule, index: Int) -> String {
    if let appID = rule.appID, !appID.isEmpty { return appID }
    if let title = rule.title, !title.isEmpty { return "Title: \(title)" }
    if let role = rule.role, !role.isEmpty { return "Role: \(role)" }
    return "Rule \(index + 1)"
  }

  public func rulesReferencingWorkspace(_ name: String) -> [String] {
    config.rules.enumerated().compactMap { index, rule in
      rule.workspace == name ? ruleName(rule, index: index) : nil
    }
  }

  public func addRule(_ rule: Rule) {
    guard validateRule(rule) else { return }
    save([.appendRule(rule)])
  }

  public func updateRule(_ rule: Rule, original: Rule, originalIndex: Int) {
    guard validateRule(rule) else { return }
    let index: Int
    if config.rules.indices.contains(originalIndex), config.rules[originalIndex] == original {
      index = originalIndex
    } else if let current = config.rules.firstIndex(of: original) {
      index = current
    } else {
      message = "This application rule changed or was removed in the configuration file."
      return
    }
    save(ruleOperations(rule, at: index))
  }

  public func removeRule(at index: Int) {
    guard config.rules.indices.contains(index) else { return }
    save([.removeRule(index)])
  }

  public func moveRule(from source: Int, to destination: Int) {
    guard config.rules.indices.contains(source), config.rules.indices.contains(destination),
      source != destination
    else { return }
    save([.moveRule(from: source, to: destination)])
  }

  private func refreshRuleRows() {
    var remaining = ruleRows
    ruleRows = config.rules.map { rule in
      if let index = remaining.firstIndex(where: { $0.rule == rule }) {
        return remaining.remove(at: index)
      }
      return SettingsRuleRow(id: UUID(), rule: rule)
    }
  }

  public func reorderRules(_ sources: [UUID], before destination: UUID?) {
    var current = ruleRows.map(\.id)
    let reordered = reorderedSettingsItems(current, moving: sources, before: destination)
    var operations: [SettingsTOMLOperation] = []
    for (target, id) in reordered.enumerated() {
      guard let source = current.firstIndex(of: id), source != target else { continue }
      operations.append(.moveRule(from: source, to: target))
      current.insert(current.remove(at: source), at: target)
    }
    if !operations.isEmpty { save(operations) }
  }

  public func reorderWorkspaces(_ sources: [String], before destination: String?) {
    let names = reorderedSettingsItems(config.workspaces.names, moving: sources, before: destination)
    guard names != config.workspaces.names else { return }
    set(table: "workspaces", key: "names", value: tomlStrings(names))
  }

  public func setWorkspaceIcon(_ name: String, symbol: String?) {
    if let symbol, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil {
      message = "Choose a valid SF Symbol available on this Mac."
      return
    }
    var icons = config.workspaces.icons
    icons[name] = symbol
    set(table: "workspaces", key: "icons", value: icons.isEmpty ? nil : tomlStringMap(icons))
  }

  public func renameWorkspace(_ oldName: String, to rawName: String) {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != oldName else { return }
    guard !config.workspaces.names.contains(name) else {
      message = "A workspace named ‘\(name)’ already exists."
      return
    }
    guard name.allSatisfy({ !$0.isWhitespace }), !name.hasPrefix(WorkspaceID.dynamicPrefix) else {
      message = "Workspace names cannot contain spaces or use Defi’s reserved prefix."
      return
    }
    var names = config.workspaces.names
    guard let index = names.firstIndex(of: oldName) else { return }
    names[index] = name
    var ids = config.workspaces.monitorIDs
    if let value = ids.removeValue(forKey: oldName) { ids[name] = value }
    var positions = config.workspaces.monitors
    if let value = positions.removeValue(forKey: oldName) { positions[name] = value }
    var icons = config.workspaces.icons
    if let value = icons.removeValue(forKey: oldName) { icons[name] = value }
    var operations: [SettingsTOMLOperation] = [
      .set(table: "workspaces", key: "icons", value: icons.isEmpty ? nil : tomlStringMap(icons)),
      .set(table: "workspaces", key: "names", value: tomlStrings(names)),
      .set(table: "workspaces", key: "monitor_ids", value: ids.isEmpty ? nil : tomlStringMap(ids)),
      .set(table: "workspaces", key: "monitors", value: positions.isEmpty ? nil : tomlIntMap(positions)),
    ]
    if config.workspaces.defaultName == oldName {
      operations.append(.set(table: "workspaces", key: "default", value: tomlString(name)))
    }
    for (ruleIndex, rule) in config.rules.enumerated() where rule.workspace == oldName {
      operations.append(.set(table: "rules", key: "workspace", value: tomlString(name), occurrence: ruleIndex))
    }
    for (accelerator, command) in config.keyOverrides {
      if let rewritten = commandByRenamingWorkspace(command, from: oldName, to: name) {
        operations.append(.set(table: "keys", key: accelerator, value: tomlString(rewritten)))
      }
    }
    save(operations)
  }

  public func moveWorkspace(from source: Int, to destination: Int) {
    guard config.workspaces.names.indices.contains(source),
      config.workspaces.names.indices.contains(destination), source != destination
    else { return }
    var names = config.workspaces.names
    names.insert(names.remove(at: source), at: destination)
    set(table: "workspaces", key: "names", value: tomlStrings(names))
  }

  public func setWorkspaceMonitor(_ name: String, identifier: String) {
    var monitorIDs = config.workspaces.monitorIDs
    var positions = config.workspaces.monitors
    if identifier.isEmpty {
      monitorIDs.removeValue(forKey: name)
      positions.removeValue(forKey: name)
    } else if identifier.hasPrefix("legacy-position:"),
      let position = Int(identifier.dropFirst("legacy-position:".count)), position > 0
    {
      positions[name] = position
      monitorIDs.removeValue(forKey: name)
    } else {
      monitorIDs[name] = identifier
      positions.removeValue(forKey: name)
    }
    save([
      .set(table: "workspaces", key: "monitor_ids", value: monitorIDs.isEmpty ? nil : tomlStringMap(monitorIDs)),
      .set(table: "workspaces", key: "monitors", value: positions.isEmpty ? nil : tomlIntMap(positions)),
    ])
  }

  public func setWorkspaceMonitorPosition(_ name: String, position: Int?) {
    var positions = config.workspaces.monitors
    var monitorIDs = config.workspaces.monitorIDs
    if let position, position > 0 {
      positions[name] = position
      monitorIDs.removeValue(forKey: name)
    } else {
      positions.removeValue(forKey: name)
    }
    save([
      .set(table: "workspaces", key: "monitors", value: positions.isEmpty ? nil : tomlIntMap(positions)),
      .set(table: "workspaces", key: "monitor_ids", value: monitorIDs.isEmpty ? nil : tomlStringMap(monitorIDs)),
    ])
  }

  public func workspaceMonitorSelection(_ name: String) -> String {
    if let identifier = config.workspaces.monitorIDs[name] { return identifier }
    if let position = config.workspaces.monitors[name] { return "legacy-position:\(position)" }
    return ""
  }

  public func workspaceMonitorPosition(_ name: String) -> Int? {
    config.workspaces.monitors[name]
  }

  public func disconnectedMonitorOption(for name: String) -> SettingsDisplayOption? {
    let selection = workspaceMonitorSelection(name)
    guard !selection.isEmpty, !selection.hasPrefix("legacy-position:"),
      !displays.contains(where: { $0.id == selection })
    else { return nil }
    return SettingsDisplayOption(
      id: selection,
      label: "Disconnected display · \(selection.prefix(8))…",
      position: 0
    )
  }

  public func addWorkspace(_ rawName: String) {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    guard name.allSatisfy({ !$0.isWhitespace }), !name.hasPrefix(WorkspaceID.dynamicPrefix) else {
      message = "Workspace names cannot contain spaces or use Defi’s reserved prefix."
      return
    }
    var names = config.workspaces.names
    guard !names.contains(name) else {
      message = "A workspace named ‘\(name)’ already exists."
      return
    }
    names.append(name)
    set(table: "workspaces", key: "names", value: tomlStrings(names))
  }

  public func removeWorkspace(_ name: String, clearingRuleAssignments: Bool = false) {
    let references = rulesReferencingWorkspace(name)
    guard references.isEmpty || clearingRuleAssignments else {
      message = "Deleting ‘\(name)’ will remove its workspace assignment from: \(references.joined(separator: ", "))."
      return
    }
    let shortcutReferences = config.keyOverrides.filter {
      commandByRenamingWorkspace($0.value, from: name, to: "") != nil
    }.map(\.key)
    guard shortcutReferences.isEmpty else {
      message = "These shortcuts still refer to ‘\(name)’: \(shortcutReferences.joined(separator: ", ")). Change them before deleting the workspace."
      return
    }
    let names = config.workspaces.names.filter { $0 != name }
    var monitorIDs = config.workspaces.monitorIDs
    var positions = config.workspaces.monitors
    monitorIDs.removeValue(forKey: name)
    positions.removeValue(forKey: name)
    let nextDefault =
      config.workspaces.defaultName == name ? names.first : config.workspaces.defaultName
    var icons = config.workspaces.icons
    icons.removeValue(forKey: name)
    var operations: [SettingsTOMLOperation] = [
      .set(table: "workspaces", key: "icons", value: icons.isEmpty ? nil : tomlStringMap(icons)),
      .set(table: "workspaces", key: "names", value: tomlStrings(names)),
      .set(table: "workspaces", key: "default", value: nextDefault.map(tomlString)),
      .set(table: "workspaces", key: "monitor_ids", value: monitorIDs.isEmpty ? nil : tomlStringMap(monitorIDs)),
      .set(table: "workspaces", key: "monitors", value: positions.isEmpty ? nil : tomlIntMap(positions)),
    ]
    for (index, rule) in config.rules.enumerated().reversed() where rule.workspace == name {
      var remaining = rule
      remaining.workspace = nil
      if hasActions(remaining) {
        operations.append(.set(table: "rules", key: "workspace", value: nil, occurrence: index))
      } else {
        operations.append(.removeRule(index))
      }
    }
    save(operations)
  }

  public func moveShortcut(_ row: SettingsShortcutRow, to rawAccelerator: String) {
    let proposed = rawAccelerator.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let accelerator =
      normalizedAccelerator(proposed, aliases: config.modifierCombinations) ?? proposed
    guard !accelerator.isEmpty, !sameAccelerator(accelerator, row.accelerator) else { return }
    if let conflict = config.keys.first(where: { sameAccelerator($0.key, accelerator) }) {
      guard conflict.value != row.command else { return }
      message = "This shortcut is already used by ‘\(conflict.value)’. Choose another combination."
      return
    }
    var disabled = config.disabledKeys
    if inheritedBindings[row.accelerator] == row.command {
      disabled.append(row.accelerator)
    }
    if inheritedBindings[accelerator] == row.command {
      disabled.removeAll { sameAccelerator($0, accelerator) }
    }
    var operations = [SettingsTOMLOperation.set(table: "keys", key: row.accelerator, value: nil)]
    operations.append(.set(
      table: "keys", key: accelerator,
      value: inheritedBindings[accelerator] == row.command ? nil : tomlString(row.command)
    ))
    operations.append(.set(
      table: "", key: "disabled_keys",
      value: disabled.isEmpty ? nil : tomlStrings(Array(Set(disabled)).sorted())
    ))
    save(operations)
  }

  public func saveShortcut(_ row: SettingsShortcutRow?, accelerator rawAccelerator: String, command rawCommand: String) {
    let accelerator = normalizedAccelerator(rawAccelerator.lowercased(), aliases: config.modifierCombinations)
      ?? rawAccelerator.lowercased()
    let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else { message = "Choose a command for this shortcut."; return }
    if let conflict = config.keys.first(where: {
      sameAccelerator($0.key, accelerator) && $0.key != row?.accelerator
    }) {
      message = "This shortcut is already used by ‘\(conflict.value)’. Choose another combination."
      return
    }
    var disabled = config.disabledKeys
    var operations: [SettingsTOMLOperation] = []
    if let row {
      operations.append(.set(table: "keys", key: row.accelerator, value: nil))
      if inheritedBindings.contains(where: { sameAccelerator($0.key, row.accelerator) && $0.value == row.command }) {
        disabled.append(row.accelerator)
      }
    }
    if let inherited = inheritedBindings.first(where: { sameAccelerator($0.key, accelerator) }), inherited.value == command {
      disabled.removeAll { sameAccelerator($0, accelerator) }
      operations.append(.set(table: "keys", key: accelerator, value: nil))
    } else {
      operations.append(.set(table: "keys", key: accelerator, value: tomlString(command)))
      disabled.removeAll { sameAccelerator($0, accelerator) }
    }
    operations.append(.set(
      table: "", key: "disabled_keys",
      value: disabled.isEmpty ? nil : tomlStrings(Array(Set(disabled)).sorted())
    ))
    save(operations)
  }

  public func removeShortcut(_ row: SettingsShortcutRow) {
    var disabled = config.disabledKeys
    if inheritedBindings.contains(where: { sameAccelerator($0.key, row.accelerator) && $0.value == row.command }) {
      disabled.append(row.accelerator)
    }
    save([
      .set(table: "keys", key: row.accelerator, value: nil),
      .set(table: "", key: "disabled_keys", value: disabled.isEmpty ? nil : tomlStrings(Array(Set(disabled)).sorted())),
    ])
  }

  public func restoreShortcut(_ row: SettingsShortcutRow) {
    var disabled = config.disabledKeys
    if let defaultAccelerator = row.defaultAccelerator {
      disabled.removeAll { sameAccelerator($0, defaultAccelerator) }
    }
    save([
      .set(table: "keys", key: row.accelerator, value: nil),
      .set(table: "", key: "disabled_keys", value: disabled.isEmpty ? nil : tomlStrings(Array(Set(disabled)).sorted())),
    ])
  }

  public func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        if SMAppService.mainApp.status == .requiresApproval {
          SMAppService.openSystemSettingsLoginItems()
        } else {
          try SMAppService.mainApp.register()
        }
      } else if SMAppService.mainApp.status != .notRegistered {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      message = "Could not change Launch at Login: \(error)"
    }
    refreshSystemStatus()
  }

  public func openConfiguration() {
    do {
      try FileManager.default.createDirectory(
        at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      if !FileManager.default.fileExists(atPath: configURL.path) {
        try Data().write(to: configURL, options: .atomic)
        lastWrittenData = Data()
      }
      NSWorkspace.shared.open(configURL)
    } catch {
      message = "Could not open the configuration file: \(error)"
    }
  }

  public func openLogs() {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Logs/Defi/Diagnostics", directoryHint: .isDirectory)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if !NSWorkspace.shared.open(directory) {
        message = "Could not open the logs folder in Finder."
      }
    } catch {
      message = "Could not open the logs folder: \(error)"
    }
  }

  public func openAccessibilitySettings() {
    openDefiAccessibilitySettings()
  }

  public func openDocumentation() {
    guard let url = URL(string: "https://github.com/qeude/Defi/blob/main/CONFIGURATION.md") else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  public func dismissMessage() { message = nil }
  public func presentMessage(_ message: String) { self.message = message }

  private var inheritedBindings: [String: String] {
    Config(
      workspaces: config.workspaces,
      modifierCombinations: config.modifierCombinations,
      defaultKeyModifier: config.defaultKeyModifier
    ).keys
  }

  private func isDisabledKey(_ accelerator: String) -> Bool {
    config.disabledKeys.contains { sameAccelerator($0, accelerator) }
  }

  private func sameAccelerator(_ lhs: String, _ rhs: String) -> Bool {
    normalizedAccelerator(lhs, aliases: config.modifierCombinations)
      == normalizedAccelerator(rhs, aliases: config.modifierCombinations)
  }

  private func validateRule(_ rule: Rule) -> Bool {
    guard rule.appID?.isEmpty == false || rule.title?.isEmpty == false || rule.role?.isEmpty == false else {
      message = "Choose an application or add a title or role condition."
      return false
    }
    guard hasActions(rule) else {
      message = "Choose at least one action for this application rule."
      return false
    }
    return true
  }

  private func hasActions(_ rule: Rule) -> Bool {
    rule.workspace != nil || rule.followFocus || rule.floating || rule.forceTiling
      || rule.intrinsicSize || rule.initialColumnWidth != nil || rule.includeInitialWidthInCycle
  }

  private func ruleOperations(_ rule: Rule, at index: Int) -> [SettingsTOMLOperation] {
    guard config.rules.indices.contains(index) else { return [] }
    let original = config.rules[index]
    var changes: [SettingsTOMLOperation] = []
    func add(_ key: String, _ old: String?, _ new: String?) {
      guard old != new else { return }
      changes.append(.set(table: "rules", key: key, value: new.map(tomlString), occurrence: index))
    }
    add("app_id", original.appID, rule.appID)
    add("title", original.title, rule.title)
    add("role", original.role, rule.role)
    add("workspace", original.workspace, rule.workspace)
    func addBool(_ key: String, _ old: Bool, _ new: Bool) {
      guard old != new else { return }
      changes.append(.set(table: "rules", key: key, value: new ? "true" : "false", occurrence: index))
    }
    addBool("follow_focus", original.followFocus, rule.followFocus)
    addBool("floating", original.floating, rule.floating)
    addBool("force_tiling", original.forceTiling, rule.forceTiling)
    addBool("intrinsic_size", original.intrinsicSize, rule.intrinsicSize)
    if original.initialColumnWidth != rule.initialColumnWidth {
      let width = rule.initialColumnWidth.map { String($0) }
      changes.append(SettingsTOMLOperation.set(
        table: "rules", key: "initial_column_width", value: width, occurrence: index))
    }
    addBool("include_initial_width_in_cycle", original.includeInitialWidthInCycle, rule.includeInitialWidthInCycle)
    return changes
  }

  private func ruleValues(_ rule: Rule) -> [(String, String)] {
    var values: [(String, String)] = []
    for (key, value) in [("app_id", rule.appID), ("title", rule.title), ("role", rule.role), ("workspace", rule.workspace)] {
      if let value { values.append((key, tomlString(value))) }
    }
    for (key, enabled) in [
      ("follow_focus", rule.followFocus), ("floating", rule.floating),
      ("force_tiling", rule.forceTiling), ("intrinsic_size", rule.intrinsicSize),
      ("include_initial_width_in_cycle", rule.includeInitialWidthInCycle),
    ] where enabled {
      values.append((key, "true"))
    }
    if let width = rule.initialColumnWidth { values.append(("initial_column_width", String(width))) }
    return values
  }

  private func commandByRenamingWorkspace(_ command: String, from oldName: String, to newName: String) -> String? {
    var parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
    guard parts.count > 1, parts[1] == oldName,
      ["workspace", "move-window-to-workspace", "send-window-to-workspace",
        "focus-workspace", "focus-workspace-name", "move-column-to-workspace",
        "move-column-to-workspace-name", "send-column-to-workspace",
        "send-column-to-workspace-name", "move-column-to-workspace-position",
        "move-window-to-workspace-name", "send-window-to-workspace-name",
        "move-window-to-workspace-position", "send-window-to-workspace-position"].contains(parts[0])
    else { return nil }
    parts[1] = newName
    return parts.joined(separator: " ")
  }

  private func apply(_ operation: SettingsTOMLOperation, to document: inout LosslessTOMLDocument) {
    switch operation {
    case .set(let table, let key, let value, let occurrence):
      document.set(table: table, key: key, value: value, occurrence: occurrence)
    case .appendRule(let rule):
      document.appendArrayTable("rules", values: ruleValues(rule))
    case .removeRule(let index):
      document.removeArrayTable("rules", occurrence: index)
    case .moveRule(let from, let to):
      document.moveArrayTable("rules", from: from, to: to)
    }
  }

  private func save(_ operations: [SettingsTOMLOperation]) {
    do {
      var baseData = try? Data(contentsOf: configURL)
      guard baseData == lastWrittenData else {
        refreshExternalChanges()
        message =
          "The configuration changed outside Settings. Review the updated values and try again."
        return
      }
      for _ in 0..<3 {
        let currentData = baseData ?? Data()
        guard let source = String(data: currentData, encoding: .utf8) else {
          message = "The configuration file is not valid UTF-8 and was left unchanged."
          return
        }
        var document = LosslessTOMLDocument(source)
        for operation in operations { apply(operation, to: &document) }
        let updatedData = Data(document.render().utf8)
        let updatedConfig = try Config.decode(updatedData)
        if updatedData == currentData {
          lastWrittenData = currentData
          config = updatedConfig
          message = nil
          return
        }
        let latestData = try? Data(contentsOf: configURL)
        guard latestData == baseData else {
          baseData = latestData
          continue
        }
        try FileManager.default.createDirectory(
          at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try updatedData.write(to: configURL, options: .atomic)
        lastWrittenData = updatedData
        config = updatedConfig
        message = nil
        return
      }
      refreshExternalChanges()
      message = "The configuration kept changing while Settings saved. The newest file is shown."
    } catch {
      message = "Settings could not be saved: \(error)"
    }
  }

  func refreshExternalChanges() {
    let currentData = try? Data(contentsOf: configURL)
    guard currentData != lastWrittenData else { return }
    lastWrittenData = currentData
    guard let currentData else {
      config = Config()
      return
    }
    do {
      config = try Config.decode(currentData)
      message = nil
    } catch {
      message =
        "The configuration file changed and is invalid. Defi keeps the last valid settings. \(error)"
    }
  }
}

func reorderedSettingsItems<ID: Hashable>(_ items: [ID], moving sources: [ID], before destination: ID?) -> [ID] {
  let moving = Set(sources)
  guard !moving.isEmpty, moving.isSubset(of: Set(items)),
    destination.map({ items.contains($0) && !moving.contains($0) }) ?? true
  else { return items }
  var remaining = items.filter { !moving.contains($0) }
  let insertion = destination.flatMap { remaining.firstIndex(of: $0) } ?? remaining.endIndex
  remaining.insert(contentsOf: items.filter { moving.contains($0) }, at: insertion)
  return remaining
}

func tomlString(_ value: String) -> String {
  "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n"))\""
}

func tomlStrings(_ values: [String]) -> String {
  "[\(values.map(tomlString).joined(separator: ", "))]"
}

func tomlStringMap(_ values: [String: String]) -> String {
  "{ \(values.keys.sorted().map { "\(tomlString($0)) = \(tomlString(values[$0]!))" }.joined(separator: ", ")) }"
}

func tomlIntMap(_ values: [String: Int]) -> String {
  "{ \(values.keys.sorted().map { "\(tomlString($0)) = \(values[$0]!)" }.joined(separator: ", ")) }"
}

private func visibleWindowCounts() -> [pid_t: Int] {
  guard let windows = CGWindowListCopyWindowInfo(
    [.optionAll, .excludeDesktopElements], kCGNullWindowID
  ) as? [[String: Any]]
  else { return [:] }
  var counts: [pid_t: Int] = [:]
  for window in windows {
    guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
      let processID = window[kCGWindowOwnerPID as String] as? pid_t
    else { continue }
    counts[processID, default: 0] += 1
  }
  return counts
}

private func installedApplicationURLs() -> [URL] {
  let roots = [
    URL(fileURLWithPath: "/Applications", isDirectory: true),
    URL(fileURLWithPath: "/System/Applications", isDirectory: true),
    URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
    FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
  ]
  var applications: [URL] = []
  for root in roots where FileManager.default.fileExists(atPath: root.path) {
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { continue }
    while let url = enumerator.nextObject() as? URL {
      guard url.pathExtension == "app" else { continue }
      applications.append(url)
      enumerator.skipDescendants()
    }
  }
  return applications
}
