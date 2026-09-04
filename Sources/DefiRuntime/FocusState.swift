import DefiConfig
import DefiCore
import DefiModel
import Foundation

public struct PendingAnimatedFocus: Equatable, Sendable {
  public let windowID: WindowID
  public let previousSelectedWindowID: WindowID?
  public let monitorID: MonitorID
  public let sourceWorkspaceID: WorkspaceID
  public let commandGeneration: UInt64
  public let focusInputTimestamp: TimeInterval
  public let cursorWarpInputTimestamp: TimeInterval?
  public let retryCount: Int

  public init(
    windowID: WindowID,
    previousSelectedWindowID: WindowID?,
    monitorID: MonitorID,
    sourceWorkspaceID: WorkspaceID,
    commandGeneration: UInt64,
    focusInputTimestamp: TimeInterval,
    cursorWarpInputTimestamp: TimeInterval?,
    retryCount: Int = 0
  ) {
    self.windowID = windowID
    self.previousSelectedWindowID = previousSelectedWindowID
    self.monitorID = monitorID
    self.sourceWorkspaceID = sourceWorkspaceID
    self.commandGeneration = commandGeneration
    self.focusInputTimestamp = focusInputTimestamp
    self.cursorWarpInputTimestamp = cursorWarpInputTimestamp
    self.retryCount = retryCount
  }
}

public struct PendingWorkspaceFocus: Equatable, Sendable {
  public let monitorID: MonitorID
  public let requestedWorkspaceID: WorkspaceID
  public let previousWorkspaceID: WorkspaceID?
  public let requestedWindowID: WindowID
  public let restoresPreviousWorkspaceOnCancellation: Bool
  public let commandGeneration: UInt64
  public let focusInputTimestamp: TimeInterval
  public let cursorWarpInputTimestamp: TimeInterval?
  public let retryCount: Int

  public init(
    monitorID: MonitorID,
    requestedWorkspaceID: WorkspaceID,
    previousWorkspaceID: WorkspaceID?,
    requestedWindowID: WindowID,
    restoresPreviousWorkspaceOnCancellation: Bool,
    commandGeneration: UInt64,
    focusInputTimestamp: TimeInterval,
    cursorWarpInputTimestamp: TimeInterval?,
    retryCount: Int = 0
  ) {
    self.monitorID = monitorID
    self.requestedWorkspaceID = requestedWorkspaceID
    self.previousWorkspaceID = previousWorkspaceID
    self.requestedWindowID = requestedWindowID
    self.restoresPreviousWorkspaceOnCancellation =
      restoresPreviousWorkspaceOnCancellation
    self.commandGeneration = commandGeneration
    self.focusInputTimestamp = focusInputTimestamp
    self.cursorWarpInputTimestamp = cursorWarpInputTimestamp
    self.retryCount = retryCount
  }
}

public enum DisplacedPointerFocusRecovery: Equatable, Sendable {
  case command(PendingAnimatedFocus, timestamp: TimeInterval)
  case workspace(PendingWorkspaceFocus, timestamp: TimeInterval)
}

public struct PendingPointerFocus: Equatable, Sendable {
  public let windowID: WindowID
  public let generation: UInt64
  public let timestamp: TimeInterval
  public let retryCount: Int

  public init(
    windowID: WindowID,
    generation: UInt64,
    timestamp: TimeInterval,
    retryCount: Int = 0
  ) {
    self.windowID = windowID
    self.generation = generation
    self.timestamp = timestamp
    self.retryCount = retryCount
  }
}

/// Transient focus state. Persisted workspace topology deliberately excludes it.
public struct FocusState: Equatable, Sendable {
  public private(set) var lastPointerWindowID: WindowID?
  private var nextSubmissionID: UInt64 = 0
  private var commandSubmission: FocusSubmissionID?
  private var workspaceSubmission: FocusSubmissionID?
  private var pointerSubmission: FocusSubmissionID?

  private mutating func nextSubmission() -> FocusSubmissionID {
    nextSubmissionID &+= 1
    return FocusSubmissionID(rawValue: nextSubmissionID)
  }

