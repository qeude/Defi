import AppKit
import DefiConfig
import DefiModel
import SwiftUI

@MainActor
public final class CheatsheetController {
  private let config: Config
  private var panel: NSPanel?

  public init(config: Config) {
    self.config = config
  }

  public func show(on monitorID: MonitorID?) {
    guard let screen = NSScreen.screens.first(where: {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
        .uint64Value == monitorID?.rawValue
    }) ?? NSScreen.main else { return }
    close()
    let bounds = screen.visibleFrame
    let size = CGSize(width: bounds.width - 48, height: bounds.height - 48)
    let frame = CGRect(
      x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
      width: size.width, height: size.height
    )
    // With a screen, the content rect is relative to that screen's origin.
    let panel = CheatsheetPanel(
      contentRect: frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false, screen: screen
    )
    panel.title = "Defi keyboard shortcuts"
    panel.setAccessibilityLabel(panel.title)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isExcludedFromWindowsMenu = true
    panel.animationBehavior = .none
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    self.panel = panel
    let hosting = NSHostingView(rootView: CheatsheetView(
      groups: shortcutGroups(
        config: config,
        displayHyper: UserDefaults.standard.object(forKey: "displayHyperSymbol") as? Bool ?? true,
        hyperIncludesShift: UserDefaults.standard.bool(forKey: "displayHyperIncludesShift")
      ), size: size,
      contentSizeChanged: { [weak self, weak panel] measured in
        DispatchQueue.main.async {
          guard let self, let panel, self.panel === panel else { return }
          let fitted = CGSize(
            width: min(measured.width, size.width), height: min(measured.height, size.height)
          )
          let frame = CGRect(
            x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
            width: fitted.width, height: fitted.height
          )
          if panel.frame != frame { panel.setFrame(frame, display: false) }
        }
      }
    ))
    hosting.sizingOptions = []
    panel.contentView = hosting
    let animated = config.animation.enabled
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    panel.alphaValue = animated ? 0.001 : 1
    panel.orderFrontRegardless()
    if animated {
      panel.displayIfNeeded()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().alphaValue = 1
      }
    }
  }

  public func close() {
    panel?.close()
    panel = nil
  }
}

private final class CheatsheetPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

struct ShortcutGroup: Equatable {
  let title: String
  let rows: [ShortcutRow]
}

struct ShortcutRow: Hashable {
  let modifiers: String
  let key: String
  let action: String
  /// The same key with Shift added, shown on the same row.
  let shifted: ShiftedShortcut?
}

struct ShiftedShortcut: Hashable {
  let modifiers: String
  let action: String
}

private let shortcutSections = [
  "Columns", "Windows in a column", "Workspaces", "Monitors", "Size", "Floating", "Other",
]

// Order defines row order inside a section. Entries without an argument label the
// whole command family, which also names merged rows such as 1–9 or arrows.
private let shortcutLabels: [(command: String, label: String)] = [
  ("focus-column left", "Column left"), ("focus-column right", "Column right"),
  ("focus-column first", "First column"), ("focus-column last", "Last column"),
  ("focus-window up", "Window up"), ("focus-window down", "Window down"),
  ("join-window left", "Join left column"), ("join-window right", "Join right column"),
  ("unjoin-windows", "Unjoin"),
  ("focus-workspace up", "Workspace up"), ("focus-workspace down", "Workspace down"),
  ("focus-workspace-name", "Workspace"), ("workspace", "Workspace"),
  ("focus-workspace-position", "Workspace"), ("toggle-overview", "Overview"),
  ("focus-monitor", "Focus monitor"), ("move-workspace-to-monitor", "Move workspace to monitor"),
  ("cycle-width previous", "Narrower"), ("cycle-width next", "Wider"),
  ("maximize-column", "Maximize column"),
  ("toggle-floating", "Float or tile window"),
  ("focus-floating previous", "Previous floating"), ("focus-floating next", "Next floating"),
  ("toggle-cheatsheet", "Shortcuts"),
  ("move-column left", "Move column left"), ("move-column right", "Move column right"),
  ("move-column first", "Move column to first"), ("move-column last", "Move column to last"),
  ("move-window up", "Move window up"), ("move-window down", "Move window down"),
  ("move-column-to-workspace up", "Move column to workspace up"),
  ("move-column-to-workspace down", "Move column to workspace down"),
  ("move-column-to-workspace", "Move column to workspace"),
  ("move-column-to-workspace-name", "Move column to workspace"),
  ("move-column-to-workspace-position", "Move column to workspace"),
  ("move-column-to-monitor", "Move column to monitor"), ("activate-floating", "Show floating layer"),
]

