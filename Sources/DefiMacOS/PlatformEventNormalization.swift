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
  case screens
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

  private let lock = NSLock()
  private var latestTimestamp: TimeInterval = 0
  private var latestFocusIntent: FocusIntent?
  private var latestCloseIntentTimestamp: TimeInterval = 0
  private var observedFocusIntentTimestamp: TimeInterval = 0
  private var observedFocusWindowID: WindowID?
  private var observedFocusProcessID: pid_t?

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
      focusIntent.timestamp > observedFocusIntentTimestamp
        || (focusIntent.timestamp == observedFocusIntentTimestamp
          && observedFocusWindowID == nil && windowID != nil)
    else {
      lock.unlock()
      return
    }
    observedFocusIntentTimestamp = focusIntent.timestamp
    observedFocusWindowID = windowID
    observedFocusProcessID = processID
    lock.unlock()
  }

  public func focusRecoveryTarget(
    after timestamp: TimeInterval
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
      return FocusRecoveryTarget(
        timestamp: focusIntent.timestamp,
        windowID: observedFocusWindowID,
        processID: observedFocusProcessID
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

func windowSnapshotInvalidation(
  for kind: PlatformEventKind,
  processID: pid_t?
) -> WindowSnapshotInvalidation {
  switch kind {
  case .windows, .applicationTerminated:
    return processID.map(WindowSnapshotInvalidation.process) ?? .full
  case .application, .screens:
    return .full
  case .focus, .frame, .mouse:
    return .none
  }
}

struct MouseGestureEventNormalizer {
  struct Actions: Equatable {
    var refreshBorderStacking = false
    var synchronizeDesktop = false
  }

  private var moved = false
  private var synchronizedDuringGesture = false

  mutating func actions(
    for eventType: NSEvent.EventType
  ) -> Actions {
    switch eventType {
    case .leftMouseDown:
      moved = false
      synchronizedDuringGesture = false
      return Actions(refreshBorderStacking: true)
    case .leftMouseDragged:
      moved = true
      guard synchronizedDuringGesture == false else {
        return Actions()
      }
      synchronizedDuringGesture = true
      return Actions(synchronizeDesktop: true)
    case .leftMouseUp:
      defer {
        moved = false
        synchronizedDuringGesture = false
      }
      return Actions(synchronizeDesktop: moved)
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
