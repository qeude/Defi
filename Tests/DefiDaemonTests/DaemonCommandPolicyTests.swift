import DefiCore
import DefiModel
import Testing

@testable import DefiDaemon

struct DaemonCommandPolicyTests {
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