  public private(set) var pendingAnimatedFocus: PendingAnimatedFocus?
  public private(set) var submittedCommandFocus: PendingAnimatedFocus?
  public private(set) var pendingWorkspaceFocus: PendingWorkspaceFocus?
  public private(set) var submittedWorkspaceFocusGeneration: UInt64?
  public private(set) var displacedPointerFocusRecovery: DisplacedPointerFocusRecovery?
  public private(set) var submittedPointerFocus: PendingPointerFocus?
  public private(set) var pendingPointerFocus: PendingPointerFocus?
  public private(set) var pointerFocusGeneration: UInt64 = 0

  public init() {}

  public mutating func queueCommand(_ request: PendingAnimatedFocus?) {
    pendingAnimatedFocus = request
  }

  @discardableResult
  public mutating func submitCommand(_ request: PendingAnimatedFocus) -> FocusSubmissionID {
    pendingAnimatedFocus = nil
    submittedCommandFocus = request
    let submission = nextSubmission()
    commandSubmission = submission
    return submission
  }

  public mutating func cancelSubmittedCommand() {
    submittedCommandFocus = nil
    commandSubmission = nil
  }

  public mutating func queueWorkspace(_ request: PendingWorkspaceFocus?) {
    pendingWorkspaceFocus = request
    submittedWorkspaceFocusGeneration = nil
    workspaceSubmission = nil
  }

  public mutating func cancelSubmittedWorkspace() {
    submittedWorkspaceFocusGeneration = nil
    workspaceSubmission = nil
  }

  @discardableResult
  public mutating func submitWorkspace(_ request: PendingWorkspaceFocus) -> FocusSubmissionID {
    pendingWorkspaceFocus = request
    submittedWorkspaceFocusGeneration = request.commandGeneration
    let submission = nextSubmission()
    workspaceSubmission = submission
    return submission
  }

  public func workspaceCompletionIsCurrent(
    _ request: PendingWorkspaceFocus, submission: FocusSubmissionID
  ) -> Bool {
    workspaceSubmission == submission && pendingWorkspaceFocus == request
  }

  public mutating func rearmPointer() {
    lastPointerWindowID = nil
  }

  public mutating func observePointer(
    windowID: WindowID?,
    timestamp: TimeInterval,
    latestInputTimestamp: TimeInterval,
    ready: Bool,
    restoresNativeFocus: Bool,
    activeMonitorID: MonitorID?,
    viewports: [MonitorID: Rect],
    input: InputConfig,
    state: RuntimeState
  ) -> PointerFocusIntentEffect {
    guard
      pointerFocusIntentIsCurrent(
        pointerTimestamp: timestamp, latestUserInputTimestamp: latestInputTimestamp
      )
    else {
      invalidatePointer()
      return .stale
    }
    guard lastPointerWindowID != windowID else { return .redundant }
    lastPointerWindowID = windowID
    let logicalFocus = activeMonitorID.flatMap { state.selectedWindowID(on: $0) }
    let recovery: WindowID?
    if !input.focusFollowsMouse {
      recovery = logicalFocus
    } else {
      let managed = windowID.flatMap { state.monitorID(containing: $0) } != nil
      let accepted =
        windowID.flatMap { id in
          managed && ready
            ? pointerFocusMonitor(
              id, activeMonitorID: activeMonitorID, state: state,
              viewports: viewports, maximumScrollAmount: input.focusFollowsMouseMaxScrollAmount,
              acceptsAlreadySelectedWindow: restoresNativeFocus
            ) : nil
        } != nil
      recovery = pointerFocusRecoveryWindowID(
        pointerWindowIsManaged: managed,
        pointerWindowIsReady: ready,
        targetAccepted: accepted,
        logicalFocusWindowID: logicalFocus
      )
    }
    invalidatePointer()
    guard input.focusFollowsMouse, let windowID else {
      return .changed(recoveringTo: recovery, request: nil)
    }
    let request = PendingPointerFocus(
      windowID: windowID, generation: pointerFocusGeneration, timestamp: timestamp
    )
    guard ready else {
      pendingPointerFocus = request
      return .changed(recoveringTo: recovery, request: nil)
    }
    return .changed(recoveringTo: recovery, request: request)
  }

