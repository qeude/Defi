import AppKit
import ApplicationServices
import CoreGraphics
import DefiModel

enum PlatformEventKind: Equatable {
  case application
  case applicationTerminated
  case focus
  case frame
  case windows
  case mouse
  case mouseRelease
  case screens
}

func platformEventCancelsMouseAnimation(_ kind: PlatformEventKind) -> Bool {
  kind == .mouse
}

func nativeFocusedWindowIDAfterEvent(
  _ kind: PlatformEventKind,
  cachedWindowID: WindowID?
) -> WindowID? {
  kind == .focus ? nil : cachedWindowID
}

func mouseGestureRefreshProcessID(
  latestFocusIntent: UserInputTracker.FocusIntent?,
  focusedWindowID: WindowID?,
  processIDs: [WindowID: pid_t]
) -> pid_t? {
  let mouseWindowID: WindowID?
  if let latestFocusIntent,
    case .mouse(let windowID) = latestFocusIntent.source
  {
    mouseWindowID = windowID
  } else {
    mouseWindowID = nil
  }

  for windowID in [mouseWindowID, focusedWindowID].compactMap({ $0 }) {
    if let processID = processIDs[windowID] {
      return processID
    }
  }
  return nil
}

enum WindowSnapshotInvalidation: Equatable {
  case none
  case process(pid_t)
  case full
}

public final class UserInputTracker: @unchecked Sendable {
  public enum FocusIntentSource: Equatable, Sendable {
    case keyboard
    case mouse(windowID: WindowID?)
  }

  public struct FocusIntent: Equatable, Sendable {
    public let timestamp: TimeInterval
    public let source: FocusIntentSource
  }

  public struct FocusRecoveryTarget: Equatable, Sendable {
    public let timestamp: TimeInterval
    public let windowID: WindowID?
    public let processID: pid_t?
  }

  public struct Snapshot: Equatable, Sendable {
    public let latestEventTimestamp: TimeInterval
    public let latestFocusIntent: FocusIntent?
    public let latestCloseIntent: TimeInterval
  }

  private struct ObservedFocusTarget: Equatable {
    let windowID: WindowID?
    let processID: pid_t?
  }

  private let lock = NSLock()
  private var latestTimestamp: TimeInterval = 0
  private var latestFocusIntent: FocusIntent?
  private var latestCloseIntentTimestamp: TimeInterval = 0
  private var observedFocusIntentTimestamp: TimeInterval = 0
  private var observedFocusTargets: [ObservedFocusTarget] = []

  public init() {}

  public func record(
    timestamp: TimeInterval,
    focusIntent: FocusIntentSource? = nil,
    closeIntent: Bool = false
  ) {
    lock.lock()
    latestTimestamp = max(latestTimestamp, timestamp)
    if let focusIntent,
      latestFocusIntent.map({ timestamp >= $0.timestamp }) ?? true
    {
      if latestFocusIntent.map({ timestamp > $0.timestamp }) ?? true {
        observedFocusIntentTimestamp = 0
        observedFocusTargets.removeAll(keepingCapacity: true)
      }
      latestFocusIntent = FocusIntent(
        timestamp: timestamp,
        source: focusIntent
      )
    }
    if closeIntent {
      latestCloseIntentTimestamp = max(latestCloseIntentTimestamp, timestamp)
    }
    lock.unlock()
  }

  public func invalidate(at timestamp: TimeInterval) {
    lock.lock()
    latestTimestamp = max(latestTimestamp, timestamp).nextUp
    latestFocusIntent = nil
    observedFocusIntentTimestamp = 0
    observedFocusTargets.removeAll(keepingCapacity: true)
    lock.unlock()
  }

