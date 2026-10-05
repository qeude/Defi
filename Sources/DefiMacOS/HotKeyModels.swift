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
