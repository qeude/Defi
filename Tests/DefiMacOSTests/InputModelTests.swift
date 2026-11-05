import CoreGraphics
import DefiConfig
import DefiModel
import Foundation
import Synchronization
import Testing

@testable import DefiMacOS

/// Model-based check of keyboard and pointer intake: random event sequences go through the real
/// InputMonitor taps (the active `intercept` tap, then the listen-only `handle` tap, as macOS
/// chains them), and every delivery is compared with the rules below. The rules come from
/// AGENTS.md (keyboard capture and command intake stay responsive; each bound key gives its
/// command) and CONFIGURATION.md (bindings, the cheatsheet, the Overview keys).
///
/// - a bound key down gives exactly its command, once per press, and an autorepeat repeats
///   it, except `toggle-cheatsheet`, which toggles once per press;
/// - nothing is delivered while another app captures the keyboard, or for keys typed into a
///   focused Defi text field, which reach the field unchanged;
/// - Escape while the cheatsheet shows dismisses it and goes no further;
/// - with the Overview open, its keys drive the Overview instead of commands, and Command-Tab
///   closes it and still reaches macOS;
/// - the cheatsheet sees every key down and modifier change outside Defi's text fields, and a
///   click dismisses it;
/// - a delivered command or Overview key is recorded as captured input at its timestamp.
struct InputModelTests {
  private static let modifiers: CGEventFlags = [.maskControl, .maskAlternate]
  private static let keys: [(code: CGKeyCode, command: String)] = [
    (123, "focus-column left"), (124, "focus-column right"), (126, "focus-workspace up"),
    (44, "toggle-cheatsheet"), (31, "toggle-overview"),
  ]

  private struct State {
    var overview = false
    var cheatsheet = false
    var captured = false
    var textFocused = false
  }

  private enum Event {
    case key(code: CGKeyCode, flags: CGEventFlags, autorepeat: Bool, targetsDefi: Bool)
    case flags(CGEventFlags)
    case click
    case setOverview(Bool), setCheatsheet(Bool), setCaptured(Bool), setTextFocused(Bool)
  }

  private struct Expected: Equatable {
    var commands: [String] = []
    var overview: [OverviewKeyAction] = []
    var cheatsheet: [CheatsheetInput] = []
    var reachesMacOS = true
    var capturedAt: TimeInterval?
  }

  private static func expected(_ event: Event, _ state: State, timestamp: TimeInterval,
    bindings: [Key: String]) -> Expected {
    var out = Expected()
    let cheatsheetBits = hotKeyModifierBits(modifiers)
    switch event {
    case .key(let code, let flags, let autorepeat, let targetsDefi):
      let key = Key(code: code, flags: flags.rawValue)
      if targetsDefi && state.textFocused { return out }
      if state.cheatsheet && code == 53 {
        out.cheatsheet = [.dismiss]
        out.reachesMacOS = false
        return out
      }
      if state.overview, let action = overviewKeyAction(
        keyCode: code, modifierBits: key.modifierBits, configuredCommand: bindings[key]) {
        out.overview = [action]
        out.reachesMacOS = false
        out.capturedAt = timestamp
        return out
      }
      out.cheatsheet = [.keyDown(modifiersHeld: hotKeyModifierBits(flags) != 0)]
      if state.overview, flags.contains(.maskCommand), code == 48 {
        out.overview = [.cancel]
        return out
      }
      guard let command = bindings[key], !state.captured else { return out }
      if command == "toggle-cheatsheet", autorepeat { return out }
      out.commands = [command]
      out.capturedAt = timestamp
    case .flags(let flags):
      let bits = hotKeyModifierBits(flags)
      out.cheatsheet = [.modifiersChanged(
        matches: bits != 0 && bits == cheatsheetBits && !state.captured, released: bits == 0)]
    case .click:
      out.cheatsheet = [.dismiss]
    case .setOverview, .setCheatsheet, .setCaptured, .setTextFocused:
      break
    }
    return out
  }

  private static func randomEvent(_ random: inout UInt64) -> Event {
    func next(_ bound: Int) -> Int {
      random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((random >> 33) % UInt64(bound))
    }
    let flagChoices: [CGEventFlags] = [modifiers, [], [.maskCommand], modifiers.union(.maskShift)]
    switch next(20) {
    case 0..<11:
      let codes = keys.map(\.code) + [53, 48, 0, 125]
      return .key(code: codes[next(codes.count)], flags: flagChoices[next(flagChoices.count)],
        autorepeat: next(4) == 0, targetsDefi: next(5) == 0)
    case 11..<14: return .flags(flagChoices[next(flagChoices.count)])
    case 14: return .click
    case 15, 16: return .setOverview(next(2) == 0)
    case 17: return .setCheatsheet(next(2) == 0)
    case 18: return .setCaptured(next(3) == 0)
    default: return .setTextFocused(next(2) == 0)
    }
  }