  public func recordObservedFocus(
    windowID: WindowID?,
    processID: pid_t?
  ) {
    lock.lock()
    guard let focusIntent = latestFocusIntent,
      focusIntent.timestamp > latestCloseIntentTimestamp,
      windowID != nil || processID != nil
    else {
      lock.unlock()
      return
    }
    if observedFocusIntentTimestamp != focusIntent.timestamp {
      observedFocusIntentTimestamp = focusIntent.timestamp
      observedFocusTargets.removeAll(keepingCapacity: true)
    }
    let target = ObservedFocusTarget(
      windowID: windowID,
      processID: processID
    )
    if let windowID,
      let index = observedFocusTargets.lastIndex(where: {
        $0.windowID == nil && $0.processID == processID
      })
    {
      observedFocusTargets[index] = ObservedFocusTarget(
        windowID: windowID,
        processID: processID
      )
    } else if !observedFocusTargets.contains(target) {
      observedFocusTargets.append(target)
      if observedFocusTargets.count > 8 {
        observedFocusTargets.removeFirst()
      }
    }
    lock.unlock()
  }

  public func focusRecoveryTarget(
    after timestamp: TimeInterval,
    excludingWindowID: WindowID? = nil,
    excludingProcessID: pid_t? = nil,
    fallbackWindowID: WindowID? = nil,
    fallbackProcessID: pid_t? = nil
  ) -> FocusRecoveryTarget? {
    lock.lock()
    defer { lock.unlock() }
    guard latestTimestamp > timestamp else {
      return nil
    }
    if let focusIntent = latestFocusIntent,
      focusIntent.timestamp > timestamp
    {
      guard focusIntent.timestamp > latestCloseIntentTimestamp else {
        return nil
      }
      let observedTarget = {
        guard self.observedFocusIntentTimestamp == focusIntent.timestamp else {
          return nil as ObservedFocusTarget?
        }
        return self.observedFocusTargets.reversed().first(where: {
          if let excludingWindowID, $0.windowID == excludingWindowID {
            return false
          }
          if $0.windowID == nil,
            let excludingProcessID,
            $0.processID == excludingProcessID
          {
            return false
          }
          return true
        })
      }
      switch focusIntent.source {
      case .keyboard:
        guard let target = observedTarget() else { return nil }
        return FocusRecoveryTarget(
          timestamp: latestTimestamp,
          windowID: target.windowID,
          processID: target.processID
        )
      case .mouse(let windowID):
        if let target = observedTarget(), target.windowID != windowID {
          return FocusRecoveryTarget(
            timestamp: latestTimestamp,
            windowID: target.windowID,
            processID: target.processID
          )
        }
        if let windowID {
          return FocusRecoveryTarget(
            timestamp: latestTimestamp,
            windowID: windowID,
            processID: nil
          )
        }
        guard let target = observedTarget() else { return nil }
        return FocusRecoveryTarget(
          timestamp: latestTimestamp,
          windowID: target.windowID,
          processID: target.processID
        )
      }
    }
    guard latestCloseIntentTimestamp <= timestamp else { return nil }
    if let fallbackWindowID, fallbackWindowID == excludingWindowID {
      return nil
    }
    if fallbackWindowID == nil,
      let fallbackProcessID,
      fallbackProcessID == excludingProcessID
    {
      return nil
    }
    guard fallbackWindowID != nil || fallbackProcessID != nil else {
      return nil
    }
    return FocusRecoveryTarget(
      timestamp: latestTimestamp,
      windowID: fallbackWindowID,
      processID: fallbackProcessID
    )
  }

  public var latestEventTimestamp: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return latestTimestamp
  }

  public var snapshot: Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return Snapshot(
      latestEventTimestamp: latestTimestamp,
      latestFocusIntent: latestFocusIntent,
      latestCloseIntent: latestCloseIntentTimestamp
    )
  }
}

public final class PointerMotionTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var timestamp: TimeInterval = 0

  public init() {}

  public func record(timestamp: TimeInterval) {
    lock.lock()
    self.timestamp = max(self.timestamp, timestamp)
    lock.unlock()
  }

  public func invalidate(at timestamp: TimeInterval) {
    lock.lock()
    self.timestamp = max(self.timestamp, timestamp).nextUp
    lock.unlock()
  }

  public var latestTimestamp: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return timestamp
  }
}

