import DefiRuntime
import DefiCore
import DefiModel
import ApplicationServices
import Carbon
import DefiConfig
import Synchronization
import Testing
@testable import DefiMacOS

private final class HotKeyInvocationRecorder: Sendable {
  private let invocations = Mutex<[HotKeyInvocation]>([])

  func append(_ invocation: HotKeyInvocation) {
    invocations.withLock { $0.append(invocation) }
  }

  var commands: [String] {
    invocations.withLock { $0.map(\.command) }
  }
}

@Suite
struct OverviewHotKeyTests {
  static let hyper = hotKeyModifierBits([.maskAlternate, .maskCommand, .maskControl])
  static let hyperShift = hyper | hotKeyModifierBits([.maskShift])

  // key code, modifiers, configured command -> action
  @Test(arguments: [
    (31, UInt64.max, "toggle-overview", .cancel),
    (33, hyper, "focus-column first", .firstColumn), (0, hyper, "focus-column first", .firstColumn),
    (30, hyper, "focus-column last", .lastColumn),
    (126, hyper, "focus-workspace up", .workspaceUp), (125, hyper, "focus-workspace down", .workspaceDown),
    (18, hyper, "workspace dev", .workspace(.named("dev"))),
    (19, hyper, "focus-workspace-position 2", .workspace(.position(2))),
    (20, hyper, "focus-workspace-name dev-secondary", .workspace(.named("dev-secondary"))),
    (123, 0, nil, .left), (123, hyper, "focus-column left", .left), (123, hyper, nil, nil),
    (123, hyperShift, "move-column left", .layout(.moveColumn(.left))),
    (126, hyperShift, "move-window up", .moveUp), (125, hyperShift, "move-window down", .moveDown),
    (36, 0, nil, .select), (36, hyper, "focus-column left", nil), (53, 0, nil, .cancel), (0, 0, nil, nil),
  ] as [(CGKeyCode, UInt64, String?, OverviewKeyAction?)])
  func overviewKeyActionFollowsKeyAndBinding(keyCode: CGKeyCode, modifiers: UInt64, command: String?,
    action: OverviewKeyAction?) {
    #expect(overviewKeyAction(keyCode: keyCode, modifierBits: modifiers, configuredCommand: command) == action)
  }

  @Test(arguments: [false, true])
  func settingsTargetKeyEventsRespectTextFocus(textFocused: Bool) throws {
    let key = try Key(accelerator: "alt-left", aliases: [:])
    let invocations = HotKeyInvocationRecorder()
    let context = InputMonitor(
      bindings: [key: "focus-column left"], userInputTracker: UserInputTracker(),
      pointerMotionTracker: PointerMotionTracker(), tracksPointerWindowTransitions: false,
      deliver: { invocations.append($0) }, deliverOverview: { _ in },
      deliverPointerMotion: { _ in }, tapReenabled: { _ in },
      textInputFocused: { textFocused })
    context.setHotKeysRegistered(true)
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: true))
    event.flags = [.maskAlternate]
    event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(getpid()))
    let forwarded = context.handle(type: .keyDown, event: event)
    if textFocused {
      #expect(forwarded?.takeUnretainedValue() === event)
      #expect(invocations.commands.isEmpty)
    } else {
      #expect(forwarded?.takeUnretainedValue() === event)
      #expect(invocations.commands == ["focus-column left"])
    }
  }

  @Test(arguments: [false, true])
  func interceptedModalKeysStillUpdateUserActivity(overview: Bool) throws {
    let tracker = UserInputTracker()
    let context = InputMonitor(
      bindings: [:], userInputTracker: tracker,
      pointerMotionTracker: PointerMotionTracker(), tracksPointerWindowTransitions: false,
      deliver: { _ in }, deliverOverview: { _ in }, deliverPointerMotion: { _ in },
      tapReenabled: { _ in }, textInputFocused: { false })
    context.setOverviewModeEnabled(overview)
    context.setCheatsheetVisible(!overview)
    let event = try #require(CGEvent(keyboardEventSource: nil,
                                    virtualKey: overview ? 125 : 53, keyDown: true))
    event.flags = []
    event.timestamp = 7_000_000_000
    #expect(context.intercept(type: .keyDown, event: event) == nil)
    #expect(tracker.latestEventTimestamp == 7)
    #expect(tracker.snapshot.latestCapturedCommandTimestamp == (overview ? 7 : 0))
  }

}

