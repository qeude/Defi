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
  private var savedArrangements: [Set<MonitorID>: [MonitorID: Rect]] = [:]
  private var pending = true
  private let readFrames: () -> [MonitorID: Rect]
  private let applyFrames: ([MonitorID: Rect], CGConfigureOption) -> CGError
  private let primaryDisplay: () -> MonitorID
  private let isMirrored: (MonitorID) -> Bool
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
    pointerRouter: DisplayPointerRouter = DisplayPointerRouter(),
    stateURL: URL? = nil,
    sessionID: String? = nil
  ) {
    self.readFrames = readFrames
    self.applyFrames = applyFrames
    self.primaryDisplay = primaryDisplay
    self.isMirrored = isMirrored
    self.pointerRouter = pointerRouter
    self.stateURL = stateURL
    self.sessionID = sessionID
    if let stateURL, let data = try? Data(contentsOf: stateURL),
      let stored = try? JSONDecoder().decode(StoredDisplayArrangement.self, from: data),
      stored.version == 1, stored.sessionID == sessionID
    {
      savedState = stored
    }
  }

  public var needsReconciliation: Bool { pending }

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
    // Display-mode changes can commit our temporary origins to the macOS session.
    // Recover only our exact last geometry; a new native arrangement wins.
    if appliedFrames.isEmpty, let savedState, savedState.technical == current,
      Set(savedState.desk.keys) == Set(current.keys),
      savedState.desk.values.allSatisfy({ frame in
        [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite)
          && frame.width > 0 && frame.height > 0
      })
    {
      deskFrames = savedState.desk
      appliedFrames = current
      savedArrangements[Set(current.keys)] = deskFrames
      status = current == deskFrames ? "native" : "isolated"
    }
    if current == appliedFrames {
      pointerRouter.update(technical: current, desk: status == "native" ? current : deskFrames)
      return false
    }
    let ids = Set(current.keys)
    let primary = primaryDisplay()
    guard let primaryFrame = current[primary] else {
      pending = true
      return false
    }
    defer { saveArrangement() }
    let sameDisplays = ids == Set(appliedFrames.keys)
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
    // Resolution and main-display changes keep desk relationships. A new native
    // arrangement of the same displays is explicit user intent.
    if !sameDisplays, let saved = savedArrangements[ids] {
      deskFrames = saved
    } else if !sizesChanged && !translatedOnly {
      deskFrames = current
    }
    if let anchor = deskFrames[primary] {
      deskFrames = deskFrames.mapValues {
        Rect(x: $0.x - anchor.x, y: $0.y - anchor.y, width: $0.width, height: $0.height)
      }
    }
    savedArrangements[ids] = deskFrames
    guard current.count > 1,
      !current.keys.contains(where: isMirrored)
    else {
      appliedFrames = current
      pointerRouter.update(technical: current, desk: current)
      status = "native"
      return false
    }
    let desired = isolatedDisplayArrangement(current, primary: primary)
    guard desired != current else {
      appliedFrames = current
      pointerRouter.update(technical: current, desk: deskFrames)
      status = "isolated"
      return false
    }
    pointerRouter.update(technical: [:], desk: [:])
    let result = applyFrames(desired, .forAppOnly)
    let observed = readFrames()
    guard result == .success, observed == desired else {
      // Never run a logical pointer map against geometry the OS did not accept.
      if observed != current { _ = applyFrames(current, .forAppOnly) }
      appliedFrames = readFrames()
      deskFrames = appliedFrames
      pointerRouter.update(technical: appliedFrames, desk: appliedFrames)
      status = result == .success ? "observation-mismatch" : "failed:\(result.rawValue)"
      return observed != current
    }
    appliedFrames = observed
    pointerRouter.update(technical: observed, desk: deskFrames)
    status = "isolated"
    return true
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
      sessionID: sessionID, technical: appliedFrames, desk: deskFrames
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
  var version = 1
  let sessionID: String
  let technical: [MonitorID: Rect]
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
    self.init(warpPointer: { point in
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
