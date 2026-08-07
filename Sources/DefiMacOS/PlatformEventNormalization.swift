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
    excludingProcessID: pid_t? = nil
  ) -> FocusRecoveryTarget? {
    lock.lock()
    defer { lock.unlock() }
    guard let focusIntent = latestFocusIntent,
      focusIntent.timestamp > timestamp,
      focusIntent.timestamp > latestCloseIntentTimestamp
    else {
      return nil
    }
    switch focusIntent.source {
    case .keyboard:
      guard observedFocusIntentTimestamp == focusIntent.timestamp else {
        return nil
      }
      guard
        let target = observedFocusTargets.reversed().first(where: {
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
      else {
        return nil
      }
      return FocusRecoveryTarget(
        timestamp: focusIntent.timestamp,
        windowID: target.windowID,
        processID: target.processID
      )
    case .mouse(let windowID):
      guard let windowID else { return nil }
      return FocusRecoveryTarget(
        timestamp: focusIntent.timestamp,
        windowID: windowID,
        processID: nil
      )
    }
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

func mouseFocusIntentWindowID(rawWindowID: Int64) -> WindowID? {
  guard rawWindowID > 0 else { return nil }
  return WindowID(rawValue: UInt64(rawWindowID))
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
  case .windows, .applicationTerminated:
    return processID.map(WindowSnapshotInvalidation.process) ?? .full
  case .application, .screens:
    return .full
  case .focus, .frame, .mouse, .mouseRelease:
    return .none
  }
}

struct MouseGestureEventNormalizer {
  enum Synchronization: Equatable {
    case gesture
    case clickRelease
  }

  struct Actions: Equatable {
    var refreshBorderStacking = false
    var startsGesture = false
    var synchronization: Synchronization?
  }

  private var pressed = false
  private var dragged = false

  mutating func actions(
    for eventType: NSEvent.EventType
  ) -> Actions {
    switch eventType {
    case .leftMouseDown:
      pressed = true
      dragged = false
      return Actions(refreshBorderStacking: true, startsGesture: true)
    case .leftMouseDragged:
      dragged = true
      // Platform sync demand is a Boolean, so repeated drag events coalesce
      // while still scheduling fresh snapshots after live reorder animations.
      return Actions(synchronization: .gesture)
    case .leftMouseUp:
      defer {
        pressed = false
        dragged = false
      }
      guard pressed else { return Actions() }
      return Actions(synchronization: dragged ? .gesture : .clickRelease)
    default:
      return Actions()
    }
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
