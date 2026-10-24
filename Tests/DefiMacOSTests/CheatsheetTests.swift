import AppKit
import ApplicationServices
import DefiConfig
import DefiModel
import Synchronization
import Testing
@testable import DefiMacOS

struct CheatsheetHotKeyTests {
  @Test
  func `Tap normalizes modifier aliases and captures Escape only while help is visible`() throws {
    let flags: CGEventFlags = [.maskAlternate, .maskCommand, .maskControl]
    let key = try Key(accelerator: "hyper-a", aliases: ["hyper": "Alt + Cmd + Ctrl"])
    let inputs = Mutex<[CheatsheetInput]>([])
    let context = InputMonitor(
      bindings: [:], userInputTracker: UserInputTracker(),
      pointerMotionTracker: PointerMotionTracker(), tracksPointerWindowTransitions: false,
      cheatsheetModifierBits: key.modifierBits,
      deliverCheatsheet: { input in inputs.withLock { $0.append(input) } },
      deliver: { _ in }, deliverOverview: { _ in }, deliverPointerMotion: { _ in },
      tapReenabled: { _ in }
    )
    context.setHotKeysRegistered(true)
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
    event.flags = [.maskAlternate]
    #expect(context.handle(type: .flagsChanged, event: event) != nil)
    event.flags = flags
    #expect(context.handle(type: .flagsChanged, event: event) != nil)
    #expect(context.handle(type: .keyDown, event: event) != nil)
    context.setCheatsheetVisible(true)
    #expect(context.intercept(type: .keyDown, event: event) == nil)
    event.flags = []
    #expect(context.handle(type: .flagsChanged, event: event) != nil)
    #expect(inputs.withLock { $0 } == [
      .modifiersChanged(matches: false, released: false),
      .modifiersChanged(matches: true, released: false),
      .keyDown(modifiersHeld: true), .dismiss,
      .modifiersChanged(matches: false, released: true),
    ])
    for type: CGEventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
      inputs.withLock { $0.removeAll() }
      event.type = type
      #expect(context.handle(type: type, event: event) != nil)
      #expect(inputs.withLock { $0 } == [.dismiss])
    }
  }

  @Test
  func `Help includes configured overrides and abbreviates Hyper`() {
    let config = Config(
      modifierCombinations: ["hyper": "Alt + Cmd + Ctrl"],
      defaultKeyModifier: "hyper",
      keys: ["hyper-left": "focus-column first", "hyper-slash": "toggle-cheatsheet"]
    )
    let shortcuts = shortcutGroups(config: config).flatMap(\.shortcuts)
    #expect(shortcuts.count == config.keys.count)
    #expect(shortcuts.contains { $0.keys == "✦←" && $0.command == "Focus column first" })
    #expect(shortcuts.contains { $0.keys == "✦/" && $0.command == "Toggle cheatsheet" })
    #expect(shortcuts.contains { $0.command == "Focus column left" } == false)
  }
}

@MainActor
struct CheatsheetPanelTests {
  @Test
  func `Panel fits its content and never restores a closed panel or takes focus`() async throws {
    let wasActive = NSApplication.shared.isActive
    let controller = CheatsheetController(config: Config(
      modifierCombinations: ["hyper": "Alt + Cmd + Ctrl"], defaultKeyModifier: "hyper"
    ))
    defer { controller.close() }
    func visiblePanel() -> NSWindow? {
      NSApplication.shared.windows.first { $0.title == "Defi keyboard shortcuts" && $0.isVisible }
    }
    controller.show(on: nil)
    let first = try #require(visiblePanel())
    #expect(!first.canBecomeKey)
    #expect(!first.canBecomeMain)
    #expect(!first.styleMask.contains(.titled))
    controller.close()
    controller.show(on: nil)
    let current = try #require(visiblePanel())
    let screen = try #require(current.screen)
    let deadline = ContinuousClock.now + .seconds(2)
    // The fit can follow an opaque panel (no fade under Reduce Motion), and on a small
    // screen it keeps the largest frame: wait for the frame to hold still instead.
    var settled = current.frame, stableSince = ContinuousClock.now
    while first.isVisible || current.alphaValue < 0.99
      || ContinuousClock.now - stableSince < .milliseconds(150), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
      if current.frame != settled { settled = current.frame; stableSince = ContinuousClock.now }
    }
    #expect(!first.isVisible, "A closed panel must not reappear")
    #expect(abs(current.alphaValue - 1) < 0.01)
    #expect(NSApplication.shared.isActive == wasActive, "Showing the panel must not activate Defi")
    #expect(current.frame.height <= screen.visibleFrame.height - 48)
    #expect(current.frame.width <= screen.visibleFrame.width - 48)
    #expect(current.frame.width > 600)
    #expect(abs(current.frame.midX - screen.visibleFrame.midX) <= 1)
    #expect(abs(current.frame.midY - screen.visibleFrame.midY) <= 1)
    let fitted = current.frame
    try await Task.sleep(for: .milliseconds(200))
    #expect(current.frame == fitted, "The fitted panel must not resize after showing")
    controller.close()
    while current.isVisible, ContinuousClock.now < deadline + .seconds(1) {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!current.isVisible)
  }

  @Test
  func `Panel opens on the requested display`() async throws {
    let controller = CheatsheetController(config: Config())
    defer { controller.close() }
    func visiblePanels() -> [NSWindow] {
      NSApplication.shared.windows.filter { $0.title == "Defi keyboard shortcuts" && $0.isVisible }
    }
    for screen in NSScreen.screens {
      let number = try #require(
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint64Value)
      // The previous panel fades out before the next one is checked.
      let deadline = ContinuousClock.now + .seconds(2)
      while !visiblePanels().isEmpty, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      controller.show(on: MonitorID(rawValue: number))
      let panel = try #require(visiblePanels().first)
      #expect(panel.screen == screen, "Panel must open on display \(number)")
      #expect(screen.visibleFrame.contains(panel.frame), "Panel must open inside display \(number)")
      controller.close()
    }
  }
}
