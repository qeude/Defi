import DefiConfig
import DefiModel
import Testing

@testable import DefiRuntime

struct NativeFocusTests {
  private let monitorID = MonitorID(rawValue: 1)

  @Test
  func alreadySelectedWindowDoesNotChangeNativeFocusSelection() throws {
    var state = try makeState()
    let selected = WindowID(rawValue: 1)
    #expect(focusWindow(selected, state: &state) == false)

    #expect(
      nativeFocusChangesSelection(
        selected,
        activeMonitorID: monitorID,
        state: state
      ) == false
    )
  }

  @Test
  func focusInsideActiveWorkspaceDoesNotReportWorkspaceActivation() throws {
    var state = try makeState()

    #expect(focusWindow(WindowID(rawValue: 2), state: &state) == false)
  }

  @Test
  func differentWindowChangesNativeFocusSelection() throws {
    var state = try makeState()
    focusWindow(WindowID(rawValue: 1), state: &state)

    #expect(
      nativeFocusChangesSelection(
        WindowID(rawValue: 2),
        activeMonitorID: monitorID,
        state: state
      )
    )
  }

  @Test
  func mouseDownDefersNativeFocusMutationUntilRelease() {
    #expect(
      nativeFocusMutationIsReady(
        nativeFocusChanged: true,
        mouseInteractionEnded: false,
        leftMouseButtonDown: true,
        mouseReleaseFocusIntentCurrent: false
      ) == false
    )
    #expect(
      nativeFocusMutationIsReady(
        nativeFocusChanged: false,
        mouseInteractionEnded: true,
        leftMouseButtonDown: false,
        mouseReleaseFocusIntentCurrent: true
      )
    )
  }

  @Test
  func nonMouseNativeFocusMutatesImmediately() {
    #expect(
      nativeFocusMutationIsReady(
        nativeFocusChanged: true,
        mouseInteractionEnded: false,
        leftMouseButtonDown: false,
        mouseReleaseFocusIntentCurrent: false
      )
    )
  }

  @Test
  func newerCommandRejectsDeferredMouseReleaseFocus() {
    let focusedWindowID = WindowID(rawValue: 2)
    #expect(
      mouseReleaseFocusIntentIsCurrent(
        focusedWindowID: focusedWindowID,
        mouseFocusIntentWindowID: focusedWindowID,
        mouseFocusIntentTimestamp: 10,
        latestCommandInputTimestamp: 11,
        nativeFocusChanged: true
      ) == false
    )
    #expect(
      nativeFocusMutationIsReady(
        nativeFocusChanged: true,
        mouseInteractionEnded: true,
        leftMouseButtonDown: false,
        mouseReleaseFocusIntentCurrent: false
      ) == false
    )
  }

  @Test
  func currentMouseReleaseAcceptsObservedFocusWithoutWindowHint() {
    #expect(
      mouseReleaseFocusIntentIsCurrent(
        focusedWindowID: WindowID(rawValue: 2),
        mouseFocusIntentWindowID: nil,
        mouseFocusIntentTimestamp: 12,
        latestCommandInputTimestamp: 11,
        nativeFocusChanged: true
      )
    )
  }

  @Test
  func queuedHotKeyKeepsCapturedInputOrder() {
    #expect(
      resolvedLatestCommandInputTimestamp(
        previousTimestamp: 0,
        capturedInputTimestamp: 10,
        commandHandledAt: 12
      ) == 10
    )
    #expect(
      resolvedLatestCommandInputTimestamp(
        previousTimestamp: 11,
        capturedInputTimestamp: 10,
        commandHandledAt: 12
      ) == 11
    )
    #expect(
      resolvedLatestCommandInputTimestamp(
        previousTimestamp: 11,
        capturedInputTimestamp: nil,
        commandHandledAt: 12
      ) == 12
    )
  }

  @Test
  func selectedWindowOnDifferentActiveMonitorChangesSelection() throws {
    var state = try makeState()
    let selected = WindowID(rawValue: 1)
    focusWindow(selected, state: &state)

    #expect(
      nativeFocusChangesSelection(
        selected,
        activeMonitorID: MonitorID(rawValue: 2),
        state: state
      )
    )
  }

  @Test
  func selectedRemovalPreservesWorkspaceAgainstAutomaticExternalFocus() throws {
    var fixture = try makeRemovalFixture()
    let guardToken = try removeSelectedWindow(
      keeping: [fixture.localFallback, fixture.external],
      from: &fixture
    )

    #expect(
      windowRemovalFocusDecision(
        guard: guardToken,
        nativeFocusedWindowID: fixture.external.id,
        nativeFocusChanged: true,
        latestUserInputTimestamp: 10,
        state: fixture.state
      ) == .preserve(localFallback: fixture.localFallback.id)
    )
  }

  @Test
  func inputAfterRemovalAcceptsImmediateExternalFocus() throws {
    var fixture = try makeRemovalFixture()
    let guardToken = try removeSelectedWindow(
      keeping: [fixture.localFallback, fixture.external],
      from: &fixture
    )

    #expect(
      windowRemovalFocusDecision(
        guard: guardToken,
        nativeFocusedWindowID: fixture.external.id,
        nativeFocusChanged: true,
        latestUserInputTimestamp: 11,
        state: fixture.state
      ) == .accept
    )
    #expect(
      windowRemovalFocusGuard(
        previousMonitorID: monitorID,
        previousWorkspaceID: fixture.devWorkspace,
        previousSelectedWindowID: fixture.selected.id,
        removedWindowIDs: [fixture.selected.id],
        userInputAfterWindowTopology: true,
        latestUserInputTimestamp: 11
      ) == nil
    )
  }

  @Test
  func localNativeFallbackIsAccepted() throws {
    var fixture = try makeRemovalFixture()
    let guardToken = try removeSelectedWindow(
      keeping: [fixture.localFallback, fixture.external],
      from: &fixture
    )

    #expect(
      windowRemovalFocusDecision(
        guard: guardToken,
        nativeFocusedWindowID: fixture.localFallback.id,
        nativeFocusChanged: true,
        latestUserInputTimestamp: 10,
        state: fixture.state
      ) == .accept
    )
  }

  @Test
  func nonSelectedRemovalDoesNotCreateFocusGuard() throws {
    let fixture = try makeRemovalFixture()

    #expect(
      windowRemovalFocusGuard(
        previousMonitorID: monitorID,
        previousWorkspaceID: fixture.devWorkspace,
        previousSelectedWindowID: fixture.selected.id,
        removedWindowIDs: [fixture.localFallback.id],
        userInputAfterWindowTopology: false,
        latestUserInputTimestamp: 10
      ) == nil
    )
  }

  @Test
  func emptyWorkspaceStaysActiveWithoutInventingFallback() throws {
    var fixture = try makeRemovalFixture()
    let guardToken = try removeSelectedWindow(
      keeping: [fixture.external],
      removedWindowIDs: [fixture.selected.id, fixture.localFallback.id],
      from: &fixture
    )

    #expect(
      windowRemovalFocusDecision(
        guard: guardToken,
        nativeFocusedWindowID: fixture.external.id,
        nativeFocusChanged: true,
        latestUserInputTimestamp: 10,
        state: fixture.state
      ) == .preserve(localFallback: nil)
    )
    #expect(
      fixture.state.monitors[0].activeWorkspace == fixture.devWorkspace
    )
  }

  @Test
  func nativeFocusPreservesTwoVisibleColumns() throws {
    var state = try makeState(windowCount: 2)
    setColumnWidths(.fraction(0.5), state: &state)
    focusWindow(WindowID(rawValue: 2), state: &state)

    alignFocusedColumnLeft(
      on: monitorID,
      state: &state,
      viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
    )

    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 0)
  }

  @Test
  func nativeFocusPreservesVisibleColumnInsideOverflowingStrip() throws {
    var state = try makeState(windowCount: 4)
    setColumnWidths(.fraction(0.5), state: &state)
    focusWindow(WindowID(rawValue: 3), state: &state)
    state.monitors[0].workspaces[0].scrollOffset = 0.5

    alignFocusedColumnLeft(
      on: monitorID,
      state: &state,
      viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
    )

    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 0.5)
  }

  @Test
  func nativeFocusAlignmentCannotOverscrollPastStripEnd() throws {
    var state = try makeState(windowCount: 4)
    setColumnWidths(.fraction(0.5), state: &state)
    focusWindow(WindowID(rawValue: 4), state: &state)

    alignFocusedColumnLeft(
      on: monitorID,
      state: &state,
      viewports: [monitorID: Rect(x: 0, y: 0, width: 1_000, height: 700)]
    )

    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 1)
  }

  private func makeState(windowCount: Int = 2) throws -> RuntimeState {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    for id in 1...windowCount {
      let window = Window(
        id: WindowID(rawValue: UInt64(id)),
        appID: "app-\(id)",
        title: "Window \(id)",
        frame: Rect(x: 0, y: 0, width: 800, height: 700),
        monitorID: monitorID
      )
      try discoverWindow(window, decision: RuleDecision(), state: &state)
    }
    return state
  }

  private struct RemovalFixture {
    var state: RuntimeState
    let config: Config
    let devWorkspace: WorkspaceID
    let selected: Window
    let localFallback: Window
    let external: Window
  }

  private func makeRemovalFixture() throws -> RemovalFixture {
    let devWorkspace = WorkspaceID(rawValue: "dev")
    let webWorkspace = WorkspaceID(rawValue: "web")
    let config = Config(
      workspaces: WorkspacesConfig(names: ["dev", "web"])
    )
    var state = RuntimeState(config: config)
    state.attachMonitor(monitorID)
    let selected = Window(
      id: WindowID(rawValue: 1),
      appID: "selected",
      title: "Selected",
      frame: Rect(x: 0, y: 0, width: 800, height: 700),
      monitorID: monitorID
    )
    let localFallback = Window(
      id: WindowID(rawValue: 2),
      appID: "fallback",
      title: "Fallback",
      frame: Rect(x: 0, y: 0, width: 800, height: 700),
      monitorID: monitorID
    )
    let external = Window(
      id: WindowID(rawValue: 3),
      appID: "external",
      title: "External",
      frame: Rect(x: 0, y: 0, width: 800, height: 700),
      monitorID: monitorID
    )
    try discoverWindow(selected, decision: RuleDecision(), state: &state)
    try discoverWindow(localFallback, decision: RuleDecision(), state: &state)
    try discoverWindow(
      external,
      decision: RuleDecision(workspace: webWorkspace),
      state: &state
    )
    focusWindow(selected.id, state: &state)
    return RemovalFixture(
      state: state,
      config: config,
      devWorkspace: devWorkspace,
      selected: selected,
      localFallback: localFallback,
      external: external
    )
  }

  private func removeSelectedWindow(
    keeping windows: [Window],
    removedWindowIDs: Set<WindowID>? = nil,
    from fixture: inout RemovalFixture
  ) throws -> WindowRemovalFocusGuard {
    reconcileWindows(windows, config: fixture.config, state: &fixture.state)
    return try #require(
      windowRemovalFocusGuard(
        previousMonitorID: monitorID,
        previousWorkspaceID: fixture.devWorkspace,
        previousSelectedWindowID: fixture.selected.id,
        removedWindowIDs: removedWindowIDs ?? [fixture.selected.id],
        userInputAfterWindowTopology: false,
        latestUserInputTimestamp: 10
      )
    )
  }

  private func setColumnWidths(_ width: ColumnWidth, state: inout RuntimeState) {
    for index in state.monitors[0].workspaces[0].columns.indices {
      state.monitors[0].workspaces[0].columns[index].width = width
    }
  }
}