  @Test(arguments: 1...40)
  func inputIntakeFollowsItsRules(seed: Int) throws {
    let bindings = Dictionary(uniqueKeysWithValues: Self.keys.map {
      (Key(code: $0.code, flags: Self.modifiers.rawValue), $0.command)
    })
    let commands = Mutex<[String]>([]), overview = Mutex<[OverviewKeyAction]>([])
    let cheatsheet = Mutex<[CheatsheetInput]>([])
    let state = Mutex(State())
    let tracker = UserInputTracker()
    let monitor = InputMonitor(
      bindings: bindings, userInputTracker: tracker, pointerMotionTracker: PointerMotionTracker(),
      tracksPointerWindowTransitions: false,
      cheatsheetModifierBits: hotKeyModifierBits(Self.modifiers),
      deliverCheatsheet: { input in cheatsheet.withLock { $0.append(input) } },
      deliver: { invocation in commands.withLock { $0.append(invocation.command) } },
      deliverOverview: { action in overview.withLock { $0.append(action) } },
      deliverPointerMotion: { _ in }, tapReenabled: { _ in },
      textInputFocused: { state.withLock { $0.textFocused } },
      keyboardCaptured: { state.withLock { $0.captured } }
    )
    monitor.setHotKeysRegistered(true)
    var random = UInt64(seed)
    for index in 0..<80 {
      let event = Self.randomEvent(&random)
      let timestamp = TimeInterval(index + 1)
      let before = state.withLock { $0 }
      let expected = Self.expected(event, before, timestamp: timestamp, bindings: bindings)
      commands.withLock { $0.removeAll() }
      overview.withLock { $0.removeAll() }
      cheatsheet.withLock { $0.removeAll() }
      var reachesMacOS = true
      switch event {
      case .setOverview(let on):
        state.withLock { $0.overview = on }
        monitor.setOverviewModeEnabled(on)
        continue
      case .setCheatsheet(let on):
        state.withLock { $0.cheatsheet = on }
        monitor.setCheatsheetVisible(on)
        continue
      case .setCaptured(let on):
        state.withLock { $0.captured = on }
        continue
      case .setTextFocused(let on):
        state.withLock { $0.textFocused = on }
        continue
      case .key(let code, let flags, let autorepeat, let targetsDefi):
        let cgEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
        cgEvent.flags = flags
        cgEvent.timestamp = UInt64(timestamp * 1_000_000_000)
        cgEvent.setIntegerValueField(.keyboardEventAutorepeat, value: autorepeat ? 1 : 0)
        cgEvent.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(targetsDefi ? getpid() : 4_242))
        if monitor.intercept(type: .keyDown, event: cgEvent) == nil {
          reachesMacOS = false
        } else {
          reachesMacOS = monitor.handle(type: .keyDown, event: cgEvent) != nil
        }
      case .flags(let flags):
        let cgEvent = try #require(CGEvent(source: nil))
        cgEvent.type = .flagsChanged
        cgEvent.flags = flags
        cgEvent.timestamp = UInt64(timestamp * 1_000_000_000)
        cgEvent.setIntegerValueField(.eventTargetUnixProcessID, value: 4_242)
        reachesMacOS = monitor.handle(type: .flagsChanged, event: cgEvent) != nil
      case .click:
        let cgEvent = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
          mouseCursorPosition: .zero, mouseButton: .left))
        cgEvent.timestamp = UInt64(timestamp * 1_000_000_000)
        reachesMacOS = monitor.handle(type: .leftMouseDown, event: cgEvent) != nil
      }
      let actual = Expected(
        commands: commands.withLock { $0 }, overview: overview.withLock { $0 },
        cheatsheet: cheatsheet.withLock { $0 }, reachesMacOS: reachesMacOS,
        capturedAt: expected.capturedAt == nil ? nil : tracker.snapshot.latestCapturedCommandTimestamp
      )
      #expect(actual == expected, "seed \(seed) event \(index): \(event) with \(before)")
      if actual != expected { return }
    }
  }
}
