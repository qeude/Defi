import AppKit
import ApplicationServices
import CoreGraphics
import DefiModel

enum PlatformEventKind: Equatable {
  case application
  case applicationTerminated
  case focus
  case frame
  case windowCreated
  case windows
  case mouse
  case mouseRelease
  case screens
  case space
}

enum DesktopSessionEvent {
  case willSleep
  case didWake
  case screensDidSleep
  case screensDidWake
  case sessionDidResignActive
  case sessionDidBecomeActive
}

enum DesktopSessionActivityChange: Equatable {
  case becameInactive
  case becameActive
}

struct DesktopSessionState: Equatable {
  var systemAwake: Bool
  var screensAwake: Bool
  var sessionActive: Bool

  static let active = DesktopSessionState(
    systemAwake: true,
    screensAwake: true,
    sessionActive: true
  )

  var isActive: Bool {
    systemAwake && screensAwake && sessionActive
  }
}

struct DesktopSessionEventNormalizer {
  private var state: DesktopSessionState

  init(initialState: DesktopSessionState = .active) {
    state = initialState
  }

  mutating func consume(
    _ event: DesktopSessionEvent
  ) -> DesktopSessionActivityChange? {
    let wasActive = state.isActive
    switch event {
    case .willSleep:
      state.systemAwake = false
    case .didWake:
      state.systemAwake = true
    case .screensDidSleep:
      state.screensAwake = false
    case .screensDidWake:
      state.screensAwake = true
    case .sessionDidResignActive:
      state.sessionActive = false
    case .sessionDidBecomeActive:
      state.sessionActive = true
    }
    guard state.isActive != wasActive else { return nil }
    return state.isActive ? .becameActive : .becameInactive
  }
}

func currentDesktopSessionState() -> DesktopSessionState {
  let session = CGSessionCopyCurrentDictionary() as NSDictionary?
  let sessionActive =
    (session?[kCGSessionOnConsoleKey] as? Bool ?? true)
    && (session?[kCGSessionLoginDoneKey] as? Bool ?? true)

  var displayCount: UInt32 = 0
  var screensAwake = true
  if CGGetOnlineDisplayList(0, nil, &displayCount) == .success {
    var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    if CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)
      == .success
    {
      screensAwake =
        displayCount == 0
        || displayIDs.prefix(Int(displayCount)).contains {
          CGDisplayIsAsleep($0) == 0
        }
    }
  }

  return DesktopSessionState(
    systemAwake: true,
    screensAwake: screensAwake,
    sessionActive: sessionActive
  )
}

func platformEventCancelsMouseAnimation(_ kind: PlatformEventKind) -> Bool {
  kind == .mouse
}

func applicationLifecycleRefreshDelays(for kind: PlatformEventKind) -> [Int] {
  switch kind {
  case .application, .applicationTerminated:
    return [50, 150, 350, 700, 1_200, 2_000, 3_500, 5_500, 8_000, 12_000]
  case .focus, .frame, .windowCreated, .windows, .mouse, .mouseRelease, .screens,
    .space:
    return []
  }
}

func windowTopologyRefreshDelays(
  for kind: PlatformEventKind,
  latestInputTimestamp: TimeInterval?,
  latestCloseIntentTimestamp: TimeInterval,
  now: TimeInterval
) -> [Int] {
  guard let latestInputTimestamp,
    kind == .windowCreated,
    latestCloseIntentTimestamp < latestInputTimestamp,
    latestInputTimestamp <= now,
    now - latestInputTimestamp <= 1
  else { return [] }
  return [50, 150, 350]
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
  case .windowCreated, .windows, .applicationTerminated:
    return latestInputTimestamp
  case .application, .focus, .frame, .mouse, .mouseRelease, .screens, .space:
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
  guard let latestFocusIntent,
    latestFocusIntent.timestamp >= topologyInputTimestamp
  else {
    return latestInputTimestamp > topologyInputTimestamp
      && latestInputTimestamp > latestCloseIntentTimestamp
  }
  switch latestFocusIntent.source {
  case .keyboard:
    return true
  case .mouse(let windowID):
    guard let windowID else { return true }
    guard removedWindowIDs.contains(windowID) else { return true }
    return latestInputTimestamp > latestFocusIntent.timestamp
      && latestInputTimestamp > latestCloseIntentTimestamp
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
  case .windowCreated, .windows:
    return processID.map(WindowSnapshotInvalidation.process) ?? .full
  case .application, .applicationTerminated, .screens, .space:
    return .full
  case .focus, .frame, .mouse, .mouseRelease:
    return .none
  }
}
