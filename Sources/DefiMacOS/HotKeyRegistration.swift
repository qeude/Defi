import AppKit
import Carbon
import Foundation
import Synchronization

extension Key {
  var carbonModifiers: UInt32 {
    var result: UInt32 = 0
    for (flag, modifier) in [
      (CGEventFlags.maskCommand, cmdKey), (.maskAlternate, optionKey),
      (.maskControl, controlKey), (.maskShift, shiftKey),
    ] where modifierBits & flag.rawValue != 0 {
      result |= UInt32(modifier)
    }
    return result
  }
}

/// Carbon owns shortcut reservation. The passive monitor delivers commands on
/// its own run loop, including while the application's event loop is busy.
/// All Carbon calls and references remain on the main thread.
final class HotKeyRegistration: @unchecked Sendable {
  private let monitor: InputMonitor
  private let resolve: (@MainActor () -> HotKeyResolution?)?
  private let changed: @Sendable (HotKeyError?, [String]) -> Void
  private let cancelled = Mutex(false)
  @MainActor private var references: [EventHotKeyRef] = []
  @MainActor private var eventHandler: EventHandlerRef?
  @MainActor private var observer: CFRunLoopObserver?
  @MainActor private var suspended: Bool?
  @MainActor private var bindings: [Key: (accelerator: String, command: String)]
  @MainActor private var layoutObserver: KeyboardLayoutObserver?
  /// Accelerators whose chord another app already reserves; a layout change or reload retries them.
  @MainActor private var held: [String] = []
  @MainActor private var registrationFailed = false

  /// `resolve`, when given, reads the keyboard layout and runs on the main thread only.
  init(bindings: [Key: (accelerator: String, command: String)], monitor: InputMonitor,
       resolve: (@MainActor () -> HotKeyResolution?)? = nil,
       changed: @escaping @Sendable (HotKeyError?, [String]) -> Void) {
    self.bindings = bindings
    self.monitor = monitor
    self.resolve = resolve
    self.changed = changed
  }

  func start() {
    DispatchQueue.main.async { [self] in
      MainActor.assumeIsolated {
        guard !cancelled.withLock({ $0 }) else { return }
        var types = [
          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        // Acknowledge Carbon notifications without delivering a second command.
        let status = InstallEventHandler(
          GetApplicationEventTarget(), { _, _, _ in noErr },
          types.count, &types, nil, &eventHandler
        )
        guard status == noErr else {
          changed(.registrationFailed(keyCode: nil, status: status), [])
          return
        }
        let observer = CFRunLoopObserverCreateWithHandler(
          nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1
        ) { [weak self] _, _ in
          MainActor.assumeIsolated { self?.refresh() }
        }
        guard let observer else {
          if let eventHandler { RemoveEventHandler(eventHandler) }
          eventHandler = nil
          changed(.registrationFailed(keyCode: nil, status: Int32(memFullErr)), [])
          return
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        if let resolve {
          if let resolution = resolve() { adopt(resolution) }
          layoutObserver = KeyboardLayoutObserver { [weak self] in self?.layoutChanged() }
          monitor.onKeyboardTypeChange { [weak self] type in
            observedKeyboardType.withLock { $0 = type }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.layoutChanged() } }
          }
        }
        refresh()
      }
    }
  }

  @MainActor private func adopt(_ resolution: HotKeyResolution) {
    bindings = resolution.keys
    for (accelerator, reason) in resolution.inactive.sorted(by: { $0.key < $1.key }) {
      NSLog("Defi: shortcut %@ is inactive: %@", accelerator, String(describing: reason))
    }
  }

  /// Also fires for input-method switches that keep the layout, which resolve to the same table.
  @MainActor private func layoutChanged() {
    guard !cancelled.withLock({ $0 }), let resolution = resolve?(),
      registrationFailed || !held.isEmpty || resolution.keys.mapValues(\.command) != bindings.mapValues(\.command)
    else { return }
    adopt(resolution)
    suspended = nil
    refresh()
  }

  @MainActor private func refresh() {
    guard !cancelled.withLock({ $0 }) else { return }
    // Text editing in Defi must retain native shortcuts. The recorder's active
    // interceptor remains independent of these reservations.
    let shouldSuspend = ShortcutRecorderButton.capturesKeyboard
      || (NSApplication.shared.isActive && settingsTextInputFocused.withLock { $0 })
    guard suspended != shouldSuspend else { return }
    suspended = shouldSuspend
    unregister()
    guard !shouldSuspend else {
      changed(nil, held)
      return
    }
    var failed: [(key: Key, status: Int32)] = []
    for (index, key) in bindings.keys.sorted(by: {
      ($0.code, $0.modifierBits) < ($1.code, $1.modifierBits)
    }).enumerated() {
      var reference: EventHotKeyRef?
      let status = RegisterEventHotKey(
        UInt32(key.code), key.carbonModifiers,
        EventHotKeyID(signature: 0x44656669, id: UInt32(index + 1)),
        GetApplicationEventTarget(), OptionBits(kEventHotKeyNoOptions), &reference
      )
      if status == noErr, let reference {
        references.append(reference)
      } else {
        failed.append((key, status))
      }
    }
    guard !cancelled.withLock({ $0 }) else {
      unregister()
      return
    }
    // Nothing registered: the whole set is unavailable. Otherwise one chord held elsewhere costs only itself.
    if references.isEmpty, let first = failed.first {
      registrationFailed = true
      changed(.registrationFailed(keyCode: first.key.code, status: first.status), [])
      return
    }
    registrationFailed = false
    // The tap must not run a command for a chord another app owns.
    let lost = Set(failed.map(\.key))
    monitor.setBindings(bindings.filter { !lost.contains($0.key) }.mapValues(\.command))
    monitor.setHotKeysRegistered(!references.isEmpty)
    let heldNow = failed.compactMap { bindings[$0.key]?.accelerator }.sorted()
    if heldNow != held {
      held = heldNow
      for accelerator in heldNow { NSLog("Defi: shortcut %@ is inactive: held by another app", accelerator) }
    }
    changed(nil, held)
  }

  @MainActor private func unregister() {
    monitor.setHotKeysRegistered(false)
    for reference in references {
      let status = UnregisterEventHotKey(reference)
      if status != noErr { NSLog("Defi: UnregisterEventHotKey failed: %d", status) }
    }
    references.removeAll()
  }

  func stop() {
    cancelled.withLock { $0 = true }
    monitor.setHotKeysRegistered(false)
    DispatchQueue.main.async { [self] in
      MainActor.assumeIsolated {
        if let observer { CFRunLoopObserverInvalidate(observer) }
        observer = nil
        layoutObserver = nil
        unregister()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
      }
    }
  }
}
