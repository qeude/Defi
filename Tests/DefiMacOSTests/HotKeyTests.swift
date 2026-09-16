import DefiCore
import DefiModel
import ApplicationServices
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
  @Test
  func `Overview captures navigation arrows but leaves move bindings active`() {
    let hyper = hotKeyModifierBits([
      .maskAlternate,
      .maskCommand,
      .maskControl,
    ])

    #expect(overviewKeyAction(keyCode: 123, modifierBits: 0) == .left)
    #expect(
      overviewKeyAction(
        keyCode: 123,
        modifierBits: hyper,
        configuredCommand: "focus-column left"
      ) == .left
    )
    #expect(overviewKeyAction(keyCode: 123, modifierBits: hyper) == nil)
    #expect(
      overviewKeyAction(
        keyCode: 123,
        modifierBits: hyper | hotKeyModifierBits([.maskShift]),
        configuredCommand: "move-column left"
      ) == nil
    )
    #expect(
      overviewKeyAction(
        keyCode: 126,
        modifierBits: hyper | hotKeyModifierBits([.maskShift]),
        configuredCommand: "move-window up"
      ) == .moveUp
    )
    #expect(
      overviewKeyAction(
        keyCode: 125,
        modifierBits: hyper | hotKeyModifierBits([.maskShift]),
        configuredCommand: "move-window down"
      ) == .moveDown
    )
    #expect(overviewKeyAction(keyCode: 36, modifierBits: 0) == .select)
    #expect(
      overviewKeyAction(
        keyCode: 36,
        modifierBits: hyper,
        configuredCommand: "focus-column left"
      ) == nil
    )
    #expect(overviewKeyAction(keyCode: 53, modifierBits: 0) == .cancel)
    #expect(overviewKeyAction(keyCode: 0, modifierBits: 0) == nil)
  }
}

struct HotKeyTests {
  @Test(arguments: ["-left", "alt--left", "alt-left-", "", "broken-left"])
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
  func routedPointerEventsWarpAndMouseMovementSuppressesSourceFocus(type: CGEventType) async throws {
    let first = MonitorID(rawValue: 1), second = MonitorID(rawValue: 2)
    let desk = [
      first: Rect(x: 0, y: 0, width: 1_000, height: 700),
      second: Rect(x: 1_000, y: 0, width: 1_000, height: 700),
    ]
    let router = DisplayPointerRouter(warpPointer: { _ in .success })
    router.update(technical: isolatedDisplayArrangement(desk, primary: first), desk: desk)
    let context = HotKeyTapContext(
      bindings: [:], userInputTracker: UserInputTracker(),
      pointerMotionTracker: PointerMotionTracker(), displayPointerRouter: router,
      tracksPointerWindowTransitions: true,
      deliver: { _ in }, deliverOverview: { _ in },
      deliverPointerMotion: { _ in Issue.record("Delivered stale pre-warp window focus") },
      tapReenabled: { _ in }
    )
    let event = try #require(CGEvent(
      mouseEventSource: nil, mouseType: type,
      mouseCursorPosition: CGPoint(x: 999, y: 350), mouseButton: .left
    ))
    event.setDoubleValueField(.mouseEventDeltaX, value: 5)
    event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 42)
    #expect(context.handle(type: type, event: event) != nil)
    #expect(router.warpCount == 1)
    #expect(event.location == CGPoint(x: 1_002, y: -350))
    if type == .mouseMoved {
      try await Task.sleep(for: .milliseconds(30))
      #expect(context.pointerTransitionCount == 0)
    }
  }

  private let aliases = [
    "hyper": "Alt + Cmd + Ctrl"
  ]

  private func makeContext(
    bindings: [Key: String],
    closeIntent: @escaping @Sendable (TimeInterval, pid_t?) -> Void = { _, _ in }
  ) -> (HotKeyTapContext, HotKeyInvocationRecorder) {
    let invocations = HotKeyInvocationRecorder()
    return (
      HotKeyTapContext(
        bindings: bindings,
        userInputTracker: UserInputTracker(),
        pointerMotionTracker: PointerMotionTracker(),
        tracksPointerWindowTransitions: false,
        deliver: { invocations.append($0) },
        deliverOverview: { _ in },
        deliverPointerMotion: { _ in },
        tapReenabled: { _ in },
        closeIntent: closeIntent
      ),
      invocations
    )
  }

  @Test(arguments: [
    ("hyper-left", CGKeyCode(123), false),
    ("hyper-shift-1", CGKeyCode(18), true),
    ("hyper-equal", CGKeyCode(24), false),
    ("hyper-minus", CGKeyCode(27), false),
    ("hyper-f", CGKeyCode(3), false),
    ("hyper-backslash", CGKeyCode(42), false),
    ("hyper-comma", CGKeyCode(43), false),
    ("hyper-period", CGKeyCode(47), false),
  ])
  func `Hyper bindings use expected key codes and modifiers`(
    testCase: (accelerator: String, code: CGKeyCode, shift: Bool)
  ) throws {
    var expectedModifiers = CGEventFlags([
      .maskAlternate,
      .maskCommand,
      .maskControl,
    ])
    if testCase.shift {
      expectedModifiers.insert(.maskShift)
    }

    let key = try Key(accelerator: testCase.accelerator, aliases: aliases)

    #expect(key.code == testCase.code)
    #expect(key.modifierBits == expectedModifiers.rawValue)
  }

  @MainActor
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

  @Test
  func `Filtering tap runs after remappers`() {
    #expect(hotKeyEventTapPlacement == .tailAppendEventTap)
  }

  @Test
  func `Captured hyper shortcut never reaches the foreground application`() throws {
    let hyper = CGEventFlags([
      .maskAlternate,
      .maskCommand,
      .maskControl,
    ])
    let boundKey = try Key(accelerator: "hyper-1", aliases: aliases)
    let (context, invocations) = makeContext(
      bindings: [boundKey: "workspace 1"]
    )
    let event = try #require(
      CGEvent(keyboardEventSource: nil, virtualKey: 18, keyDown: true)
    )
    event.flags = hyper

    let forwardedEvent = context.handle(type: .keyDown, event: event)

    #expect(forwardedEvent == nil)
    #expect(invocations.commands == ["workspace 1"])

    let modifierRelease = try #require(
      CGEvent(keyboardEventSource: nil, virtualKey: 59, keyDown: false)
    )
    modifierRelease.type = .flagsChanged
    modifierRelease.flags = [.maskAlternate, .maskCommand]

    #expect(
      context.handle(type: .flagsChanged, event: modifierRelease)?
        .takeUnretainedValue() === modifierRelease
    )
  }

  @Test
  func `Bare command shortcut reaches the foreground application unchanged`() throws {
    let (context, invocations) = makeContext(
      bindings: [
        try Key(accelerator: "hyper-1", aliases: aliases): "workspace 1"
      ]
    )
    let event = try #require(
      CGEvent(keyboardEventSource: nil, virtualKey: 18, keyDown: true)
    )
    event.flags = [.maskCommand]

    let forwardedEvent = context.handle(type: .keyDown, event: event)

    #expect(forwardedEvent?.takeUnretainedValue() === event)
    #expect(event.flags == [.maskCommand])
    #expect(invocations.commands.isEmpty)
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

  @Test
  func `Unbound hyper shortcut is not downgraded to a command shortcut`() throws {
    let hyper = CGEventFlags([
      .maskAlternate,
      .maskCommand,
      .maskControl,
    ])
    let (context, invocations) = makeContext(
      bindings: [
        try Key(accelerator: "hyper-1", aliases: aliases): "workspace 1"
      ]
    )
    let event = try #require(
      CGEvent(keyboardEventSource: nil, virtualKey: 19, keyDown: true)
    )
    event.flags = hyper

    let forwardedEvent = context.handle(type: .keyDown, event: event)

    #expect(forwardedEvent?.takeUnretainedValue() === event)
    #expect(event.flags == hyper)
    #expect(invocations.commands.isEmpty)
  }
}