private struct ShortcutBinding {
  let modifiers: Set<String>
  let key: String
  let command: String

  var verb: String { command.split(maxSplits: 1, whereSeparator: \.isWhitespace).first.map(String.init) ?? command }
  var argument: String? {
    let words = command.split(maxSplits: 1, whereSeparator: \.isWhitespace)
    return words.count > 1 ? String(words[1]) : nil
  }
  var section: String {
    if verb.contains("monitor") { return "Monitors" }
    if verb.contains("workspace") || verb == "toggle-overview" { return "Workspaces" }
    if verb.contains("width") || verb == "maximize-column" { return "Size" }
    if verb.contains("floating") { return "Floating" }
    if verb.contains("window") { return "Windows in a column" }
    if verb.contains("column") { return "Columns" }
    return "Other"
  }
  var rank: Int {
    shortcutLabels.firstIndex { $0.command == command }
      ?? shortcutLabels.firstIndex { $0.command == verb } ?? shortcutLabels.count
  }
  var label: String {
    if let exact = shortcutLabels.first(where: { $0.command == command }) { return exact.label }
    return familyLabel + (argument.map { " " + $0 } ?? "")
  }
  var familyLabel: String {
    if let family = shortcutLabels.first(where: { $0.command == verb }) { return family.label }
    let name = verb.replacingOccurrences(of: "-", with: " ")
    return name.prefix(1).uppercased() + name.dropFirst()
  }
  func chord(_ modifiers: Set<String>) -> String { "\(section)|\(modifiers.sorted())|\(key)" }
}

