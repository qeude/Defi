import ApplicationServices
import DefiConfig
import DefiModel
import Foundation

public enum HotKeyError: Error, CustomStringConvertible {
  case invalidAccelerator(String)
  case eventTapUnavailable

  public var description: String {
    switch self {
    case .invalidAccelerator(let value): "invalid accelerator: \(value)"
    case .eventTapUnavailable: "global hotkey event tap unavailable"
    }
  }
}

@MainActor
public final class HotKeyManager {
  public typealias Handler = @MainActor @Sendable (String) -> Void

  private let bindings: [Key: String]
  private let handler: Handler
  private let userInputTracker: UserInputTracker
  private var context: HotKeyTapContext?
  private var thread: Thread?

  public var bindingCount: Int { bindings.count }

  public var isEnabled: Bool {
    context?.isEnabled ?? false
  }

  public var capturedKeyCount: Int {
    context?.capturedKeyCount ?? 0
  }

  public var tapReenableCount: Int {
    context?.tapReenableCount ?? 0
  }

  public init(
    config: Config,
    userInputTracker: UserInputTracker = UserInputTracker(),
    handler: @escaping Handler
  ) throws {
    self.handler = handler
    self.userInputTracker = userInputTracker
    var bindings: [Key: String] = [:]
    for (accelerator, command) in config.keys {
      let key = try Key(
        accelerator: accelerator,
        aliases: config.modifierCombinations
      )
      bindings[key] = command
    }
    self.bindings = bindings
  }

  public func start() throws {
    guard context == nil else { return }
    let mask = CGEventMask(
      (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.leftMouseDown.rawValue)
    )
    let callback: CGEventTapCallBack = { _, type, event, userInfo in
      guard let userInfo else {
        return Unmanaged.passUnretained(event)
      }
      let context = Unmanaged<HotKeyTapContext>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
      return context.handle(type: type, event: event)
    }
    let handler = self.handler
    let context = HotKeyTapContext(
      bindings: bindings,
      userInputTracker: userInputTracker
    ) { command in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          handler(command)
        }
      }
    }
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: callback,
        userInfo: Unmanaged.passUnretained(context).toOpaque()
      )
    else {
      throw HotKeyError.eventTapUnavailable
    }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    else {
      CGEvent.tapEnable(tap: tap, enable: false)
      throw HotKeyError.eventTapUnavailable
    }
    context.install(tap: tap, source: source)
    let thread = Thread { context.run() }
    thread.name = "com.quentin.defi.hotkeys"
    thread.qualityOfService = .userInteractive
    self.context = context
    self.thread = thread
    thread.start()
    guard context.waitUntilReady() else {
      context.stop()
      self.context = nil
      self.thread = nil
      throw HotKeyError.eventTapUnavailable
    }
  }

  isolated deinit {
    context?.stop()
  }
}

private final class HotKeyTapContext: @unchecked Sendable {
  private static let commandTabKeyCode = CGKeyCode(48)
  private static let closeWindowKeyCodes: Set<CGKeyCode> = [12, 13]

  private let bindings: [Key: String]
  private let userInputTracker: UserInputTracker
  private let deliver: @Sendable (String) -> Void
  private let lock = NSLock()
  private let ready = DispatchSemaphore(value: 0)
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var runLoop: CFRunLoop?
  private var captured = 0
  private var reenables = 0

  init(
    bindings: [Key: String],
    userInputTracker: UserInputTracker,
    deliver: @escaping @Sendable (String) -> Void
  ) {
    self.bindings = bindings
    self.userInputTracker = userInputTracker
    self.deliver = deliver
  }

  func install(tap: CFMachPort, source: CFRunLoopSource) {
    lock.lock()
    self.tap = tap
    self.source = source
    lock.unlock()
  }

  func run() {
    lock.lock()
    let tap = tap
    let source = source
    let runLoop = CFRunLoopGetCurrent()
    self.runLoop = runLoop
    lock.unlock()
    guard let tap, let source else {
      ready.signal()
      return
    }
    CFRunLoopAddSource(runLoop, source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    ready.signal()
    CFRunLoopRun()
  }

  func waitUntilReady() -> Bool {
    ready.wait(timeout: .now() + 1) == .success && isEnabled
  }

  func handle(
    type: CGEventType,
    event: CGEvent
  ) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      lock.lock()
      let tap = tap
      reenables += 1
      lock.unlock()
      if let tap {
        CGEvent.tapEnable(tap: tap, enable: true)
      }
      return Unmanaged.passUnretained(event)
    }
    let isKeyDown = type == .keyDown
    if isKeyDown || type == .leftMouseDown {
      let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
      let commandPressed = event.flags.contains(.maskCommand)
      let focusIntent: UserInputTracker.FocusIntentSource?
      if type == .leftMouseDown {
        let rawWindowID = event.getIntegerValueField(
          .mouseEventWindowUnderMousePointerThatCanHandleThisEvent
        )
        focusIntent = .mouse(
          windowID: mouseFocusIntentWindowID(rawWindowID: rawWindowID)
        )
      } else if commandPressed && code == Self.commandTabKeyCode {
        focusIntent = .keyboard
      } else {
        focusIntent = nil
      }
      userInputTracker.record(
        timestamp: Double(event.timestamp) / 1_000_000_000,
        focusIntent: focusIntent,
        closeIntent: isKeyDown && commandPressed
          && Self.closeWindowKeyCodes.contains(code)
      )
    }
    guard isKeyDown else {
      return Unmanaged.passUnretained(event)
    }
    let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let key = Key(code: code, flags: event.flags.rawValue)
    guard let command = bindings[key] else {
      return Unmanaged.passUnretained(event)
    }
    lock.lock()
    captured += 1
    lock.unlock()
    deliver(command)
    return nil
  }

  var isEnabled: Bool {
    lock.lock()
    let tap = tap
    lock.unlock()
    return tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
  }

  var capturedKeyCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return captured
  }

  var tapReenableCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return reenables
  }

  func stop() {
    lock.lock()
    let tap = tap
    let source = source
    let runLoop = runLoop
    lock.unlock()
    guard let runLoop else {
      if let tap {
        CGEvent.tapEnable(tap: tap, enable: false)
      }
      return
    }
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
      if let source {
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
      }
      if let tap {
        CGEvent.tapEnable(tap: tap, enable: false)
      }
      CFRunLoopStop(runLoop)
    }
    CFRunLoopWakeUp(runLoop)
  }
}

struct Key: Hashable, Sendable {
  let code: CGKeyCode
  let modifierBits: UInt64

  init(code: CGKeyCode, flags: UInt64) {
    self.code = code
    modifierBits = flags & Self.modifierMask.rawValue
  }

  init(accelerator: String, aliases: [String: String]) throws {
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

  private static let modifierMask: CGEventFlags = [
    .maskCommand,
    .maskAlternate,
    .maskControl,
    .maskShift,
  ]

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