struct HotKeyTests {
  @Test(arguments: ["a", "alt-fn", "typo-left", "-left", "alt--left", "alt-left-", "", "broken-left"])
  func malformedAcceleratorsCannotBecomeNativeShortcuts(accelerator: String) {
    #expect(throws: HotKeyError.invalidAccelerator(accelerator)) {
      try Key(accelerator: accelerator, aliases: ["broken": "Ctrl + + Alt"])
    }
  }

  @Test(arguments: ["combo", "zzcombo", "shift-control-option"])
  func equivalentAcceleratorsRespectConfigurationPrecedence(modifier: String) throws {
    let aliases = ["combo": "Ctrl + Alt + Shift", "zzcombo": "Ctrl + Alt + Shift"]
    let config = Config(modifierCombinations: aliases, defaultKeyModifier: modifier)
    let key = try Key(accelerator: "ctrl-alt-shift-left", aliases: aliases)
    #expect(try configuredHotKeys(config)[key]?.command == "focus-column left")
    // An explicit binding wins even when its spelling sorts before the default.
    let overridden = Config(
      modifierCombinations: aliases, defaultKeyModifier: modifier,
      keys: ["combo-left": "focus-column first"]
    )
    #expect(try configuredHotKeys(overridden)[key]?.command == "focus-column first")
  }

  @Test(arguments: [CGEventType.mouseMoved, .leftMouseDragged])
  func routedPointerEventsDeliverDestinationWithoutStaleSourceFocus(type: CGEventType) async throws {
    let first = MonitorID(rawValue: 1), second = MonitorID(rawValue: 2)
    let desk = [
      first: Rect(x: 0, y: 0, width: 1_000, height: 700),
      second: Rect(x: 1_000, y: 0, width: 1_000, height: 700),
    ]
    let router = DisplayPointerRouter(warpPointer: { _ in .success })
    let motions = Mutex<[PointerMotionInvocation]>([])
    router.update(technical: isolatedDisplayArrangement(desk, primary: first), desk: desk)
    let context = InputMonitor(
      bindings: [:], userInputTracker: UserInputTracker(),
      pointerMotionTracker: PointerMotionTracker(), displayPointerRouter: router,
      tracksPointerWindowTransitions: true,
      deliver: { _ in }, deliverOverview: { _ in },
      deliverPointerMotion: { invocation in motions.withLock { $0.append(invocation) } },
      tapReenabled: { _ in }
    )
    let event = try #require(CGEvent(
      mouseEventSource: nil, mouseType: type,
      mouseCursorPosition: CGPoint(x: 999, y: 350), mouseButton: .left
    ))
    event.setDoubleValueField(.mouseEventDeltaX, value: 5)
    event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 42)
    #expect(context.intercept(type: type, event: event) != nil)
    #expect(context.handle(type: type, event: event) != nil)
    #expect(router.warpCount == 1)
    #expect(event.location == CGPoint(x: 1_002, y: -350))
    if type == .mouseMoved {
      let deadline = ContinuousClock.now + .seconds(2)
      while motions.withLock({ $0.isEmpty }), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      let delivered = motions.withLock { $0 }
      #expect(delivered.count == 1)
      #expect(delivered.first?.windowID == nil)
      #expect(delivered.first?.location == event.location)
    } else {
      #expect(motions.withLock { $0.isEmpty })
    }
  }

  private let aliases = [
    "hyper": "Alt + Cmd + Ctrl"
  ]

  private func makeContext(
    bindings: [Key: String],
    closeIntent: @escaping @Sendable (TimeInterval, pid_t?) -> Void = { _, _ in }
  ) -> (InputMonitor, HotKeyInvocationRecorder) {
    let invocations = HotKeyInvocationRecorder()
    let context = InputMonitor(
      bindings: bindings,
      userInputTracker: UserInputTracker(),
      pointerMotionTracker: PointerMotionTracker(),
      tracksPointerWindowTransitions: false,
      deliver: { invocations.append($0) },
      deliverOverview: { _ in },
      deliverPointerMotion: { _ in },
      tapReenabled: { _ in },
      closeIntent: closeIntent
    )
    context.setHotKeysRegistered(true)
    return (context, invocations)
  }

  @Test(arguments: [
    ("hyper-left", 123, [.maskAlternate, .maskCommand, .maskControl], optionKey | cmdKey | controlKey),
    ("hyper-shift-1", 18, [.maskAlternate, .maskCommand, .maskControl, .maskShift],
      optionKey | cmdKey | controlKey | shiftKey),
    ("hyper-equal", 24, [.maskAlternate, .maskCommand, .maskControl], optionKey | cmdKey | controlKey),
    ("hyper-minus", 27, [.maskAlternate, .maskCommand, .maskControl], optionKey | cmdKey | controlKey),
    ("hyper-f", 3, [.maskAlternate, .maskCommand, .maskControl], optionKey | cmdKey | controlKey),
    ("hyper-backslash", 42, [.maskAlternate, .maskCommand, .maskControl], optionKey | cmdKey | controlKey),
    ("hyper-comma", 43, [.maskAlternate, .maskCommand, .maskControl], optionKey | cmdKey | controlKey),
    ("hyper-period", 47, [.maskAlternate, .maskCommand, .maskControl], optionKey | cmdKey | controlKey),
    ("alt-left", 123, [.maskAlternate], optionKey),
    ("ctrl-shift-right", 124, [.maskControl, .maskShift], controlKey | shiftKey),
  ] as [(String, CGKeyCode, CGEventFlags, Int)])
  func acceleratorsResolveKeyCodeAndModifiers(accelerator: String, code: CGKeyCode, flags: CGEventFlags,
    carbon: Int) throws {
    let key = try Key(accelerator: accelerator, aliases: aliases)
    #expect(key.code == code)
    #expect(key.modifierBits == flags.rawValue)
    #expect(key.carbonModifiers == UInt32(carbon))
  }

  @NavigationActor
  @Test
  func `Invalid binding disables hot keys but keeps pointer tracking configured`() {
    let config = Config(
      input: InputConfig(focusFollowsMouse: true),
      keys: ["unknown-no-such-key": "focus-column left"]
    )

    let manager = HotKeyManager(config: config) { _ in }

    #expect(manager.bindingCount == 0)
    #expect(manager.bindingError == .invalidAccelerator("unknown-no-such-key"))
    #expect(manager.tracksPointerMotion)
  }

  // key code, flags, registered -> commands; every event reaches the application unchanged
  @Test(arguments: [
    (18, [.maskAlternate, .maskCommand, .maskControl], true, ["workspace 1"]),
    (18, [.maskCommand], true, []),
    (19, [.maskAlternate, .maskCommand, .maskControl], true, []),
    (18, [.maskAlternate, .maskCommand, .maskControl], false, []),
  ] as [(CGKeyCode, CGEventFlags, Bool, [String])])
  func shortcutsTriggerOnlyTheirRegisteredChordAndForwardEveryEvent(code: CGKeyCode, flags: CGEventFlags,
    registered: Bool, commands: [String]) throws {
    let (context, invocations) = makeContext(bindings: [try Key(accelerator: "hyper-1", aliases: aliases): "workspace 1"])
    context.setHotKeysRegistered(registered)
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
    event.flags = flags
    #expect(context.handle(type: .keyDown, event: event)?.takeUnretainedValue() === event)
    #expect(context.intercept(type: .keyDown, event: event)?.takeUnretainedValue() === event)
    #expect(event.flags == flags)
    #expect(invocations.commands == commands)
    #expect(context.capturedKeyCount == commands.count)
    let modifierRelease = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 59, keyDown: false))
    modifierRelease.type = .flagsChanged
    modifierRelease.flags = [.maskAlternate, .maskCommand]
    #expect(context.handle(type: .flagsChanged, event: modifierRelease)?.takeUnretainedValue() === modifierRelease)
  }

  @Test
  func overviewModeRoutesBoundKeysToOverviewWithoutCommands() throws {
    let bindings = Dictionary(uniqueKeysWithValues: try [
      ("hyper-left", "focus-column left"), ("hyper-1", "workspace dev"),
      ("hyper-2", "focus-workspace-position 2"), ("hyper-3", "focus-workspace-name web"),
    ].map { (try Key(accelerator: $0.0, aliases: aliases), $0.1) })
    let actions = Mutex<[OverviewKeyAction]>([])
    let invocations = HotKeyInvocationRecorder()
    let context = InputMonitor(
      bindings: bindings, userInputTracker: UserInputTracker(),
      pointerMotionTracker: PointerMotionTracker(), tracksPointerWindowTransitions: false,
      deliver: { invocations.append($0) },
      deliverOverview: { action in actions.withLock { $0.append(action) } },
      deliverPointerMotion: { _ in }, tapReenabled: { _ in })
    context.setHotKeysRegistered(true)
    context.setOverviewModeEnabled(true)
    for code: CGKeyCode in [123, 18, 19, 20] {
      let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
      event.flags = [.maskAlternate, .maskCommand, .maskControl]
      #expect(context.intercept(type: .keyDown, event: event) == nil)
      _ = context.handle(type: .keyDown, event: event)
    }
    #expect(actions.withLock { $0 } == [.left, .workspace(.named("dev")),
      .workspace(.position(2)), .workspace(.named("web"))])
    #expect(invocations.commands.isEmpty, "Overview keys must not mutate the native workspace")
    #expect(context.capturedKeyCount == 4)
  }

  @Test
  func heldCheatsheetShortcutTogglesOnceWhileOtherCommandsRepeat() throws {
    let toggle = try Key(accelerator: "hyper-slash", aliases: aliases)
    let focus = try Key(accelerator: "hyper-right", aliases: aliases)
    let (context, invocations) = makeContext(bindings: [toggle: "toggle-cheatsheet", focus: "focus-column right"])
    for key in [toggle, focus] {
      let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: true))
      event.flags = CGEventFlags(rawValue: key.modifierBits)
      _ = context.handle(type: .keyDown, event: event)
      event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
      _ = context.handle(type: .keyDown, event: event)
    }
    #expect(invocations.commands == ["toggle-cheatsheet", "focus-column right", "focus-column right"])
  }

  @Test
  func scrollWheelRecordsUserInput() throws {
    let tracker = UserInputTracker()
    let context = InputMonitor(
      bindings: [:], userInputTracker: tracker,
      pointerMotionTracker: PointerMotionTracker(), tracksPointerWindowTransitions: false,
      deliver: { _ in }, deliverOverview: { _ in }, deliverPointerMotion: { _ in },
      tapReenabled: { _ in })
    let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
      wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
    scroll.timestamp = 9_000_000_000
    _ = context.handle(type: .scrollWheel, event: scroll)
    #expect(tracker.latestEventTimestamp == 9)
  }

  @Test(arguments: [pid_t(0), 4242])
  func `Command W forwards the event and reports close intent`(
    rawProcessID: pid_t
  ) throws {
    let intents = Mutex<[(timestamp: TimeInterval, processID: pid_t?)]>([])
    let (context, invocations) = makeContext(
      bindings: [:],
      closeIntent: { timestamp, processID in
        intents.withLock { $0.append((timestamp, processID)) }
      }
    )
    let event = try #require(
      CGEvent(keyboardEventSource: nil, virtualKey: 13, keyDown: true)
    )
    event.flags = [.maskCommand]
    event.setIntegerValueField(
      .eventTargetUnixProcessID,
      value: Int64(rawProcessID)
    )
    let expectedTimestamp = Double(event.timestamp) / 1_000_000_000

    let forwardedEvent = context.handle(type: .keyDown, event: event)

    #expect(forwardedEvent?.takeUnretainedValue() === event)
    #expect(invocations.commands.isEmpty)
    #expect(intents.withLock { $0.map(\.timestamp) } == [expectedTimestamp])
    let expectedProcessID = rawProcessID > 0 ? rawProcessID : nil
    #expect(intents.withLock { $0.map(\.processID) } == [expectedProcessID])
  }

}

struct HotKeyModifierReleaseTests {
  private let hyper = hotKeyModifierBits([
    .maskAlternate,
    .maskCommand,
    .maskControl,
  ])

  // flags after capturing Hyper -> whether each change is new input
  @Test(arguments: [
    ([[.maskAlternate, .maskCommand], [.maskAlternate], []], [false, false, false]),
    ([[.maskAlternate, .maskCommand, .maskControl, .maskShift]], [true]),
    ([[.maskAlternate, .maskCommand], [.maskAlternate, .maskCommand, .maskControl]], [false, true]),
  ] as [([CGEventFlags], [Bool])])
  func onlyNewModifierPressesAfterACapturedChordBecomeInput(changes: [CGEventFlags], records: [Bool]) {
    var state = CapturedHotKeyModifierReleaseState()
    state.capture(modifierBits: hyper)
    #expect(changes.map { state.shouldRecord(flagsChangedTo: hotKeyModifierBits($0)) } == records)
    #expect(state.heldModifierBits == 0)
  }

}
