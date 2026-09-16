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
    guard let normalized = normalizedAccelerator(accelerator, aliases: aliases) else {
      throw HotKeyError.invalidAccelerator(accelerator)
    }
    var parts = normalized.split(separator: "-").map(String.init)
    guard let keyName = parts.popLast(), let code = acceleratorKeyCodes[keyName] else {
      throw HotKeyError.invalidAccelerator(accelerator)
    }
    var modifiers: CGEventFlags = []
    for name in parts {
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
}

func configuredHotKeys(_ config: Config) throws(HotKeyError) -> [Key: (accelerator: String, command: String)] {
  var bindings: [Key: (accelerator: String, command: String)] = [:]
  for (accelerator, command) in config.keys.sorted(by: { $0.key < $1.key }) {
    let key = try Key(accelerator: accelerator, aliases: config.modifierCombinations)
    bindings[key] = (accelerator, command)
  }
  return bindings
}