  public mutating func resumePointer(
    latestInputTimestamp: TimeInterval,
    ready: Bool,
    windowUnderPointerID: WindowID?
  ) -> PointerFocusResumeEffect {
    guard let request = pendingPointerFocus else { return .waiting }
    guard
      pointerFocusRequestIsCurrent(
        requestGeneration: request.generation, currentGeneration: pointerFocusGeneration,
        pointerTimestamp: request.timestamp, latestUserInputTimestamp: latestInputTimestamp
      )
    else {
      invalidatePointer()
      return .stale
    }
    guard ready else { return .waiting }
    pendingPointerFocus = nil
    guard
      pointerFocusRetryIsCurrent(
        pendingWindowID: request.windowID, windowUnderPointerID: windowUnderPointerID,
        requestGeneration: request.generation, currentGeneration: pointerFocusGeneration,
        pointerTimestamp: request.timestamp, latestUserInputTimestamp: latestInputTimestamp
      )
    else { return .stale }
    return .ready(request)
  }

  public mutating func invalidatePointer() {
    pointerFocusGeneration &+= 1
    pendingPointerFocus = nil
    submittedPointerFocus = nil
    pointerSubmission = nil
  }

  public mutating func discardDisplacedFocus() {
    displacedPointerFocusRecovery = nil
  }

  public mutating func displaceCommandFocus(at timestamp: TimeInterval) {
    if let command = pendingAnimatedFocus ?? submittedCommandFocus {
      displacedPointerFocusRecovery = .command(command, timestamp: timestamp)
    } else if let workspace = pendingWorkspaceFocus {
      displacedPointerFocusRecovery = .workspace(workspace, timestamp: timestamp)
    }
    pendingAnimatedFocus = nil
    pendingWorkspaceFocus = nil
    submittedWorkspaceFocusGeneration = nil
    workspaceSubmission = nil
  }

  public func commandCompletionIsCurrent(
    _ request: PendingAnimatedFocus, submission: FocusSubmissionID
  ) -> Bool {
    commandSubmission == submission && submittedCommandFocus == request
  }

  public mutating func completeCommand(
    _ request: PendingAnimatedFocus,
    submission: FocusSubmissionID,
    result: NativeFocusResult,
    commandGeneration: UInt64,
    keepsRequestedWindow: Bool,
    state: inout RuntimeState
  ) -> FocusCompletionEffect {
    guard commandCompletionIsCurrent(request, submission: submission) else { return .stale }
    submittedCommandFocus = nil
    commandSubmission = nil
    if result == .failed || result == .failedAfterMutation,
      let retryCount = nextCommandFocusRetryCount(
        currentRetryCount: request.retryCount,
        maximumRetryCount: 1,
        requestGeneration: request.commandGeneration,
        currentGeneration: commandGeneration,
        requestedWindowID: request.windowID,
        selectedWindowID: state.selectedWindowID(on: request.monitorID)
      )
    {
      pendingAnimatedFocus = PendingAnimatedFocus(
        windowID: request.windowID,
        previousSelectedWindowID: request.previousSelectedWindowID,
        monitorID: request.monitorID,
        sourceWorkspaceID: request.sourceWorkspaceID,
        commandGeneration: request.commandGeneration,
        focusInputTimestamp: request.focusInputTimestamp,
        cursorWarpInputTimestamp: request.cursorWarpInputTimestamp,
        retryCount: retryCount
      )
      return .settled
    }
    guard !keepsRequestedWindow,
      let fallback = commandFocusCancellationFallback(
        cancelledBeforeMutation: result == .cancelled || result == .failed,
        rollbackAfterMutation: result.requiresLogicalRollback,
        requestGeneration: request.commandGeneration,
        currentGeneration: commandGeneration,
        requestedWindowID: request.windowID,
        selectedWindowID: state.selectedWindowID(on: request.monitorID),
        previousSelectedWindowID: request.previousSelectedWindowID,
        sourceWorkspaceID: request.sourceWorkspaceID,
        previousSelectedWindowWorkspaceID: request.previousSelectedWindowID.flatMap {
          state.location(containing: $0)?.workspaceID
        }
      ),
      state.location(containing: fallback)?.monitorID == request.monitorID
    else { return .settled }
    _ = focusWindow(fallback, state: &state)
    return .selectionChanged(request.monitorID)
  }

