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

@MainActor
public final class HotKeyManager {
  public typealias Handler = @MainActor @Sendable (HotKeyInvocation) -> Void
  public typealias PointerMotionHandler =
    @MainActor @Sendable (PointerMotionInvocation) -> Void
  public typealias TapReenabledHandler =
    @MainActor @Sendable (TimeInterval) -> Void

  private let bindings: [Key: String]
  private let handler: Handler
  public let tracksPointerMotion: Bool
  public let bindingError: HotKeyError?
  private let pointerMotionHandler: PointerMotionHandler?
  private let tapReenabledHandler: TapReenabledHandler
  private let userInputTracker: UserInputTracker
  private let pointerMotionTracker: PointerMotionTracker
  private var context: HotKeyTapContext?
  private var thread: Thread?

  public var bindingCount: Int { bindings.count }

  public var isHotKeyCaptureEnabled: Bool {
    bindingError == nil && isEnabled
  }

  public var isEnabled: Bool {
    context?.isEnabled ?? false
  }

  public var capturedKeyCount: Int {
    context?.capturedKeyCount ?? 0
  }

  public var tapReenableCount: Int {
    context?.tapReenableCount ?? 0
  }

  public var pointerTransitionCount: Int {
    context?.pointerTransitionCount ?? 0
  }

  public init(
    config: Config,
    userInputTracker: UserInputTracker = UserInputTracker(),
    pointerMotionTracker: PointerMotionTracker = PointerMotionTracker(),
    pointerMotionHandler: PointerMotionHandler? = nil,
    tapReenabledHandler: @escaping TapReenabledHandler = { _ in },
    handler: @escaping Handler
  ) {
    self.handler = handler
    tracksPointerMotion =
      config.input.focusFollowsMouse || config.input.mouseFollowsFocus
    self.pointerMotionHandler = config.input.focusFollowsMouse
      ? pointerMotionHandler
      : nil
    self.tapReenabledHandler = tapReenabledHandler
    self.userInputTracker = userInputTracker
    self.pointerMotionTracker = pointerMotionTracker
    var bindings: [Key: String] = [:]
    var bindingError: HotKeyError?
    do {
      for (accelerator, command) in config.keys {
        let key = try Key(
          accelerator: accelerator,
          aliases: config.modifierCombinations
        )
        bindings[key] = command
      }
    } catch let error {
      bindings.removeAll(keepingCapacity: false)
      bindingError = error
    }
    self.bindings = bindings
    self.bindingError = bindingError
  }

