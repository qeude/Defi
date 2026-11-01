import ApplicationServices
import DefiConfig
import DefiModel
import Foundation
import Synchronization

let settingsTextInputFocused = Mutex(false)

func hotKeyTargetIsCurrentApplication(
  _ targetPID: pid_t?, currentPID: pid_t, recordingShortcut: Bool = false
) -> Bool {
  recordingShortcut || targetPID == currentPID
}

public enum HotKeyError: Error, CustomStringConvertible, Equatable {
  case invalidAccelerator(String)
  case eventTapUnavailable
  case registrationFailed(keyCode: CGKeyCode?, status: Int32)

  public var description: String {
    switch self {
    case .invalidAccelerator(let value): "invalid accelerator: \(value)"
    case .eventTapUnavailable: "global input event tap unavailable"
    case .registrationFailed(let keyCode, let status):
      "global hotkey registration failed\(keyCode.map { " for key code \($0)" } ?? ""): OSStatus \(status)"
    }
  }
}

public struct HotKeyInvocation: Equatable, Sendable {
  public let command: String
  public let timestamp: TimeInterval
  public let sourceProcessID: Int32?

  public init(command: String, timestamp: TimeInterval, sourceProcessID: Int32? = nil) {
    self.command = command
    self.timestamp = timestamp
    self.sourceProcessID = sourceProcessID
  }
}

public enum OverviewKeyAction: Equatable, Sendable {
  case left
  case right
  case up
  case down
  case firstColumn
  case lastColumn
  case workspaceUp
  case workspaceDown
  case workspace(WorkspaceTarget)
  case monitor(Direction)
  case moveToMonitor(Direction)
  case moveUp
  case moveDown
  case select
  case cancel
  case layout(Command)
}

func overviewKeyAction(
  keyCode: CGKeyCode,
  modifierBits: UInt64,
  configuredCommand: String? = nil
) -> OverviewKeyAction? {
  let parts = configuredCommand?.split(whereSeparator: \.isWhitespace) ?? []
  let commandName = parts.first
  if commandName == "move-window", keyCode == 125 { return .moveDown }
  if commandName == "move-window", keyCode == 126 { return .moveUp }
  if let configuredCommand, let command = try? parseCommand(configuredCommand) {
    switch command {
    case .switchWorkspace(let id): return .workspace(.named(id.rawValue))
    case .focusWorkspace(let target):
      switch target {
      case .relative(.up): return .workspaceUp
      case .relative(.down): return .workspaceDown
      default: return .workspace(target)
      }
    case .focusMonitor(let direction): return .monitor(direction)
    // shortcut: the overview moves the selected window alone, even for move-column-to-monitor;
    // move whole columns once overview drops can carry a column.
    case .moveColumnToMonitor(let direction), .moveWindowToMonitor(let direction):
      return .moveToMonitor(direction)
    default:
      if command.editsSelectedLayout { return .layout(command) }
    }
  }
  if parts.count == 2 {
    switch (parts[0], parts[1]) {
    case ("focus-column", "first"): return .firstColumn
    case ("focus-column", "last"): return .lastColumn
    default: break
    }
  }
  let navigatesOverview =
    modifierBits == 0
    || commandName == "focus-column"
    || commandName == "focus-window"
    || commandName == "focus-window-or-workspace"
  return switch keyCode {
  case 123 where navigatesOverview: .left
  case 124 where navigatesOverview: .right
  case 125 where navigatesOverview: .down
  case 126 where navigatesOverview: .up
  case 36 where modifierBits == 0: .select
  case 76 where modifierBits == 0: .select
  case 53 where modifierBits == 0: .cancel
  case _ where commandName == "toggle-overview": .cancel
  default: nil
  }
}

public struct PointerMotionInvocation: Equatable, Sendable {
  public let windowID: WindowID?
  public let location: CGPoint
  public let timestamp: TimeInterval

  public init(
    windowID: WindowID?,
    location: CGPoint = .zero,
    timestamp: TimeInterval
  ) {
    self.windowID = windowID
    self.location = location
    self.timestamp = timestamp
  }
}

private let hotKeyModifierMask: CGEventFlags = [
  .maskCommand,
  .maskAlternate,
  .maskControl,
  .maskShift,
]

func hotKeyModifierBits(_ flags: CGEventFlags) -> UInt64 {
  flags.rawValue & hotKeyModifierMask.rawValue
}

struct CapturedHotKeyModifierReleaseState: Equatable, Sendable {
  private(set) var heldModifierBits: UInt64 = 0

  mutating func capture(modifierBits: UInt64) {
    heldModifierBits = modifierBits
  }

  mutating func shouldRecord(flagsChangedTo currentModifierBits: UInt64) -> Bool {
    guard heldModifierBits != 0 else { return true }
    let newlyPressed = currentModifierBits & ~heldModifierBits
    let released = heldModifierBits & ~currentModifierBits
    guard newlyPressed == 0, released != 0 else {
      heldModifierBits = 0
      return true
    }
    heldModifierBits = currentModifierBits
    return false
  }