  public mutating func completeWorkspace(
    _ request: PendingWorkspaceFocus,
    submission: FocusSubmissionID,
    result: NativeFocusResult,
    commandGeneration: UInt64,
    keepsRequestedWindow: Bool,
    state: inout RuntimeState
  ) -> FocusCompletionEffect {
    guard workspaceCompletionIsCurrent(request, submission: submission) else { return .stale }
    submittedWorkspaceFocusGeneration = nil
    workspaceSubmission = nil
    if result == .frameSuperseded { return .settled }
    if result == .failed || result == .failedAfterMutation,
      let retryCount = nextCommandFocusRetryCount(
        currentRetryCount: request.retryCount,
        maximumRetryCount: 1,
        requestGeneration: request.commandGeneration,
        currentGeneration: commandGeneration,
        requestedWindowID: request.requestedWindowID,
        selectedWindowID: state.selectedWindowID(on: request.monitorID)
      )
    {
      pendingWorkspaceFocus = PendingWorkspaceFocus(
        monitorID: request.monitorID,
        requestedWorkspaceID: request.requestedWorkspaceID,
        previousWorkspaceID: request.previousWorkspaceID,
        requestedWindowID: request.requestedWindowID,
        restoresPreviousWorkspaceOnCancellation: request.restoresPreviousWorkspaceOnCancellation,
        commandGeneration: request.commandGeneration,
        focusInputTimestamp: request.focusInputTimestamp,
        cursorWarpInputTimestamp: request.cursorWarpInputTimestamp,
        retryCount: retryCount
      )
      return .settled
    }
    pendingWorkspaceFocus = nil
    guard !keepsRequestedWindow,
      let monitor = state.monitors.first(where: { $0.id == request.monitorID }),
      let fallback = workspaceFocusCancellationFallback(
        cancelledBeforeMutation: result == .cancelled || result == .failed,
        rollbackAfterMutation: result.requiresLogicalRollback,
        requestGeneration: request.commandGeneration,
        currentGeneration: commandGeneration,
        requestedWorkspaceID: request.requestedWorkspaceID,
        activeWorkspaceID: monitor.activeWorkspace,
        previousWorkspaceID: request.previousWorkspaceID,
        requestedWindowID: request.requestedWindowID,
        selectedWindowID: state.selectedWindowID(on: request.monitorID),
        restoresPreviousWorkspace: request.restoresPreviousWorkspaceOnCancellation
      )
    else { return .settled }
    do {
      try reduce(.switchWorkspace(fallback), on: request.monitorID, state: &state)
      return .selectionChanged(request.monitorID)
    } catch {
      return .settled
    }
  }

  public mutating func rebind(
    using replacements: [WindowID: WindowID],
    workspaceWritePending: Bool
  ) -> (command: WindowID?, workspace: WindowID?) {
    guard !replacements.isEmpty else { return (nil, nil) }
    var commandTarget: WindowID?
    var workspaceTarget: WindowID?
    if let submittedCommandFocus {
      let rebound = reboundPendingAnimatedFocus(submittedCommandFocus, using: replacements)
      if rebound != submittedCommandFocus {
        commandTarget = rebound.windowID
        self.submittedCommandFocus = nil
        pendingAnimatedFocus = rebound
      }
    }
    pendingAnimatedFocus = pendingAnimatedFocus.map {
      reboundPendingAnimatedFocus($0, using: replacements)
    }
    if let pendingWorkspaceFocus {
      let rebound = reboundPendingWorkspaceFocus(pendingWorkspaceFocus, using: replacements)
      if rebound != pendingWorkspaceFocus,
        submittedWorkspaceFocusGeneration != nil || workspaceWritePending
      {
        workspaceTarget = rebound.requestedWindowID
        submittedWorkspaceFocusGeneration = nil
        workspaceSubmission = nil
      }
      self.pendingWorkspaceFocus = rebound
    }
    displacedPointerFocusRecovery = displacedPointerFocusRecovery.map {
      reboundDisplacedPointerFocusRecovery($0, using: replacements)
    }
    return (commandTarget, workspaceTarget)
  }

