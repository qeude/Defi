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
    let panel = CheatsheetPanel(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
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
      groups: shortcutGroups(config: config), size: size,
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

struct ShortcutGroup {
  let title: String
  let shortcuts: [(keys: String, command: String)]
}

func shortcutGroups(config: Config) -> [ShortcutGroup] {
  let bindings = ((try? configuredHotKeys(config)) ?? [:]).values.sorted {
    $0.command == $1.command ? $0.accelerator < $1.accelerator : $0.command < $1.command
  }
  let groups = Dictionary(grouping: bindings) { binding in
    if binding.command.hasPrefix("focus-") || binding.command.hasPrefix("workspace ") { return "Navigation" }
    if binding.command.hasPrefix("move-") || binding.command.hasPrefix("send-")
      || binding.command.hasPrefix("reorder-") { return "Movement" }
    return "Layout and actions"
  }
  return ["Navigation", "Movement", "Layout and actions"].compactMap { title in
    guard let bindings = groups[title] else { return nil }
    return ShortcutGroup(title: title, shortcuts: bindings.map { accelerator, command in
      let parts = accelerator.lowercased().split(separator: "-").map(String.init)
      let symbols = ["cmd": "⌘", "command": "⌘", "alt": "⌥", "option": "⌥",
        "ctrl": "⌃", "control": "⌃", "shift": "⇧", "left": "←", "right": "→",
        "up": "↑", "down": "↓", "leftbracket": "[", "rightbracket": "]",
        "backslash": "\\", "slash": "/", "semicolon": ";", "quote": "'",
        "minus": "−", "equal": "=", "comma": ",", "period": "."]
      let expanded = parts.dropLast().flatMap { part -> [String] in
        if part == "hyper", config.modifierCombinations[part] != nil { return ["✦"] }
        return (config.modifierCombinations[part] ?? part).lowercased().split(separator: "+")
          .map { $0.trimmingCharacters(in: .whitespaces) }
      } + parts.suffix(1)
      let keys = expanded.map { symbols[$0] ?? $0.uppercased() }.joined()
      let words = command.split(maxSplits: 1, whereSeparator: \.isWhitespace)
      let name = words.first.map { $0.replacingOccurrences(of: "-", with: " ") } ?? command
      let action = name.prefix(1).uppercased() + name.dropFirst()
      return (keys, action + (words.count > 1 ? " " + words[1] : ""))
    })
  }
}