  mutating func reset() {
    heldModifierBits = 0
  }
}

struct Key: Hashable, Sendable {
  let code: CGKeyCode
  let modifierBits: UInt64

  init(code: CGKeyCode, flags: UInt64) {
    self.code = code
    modifierBits = hotKeyModifierBits(CGEventFlags(rawValue: flags))
  }

  init(
    accelerator: String,
    aliases: [String: String]
  ) throws(HotKeyError) {
    let (modifiers, name) = try parseAccelerator(accelerator, aliases: aliases)
    guard let code = acceleratorKeyCodes[name] else {
      throw HotKeyError.invalidAccelerator(accelerator)
    }
    self.code = code
    modifierBits = modifiers.rawValue
  }
}

func parseAccelerator(
  _ accelerator: String, aliases: [String: String]
) throws(HotKeyError) -> (modifiers: CGEventFlags, name: String) {
  guard let normalized = normalizedAccelerator(accelerator, aliases: aliases) else {
    throw HotKeyError.invalidAccelerator(accelerator)
  }
  var parts = normalized.split(separator: "-").map(String.init)
  guard let name = parts.popLast() else { throw HotKeyError.invalidAccelerator(accelerator) }
  var modifiers: CGEventFlags = []
  for part in parts {
    switch part {
    case "cmd", "command":
      modifiers.insert(.maskCommand)
    case "alt", "option":
      modifiers.insert(.maskAlternate)
    case "ctrl", "control":
      modifiers.insert(.maskControl)
    case "shift":
      modifiers.insert(.maskShift)
    default:
      throw HotKeyError.invalidAccelerator(accelerator)
    }
  }
  return (modifiers, name)
}

/// Modifiers that change which character a key prints. Command is chosen by the binding, never added.
struct KeyboardLayer: OptionSet, Hashable, Sendable {
  let rawValue: Int
  static let shift = KeyboardLayer(rawValue: 1)
  static let option = KeyboardLayer(rawValue: 2)
  static let command = KeyboardLayer(rawValue: 4)
}

/// Main-block typing keys, including the two JIS-only ones. Excludes the keypad, Return, Tab and Space.
let layoutScannedKeyCodes: [UInt16] = Array(0...47).filter { $0 != 36 } + [50, 93, 94]

/// What each key prints on one layout, lowercased and without dead keys. A key that prints
/// nothing printable has no entry.
struct KeyboardLayout: Equatable, Sendable {
  let characters: [KeyboardLayer: [UInt16: String]]

  /// Base, Shift, Option, then Option-Shift; the lowest scanned key code within a layer.
  func position(of character: String, command: Bool) -> (code: UInt16, layer: KeyboardLayer)? {
    for layer: KeyboardLayer in [[], .shift, .option, [.shift, .option]] {
      let layer = command ? layer.union(.command) : layer
      if let code = layoutScannedKeyCodes.first(where: { characters[layer]?[$0] == character }) {
        return (code, layer)
      }
    }
    return nil
  }

  func baseCharacter(code: UInt16, command: Bool) -> String? {
    characters[command ? .command : []]?[code]
  }
}

enum HotKeyInactivity: Equatable, Sendable {
  case absentFromLayout
  case held(by: String)
  /// Registered elsewhere, so Carbon refused the chord.
  case heldByAnotherApp
}

struct HotKeyResolution {
  var keys: [Key: (accelerator: String, command: String)] = [:]
  /// Bindings that hold no chord, by accelerator as configured.
  var inactive: [String: HotKeyInactivity] = [:]
}

