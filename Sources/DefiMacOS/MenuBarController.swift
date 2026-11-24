import AppKit
import SwiftUI

/// Draws every workspace in the menu bar; a click on a mark switches to it, any other click opens the menu.
@MainActor
public final class MenuBarController: NSObject {
  private let state: MenuBarState
  private let commandHandler: (String) -> Void
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private lazy var menu = NSHostingMenu(rootView: MenuBarContent(state: state, commandHandler: commandHandler))
  private var target: MenuBarLayout?
  private var shown: MenuBarLayout?
  private var animation: (from: MenuBarLayout, start: TimeInterval, timer: Timer)?

  public init(state: MenuBarState, commandHandler: @escaping (String) -> Void) {
    self.state = state
    self.commandHandler = commandHandler
    super.init()
    item.autosaveName = "Defi Workspaces"
    if let button = item.button {
      button.imagePosition = .imageOnly
      button.target = self
      button.action = #selector(clicked)
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    state.onChange = { [weak self] in self?.render() }
    render()
  }

  private func render() {
    item.isVisible = state.isInserted
    item.button?.setAccessibilityLabel("Defi workspace \(state.activeLabel)")
    item.button?.toolTip = "Defi workspace \(state.activeLabel)"
    let next = menuBarLayout(state.displayedMonitors, config: state.config)
    guard next != target else { return }
    target = next
    animation?.timer.invalidate()
    animation = nil
    guard let shown, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      shown.marks.contains(where: { mark in next.marks.contains { $0.workspaceID == mark.workspaceID } })
    else { return show(next) }
    let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.step() }
    }
    RunLoop.main.add(timer, forMode: .common)
    animation = (shown, ProcessInfo.processInfo.systemUptime, timer)
  }

  private func step() {
    guard let animation, let target else { return }
    let t = min((ProcessInfo.processInfo.systemUptime - animation.start) / 0.2, 1)
    if t >= 1 {
      animation.timer.invalidate()
      self.animation = nil
      return show(target)
    }
    show(interpolate(animation.from, target, 1 - pow(1 - t, 3)))
  }

  private func show(_ layout: MenuBarLayout) {
    shown = layout
    item.button?.image = menuBarImage(layout)
  }

  @objc private func clicked(_ sender: NSStatusBarButton) {
    if let event = NSApp.currentEvent, event.type == .leftMouseUp, !event.modifierFlags.contains(.control),
      let shown, let image = sender.image, let window = sender.window
    {
      // The action's event is not always located in the button's window, so read the pointer instead.
      let pointer = sender.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
      let x = pointer.x - (sender.bounds.width - image.size.width) / 2
      if let workspace = shown.workspace(atX: x) {
        return commandHandler("workspace \(workspace)")
      }
    }
    state.refreshAccessibilityPermission()
    item.menu = menu
    sender.performClick(nil)
    item.menu = nil
  }
}
