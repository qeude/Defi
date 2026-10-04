import ApplicationServices
import DefiConfig
import DefiModel
import DefiRuntime
import Darwin
import Foundation

let hotKeyEventTapPlacement = CGEventTapPlacement.tailAppendEventTap
let inputMonitorTapOptions = CGEventTapOptions.listenOnly

@NavigationActor
public final class HotKeyManager {
  public typealias Handler = @NavigationActor @Sendable (HotKeyInvocation) -> Void
  public typealias PointerMotionHandler =
    @NavigationActor @Sendable (PointerMotionInvocation) -> Void
  public typealias TapReenabledHandler =
    @NavigationActor @Sendable (TimeInterval) -> Void
  public typealias CloseIntentHandler =
    @NavigationActor @Sendable (TimeInterval, pid_t?) -> Void
  public typealias OverviewHandler =
    @NavigationActor @Sendable (OverviewKeyAction) -> Void

  private let bindings: [Key: String]
  private let handler: Handler
  public let tracksPointerMotion: Bool
  public private(set) var bindingError: HotKeyError?
  private let configurationError: HotKeyError?
  private let pointerMotionHandler: PointerMotionHandler?
  private let tapReenabledHandler: TapReenabledHandler
  private let closeIntentHandler: CloseIntentHandler
  private let overviewHandler: OverviewHandler
  private let cheatsheetHandler: @NavigationActor @Sendable (CheatsheetInput) -> Void
  private let cheatsheetModifierBits: UInt64?
  private let userInputTracker: UserInputTracker
  private let displayPointerRouter: DisplayPointerRouter?
  private let pointerMotionTracker: PointerMotionTracker
  private var context: InputMonitor?
  private var thread: Thread?
  private var registration: HotKeyRegistration?
  private let registrationHandler: @NavigationActor @Sendable (Bool, HotKeyError?) -> Void

  public var bindingCount: Int { bindings.count }

  public var isHotKeyCaptureEnabled: Bool {
    bindingError == nil && bindingCount > 0 && isEnabled && context?.hasRegisteredHotKeys == true
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
    displayPointerRouter: DisplayPointerRouter? = nil,
    tapReenabledHandler: @escaping TapReenabledHandler = { _ in },
    closeIntentHandler: @escaping CloseIntentHandler = { _, _ in },
    overviewHandler: @escaping OverviewHandler = { _ in },
    cheatsheetHandler: @escaping @NavigationActor @Sendable (CheatsheetInput) -> Void = { _ in },
    registrationHandler: @escaping @NavigationActor @Sendable (Bool, HotKeyError?) -> Void = { _, _ in },
    handler: @escaping Handler
  ) {
    self.handler = handler
    self.registrationHandler = registrationHandler
    tracksPointerMotion =
      displayPointerRouter != nil || config.input.focusFollowsMouse || config.input.mouseFollowsFocus
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
    self.displayPointerRouter = displayPointerRouter
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
    configurationError = bindingError
  }

  public func start() throws {
    guard context == nil else { return }
    bindingError = configurationError
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
      let context = Unmanaged<InputMonitor>
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
    let context = InputMonitor(
      bindings: bindings,
      userInputTracker: userInputTracker,
      pointerMotionTracker: pointerMotionTracker,
      displayPointerRouter: displayPointerRouter,
      tracksPointerWindowTransitions: pointerMotionHandler != nil,
      cheatsheetModifierBits: bindingError == nil ? cheatsheetModifierBits : nil,
      deliverCheatsheet: { input in
        NavigationActor.enqueue {
          cheatsheetHandler(input)
        }
      }
    ) { invocation in
      NavigationActor.enqueue {
        handler(invocation)
      }
    } deliverOverview: { action in
      NavigationActor.enqueue {
        overviewHandler(action)
      }
    } deliverPointerMotion: { invocation in
      NavigationActor.enqueue {
        pointerMotionHandler?(invocation)
      }
    } tapReenabled: { timestamp in
      NavigationActor.enqueue {
        tapReenabledHandler(timestamp)
      }
    } closeIntent: { timestamp, processID in
      NavigationActor.enqueue {
        closeIntentHandler(timestamp, processID)
      }
    }
    // Install interception first so passive observation sees routed pointer events.
    // Ordinary shortcuts always pass through the filtering callback unchanged.
    let interceptorMask = mask & ~CGEventMask(
      (1 << CGEventType.flagsChanged.rawValue)
        | (1 << CGEventType.leftMouseDown.rawValue)
        | (1 << CGEventType.rightMouseDown.rawValue)
        | (1 << CGEventType.otherMouseDown.rawValue)
        | (1 << CGEventType.scrollWheel.rawValue)
    )
    let interceptorCallback: CGEventTapCallBack = { _, type, event, userInfo in
      guard let userInfo else { return Unmanaged.passUnretained(event) }
      return Unmanaged<InputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        .intercept(type: type, event: event)
    }
    try context.installTap(options: .defaultTap, mask: interceptorMask, callback: interceptorCallback)
    do {
      try context.installTap(options: inputMonitorTapOptions, mask: mask, callback: callback)
    } catch {
      context.stop()
      throw error
    }
    let thread = Thread { context.run() }
    thread.name = "com.quentin.defi.input-monitor"
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
    registerHotKeys(in: context)
  }

