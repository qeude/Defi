import AppKit
import DefiConfig
import DefiModel
import SwiftUI

@MainActor
public final class CheatsheetController {
  private let config: Config
  private var panel: NSPanel?
  private var closingPanel: NSPanel?
  /// Fitting sizes per column count: measuring builds a hosting view each, at every opening.
  private var measured: (groups: [ShortcutGroup], sizes: [CGSize])?
  private var grouped: (layout: KeyboardLayout?, displayMod: Bool, groups: [ShortcutGroup])?
  private var shown: (groups: [ShortcutGroup], frame: CGRect)?
  /// A closed panel kept briefly for the next opening: building and first drawing the SwiftUI
  /// panel cost each opening ~40 ms. Released 30 s after closing, so idle memory stays as it was.
  private var idle: (panel: NSPanel, groups: [ShortcutGroup], frame: CGRect)?
  private var idleRelease: Task<Void, Never>?

  public init(config: Config) {
    self.config = config
  }

  public func show(on monitorID: MonitorID?) {
    guard let screen = NSScreen.screens.first(where: {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
        .uint64Value == monitorID?.rawValue
    }) ?? NSScreen.main else { return }
    panel?.close()
    panel = nil
    finishClosing()
    let bounds = screen.visibleFrame
    let keyboardLayout = currentKeyboardLayout()
    let displayMod = UserDefaults.standard.object(forKey: displayModDefaultsKey) as? Bool ?? false
    let groups = grouped.flatMap { $0.layout == keyboardLayout && $0.displayMod == displayMod ? $0.groups : nil }
      ?? shortcutGroups(config: config, layout: keyboardLayout, displayMod: displayMod)
    grouped = (keyboardLayout, displayMod, groups)
    let sizes = measured?.groups == groups ? measured!.sizes : (1...max(1, min(4, groups.count))).map {
      NSHostingView(rootView: CheatsheetContent(groups: groups, columnCount: $0)).fittingSize
    }
    measured = (groups, sizes)
    let layout = CheatsheetLayout(
      contentSizes: sizes,
      available: CGSize(width: bounds.width - 48, height: bounds.height - 48)
    )
    let size = layout.panelSize
    let frame = CGRect(
      x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
      width: size.width, height: size.height
    )
    shown = (groups, frame)
    if let reused = idle, reused.groups == groups, reused.frame == frame,
      let content = reused.panel.contentView {
      idle = nil
      idleRelease?.cancel()
      panel = reused.panel
      if animates { Self.fade(content, from: 0, to: 1, duration: 0.15, timing: .easeOut) } else { content.layer?.opacity = 1 }
      reused.panel.orderFrontRegardless()
      return
    }
    idle?.panel.close()
    idle = nil
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
    let hosting = NSHostingView(rootView: CheatsheetView(groups: groups, layout: layout))
    hosting.sizingOptions = []
    panel.contentView = hosting
    hosting.wantsLayer = true
    if animates {
      panel.displayIfNeeded()
      Self.fade(hosting, from: 0, to: 1, duration: 0.15, timing: .easeOut)
    }
    panel.orderFrontRegardless()
  }

  /// The render server runs the fade: AppKit's window-alpha animation stepped from the main
  /// thread, which SwiftUI's first layout keeps busy right when the panel opens.
  private static func fade(_ view: NSView, from start: Float? = nil, to opacity: Float,
    duration: TimeInterval, timing: CAMediaTimingFunctionName) {
    guard let layer = view.layer else { return }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = start ?? (layer.presentation() ?? layer).opacity
    fade.toValue = opacity
    fade.duration = duration
    fade.timingFunction = CAMediaTimingFunction(name: timing)
    fade.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
    layer.opacity = opacity
    layer.add(fade, forKey: "fade")
    MotionSignpost.span("cheatsheet", duration)
  }

