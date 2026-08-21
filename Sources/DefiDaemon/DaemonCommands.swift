import AppKit
import DefiConfig
import DefiCore
import DefiIPC
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation
import OSLog

private func ipcEventHandler(
  server: UnixSocketServer,
  clientQueue: DispatchQueue,
  daemon: Daemon
) -> @Sendable () -> Void {
  { [weak daemon] in
    do {
      for _ in 0..<16 {
        let handled = try server.poll(
          on: clientQueue,
          handler: { request in
            DispatchQueue.main.sync {
              MainActor.assumeIsolated {
                daemon?.handle(
                  request.command,
                  monitorIndex: request.monitorIndex
                ) ?? .failure("daemon unavailable")
              }
            }
          },
          completion: { [weak daemon] request in
            guard request.command == "quit" else { return }
            DispatchQueue.main.async {
              guard let daemon, daemon.shouldShutdown else { return }
              daemon.shutdown()
            }
          }
        )
        if !handled { break }
      }
    } catch {
      let message = "IPC error: \(error)"
      DispatchQueue.main.async { [weak daemon] in
        daemon?.log(message)
      }
    }
  }
}

func commandFollowUpIsPending(
  frameWrites: Bool,
  animatedFocus: Bool,
  workspaceFocus: Bool
) -> Bool {
  frameWrites || animatedFocus || workspaceFocus
}

func crossMonitorCommandWindowID(
  _ command: Command,
  selectedWindowID: WindowID?,
  selectedTiledWindowID: WindowID?
) -> WindowID? {
  if case .moveColumnToMonitor = command { return selectedTiledWindowID }
  return selectedWindowID
}

func commandDiagnosticMetadata(
  command: String,
  generation: UInt64,
  inputTimestamp: TimeInterval,
  monitorID: MonitorID?,
  selectedWindowID: WindowID?,
  state: RuntimeState,
  commandStartedAt: TimeInterval? = nil
) -> CommandDiagnosticMetadata {
  let monitor = monitorID.flatMap { id in
    state.monitors.first(where: { $0.id == id })
  }
  let window = selectedWindowID.flatMap { state.windows[$0] }
  let queueWaitMS = commandStartedAt.map { startedAt in
    max(startedAt - inputTimestamp, 0) * 1_000
  }
  return CommandDiagnosticMetadata(
    timestamp: Date(),
    inputTimestamp: inputTimestamp,
    command: command,
    generation: generation,
    monitorID: monitorID,
    workspaceID: monitor?.activeWorkspace,
    windowID: selectedWindowID,
    applicationID: window?.appID,
    processID: window?.processID,
    queueWaitMS: queueWaitMS
  )
}

@MainActor
extension Daemon {
  func installIPCSource() {
    let server = server
    let clientQueue = DispatchQueue(
      label: "com.quentin.defi.ipc.clients",
      qos: .userInitiated,
      attributes: .concurrent
    )
    let source = DispatchSource.makeReadSource(
      fileDescriptor: server.listeningFileDescriptor,
      queue: DispatchQueue(label: "com.quentin.defi.ipc.accept", qos: .userInitiated)
    )
    source.setEventHandler(
      handler: ipcEventHandler(
        server: server,
        clientQueue: clientQueue,
        daemon: self
      )
    )
    source.resume()
    ipcSource = source
  }