  private func registerHotKeys(in context: InputMonitor) {
    guard bindingError == nil else {
      return
    }
    let registration = HotKeyRegistration(bindings: bindings, monitor: context) { [weak self] error in
      NavigationActor.enqueue {
        guard let self, self.context === context else { return }
        self.bindingError = error
        self.registrationHandler(self.isHotKeyCaptureEnabled, error)
      }
    }
    self.registration = registration
    registration.start()
  }

  public func resetPointerWindowTransition() {
    context?.resetPointerWindowTransition()
  }

  public var overviewModeSetter: @Sendable (Bool) -> Void {
    let context = context
    return { context?.setOverviewModeEnabled($0) }
  }

  public func setOverviewModeEnabled(_ enabled: Bool) {
    context?.setOverviewModeEnabled(enabled)
  }

  public func setCheatsheetVisible(_ visible: Bool) {
    context?.setCheatsheetVisible(visible)
  }

  public func stop() {
    registration?.stop()
    registration = nil
    context?.stop()
    context = nil
    thread = nil
  }

  isolated deinit {
    registration?.stop()
    context?.stop()
  }
}

final class InputMonitor: @unchecked Sendable {
  private static let commandTabKeyCode = CGKeyCode(48)
  private static let closeWindowKeyCodes: Set<CGKeyCode> = [12, 13]

  private let bindings: [Key: String]
  private let userInputTracker: UserInputTracker
  private let displayPointerRouter: DisplayPointerRouter?
  private let pointerMotionTracker: PointerMotionTracker
  private let tracksPointerWindowTransitions: Bool
  private let deliver: @Sendable (HotKeyInvocation) -> Void
  private let deliverOverview: @Sendable (OverviewKeyAction) -> Void
  private let deliverPointerMotion: @Sendable (PointerMotionInvocation) -> Void
  private let tapReenabled: @Sendable (TimeInterval) -> Void
  private let closeIntent: @Sendable (TimeInterval, pid_t?) -> Void
  private let lock = NSLock()
  private let ready = DispatchSemaphore(value: 0)
  private struct Tap: @unchecked Sendable {
    let port: CFMachPort
    let source: CFRunLoopSource
    let context: Unmanaged<InputMonitor>
  }
  private var taps: [Tap] = []
  private var registeredHotKeys = false
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
  private var overviewModeEnabled = false
  private var cheatsheetVisible = false
  private let cheatsheetModifierBits: UInt64?
  private let deliverCheatsheet: @Sendable (CheatsheetInput) -> Void
  private let textInputFocused: @Sendable () -> Bool

