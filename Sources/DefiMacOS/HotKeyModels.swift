import ApplicationServices
import DefiConfig
import DefiModel
import Foundation

public enum HotKeyError: Error, CustomStringConvertible, Equatable {
  case invalidAccelerator(String)
  case eventTapUnavailable

  public var description: String {
    switch self {
    case .invalidAccelerator(let value): "invalid accelerator: \(value)"
    case .eventTapUnavailable: "global hotkey event tap unavailable"
    }
  }
}

public struct HotKeyInvocation: Equatable, Sendable {
  public let command: String
  public let timestamp: TimeInterval

  public init(command: String, timestamp: TimeInterval) {
    self.command = command
    self.timestamp = timestamp
  }
}

public enum OverviewKeyAction: Equatable, Sendable {
  case left
  case right
  case up
  case down
  case moveUp
  case moveDown
  case select
  case cancel
}

func overviewKeyAction(
  keyCode: CGKeyCode,
  modifierBits: UInt64,
  configuredCommand: String? = nil
) -> OverviewKeyAction? {
  let commandName = configuredCommand?.split(whereSeparator: \.isWhitespace).first
  let navigatesOverview =
    modifierBits == 0
    || commandName == "focus-column"
    || commandName == "focus-window"
  return switch keyCode {
  case 125 where commandName == "move-window": .moveDown
  case 126 where commandName == "move-window": .moveUp
  case 123 where navigatesOverview: .left
  case 124 where navigatesOverview: .right
  case 125 where navigatesOverview: .down
  case 126 where navigatesOverview: .up
  case 36 where modifierBits == 0: .select
  case 76 where modifierBits == 0: .select
  case 53 where modifierBits == 0: .cancel
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
    var parts = accelerator.lowercased().split(separator: "-").map(String.init)
    guard let keyName = parts.popLast(), let code = Self.keyCodes[keyName] else {
      throw HotKeyError.invalidAccelerator(accelerator)
    }
    var modifierNames: [String] = []
    for part in parts {
      if let alias = aliases[part] {
        modifierNames.append(
          contentsOf:
            alias
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        )
      } else {
        modifierNames.append(part)
      }
    }
    var modifiers: CGEventFlags = []
    for name in modifierNames {
      switch name {
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
    self.code = code
    modifierBits = modifiers.rawValue
  }

  private static let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
    "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
    "equal": 24, "9": 25, "7": 26, "minus": 27, "8": 28, "0": 29,
    "rightbracket": 30, "o": 31, "u": 32, "leftbracket": 33,
    "i": 34, "p": 35, "l": 37, "j": 38, "quote": 39,
    "k": 40, "semicolon": 41, "backslash": 42, "comma": 43,
    "slash": 44, "n": 45, "m": 46, "period": 47,
    "left": 123, "right": 124, "down": 125, "up": 126,
  ]
}

func configuredHotKeys(_ config: Config) throws(HotKeyError) -> [Key: (accelerator: String, command: String)] {
  var bindings: [Key: (accelerator: String, command: String)] = [:]
  for (accelerator, command) in config.keys.sorted(by: { $0.key < $1.key }) {
    let key = try Key(accelerator: accelerator, aliases: config.modifierCombinations)
    bindings[key] = (accelerator, command)
  }
  return bindings
}