  func scheduleTick() {
    guard !tickScheduled else { return }
    tickScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.tickScheduled = false
      self.tick()
    }
  }

  func enqueueHotKey(_ invocation: HotKeyInvocation) {
    guard pendingHotKeyCommands.count < 64 else { return }
    pendingHotKeyCommands.append(invocation)
    processPendingHotKeys()
  }

  func processPendingHotKeys() {
    guard !processingHotKeyCommands else { return }
    processingHotKeyCommands = true
    defer { processingHotKeyCommands = false }
    for _ in 0..<min(pendingHotKeyCommands.count, 8) {
      let invocation = pendingHotKeyCommands.removeFirst()
      _ = handle(
        invocation.command,
        inputTimestamp: invocation.timestamp
      )
      processedHotKeyCount += 1
    }
  }

  @discardableResult
  func handle(
    _ rawCommand: String,
    monitorIndex: Int? = nil,
    inputTimestamp: TimeInterval? = nil
  ) -> CommandResponse {
    if rawCommand == "list-workspaces" {
      return .success(state.workspaceNames.map(\.rawValue).joined(separator: "\n"))
    }
    if rawCommand == "list-workspaces --json" {
      do {
        return .success(try workspaceStateJSON())
      } catch {
        return .failure(String(describing: error))
      }
    }
    if let response = handleReservedAreaCommand(
      rawCommand,
      monitorIndex: monitorIndex
    ) {
      return response
    }
    if rawCommand == "status" {
      return .success(status())
    }
    if rawCommand == "trace" {
      return .success(platform.frameCoordinatorTrace)
    }
    if rawCommand == "diagnostic-mark" {
      diagnostics.mark(status: status(), trace: platform.frameCoordinatorTrace)
      return .success("marked \(diagnostics.currentFileURL.path)")
    }
    if rawCommand == "restore" {
      restoreAllWindows()
      return .success("restored")
    }
    if rawCommand == "quit" {
      shouldShutdown = true
      return .success("stopping")
    }
    do {
      let commandStartedAt = ProcessInfo.processInfo.systemUptime
      let command = try parseCommand(rawCommand)
      let commandMonitorID: MonitorID?
      if let monitorIndex {
        guard let monitorID = monitorID(atAppKitIndex: monitorIndex) else {
          return .failure("unknown monitor index: \(monitorIndex)")
        }
        commandMonitorID = monitorID
      } else {
        commandMonitorID = activeMonitorID ?? state.monitors.first?.id
      }
      let commandInputTimestamp = inputTimestamp ?? commandStartedAt
      platform.userInputTracker.record(timestamp: commandInputTimestamp)
      let physicalMonitorFrames = Dictionary(
        uniqueKeysWithValues: latestMonitors.map { ($0.id, $0.physicalFrame) }
      )
      let commandViewports = viewportsByMonitor
      // When frames are already in flight the reducer must run on the live
      // state after the displayed-frame rebase, so skip the validation copy.
      let rebasesPendingFrame =
        !scrollAnimations.isEmpty || platform.hasPendingAnimatedFrameWrites
      let validationState = try rebasesPendingFrame
        ? nil
        : changedState(
          after: command,
          on: commandMonitorID,
          from: state,
          monitorFrames: physicalMonitorFrames,
          viewports: commandViewports
        )
      if validationState == nil, command.explicitlyFocusesFloating == false {
        commandGeneration &+= 1
        lastCommandDurationMS =
          (ProcessInfo.processInfo.systemUptime - commandStartedAt) * 1_000
        diagnostics.recordNoOp(
          commandDiagnosticMetadata(
            command: rawCommand,
            generation: commandGeneration,
            inputTimestamp: commandInputTimestamp,
            monitorID: commandMonitorID,
            selectedWindowID: commandMonitorID.flatMap {
              state.selectedWindowID(on: $0)
            },
            state: state,
            commandStartedAt: commandStartedAt
          ),
          durationMS: lastCommandDurationMS
        )
        platform.recordPerformanceTrace(
          "command-no-op command=\(rawCommand) ms=\(String(format: "%.2f", lastCommandDurationMS))"
        )
        return .success()
      }
      let previouslySelectedWindowID = commandMonitorID.flatMap {
        state.selectedWindowID(on: $0)
      }
      let crossMonitorWindowID = crossMonitorCommandWindowID(
        command,
        selectedWindowID: previouslySelectedWindowID,
        selectedTiledWindowID: commandMonitorID.flatMap {
          state.selectedTiledWindowID(on: $0)
        }
      )
      commandGeneration &+= 1
      let currentCommandGeneration = commandGeneration
      let validationMS =
        (ProcessInfo.processInfo.systemUptime - commandStartedAt) * 1_000
      platform.recordPerformanceTrace(
        "command-start cg=\(currentCommandGeneration) command=\(rawCommand) validationMs=\(String(format: "%.2f", validationMS))"
      )
      displacedPointerFocusRecovery = nil
      invalidatePointerFocusIntent(recoveringTo: previouslySelectedWindowID)
      let focusInputTimestamp = commandFocusInputTimestamp(
        capturedInputTimestamp: inputTimestamp,
        commandHandledAt: commandStartedAt
      )
      let commandPerformance = CommandPerformanceContext(
        generation: currentCommandGeneration,
        inputTimestamp: focusInputTimestamp
      )
      platform.beginCommandPerformance(commandPerformance)
      let cursorWarpInputTimestamp = keyboardCursorWarpTimestamp(
        mouseFollowsFocus: config.input.mouseFollowsFocus,
        capturedInputTimestamp: inputTimestamp
      )
      mouseReorderAnimationActive = false
      latestCommandInputTimestamp = resolvedLatestCommandInputTimestamp(
        previousTimestamp: latestCommandInputTimestamp,
        capturedInputTimestamp: inputTimestamp,
        commandHandledAt: commandStartedAt
      )
      pendingWindowRemovalFocusGuard = nil
      let switchesWorkspace = command.activatesWorkspace
      let mutatesWorkspaceWindows = command.movesWindowBetweenWorkspaces
      let movesAcrossMonitors = command.movesWindowsAcrossMonitors
      let resizesManagedLayout = command.resizesManagedLayout
      let speculativeRibbonNavigation = isSpeculativeRibbonNavigation(command)
      if switchesWorkspace || mutatesWorkspaceWindows || movesAcrossMonitors
        || resizesManagedLayout || speculativeRibbonNavigation
      {
        rearmPointerFocusTransition()
      }
      if switchesWorkspace || mutatesWorkspaceWindows || movesAcrossMonitors
        || resizesManagedLayout
        || speculativeRibbonNavigation
      {
        preemptMouseGesture()
      }
      let animatedManagedResize =
        resizesManagedLayout
        && config.animation.enabled
        && config.animation.durationMS > 0
      let previousWorkspaceID = commandMonitorID.flatMap { monitorID in
        state.monitors.first(where: { $0.id == monitorID })?.activeWorkspace
      }
      let preCommandWindowMonitorIDs = state.windowLocationMap()
      let inFlightAnimationMonitorIDs = Set(
        scrollAnimations.keys.map(\.monitorID)
      ).union(
        platform.pendingAnimatedFrameWindowIDs.compactMap {
          preCommandWindowMonitorIDs[$0]?.monitorID
        }
      )
      if rebasesPendingFrame {
        rebaseActiveScrollOffsetToDisplayedFrames()
      }
      if switchesWorkspace || mutatesWorkspaceWindows || movesAcrossMonitors {
        refreshFloatingWindowFramesBeforeWorkspaceMutation(on: commandMonitorID)
      }
      if switchesWorkspace {
        suppressNativeFocusUntil = commandStartedAt + 0.25
        pendingAnimatedFocus = nil
        invalidateSubmittedCommandFocus()
        invalidateSubmittedWorkspaceFocus()
        pendingWorkspaceFocus = nil
      }
      let previousWindowMonitorIDs = movesAcrossMonitors
        ? monitorIDsByWindow(preCommandWindowMonitorIDs)
        : [:]
      if rebasesPendingFrame {
        try reduce(
          command,
          on: commandMonitorID,
          state: &state,
          monitorFrames: physicalMonitorFrames,
          viewports: commandViewports
        )
      } else if let validationState {
        state = validationState
      }
      let nextWindowMonitorIDsMap = state.windowLocationMap()
      let resultMonitorID = movesAcrossMonitors
        ? crossMonitorWindowID.flatMap { nextWindowMonitorIDsMap[$0]?.monitorID }
          ?? commandMonitorID
        : commandMonitorID
      let nextWindowMonitorIDs = movesAcrossMonitors
        ? monitorIDsByWindow(nextWindowMonitorIDsMap)
        : [:]
      let movedFloatingWindowIDs = floatingWindowIDsMovedBetweenMonitors(
        previousWindowMonitorIDs: previousWindowMonitorIDs,
        nextWindowMonitorIDs: nextWindowMonitorIDs,
        windows: state.windows
      )
      if movesAcrossMonitors {
        activeMonitorID = resultMonitorID
        rebaseFloatingWindowFrames(
          previousViewports: commandViewports,
          nextViewports: commandViewports,
          previousMonitorIDs: previousWindowMonitorIDs,
          windowIDs: movedFloatingWindowIDs
        )
        for (windowID, window) in state.windows where window.floating {
          guard let nextMonitorID = nextWindowMonitorIDsMap[windowID]?.monitorID,
            previousWindowMonitorIDs[windowID] != nextMonitorID
          else {
            continue
          }
          if let frame = floatingWindowFrames[windowID] {
            state.updateWindowFrame(frame, for: windowID)
          } else {
            floatingWindowFrames[windowID] = window.frame
          }
          if window.floatingOrigin == .automatic {
            invalidatePlacementPreference(for: window)
          }
        }
      }
      let commandTransfersFocus: Bool
      if command.activatesWorkspace {
        commandTransfersFocus = true
      } else if let resultMonitorID,
        let selectedWindowID = state.selectedWindowID(on: resultMonitorID)
      {
        commandTransfersFocus = commandShouldFocusWindow(
          command,
          previousSelectedWindowID: previouslySelectedWindowID,
          selectedWindowID: selectedWindowID,
          selectedFloatingWindowID: state.selectedFloatingWindowID(
            on: resultMonitorID
          ),
          movesAcrossMonitors: movesAcrossMonitors
        )
      } else {
        commandTransfersFocus = false
      }
      platform.recordCommandFocusExpectation(
        commandPerformance,
        expectsFocus: commandTransfersFocus
      )
      let diagnosticMonitorID = resultMonitorID ?? commandMonitorID
      diagnostics.beginCommand(
        commandDiagnosticMetadata(
          command: rawCommand,
          generation: currentCommandGeneration,
          inputTimestamp: commandInputTimestamp,
          monitorID: diagnosticMonitorID,
          selectedWindowID: diagnosticMonitorID.flatMap {
            state.selectedWindowID(on: $0)
          } ?? previouslySelectedWindowID,
          state: state,
          commandStartedAt: commandStartedAt
        )
      )
      if commandTransfersFocus {
        activeMonitorID = resultMonitorID
      }
      if command.movesWindowBetweenWorkspaces,
        let movedWindowID = previouslySelectedWindowID,
        let movedWindow = state.windows[movedWindowID],
        movedWindow.floatingOrigin == .automatic
      {
        invalidatePlacementPreference(for: movedWindow)
      }
      if !switchesWorkspace,
        let submittedCommandFocus,
        let resultMonitorID,
        let selectedWindowID = state.selectedWindowID(on: resultMonitorID),
        !commandFocusIsPreserved(
          pendingWindowID: nil,
          submittedWindowID: submittedCommandFocus.windowID,
          selectedWindowID: selectedWindowID
        )
      {
        invalidateSubmittedCommandFocus()
      }
      let stateReadyAt = ProcessInfo.processInfo.systemUptime
      synchronizeScrollOffsets(state: &state, viewports: commandViewports)
      if switchesWorkspace {
        snapScrollOffsetsToTargets()
      } else {
        startScrollAnimationsIfNeeded()
      }
      let animationReadyAt = ProcessInfo.processInfo.systemUptime
      platform.recordPerformanceTrace(
        "command-ready cg=\(currentCommandGeneration) stateMs=\(String(format: "%.2f", (stateReadyAt - commandStartedAt) * 1_000)) scrollMs=\(String(format: "%.2f", (animationReadyAt - stateReadyAt) * 1_000))"
      )
      let affectedMonitorIDs = commandLayoutMonitorIDs(
        affected: affectedMonitorIDsForWindowMove(
          commandMonitorID: commandMonitorID,
          resultMonitorID: resultMonitorID,
          previousWindowMonitorIDs: previousWindowMonitorIDs,
          nextWindowMonitorIDs: nextWindowMonitorIDs
        ),
        inFlightAnimations: inFlightAnimationMonitorIDs
      )
      let dispatchedAnimation =
        animatedManagedResize
        ? dispatchManagedResizeAnimation(
          monitorIDs: affectedMonitorIDs,
          forcingFloatingFrameWritesFor: movedFloatingWindowIDs,
          commandPerformance: commandPerformance
        )
        : dispatchScrollAnimationIfNeeded(
          monitorIDs: affectedMonitorIDs,
          forcingFloatingFrameWritesFor: movedFloatingWindowIDs,
          commandPerformance: commandPerformance
        )
      let workspaceFocusRequest: PendingWorkspaceFocus?
      if switchesWorkspace,
        let commandMonitorID,
        let requestedWorkspaceID = state.monitors.first(where: {
          $0.id == commandMonitorID
        })?.activeWorkspace,
        let requestedWindowID = state.selectedWindowID(on: commandMonitorID)
      {
        let restoresPreviousWorkspaceOnCancellation: Bool
        if case .switchWorkspace = command {
          restoresPreviousWorkspaceOnCancellation = true
        } else {
          restoresPreviousWorkspaceOnCancellation = false
        }
        workspaceFocusRequest = PendingWorkspaceFocus(
          monitorID: commandMonitorID,
          requestedWorkspaceID: requestedWorkspaceID,
          previousWorkspaceID: previousWorkspaceID,
          requestedWindowID: requestedWindowID,
          restoresPreviousWorkspaceOnCancellation:
            restoresPreviousWorkspaceOnCancellation,
          commandGeneration: currentCommandGeneration,
          focusInputTimestamp: focusInputTimestamp,
          cursorWarpInputTimestamp: cursorWarpInputTimestamp
        )
      } else if let pending = pendingWorkspaceFocus,
        pendingWorkspaceFocusIsPreserved(
          pendingMonitorID: pending.monitorID,
          commandMonitorID: commandMonitorID,
          requestedWorkspaceID: pending.requestedWorkspaceID,
          activeWorkspaceID: state.monitors.first(where: {
            $0.id == pending.monitorID
          })?.activeWorkspace,
          requestedWindowID: pending.requestedWindowID,
          selectedWindowID: state.selectedWindowID(on: pending.monitorID)
        )
      {
        workspaceFocusRequest = PendingWorkspaceFocus(
          monitorID: pending.monitorID,
          requestedWorkspaceID: pending.requestedWorkspaceID,
          previousWorkspaceID: pending.previousWorkspaceID,
          requestedWindowID: pending.requestedWindowID,
          restoresPreviousWorkspaceOnCancellation:
            pending.restoresPreviousWorkspaceOnCancellation,
          commandGeneration: currentCommandGeneration,
          focusInputTimestamp: focusInputTimestamp,
          cursorWarpInputTimestamp: cursorWarpInputTimestamp
        )
      } else {
        workspaceFocusRequest = nil
      }
      invalidateSubmittedWorkspaceFocus()
      pendingWorkspaceFocus = workspaceFocusRequest
      if switchesWorkspace || !dispatchedAnimation {
        let focusWindowIDAfterCommit = workspaceFocusRequest?.requestedWindowID
        let focusCompletionAfterCommit: (@MainActor @Sendable (NativeFocusResult) -> Void)?
        let cursorWarpIsCurrentAfterCommit: (@MainActor @Sendable () -> Bool)?
        let focusRequestIDAfterCommit: (@MainActor @Sendable (NativeFocusRequestID?) -> Void)?
        if let workspaceFocusRequest {
          submittedWorkspaceFocusGeneration =
            workspaceFocusRequest.commandGeneration
          focusCompletionAfterCommit = { [weak self] result in
            self?.commitWorkspaceCommandFocus(
              result: result,
              request: workspaceFocusRequest
            )
          }
          cursorWarpIsCurrentAfterCommit = { [weak self] in
            guard let self else { return false }
            return self.pendingWorkspaceFocus?.commandGeneration
              == workspaceFocusRequest.commandGeneration
              && self.submittedWorkspaceFocusGeneration
                == workspaceFocusRequest.commandGeneration
          }
          focusRequestIDAfterCommit = { [weak self] requestID in
            guard let self,
              self.pendingWorkspaceFocus?.commandGeneration
                == workspaceFocusRequest.commandGeneration,
              self.submittedWorkspaceFocusGeneration
                == workspaceFocusRequest.commandGeneration
            else { return }
            self.submittedWorkspaceFocusRequestID = requestID
            self.submittedWorkspaceFocusRequestTimestamp =
              requestID == nil
              ? nil
              : workspaceFocusRequest.focusInputTimestamp
          }
        } else {
          focusCompletionAfterCommit = nil
          cursorWarpIsCurrentAfterCommit = nil
          focusRequestIDAfterCommit = nil
        }
        applyCurrentLayout(
          monitorIDs: affectedMonitorIDs,
          asynchronousPositions: true,
          updateVisibility: scrollAnimations.isEmpty,
          positionTimeoutSeconds: scrollAnimations.isEmpty ? 0.05 : 0.016,
          positionsOnly: speculativeRibbonNavigation,
          stagesVisibleBeforeParking: switchesWorkspace,
          focusWindowIDAfterCommit: focusWindowIDAfterCommit,
          focusInputTimestampAfterCommit:
            workspaceFocusRequest?.focusInputTimestamp,
          cursorWarpInputTimestampAfterCommit:
            workspaceFocusRequest?.cursorWarpInputTimestamp,
          focusCompletionAfterCommit: focusCompletionAfterCommit,
          cursorWarpIsCurrentAfterCommit:
            cursorWarpIsCurrentAfterCommit,
          focusRequestIDAfterCommit: focusRequestIDAfterCommit,
          forcingFloatingFrameWritesFor: movedFloatingWindowIDs,
          commandPerformance: commandPerformance,
          source: switchesWorkspace ? "workspace-command" : "command"
        )
      }
      if !switchesWorkspace,
        let monitorID = resultMonitorID ?? state.monitors.first?.id,
        let sourceWorkspaceID = previousWorkspaceID,
        let selected = state.selectedWindowID(on: monitorID),
        commandShouldFocusWindow(
          command,
          previousSelectedWindowID: previouslySelectedWindowID,
          selectedWindowID: selected,
          selectedFloatingWindowID: state.selectedFloatingWindowID(on: monitorID),
          movesAcrossMonitors: movesAcrossMonitors
        )
      {
        if focusIsReady(on: monitorID, targetWindowID: selected) {
          commitCommandFocus(
            selected,
            previousSelectedWindowID: previouslySelectedWindowID,
            monitorID: monitorID,
            sourceWorkspaceID: sourceWorkspaceID,
            commandGeneration: currentCommandGeneration,
            focusInputTimestamp: focusInputTimestamp,
            cursorWarpInputTimestamp: cursorWarpInputTimestamp
          )
        } else {
          pendingAnimatedFocus = PendingAnimatedFocus(
            windowID: selected,
            previousSelectedWindowID: previouslySelectedWindowID,
            monitorID: monitorID,
            sourceWorkspaceID: sourceWorkspaceID,
            commandGeneration: currentCommandGeneration,
            focusInputTimestamp: focusInputTimestamp,
            cursorWarpInputTimestamp: cursorWarpInputTimestamp
          )
        }
      } else if !switchesWorkspace,
        let monitorID = resultMonitorID ?? state.monitors.first?.id,
        let sourceWorkspaceID = pendingAnimatedFocus?.sourceWorkspaceID
          ?? submittedCommandFocus?.sourceWorkspaceID
          ?? previousWorkspaceID,
        let selected = state.selectedWindowID(on: monitorID),
        commandFocusIsPreserved(
          pendingWindowID: pendingAnimatedFocus?.windowID,
          submittedWindowID: submittedCommandFocus?.windowID,
          selectedWindowID: selected
        )
      {
        let previousCommandFocus =
          pendingAnimatedFocus
          ?? submittedCommandFocus
        pendingAnimatedFocus = PendingAnimatedFocus(
          windowID: selected,
          previousSelectedWindowID:
            previousCommandFocus?.previousSelectedWindowID,
          monitorID: monitorID,
          sourceWorkspaceID: sourceWorkspaceID,
          commandGeneration: currentCommandGeneration,
          focusInputTimestamp: focusInputTimestamp,
          cursorWarpInputTimestamp: cursorWarpInputTimestamp
        )
      }
      if movesAcrossMonitors,
        let selectedWindowID = resultMonitorID.flatMap({ state.selectedWindowID(on: $0) }),
        platform.isWindowNativelyFocused(selectedWindowID)
      {
        platform.recordCommandFocus(
          commandPerformance,
          result: .completedWithoutMutation
        )
      }
      persistPlacements()
      updateMenuBar()
      if commandFollowUpIsPending(
        frameWrites: platform.hasPendingFrameWrites,
        animatedFocus: pendingAnimatedFocus != nil,
        workspaceFocus: pendingWorkspaceFocus != nil
      ) {
        setTimerFrequency(60)
      }
      lastCommandDurationMS =
        (ProcessInfo.processInfo.systemUptime - commandStartedAt) * 1_000
      performanceLogger.debug(
        "command applied command=\(rawCommand, privacy: .public) duration_ms=\(self.lastCommandDurationMS, format: .fixed(precision: 2)) animations=\(self.scrollAnimations.count)"
      )
      return .success()
    } catch {
      return .failure(String(describing: error))
    }
  }
}