  init(
    bindings: [Key: String],
    userInputTracker: UserInputTracker,
    pointerMotionTracker: PointerMotionTracker,
    displayPointerRouter: DisplayPointerRouter? = nil,
    tracksPointerWindowTransitions: Bool,
    cheatsheetModifierBits: UInt64? = nil,
    deliverCheatsheet: @escaping @Sendable (CheatsheetInput) -> Void = { _ in },
    deliver: @escaping @Sendable (HotKeyInvocation) -> Void,
    deliverOverview: @escaping @Sendable (OverviewKeyAction) -> Void,
    deliverPointerMotion: @escaping @Sendable (PointerMotionInvocation) -> Void,
    tapReenabled: @escaping @Sendable (TimeInterval) -> Void,
    closeIntent: @escaping @Sendable (TimeInterval, pid_t?) -> Void = { _, _ in },
    textInputFocused: @escaping @Sendable () -> Bool = { settingsTextInputFocused.withLock { $0 } }
  ) {
    self.bindings = bindings
    self.textInputFocused = textInputFocused
    self.cheatsheetModifierBits = cheatsheetModifierBits
    self.deliverCheatsheet = deliverCheatsheet
    self.userInputTracker = userInputTracker
    self.pointerMotionTracker = pointerMotionTracker
    self.displayPointerRouter = displayPointerRouter
    self.tracksPointerWindowTransitions = tracksPointerWindowTransitions
    self.deliver = deliver
    self.deliverOverview = deliverOverview
    self.deliverPointerMotion = deliverPointerMotion
    self.tapReenabled = tapReenabled
    self.closeIntent = closeIntent
  }