struct PointerWindowTransitionState {
  private var previousRawWindowID: Int64?

  mutating func changed(to rawWindowID: Int64) -> Bool {
    guard previousRawWindowID != rawWindowID else { return false }
    previousRawWindowID = rawWindowID
    return true
  }

  mutating func reset() {
    previousRawWindowID = nil
  }
}

func pointerMotionDeliveryDelay(
  rawWindowID: Int64,
  eventTimestamp: TimeInterval,
  lastDeliveryTimestamp: TimeInterval?,
  maximumFrequencyHz: Double = 120
) -> TimeInterval {
  guard maximumFrequencyHz > 0,
    let lastDeliveryTimestamp
  else {
    return 0
  }
  let minimumInterval = 1 / maximumFrequencyHz
  let elapsed = max(0, eventTimestamp - lastDeliveryTimestamp)
  return max(0, minimumInterval - elapsed)
}

struct PointerMotionDeliveryPlan: Equatable {
  let shouldSchedule: Bool
  let delay: TimeInterval
}

func pointerMotionDeliveryPlan(
  rawWindowChanged: Bool,
  refreshDelay: TimeInterval,
  deliveryScheduled: Bool
) -> PointerMotionDeliveryPlan {
  PointerMotionDeliveryPlan(
    shouldSchedule: !deliveryScheduled,
    delay: rawWindowChanged ? 0 : refreshDelay
  )
}

func eventTracksPhysicalPointerMotion(_ type: CGEventType) -> Bool {
  switch type {
  case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
    true
  default:
    false
  }
}

func eventIsMouseButtonDown(_ type: CGEventType) -> Bool {
  switch type {
  case .leftMouseDown, .rightMouseDown, .otherMouseDown:
    true
  default:
    false
  }
}

func eventTracksGeneralUserInput(
  _ type: CGEventType,
  scrollMomentumPhase: Int64? = nil
) -> Bool {
  type == .keyDown || type == .flagsChanged
    || (type == .scrollWheel && (scrollMomentumPhase ?? 0) == 0)
    || eventIsMouseButtonDown(type)
}

func eventEndsMouseFocusInteraction(_ type: NSEvent.EventType) -> Bool {
  switch type {
  case .leftMouseUp, .rightMouseUp, .otherMouseUp:
    true
  default:
    false
  }
}

func eventStartsMouseFocusInteraction(_ type: NSEvent.EventType) -> Bool {
  switch type {
  case .leftMouseDown, .rightMouseDown, .otherMouseDown:
    true
  default:
    false
  }
}

func mouseFocusIntentWindowID(rawWindowID: Int64) -> WindowID? {
  guard rawWindowID > 0 else { return nil }
  return WindowID(rawValue: UInt64(rawWindowID))
}

func mouseFocusIntent(
  eventType: CGEventType,
  rawWindowID: Int64
) -> UserInputTracker.FocusIntentSource? {
  guard eventType == .leftMouseDown else { return nil }
  return .mouse(windowID: mouseFocusIntentWindowID(rawWindowID: rawWindowID))
}

func updatedWindowTopologyInputTimestamp(
  for kind: PlatformEventKind,
  latestInputTimestamp: TimeInterval,
  previousTimestamp: TimeInterval?
) -> TimeInterval? {
  switch kind {
  case .windows, .applicationTerminated:
    return latestInputTimestamp
  case .application, .focus, .frame, .mouse, .mouseRelease, .screens:
    return previousTimestamp
  }
}

