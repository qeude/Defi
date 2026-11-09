import AppKit
import CoreGraphics
import DefiCore
import DefiModel
import Foundation

/// Owns only the temporary native display configuration, never workspace state.
/// `.forAppOnly` also lets WindowServer restore the session layout after a crash.
@MainActor
public final class DisplayArrangementController {
  public let pointerRouter: DisplayPointerRouter
  public private(set) var deskFrames: [MonitorID: Rect] = [:]
  public private(set) var status = "native"
  private var appliedFrames: [MonitorID: Rect] = [:]
  private var appliedIdentities: [MonitorID: String] = [:]
  /// Desks by physical display: macOS may hand a reconnected or different panel another
  /// display's former ID, so IDs alone would replay one monitor's desk for another.
  private var savedArrangements: [Set<String>: [String: Rect]] = [:]
  private var pending = true
  private var suspended = false
  private var suspensionChanged = false
  private var activationObserver: NSObjectProtocol?
  private let readFrames: () -> [MonitorID: Rect]
  private let applyFrames: ([MonitorID: Rect], CGConfigureOption) -> CGError
  private let primaryDisplay: () -> MonitorID
  private let isMirrored: (MonitorID) -> Bool
  private let displayIdentity: (MonitorID) -> String?
  private let stateURL: URL?
  private let sessionID: String?
  private var savedState: StoredDisplayArrangement?

  public convenience init(
    pointerRouter: DisplayPointerRouter = DisplayPointerRouter(), sessionID: String? = nil
  ) {
    self.init(
      readFrames: Self.currentFrames, applyFrames: Self.apply,
      primaryDisplay: { MonitorID(rawValue: UInt64(CGMainDisplayID())) },
      isMirrored: { CGDisplayIsInMirrorSet(CGDirectDisplayID($0.rawValue)) != 0 },
      displayIdentity: { stableDisplayIdentifier(CGDirectDisplayID($0.rawValue)) },
      pointerRouter: pointerRouter,
      stateURL: sessionID == nil ? nil : FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Defi/display-arrangement.json"),
      sessionID: sessionID
    )
  }

  init(
    readFrames: @escaping () -> [MonitorID: Rect],
    applyFrames: @escaping ([MonitorID: Rect], CGConfigureOption) -> CGError,
    primaryDisplay: @escaping () -> MonitorID,
    isMirrored: @escaping (MonitorID) -> Bool = { _ in false },
    displayIdentity: @escaping (MonitorID) -> String? = { _ in nil },
    pointerRouter: DisplayPointerRouter = DisplayPointerRouter(),
    stateURL: URL? = nil,
    sessionID: String? = nil
  ) {
    self.readFrames = readFrames
    self.applyFrames = applyFrames
    self.primaryDisplay = primaryDisplay
    self.isMirrored = isMirrored
    self.displayIdentity = displayIdentity
    self.pointerRouter = pointerRouter
    self.stateURL = stateURL
    self.sessionID = sessionID
    if let stateURL, let data = try? Data(contentsOf: stateURL),
      let stored = try? JSONDecoder().decode(StoredDisplayArrangement.self, from: data),
      stored.version == 2, stored.sessionID == sessionID,
      stored.desk.values.allSatisfy({ frame in
        [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite)
          && frame.width > 0 && frame.height > 0
      })
    {
      savedState = stored
    }
  }

  public var needsReconciliation: Bool { pending }