  @discardableResult
  func installTap(
    options: CGEventTapOptions, mask: CGEventMask, callback: CGEventTapCallBack
  ) throws -> CFMachPort {
    let reference = Unmanaged.passRetained(self)
    guard let port = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: hotKeyEventTapPlacement, options: options,
      eventsOfInterest: mask, callback: callback, userInfo: reference.toOpaque()
    ) else {
      reference.release()
      throw HotKeyError.eventTapUnavailable
    }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
      CFMachPortInvalidate(port)
      reference.release()
      throw HotKeyError.eventTapUnavailable
    }
    lock.withLock { taps.append(Tap(port: port, source: source, context: reference)) }
    return port
  }

  func run() {
    let runLoop = CFRunLoopGetCurrent()!
    let taps = lock.withLock {
      self.runLoop = runLoop
      return self.taps
    }
    guard !taps.isEmpty else { ready.signal(); return }
    for tap in taps {
      CFRunLoopAddSource(runLoop, tap.source, .commonModes)
      CGEvent.tapEnable(tap: tap.port, enable: true)
    }
    ready.signal()
    CFRunLoopRun()
  }

  var hasRegisteredHotKeys: Bool { lock.withLock { registeredHotKeys } }

  func setHotKeysRegistered(_ registered: Bool) {
    let dismiss = lock.withLock {
      let dismiss = registeredHotKeys && !registered
      registeredHotKeys = registered
      return dismiss
    }
    if dismiss { deliverCheatsheet(.dismiss) }
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
      let taps = self.taps.filter { !CGEvent.tapIsEnabled(tap: $0.port) }
      guard !taps.isEmpty else {
        lock.unlock()
        return Unmanaged.passUnretained(event)
      }
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
      for tap in taps { CGEvent.tapEnable(tap: tap.port, enable: true) }
      deliverCheatsheet(.dismiss)
      tapReenabled(timestamp)
      return Unmanaged.passUnretained(event)
    }
    let timestamp = Double(event.timestamp) / 1_000_000_000
    if eventTracksPhysicalPointerMotion(type) {
      pointerMotionTracker.record(timestamp: timestamp)
      if type == .mouseMoved, tracksPointerWindowTransitions {
        // Hit-test the destination immediately; the event's window ID still
        // describes the source screen before the warp.
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
    let eventTargetPID = pid_t(exactly: event.getIntegerValueField(.eventTargetUnixProcessID))
    let isDefiTextInput = hotKeyTargetIsCurrentApplication(
      eventTargetPID, currentPID: getpid(),
      recordingShortcut: ShortcutRecorderButton.capturesKeyboard
    ) && (ShortcutRecorderButton.capturesKeyboard || textInputFocused())
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
      recordGeneralUserInput(type: type, event: event, isDefiTextInput: isDefiTextInput)
    }
    if isDefiTextInput && (isKeyDown || type == .flagsChanged) {
      return Unmanaged.passUnretained(event)
    }
    if type == .flagsChanged {
      let bits = hotKeyModifierBits(event.flags)
      deliverCheatsheet(.modifiersChanged(
        matches: hasRegisteredHotKeys && bits != 0 && bits == cheatsheetModifierBits,
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
    if cheatsheetVisible && code == 53 { return Unmanaged.passUnretained(event) }
    if overviewModeEnabled,
      event.flags.contains(.maskCommand), code == Self.commandTabKeyCode {
      deliverOverview(.cancel)
      return Unmanaged.passUnretained(event)
    }
    if overviewModeEnabled,
      overviewKeyAction(keyCode: code, modifierBits: key.modifierBits,
                        configuredCommand: bindings[key]) != nil {
      return Unmanaged.passUnretained(event)
    }
    guard hasRegisteredHotKeys else { return Unmanaged.passUnretained(event) }
    guard let command = bindings[key] else {
      return Unmanaged.passUnretained(event)
    }
    if command == "toggle-cheatsheet",
      event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    {
      return Unmanaged.passUnretained(event)
    }
    lock.lock()
    captured += 1
    lock.unlock()
    capturedModifierReleaseState.capture(modifierBits: key.modifierBits)
    userInputTracker.recordCapturedCommand(at: timestamp)
    deliver(HotKeyInvocation(
      command: command,
      timestamp: timestamp,
      sourceProcessID: Int32(exactly: event.getIntegerValueField(.eventSourceUnixProcessID))
        .flatMap { $0 == 0 ? nil : $0 }
    ))
    return Unmanaged.passUnretained(event)
  }

  private func recordGeneralUserInput(
    type: CGEventType, event: CGEvent, isDefiTextInput: Bool
  ) {
    let timestamp = Double(event.timestamp) / 1_000_000_000
    let isKeyDown = type == .keyDown
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
      && !isDefiTextInput
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

  /// The active tap only intercepts modal input and routes physical pointer movement.
  func intercept(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      return handle(type: type, event: event)
    }
    if eventTracksPhysicalPointerMotion(type) {
      if displayPointerRouter?.route(event) == true {
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 0)
      }
      return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    if let record = ShortcutRecorderButton.captureHandler.withLock({ $0 }) {
      capturedModifierReleaseState.reset()
      recordGeneralUserInput(type: type, event: event, isDefiTextInput: true)
      record(UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
             event.flags.rawValue, event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
      return nil
    }
    let targetPID = pid_t(exactly: event.getIntegerValueField(.eventTargetUnixProcessID))
    if targetPID == getpid(), textInputFocused() { return Unmanaged.passUnretained(event) }
    let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let key = Key(code: code, flags: event.flags.rawValue)
    let (overview, cheatsheet) = lock.withLock { (overviewModeEnabled, cheatsheetVisible) }
    if cheatsheet && code == 53 {
      capturedModifierReleaseState.reset()
      recordGeneralUserInput(type: type, event: event, isDefiTextInput: false)
      deliverCheatsheet(.dismiss)
      return nil
    }
    if overview, let action = overviewKeyAction(
      keyCode: code, modifierBits: key.modifierBits, configuredCommand: bindings[key]
    ) {
      capturedModifierReleaseState.reset()
      recordGeneralUserInput(type: type, event: event, isDefiTextInput: false)
      let timestamp = Double(event.timestamp) / 1_000_000_000
      userInputTracker.recordCapturedCommand(at: timestamp)
      lock.withLock {
        captured += 1
        capturedModifierReleaseState.capture(modifierBits: key.modifierBits)
      }
      deliverOverview(action)
      return nil
    }
    return Unmanaged.passUnretained(event)
  }

  var isEnabled: Bool {
    let taps = lock.withLock { self.taps }
    return !taps.isEmpty && taps.allSatisfy { CGEvent.tapIsEnabled(tap: $0.port) }
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
    NavigationActor.shared.queue.asyncAfter(
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
    let (taps, runLoop) = lock.withLock {
      let taps = self.taps
      self.taps = []
      registeredHotKeys = false
      return (taps, self.runLoop)
    }
    for tap in taps { CGEvent.tapEnable(tap: tap.port, enable: false) }
    let cleanup: () -> Void = {
      for tap in taps {
        if let runLoop { CFRunLoopRemoveSource(runLoop, tap.source, .commonModes) }
        CFMachPortInvalidate(tap.port)
        tap.context.release()
      }
      if let runLoop { CFRunLoopStop(runLoop) }
    }
    if let runLoop {
      CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, cleanup)
      CFRunLoopWakeUp(runLoop)
    } else { cleanup() }
  }
}
