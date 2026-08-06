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
  if hasUnknownEventProcess { return true }
  guard let focusedProcessID else { return false }
  return eventProcessIDs.contains(focusedProcessID)
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

struct NormalWindowStackEntry: Equatable {
  let windowID: WindowID
  let frame: Rect
}

private let minimumBorderOccludingWindowArea = 2_048.0

func frontmostBorderOccludingWindowID(
  in entries: [NormalWindowStackEntry]
) -> WindowID? {
  // AppKit and Electron can create tiny normal-level helper surfaces on mouse-down.
  entries.first { entry in
    entry.frame.width * entry.frame.height >= minimumBorderOccludingWindowArea
  }?.windowID
}