  public func close() {
    guard let panel else { return }
    self.panel = nil
    guard animates else { return panel.close() }
    finishClosing()
    closingPanel = panel
    if let content = panel.contentView { Self.fade(content, to: 0, duration: 0.12, timing: .easeIn) }
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(0.12))
      if self?.closingPanel === panel { self?.finishClosing() }
    }
  }

  private func finishClosing() {
    guard let closingPanel else { return }
    self.closingPanel = nil
    closingPanel.orderOut(nil)
    idle?.panel.close()
    idle = shown.map { (closingPanel, $0.groups, $0.frame) }
    idleRelease?.cancel()
    idleRelease = Task { [weak self] in
      try? await Task.sleep(for: .seconds(30))
      guard !Task.isCancelled, let self, let idle else { return }
      idle.panel.close()
      self.idle = nil
    }
  }

  private var animates: Bool {
    config.animation.enabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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

/// Shared with Settings, which groups its shortcut list the same way.
func shortcutSectionTitle(for category: CommandCategory?) -> String {
  switch category {
  case .column: "Columns"
  case .window: "Windows in a column"
  case .workspace: "Workspaces"
  case .monitor: "Monitors"
  case .size: "Size"
  case .floating: "Floating"
  case .other, nil: "Other"
  }
}

private let shortcutSections = CommandCategory.allCases.map(shortcutSectionTitle)

// Order defines row order inside a section. Entries without an argument label the
// whole command family, which also names merged rows such as 1–9 or arrows.
private let shortcutLabels: [(command: String, label: String)] = [
  ("focus-column left", "Column left"), ("focus-column right", "Column right"),
  ("focus-column first", "First column"), ("focus-column last", "Last column"),
  ("center-column", "Center column"),
  ("center-visible-columns", "Center visible columns"),
  ("focus-window up", "Window up"), ("focus-window down", "Window down"),
  ("consume-or-expel-window left", "Join or leave stack left"),
  ("consume-or-expel-window right", "Join or leave stack right"),
  ("unjoin-windows", "Unjoin"),
  ("join-window left", "Join left column"), ("join-window right", "Join right column"),
  ("swap-window left", "Swap window left"), ("swap-window right", "Swap window right"),
  ("focus-workspace up", "Workspace up"), ("focus-workspace down", "Workspace down"),
  ("focus-window-or-workspace up", "Window or workspace up"),
  ("focus-window-or-workspace down", "Window or workspace down"),
  ("focus-workspace-previous", "Previous workspace"),
  ("focus-window-previous", "Previous window"),
  ("recent-windows next", "Recent windows"), ("recent-windows previous", "Recent windows, backward"),
  ("focus-workspace-name", "Workspace"), ("workspace", "Workspace"),
  ("focus-workspace-position", "Workspace"), ("toggle-overview", "Overview"),
  ("focus-column-or-monitor left", "Column or monitor left"),
  ("focus-column-or-monitor right", "Column or monitor right"),
  ("reorder-workspace up", "Reorder workspace up"), ("reorder-workspace down", "Reorder workspace down"),
  ("focus-monitor", "Focus monitor"), ("move-workspace-to-monitor", "Move workspace to monitor"),
  ("cycle-width previous", "Narrower"), ("cycle-width next", "Wider"),
  ("maximize-column", "Maximize column"), ("set-column-width", "Set width"),
  ("expand-column-to-available-width", "Fill free width"),
  ("pin-column left", "Pin column left"), ("pin-column right", "Pin column right"),
  ("set-window-height", "Window height"), ("switch-preset-window-height", "Next window height"),
  ("reset-window-height", "Even window heights"),
  ("toggle-floating", "Float or tile window"),
  ("close-window", "Close window"),
  ("focus-floating previous", "Previous floating"), ("focus-floating next", "Next floating"),
  ("toggle-cheatsheet", "Shortcuts"), ("open-settings", "Settings"),
  ("spawn-sh", "Run"),
  ("move-column left", "Move column left"), ("move-column right", "Move column right"),
  ("move-column first", "Move column to first"), ("move-column last", "Move column to last"),
  ("move-window up", "Move window up"), ("move-window down", "Move window down"),
  ("move-column-to-workspace up", "Move column to workspace up"),
  ("move-column-to-workspace down", "Move column to workspace down"),
  ("move-column-to-workspace", "Move column to workspace"),
  ("move-column-to-workspace-name", "Move column to workspace"),
  ("move-column-to-workspace-position", "Move column to workspace"),
  ("move-column-or-to-monitor left", "Move column or to monitor left"),
  ("move-column-or-to-monitor right", "Move column or to monitor right"),
  ("move-column-to-monitor", "Move column to monitor"), ("activate-floating", "Show floating layer"),
  ("activate-window", "Activate window"),
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
  var section: String { shortcutSectionTitle(for: commandSpec(named: verb)?.category) }
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
  config: Config, layout: KeyboardLayout? = nil, displayMod: Bool = false
) -> [ShortcutGroup] {
  func label(_ modifiers: Set<String>) -> String {
    modifierLabel(modifiers, displayMod: displayMod, aliases: config.modifierAliases)
  }
  let resolution = ShortcutResolution(config: config, layout: layout)
  let bindings = resolution.resolution.keys.compactMap { key, binding in
    normalizedAccelerator(binding.accelerator, aliases: config.modifierAliases)?
      .split(separator: "-").last.map {
        ShortcutBinding(
          modifiers: key.modifierNames, key: resolution.keyName(for: key, named: String($0)),
          command: binding.command)
      }
  }
  // A chord with Shift or Command added joins the row of the same chord without it in the
  // same section; Command, the move layer, wins when both exist.
  let chords = Set(bindings.map { $0.chord($0.modifiers) })
  var shifted: [String: ShortcutBinding] = [:]
  for added in ["shift", "cmd"] {
    for binding in bindings where binding.modifiers.contains(added) {
      let base = binding.chord(binding.modifiers.subtracting([added]))
      if chords.contains(base) { shifted[base] = binding }
    }
  }
  // A chord with its own companion keeps its row instead of joining another.
  shifted = shifted.filter { shifted[$0.value.chord($0.value.modifiers)] == nil }
  let paired = Set(shifted.values.map { $0.chord($0.modifiers) })
  // Alternative keys for the same commands, such as H beside ←, show once: arrows first,
  // Home, End and the page keys last.
  func preference(_ binding: ShortcutBinding) -> (Int, String) {
    let rank = ["left", "right", "up", "down"].contains(binding.key) ? 0
      : ["home", "end", "pageup", "pagedown"].contains(binding.key) ? 2 : 1
    return (rank, binding.key)
  }
  var shown = Set<String>()
  let entries = bindings.filter { !paired.contains($0.chord($0.modifiers)) }
    .sorted { preference($0) < preference($1) }
    .map { (binding: $0, shifted: shifted[$0.chord($0.modifiers)]) }
    .filter {
      shown.insert("\($0.binding.modifiers.sorted())|\($0.binding.command)|\($0.shifted?.command ?? "")")
        .inserted
    }

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

/// With `resolved`, the label names the key actually pressed, including modifiers the layout adds,
/// or says why the shortcut is inactive. An accelerator the resolution does not know is resolved alone.
func shortcutKeyLabel(
  _ accelerator: String, aliases: [String: String],
  displayMod: Bool = false, resolved: ShortcutResolution? = nil
) -> String {
  guard let normalized = normalizedAccelerator(accelerator, aliases: aliases) else {
    return accelerator
  }
  var parts = normalized.split(separator: "-").map(String.init)
  let key = parts.removeLast()
  func label(_ modifiers: Set<String>, _ key: String) -> String {
    modifierLabel(modifiers, displayMod: displayMod, aliases: aliases) + keySymbol(key)
  }
  guard var resolved else { return label(Set(parts), key) }
  if resolved.key(for: normalized) == nil, resolved.inactivity(for: normalized) == nil {
    resolved = ShortcutResolution(bindings: [accelerator: ""], aliases: aliases, layout: resolved.layout)
  }
  if let chord = resolved.key(for: normalized) {
    return label(chord.modifierNames, resolved.keyName(for: chord, named: key))
  }
  switch resolved.inactivity(for: normalized) {
  case .held(let holder):
    return "Held by " + shortcutKeyLabel(
      holder, aliases: aliases, displayMod: displayMod, resolved: resolved)
  case .heldByAnotherApp:
    return "Held by another app"
  default:
    return "Not on this layout"
  }
}

/// Whether shortcut labels show the `mod` combination as ✧; a display preference only.
let displayModDefaultsKey = "displayModSymbol"

private func modifierLabel(_ modifiers: Set<String>, displayMod: Bool, aliases: [String: String]) -> String {
  var modifiers = modifiers
  let mod = Set(normalizedAccelerator("mod-a", aliases: aliases)?.split(separator: "-").dropLast().map(String.init) ?? [])
  let compact = displayMod && !mod.isEmpty && mod.isSubset(of: modifiers)
  if compact { modifiers.subtract(mod) }
  return (compact ? "✧" : "")
    + ["ctrl", "alt", "shift", "cmd"].filter(modifiers.contains).map(keySymbol).joined()
}

private func keySymbol(_ key: String) -> String {
  let symbols = ["cmd": "⌘", "alt": "⌥", "ctrl": "⌃", "shift": "⇧",
    "left": "←", "right": "→", "up": "↑", "down": "↓",
    "tab": "⇥", "return": "↩", "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
    "leftbracket": "[", "rightbracket": "]", "backslash": "\\", "slash": "/",
    "semicolon": ";", "quote": "'", "minus": "−", "equal": "=",
    "comma": ",", "period": "."]
  return symbols[key] ?? key.uppercased()
}
