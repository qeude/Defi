import ApplicationServices
import DefiConfig
import Testing
@testable import DefiMacOS

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
  private let aliases = [
    "hyper": "Alt + Cmd + Ctrl"
  ]

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