func commandLayoutMonitorIDs(
  affected: Set<MonitorID>,
  inFlightAnimations: Set<MonitorID>
) -> Set<MonitorID> {
  affected.union(inFlightAnimations)
}

func affectedMonitorIDsForWindowMove(
  commandMonitorID: MonitorID?,
  resultMonitorID: MonitorID?,
  previousWindowMonitorIDs: [WindowID: MonitorID],
  nextWindowMonitorIDs: [WindowID: MonitorID]
) -> Set<MonitorID> {
  var monitorIDs = Set([commandMonitorID, resultMonitorID].compactMap { $0 })
  for (windowID, previousMonitorID) in previousWindowMonitorIDs {
    guard nextWindowMonitorIDs[windowID] != previousMonitorID else { continue }
    monitorIDs.insert(previousMonitorID)
    if let nextMonitorID = nextWindowMonitorIDs[windowID] {
      monitorIDs.insert(nextMonitorID)
    }
  }
  return monitorIDs
}

func floatingWindowIDsMovedBetweenMonitors(
  previousWindowMonitorIDs: [WindowID: MonitorID],
  nextWindowMonitorIDs: [WindowID: MonitorID],
  windows: [WindowID: Window]
) -> Set<WindowID> {
  Set(previousWindowMonitorIDs.compactMap { windowID, previousMonitorID in
    guard nextWindowMonitorIDs[windowID] != previousMonitorID,
      windows[windowID]?.floating == true
    else { return nil }
    return windowID
  })
}

private func monitorIDsByWindow(
  _ locations: WindowLocationMap
) -> [WindowID: MonitorID] {
  var monitorIDs: [WindowID: MonitorID] = [:]
  monitorIDs.reserveCapacity(locations.count)
  for (windowID, location) in locations {
    monitorIDs[windowID] = location.monitorID
  }
  return monitorIDs
}
