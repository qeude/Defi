import ApplicationServices
import DefiConfig
import DefiModel
import Foundation

let hotKeyEventTapPlacement = CGEventTapPlacement.tailAppendEventTap

@MainActor
public final class HotKeyManager {
  public typealias Handler = @MainActor @Sendable (HotKeyInvocation) -> Void
  public typealias PointerMotionHandler =
    @MainActor @Sendable (PointerMotionInvocation) -> Void
  public typealias TapReenabledHandler =
    @MainActor @Sendable (TimeInterval) -> Void
  public typealias CloseIntentHandler =
    @MainActor @Sendable (TimeInterval, pid_t?) -> Void
  public typealias OverviewHandler =
    @MainActor @Sendable (OverviewKeyAction) -> Void

  private let bindings: [Key: String]
  private let handler: Handler
  public let tracksPointerMotion: Bool
  public let bindingError: HotKeyError?
  private let pointerMotionHandler: PointerMotionHandler?
  private let tapReenabledHandler: TapReenabledHandler
  private let closeIntentHandler: CloseIntentHandler
  private let overviewHandler: OverviewHandler
  private let cheatsheetHandler: @MainActor @Sendable (CheatsheetInput) -> Void
  private let cheatsheetModifierBits: UInt64?
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
    closeIntentHandler: @escaping CloseIntentHandler = { _, _ in },
    overviewHandler: @escaping OverviewHandler = { _ in },
    cheatsheetHandler: @escaping @MainActor @Sendable (CheatsheetInput) -> Void = { _ in },
    handler: @escaping Handler
  ) {
    self.handler = handler
    tracksPointerMotion =
      config.input.focusFollowsMouse || config.input.mouseFollowsFocus
    self.pointerMotionHandler = config.input.focusFollowsMouse
      ? pointerMotionHandler
      : nil
    self.tapReenabledHandler = tapReenabledHandler
    self.closeIntentHandler = closeIntentHandler
    self.overviewHandler = overviewHandler
    self.cheatsheetHandler = cheatsheetHandler
    cheatsheetModifierBits = try? Key(
      accelerator: "\(config.defaultKeyModifier)-a",
      aliases: config.modifierCombinations
    ).modifierBits
    self.userInputTracker = userInputTracker
    self.pointerMotionTracker = pointerMotionTracker
    var bindings: [Key: String] = [:]
    var bindingError: HotKeyError?
    do {
      bindings = try configuredHotKeys(config).mapValues(\.command)
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
    let closeIntentHandler = self.closeIntentHandler
    let overviewHandler = self.overviewHandler
    let cheatsheetHandler = self.cheatsheetHandler
    let context = HotKeyTapContext(
      bindings: bindings,
      userInputTracker: userInputTracker,
      pointerMotionTracker: pointerMotionTracker,
      tracksPointerWindowTransitions: pointerMotionHandler != nil,
      cheatsheetModifierBits: bindingError == nil ? cheatsheetModifierBits : nil,
      deliverCheatsheet: { input in
        DispatchQueue.main.async {
          MainActor.assumeIsolated { cheatsheetHandler(input) }
        }
      }
    ) { invocation in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          handler(invocation)
        }
      }
    } deliverOverview: { action in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          overviewHandler(action)
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
    } closeIntent: { timestamp, processID in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          closeIntentHandler(timestamp, processID)
        }
      }
    }
    let callbackContext = Unmanaged.passRetained(context)
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: hotKeyEventTapPlacement,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: callback,
        userInfo: callbackContext.toOpaque()
      )
    else {
      callbackContext.release()
      throw HotKeyError.eventTapUnavailable
    }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    else {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
      callbackContext.release()
      throw HotKeyError.eventTapUnavailable
    }
    context.install(
      tap: tap,
      source: source,
      callbackContext: callbackContext
    )
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

  public func setOverviewModeEnabled(_ enabled: Bool) {
    context?.setOverviewModeEnabled(enabled)
  }

  public func setCheatsheetVisible(_ visible: Bool) {
    context?.setCheatsheetVisible(visible)
  }

  public func stop() {
    context?.stop()
    context = nil
    thread = nil
  }

  isolated deinit {
    context?.stop()
  }
}