  @discardableResult
  public mutating func submitPointer(_ request: PendingPointerFocus) -> FocusSubmissionID {
    pendingPointerFocus = nil
    submittedPointerFocus = request
    displaceCommandFocus(at: request.timestamp)
    let submission = nextSubmission()
    pointerSubmission = submission
    return submission
  }

  public mutating func completePointer(
    _ request: PendingPointerFocus,
    submission: FocusSubmissionID,
    result: NativeFocusResult,
    latestInputTimestamp: TimeInterval,
    windowUnderPointerID: WindowID?,
    commandGeneration: UInt64,
    activeMonitorID: MonitorID?,
    viewports: [MonitorID: Rect],
    maximumScrollAmount: Double?,
    acceptsAlreadySelectedWindow: Bool,
    state: inout RuntimeState
  ) -> PointerFocusCompletionEffect {
    guard pointerSubmission == submission, submittedPointerFocus == request else { return .stale }
    submittedPointerFocus = nil
    pointerSubmission = nil
    guard
      pointerFocusRequestIsCurrent(
        requestGeneration: request.generation,
        currentGeneration: pointerFocusGeneration,
        pointerTimestamp: request.timestamp,
        latestUserInputTimestamp: latestInputTimestamp
      )
    else { return .ignored(rearm: true) }

    if result == .completed || result == .completedWithoutMutation {
      let previousSelection = activeMonitorID.flatMap { state.selectedWindowID(on: $0) }
      guard
        let monitorID = focusWindowFromPointer(
          request.windowID,
          activeMonitorID: activeMonitorID,
          state: &state,
          viewports: viewports,
          maximumScrollAmount: maximumScrollAmount,
          acceptsAlreadySelectedWindow: acceptsAlreadySelectedWindow
        )
      else { return .recover(previousSelection) }
      displacedPointerFocusRecovery = nil
      return .selectionChanged(monitorID)
    }
    guard result == .failed || result == .failedAfterMutation else {
      return .ignored(
        rearm: cancelledPointerFocusShouldRearm(
          pointerTimestamp: request.timestamp,
          latestUserInputTimestamp: latestInputTimestamp
        ))
    }
    let intentCurrent = pointerFocusRetryIsCurrent(
      pendingWindowID: request.windowID,
      windowUnderPointerID: windowUnderPointerID,
      requestGeneration: request.generation,
      currentGeneration: pointerFocusGeneration,
      pointerTimestamp: request.timestamp,
      latestUserInputTimestamp: latestInputTimestamp
    )
    if let retryCount = nextPointerFocusRetryCount(
      currentRetryCount: request.retryCount,
      maximumRetryCount: 1,
      intentCurrent: intentCurrent
    ) {
      pendingPointerFocus = PendingPointerFocus(
        windowID: request.windowID,
        generation: request.generation,
        timestamp: request.timestamp,
        retryCount: retryCount
      )
      return .ignored(rearm: false)
    }
    if result == .failed, intentCurrent {
      restoreDisplacedFocus(
        at: request.timestamp, commandGeneration: commandGeneration, state: state)
      return .resumeDisplaced
    }
    displacedPointerFocusRecovery = nil
    return .refresh
  }