  /// System Settings shows and edits the technical arrangement: show the desk there so
  /// the user sees and rearranges their real displays, and restore the staircase after.
  public func suspendWhileSystemSettingsIsActive(_ changed: @escaping @MainActor () -> Void) {
    let systemSettings = "com.apple.systempreferences"
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] notification in
      let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      let active = application?.bundleIdentifier == systemSettings
      MainActor.assumeIsolated {
        if self?.setSuspended(active) == true { changed() }
      }
    }
    // Defi usually starts right after the Accessibility grant, inside System Settings.
    let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    if setSuspended(frontmost == systemSettings) { changed() }
  }

  /// Returns true when the caller must reconcile.
  func setSuspended(_ suspended: Bool) -> Bool {
    guard suspended != self.suspended else { return false }
    self.suspended = suspended
    suspensionChanged = true
    pending = true
    return true
  }

  public func invalidate() {
    pointerRouter.update(technical: [:], desk: [:])
    pending = true
  }

  /// Returns true when geometry changed and callers must wait for a fresh snapshot.
  public func reconcile() -> Bool {
    guard pending else { return false }
    pending = false
    let current = readFrames()
    guard !current.isEmpty else {
      pending = true
      return false
    }
    let primary = primaryDisplay()
    let identities = identities(of: current)
    // Display-mode changes can commit our temporary origins to the macOS session.
    // Recover only our exact last geometry; a new native arrangement wins.
    if appliedFrames.isEmpty, let savedState, savedState.technical == current,
      savedState.identities == identities, Set(savedState.desk.keys) == Set(current.keys),
      !isDisplayStaircase(savedState.desk, primary: primary)
    {
      deskFrames = savedState.desk
      appliedFrames = current
      appliedIdentities = identities
      remember(deskFrames)
      status = current == deskFrames ? "native" : "isolated"
    }
    if current == appliedFrames, identities == appliedIdentities, !suspensionChanged {
      pointerRouter.update(technical: current, desk: status == "native" ? current : deskFrames)
      return false
    }
    guard let primaryFrame = current[primary] else {
      pending = true
      return false
    }
    suspensionChanged = false
    defer { saveArrangement() }
    // A failed apply can leave fewer applied frames than identities.
    let sameDisplays = identities == appliedIdentities && Set(current.keys) == Set(appliedFrames.keys)
    appliedIdentities = identities
    let sizesChanged = sameDisplays && current.contains {
      appliedFrames[$0.key]?.width != $0.value.width
        || appliedFrames[$0.key]?.height != $0.value.height
    }
    let translationX = primaryFrame.x - (appliedFrames[primary]?.x ?? 0)
    let translationY = primaryFrame.y - (appliedFrames[primary]?.y ?? 0)
    let translatedOnly = sameDisplays && current.allSatisfy {
      $0.value.x - appliedFrames[$0.key]!.x == translationX
        && $0.value.y - appliedFrames[$0.key]!.y == translationY
    }
    // macOS already restores its own arrangement for each set of displays, so a new
    // set or a new native arrangement is the desk. Resolution and main-display
    // changes keep desk relationships.
    if !sameDisplays || (!sizesChanged && !translatedOnly) {
      deskFrames = desk(for: current, primary: primary)
    }
    if let anchor = deskFrames[primary] {
      deskFrames = deskFrames.mapValues {
        Rect(x: $0.x - anchor.x, y: $0.y - anchor.y, width: $0.width, height: $0.height)
      }
    }
    guard !deskFrames.isEmpty else {
      appliedFrames = current
      pointerRouter.update(technical: current, desk: current)
      status = "ambiguous"
      return false
    }
    remember(deskFrames)
    guard current.count > 1,
      !current.keys.contains(where: isMirrored)
    else {
      appliedFrames = current
      pointerRouter.update(technical: current, desk: current)
      status = "native"
      return false
    }
    // The desk keeps its sizes across resolution changes; only its origins are applied.
    let desired = suspended
      ? current.reduce(into: [:]) { result, display in
        let origin = deskFrames[display.key] ?? display.value
        result[display.key] = Rect(
          x: origin.x, y: origin.y, width: display.value.width, height: display.value.height
        )
      }
      : isolatedDisplayArrangement(current, primary: primary)
    let applied = suspended ? "suspended" : "isolated"
    guard desired != current else {
      appliedFrames = current
      pointerRouter.update(technical: current, desk: deskFrames)
      status = applied
      return false
    }
    pointerRouter.update(technical: [:], desk: [:])
    let result = applyFrames(desired, .forAppOnly)
    let observed = readFrames()
    guard result == .success, observed == desired else {
      // Never run a logical pointer map against geometry the OS did not accept.
      if observed != current { _ = applyFrames(current, .forAppOnly) }
      appliedFrames = readFrames()
      deskFrames = desk(for: appliedFrames, primary: primary)
      pointerRouter.update(technical: appliedFrames, desk: appliedFrames)
      status = deskFrames.isEmpty ? "ambiguous"
        : result == .success ? "observation-mismatch" : "failed:\(result.rawValue)"
      return observed != current
    }
    appliedFrames = observed
    pointerRouter.update(technical: observed, desk: deskFrames)
    status = applied
    return true
  }

  /// Our own staircase is never the user's desk: keep a known desk or leave it unknown.
  /// Limit: a user who really arranges that exact corner-touching diagonal is ambiguous.
  private func desk(for frames: [MonitorID: Rect], primary: MonitorID) -> [MonitorID: Rect] {
    guard isDisplayStaircase(frames, primary: primary) else { return frames }
    let identities = identities(of: frames)
    let saved = savedArrangements[Set(identities.values)].map { saved in
      identities.compactMapValues { saved[$0] }
    }
    let stored = savedState?.identities == identities ? savedState?.desk : nil
    return [saved, stored].compactMap { $0 }.first {
      Set($0.keys) == Set(frames.keys) && !isDisplayStaircase($0, primary: primary)
    } ?? [:]
  }

  /// The display ID keeps identities unique: identical panels without a serial share a UUID.
  /// A panel back under a new display ID is a new set; macOS's arrangement still applies.
  private func identities(of frames: [MonitorID: Rect]) -> [MonitorID: String] {
    Dictionary(uniqueKeysWithValues: frames.keys.map { id in
      // A UUID missing during wake or startup must not turn a known display into a new
      // set: keep the identity the display already has until it disconnects.
      let fallback = "#\(id.rawValue)"
      let known = appliedIdentities[id]
      let identity = displayIdentity(id).map { "\($0)\(fallback)" }
      return (id, known == fallback ? fallback : identity ?? known ?? fallback)
    })
  }

  private func remember(_ desk: [MonitorID: Rect]) {
    let identities = identities(of: desk)
    savedArrangements[Set(identities.values)] = Dictionary(
      uniqueKeysWithValues: desk.map { (identities[$0.key]!, $0.value) }
    )
  }

  @discardableResult
  public func restore() -> [MonitorID: Rect] {
    pointerRouter.update(technical: [:], desk: [:])
    let current = readFrames()
    guard !deskFrames.isEmpty else { return current }
    // Do not undo a newer native arrangement made after our last reconciliation.
    guard current == appliedFrames, Set(current.keys) == Set(deskFrames.keys) else { return current }
    if current != deskFrames {
      // App-scoped restoration is itself undone at exit if macOS has retained
      // the staircase in its session configuration (for example after scaling).
      let result = applyFrames(deskFrames, .forSession)
      status = result == .success ? "restored" : "restore-failed:\(result.rawValue)"
    }
    appliedFrames = readFrames()
    return appliedFrames
  }

  private func saveArrangement() {
    guard let stateURL, let sessionID else { return }
    let updated = StoredDisplayArrangement(
      sessionID: sessionID, technical: appliedFrames, identities: appliedIdentities, desk: deskFrames
    )
    guard updated != savedState else { return }
    do {
      try FileManager.default.createDirectory(
        at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      try JSONEncoder().encode(updated).write(to: stateURL, options: .atomic)
      savedState = updated
    } catch {
      FileHandle.standardError.write(Data("[defi] display arrangement persistence failed: \(error)\n".utf8))
    }
  }

  static func currentFrames() -> [MonitorID: Rect] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [:] }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [:] }
    return Dictionary(uniqueKeysWithValues: displays.prefix(Int(count)).map {
      let frame = CGDisplayBounds($0)
      return (MonitorID(rawValue: UInt64($0)), Rect(
        x: frame.minX, y: frame.minY, width: frame.width, height: frame.height
      ))
    })
  }

  static func apply(_ frames: [MonitorID: Rect], scope: CGConfigureOption = .forAppOnly) -> CGError {
    var transaction: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&transaction)
    guard begin == .success, let transaction else { return begin }
    for (id, frame) in frames.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
      guard frame.x.isFinite, frame.y.isFinite,
        frame.x >= Double(Int32.min), frame.x <= Double(Int32.max),
        frame.y >= Double(Int32.min), frame.y <= Double(Int32.max)
      else {
        CGCancelDisplayConfiguration(transaction)
        return .rangeCheck
      }
      let result = CGConfigureDisplayOrigin(
        transaction, CGDirectDisplayID(id.rawValue), Int32(frame.x), Int32(frame.y)
      )
      guard result == .success else {
        CGCancelDisplayConfiguration(transaction)
        return result
      }
    }
    return CGCompleteDisplayConfiguration(transaction, scope)
  }
}

