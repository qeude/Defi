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
  public struct Snapshot: Equatable, Sendable {
    public let latestEventTimestamp: TimeInterval
    public let latestFocusIntent: TimeInterval
    public let latestCloseIntent: TimeInterval
  }

  private let lock = NSLock()
  private var latestTimestamp: TimeInterval = 0
  private var latestFocusIntentTimestamp: TimeInterval = 0
  private var latestCloseIntentTimestamp: TimeInterval = 0

  public init() {}

  public func record(
    timestamp: TimeInterval,
    focusIntent: Bool = false,
    closeIntent: Bool = false
  ) {
    lock.lock()
    latestTimestamp = max(latestTimestamp, timestamp)
    if focusIntent {
      latestFocusIntentTimestamp = max(latestFocusIntentTimestamp, timestamp)
    }
    if closeIntent {
      latestCloseIntentTimestamp = max(latestCloseIntentTimestamp, timestamp)
    }
    lock.unlock()
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
      latestFocusIntent: latestFocusIntentTimestamp,
      latestCloseIntent: latestCloseIntentTimestamp
    )
  }
}

func userInputOccurredAfterWindowTopology(
  topologyInputTimestamp: TimeInterval?,
  latestInputTimestamp: TimeInterval,
  latestFocusIntentTimestamp: TimeInterval = 0,
  latestCloseIntentTimestamp: TimeInterval = 0
) -> Bool {
  guard let topologyInputTimestamp else { return false }
  return latestInputTimestamp > topologyInputTimestamp
    || (latestFocusIntentTimestamp >= topologyInputTimestamp
      && latestFocusIntentTimestamp > latestCloseIntentTimestamp)
}

func guardedFocusIsCurrent(
  latestInputTimestamp: TimeInterval,
  maximumInputTimestamp: TimeInterval
) -> Bool {
  latestInputTimestamp <= maximumInputTimestamp
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