  private mutating func restoreDisplacedFocus(
    at timestamp: TimeInterval,
    commandGeneration: UInt64,
    state: RuntimeState
  ) {
    guard let recovery = displacedPointerFocusRecovery else { return }
    displacedPointerFocusRecovery = nil
    switch recovery {
    case .command(let request, _):
      guard commandGeneration == request.commandGeneration,
        state.selectedWindowID(on: request.monitorID) == request.windowID
      else { return }
      pendingAnimatedFocus = PendingAnimatedFocus(
        windowID: request.windowID,
        previousSelectedWindowID: request.previousSelectedWindowID,
        monitorID: request.monitorID,
        sourceWorkspaceID: request.sourceWorkspaceID,
        commandGeneration: commandGeneration,
        focusInputTimestamp: timestamp,
        cursorWarpInputTimestamp: nil,
        retryCount: request.retryCount
      )
    case .workspace(let request, _):
      guard commandGeneration == request.commandGeneration,
        state.monitors.first(where: { $0.id == request.monitorID })?.activeWorkspace
          == request.requestedWorkspaceID,
        state.selectedWindowID(on: request.monitorID) == request.requestedWindowID
      else { return }
      pendingWorkspaceFocus = PendingWorkspaceFocus(
        monitorID: request.monitorID,
        requestedWorkspaceID: request.requestedWorkspaceID,
        previousWorkspaceID: request.previousWorkspaceID,
        requestedWindowID: request.requestedWindowID,
        restoresPreviousWorkspaceOnCancellation: request.restoresPreviousWorkspaceOnCancellation,
        commandGeneration: commandGeneration,
        focusInputTimestamp: timestamp,
        cursorWarpInputTimestamp: nil,
        retryCount: request.retryCount
      )
      submittedWorkspaceFocusGeneration = nil
      workspaceSubmission = nil
    }
  }

  public mutating func requeueDisplacedPointerFocusAfterDisplayChange(
    _ recovery: DisplacedPointerFocusRecovery,
    state: RuntimeState
  ) {
    switch recovery {
    case .command(let request, let timestamp):
      guard
        let monitorID = state.reboundFocusMonitorID(
          for: request.windowID
        )
      else { return }
      pendingAnimatedFocus = PendingAnimatedFocus(
        windowID: request.windowID,
        previousSelectedWindowID: request.previousSelectedWindowID,
        monitorID: monitorID,
        sourceWorkspaceID: request.sourceWorkspaceID,
        commandGeneration: request.commandGeneration,
        focusInputTimestamp: pointerDisplacedFocusInputTimestamp(
          commandInputTimestamp: request.focusInputTimestamp,
          pointerInputTimestamp: timestamp
        ),
        cursorWarpInputTimestamp: nil,
        retryCount: request.retryCount
      )
    case .workspace(let request, let timestamp):
      guard
        let monitorID = state.reboundFocusMonitorID(
          for: request.requestedWindowID,
          requestedWorkspaceID: request.requestedWorkspaceID
        )
      else { return }
      pendingWorkspaceFocus = PendingWorkspaceFocus(
        monitorID: monitorID,
        requestedWorkspaceID: request.requestedWorkspaceID,
        previousWorkspaceID: request.previousWorkspaceID,
        requestedWindowID: request.requestedWindowID,
        restoresPreviousWorkspaceOnCancellation:
          request.restoresPreviousWorkspaceOnCancellation,
        commandGeneration: request.commandGeneration,
        focusInputTimestamp: pointerDisplacedFocusInputTimestamp(
          commandInputTimestamp: request.focusInputTimestamp,
          pointerInputTimestamp: timestamp
        ),
        cursorWarpInputTimestamp: nil,
        retryCount: request.retryCount
      )
      submittedWorkspaceFocusGeneration = nil
      workspaceSubmission = nil
    }
  }

