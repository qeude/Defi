import DefiConfig
import DefiModel
import DefiRuntime
import Testing

struct FocusStateTests {
  private let monitor = MonitorID(rawValue: 1)
  private let first = WorkspaceID(rawValue: "first")
  private let second = WorkspaceID(rawValue: "second")
  private let a = WindowID(rawValue: 1)
  private let b = WindowID(rawValue: 2)
  private let c = WindowID(rawValue: 3)

  @Test func lateCommandCompletionCannotRollbackNewerSelectionOrRetry() throws {
    var state = makeState()
    var focus = FocusState()
    let request = command()
    let supersededSubmission = focus.submitCommand(request)
    let submission = focus.submitCommand(request)
    #expect(
      focus.completeCommand(
        request, submission: supersededSubmission, result: .failedAfterMutation,
        commandGeneration: 10, keepsRequestedWindow: false, state: &state
      ) == .stale)
    #expect(
      focus.completeCommand(
        request, submission: submission, result: .failed, commandGeneration: 10,
        keepsRequestedWindow: false, state: &state
      ) == .settled)
    let retry = try #require(focus.pendingAnimatedFocus)
    #expect(retry.retryCount == 1)
    let retrySubmission = focus.submitCommand(retry)
    #expect(
      focus.completeCommand(
        request, submission: submission, result: .failedAfterMutation, commandGeneration: 10,
        keepsRequestedWindow: false, state: &state
      ) == .stale)
    #expect(focus.submittedCommandFocus == retry)
    #expect(state.selectedWindowID(on: monitor) == b)
    #expect(
      focus.completeCommand(
        retry, submission: retrySubmission, result: .failedAfterMutation, commandGeneration: 10,
        keepsRequestedWindow: false, state: &state
      ) == .selectionChanged(monitor))
    #expect(state.selectedWindowID(on: monitor) == a)

    let obsoleteSubmission = focus.submitCommand(request)
    let newer = command(windowID: a, generation: 11)
    focus.submitCommand(newer)
    let before = state
    #expect(
      focus.completeCommand(
        request, submission: obsoleteSubmission, result: .cancelledAfterInputMutation,
        commandGeneration: 11,
        keepsRequestedWindow: false, state: &state
      ) == .stale)
    #expect(state == before)
    #expect(focus.submittedCommandFocus == newer)
  }

  @Test func workspaceRetryAndLateCompletionPreserveLatestRequest() throws {
    var state = makeState()
    state.monitors[0].activeWorkspace = second
    var focus = FocusState()
    let request = PendingWorkspaceFocus(
      monitorID: monitor, requestedWorkspaceID: second,
      previousWorkspaceID: first, requestedWindowID: c,
      restoresPreviousWorkspaceOnCancellation: true,
      commandGeneration: 10, focusInputTimestamp: 10,
      cursorWarpInputTimestamp: nil
    )
    focus.queueWorkspace(request)
    var submission = focus.submitWorkspace(request)
    #expect(
      focus.completeWorkspace(
        request, submission: submission, result: .frameSuperseded, commandGeneration: 10,
        keepsRequestedWindow: false, state: &state
      ) == .settled)
    #expect(focus.pendingWorkspaceFocus == request)
    #expect(focus.submittedWorkspaceFocusGeneration == nil)
    submission = focus.submitWorkspace(request)
    #expect(
      focus.completeWorkspace(
        request, submission: submission, result: .failed, commandGeneration: 10,
        keepsRequestedWindow: false, state: &state
      ) == .settled)
    let retry = try #require(focus.pendingWorkspaceFocus)
    let retrySubmission = focus.submitWorkspace(retry)
    #expect(
      focus.completeWorkspace(
        request, submission: submission, result: .failed, commandGeneration: 10,
        keepsRequestedWindow: false, state: &state
      ) == .stale)
    #expect(
      focus.completeWorkspace(
        retry, submission: retrySubmission, result: .failed, commandGeneration: 10,
        keepsRequestedWindow: false, state: &state
      ) == .selectionChanged(monitor))
    #expect(state.monitors[0].activeWorkspace == first)
  }

  @Test func failedPointerRetryRestoresDisplacedCommandAtLatestMonitor() throws {
    var state = makeState()
    var focus = FocusState()
    focus.submitCommand(command())
    let request = PendingPointerFocus(windowID: a, generation: 0, timestamp: 20)
    let submission = focus.submitPointer(request)
    focus.cancelSubmittedCommand()
    #expect(
      completePointer(&focus, request, submission: submission, state: &state)
        == .ignored(rearm: false))
    let retry = try #require(focus.pendingPointerFocus)
    #expect(retry.retryCount == 1)
    let retrySubmission = focus.submitPointer(retry)
    #expect(
      completePointer(&focus, retry, submission: retrySubmission, state: &state) == .resumeDisplaced
    )
    let restored = try #require(focus.pendingAnimatedFocus)
    #expect(restored.windowID == b)
    #expect(restored.focusInputTimestamp == 20)
    #expect(restored.cursorWarpInputTimestamp == nil)
    #expect(focus.displacedPointerFocusRecovery == nil)

    let destination = MonitorID(rawValue: 2)
    state.monitors[0] = Monitor(
      id: destination, workspaces: state.monitors[0].workspaces,
      activeWorkspace: state.monitors[0].activeWorkspace
    )
    state.windows[b]?.monitorID = destination
    focus.queueCommand(nil)
    focus.requeuePreservedFocusAfterMonitorRetention(
      command: restored, workspace: nil, displaced: nil, state: state
    )
    #expect(focus.pendingAnimatedFocus?.monitorID == destination)
    #expect(focus.pendingAnimatedFocus?.focusInputTimestamp == 20)
  }

  @Test func pointerCompletionCannotOvertakeNewerInputOrSelection() {
    var state = makeState()
    var focus = FocusState()
    let request = PendingPointerFocus(windowID: a, generation: 0, timestamp: 20)
    var submission = focus.submitPointer(request)
    #expect(
      completePointer(
        &focus, request, submission: submission, result: .completed, latestInput: 21, state: &state
      ) == .ignored(rearm: true))
    #expect(state.selectedWindowID(on: monitor) == b)

    submission = focus.submitPointer(request)
    focus.invalidatePointer()
    let newer = PendingPointerFocus(windowID: a, generation: 1, timestamp: 22)
    let newerSubmission = focus.submitPointer(newer)
    #expect(
      completePointer(&focus, request, submission: submission, result: .completed, state: &state)
        == .stale)
    #expect(focus.submittedPointerFocus == newer)
    #expect(
      completePointer(
        &focus, newer, submission: newerSubmission, result: .completed, latestInput: 22,
        state: &state
      ) == .selectionChanged(monitor))
    #expect(state.selectedWindowID(on: monitor) == a)
  }

  @Test func identityReplacementRequeuesFocusAndRejectsOldCompletion() {
    var state = makeState()
    var focus = FocusState()
    let request = command()
    let submission = focus.submitCommand(request)
    let replacement = WindowID(rawValue: 4)
    let effects = focus.rebind(using: [b: replacement], workspaceWritePending: false)
    #expect(effects.command == replacement)
    #expect(focus.pendingAnimatedFocus?.windowID == replacement)
    #expect(
      focus.completeCommand(
        request, submission: submission, result: .failedAfterMutation, commandGeneration: 10,
        keepsRequestedWindow: false, state: &state
      ) == .stale)
    #expect(state.selectedWindowID(on: monitor) == b)
  }

  @Test func pointerObservationWaitsForGeometryAndRechecksInput() throws {
    var focus = FocusState()
    let state = makeState()
    let viewports = [monitor: Rect(x: 0, y: 0, width: 1_000, height: 800)]
    #expect(
      focus.observePointer(
        windowID: a, timestamp: 20, latestInputTimestamp: 20,
        ready: false, restoresNativeFocus: true, activeMonitorID: monitor,
        viewports: viewports, input: InputConfig(focusFollowsMouse: true), state: state
      ) == .changed(recoveringTo: b, request: nil))
    let pending = try #require(focus.pendingPointerFocus)
    #expect(
      focus.resumePointer(
        latestInputTimestamp: 20, ready: false, windowUnderPointerID: a
      ) == .waiting)
    #expect(focus.pendingPointerFocus == pending)
    #expect(
      focus.resumePointer(
        latestInputTimestamp: 20, ready: true, windowUnderPointerID: a
      ) == .ready(pending))
    #expect(focus.pendingPointerFocus == nil)

    focus.rearmPointer()
    _ = focus.observePointer(
      windowID: a, timestamp: 20, latestInputTimestamp: 20,
      ready: false, restoresNativeFocus: true, activeMonitorID: monitor,
      viewports: viewports, input: InputConfig(focusFollowsMouse: true), state: state
    )
    #expect(
      focus.resumePointer(
        latestInputTimestamp: 21, ready: true, windowUnderPointerID: a
      ) == .stale)
    #expect(focus.pendingPointerFocus == nil)
  }

  private func completePointer(
    _ focus: inout FocusState,
    _ request: PendingPointerFocus,
    submission: FocusSubmissionID,
    result: NativeFocusResult = .failed,
    latestInput: Double = 20,
    state: inout RuntimeState
  ) -> PointerFocusCompletionEffect {
    focus.completePointer(
      request, submission: submission, result: result, latestInputTimestamp: latestInput,
      windowUnderPointerID: a, commandGeneration: 10,
      activeMonitorID: monitor,
      viewports: [monitor: Rect(x: 0, y: 0, width: 1_000, height: 800)],
      maximumScrollAmount: nil, acceptsAlreadySelectedWindow: true,
      state: &state
    )
  }

  private func command(windowID: WindowID? = nil, generation: UInt64 = 10) -> PendingAnimatedFocus {
    PendingAnimatedFocus(
      windowID: windowID ?? b, previousSelectedWindowID: a,
      monitorID: monitor, sourceWorkspaceID: first,
      commandGeneration: generation, focusInputTimestamp: 10,
      cursorWarpInputTimestamp: 10
    )
  }

  private func makeState() -> RuntimeState {
    var state = RuntimeState(
      config: Config(
        workspaces: WorkspacesConfig(names: ["first", "second"], defaultName: "first")
      ))
    state.attachMonitor(monitor)
    state.monitors[0].workspaces[0].columns = [
      Column(window: a, width: .fraction(0.5)),
      Column(window: b, width: .fraction(0.5)),
    ]
    state.monitors[0].workspaces[0].focusedColumn = 1
    state.monitors[0].workspaces[1].columns = [Column(window: c, width: .fraction(0.5))]
    for id in [a, b, c] {
      state.windows[id] = Window(
        id: id, appID: "test", title: "test",
        frame: Rect(x: 0, y: 0, width: 500, height: 800), monitorID: monitor
      )
    }
    return state
  }
}
