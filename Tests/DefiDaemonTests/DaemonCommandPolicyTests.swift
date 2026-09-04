import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing

@testable import DefiDaemon

struct DaemonCommandPolicyTests {
  @Test
  func inactiveDesktopNeverArmsRecurringTimer() {
    #expect(desktopTimerFrequency(requested: 240, sessionActive: false) == 0)
    #expect(desktopTimerFrequency(requested: 2, sessionActive: true) == 2)
    #expect(desktopTimerFrequency(requested: 0, sessionActive: true) == 1)
    #expect(desktopTimerFrequency(requested: 500, sessionActive: true) == 240)
  }

  @Test
  func stalledRepairsBackOffWhileFocusRemainsResponsive() {
    #expect(followUpTimerFrequency(backoffSteps: 2, unchangedDuration: 3, focusPending: false) == 2)
    #expect(followUpTimerFrequency(backoffSteps: 2, unchangedDuration: 3, focusPending: true) == 15)
    #expect(followUpTimerFrequency(backoffSteps: 0, unchangedDuration: 0, focusPending: false) == 60)
  }

  @Test
  func idleWatchdogUsesEarliestDeadlineWithoutDelayingFallbackReads() {
    #expect(idleDesktopRefreshDelay(
      now: 10, latestInputAt: 0,
      deadlinesAndIntervals: [(40, 30), (25, 30)]
    ) == 15)
    #expect(idleDesktopRefreshDelay(
      now: 10, latestInputAt: 9.8,
      deadlinesAndIntervals: [(9, 30)]
    ) > 0.79)
    #expect(idleDesktopRefreshDelay(
      now: 10, latestInputAt: 10,
      deadlinesAndIntervals: [(9, 0.3), (40, 30)]
    ) == 0.3)
  }

  @Test(
    "Close fallback keeps the selected process",
    .bug("https://github.com/qeude/Defi/pull/49#discussion_r3925069182")
  )
  func closeFallbackKeepsSelectedProcess() {
    #expect(
      windowCloseTargetProcessID(
        eventTargetProcessID: nil,
        selectedProcessID: 42
      ) == 42
    )
  }

  @Test
  func closeTopologyRetriesAreBoundedAndLatestWins() {
    #expect(windowCloseRefreshDelays == [50, 150, 350, 700, 1_200, 2_000])
    #expect(
      windowCloseRetryIsCurrent(
        intentTimestamp: 10,
        latestInputTimestamp: 10,
        latestCloseIntentTimestamp: 10
      )
    )
    #expect(
      windowCloseRetryIsCurrent(
        intentTimestamp: 10,
        latestInputTimestamp: 11,
        latestCloseIntentTimestamp: 10
      ) == false
    )
    #expect(
      windowCloseRetryIsCurrent(
        intentTimestamp: 10,
        latestInputTimestamp: 11,
        latestCloseIntentTimestamp: 11
      ) == false
    )
  }

  @Test
  func backgroundSnapshotWaitsForTheCurrentCommandAnimation() {
    #expect(
      desktopSnapshotWaitsForCommandAnimation(
        animationPending: true,
        latestCommandInputTimestamp: 10,
        mouseFocusIntentTimestamp: nil,
        keyboardFocusIntentTimestamp: nil
      ))
    #expect(
      desktopSnapshotWaitsForCommandAnimation(
        animationPending: true,
        latestCommandInputTimestamp: 10,
        mouseFocusIntentTimestamp: 11,
        keyboardFocusIntentTimestamp: nil
      ) == false)
  }

  @Test
  func verticalWorkspaceTransitionUsesAPerceivableMinimumDuration() {
    #expect(workspaceVerticalTransitionDuration(configuredDurationMS: 0) == 0)
    #expect(workspaceVerticalTransitionDuration(configuredDurationMS: 35) == 0.18)
    #expect(workspaceVerticalTransitionDuration(configuredDurationMS: 250) == 0.25)
  }

  @Test
  func verticalWorkspaceTransitionRejectsAOverlappingMonitorPath() {
    let owner = Rect(x: 0, y: 0, width: 1_000, height: 800)

    #expect(
      workspaceTransitionPathIsClear(
        ownerFrame: owner,
        otherMonitorFrames: [Rect(x: 1_000, y: 0, width: 1_000, height: 800)]
      )
    )
    #expect(
      !workspaceTransitionPathIsClear(
        ownerFrame: owner,
        otherMonitorFrames: [Rect(x: 0, y: 800, width: 1_000, height: 800)]
      )
    )
  }

  @Test
  func verticalWorkspaceTransitionRejectsAnUncoveredDisplayMargin() {
    let physicalFrame = Rect(x: 0, y: 0, width: 1_512, height: 982)

    #expect(
      workspaceVerticalTransitionCanAnimateWithoutReservedAreaLeak(
        viewport: physicalFrame,
        physicalFrame: physicalFrame
      )
    )
    #expect(
      workspaceVerticalTransitionCanAnimateWithoutReservedAreaLeak(
        viewport: Rect(x: 0, y: 33, width: 1_512, height: 900),
        physicalFrame: physicalFrame
      ) == false
    )
  }

  @Test
  func verticalWorkspaceRibbonClearsThePhysicalMonitor() {
    let physicalFrame = Rect(x: 0, y: 0, width: 1_512, height: 982)
    let windowFrame = Rect(x: 4, y: 37, width: 1_204, height: 900)

    #expect(
      windowFrame.y
        + workspaceVerticalRibbonOffset(
          relativePosition: 1,
          physicalFrame: physicalFrame
        ) >= physicalFrame.y + physicalFrame.height
    )
    #expect(
      windowFrame.y + windowFrame.height
        + workspaceVerticalRibbonOffset(
          relativePosition: -1,
          physicalFrame: physicalFrame
        ) <= physicalFrame.y
    )
  }

  @Test
  func inactiveWorkspaceOnlyJoinsTheRibbonWhileLeaving() {
    let monitorID = MonitorID(rawValue: 1)
    let outgoingWorkspaceID = WorkspaceID(rawValue: "dev")
    let transition = WorkspaceVerticalTransition(
      monitorID: monitorID,
      outgoingWorkspaceID: outgoingWorkspaceID,
      direction: 1
    )
    let physicalFrame = Rect(x: 0, y: 0, width: 1_512, height: 982)

    #expect(
      outgoingWorkspaceVerticalRibbonOffset(
        workspaceID: outgoingWorkspaceID,
        monitorID: monitorID,
        transition: transition,
        physicalFrame: physicalFrame
      ) == -982
    )
    #expect(
      outgoingWorkspaceVerticalRibbonOffset(
        workspaceID: WorkspaceID(rawValue: "web"),
        monitorID: monitorID,
        transition: transition,
        physicalFrame: physicalFrame
      ) == nil
    )
  }

  @Test
  func workspaceTransitionIntentUsesTheTargetMonitorOrder() throws {
    let monitorID = MonitorID(rawValue: 1)
    var state = RuntimeState(
      config: Config(workspaces: WorkspacesConfig(names: ["dev", "web"]))
    )
    state.attachMonitor(monitorID)

    let intent = try #require(
      workspaceTransitionIntent(
        targetWorkspaceID: WorkspaceID(rawValue: "web"),
        state: state
      )
    )

    #expect(intent.monitorID == monitorID)
    #expect(intent.outgoingWorkspaceID == WorkspaceID(rawValue: "dev"))
    #expect(intent.incomingWorkspaceID == WorkspaceID(rawValue: "web"))
    #expect(intent.direction == 1)
  }

  @Test
  func overviewIgnoresParkingFocusWithoutNewFocusInput() {
    #expect(
      !shouldCloseOverviewAfterNativeFocusChange(
        nativeFocusChanged: true,
        overviewOpenedAt: 10,
        mouseFocusIntentTimestamp: 9,
        keyboardFocusIntentTimestamp: nil
      )
    )
    #expect(
      shouldCloseOverviewAfterNativeFocusChange(
        nativeFocusChanged: true,
        overviewOpenedAt: 10,
        mouseFocusIntentTimestamp: nil,
        keyboardFocusIntentTimestamp: 11
      )
    )
  }

  @Test
  func localCommandResubmitsMonitorsWithInFlightAnimation() {
    let animatedMonitor = MonitorID(rawValue: 1)
    let commandMonitor = MonitorID(rawValue: 2)

    #expect(
      commandLayoutMonitorIDs(
        affected: [commandMonitor],
        inFlightAnimations: [animatedMonitor]
      ) == [animatedMonitor, commandMonitor]
    )
  }

  @Test
  func inFlightAnimationDoesNotTurnACommandIntoANoOp() {
    #expect(
      !commandValidationIsNoOp(
        hasValidationState: false,
        rebasesPendingFrame: true,
        explicitlyFocusesFloating: false
      )
    )
    #expect(
      commandValidationIsNoOp(
        hasValidationState: false,
        rebasesPendingFrame: false,
        explicitlyFocusesFloating: false
      )
    )
  }

  @Test
  func localLayoutSubmissionSkipsCachedMonitorAssignments() {
    let included = MonitorID(rawValue: 1)
    let excluded = MonitorID(rawValue: 2)
    let assignment = FrameAssignment(
      windowID: WindowID(rawValue: 10),
      frame: Rect(x: 0, y: 0, width: 800, height: 600)
    )
    let plan = MonitorLayoutPlan(
      assignments: [assignment],
      borderAssignments: [assignment],
      nativeFullscreenPlaceholderAssignments: [],
      hiddenWindowIDs: []
    )

    #expect(
      layoutWindowIDsOutsideSubmissionScope(
        plan,
        monitorID: included,
        restrictedTo: [included]
      ).isEmpty
    )
    #expect(
      layoutWindowIDsOutsideSubmissionScope(
        plan,
        monitorID: excluded,
        restrictedTo: [included]
      ) == [assignment.windowID]
    )
  }

  @Test
  func staticFrameOrDeferredFocusKeepsCommandFollowUpResponsive() {
    #expect(
      commandFollowUpIsPending(
        frameWrites: true,
        animatedFocus: false,
        workspaceFocus: false
      )
    )
    #expect(
      commandFollowUpIsPending(
        frameWrites: false,
        animatedFocus: true,
        workspaceFocus: false
      )
    )
    #expect(
      commandFollowUpIsPending(
        frameWrites: false,
        animatedFocus: false,
        workspaceFocus: false
      ) == false)
  }

  @Test
  func crossMonitorAnimationWaitsForEveryDisplayAtTheSlowestCadence() {
    let source = MonitorID(rawValue: 1)
    let destination = MonitorID(rawValue: 2)

    let timing = animationDisplayTiming(
      monitorIDs: [source, destination],
      activeMonitorID: destination,
      fallbackMonitorID: source,
      refreshRates: [source: 60, destination: 120]
    )

    #expect(timing.refreshRateHz == 60)
    #expect(timing.displayIDs == [1, 2])
  }

  @Test
  func workspaceMutationUsesTheCommandMonitorFloatingWindows() {
    let activeMonitor = MonitorID(rawValue: 1)
    let commandMonitor = MonitorID(rawValue: 2)
    let activeFloating = WindowID(rawValue: 10)
    let commandFloating = WindowID(rawValue: 20)
    let workspaceID = WorkspaceID(rawValue: "dev")
    let monitors = [
      Monitor(
        id: activeMonitor,
        workspaces: [Workspace(id: workspaceID, floatingWindows: [activeFloating])],
        activeWorkspace: workspaceID
      ),
      Monitor(
        id: commandMonitor,
        workspaces: [Workspace(id: workspaceID, floatingWindows: [commandFloating])],
        activeWorkspace: workspaceID
      ),
    ]

    #expect(
      floatingWindowIDsForWorkspaceMutation(
        monitors: monitors,
        monitorID: commandMonitor
      ) == [commandFloating]
    )
  }

  @Test
  func crossMonitorMoveRefreshesEveryPreviousMonitor() {
    let source = MonitorID(rawValue: 1)
    let destination = MonitorID(rawValue: 2)
    let previousTransientMonitor = MonitorID(rawValue: 3)
    let owner = WindowID(rawValue: 10)
    let transient = WindowID(rawValue: 11)

    #expect(
      affectedMonitorIDsForWindowMove(
        commandMonitorID: source,
        resultMonitorID: destination,
        previousWindowMonitorIDs: [
          owner: source,
          transient: previousTransientMonitor,
        ],
        nextWindowMonitorIDs: [
          owner: destination,
          transient: destination,
        ]
      ) == [source, destination, previousTransientMonitor]
    )
  }

  @Test
  func columnTransferTargetsTheTiledSelectionWhenFloatingIsFocused() {
    let tiledID = WindowID(rawValue: 10)
    let floatingID = WindowID(rawValue: 11)

    #expect(
      crossMonitorCommandWindowID(
        .moveColumnToMonitor(.right),
        selectedWindowID: floatingID,
        selectedTiledWindowID: tiledID
      ) == tiledID
    )
    #expect(
      crossMonitorCommandWindowID(
        .moveWindowToMonitor(.right),
        selectedWindowID: floatingID,
        selectedTiledWindowID: tiledID
      ) == floatingID
    )
  }

  @Test
  func crossMonitorMoveRebasesTheFreshlyObservedFloatingFrame() {
    let source = MonitorID(rawValue: 1)
    let destination = MonitorID(rawValue: 2)
    let windowID = WindowID(rawValue: 10)
    let freshFrame = Rect(x: 350, y: 80, width: 300, height: 200)

    #expect(
      rebasedFloatingWindowFrames(
        [windowID: freshFrame],
        previousViewports: [
          source: Rect(x: 0, y: 0, width: 1_000, height: 800)
        ],
        nextViewports: [
          destination: Rect(x: 1_000, y: 0, width: 2_000, height: 800)
        ],
        previousMonitorIDs: [windowID: source],
        nextMonitorIDs: [windowID: destination]
      )[windowID] == Rect(x: 1_850, y: 80, width: 300, height: 200)
    )
  }

  @Test
  func crossMonitorMoveForcesOnlyMovedFloatingFrameWrites() {
    let source = MonitorID(rawValue: 1)
    let destination = MonitorID(rawValue: 2)
    let floatingID = WindowID(rawValue: 10)
    let tiledID = WindowID(rawValue: 11)
    let stationaryFloatingID = WindowID(rawValue: 12)

    #expect(
      floatingWindowIDsMovedBetweenMonitors(
        previousWindowMonitorIDs: [
          floatingID: source,
          tiledID: source,
          stationaryFloatingID: source,
        ],
        nextWindowMonitorIDs: [
          floatingID: destination,
          tiledID: destination,
          stationaryFloatingID: source,
        ],
        windows: [
          floatingID: Window(
            id: floatingID,
            appID: "app",
            title: "Floating",
            frame: Rect(x: 0, y: 0, width: 300, height: 200),
            floating: true
          ),
          tiledID: Window(
            id: tiledID,
            appID: "app",
            title: "Tiled",
            frame: Rect(x: 0, y: 0, width: 600, height: 800)
          ),
          stationaryFloatingID: Window(
            id: stationaryFloatingID,
            appID: "app",
            title: "Stationary",
            frame: Rect(x: 0, y: 0, width: 300, height: 200),
            floating: true
          ),
        ]
      ) == [floatingID]
    )
  }
}