  public func start() throws {
    guard context == nil else { return }
    var mask = CGEventMask(
      (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.leftMouseDown.rawValue)
        | (1 << CGEventType.rightMouseDown.rawValue)
        | (1 << CGEventType.otherMouseDown.rawValue)
        | (1 << CGEventType.scrollWheel.rawValue)
    )
    mask |= CGEventMask(1 << CGEventType.flagsChanged.rawValue)
    if tracksPointerMotion {
      for eventType in [
        CGEventType.mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
      ] {
        mask |= CGEventMask(1 << eventType.rawValue)
      }
    }
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
    let pointerMotionHandler = self.pointerMotionHandler
    let tapReenabledHandler = self.tapReenabledHandler
    let context = HotKeyTapContext(
      bindings: bindings,
      userInputTracker: userInputTracker,
      pointerMotionTracker: pointerMotionTracker,
      tracksPointerWindowTransitions: pointerMotionHandler != nil
    ) { invocation in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          handler(invocation)
        }
      }
    } deliverPointerMotion: { invocation in
      MainActor.assumeIsolated {
        pointerMotionHandler?(invocation)
      }
    } tapReenabled: { timestamp in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          tapReenabledHandler(timestamp)
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

  public func resetPointerWindowTransition() {
    context?.resetPointerWindowTransition()
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
  private let pointerMotionTracker: PointerMotionTracker
  private let tracksPointerWindowTransitions: Bool
  private let deliver: @Sendable (HotKeyInvocation) -> Void
  private let deliverPointerMotion: @Sendable (PointerMotionInvocation) -> Void
  private let tapReenabled: @Sendable (TimeInterval) -> Void
  private let lock = NSLock()
  private let ready = DispatchSemaphore(value: 0)
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var runLoop: CFRunLoop?
  private var captured = 0
  private var reenables = 0
  private var pointerTransitions = 0
  private var pointerTransitionState = PointerWindowTransitionState()
  private var pendingPointerMotion: PointerMotionInvocation?
  private var pointerDeliveryScheduled = false
  private var pointerDeliveryGeneration: UInt64 = 0
  private var lastPointerDeliveryTimestamp: TimeInterval?
  private var capturedModifierReleaseState = CapturedHotKeyModifierReleaseState()

  init(
    bindings: [Key: String],
    userInputTracker: UserInputTracker,
    pointerMotionTracker: PointerMotionTracker,
    tracksPointerWindowTransitions: Bool,
    deliver: @escaping @Sendable (HotKeyInvocation) -> Void,
    deliverPointerMotion: @escaping @Sendable (PointerMotionInvocation) -> Void,
    tapReenabled: @escaping @Sendable (TimeInterval) -> Void
  ) {
    self.bindings = bindings
    self.userInputTracker = userInputTracker
    self.pointerMotionTracker = pointerMotionTracker
    self.tracksPointerWindowTransitions = tracksPointerWindowTransitions
    self.deliver = deliver
    self.deliverPointerMotion = deliverPointerMotion
    self.tapReenabled = tapReenabled
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
      let timestamp = Double(event.timestamp) / 1_000_000_000
      lock.lock()
      let tap = tap
      reenables += 1
      pointerTransitionState.reset()
      pendingPointerMotion = nil
      pointerDeliveryGeneration &+= 1
      pointerDeliveryScheduled = false
      lastPointerDeliveryTimestamp = nil
      capturedModifierReleaseState.reset()
      lock.unlock()
      userInputTracker.invalidate(at: timestamp)
      pointerMotionTracker.invalidate(at: timestamp)
      if let tap {
        CGEvent.tapEnable(tap: tap, enable: true)
      }
      tapReenabled(timestamp)
      return Unmanaged.passUnretained(event)
    }
    let timestamp = Double(event.timestamp) / 1_000_000_000
    if eventTracksPhysicalPointerMotion(type) {
      pointerMotionTracker.record(timestamp: timestamp)
      if type == .mouseMoved, tracksPointerWindowTransitions {
        let rawWindowID = event.getIntegerValueField(
          .mouseEventWindowUnderMousePointer
        )
        enqueuePointerMotionIfNeeded(
          PointerMotionInvocation(
            windowID: mouseFocusIntentWindowID(rawWindowID: rawWindowID),
            location: event.location,
            timestamp: timestamp
          ),
          rawWindowID: rawWindowID
        )
      }
      return Unmanaged.passUnretained(event)
    }
    let isKeyDown = type == .keyDown
    let tracksGeneralUserInput: Bool
    if type == .flagsChanged {
      tracksGeneralUserInput = capturedModifierReleaseState.shouldRecord(
        flagsChangedTo: hotKeyModifierBits(event.flags)
      )
    } else {
      tracksGeneralUserInput = eventTracksGeneralUserInput(type)
      if tracksGeneralUserInput {
        capturedModifierReleaseState.reset()
      }
    }
    if tracksGeneralUserInput {
      let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
      let commandPressed = event.flags.contains(.maskCommand)
      let focusIntent: UserInputTracker.FocusIntentSource?
      if eventIsMouseButtonDown(type) {
        let rawWindowID = event.getIntegerValueField(
          .mouseEventWindowUnderMousePointerThatCanHandleThisEvent
        )
        focusIntent = mouseFocusIntent(
          eventType: type,
          rawWindowID: rawWindowID
        )
      } else if commandPressed && code == Self.commandTabKeyCode {
        focusIntent = .keyboard
      } else {
        focusIntent = nil
      }
      userInputTracker.record(
        timestamp: timestamp,
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
    capturedModifierReleaseState.capture(modifierBits: key.modifierBits)
    deliver(HotKeyInvocation(command: command, timestamp: timestamp))
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

  var pointerTransitionCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return pointerTransitions
  }

  func resetPointerWindowTransition() {
    lock.lock()
    pointerTransitionState.reset()
    lock.unlock()
  }

  private func enqueuePointerMotionIfNeeded(
    _ invocation: PointerMotionInvocation,
    rawWindowID: Int64
  ) {
    lock.lock()
    let rawWindowChanged = pointerTransitionState.changed(to: rawWindowID)
    guard rawWindowID <= 0 || rawWindowChanged
    else {
      lock.unlock()
      return
    }
    pendingPointerMotion = invocation
    let schedulesDelivery = !pointerDeliveryScheduled
    let deliveryDelay = pointerMotionDeliveryDelay(
      rawWindowID: rawWindowID,
      eventTimestamp: invocation.timestamp,
      lastDeliveryTimestamp: lastPointerDeliveryTimestamp
    )
    pointerDeliveryScheduled = true
    let deliveryGeneration = pointerDeliveryGeneration
    lock.unlock()

    guard schedulesDelivery else { return }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + deliveryDelay
    ) { [weak self] in
      self?.flushPointerMotion(generation: deliveryGeneration)
    }
  }

  private func flushPointerMotion(generation: UInt64) {
    lock.lock()
    guard generation == pointerDeliveryGeneration else {
      lock.unlock()
      return
    }
    let invocation = pendingPointerMotion
    pendingPointerMotion = nil
    pointerDeliveryScheduled = false
    if let invocation {
      lastPointerDeliveryTimestamp = invocation.timestamp
      pointerTransitions += 1
    }
    lock.unlock()

    if let invocation {
      deliverPointerMotion(invocation)
    }
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