struct HotKeyModifierReleaseTests {
  private let hyper = hotKeyModifierBits([
    .maskAlternate,
    .maskCommand,
    .maskControl,
  ])

  @Test
  func capturedChordReleasesDoNotBecomeNewInput() {
    var state = CapturedHotKeyModifierReleaseState()
    state.capture(modifierBits: hyper)

    let recordsControlRelease = state.shouldRecord(
      flagsChangedTo: hotKeyModifierBits([.maskAlternate, .maskCommand])
    )
    let recordsCommandRelease = state.shouldRecord(
      flagsChangedTo: hotKeyModifierBits([.maskAlternate])
    )
    let recordsAlternateRelease = state.shouldRecord(flagsChangedTo: 0)

    #expect(recordsControlRelease == false)
    #expect(recordsCommandRelease == false)
    #expect(recordsAlternateRelease == false)
    #expect(state.heldModifierBits == 0)
  }

  @Test
  func newModifierPressAfterCaptureBecomesNewInput() {
    var state = CapturedHotKeyModifierReleaseState()
    state.capture(modifierBits: hyper)

    let hyperShift = hyper | hotKeyModifierBits([.maskShift])
    let recordsShiftPress = state.shouldRecord(flagsChangedTo: hyperShift)

    #expect(recordsShiftPress)
    #expect(state.heldModifierBits == 0)
  }

  @Test
  func repressAfterPartialReleaseBecomesNewInput() {
    var state = CapturedHotKeyModifierReleaseState()
    state.capture(modifierBits: hyper)
    let withoutControl = hotKeyModifierBits([.maskAlternate, .maskCommand])

    let recordsControlRelease = state.shouldRecord(
      flagsChangedTo: withoutControl
    )
    let recordsControlRepress = state.shouldRecord(flagsChangedTo: hyper)

    #expect(recordsControlRelease == false)
    #expect(recordsControlRepress)
    #expect(state.heldModifierBits == 0)
  }
}