func userInputOccurredAfterWindowTopology(
  topologyInputTimestamp: TimeInterval?,
  latestInputTimestamp: TimeInterval,
  latestFocusIntent: UserInputTracker.FocusIntent? = nil,
  latestCloseIntentTimestamp: TimeInterval = 0,
  removedWindowIDs: Set<WindowID> = []
) -> Bool {
  guard let topologyInputTimestamp else { return false }
  if latestInputTimestamp > topologyInputTimestamp {
    return true
  }
  guard let latestFocusIntent,
    latestFocusIntent.timestamp >= topologyInputTimestamp,
    latestFocusIntent.timestamp > latestCloseIntentTimestamp
  else {
    return false
  }
  switch latestFocusIntent.source {
  case .keyboard:
    return true
  case .mouse(let windowID):
    guard let windowID else { return false }
    return !removedWindowIDs.contains(windowID)
  }
}

func guardedFocusIsCurrent(
  latestInputTimestamp: TimeInterval,
  maximumInputTimestamp: TimeInterval
) -> Bool {
  latestInputTimestamp <= maximumInputTimestamp
}

func guardedFocusMutationNeedsRecovery(
  mutationApplied: Bool,
  generationCurrent: Bool,
  inputCurrent: Bool
) -> Bool {
  mutationApplied && generationCurrent && !inputCurrent
}

func nativeFocusEventMatchesTarget(
  eventPending: Bool,
  eventProcessIDs: Set<pid_t>,
  hasUnknownEventProcess: Bool,
  focusedProcessID: pid_t?
) -> Bool {
  guard eventPending else { return false }
  guard let focusedProcessID else { return false }
  if hasUnknownEventProcess { return true }
  return eventProcessIDs.contains(focusedProcessID)
}

func nativeFocusEventShouldRemainPending(
  eventPending: Bool,
  targetMatched: Bool
) -> Bool {
  eventPending && !targetMatched
}

func windowSnapshotInvalidation(
  for kind: PlatformEventKind,
  processID: pid_t?
) -> WindowSnapshotInvalidation {
  switch kind {
  case .windows:
    return processID.map(WindowSnapshotInvalidation.process) ?? .full
  case .application, .applicationTerminated, .screens:
    return .full
  case .focus, .frame, .mouse, .mouseRelease:
    return .none
  }
}

struct MouseGestureEventNormalizer {
  private enum Button: Hashable {
    case left
    case right
    case other(Int)

    init(eventType: NSEvent.EventType, buttonNumber: Int) {
      switch eventType {
      case .leftMouseDown, .leftMouseUp:
        self = .left
      case .rightMouseDown, .rightMouseUp:
        self = .right
      default:
        self = .other(buttonNumber)
      }
    }
  }

  enum Synchronization: Equatable {
    case gesture
  }

  struct Actions: Equatable {
    var refreshBorderStacking = false
    var startsGesture = false
    var synchronization: Synchronization?
    var endsFocusInteraction = false
  }

  private var heldButtons = Set<Button>()
  private var dragged = false

  mutating func actions(
    for eventType: NSEvent.EventType,
    buttonNumber: Int = 0
  ) -> Actions {
    switch eventType {
    case .leftMouseDown:
      heldButtons.insert(.left)
      dragged = false
      return Actions(refreshBorderStacking: true, startsGesture: true)
    case .rightMouseDown, .otherMouseDown:
      heldButtons.insert(
        Button(eventType: eventType, buttonNumber: buttonNumber)
      )
      return Actions()
    case .leftMouseDragged:
      guard heldButtons.contains(.left) else { return Actions() }
      dragged = true
      // Platform sync demand is a Boolean, so repeated drag events coalesce
      // while still scheduling fresh snapshots after live reorder animations.
      return Actions(synchronization: .gesture)
    case .leftMouseUp, .rightMouseUp, .otherMouseUp:
      let button = Button(eventType: eventType, buttonNumber: buttonNumber)
      guard heldButtons.remove(button) != nil else { return Actions() }
      let wasDragged = button == .left && dragged
      if button == .left {
        dragged = false
      }
      return Actions(
        synchronization: wasDragged ? .gesture : nil,
        endsFocusInteraction: heldButtons.isEmpty
      )
    default:
      return Actions()
    }
  }

  mutating func reset() -> Bool {
    let hadHeldButtons = !heldButtons.isEmpty
    heldButtons.removeAll(keepingCapacity: true)
    dragged = false
    return hadHeldButtons
  }
}