  public mutating func requeuePreservedFocusAfterMonitorRetention(
    command: PendingAnimatedFocus?,
    workspace: PendingWorkspaceFocus?,
    displaced: DisplacedPointerFocusRecovery?,
    state: RuntimeState
  ) {
    if let displaced {
      requeueDisplacedPointerFocusAfterDisplayChange(displaced, state: state)
      return
    }
    if let command,
      let monitorID = state.reboundFocusMonitorID(for: command.windowID)
    {
      pendingAnimatedFocus = PendingAnimatedFocus(
        windowID: command.windowID,
        previousSelectedWindowID: command.previousSelectedWindowID,
        monitorID: monitorID,
        sourceWorkspaceID: command.sourceWorkspaceID,
        commandGeneration: command.commandGeneration,
        focusInputTimestamp: command.focusInputTimestamp,
        cursorWarpInputTimestamp: command.cursorWarpInputTimestamp,
        retryCount: command.retryCount
      )
    }
    if let workspace,
      let monitorID = state.reboundFocusMonitorID(
        for: workspace.requestedWindowID,
        requestedWorkspaceID: workspace.requestedWorkspaceID
      )
    {
      pendingWorkspaceFocus = PendingWorkspaceFocus(
        monitorID: monitorID,
        requestedWorkspaceID: workspace.requestedWorkspaceID,
        previousWorkspaceID: workspace.previousWorkspaceID,
        requestedWindowID: workspace.requestedWindowID,
        restoresPreviousWorkspaceOnCancellation:
          workspace.restoresPreviousWorkspaceOnCancellation,
        commandGeneration: workspace.commandGeneration,
        focusInputTimestamp: workspace.focusInputTimestamp,
        cursorWarpInputTimestamp: workspace.cursorWarpInputTimestamp,
        retryCount: workspace.retryCount
      )
      submittedWorkspaceFocusGeneration = nil
      workspaceSubmission = nil
    }
  }

}

public enum FocusCompletionEffect: Equatable, Sendable {
  case stale
  case settled
  case selectionChanged(MonitorID)
}

extension NativeFocusResult {
  fileprivate var requiresLogicalRollback: Bool {
    self == .failedAfterMutation || self == .cancelledAfterInputMutation
  }
}

func reboundPendingAnimatedFocus(
  _ request: PendingAnimatedFocus,
  using replacements: [WindowID: WindowID]
) -> PendingAnimatedFocus {
  PendingAnimatedFocus(
    windowID: replacements[request.windowID] ?? request.windowID,
    previousSelectedWindowID: request.previousSelectedWindowID.map {
      replacements[$0] ?? $0
    },
    monitorID: request.monitorID,
    sourceWorkspaceID: request.sourceWorkspaceID,
    commandGeneration: request.commandGeneration,
    focusInputTimestamp: request.focusInputTimestamp,
    cursorWarpInputTimestamp: request.cursorWarpInputTimestamp,
    retryCount: request.retryCount
  )
}

func reboundPendingWorkspaceFocus(
  _ request: PendingWorkspaceFocus,
  using replacements: [WindowID: WindowID]
) -> PendingWorkspaceFocus {
  PendingWorkspaceFocus(
    monitorID: request.monitorID,
    requestedWorkspaceID: request.requestedWorkspaceID,
    previousWorkspaceID: request.previousWorkspaceID,
    requestedWindowID:
      replacements[request.requestedWindowID] ?? request.requestedWindowID,
    restoresPreviousWorkspaceOnCancellation:
      request.restoresPreviousWorkspaceOnCancellation,
    commandGeneration: request.commandGeneration,
    focusInputTimestamp: request.focusInputTimestamp,
    cursorWarpInputTimestamp: request.cursorWarpInputTimestamp,
    retryCount: request.retryCount
  )
}

func reboundDisplacedPointerFocusRecovery(
  _ recovery: DisplacedPointerFocusRecovery,
  using replacements: [WindowID: WindowID]
) -> DisplacedPointerFocusRecovery {
  switch recovery {
  case .command(let request, let timestamp):
    .command(
      reboundPendingAnimatedFocus(request, using: replacements),
      timestamp: timestamp
    )
  case .workspace(let request, let timestamp):
    .workspace(
      reboundPendingWorkspaceFocus(request, using: replacements),
      timestamp: timestamp
    )
  }
}

public enum PointerFocusCompletionEffect: Equatable, Sendable {
  case stale
  case ignored(rearm: Bool)
  case recover(WindowID?)
  case selectionChanged(MonitorID)
  case resumeDisplaced
  case refresh
}

/// Identifies one attempt, independently of the human command that requested it.
public struct FocusSubmissionID: Equatable, Sendable {
  fileprivate let rawValue: UInt64
}

public enum PointerFocusIntentEffect: Equatable, Sendable {
  case stale
  case redundant
  case changed(recoveringTo: WindowID?, request: PendingPointerFocus?)
}

public enum PointerFocusResumeEffect: Equatable, Sendable {
  case waiting
  case stale
  case ready(PendingPointerFocus)
}