/// Each binding offers chords in rank order; sorted by rank, then accelerator, the first free one wins.
/// 0 digits and arrows, always physical. 1 the character on the base layer. 2 the character
/// on Shift or Option, with that modifier added. 3 the physical key. 4 the lowest free key, so a
/// table name always holds a chord. Literal names (`é`) use ranks 1 and 2 only. A nil layout is physical.
func resolveHotKeys(
  _ bindings: [String: String], aliases: [String: String], layout: KeyboardLayout?
) throws(HotKeyError) -> HotKeyResolution {
  struct Claim {
    let rank: Int
    let accelerator: String
    let command: String
    let modifiers: CGEventFlags
    let code: UInt16?
  }
  var claims: [Claim] = []
  for (accelerator, command) in bindings {
    let (modifiers, name) = try parseAccelerator(accelerator, aliases: aliases)
    func claim(_ rank: Int, _ modifiers: CGEventFlags, _ code: UInt16?) {
      claims.append(Claim(rank: rank, accelerator: accelerator, command: command, modifiers: modifiers, code: code))
    }
    let physical = acceleratorKeyCodes[name]
    // Digits and arrows (codes from 123) never follow the layout.
    if let physical, layout == nil || Int(name) != nil || physical >= 123 {
      claim(0, modifiers, physical)
      continue
    }
    guard let layout else { continue }
    let isLetter = physical != nil && acceleratorSymbolCharacters[name] == nil
    let character = acceleratorSymbolCharacters[name] ?? name
    if let hit = layout.position(of: character, command: modifiers.contains(.maskCommand)) {
      var added: CGEventFlags = []
      if hit.layer.contains(.shift) { added.insert(.maskShift) }
      if hit.layer.contains(.option) { added.insert(.maskAlternate) }
      if added.isEmpty {
        claim(1, modifiers, hit.code)
      } else if !isLetter {
        claim(2, modifiers.union(added), hit.code)
      }
    }
    if let physical {
      claim(3, modifiers, physical)
      claim(4, modifiers, nil)
    }
  }
  var result = HotKeyResolution()
  var placed = Set<String>()
  var blockers: [String: String] = [:]
  for claim in claims.sorted(by: { ($0.rank, $0.accelerator) < ($1.rank, $1.accelerator) })
  where !placed.contains(claim.accelerator) {
    func key(_ code: UInt16) -> Key { Key(code: code, flags: claim.modifiers.rawValue) }
    guard let code = claim.code ?? layoutScannedKeyCodes.first(where: { result.keys[key($0)] == nil }) else { continue }
    if let holder = result.keys[key(code)] {
      blockers[claim.accelerator] = holder.accelerator
    } else {
      result.keys[key(code)] = (claim.accelerator, claim.command)
      placed.insert(claim.accelerator)
    }
  }
  for accelerator in bindings.keys where !placed.contains(accelerator) {
    result.inactive[accelerator] = blockers[accelerator].map { .held(by: $0) } ?? .absentFromLayout
  }
  return result
}

func configuredHotKeys(
  _ config: Config, layout: KeyboardLayout? = nil
) throws(HotKeyError) -> [Key: (accelerator: String, command: String)] {
  try resolveHotKeys(config.keys, aliases: config.modifierCombinations, layout: layout).keys
}

extension Key {
  var modifierNames: Set<String> {
    let flags = CGEventFlags(rawValue: modifierBits)
    return Set(
      [("ctrl", CGEventFlags.maskControl), ("alt", .maskAlternate), ("shift", .maskShift), ("cmd", .maskCommand)]
        .filter { flags.contains($0.1) }.map(\.0))
  }
}

func canonicalKeyName(_ character: String) -> String {
  acceleratorSymbolCharacters.first { $0.value == character }?.key ?? character
}

/// What labels and conflict checks need: the chord each accelerator holds on one layout, or why it holds none.
struct ShortcutResolution {
  let layout: KeyboardLayout?
  let aliases: [String: String]
  let resolution: HotKeyResolution
  private let chords: [String: Key]
  private let reasons: [String: HotKeyInactivity]

  init(
    bindings: [String: String], aliases: [String: String], layout: KeyboardLayout?,
    heldByAnotherApp: Set<String> = []
  ) {
    self.layout = layout
    self.aliases = aliases
    var resolution = (try? resolveHotKeys(bindings, aliases: aliases, layout: layout)) ?? HotKeyResolution()
    for (key, binding) in resolution.keys where heldByAnotherApp.contains(binding.accelerator) {
      resolution.keys[key] = nil
      resolution.inactive[binding.accelerator] = .heldByAnotherApp
    }
    self.resolution = resolution
    chords = Dictionary(
      resolution.keys.compactMap { key, binding in
        normalizedAccelerator(binding.accelerator, aliases: aliases).map { ($0, key) }
      }, uniquingKeysWith: { first, _ in first })
    reasons = Dictionary(
      resolution.inactive.compactMap { accelerator, reason in
        normalizedAccelerator(accelerator, aliases: aliases).map { ($0, reason) }
      }, uniquingKeysWith: { first, _ in first })
  }

  init(config: Config, layout: KeyboardLayout?, heldByAnotherApp: Set<String> = []) {
    self.init(
      bindings: config.keys, aliases: config.modifierCombinations, layout: layout,
      heldByAnotherApp: heldByAnotherApp)
  }

  func key(for normalizedAccelerator: String) -> Key? { chords[normalizedAccelerator] }
  func inactivity(for normalizedAccelerator: String) -> HotKeyInactivity? { reasons[normalizedAccelerator] }

  /// Digits and arrows keep their name; any other key is named for the keycap at its resolved code.
  func keyName(for key: Key, named name: String) -> String {
    guard let layout, Int(name) == nil, (acceleratorKeyCodes[name] ?? 0) < 123,
      let character = layout.baseCharacter(code: key.code, command: key.modifierNames.contains("cmd"))
    else { return name }
    return canonicalKeyName(character)
  }
}