private struct StoredDisplayArrangement: Codable, Equatable {
  var version = 2
  let sessionID: String
  let technical: [MonitorID: Rect]
  let identities: [MonitorID: String]
  let desk: [MonitorID: Rect]
}

/// Called on the existing input thread; AX work and main-thread layout cannot
/// delay an edge crossing. Maps are replaced atomically after reconfiguration.
public final class DisplayPointerRouter: @unchecked Sendable {
  private let lock = NSLock()
  private var technical: [MonitorID: Rect] = [:]
  private var desk: [MonitorID: Rect] = [:]
  private var active = true
  private var warps = 0
  private let warpPointer: @Sendable (CGPoint) -> CGError

  public convenience init() {
    // A warp otherwise freezes physical pointer motion for 0.25 s after each crossing.
    // The interval applies to every warp in the process; the closure keeps the source alive.
    nonisolated(unsafe) let source = CGEventSource(stateID: .combinedSessionState)
    source?.localEventsSuppressionInterval = 0
    self.init(warpPointer: { point in
      withExtendedLifetime(source) {}
      let result = CGWarpMouseCursorPosition(point)
      if result == .success { CGAssociateMouseAndMouseCursorPosition(1) }
      return result
    })
  }

  init(warpPointer: @escaping @Sendable (CGPoint) -> CGError) {
    self.warpPointer = warpPointer
  }

  func update(technical: [MonitorID: Rect], desk: [MonitorID: Rect]) {
    lock.lock()
    self.technical = technical
    self.desk = desk
    lock.unlock()
  }

  public func invalidate() {
    update(technical: [:], desk: [:])
  }

  public func setActive(_ active: Bool) {
    lock.lock()
    self.active = active
    lock.unlock()
  }

  public var warpCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return warps
  }

  func route(_ event: CGEvent) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard active else { return false }
    let destination = displayPointerDestination(
      x: event.location.x, y: event.location.y,
      deltaX: event.getDoubleValueField(.mouseEventDeltaX),
      deltaY: event.getDoubleValueField(.mouseEventDeltaY),
      technical: technical, desk: desk
    )
    guard let destination else { return false }
    let point = CGPoint(x: destination.x, y: destination.y)
    // Keep invalidation ordered after any in-flight warp, not just map lookup.
    guard warpPointer(point) == .success else { return false }
    event.location = point
    warps += 1
    return true
  }
}