final class HotKeyTapContext: @unchecked Sendable {
  private static let commandTabKeyCode = CGKeyCode(48)
  private static let closeWindowKeyCodes: Set<CGKeyCode> = [12, 13]

  private let bindings: [Key: String]
  private let userInputTracker: UserInputTracker
  private let pointerMotionTracker: PointerMotionTracker
  private let tracksPointerWindowTransitions: Bool
  private let deliver: @Sendable (HotKeyInvocation) -> Void
  private let deliverOverview: @Sendable (OverviewKeyAction) -> Void
  private let deliverPointerMotion: @Sendable (PointerMotionInvocation) -> Void
  private let tapReenabled: @Sendable (TimeInterval) -> Void
  private let closeIntent: @Sendable (TimeInterval, pid_t?) -> Void
  private let lock = NSLock()
  private let ready = DispatchSemaphore(value: 0)
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var runLoop: CFRunLoop?
  private var callbackContext: Unmanaged<HotKeyTapContext>?
  private var captured = 0
  private var reenables = 0
  private var pointerTransitions = 0
  private var pointerTransitionState = PointerWindowTransitionState()
  private var pendingPointerMotion: PointerMotionInvocation?
  private var pointerDeliveryScheduled = false
  private var pointerDeliveryGeneration: UInt64 = 0
  private var lastPointerDeliveryTimestamp: TimeInterval?
  private var capturedModifierReleaseState = CapturedHotKeyModifierReleaseState()
  private var overviewModeEnabled = false
  private var cheatsheetVisible = false
  private let cheatsheetModifierBits: UInt64?
  private let deliverCheatsheet: @Sendable (CheatsheetInput) -> Void

  init(
    bindings: [Key: String],
    userInputTracker: UserInputTracker,
    pointerMotionTracker: PointerMotionTracker,
    tracksPointerWindowTransitions: Bool,
    cheatsheetModifierBits: UInt64? = nil,
    deliverCheatsheet: @escaping @Sendable (CheatsheetInput) -> Void = { _ in },
    deliver: @escaping @Sendable (HotKeyInvocation) -> Void,
    deliverOverview: @escaping @Sendable (OverviewKeyAction) -> Void,
    deliverPointerMotion: @escaping @Sendable (PointerMotionInvocation) -> Void,
    tapReenabled: @escaping @Sendable (TimeInterval) -> Void,
    closeIntent: @escaping @Sendable (TimeInterval, pid_t?) -> Void = { _, _ in }
  ) {
    self.bindings = bindings
    self.cheatsheetModifierBits = cheatsheetModifierBits
    self.deliverCheatsheet = deliverCheatsheet
    self.userInputTracker = userInputTracker
    self.pointerMotionTracker = pointerMotionTracker
    self.tracksPointerWindowTransitions = tracksPointerWindowTransitions
    self.deliver = deliver
    self.deliverOverview = deliverOverview
    self.deliverPointerMotion = deliverPointerMotion
    self.tapReenabled = tapReenabled
    self.closeIntent = closeIntent
  }