func shortcutGroups(
  config: Config, displayHyper: Bool = true, hyperIncludesShift: Bool = false
) -> [ShortcutGroup] {
  func chord(_ accelerator: String) -> (modifiers: Set<String>, key: String)? {
    guard var parts = normalizedAccelerator(accelerator, aliases: config.modifierCombinations)?
      .split(separator: "-").map(String.init) else { return nil }
    let key = parts.removeLast()
    return (Set(parts), key)
  }
  func label(_ modifiers: Set<String>) -> String {
    modifierLabel(modifiers, displayHyper: displayHyper, hyperIncludesShift: hyperIncludesShift)
  }
  let bindings = ((try? configuredHotKeys(config)) ?? [:]).values.compactMap { binding in
    chord(binding.accelerator).map {
      ShortcutBinding(modifiers: $0.modifiers, key: $0.key, command: binding.command)
    }
  }
  // A Shift chord joins the row of the same chord without Shift in the same section.
  let chords = Set(bindings.map { $0.chord($0.modifiers) })
  var shifted: [String: ShortcutBinding] = [:]
  for binding in bindings where binding.modifiers.contains("shift") {
    let base = binding.chord(binding.modifiers.subtracting(["shift"]))
    if chords.contains(base) { shifted[base] = binding }
  }
  let paired = Set(shifted.values.map { $0.chord($0.modifiers) })
  let entries = bindings.filter { !paired.contains($0.chord($0.modifiers)) }
    .map { (binding: $0, shifted: shifted[$0.chord($0.modifiers)]) }

  let groups = shortcutSections.compactMap { title -> ShortcutGroup? in
    let section = entries.filter { $0.binding.section == title }
    guard !section.isEmpty else { return nil }
    var rows: [(rank: Int, order: String, row: ShortcutRow)] = []
    let families = Dictionary(grouping: section) {
      "\($0.binding.modifiers.sorted())|\($0.binding.verb)|\($0.shifted?.verb ?? "")"
    }
    for family in families.values {
      var remaining = family
      let prefix = label(family[0].binding.modifiers)
      // Merge 1–9 and the four arrows only when each argument is its own key.
      let ownKey = remaining.filter {
        $0.binding.argument == $0.binding.key && ($0.shifted.map { $0.argument == $0.key } ?? true)
      }
      let digits = ownKey.compactMap { Int($0.binding.key) }.sorted()
      let arrows = Set(ownKey.map(\.binding.key)).intersection(["left", "right", "up", "down"])
      var mergedKey: String?
      var merged: Set<String> = []
      if digits.count > 1, digits.last! - digits.first! == digits.count - 1 {
        mergedKey = "\(digits.first!)–\(digits.last!)"
        merged = Set(digits.map(String.init))
      } else if arrows.count == 4 {
        mergedKey = "←↑↓→"
        merged = arrows
      }
      let mergedEntries = ownKey.filter { merged.contains($0.binding.key) }
      if let mergedKey, let first = mergedEntries.first {
        let suffix = digits.count > 1 ? " " + mergedKey : ""
        rows.append((first.binding.rank, mergedKey, ShortcutRow(
          modifiers: prefix, key: mergedKey, action: first.binding.familyLabel + suffix,
          shifted: first.shifted.map {
            ShiftedShortcut(modifiers: label($0.modifiers), action: $0.familyLabel + suffix)
          })))
        let mergedChords = Set(mergedEntries.map { $0.binding.chord($0.binding.modifiers) })
        remaining.removeAll { mergedChords.contains($0.binding.chord($0.binding.modifiers)) }
      }
      for entry in remaining {
        rows.append((entry.binding.rank, entry.binding.key, ShortcutRow(
          modifiers: prefix, key: keySymbol(entry.binding.key), action: entry.binding.label,
          shifted: entry.shifted.map {
            ShiftedShortcut(modifiers: label($0.modifiers), action: $0.label)
          })))
      }
    }
    return ShortcutGroup(title: title, rows: rows.sorted {
      ($0.rank, $0.row.modifiers, $0.order) < ($1.rank, $1.row.modifiers, $1.order)
    }.map(\.row))
  }
  return groups
}

func shortcutKeyLabel(
  _ accelerator: String, aliases: [String: String],
  displayHyper: Bool = true, hyperIncludesShift: Bool = false
) -> String {
  guard let normalized = normalizedAccelerator(accelerator, aliases: aliases) else {
    return accelerator
  }
  var parts = normalized.split(separator: "-").map(String.init)
  let key = parts.removeLast()
  return modifierLabel(Set(parts), displayHyper: displayHyper, hyperIncludesShift: hyperIncludesShift)
    + keySymbol(key)
}

private func modifierLabel(
  _ modifiers: Set<String>, displayHyper: Bool, hyperIncludesShift: Bool
) -> String {
  var modifiers = modifiers
  let hyper: Set<String> = hyperIncludesShift
    ? ["ctrl", "alt", "cmd", "shift"] : ["ctrl", "alt", "cmd"]
  let compact = displayHyper && hyper.isSubset(of: modifiers)
  if compact { modifiers.subtract(hyper) }
  return (compact ? "✧" : "")
    + ["ctrl", "alt", "shift", "cmd"].filter(modifiers.contains).map(keySymbol).joined()
}

private func keySymbol(_ key: String) -> String {
  let symbols = ["cmd": "⌘", "alt": "⌥", "ctrl": "⌃", "shift": "⇧",
    "left": "←", "right": "→", "up": "↑", "down": "↓",
    "leftbracket": "[", "rightbracket": "]", "backslash": "\\", "slash": "/",
    "semicolon": ";", "quote": "'", "minus": "−", "equal": "=",
    "comma": ",", "period": "."]
  return symbols[key] ?? key.uppercased()
}
