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
    let context = HotKeyTapContext(
      bindings: [:], userInputTracker: UserInputTracker(),
      pointerMotionTracker: PointerMotionTracker(), tracksPointerWindowTransitions: false,
      cheatsheetModifierBits: key.modifierBits,
      deliverCheatsheet: { input in inputs.withLock { $0.append(input) } },
      deliver: { _ in }, deliverOverview: { _ in }, deliverPointerMotion: { _ in },
      tapReenabled: { _ in }
    )
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
    event.flags = [.maskAlternate]
    #expect(context.handle(type: .flagsChanged, event: event) != nil)
    event.flags = flags
    #expect(context.handle(type: .flagsChanged, event: event) != nil)
    #expect(context.handle(type: .keyDown, event: event) != nil)
    context.setCheatsheetVisible(true)
    #expect(context.handle(type: .keyDown, event: event) == nil)
    event.flags = []
    #expect(context.handle(type: .flagsChanged, event: event) != nil)
    #expect(inputs.withLock { $0 } == [
      .modifiersChanged(matches: false, released: false),
      .modifiersChanged(matches: true, released: false),
      .keyDown(modifiersHeld: true), .keyDown(modifiersHeld: true), .dismiss,
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