  func install(
    tap: CFMachPort,
    source: CFRunLoopSource,
    callbackContext: Unmanaged<HotKeyTapContext>
  ) {
    lock.lock()
    self.tap = tap
    self.source = source
    self.callbackContext = callbackContext
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
      deliverCheatsheet(.dismiss)
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
      tracksGeneralUserInput = eventTracksGeneralUserInput(
        type,
        scrollMomentumPhase: type == .scrollWheel
          ? event.getIntegerValueField(.scrollWheelEventMomentumPhase)
          : nil
      )
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
      let closeIntent = isKeyDown && commandPressed
        && Self.closeWindowKeyCodes.contains(code)
      userInputTracker.record(
        timestamp: timestamp,
        focusIntent: focusIntent,
        closeIntent: closeIntent
      )
      if closeIntent {
        capturedModifierReleaseState.capture(
          modifierBits: hotKeyModifierBits(event.flags)
        )
        let rawProcessID = event.getIntegerValueField(
          .eventTargetUnixProcessID
        )
        let processID = pid_t(exactly: rawProcessID)
          .flatMap { $0 > 0 ? $0 : nil }
        self.closeIntent(timestamp, processID)
      }
    }
    if type == .flagsChanged {
      let bits = hotKeyModifierBits(event.flags)
      deliverCheatsheet(.modifiersChanged(
        matches: bits != 0 && bits == cheatsheetModifierBits,
        released: bits == 0
      ))
    } else if type == .keyDown {
      deliverCheatsheet(.keyDown(modifiersHeld: hotKeyModifierBits(event.flags) != 0))
    } else if eventIsMouseButtonDown(type) {
      deliverCheatsheet(.dismiss)
    }
    guard isKeyDown else {
      return Unmanaged.passUnretained(event)
    }
    let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let key = Key(code: code, flags: event.flags.rawValue)
    lock.lock()
    let overviewModeEnabled = overviewModeEnabled
    let cheatsheetVisible = cheatsheetVisible
    lock.unlock()
    if cheatsheetVisible && code == 53 {
      deliverCheatsheet(.dismiss)
      return nil
    }
    if overviewModeEnabled,
      event.flags.contains(.maskCommand),
      code == Self.commandTabKeyCode
    {
      deliverOverview(.cancel)
      return Unmanaged.passUnretained(event)
    }
    if overviewModeEnabled,
      let action = overviewKeyAction(
        keyCode: code,
        modifierBits: key.modifierBits,
        configuredCommand: bindings[key]
      )
    {
      lock.lock()
      captured += 1
      lock.unlock()
      capturedModifierReleaseState.capture(modifierBits: key.modifierBits)
      deliverOverview(action)
      return nil
    }
    guard let command = bindings[key] else {
      return Unmanaged.passUnretained(event)
    }
    if command == "toggle-cheatsheet",
      event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    {
      return nil
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
    pendingPointerMotion = nil
    pointerDeliveryGeneration &+= 1
    pointerDeliveryScheduled = false
    lock.unlock()
  }

  func setCheatsheetVisible(_ visible: Bool) {
    lock.lock()
    cheatsheetVisible = visible
    lock.unlock()
  }

  func setOverviewModeEnabled(_ enabled: Bool) {
    lock.lock()
    overviewModeEnabled = enabled
    lock.unlock()
  }

  private func enqueuePointerMotionIfNeeded(
    _ invocation: PointerMotionInvocation,
    rawWindowID: Int64
  ) {
    lock.lock()
    let rawWindowChanged = pointerTransitionState.changed(to: rawWindowID)
    let refreshDelay = pointerMotionDeliveryDelay(
      rawWindowID: rawWindowID,
      eventTimestamp: invocation.timestamp,
      lastDeliveryTimestamp: lastPointerDeliveryTimestamp
    )
    let deliveryPlan = pointerMotionDeliveryPlan(
      rawWindowChanged: rawWindowChanged,
      refreshDelay: refreshDelay,
      deliveryScheduled: pointerDeliveryScheduled
    )
    pendingPointerMotion = invocation
    let schedulesDelivery = deliveryPlan.shouldSchedule
    let deliveryDelay = deliveryPlan.delay
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
    let callbackContext = callbackContext
    self.tap = nil
    self.source = nil
    self.callbackContext = nil
    lock.unlock()
    guard let callbackContext else { return }
    if let tap {
      CGEvent.tapEnable(tap: tap, enable: false)
    }
    guard let runLoop else {
      if let tap {
        CFMachPortInvalidate(tap)
      }
      callbackContext.release()
      return
    }
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
      if let source {
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
      }
      if let tap {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
      }
      callbackContext.release()
      CFRunLoopStop(runLoop)
    }
    CFRunLoopWakeUp(runLoop)
  }
}