struct WindowBorderStackingRefreshRequest: Equatable, Sendable {
  let generation: UInt64
  let windowID: WindowID
}

struct WindowBorderStackingRefreshState {
  private var generation: UInt64 = 0

  mutating func request(
    for windowID: WindowID?
  ) -> WindowBorderStackingRefreshRequest? {
    generation &+= 1
    return windowID.map {
      WindowBorderStackingRefreshRequest(
        generation: generation,
        windowID: $0
      )
    }
  }

  func shouldApply(
    _ request: WindowBorderStackingRefreshRequest,
    activeWindowID: WindowID?
  ) -> Bool {
    request.generation == generation && request.windowID == activeWindowID
  }
}

struct WindowStackEntry: Equatable, Sendable {
  let windowID: WindowID
  let processID: pid_t
  let layer: Int
  let frame: Rect
}

struct WindowBorderStacking: Equatable, Sendable {
  let targetWindowID: WindowID?
  let activeWindowIsFrontmost: Bool
  let upperBoundWindowID: WindowID?
  let upperBoundLevel: Int?

  static func inactive(for targetWindowID: WindowID?) -> Self {
    Self(
      targetWindowID: targetWindowID,
      activeWindowIsFrontmost: false,
      upperBoundWindowID: nil,
      upperBoundLevel: nil
    )
  }
}

private let minimumBorderOccludingWindowArea = 2_048.0

func windowBorderStacking(
  targetWindowID: WindowID?,
  ownProcessID: pid_t,
  floatingLevel: Int,
  entries: [WindowStackEntry],
  monitorFrames: [Rect] = [],
  knownWindowIDs: Set<WindowID> = []
) -> WindowBorderStacking {
  let externalEntries = entries.filter { $0.processID != ownProcessID }
  let targetMonitorFrames: [Rect]
  if let targetWindowID,
    let targetFrame = externalEntries.first(where: {
      $0.windowID == targetWindowID
    })?.frame
  {
    targetMonitorFrames = monitorFrames.filter {
      framesIntersect($0, targetFrame)
    }
  } else {
    targetMonitorFrames = monitorFrames
  }
  let relevantEntries = externalEntries.filter { entry in
    targetMonitorFrames.isEmpty
      || targetMonitorFrames.contains { framesIntersect($0, entry.frame) }
  }
  let targetProcessID = relevantEntries.first(where: {
    $0.windowID == targetWindowID
  })?.processID
  // Untracked same-process helpers can appear during mouse-down. Known windows remain
  // occluders so a selected window's border cannot cover its app's dialogs.
  let frontmostNormalWindowID = relevantEntries.first { entry in
    entry.layer == NSWindow.Level.normal.rawValue
      && entry.frame.width * entry.frame.height >= minimumBorderOccludingWindowArea
      && (entry.windowID == targetWindowID
        || entry.processID != targetProcessID
        || knownWindowIDs.contains(entry.windowID))
  }?.windowID
  guard let targetWindowID,
    frontmostNormalWindowID == targetWindowID,
    let targetIndex = relevantEntries.firstIndex(where: {
      $0.windowID == targetWindowID
    })
  else {
    return .inactive(for: targetWindowID)
  }
  let upperBound = relevantEntries[..<targetIndex].last { entry in
    entry.layer > NSWindow.Level.normal.rawValue
      && entry.layer <= floatingLevel
  }
  return WindowBorderStacking(
    targetWindowID: targetWindowID,
    activeWindowIsFrontmost: true,
    upperBoundWindowID: upperBound?.windowID,
    upperBoundLevel: upperBound?.layer
  )
}

private func framesIntersect(_ lhs: Rect, _ rhs: Rect) -> Bool {
  lhs.x + lhs.width > rhs.x
    && lhs.x < rhs.x + rhs.width
    && lhs.y + lhs.height > rhs.y
    && lhs.y < rhs.y + rhs.height
}
